from __future__ import annotations

import json
import logging
import mimetypes
import os
import glob
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from urllib.request import urlopen

from .config import AgentConfig, validate_provisioning
from .control_bus import ControlBus
from .ssh_control_client import SshControlClient


WEB_ROOT = Path(__file__).resolve().parents[2] / "web"
DEFAULT_CONFIG_PATH = "/etc/darwin-switch-agent/config.json"
STATIC_CACHE_CONTROL = "public, max-age=0, must-revalidate"

# Config keys whose values are nested dicts and must be merged one level deep.
_NESTED_SECTIONS = ("mac", "robot", "camera", "ssh", "motion")
PREFLIGHT_TIMEOUT_SEC = 0.55
_KIOSK_BROWSER_COMMANDS = ("firefox", "chromium-browser", "chromium", "google-chrome")
_BROWSER_COMMANDS = (*_KIOSK_BROWSER_COMMANDS, "xdg-open")
_SERVICE_TARGETS = {
    "agent": "darwin-switch-agent.service",
    "camera_tunnel": "darwin-switch-camera-tunnel.service",
}
_SERVICE_ACTIONS = {"enable_now", "restart", "stop"}
_SYSTEM_ACTIONS = {"exit_app"}
_ROBOT_READY_ACTIONS = {
    "plan": 8.0,
    "keygen": 12.0,
    "probe": 8.0,
    "status": 12.0,
    "start-walklab": 24.0,
    "enable-agent-ssh": 14.0,
    "stabilize": 14.0,
    "all": 60.0,
}
CAMERA_FRAME_PROXY_MIN_INTERVAL_SEC = 0.22
CAMERA_FRAME_PROXY_TIMEOUT_SEC = 0.8
CAMERA_FRAME_PROXY_STALE_SEC = 3.0


class CameraFrameProxy:
    """Small single-frame cache in front of ROBOTIS camera_tutorial.

    The Switch UI used to point <img> directly at `/?action=snapshot` every
    ~110ms. On real hardware that can make camera_tutorial reset connections or
    leave :8080 accepting sockets without delivering a JPEG. This proxy keeps
    the browser on a local same-origin URL and rate-limits robot camera reads;
    if one fetch fails, it can still serve the last good frame briefly instead
    of flashing the camera panel black.
    """

    def __init__(
        self,
        *,
        min_interval_sec: float = CAMERA_FRAME_PROXY_MIN_INTERVAL_SEC,
        timeout_sec: float = CAMERA_FRAME_PROXY_TIMEOUT_SEC,
        stale_sec: float = CAMERA_FRAME_PROXY_STALE_SEC,
    ) -> None:
        self.min_interval_sec = min_interval_sec
        self.timeout_sec = timeout_sec
        self.stale_sec = stale_sec
        self._lock = threading.Lock()
        self._last_url = ""
        self._last_data = b""
        self._last_at = 0.0

    def get(self, url: str) -> tuple[bytes, bool]:
        now = time.monotonic()
        with self._lock:
            if self._last_url == url and self._last_data and now - self._last_at < self.min_interval_sec:
                return self._last_data, True
            cached = self._last_data if self._last_url == url else b""
            cached_age = now - self._last_at if cached else 0.0
        try:
            data = self._fetch_jpeg(url, attempts=1 if cached else 2)
            with self._lock:
                self._last_url = url
                self._last_data = data
                self._last_at = time.monotonic()
            return data, False
        except Exception:
            if cached and cached_age <= self.stale_sec:
                return cached, True
            raise

    def _fetch_jpeg(self, url: str, attempts: int) -> bytes:
        last_error: Exception | None = None
        for attempt in range(max(1, attempts)):
            try:
                with urlopen(url, timeout=self.timeout_sec) as fp:
                    data = fp.read(1_500_000)
                if not _looks_like_jpeg(data):
                    raise OSError("camera endpoint did not return a JPEG frame")
                return data
            except Exception as exc:
                last_error = exc
                if attempt + 1 < attempts:
                    time.sleep(0.08)
        raise last_error or OSError("camera frame unavailable")


