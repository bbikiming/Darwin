from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path("/opt/darwin-switch-agent")
DEFAULT_CONFIG = Path("/etc/darwin-switch-agent/config.json")
KIOSK_BROWSERS = ("firefox", "firefox-esr", "chromium-browser", "chromium", "google-chrome")
REQUIRED_BUNDLE_FILES = (
    "README.md",
    "config.example.json",
    "install.sh",
    "uninstall.sh",
    "bin/darwin-switch-cockpit",
    "bin/darwin-switch-native-cockpit",
    "bin/darwin-switch-camera-tunnel",
    "bin/darwin-switch-bootstrap-os",
    "bin/darwin-switch-collect-diagnostics",
    "bin/darwin-switch-day0-acceptance",
    "bin/darwin-switch-input-check",
    "bin/darwin-switch-network-check",
    "bin/darwin-switch-native-acceptance",
    "bin/darwin-switch-preflight",
    "bin/darwin-switch-robot-ready",
    "bin/darwin-switch-smoke-test",
    "bin/darwin-switch-onepass-install",
    "src/darwin_switch_agent/main.py",
    "src/darwin_switch_agent/cockpit.py",
    "src/darwin_switch_agent/native_cockpit.py",
    "src/darwin_switch_agent/native_acceptance.py",
    "systemd/darwin-switch-agent.service",
    "systemd/darwin-switch-camera-tunnel.service",
    "desktop/darwin-switch-cockpit.desktop",
    "desktop/darwin-switch.desktop",
    "desktop/darwin-switch-native.desktop",
    "web/index.html",
    "web/setup.html",
    "web/model-check.html",
    "web/app.js",
    "web/setup.js",
    "web/styles.css",
    "web/sw.js",
    "web/manifest.webmanifest",
    "web/assets/darwin-icon.png",
    "web/assets/darwin.glb",
    "web/vendor/three.module.min.js",
    "web/vendor/GLTFLoader.js",
    "web/vendor/BufferGeometryUtils.js",
)


@dataclass(frozen=True)
class Check:
    id: str
    level: str
    title: str
    detail: str
    fix: str = ""


def run_preinstall_audit(
    root: Path,
    config_path: Path,
    installed: bool = False,
    bundle_only: bool = False,
) -> dict[str, Any]:
    checks: list[Check] = []
    if not bundle_only:
        checks.extend(
            [
                _os_check(),
                _l4t_ubuntu_check(),
                _arch_check(),
                _python_check(),
                _systemd_check(),
                _browser_check(),
                _gtk_runtime_check(),
                _ssh_client_check(),
                _autossh_check(),
            ]
        )
    checks.extend(
        [
            _bundle_check(root),
            _config_check(config_path, root / "config.example.json"),
            _glb_size_check(root),
        ]
    )
    if not bundle_only:
        checks.extend(
            [
                _disk_space_check(root if root.exists() else root.parent),
                _input_nodes_check(),
                _joycond_check(),
            ]
        )
    if installed and not bundle_only:
        checks.extend(
            [
                _installed_file_check(Path("/usr/local/bin/darwin-switch-cockpit"), "cockpit_launcher", "Cockpit launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-native-cockpit"), "native_cockpit_launcher", "Native cockpit launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-camera-tunnel"), "camera_tunnel_launcher", "Camera tunnel launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-bootstrap-os"), "bootstrap_launcher", "OS bootstrap launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-collect-diagnostics"), "diagnostics_launcher", "Diagnostics launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-day0-acceptance"), "acceptance_launcher", "Day-0 acceptance launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-input-check"), "input_check_launcher", "Input check launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-network-check"), "network_check_launcher", "Network check launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-native-acceptance"), "native_acceptance_launcher", "Native acceptance launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-preflight"), "preflight_launcher", "Preflight launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-robot-ready"), "robot_ready_launcher", "Robot SSH ready launcher"),
                _installed_file_check(Path("/usr/local/bin/darwin-switch-smoke-test"), "smoke_test_launcher", "Smoke test launcher"),
                _installed_file_check(Path("/etc/systemd/system/darwin-switch-agent.service"), "agent_unit", "Agent systemd unit"),
                _installed_file_check(Path("/etc/systemd/system/darwin-switch-camera-tunnel.service"), "camera_unit", "Camera tunnel unit"),
                _installed_file_check(Path("/etc/xdg/autostart/darwin-switch-cockpit.desktop"), "autostart", "Desktop autostart"),
                _service_state_check("darwin-switch-agent.service", "agent_service", "Agent service"),
                _service_state_check("darwin-switch-camera-tunnel.service", "camera_service", "Camera tunnel service"),
            ]
        )
    level = _overall_level(checks)
    return {
        "ok": level != "bad",
        "level": level,
        "root": str(root),
        "config": str(config_path),
        "installed": installed,
        "bundle_only": bundle_only,
        "checks": [asdict(check) for check in checks],
    }


