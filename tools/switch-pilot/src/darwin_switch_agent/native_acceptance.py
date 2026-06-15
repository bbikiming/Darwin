from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.error import URLError
from urllib.request import urlopen

from .config import AgentConfig


DEFAULT_CONFIG = Path("/etc/darwin-switch-agent/config.json")


@dataclass(frozen=True)
class NativeCheck:
    id: str
    level: str
    title: str
    detail: str
    fix: str = ""


def _check(check_id: str, level: str, title: str, detail: str, fix: str = "") -> NativeCheck:
    return NativeCheck(check_id, level, title, detail, fix)


def run_native_acceptance(
    config_path: Path = DEFAULT_CONFIG,
    base_url: str = "http://127.0.0.1:8765",
    timeout: float = 1.5,
    sample_seconds: float = 0.0,
    sample_interval: float = 0.25,
) -> dict[str, Any]:
    checks: list[NativeCheck] = [
        _gtk_check(),
        _launcher_check(),
    ]

    config = _load_config(config_path)
    if config is None:
        checks.append(_check("config", "bad", "Agent config", f"{config_path} 읽기 실패", "설치를 다시 실행하거나 config 경로를 확인하세요."))
    else:
        checks.extend(_config_checks(config))

    state_payload = _http_json(f"{base_url.rstrip('/')}/api/state", timeout)
    checks.append(_state_check(state_payload))
    if state_payload.get("ok"):
        checks.extend(_state_detail_checks(state_payload.get("json", {})))

    command_payload = _http_json(f"{base_url.rstrip('/')}/api/robot-command", timeout)
    checks.append(_robot_command_check(command_payload))
    if command_payload.get("ok"):
        checks.extend(_robot_command_detail_checks(command_payload.get("json", {})))

    samples: list[dict[str, Any]] = []
    if sample_seconds > 0:
        samples = _sample_runtime(base_url, timeout, sample_seconds, sample_interval)
        checks.extend(_sample_checks(samples))

    level = _overall_level(checks)
    return {
        "ok": level != "bad",
        "level": level,
        "config": str(config_path),
        "base_url": base_url,
        "sample_seconds": sample_seconds,
        "sample_count": len(samples),
        "sample_summary": _sample_summary(samples) if samples else {},
        "checks": [asdict(check) for check in checks],
    }


def _load_config(config_path: Path) -> AgentConfig | None:
    try:
        return AgentConfig.load(str(config_path))
    except (OSError, json.JSONDecodeError, ValueError):
        return None


def _gtk_check() -> NativeCheck:
    try:
        import gi  # type: ignore

        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk  # noqa: F401  # type: ignore
    except (ImportError, ValueError) as exc:
        return _check(
            "gtk",
            "warn",
            "GTK native runtime",
            exc.__class__.__name__,
            "sudo apt-get install python3-gi gir1.2-gtk-3.0",
        )
    return _check("gtk", "good", "GTK native runtime", "python3-gi + GTK 3 사용 가능")


def _launcher_check() -> NativeCheck:
    path = shutil.which("darwin-switch-native-cockpit")
    if path:
        return _check("native_launcher", "good", "Native launcher", path)
    return _check(
        "native_launcher",
        "warn",
        "Native launcher",
        "PATH에서 darwin-switch-native-cockpit 없음",
        "sudo ./install.sh를 다시 실행하세요.",
    )