def _looks_like_jpeg(data: bytes) -> bool:
    return len(data) > 256 and data.startswith(b"\xff\xd8")


_CAMERA_FRAME_PROXY = CameraFrameProxy()


def merge_config(existing: dict[str, Any], updates: dict[str, Any]) -> dict[str, Any]:
    """Merge validated provisioning updates into config without mutation.

    Top-level scalars (e.g. 'mode') replace; known nested sections are merged
    one level deep so partial section updates keep untouched sub-keys.
    """
    merged = {**existing, **{k: v for k, v in updates.items() if k not in _NESTED_SECTIONS}}
    for section in _NESTED_SECTIONS:
        if section in updates:
            base = existing.get(section, {})
            base = base if isinstance(base, dict) else {}
            merged = {**merged, section: {**base, **updates[section]}}
    return merged


def run_preflight(config: dict[str, Any], timeout: float = PREFLIGHT_TIMEOUT_SEC) -> dict[str, Any]:
    """Fast, side-effect-free setup checks before saving device config.

    This never sends robot control commands and never starts SSH sessions. It
    only checks local config shape, TCP reachability where the transport is TCP,
    local SSH key presence, and camera URL/tunnel availability.
    """
    mode = str(config.get("mode", "dry_run"))
    checks: list[dict[str, str]] = []

    if mode == "dry_run":
        checks.append(_check("mode", "good", "연습 모드", "로봇으로 명령을 보내지 않고 UI만 확인합니다."))
    elif mode == "mac_relay":
        mac = _section(config, "mac")
        host = str(mac.get("host", "127.0.0.1"))
        port = _int_or_zero(mac.get("port", 0))
        checks.append(_tcp_preflight("mac", "Mac 릴레이", host, port, timeout))
    elif mode == "ssh":
        ssh = _section(config, "ssh")
        host = str(ssh.get("host", "192.168.123.1"))
        port = _int_or_zero(ssh.get("port", 22)) or 22
        checks.append(_tcp_preflight("ssh", "SSH 포트", host, port, timeout))
        identity = str(ssh.get("identity_file", "")).strip()
        if identity:
            path = os.path.expanduser(identity)
            checks.append(
                _check(
                    "ssh_key",
                    "good" if os.path.isfile(path) else "warn",
                    "SSH 키",
                    f"{identity} 확인됨" if os.path.isfile(path) else f"{identity} 파일을 아직 확인할 수 없습니다.",
                )
            )
        else:
            checks.append(_check("ssh_key", "warn", "SSH 키", "키 파일 없이 기본 SSH 인증을 사용합니다."))
    elif mode == "robot_udp":
        robot = _section(config, "robot")
        host = str(robot.get("host", "192.168.0.100"))
        port = _int_or_zero(robot.get("port", 55310))
        level = "good" if host and 0 < port <= 65535 else "bad"
        detail = f"{host}:{port} UDP 대상으로 저장 가능" if level == "good" else "로봇 UDP 호스트와 포트를 확인하세요."
        checks.append(_check("robot_udp", level, "로봇 UDP", detail))
        checks.append(_check("robot_udp_runtime", "warn", "수신기", "UDP 수신기는 저장 후 로봇 쪽 수신 프로그램으로 실기 검증해야 합니다."))
    else:
        checks.append(_check("mode", "bad", "조종 방식", f"지원하지 않는 모드입니다: {mode}"))

    camera = _section(config, "camera")
    if bool(camera.get("enabled", False)):
        checks.append(_camera_preflight(camera, timeout))
    else:
        checks.append(_check("camera", "warn", "카메라", "카메라 표시가 꺼져 있습니다."))

    level = _overall_level(checks)
    return {"ok": level != "bad", "level": level, "checks": checks}