def _check(check_id: str, level: str, title: str, detail: str, fix: str = "") -> Check:
    return Check(check_id, level, title, detail, fix)


def _os_check() -> Check:
    if sys.platform != "linux":
        return _check("os", "warn", "OS", f"{sys.platform}에서 실행 중", "Switchroot Ubuntu에서 최종 실행하세요.")
    pretty = _os_release().get("PRETTY_NAME", "Linux")
    return _check("os", "good", "OS", pretty)


def _l4t_ubuntu_check() -> Check:
    if sys.platform != "linux":
        return _check("l4t_ubuntu", "warn", "Switchroot L4T Ubuntu", "현재 OS에서는 판별 생략")
    release = _os_release()
    os_id = release.get("ID", "").lower()
    version = release.get("VERSION_ID", "")
    pretty = release.get("PRETTY_NAME", "Linux")
    l4t_markers = [Path("/etc/nv_tegra_release"), Path("/etc/nv_boot_control.conf")]
    has_l4t_marker = any(path.exists() for path in l4t_markers)
    if os_id == "ubuntu" and version in {"22.04", "24.04"} and has_l4t_marker:
        return _check("l4t_ubuntu", "good", "Switchroot L4T Ubuntu", f"{pretty} · L4T marker 확인")
    if os_id == "ubuntu" and version in {"22.04", "24.04"}:
        return _check(
            "l4t_ubuntu",
            "warn",
            "Switchroot L4T Ubuntu",
            f"{pretty} · L4T marker 미확인",
            "Switch 실기기에서 실행 중인지 확인하세요.",
        )
    if os_id == "ubuntu":
        return _check(
            "l4t_ubuntu",
            "warn",
            "Switchroot L4T Ubuntu",
            f"{pretty}",
            "Switchroot Noble 24.04 또는 Jammy 22.04를 권장합니다.",
        )
    return _check(
        "l4t_ubuntu",
        "warn",
        "Switchroot L4T Ubuntu",
        f"{pretty} · Ubuntu 아님",
        "Switchroot L4T Ubuntu 부팅 후 설치하세요.",
    )


def _arch_check() -> Check:
    machine = platform.machine().lower()
    if machine in {"aarch64", "arm64"}:
        return _check("arch", "good", "CPU architecture", machine)
    return _check("arch", "warn", "CPU architecture", machine or "unknown", "Switch 실기기는 aarch64여야 합니다.")


def _python_check() -> Check:
    version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    if sys.version_info >= (3, 9):
        return _check("python", "good", "Python", version)
    return _check("python", "bad", "Python", version, "sudo apt-get install python3")


def _systemd_check() -> Check:
    if not shutil.which("systemctl"):
        return _check("systemd", "bad", "systemd", "systemctl 없음", "Switchroot Ubuntu에서 systemd가 정상인지 확인하세요.")
    if sys.platform == "linux" and not Path("/run/systemd/system").exists():
        return _check("systemd", "warn", "systemd", "systemctl은 있으나 systemd 부팅 환경이 아닐 수 있음")
    return _check("systemd", "good", "systemd", "systemctl 사용 가능")


def _browser_check() -> Check:
    for name in KIOSK_BROWSERS:
        path = shutil.which(name)
        if path:
            return _check("browser", "good", "Kiosk browser", f"{name} ({path})")
    if shutil.which("xdg-open"):
        return _check(
            "browser",
            "warn",
            "Kiosk browser",
            "xdg-open만 있음",
            "sudo apt-get install chromium-browser 또는 firefox",
        )
    return _check("browser", "bad", "Kiosk browser", "브라우저 없음", "sudo apt-get install chromium-browser 또는 firefox")