def _config_checks(config: AgentConfig) -> list[NativeCheck]:
    raw = config.raw
    checks: list[NativeCheck] = []
    mode = str(raw.get("mode", ""))
    checks.append(
        _check(
            "mode",
            "good" if mode == "ssh" else "warn",
            "Control mode",
            mode or "unset",
            "로봇 직결 조종은 darwin-switch-robot-ready enable-agent-ssh 후 mode=ssh여야 합니다.",
        )
    )

    ssh = config.section("ssh")
    identity = str(ssh.get("identity_file", "")).strip()
    identity_path = Path(identity)
    checks.append(
        _check(
            "ssh_identity_absolute",
            "good" if identity_path.is_absolute() else "bad",
            "SSH identity path",
            identity or "unset",
            "systemd/root 실행에서는 ~가 /root로 풀립니다. /home/yuseok/.ssh/id_rsa_darwin 처럼 절대경로를 쓰세요.",
        )
    )
    if identity_path.is_absolute():
        checks.append(
            _check(
                "ssh_identity_exists",
                "good" if identity_path.is_file() else "bad",
                "SSH identity file",
                str(identity_path),
                "Switch 사용자 홈의 키를 해당 절대경로에 두거나 config를 수정하세요.",
            )
        )

    motion = config.section("motion")
    required_motion = {
        "max_stride_mm",
        "max_side_mm",
        "max_turn_deg",
        "max_head_pan_deg",
        "max_head_tilt_deg",
        "turn_from_side_ratio",
        "hold_head_position",
        "drive_curve",
    }
    missing = sorted(key for key in required_motion if key not in motion)
    checks.append(
        _check(
            "motion_mapping",
            "good" if not missing else "warn",
            "Motion mapping",
            "side/head-hold 설정 확인" if not missing else "누락: " + ", ".join(missing),
            "신규 패키지를 배포하고 setup 또는 튜닝 프리셋을 다시 적용하세요.",
        )
    )
    if "hold_head_position" in motion:
        checks.append(
            _check(
                "head_hold",
                "good" if bool(motion.get("hold_head_position")) else "warn",
                "Head hold",
                str(bool(motion.get("hold_head_position"))),
                "머리 위치 유지가 필요하면 motion.hold_head_position=true로 설정하세요.",
            )
        )
    return checks