def run_system_health(config_path: str = DEFAULT_CONFIG_PATH) -> dict[str, Any]:
    """Read-only Switch runtime readiness checks for the setup screen.

    Unlike install.sh, this function never enables services, edits users, or
    writes files. It only reports whether the local Linux environment looks
    ready to behave like a native fullscreen cockpit.
    """
    checks: list[dict[str, str]] = [
        _python_health(),
        _browser_health(),
        _systemd_service_health("darwin-switch-agent.service", "에이전트 서비스", "agent_service"),
        _joycond_health(),
        _input_health(),
        _camera_tunnel_health(),
        _systemd_service_health("darwin-switch-camera-tunnel.service", "카메라 터널 서비스", "camera_tunnel_service"),
        _autossh_health(),
        _config_health(config_path),
    ]
    level = _overall_level(checks)
    return {"ok": level != "bad", "level": level, "checks": checks}


def run_service_action(service_key: str, action: str) -> dict[str, Any]:
    """Run a whitelisted local systemd service action for the kiosk UI."""
    unit = _SERVICE_TARGETS.get(service_key)
    if not unit:
        return {"ok": False, "error": "unknown service"}
    if action not in _SERVICE_ACTIONS:
        return {"ok": False, "error": "unknown service action"}
    if not shutil.which("systemctl"):
        return {"ok": False, "error": "systemctl unavailable"}

    if action == "enable_now":
        command = ("enable", "--now", unit)
    elif action == "restart":
        command = ("restart", unit)
    else:
        command = ("disable", "--now", unit)

    code, out = _systemctl_slow(*command)
    if code != 0:
        return {
            "ok": False,
            "service": service_key,
            "action": action,
            "unit": unit,
            "error": out or "systemctl failed",
        }
    status = _systemd_service_health(unit, "카메라 터널 서비스", "camera_tunnel_service")
    return {"ok": True, "service": service_key, "action": action, "unit": unit, "status": status}