def _gtk_runtime_check() -> Check:
    try:
        import gi  # type: ignore

        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk  # noqa: F401  # type: ignore
    except (ImportError, ValueError) as exc:
        return _check(
            "gtk_runtime",
            "warn",
            "GTK native runtime",
            exc.__class__.__name__,
            "sudo apt-get install python3-gi gir1.2-gtk-3.0",
        )
    return _check("gtk_runtime", "good", "GTK native runtime", "python3-gi + GTK 3 사용 가능")


def _ssh_client_check() -> Check:
    if shutil.which("ssh"):
        return _check("ssh_client", "good", "SSH client", "ssh 사용 가능")
    return _check("ssh_client", "bad", "SSH client", "ssh 없음", "sudo apt-get install openssh-client")


def _autossh_check() -> Check:
    if shutil.which("autossh"):
        return _check("autossh", "good", "Camera tunnel reconnect", "autossh 사용 가능")
    return _check("autossh", "warn", "Camera tunnel reconnect", "autossh 없음", "sudo apt-get install autossh")


def _bundle_check(root: Path) -> Check:
    missing = [rel for rel in REQUIRED_BUNDLE_FILES if not (root / rel).is_file()]
    if not missing:
        return _check("bundle", "good", "Runtime bundle", f"{len(REQUIRED_BUNDLE_FILES)}개 필수 파일 확인")
    shown = ", ".join(missing[:5])
    suffix = "" if len(missing) <= 5 else f" 외 {len(missing) - 5}개"
    return _check("bundle", "bad", "Runtime bundle", f"누락: {shown}{suffix}", "패키지를 다시 풀거나 package.sh를 재실행하세요.")


def _config_check(config_path: Path, example_path: Path) -> Check:
    path = config_path if config_path.is_file() else example_path
    if not path.is_file():
        return _check("config", "bad", "Config", f"{config_path} 및 example 없음")
    try:
        with path.open("r", encoding="utf-8") as fp:
            config = json.load(fp)
    except (OSError, json.JSONDecodeError) as exc:
        return _check("config", "bad", "Config", f"{path} 읽기 실패: {exc}")
    if not isinstance(config, dict):
        return _check("config", "bad", "Config", f"{path} 최상위가 object가 아님")
    mode = str(config.get("mode", ""))
    if mode not in {"dry_run", "mac_relay", "robot_udp", "ssh"}:
        return _check("config", "bad", "Config", f"지원하지 않는 mode={mode!r}")
    source = "example" if path == example_path or path.name == "config.example.json" else "installed"
    return _check("config", "good", "Config", f"{source} config OK · mode={mode}")


def _glb_size_check(root: Path) -> Check:
    glb = root / "web/assets/darwin.glb"
    if not glb.is_file():
        return _check("darwin_glb", "bad", "DARwIn GLB", "web/assets/darwin.glb 없음")
    size_mb = glb.stat().st_size / (1024 * 1024)
    if size_mb <= 4.0:
        return _check("darwin_glb", "good", "DARwIn GLB", f"{size_mb:.2f} MB")
    return _check("darwin_glb", "warn", "DARwIn GLB", f"{size_mb:.2f} MB", "Switch에서 model-check.html을 먼저 실행하세요.")


def _disk_space_check(path: Path) -> Check:
    target = path if path.exists() else Path("/")
    try:
        usage = shutil.disk_usage(target)
    except OSError as exc:
        return _check("disk", "warn", "Disk space", f"확인 실패: {exc}")
    free_mb = usage.free / (1024 * 1024)
    if free_mb >= 512:
        return _check("disk", "good", "Disk space", f"{free_mb:.0f} MB free")
    return _check("disk", "warn", "Disk space", f"{free_mb:.0f} MB free", "최소 512MB 이상 여유 공간을 확보하세요.")


