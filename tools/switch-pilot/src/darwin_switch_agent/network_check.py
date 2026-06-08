from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import urlopen

from .config import AgentConfig
from .discovery import local_ip_hint
from .ssh_control_client import ssh_args


DEFAULT_ROOT = Path("/opt/darwin-switch-agent")
DEFAULT_CONFIG = Path("/etc/darwin-switch-agent/config.json")


@dataclass(frozen=True)
class NetCheck:
    id: str
    level: str
    title: str
    detail: str
    fix: str = ""


def _check(check_id: str, level: str, title: str, detail: str, fix: str = "") -> NetCheck:
    return NetCheck(check_id, level, title, detail, fix)


def load_config(config_path: Path, root: Path) -> AgentConfig:
    if config_path.is_file():
        return AgentConfig.load(str(config_path))
    fallback = root / "config.example.json"
    if fallback.is_file():
        return AgentConfig.load(str(fallback))
    return AgentConfig({"mode": "dry_run"})


def run_network_report(
    config: AgentConfig,
    base_url: str = "",
    timeout: float = 1.5,
    ssh_probe: bool = False,
) -> dict[str, Any]:
    raw = config.raw
    gui = config.section("gui")
    mac = config.section("mac")
    robot = config.section("robot")
    ssh = config.section("ssh")
    camera = config.section("camera")
    checks: list[NetCheck] = []

    ip_hint = local_ip_hint()
    checks.append(
        _check(
            "local_ip",
            "good" if ip_hint != "127.0.0.1" else "warn",
            "Switch IP",
            ip_hint,
            "Wi-Fi 또는 유선 네트워크를 연결하세요." if ip_hint == "127.0.0.1" else "",
        )
    )

    cockpit_url = base_url.strip() or f"http://127.0.0.1:{int(gui.get('port', 8765))}"
    checks.append(_http_check(f"{cockpit_url.rstrip('/')}/api/state", "cockpit_api", "Cockpit API", timeout))

    mode = str(raw.get("mode", "dry_run"))
    if mode == "mac_relay":
        checks.append(_tcp_check(str(mac.get("host", "")), _int(mac.get("port")), "mac_relay", "Mac relay TCP", timeout))
    elif mode == "ssh":
        checks.extend(_ssh_checks(ssh, timeout, ssh_probe))
    elif mode == "robot_udp":
        checks.append(_udp_shape_check(robot))
    else:
        checks.append(_check("mode_target", "good", "Control target", "dry_run · no remote target required"))

    # The camera tunnel uses SSH even when the control mode is not 'ssh', so
    # always validate the configured SSH endpoint when camera is enabled.
    if bool(camera.get("enabled", False)):
        if mode != "ssh":
            checks.append(_tcp_check(str(ssh.get("host", "192.168.123.1")), _int(ssh.get("port", 22)) or 22, "camera_ssh_port", "Camera SSH TCP", timeout))
        checks.append(_tool_check("autossh", "Camera tunnel reconnect", "sudo apt-get install autossh"))
        for key, title in (("stream_url", "Camera stream URL"), ("snapshot_url", "Camera snapshot URL")):
            url = str(camera.get(key, "")).strip()
            if url:
                checks.append(_http_prefix_check(url, f"camera_{key}", title, timeout))
            else:
                checks.append(_check(f"camera_{key}", "warn", title, "not configured", "Set it in /setup.html."))
    else:
        checks.append(_check("camera", "warn", "Camera", "disabled", "Enable after robot SSH/camera endpoint is ready."))

    level = _overall_level(checks)
    return {
        "ok": level != "bad",
        "level": level,
        "mode": mode,
        "base_url": cockpit_url,
        "ssh_probe": ssh_probe,
        "checks": [asdict(check) for check in checks],
    }