def run_system_action(action: str) -> dict[str, Any]:
    """Run a whitelisted local desktop action for the kiosk UI."""
    if action not in _SYSTEM_ACTIONS:
        return {"ok": False, "error": "unknown system action"}
    pids = _cockpit_browser_pids()
    if not pids:
        return {"ok": False, "action": action, "error": "cockpit browser not found"}
    try:
        pid_list = " ".join(str(pid) for pid in pids)
        subprocess.Popen(
            ["sh", "-c", f"sleep 0.25; kill -TERM {pid_list}; sleep 0.9; kill -KILL {pid_list} 2>/dev/null || true"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        return {"ok": False, "action": action, "error": str(exc), "pids": pids}
    return {"ok": True, "action": action, "pids": pids}


def _cockpit_browser_pids(proc_root: str = "/proc") -> list[int]:
    pids: list[int] = []
    current = os.getpid()
    for entry in Path(proc_root).iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == current:
            continue
        try:
            raw = (entry / "cmdline").read_bytes()
        except OSError:
            continue
        cmd = raw.replace(b"\0", b" ").decode("utf-8", "replace")
        if _is_cockpit_browser_cmd(cmd):
            pids.append(pid)
    return sorted(set(pids))


def _is_cockpit_browser_cmd(cmd: str) -> bool:
    if not cmd:
        return False
    browser = "chromium" in cmd or "chrome" in cmd or "firefox" in cmd
    if not browser:
        return False
    return (
        "darwin-switch-cockpit/chromium" in cmd
        or "127.0.0.1:8765" in cmd
        or "localhost:8765" in cmd
    )


def run_robot_ready_action(action: str, config_path: str = DEFAULT_CONFIG_PATH) -> dict[str, Any]:
    """Run a whitelisted robot-readiness command for the local kiosk UI.

    The interactive `copy-key` step is intentionally excluded: ssh-copy-id can
    require a robot password and would hang a browser-triggered request. The UI
    shows the copy command from `plan` instead.
    """
    timeout = _ROBOT_READY_ACTIONS.get(action)
    if timeout is None:
        return {"ok": False, "error": "unknown robot-ready action"}
    command = [
        shutil.which("darwin-switch-robot-ready") or str(WEB_ROOT.parent / "bin" / "darwin-switch-robot-ready"),
        "--config",
        config_path,
        action,
    ]
    try:
        proc = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "action": action,
            "error": "timeout",
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "",
        }
    except OSError as exc:
        return {"ok": False, "action": action, "error": str(exc), "stdout": "", "stderr": ""}
    return {
        "ok": proc.returncode == 0,
        "action": action,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def run_robot_command_status(config_path: str = DEFAULT_CONFIG_PATH) -> dict[str, Any]:
    """Read the robot-side WalkLab command file using the saved SSH config."""
    try:
        config = AgentConfig.load(config_path)
    except (OSError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"config unreadable: {exc}"}
    if config.mode != "ssh":
        return {"ok": False, "error": "mode is not ssh"}
    client = SshControlClient(config.section("ssh"))
    status = client.command_status()
    client.close()
    if status is None:
        return {"ok": False, "error": "robot command unavailable"}
    return {"ok": True, "status": status}


def _section(config: dict[str, Any], name: str) -> dict[str, Any]:
    value = config.get(name, {})
    return value if isinstance(value, dict) else {}


def _check(check_id: str, level: str, title: str, detail: str) -> dict[str, str]:
    return {"id": check_id, "level": level, "title": title, "detail": detail}


def _int_or_zero(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _tcp_preflight(check_id: str, title: str, host: str, port: int, timeout: float) -> dict[str, str]:
    if not host or port <= 0 or port > 65535:
        return _check(check_id, "bad", title, "호스트와 포트를 먼저 입력하세요.")
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
    except OSError as exc:
        return _check(check_id, "bad", title, f"{host}:{port} 연결 실패 ({exc.__class__.__name__})")
    return _check(check_id, "good", title, f"{host}:{port} 연결 가능")


def _camera_preflight(camera: dict[str, Any], timeout: float) -> dict[str, str]:
    raw = str(camera.get("stream_url", "")).strip()
    if not raw:
        return _check("camera", "warn", "카메라", "스트림 URL이 아직 설정되지 않았습니다.")
    parsed = urlparse(raw)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return _check("camera", "bad", "카메라", "스트림 URL 형식을 확인하세요.")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        with socket.create_connection((parsed.hostname, port), timeout=timeout):
            pass
    except OSError:
        return _check("camera", "warn", "카메라", f"{parsed.hostname}:{port} 스트림 포트가 아직 열려 있지 않습니다.")
    return _check("camera", "good", "카메라", f"{parsed.hostname}:{port} 스트림 포트 연결 가능")


def _python_health() -> dict[str, str]:
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    level = "good" if sys.version_info >= (3, 9) else "warn"
    detail = f"Python {version}"
    if level == "warn":
        detail += " · 3.9 이상 권장"
    return _check("python", level, "Python", detail)


def _browser_health() -> dict[str, str]:
    kiosk = [name for name in _KIOSK_BROWSER_COMMANDS if shutil.which(name)]
    if kiosk:
        return _check("browser", "good", "키오스크 브라우저", kiosk[0])
    if shutil.which("xdg-open"):
        return _check("browser", "warn", "키오스크 브라우저", "xdg-open만 있음 · fullscreen kiosk 브라우저 설치 권장")
    return _check("browser", "bad", "키오스크 브라우저", "firefox/chromium 계열 브라우저가 필요합니다.")


def _systemctl(*args: str) -> tuple[int, str]:
    if not shutil.which("systemctl"):
        return 127, ""
    try:
        proc = subprocess.run(
            ("systemctl", *args),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=0.8,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 126, ""
    return proc.returncode, proc.stdout.strip()


def _systemctl_slow(*args: str) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ("systemctl", *args),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=8.0,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 126, str(exc)
    return proc.returncode, proc.stdout.strip()


def _systemd_service_health(unit: str, title: str, check_id: str) -> dict[str, str]:
    code, out = _systemctl("is-active", unit)
    if code == 127:
        return _check(check_id, "warn", title, "systemd 상태를 이 환경에서 확인할 수 없습니다.")
    if code == 0:
        return _check(check_id, "good", title, "실행 중")
    code_enabled, enabled = _systemctl("is-enabled", unit)
    if code_enabled == 0:
        return _check(check_id, "warn", title, f"{enabled or 'enabled'} · 아직 실행 중 아님")
    return _check(check_id, "warn", title, "서비스 설치/실행 상태를 확인하세요.")


def _joycond_health() -> dict[str, str]:
    code, out = _systemctl("is-active", "joycond.service")
    if code == 127:
        return _check("joycond", "warn", "Joy-Con 병합", "systemd 상태를 이 환경에서 확인할 수 없습니다.")
    if code == 0:
        return _check("joycond", "good", "Joy-Con 병합", "joycond.service 실행 중")
    code_enabled, enabled = _systemctl("is-enabled", "joycond.service")
    if code_enabled == 0:
        return _check("joycond", "warn", "Joy-Con 병합", f"{enabled or 'enabled'} · 서비스 시작 필요")
    return _check("joycond", "warn", "Joy-Con 병합", "joycond 미설치 가능성 · Joy-Con 페어링 전 설치 권장")


def _input_health() -> dict[str, str]:
    paths = sorted(glob.glob("/dev/input/event*"))
    if not paths:
        return _check("input_nodes", "warn", "입력 노드", "/dev/input/event* 없음")
    readable = [path for path in paths if os.access(path, os.R_OK)]
    if readable:
        return _check("input_nodes", "good", "입력 노드", f"{len(readable)}개 읽기 가능")
    return _check("input_nodes", "warn", "입력 노드", f"{len(paths)}개 발견 · 권한 확인 필요")


def _camera_tunnel_health() -> dict[str, str]:
    bundled = WEB_ROOT.parent / "bin" / "darwin-switch-camera-tunnel"
    if shutil.which("darwin-switch-camera-tunnel"):
        return _check("camera_tunnel", "good", "카메라 터널", "PATH에서 실행 가능")
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return _check("camera_tunnel", "good", "카메라 터널", "번들 스크립트 포함")
    return _check("camera_tunnel", "warn", "카메라 터널", "darwin-switch-camera-tunnel 확인 필요")


def _autossh_health() -> dict[str, str]:
    if shutil.which("autossh"):
        return _check("autossh", "good", "터널 복구", "autossh 사용 가능")
    return _check("autossh", "warn", "터널 복구", "autossh 없음 · 카메라 터널 자동복구 약함")


def _config_health(config_path: str) -> dict[str, str]:
    path = Path(config_path)
    if path.is_file():
        return _check("config", "good", "설정 파일", str(path))
    if path.parent.exists():
        return _check("config", "warn", "설정 파일", f"{path} 아직 없음")
    return _check("config", "warn", "설정 파일", f"{path.parent} 디렉터리 없음")


def _overall_level(checks: list[dict[str, str]]) -> str:
    levels = {check.get("level", "warn") for check in checks}
    if "bad" in levels:
        return "bad"
    if "warn" in levels:
        return "warn"
    return "good"


class CockpitServer:
    def __init__(
        self,
        bus: ControlBus,
        host: str = "127.0.0.1",
        port: int = 8765,
        config_path: str = DEFAULT_CONFIG_PATH,
    ):
        self.bus = bus
        self.host = host
        self.port = port
        self.config_path = config_path
        self.log = logging.getLogger("cockpit")
        self.httpd: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        bus = self.bus
        cfg_path = self.config_path

        class Handler(CockpitHandler):
            control_bus = bus
            config_path = cfg_path

        self.httpd = ThreadingHTTPServer((self.host, self.port), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.log.info("cockpit listening on http://%s:%d", self.host, self.port)

    def stop(self) -> None:
        if self.httpd:
            self.httpd.shutdown()
            self.httpd.server_close()
        if self.thread:
            self.thread.join(timeout=1.0)


class CockpitHandler(BaseHTTPRequestHandler):
    control_bus: ControlBus
    config_path: str = DEFAULT_CONFIG_PATH

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.getLogger("cockpit.http").debug(fmt, *args)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/state"):
            self._send_json(self.control_bus.snapshot())
            return
        if parsed.path == "/api/camera-frame.jpg":
            self._handle_camera_frame()
            return
        if parsed.path == "/api/config":
            self._handle_get_config()
            return
        if parsed.path == "/api/provisioning":
            self._send_json({"provisioned": self._is_provisioned()})
            return
        if parsed.path == "/api/health":
            self._handle_health()
            return
        if parsed.path == "/api/robot-command":
            self._handle_robot_command()
            return
        if parsed.path in {"", "/"} and not self._is_provisioned():
            self._redirect("/setup.html")
            return
        path = "/index.html" if parsed.path in {"", "/"} else parsed.path
        self._send_static(path)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/action":
            self._handle_action()
            return
        if parsed.path == "/api/config":
            self._handle_post_config()
            return
        if parsed.path == "/api/preflight":
            self._handle_preflight()
            return
        if parsed.path == "/api/service":
            self._handle_service_action()
            return
        if parsed.path == "/api/robot-ready":
            self._handle_robot_ready()
            return
        if parsed.path == "/api/system":
            self._handle_system_action()
            return
        self.send_error(404)

    def _read_json_body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0") or 0)
        except (TypeError, ValueError):
            length = 0
        length = max(length, 0)
        body = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}
        return payload if isinstance(payload, dict) else {}

    def _handle_action(self) -> None:
        payload = self._read_json_body()
        action = str(payload.get("action", "")).strip()
        if action not in {"arm", "stop", "estop", "recover", "ping", "reconnect"}:
            self._send_json({"ok": False, "error": "unknown action"}, status=400)
            return
        self.control_bus.request(action)
        self._send_json({"ok": True, "action": action})

    def _is_loopback(self) -> bool:
        """True only for loopback clients. /api/config reads+writes device
        config (incl. secrets), so it is restricted to the Switch's own kiosk
        browser even if gui.host is ever set to 0.0.0.0."""
        client = (self.client_address[0] if self.client_address else "")
        return client in {"127.0.0.1", "::1", "::ffff:127.0.0.1"}

    def _handle_get_config(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local config only"}, status=403)
            return
        # First-boot provisioning UI reads current device config (localhost only).
        try:
            with open(self.config_path, "r", encoding="utf-8") as fp:
                current = json.load(fp)
        except FileNotFoundError:
            self._send_json({})
            return
        except (OSError, json.JSONDecodeError) as exc:
            logging.getLogger("cockpit").warning("config read failed: %s", exc)
            self._send_json({"ok": False, "error": "config unreadable"}, status=500)
            return
        self._send_json(current if isinstance(current, dict) else {})

    def _handle_post_config(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local config only"}, status=403)
            return
        payload = self._read_json_body()
        try:
            updates = validate_provisioning(payload)
        except ValueError as exc:
            self._send_json({"ok": False, "error": str(exc)}, status=400)
            return
        try:
            self._write_config(updates)
        except OSError as exc:
            logging.getLogger("cockpit").error("config write failed: %s", exc)
            self._send_json({"ok": False, "error": "write failed"}, status=500)
            return
        self._send_json({"ok": True})

    def _handle_preflight(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local config only"}, status=403)
            return
        payload = self._read_json_body()
        try:
            updates = validate_provisioning(payload)
        except ValueError as exc:
            self._send_json({"ok": False, "level": "bad", "error": str(exc)}, status=400)
            return
        try:
            existing = self._read_config_dict()
        except (OSError, json.JSONDecodeError) as exc:
            logging.getLogger("cockpit").warning("config read failed for preflight: %s", exc)
            existing = {}
        self._send_json(run_preflight(merge_config(existing, updates)))

    def _handle_health(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local health only"}, status=403)
            return
        self._send_json(run_system_health(self.config_path))

    def _handle_service_action(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local service only"}, status=403)
            return
        payload = self._read_json_body()
        service = str(payload.get("service", "")).strip()
        action = str(payload.get("action", "")).strip()
        result = run_service_action(service, action)
        self._send_json(result, status=200 if result.get("ok") else 400)

    def _handle_robot_ready(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local robot-ready only"}, status=403)
            return
        payload = self._read_json_body()
        action = str(payload.get("action", "")).strip()
        result = run_robot_ready_action(action, self.config_path)
        self._send_json(result, status=200 if result.get("ok") else 400)

    def _handle_system_action(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local system only"}, status=403)
            return
        payload = self._read_json_body()
        action = str(payload.get("action", "")).strip()
        result = run_system_action(action)
        self._send_json(result, status=200 if result.get("ok") else 400)

    def _handle_robot_command(self) -> None:
        if not self._is_loopback():
            self._send_json({"ok": False, "error": "local robot command only"}, status=403)
            return
        result = run_robot_command_status(self.config_path)
        self._send_json(result, status=200 if result.get("ok") else 400)

    def _handle_camera_frame(self) -> None:
        if not self._is_loopback():
            self.send_error(403)
            return
        try:
            config = self._read_config_dict()
        except (OSError, json.JSONDecodeError):
            self.send_error(503, "camera config unavailable")
            return
        camera = config.get("camera", {})
        camera = camera if isinstance(camera, dict) else {}
        if not bool(camera.get("enabled", False)):
            self.send_error(404, "camera disabled")
            return
        url = str(camera.get("snapshot_url") or camera.get("stream_url") or "").strip()
        if not url:
            self.send_error(404, "camera url missing")
            return
        try:
            data, cache_hit = _CAMERA_FRAME_PROXY.get(url)
        except Exception as exc:
            logging.getLogger("cockpit.camera").warning("camera frame fetch failed: %s", exc)
            self.send_error(503, "camera frame unavailable")
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Darwin-Camera-Cache", "hit" if cache_hit else "miss")
        self.end_headers()
        self.wfile.write(data)

    def _write_config(self, updates: dict[str, Any]) -> None:
        # Merge immutably into existing config, write atomically, drop marker.
        path = Path(self.config_path)
        try:
            existing = CockpitHandler._read_config_dict(self)
        except (FileNotFoundError, json.JSONDecodeError):
            existing = {}
        merged = merge_config(existing, updates)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".config.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fp:
                json.dump(merged, fp, indent=2)
                fp.write("\n")
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        marker = path.parent / ".provisioned"
        try:
            marker.write_text("1\n", encoding="utf-8")
        except OSError as exc:
            logging.getLogger("cockpit").warning("marker write failed: %s", exc)

    def _is_provisioned(self) -> bool:
        return CockpitHandler._provisioned_marker_path(self).is_file()

    def _provisioned_marker_path(self) -> Path:
        return Path(self.config_path).parent / ".provisioned"

    def _read_config_dict(self) -> dict[str, Any]:
        with open(self.config_path, "r", encoding="utf-8") as fp:
            current = json.load(fp)
        return current if isinstance(current, dict) else {}

    def _redirect(self, location: str) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def _send_static(self, request_path: str) -> None:
        rel = request_path.lstrip("/")
        if not rel or ".." in Path(rel).parts:
            self.send_error(404)
            return
        path = WEB_ROOT / rel
        if not path.is_file():
            self.send_error(404)
            return
        content_type = self._content_type(path)
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", STATIC_CACHE_CONTROL)
        if path.name == "sw.js":
            self.send_header("Service-Worker-Allowed", "/")
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def _content_type(path: Path) -> str:
        if path.suffix == ".webmanifest":
            return "application/manifest+json"
        if path.name == "sw.js":
            return "text/javascript"
        return mimetypes.guess_type(str(path))[0] or "application/octet-stream"

    def _send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