def _input_nodes_check() -> Check:
    input_dir = Path("/dev/input")
    if not input_dir.exists():
        return _check("input_nodes", "warn", "Input nodes", "/dev/input 없음", "Joy-Con 페어링 후 다시 확인하세요.")
    events = sorted(input_dir.glob("event*"))
    if not events:
        return _check("input_nodes", "warn", "Input nodes", "event 장치 없음", "Joy-Con 페어링 후 다시 확인하세요.")
    readable = [path for path in events if os.access(path, os.R_OK)]
    if readable:
        return _check("input_nodes", "good", "Input nodes", f"{len(readable)}/{len(events)} event 장치 읽기 가능")
    return _check("input_nodes", "warn", "Input nodes", f"{len(events)}개 발견, 읽기 권한 없음", "sudo 또는 input group 권한을 확인하세요.")


def _joycond_check() -> Check:
    code, active = _systemctl("is-active", "joycond.service")
    if code == 0:
        return _check("joycond", "good", "Joy-Con merge", active or "active")
    code_enabled, enabled = _systemctl("is-enabled", "joycond.service")
    if code_enabled == 0:
        return _check("joycond", "warn", "Joy-Con merge", f"{enabled or 'enabled'} · 실행 필요", "sudo systemctl enable --now joycond")
    if code == 127:
        return _check("joycond", "warn", "Joy-Con merge", "systemd 확인 불가")
    return _check("joycond", "warn", "Joy-Con merge", "joycond 미설치 가능성", "L4T Megascript 또는 apt로 joycond를 설치하세요.")


def _installed_file_check(path: Path, check_id: str, title: str) -> Check:
    if path.is_file():
        return _check(check_id, "good", title, str(path))
    return _check(check_id, "bad", title, f"{path} 없음", "sudo ./install.sh를 다시 실행하세요.")


def _service_state_check(unit: str, check_id: str, title: str) -> Check:
    code, active = _systemctl("is-active", unit)
    if code == 0:
        return _check(check_id, "good", title, active or "active")
    code_enabled, enabled = _systemctl("is-enabled", unit)
    if code_enabled == 0:
        return _check(check_id, "warn", title, f"{enabled or 'enabled'} · 실행 중 아님", f"sudo systemctl restart {unit}")
    if code == 127:
        return _check(check_id, "warn", title, "systemd 확인 불가")
    return _check(check_id, "warn", title, "미실행/미등록", f"sudo systemctl enable --now {unit}")


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
            timeout=1.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return 126, ""
    return proc.returncode, proc.stdout.strip()


def _os_release() -> dict[str, str]:
    path = Path("/etc/os-release")
    if not path.is_file():
        return {}
    data: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" not in line or line.startswith("#"):
                continue
            key, value = line.split("=", 1)
            data[key] = value.strip().strip('"')
    except OSError:
        return {}
    return data


def _overall_level(checks: list[Check]) -> str:
    levels = {check.level for check in checks}
    if "bad" in levels:
        return "bad"
    if "warn" in levels:
        return "warn"
    return "good"


def _print_human(result: dict[str, Any]) -> None:
    level = str(result["level"]).upper()
    print(f"Darwin Switch preflight: {level}")
    print(f"root: {result['root']}")
    print(f"config: {result['config']}")
    print("")
    for check in result["checks"]:
        marker = {"good": "OK", "warn": "WARN", "bad": "BAD"}.get(check["level"], check["level"].upper())
        line = f"[{marker}] {check['title']}: {check['detail']}"
        print(line)
        if check.get("fix"):
            print(f"      fix: {check['fix']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Darwin Switch install/readiness preflight")
    parser.add_argument("--root", default=str(_default_root()), help="runtime bundle root")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="config.json path")
    parser.add_argument("--installed", action="store_true", help="also check installed launchers/systemd units")
    parser.add_argument("--bundle-only", action="store_true", help="check only package files/config/model, safe on Mac before transfer")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--strict", action="store_true", help="return non-zero for warn/bad")
    args = parser.parse_args(argv)

    result = run_preinstall_audit(
        Path(args.root),
        Path(args.config),
        installed=args.installed,
        bundle_only=args.bundle_only,
    )
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        _print_human(result)
    if result["level"] == "bad":
        return 2
    if args.strict and result["level"] == "warn":
        return 1
    return 0


def _default_root() -> Path:
    module_root = Path(__file__).resolve().parents[2]
    if module_root.exists():
        return module_root
    return DEFAULT_ROOT


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