def _int(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _tcp_check(host: str, port: int, check_id: str, title: str, timeout: float) -> NetCheck:
    if not host or port <= 0 or port > 65535:
        return _check(check_id, "warn", title, f"not configured ({host}:{port})", "Set host/port in /setup.html.")
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
    except OSError as exc:
        return _check(check_id, "warn", title, f"{host}:{port} unreachable ({exc.__class__.__name__})", "Check same network, IP, firewall, and service status.")
    return _check(check_id, "good", title, f"{host}:{port} reachable")


def _http_check(url: str, check_id: str, title: str, timeout: float, warn_on_refused: bool = False) -> NetCheck:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return _check(check_id, "bad", title, f"invalid URL: {url}", "Use http://host:port/path.")
    try:
        with urlopen(url, timeout=timeout) as fp:
            data = fp.read(256)
            return _check(check_id, "good", title, f"HTTP {fp.status} · {len(data)} bytes")
    except HTTPError as exc:
        level = "warn" if warn_on_refused else "bad"
        return _check(check_id, level, title, f"HTTP {exc.code}", "Check endpoint path and service.")
    except (OSError, URLError) as exc:
        level = "warn" if warn_on_refused else "warn"
        return _check(check_id, level, title, f"{exc.__class__.__name__}", "Start the service or tunnel, then retry.")


def _http_prefix_check(url: str, check_id: str, title: str, timeout: float) -> NetCheck:
    """Check that a camera HTTP endpoint starts responding.

    MJPEG streams are intentionally long-lived. Reading them through urllib can
    report ConnectionResetError when a probe closes early, even though the
    browser-visible stream is healthy. For camera readiness, the invariant we
    need is simpler: the socket accepts an HTTP GET and returns a status line
    plus initial bytes within the timeout.
    """
    parsed = urlparse(url)
    if parsed.scheme != "http" or not parsed.hostname:
        return _check(check_id, "bad", title, f"invalid URL: {url}", "Use http://host:port/path.")
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {parsed.hostname}:{port}\r\n"
        "User-Agent: darwin-switch-network-check\r\n"
        "Connection: close\r\n\r\n"
    ).encode("ascii", "replace")
    try:
        with socket.create_connection((parsed.hostname, port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(request)
            data = sock.recv(512)
    except OSError as exc:
        return _check(check_id, "warn", title, f"{exc.__class__.__name__}", "Start the service or tunnel, then retry.")
    if not data:
        return _check(check_id, "warn", title, "empty response", "Start the service or tunnel, then retry.")
    first_line = data.split(b"\r\n", 1)[0].decode("ascii", "replace")
    parts = first_line.split()
    if len(parts) >= 2 and parts[0].startswith("HTTP/"):
        try:
            code = int(parts[1])
        except ValueError:
            code = 0
        level = "good" if 200 <= code < 400 else "warn"
        fix = "" if level == "good" else "Check endpoint path and service."
        return _check(check_id, level, title, f"HTTP {code} · {len(data)} initial bytes", fix)
    return _check(check_id, "warn", title, f"unexpected response · {len(data)} bytes", "Check endpoint path and service.")


def _tool_check(name: str, title: str, fix: str) -> NetCheck:
    path = shutil.which(name)
    if path:
        return _check(name, "good", title, path)
    return _check(name, "warn", title, f"{name} not found", fix)


def _udp_shape_check(robot: dict[str, Any]) -> NetCheck:
    host = str(robot.get("host", "")).strip()
    port = _int(robot.get("port"))
    if host and 0 < port <= 65535:
        return _check("robot_udp", "good", "Robot UDP target", f"{host}:{port} configured")
    return _check("robot_udp", "bad", "Robot UDP target", f"invalid target {host}:{port}", "Set robot.host and robot.port in /setup.html.")


def _ssh_checks(ssh: dict[str, Any], timeout: float, ssh_probe: bool) -> list[NetCheck]:
    host = str(ssh.get("host", "192.168.123.1"))
    port = _int(ssh.get("port", 22)) or 22
    user = str(ssh.get("user", "robotis"))
    identity = str(ssh.get("identity_file", "")).strip()
    checks = [_tcp_check(host, port, "ssh_port", "Robot SSH TCP", timeout)]
    if identity:
        identity_path = Path(identity.replace("~/", f"{Path.home()}/", 1))
        checks.append(
            _check(
                "ssh_identity",
                "good" if identity_path.is_file() else "warn",
                "SSH identity",
                str(identity_path) if identity_path.is_file() else f"{identity} not found",
                "Copy/generate the robot SSH key or clear identity_file for default auth.",
            )
        )
    else:
        checks.append(_check("ssh_identity", "warn", "SSH identity", "not configured", "Set ssh.identity_file if key auth is required."))
    if ssh_probe:
        checks.append(_ssh_probe(host, user, port, identity, timeout))
    return checks


def _ssh_probe(host: str, user: str, port: int, identity: str, timeout: float) -> NetCheck:
    ssh_bin = shutil.which("ssh") or "/usr/bin/ssh"
    args = [ssh_bin] + ssh_args(
        host,
        user,
        "echo ok",
        identity or None,
        int(max(1.0, timeout)),
        port=port,
    )
    started = time.monotonic()
    try:
        proc = subprocess.run(
            args,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=max(2.0, timeout + 1.0),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return _check("ssh_auth", "warn", "SSH auth probe", exc.__class__.__name__, "Check robot power, network, key, and legacy ssh-rsa compatibility.")
    elapsed = int((time.monotonic() - started) * 1000)
    if proc.returncode == 0 and proc.stdout.strip() == b"ok":
        return _check("ssh_auth", "good", "SSH auth probe", f"ok · {elapsed} ms")
    stderr = proc.stderr.decode("utf-8", "replace").strip().splitlines()
    detail = stderr[-1] if stderr else f"exit {proc.returncode}"
    return _check("ssh_auth", "warn", "SSH auth probe", detail, "Run with the same config after robot SSH key/IP are confirmed.")


def _overall_level(checks: list[NetCheck]) -> str:
    levels = {check.level for check in checks}
    if "bad" in levels:
        return "bad"
    if "warn" in levels:
        return "warn"
    return "good"


def print_human(report: dict[str, Any], strict: bool) -> None:
    print(f"Darwin Switch network check: {str(report['level']).upper()}")
    if strict:
        print("mode: strict")
    print(f"control mode: {report['mode']}")
    print(f"cockpit: {report['base_url']}")
    print("")
    for item in report["checks"]:
        tag = {"good": "OK", "warn": "WARN", "bad": "BAD"}.get(item["level"], item["level"].upper())
        print(f"[{tag}] {item['title']}: {item['detail']}")
        if item.get("fix"):
            print(f"      fix: {item['fix']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only network/SSH/camera readiness checker for Darwin Switch")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="runtime root, used for config fallback")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="agent config path")
    parser.add_argument("--base-url", default="", help="cockpit base URL; default uses gui.port")
    parser.add_argument("--timeout", type=float, default=1.5, help="per-probe timeout in seconds")
    parser.add_argument("--ssh-probe", action="store_true", help="also run read-only 'echo ok' over configured SSH")
    parser.add_argument("--strict", action="store_true", help="exit non-zero on WARN as well as BAD")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    args = parser.parse_args(argv)

    config = load_config(Path(args.config), Path(args.root))
    report = run_network_report(config, args.base_url, max(0.2, float(args.timeout)), args.ssh_probe)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_human(report, args.strict)
    if report["level"] == "bad":
        return 2
    if args.strict and report["level"] != "good":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