def _http_json(url: str, timeout: float) -> dict[str, Any]:
    try:
        with urlopen(url, timeout=timeout) as fp:
            data = fp.read(64 * 1024)
        return {"ok": True, "json": json.loads(data.decode("utf-8"))}
    except (OSError, URLError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": exc.__class__.__name__}


def _state_check(payload: dict[str, Any]) -> NativeCheck:
    if payload.get("ok"):
        return _check("state_api", "good", "Cockpit state API", "HTTP JSON OK")
    return _check("state_api", "bad", "Cockpit state API", str(payload.get("error", "failed")), "darwin-switch-agent 서비스를 확인하세요.")


def _state_detail_checks(state: dict[str, Any]) -> list[NativeCheck]:
    input_status = str(state.get("input_status", ""))
    mode = str(state.get("mode", ""))
    target = str(state.get("target", ""))
    ssh_connected = bool(state.get("ssh_connected", False))
    connected = bool(state.get("connected", False))
    command = state.get("command") if isinstance(state.get("command"), dict) else {}
    checks = [
        _check(
            "state_mode",
            "good" if mode == "ssh" else "warn",
            "Runtime mode",
            mode or "unset",
            "로봇 조종 테스트 전 mode=ssh인지 확인하세요.",
        ),
        _check(
            "state_target",
            "good" if target.startswith("robotis@") else "warn",
            "Runtime target",
            target or "unset",
            "target이 robotis@로봇IP 형태인지 확인하세요.",
        ),
        _check(
            "state_connection",
            "good" if connected and ssh_connected else "warn",
            "Runtime SSH connection",
            f"connected={connected}, ssh_connected={ssh_connected}",
            "로봇 전원/Wi-Fi/SSH key/auth 상태를 확인하세요.",
        ),
        _check(
            "state_input",
            "good" if input_status.startswith("/dev/input/event") else "warn",
            "Runtime input device",
            input_status or "unset",
            "joycond 결합 장치 또는 USB 게임패드가 잡혔는지 확인하세요.",
        ),
        _check(
            "state_side_command",
            "good" if "side_mm" in command else "warn",
            "Runtime side command",
            f"side_mm={command.get('side_mm', 'missing')}",
            "신규 agent가 실행 중인지 재배포 후 sudo systemctl restart darwin-switch-agent 하세요.",
        ),
    ]
    return checks


def _robot_command_check(payload: dict[str, Any]) -> NativeCheck:
    if not payload.get("ok"):
        return _check(
            "robot_command_api",
            "warn",
            "Robot command file API",
            str(payload.get("error", "failed")),
            "로봇 SSH 연결 후 다시 실행하세요. 이 체크는 읽기 전용입니다.",
        )
    body = payload.get("json", {})
    if bool(body.get("ok")):
        return _check("robot_command_api", "good", "Robot command file API", "로봇 측 명령 파일 읽기 가능")
    return _check("robot_command_api", "warn", "Robot command file API", str(body.get("error", "not ok")), "로봇 SSH/WalkLab 상태를 확인하세요.")


def _robot_command_detail_checks(body: dict[str, Any]) -> list[NativeCheck]:
    status = body.get("status") if isinstance(body.get("status"), dict) else {}
    parsed = _parsed_command(status)
    raw = str(status.get("raw", status.get("raw_command", "")) or "")
    mode = str(status.get("mode", "") or "")
    estop = bool(status.get("estop", status.get("estop_present", False)))
    checks = [
        _check(
            "robot_walklab_mode",
            "good" if mode == "walklab" else "warn",
            "Robot pilot mode",
            mode or "unset",
            "로봇에서 DarwinForge WalkLab/demo가 조종 파일을 읽는 상태인지 확인하세요.",
        ),
        _check(
            "robot_estop_file",
            "good" if not estop else "warn",
            "Robot estop file",
            "present" if estop else "absent",
            "비상정지 파일이 남아 있으면 해제/복구 후 다시 테스트하세요.",
        ),
        _check(
            "robot_command_parse",
            "good" if parsed else "warn",
            "Robot command parse",
            _command_summary(parsed) if parsed else (raw[:80] or "empty"),
            "스틱을 움직이며 다시 실행하세요. 14-token walklab command 형식이어야 합니다.",
        ),
    ]
    if parsed:
        checks.append(
            _check(
                "robot_side_token",
                "good" if "side_mm" in parsed else "bad",
                "Robot side token",
                f"side_mm={parsed.get('side_mm', 'missing')}",
                "구버전 agent/robot_ready가 side 토큰을 쓰지 않는 상태입니다. 재배포가 필요합니다.",
            )
        )
        checks.append(
            _check(
                "robot_head_tokens",
                "good" if "head_pan_deg" in parsed and "head_tilt_deg" in parsed else "warn",
                "Robot head tokens",
                f"pan={parsed.get('head_pan_deg', 'missing')}, tilt={parsed.get('head_tilt_deg', 'missing')}",
                "머리 유지 동작은 right stick 입력 후 값이 0으로 돌아가지 않는지 확인하세요.",
            )
        )
    return checks


def _sample_runtime(base_url: str, timeout: float, sample_seconds: float, sample_interval: float) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    interval = max(0.1, sample_interval)
    count = max(1, int(round(max(0.0, sample_seconds) / interval)))
    for index in range(count):
        state_payload = _http_json(f"{base_url.rstrip('/')}/api/state", timeout)
        command_payload = _http_json(f"{base_url.rstrip('/')}/api/robot-command", timeout)
        state = state_payload.get("json", {}) if state_payload.get("ok") else {}
        command_body = command_payload.get("json", {}) if command_payload.get("ok") else {}
        status = command_body.get("status", {}) if isinstance(command_body.get("status"), dict) else {}
        parsed = _parsed_command(status)
        state_command = state.get("command", {}) if isinstance(state.get("command"), dict) else {}
        controller = state.get("controller", {}) if isinstance(state.get("controller"), dict) else {}
        out.append(
            {
                "state_ok": bool(state_payload.get("ok")),
                "robot_ok": bool(command_body.get("ok", False)),
                "connected": bool(state.get("connected", False)),
                "ssh_connected": bool(state.get("ssh_connected", False)),
                "armed": bool(state.get("armed", False)),
                "deadman": bool(state.get("deadman", False)),
                "moving": bool(state.get("moving", False)),
                "state_stride_mm": _optional_float(state_command.get("stride_mm")),
                "state_side_mm": _optional_float(state_command.get("side_mm")),
                "state_turn_deg": _optional_float(state_command.get("turn_deg")),
                "state_head_pan_deg": _optional_float(state_command.get("head_pan_deg")),
                "state_head_tilt_deg": _optional_float(state_command.get("head_tilt_deg")),
                "right_x": _optional_float(controller.get("right_x")),
                "right_y": _optional_float(controller.get("right_y")),
                "robot_stride_mm": _optional_float(parsed.get("stride_mm")),
                "robot_side_mm": _optional_float(parsed.get("side_mm")),
                "robot_turn_deg": _optional_float(parsed.get("turn_deg")),
                "robot_period_ms": _optional_float(parsed.get("period_ms")),
                "robot_foot_mm": _optional_float(parsed.get("foot_mm")),
                "robot_head_pan_deg": _optional_float(parsed.get("head_pan_deg")),
                "robot_head_tilt_deg": _optional_float(parsed.get("head_tilt_deg")),
            }
        )
        if index < count - 1:
            time.sleep(interval)
    return out


def _parsed_command(status: dict[str, Any]) -> dict[str, Any]:
    parsed = status.get("parsed") if isinstance(status.get("parsed"), dict) else {}
    if parsed:
        return parsed
    parsed_command = status.get("parsed_command") if isinstance(status.get("parsed_command"), dict) else {}
    return parsed_command


def _sample_checks(samples: list[dict[str, Any]]) -> list[NativeCheck]:
    if not samples:
        return [_check("sample_capture", "warn", "Runtime sample", "샘플 없음", "--sample-seconds 값을 늘려 다시 실행하세요.")]
    summary = _sample_summary(samples)
    checks = [
        _check(
            "sample_capture",
            "good" if len(samples) >= 2 else "warn",
            "Runtime sample",
            f"{len(samples)} samples",
            "5초 이상 실행하고 그동안 조이콘을 움직이세요.",
        ),
        _check(
            "sample_robot_connection",
            "good" if summary["robot_ok_count"] > 0 and summary["ssh_connected_count"] > 0 else "warn",
            "Sample robot connection",
            f"robot_ok={summary['robot_ok_count']}, ssh_connected={summary['ssh_connected_count']}",
            "로봇 SSH 연결이 유지되는지 확인하세요.",
        ),
        _check(
            "sample_stride_variation",
            "good" if summary["robot_stride_span"] >= 2.0 else "warn",
            "Sample stride variation",
            f"robot={summary['robot_stride_span']:.2f} mm, state={summary['state_stride_span']:.2f} mm",
            "실행 중 왼쪽 스틱을 전후로 움직여 다시 측정하세요.",
        ),
        _check(
            "sample_side_variation",
            "good" if summary["robot_side_span"] >= 2.0 else "warn",
            "Sample side variation",
            f"robot={summary['robot_side_span']:.2f} mm, state={summary['state_side_span']:.2f} mm",
            "실행 중 왼쪽 스틱을 좌우로 움직여 다시 측정하세요.",
        ),
        _check(
            "sample_agent_mapping",
            "good" if summary["state_drive_span"] >= 2.0 else "warn",
            "Sample Joy-Con to agent mapping",
            f"state_drive_span={summary['state_drive_span']:.2f}",
            "UI 숫자도 변하지 않으면 조이콘 입력/권한/A/ZL-ZR 상태부터 확인하세요.",
        ),
        _check(
            "sample_robot_file_propagation",
            "good" if _propagation_ok(summary) else "warn",
            "Sample agent to robot file propagation",
            (
                f"state_drive={summary['state_drive_span']:.2f}, "
                f"robot_drive={summary['robot_drive_span']:.2f}"
            ),
            "UI 숫자는 변하는데 robot_drive가 작으면 SSH write, 권한, WalkLab 파일 경로를 확인하세요.",
        ),
        _check(
            "sample_gait_variation",
            "good" if summary["robot_period_span"] >= 20.0 or summary["robot_foot_span"] >= 3.0 else "warn",
            "Sample gait variation",
            f"period_span={summary['robot_period_span']:.0f} ms, foot_span={summary['robot_foot_span']:.1f} mm",
            "스틱을 약하게/강하게 움직여도 값이 고정이면 agent가 구버전이거나 robot_ready 설정이 고정입니다.",
        ),
        _check(
            "sample_head_hold",
            "good" if summary["robot_head_hold_count"] > 0 else "warn",
            "Sample head hold",
            (
                f"hold_frames={summary['robot_head_hold_count']}, "
                f"nonzero={summary['robot_head_nonzero_count']}"
            ),
            "오른쪽 스틱으로 머리를 움직인 뒤 놓은 상태가 측정에 포함되도록 다시 실행하세요.",
        ),
    ]
    return checks


def _sample_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    state_stride_span = _span(item.get("state_stride_mm") for item in samples)
    state_side_span = _span(item.get("state_side_mm") for item in samples)
    state_turn_span = _span(item.get("state_turn_deg") for item in samples)
    robot_stride_span = _span(item.get("robot_stride_mm") for item in samples)
    robot_side_span = _span(item.get("robot_side_mm") for item in samples)
    robot_turn_span = _span(item.get("robot_turn_deg") for item in samples)
    return {
        "robot_ok_count": sum(1 for item in samples if item.get("robot_ok")),
        "ssh_connected_count": sum(1 for item in samples if item.get("ssh_connected")),
        "moving_count": sum(1 for item in samples if item.get("moving")),
        "state_stride_span": state_stride_span,
        "state_side_span": state_side_span,
        "state_turn_span": state_turn_span,
        "state_drive_span": max(state_stride_span, state_side_span, state_turn_span),
        "robot_stride_span": robot_stride_span,
        "robot_side_span": robot_side_span,
        "robot_turn_span": robot_turn_span,
        "robot_drive_span": max(robot_stride_span, robot_side_span, robot_turn_span),
        "robot_period_span": _span(item.get("robot_period_ms") for item in samples),
        "robot_foot_span": _span(item.get("robot_foot_mm") for item in samples),
        "robot_head_pan_span": _span(item.get("robot_head_pan_deg") for item in samples),
        "robot_head_tilt_span": _span(item.get("robot_head_tilt_deg") for item in samples),
        "robot_head_nonzero_count": sum(
            1
            for item in samples
            if abs(float(item.get("robot_head_pan_deg") or 0.0)) >= 1.0
            or abs(float(item.get("robot_head_tilt_deg") or 0.0)) >= 1.0
        ),
        "robot_head_hold_count": sum(
            1
            for item in samples
            if abs(float(item.get("right_x") or 0.0)) < 0.08
            and abs(float(item.get("right_y") or 0.0)) < 0.08
            and (
                abs(float(item.get("robot_head_pan_deg") or 0.0)) >= 1.0
                or abs(float(item.get("robot_head_tilt_deg") or 0.0)) >= 1.0
            )
        ),
    }


def _propagation_ok(summary: dict[str, Any]) -> bool:
    state_drive = float(summary.get("state_drive_span") or 0.0)
    robot_drive = float(summary.get("robot_drive_span") or 0.0)
    if state_drive < 2.0:
        return False
    return robot_drive >= max(1.5, state_drive * 0.45)


def _optional_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _span(values: Any) -> float:
    nums = [float(value) for value in values if value is not None]
    if not nums:
        return 0.0
    return max(nums) - min(nums)


def _command_summary(parsed: dict[str, Any]) -> str:
    return (
        f"enabled={parsed.get('enabled')} "
        f"stride={parsed.get('stride_mm')} "
        f"side={parsed.get('side_mm')} "
        f"turn={parsed.get('turn_deg')} "
        f"period={parsed.get('period_ms')} "
        f"foot={parsed.get('foot_mm')} "
        f"head=({parsed.get('head_pan_deg')},{parsed.get('head_tilt_deg')})"
    )


def _overall_level(checks: list[NativeCheck]) -> str:
    levels = {check.level for check in checks}
    if "bad" in levels:
        return "bad"
    if "warn" in levels:
        return "warn"
    return "good"


def print_human(report: dict[str, Any], strict: bool) -> None:
    print(f"Darwin Switch native acceptance: {str(report['level']).upper()}")
    if strict:
        print("mode: strict")
    print(f"config: {report['config']}")
    print(f"cockpit: {report['base_url']}")
    if report.get("sample_count"):
        summary = report.get("sample_summary", {})
        print(
            "sample: "
            f"{report['sample_count']} frames · "
            f"stride_span={float(summary.get('robot_stride_span', 0)):.2f} · "
            f"side_span={float(summary.get('robot_side_span', 0)):.2f} · "
            f"period_span={float(summary.get('robot_period_span', 0)):.0f}"
        )
    print("")
    for item in report["checks"]:
        tag = {"good": "OK", "warn": "WARN", "bad": "BAD"}.get(item["level"], item["level"].upper())
        print(f"[{tag}] {item['title']}: {item['detail']}")
        if item.get("fix"):
            print(f"      fix: {item['fix']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only native cockpit and robot command acceptance checker")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="agent config path")
    parser.add_argument("--base-url", default="http://127.0.0.1:8765", help="local cockpit base URL")
    parser.add_argument("--timeout", type=float, default=1.5, help="HTTP timeout seconds")
    parser.add_argument("--sample-seconds", type=float, default=0.0, help="sample live command changes while you move Joy-Cons")
    parser.add_argument("--sample-interval", type=float, default=0.25, help="sample interval seconds")
    parser.add_argument("--json", action="store_true", help="print JSON report")
    parser.add_argument("--strict", action="store_true", help="exit 1 on WARN")
    args = parser.parse_args(argv)

    report = run_native_acceptance(Path(args.config), args.base_url, args.timeout, args.sample_seconds, args.sample_interval)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_human(report, args.strict)
    if report["level"] == "bad":
        return 2
    if report["level"] == "warn" and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
