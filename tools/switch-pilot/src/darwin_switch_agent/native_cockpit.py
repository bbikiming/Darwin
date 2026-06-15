"""GTK-native Darwin Switch cockpit.

This is a Linux desktop frontend for the already-verified Switch agent control
path. It intentionally does not reimplement robot control; it talks to the
local agent HTTP API so Joy-Con input, SSH safety gates, and WalkLab file writes
stay in one tested service.
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_URL = "http://127.0.0.1:8765"
APP_CSS = """
window {
  background: #f6f8fb;
  color: #172033;
  font: 13px "Ubuntu", "Noto Sans CJK KR", sans-serif;
}
frame {
  border: 1px solid #d7dee9;
  border-radius: 10px;
  background: #ffffff;
  box-shadow: none;
}
frame > label {
  color: #40506b;
  font-weight: 700;
}
button {
  min-height: 42px;
  border-radius: 9px;
  font-weight: 700;
}
.badge {
  padding: 7px 12px;
  border: 1px solid #d7dee9;
  border-radius: 999px;
  background: #ffffff;
  color: #40506b;
  font-weight: 700;
}
.badge-ok {
  color: #137a3a;
  border-color: #9bd7ad;
  background: #eefaf1;
}
.badge-warn {
  color: #9a5b00;
  border-color: #f2ce87;
  background: #fff8e8;
}
.badge-bad {
  color: #b4232c;
  border-color: #f0a0a6;
  background: #fff0f2;
}
.value-large {
  font-size: 34px;
  font-weight: 800;
}
.monospace {
  font-family: "Ubuntu Mono", "DejaVu Sans Mono", monospace;
}
.statusbar {
  padding: 8px 10px;
  border-radius: 8px;
  background: #edf2f7;
  color: #26354f;
}
levelbar block.filled {
  background: #2166f3;
}
levelbar.warning block.filled {
  background: #f59e0b;
}
levelbar.danger block.filled {
  background: #ef4444;
}
"""
SAFE_TUNING_PRESET: dict[str, Any] = {
    "motion": {
        "max_stride_mm": 24,
        "max_side_mm": 12,
        "max_turn_deg": 9,
        "turn_from_side_ratio": 0.55,
        "max_head_pan_deg": 50,
        "max_head_tilt_deg": 24,
        "hold_head_position": True,
        "drive_curve": 1.5,
        "speed_scale": 0.6,
    },
    "ssh": {
        "send_hz": 4,
        "telemetry_hz": 0.5,
        "heartbeat_ms": 1200,
        "timeout_seconds": 8,
        "connect_timeout_seconds": 3,
        "min_period_ms": 520,
        "max_period_ms": 840,
        "min_foot_mm": 18,
        "stride_ref_mm": 38,
        "turn_ref_deg": 14,
    },
}

RESPONSIVE_TUNING_PRESET: dict[str, Any] = {
    "motion": {
        "max_stride_mm": 38,
        "max_side_mm": 22,
        "max_turn_deg": 14,
        "turn_from_side_ratio": 0.75,
        "max_head_pan_deg": 70,
        "max_head_tilt_deg": 35,
        "hold_head_position": True,
        "drive_curve": 1.35,
        "speed_scale": 0.8,
    },
    "ssh": {
        "send_hz": 5,
        "telemetry_hz": 1,
        "heartbeat_ms": 900,
        "timeout_seconds": 8,
        "connect_timeout_seconds": 3,
        "min_period_ms": 500,
        "max_period_ms": 860,
        "min_foot_mm": 16,
        "stride_ref_mm": 38,
        "turn_ref_deg": 14,
    },
}


@dataclass(frozen=True)
class NativeState:
    mode: str
    target: str
    connected: bool
    ssh_connected: bool
    input_status: str
    armed: bool
    deadman: bool
    estopped: bool
    moving: bool
    stride_mm: float
    side_mm: float
    turn_deg: float
    head_pan_deg: float
    head_tilt_deg: float
    left_x: float
    left_y: float
    right_x: float
    right_y: float
    latency_ms: int | None
    battery_pct: int | None
    watchdog_label: str
    logs: list[str]

    @property
    def link_ok(self) -> bool:
        return self.ssh_connected if self.mode == "ssh" else self.connected

    @property
    def drive_speed_pct(self) -> int:
        speed = (
            (self.stride_mm / RESPONSIVE_TUNING_PRESET["motion"]["max_stride_mm"]) ** 2
            + (self.side_mm / RESPONSIVE_TUNING_PRESET["motion"]["max_side_mm"]) ** 2
            + (self.turn_deg / RESPONSIVE_TUNING_PRESET["motion"]["max_turn_deg"]) ** 2
        ) ** 0.5
        return int(max(0, min(100, round(speed * 100))))

    @property
    def direction_label(self) -> str:
        if abs(self.stride_mm) < 0.2 and abs(self.side_mm) < 0.2:
            return "정지"
        fb = "" if abs(self.stride_mm) < 0.8 else ("전진" if self.stride_mm > 0 else "후진")
        lr = "" if abs(self.side_mm) < 0.8 else ("우측" if self.side_mm > 0 else "좌측")
        return "·".join(part for part in (fb, lr) if part)


def state_from_payload(data: dict[str, Any]) -> NativeState:
    command = data.get("command") if isinstance(data.get("command"), dict) else {}
    controller = data.get("controller") if isinstance(data.get("controller"), dict) else {}
    return NativeState(
        mode=str(data.get("mode", "-")),
        target=str(data.get("target", "-")),
        connected=bool(data.get("connected", False)),
        ssh_connected=bool(data.get("ssh_connected", False)),
        input_status=str(data.get("input_status", "입력장치 없음")),
        armed=bool(data.get("armed", False)),
        deadman=bool(data.get("deadman", False)),
        estopped=bool(data.get("estopped", False)),
        moving=bool(data.get("moving", False)),
        stride_mm=float(command.get("stride_mm", 0) or 0),
        side_mm=float(command.get("side_mm", 0) or 0),
        turn_deg=float(command.get("turn_deg", 0) or 0),
        head_pan_deg=float(command.get("head_pan_deg", 0) or 0),
        head_tilt_deg=float(command.get("head_tilt_deg", 0) or 0),
        left_x=float(controller.get("left_x", 0) or 0),
        left_y=float(controller.get("left_y", 0) or 0),
        right_x=float(controller.get("right_x", 0) or 0),
        right_y=float(controller.get("right_y", 0) or 0),
        latency_ms=_optional_int(data.get("link_latency_ms")),
        battery_pct=_optional_int(data.get("battery_pct")),
        watchdog_label=str(data.get("watchdog_label", "—")),
        logs=[str(item) for item in data.get("logs", [])[:8]] if isinstance(data.get("logs"), list) else [],
    )


def _optional_int(value: Any) -> int | None:
    try:
        return None if value is None else int(value)
    except (TypeError, ValueError):
        return None


@dataclass(frozen=True)
class RobotCommandStatus:
    ok: bool
    mode: str = ""
    estop: bool = False
    mtime: int | None = None
    raw: str = ""
    enabled: bool | None = None
    stride_mm: float | None = None
    side_mm: float | None = None
    turn_deg: float | None = None
    period_ms: float | None = None
    foot_mm: float | None = None
    head_pan_deg: float | None = None
    head_tilt_deg: float | None = None
    error: str = ""

    @property
    def summary(self) -> str:
        if not self.ok:
            return self.error or "확인 불가"
        if self.enabled is None:
            return "명령 미파싱"
        state = "ON" if self.enabled else "OFF"
        stride = self.stride_mm if self.stride_mm is not None else 0.0
        side = self.side_mm if self.side_mm is not None else 0.0
        turn = self.turn_deg if self.turn_deg is not None else 0.0
        period = self.period_ms if self.period_ms is not None else 0.0
        foot = self.foot_mm if self.foot_mm is not None else 0.0
        return (
            f"{state} x={stride:.1f} y={side:.1f} "
            f"a={turn:.1f} p={period:.0f} f={foot:.0f}"
        )

    @property
    def drive_span_value(self) -> float:
        stride = abs(self.stride_mm or 0.0)
        side = abs(self.side_mm or 0.0)
        turn = abs(self.turn_deg or 0.0)
        return max(stride, side, turn)


def command_status_from_payload(data: dict[str, Any]) -> RobotCommandStatus:
    if not data.get("ok"):
        return RobotCommandStatus(ok=False, error=str(data.get("error", "확인 불가")))
    status = data.get("status") if isinstance(data.get("status"), dict) else {}
    parsed = status.get("parsed") if isinstance(status.get("parsed"), dict) else {}
    if not parsed:
        parsed = status.get("parsed_command") if isinstance(status.get("parsed_command"), dict) else {}
    return RobotCommandStatus(
        ok=True,
        mode=str(status.get("mode", "")),
        estop=bool(status.get("estop", status.get("estop_present", False))),
        mtime=_optional_int(status.get("mtime")),
        raw=str(status.get("raw", status.get("raw_command", ""))),
        enabled=bool(parsed["enabled"]) if "enabled" in parsed else None,
        stride_mm=_optional_float(parsed.get("stride_mm")),
        side_mm=_optional_float(parsed.get("side_mm")),
        turn_deg=_optional_float(parsed.get("turn_deg")),
        period_ms=_optional_float(parsed.get("period_ms")),
        foot_mm=_optional_float(parsed.get("foot_mm")),
        head_pan_deg=_optional_float(parsed.get("head_pan_deg")),
        head_tilt_deg=_optional_float(parsed.get("head_tilt_deg")),
    )


def _optional_float(value: Any) -> float | None:
    try:
        return None if value is None else float(value)
    except (TypeError, ValueError):
        return None


def bar_fraction(value: float, maximum: float, bipolar: bool = True) -> float:
    if maximum <= 0:
        return 0.5 if bipolar else 0.0
    normalized = max(-1.0, min(1.0, value / maximum))
    if bipolar:
        return (normalized + 1.0) / 2.0
    return max(0.0, min(1.0, normalized))


def robot_ready_summary(result: dict[str, Any]) -> str:
    action = str(result.get("action", "robot-ready"))
    if bool(result.get("ok")):
        stdout = str(result.get("stdout", "")).strip().splitlines()
        tail = stdout[-1] if stdout else "완료"
        return f"{action}: OK · {tail[:80]}"
    error = str(result.get("error", "") or "").strip()
    stderr = str(result.get("stderr", "") or "").strip().splitlines()
    stdout = str(result.get("stdout", "") or "").strip().splitlines()
    detail = error or (stderr[-1] if stderr else "") or (stdout[-1] if stdout else "") or "실패"
    return f"{action}: 실패 · {detail[:80]}"


def acceptance_ui_summary(report: dict[str, Any]) -> tuple[str, str]:
    summary = report.get("sample_summary", {}) if isinstance(report.get("sample_summary"), dict) else {}
    level = str(report.get("level", "unknown")).upper()
    label = (
        f"{level} · "
        f"agentΔ {float(summary.get('state_drive_span', 0)):.1f} "
        f"robotΔ {float(summary.get('robot_drive_span', 0)):.1f} "
        f"periodΔ {float(summary.get('robot_period_span', 0)):.0f}"
    )
    checks = report.get("checks", [])
    if isinstance(checks, list):
        for item in checks:
            if not isinstance(item, dict):
                continue
            if item.get("level") not in {"bad", "warn"}:
                continue
            title = str(item.get("title", "검증 항목"))
            detail = str(item.get("detail", "")).strip()
            fix = str(item.get("fix", "")).strip()
            status = f"{title}: {detail}" if detail else title
            if fix:
                status = f"{status} · {fix}"
            return label, status[:180]
    return label, "조종 검증 통과 · agent 입력과 로봇 WalkLab 명령 파일이 함께 변합니다."


def acceptance_start_instruction(
    state: NativeState | None,
    robot_status: RobotCommandStatus | None,
) -> str:
    blockers: list[str] = []
    if state is None:
        blockers.append("agent 상태 확인")
    else:
        if state.mode != "ssh":
            blockers.append("SSH 적용")
        if not state.link_ok:
            blockers.append("로봇 SSH 연결")
        if state.estopped:
            blockers.append("비상정지 복구")
        if not state.armed:
            blockers.append("A 조종 시작")

    if robot_status is not None and robot_status.ok:
        if robot_status.mode and robot_status.mode != "walklab":
            blockers.append("WalkLab 시작")
        if robot_status.estop:
            blockers.append("로봇 E-stop 해제")

    unique_blockers = list(dict.fromkeys(blockers))
    drill = "왼쪽 스틱을 약/강/좌우로 움직이고 오른쪽 스틱을 움직였다 놓으세요."
    if unique_blockers:
        return f"검증 전 확인: {' · '.join(unique_blockers)} · 준비되면 {drill}"
    return f"6초 측정 중 · {drill}"


def live_control_hint(state: NativeState, robot_status: RobotCommandStatus) -> tuple[str, str]:
    if state.mode != "ssh":
        return "warn", "SSH 적용 필요 · 로봇 직접 조종 전 enable-agent-ssh를 실행하세요."
    if not state.link_ok:
        return "warn", "로봇 SSH 연결 대기 · IP, Wi-Fi, 키 인증, darwin-switch-agent 상태를 확인하세요."
    if state.estopped:
        return "bad", "비상정지 상태 · 복구 후 다시 A로 조종 시작하세요."
    if not robot_status.ok:
        return "warn", f"로봇 명령 파일 확인 불가 · {robot_status.summary}"
    if robot_status.mode and robot_status.mode != "walklab":
        return "warn", "WalkLab 미시작 · 로봇 준비 패널에서 WalkLab 시작을 먼저 실행하세요."
    if robot_status.estop:
        return "bad", "로봇 E-stop 파일 감지 · 복구 또는 E-stop 해제 후 테스트하세요."
    if not state.armed:
        return "warn", "A로 조종 시작 필요 · 누른 뒤 왼쪽 스틱으로 이동하세요."

    agent_drive = max(abs(state.stride_mm), abs(state.side_mm), abs(state.turn_deg))
    robot_drive = robot_status.drive_span_value
    if agent_drive >= 2.0 and robot_drive < max(1.5, agent_drive * 0.45):
        return "warn", "agent 입력만 변함 · SSH write, /tmp/df-walklab-cmd 권한, WalkLab brokerage를 확인하세요."
    if agent_drive >= 2.0 and robot_status.period_ms is None:
        return "warn", "로봇 명령은 가지만 gait period 파싱 실패 · 스위치 agent/robot_ready 재배포가 필요합니다."
    if (
        abs(state.right_x) < 0.08
        and abs(state.right_y) < 0.08
        and (abs(state.head_pan_deg) >= 1.0 or abs(state.head_tilt_deg) >= 1.0)
        and abs(robot_status.head_pan_deg or 0.0) < 1.0
        and abs(robot_status.head_tilt_deg or 0.0) < 1.0
    ):
        return "warn", "머리 유지값이 로봇 파일에 없음 · head token 재배포 또는 구버전 agent 여부를 확인하세요."
    if agent_drive >= 2.0:
        return "ok", "조종 경로 정상 · 입력, SSH 명령 파일, WalkLab 값이 함께 변하고 있습니다."
    return "ok", "대기 중 · 왼쪽 스틱 이동, L/R 회전, ZL/ZR은 제자리걸음입니다."


class AgentClient:
    def __init__(self, base_url: str = DEFAULT_URL):
        self.base_url = base_url.rstrip("/")

    def get_state(self) -> NativeState:
        with urllib.request.urlopen(f"{self.base_url}/api/state", timeout=1.0) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return state_from_payload(payload if isinstance(payload, dict) else {})

    def action(self, action: str) -> bool:
        payload = json.dumps({"action": action}).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base_url}/api/action",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=1.5) as response:
            data = json.loads(response.read().decode("utf-8"))
        return bool(isinstance(data, dict) and data.get("ok"))

    def update_config(self, payload: dict[str, Any]) -> bool:
        req = urllib.request.Request(
            f"{self.base_url}/api/config",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=2.0) as response:
            data = json.loads(response.read().decode("utf-8"))
        return bool(isinstance(data, dict) and data.get("ok"))

    def get_robot_command(self) -> RobotCommandStatus:
        with urllib.request.urlopen(f"{self.base_url}/api/robot-command", timeout=2.0) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return command_status_from_payload(payload if isinstance(payload, dict) else {})

    def native_acceptance(self, sample_seconds: float = 6.0, strict: bool = False) -> dict[str, Any]:
        from .native_acceptance import run_native_acceptance

        return run_native_acceptance(
            base_url=self.base_url,
            timeout=1.2,
            sample_seconds=sample_seconds,
            sample_interval=0.3,
        )

    def robot_ready_result(self, action: str) -> dict[str, Any]:
        req = urllib.request.Request(
            f"{self.base_url}/api/robot-ready",
            data=json.dumps({"action": action}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15.0) as response:
            data = json.loads(response.read().decode("utf-8"))
        return data if isinstance(data, dict) else {"ok": False, "action": action, "error": "invalid response"}

    def robot_ready(self, action: str) -> bool:
        return bool(self.robot_ready_result(action).get("ok"))

    def service_action(self, service: str, action: str) -> bool:
        req = urllib.request.Request(
            f"{self.base_url}/api/service",
            data=json.dumps({"service": service, "action": action}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=8.0) as response:
            data = json.loads(response.read().decode("utf-8"))
        return bool(isinstance(data, dict) and data.get("ok"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Darwin Switch GTK native cockpit")
    parser.add_argument("--url", default=DEFAULT_URL, help="local agent base URL")
    parser.add_argument(
        "--windowed",
        action="store_true",
        help="open in a normal window instead of fullscreen kiosk mode",
    )
    args = parser.parse_args(argv)

    try:
        import gi  # type: ignore

        gi.require_version("Gdk", "3.0")
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gdk, GLib, Gtk  # type: ignore
    except (ImportError, ValueError) as exc:
        print(
            "GTK native cockpit requires python3-gi and GTK 3. "
            "Install with: sudo apt-get install python3-gi gir1.2-gtk-3.0",
            file=sys.stderr,
        )
        print(f"detail: {exc}", file=sys.stderr)
        return 78

    client = AgentClient(args.url)
    _install_css(Gdk, Gtk, APP_CSS)

    class DarwinNativeWindow(Gtk.ApplicationWindow):  # type: ignore[misc]
        def __init__(self, app: Gtk.Application):
            super().__init__(application=app, title="Darwin Switch Native Cockpit")
            self.set_default_size(1280, 720)
            self.set_border_width(18)
            self.labels: dict[str, Any] = {}
            self.bars: dict[str, Any] = {}
            self.panel_bodies: dict[int, Any] = {}
            self.latest_state: NativeState | None = None
            self.command_status = RobotCommandStatus(ok=False, error="대기 중")
            self.status_bar = Gtk.Label(label="agent 연결 대기 중")
            self.status_bar.set_xalign(0)
            self.status_bar.get_style_context().add_class("statusbar")
            self._build()
            GLib.timeout_add(200, self.refresh)
            GLib.timeout_add(1000, self.refresh_robot_command)

        def _build(self) -> None:
            root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
            self.add(root)

            header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            root.pack_start(header, False, False, 0)
            title = Gtk.Label()
            title.set_markup("<span size='24000' weight='700'>다윈 네이티브 조종석</span>")
            title.set_xalign(0)
            header.pack_start(title, True, True, 0)
            self._add_header_badge(header, "link", "연결 대기")
            self._add_header_badge(header, "mode", "mode")
            self._add_header_badge(header, "target", "target")

            grid = Gtk.Grid(column_spacing=14, row_spacing=14)
            grid.set_column_homogeneous(True)
            root.pack_start(grid, True, True, 0)

            grid.attach(self._drive_panel(), 0, 0, 2, 2)
            grid.attach(self._head_panel(), 2, 0, 1, 1)
            grid.attach(self._safety_panel(), 3, 0, 1, 1)
            grid.attach(self._input_panel(), 2, 1, 1, 1)
            grid.attach(self._tuning_panel(), 3, 1, 1, 1)
            grid.attach(self._robot_command_panel(), 0, 2, 2, 1)
            grid.attach(self._log_panel(), 2, 2, 2, 1)

            controls = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            root.pack_start(controls, False, False, 0)
            for label, action, style in (
                ("A 조종 시작", "arm", "suggested-action"),
                ("복구", "recover", ""),
                ("정지", "stop", ""),
                ("재연결", "reconnect", ""),
                ("비상정지", "estop", "destructive-action"),
            ):
                button = Gtk.Button(label=label)
                button.get_style_context().add_class(style)
                button.connect("clicked", self._on_action, action)
                controls.pack_start(button, True, True, 0)

            root.pack_start(self.status_bar, False, False, 0)

        def _add_header_badge(self, box: Any, key: str, text: str) -> None:
            label = Gtk.Label(label=text)
            label.get_style_context().add_class("badge")
            self.labels[key] = label
            box.pack_start(label, False, False, 0)

        def _drive_panel(self) -> Any:
            box = self._panel("이동")
            self._metric(box, "speed", "속도", "0%")
            self.labels["speed"].get_style_context().add_class("value-large")
            self._bar(box, "speed_bar", 0.0, bipolar=False)
            self._metric(box, "direction", "방향", "정지")
            self._metric(box, "stride", "전후", "0.0 mm")
            self._bar(box, "stride_bar", 0.5)
            self._metric(box, "side", "좌우", "0.0 mm")
            self._bar(box, "side_bar", 0.5)
            self._metric(box, "turn", "회전", "0.0°")
            self._bar(box, "turn_bar", 0.5)
            return box

        def _head_panel(self) -> Any:
            box = self._panel("머리")
            self._metric(box, "pan", "좌우", "0.0°")
            self._bar(box, "pan_bar", 0.5)
            self._metric(box, "tilt", "상하", "0.0°")
            self._bar(box, "tilt_bar", 0.5)
            self._metric(box, "head_hold", "유지", "마지막 위치")
            return box

        def _safety_panel(self) -> Any:
            box = self._panel("상태")
            self._metric(box, "armed", "조종 권한", "잠김")
            self._metric(box, "deadman", "제자리걸음", "꺼짐")
            self._metric(box, "moving", "명령", "정지")
            self._metric(box, "estop", "비상정지", "정상")
            self._metric(box, "watchdog", "정지 감시", "—")
            return box

        def _input_panel(self) -> Any:
            box = self._panel("입력")
            self._metric(box, "input", "장치", "-")
            self._metric(box, "left", "왼쪽 스틱", "0.00 / 0.00")
            self._metric(box, "right", "오른쪽 스틱", "0.00 / 0.00")
            self._metric(box, "latency", "지연", "—")
            self._metric(box, "battery", "배터리", "—")
            return box

        def _tuning_panel(self) -> Any:
            box = self._panel("튜닝")
            body = self._panel_body(box)
            hint = Gtk.Label(label="조종 중에는 값 적용을 누르지 마세요.")
            hint.set_xalign(0)
            hint.set_line_wrap(True)
            body.pack_start(hint, False, False, 0)
            for label, preset in (
                ("안정 우선", SAFE_TUNING_PRESET),
                ("반응 우선", RESPONSIVE_TUNING_PRESET),
            ):
                button = Gtk.Button(label=label)
                button.connect("clicked", self._on_preset, preset, label)
                body.pack_start(button, False, False, 0)
            restart = Gtk.Button(label="agent 재시작")
            restart.connect("clicked", self._on_restart_agent)
            body.pack_start(restart, False, False, 0)
            acceptance = Gtk.Button(label="조종 검증 6초")
            acceptance.connect("clicked", self._on_native_acceptance)
            body.pack_start(acceptance, False, False, 0)
            self._metric(box, "preset", "현재 프리셋", "수동/확인 전")
            self._metric(box, "acceptance", "검증", "대기")
            return box

        def _robot_command_panel(self) -> Any:
            box = self._panel("로봇 명령 파일")
            body = self._panel_body(box)
            actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            body.pack_start(actions, False, False, 0)
            for label, action in (
                ("상태", "status"),
                ("WalkLab", "start-walklab"),
                ("안정화", "stabilize"),
                ("SSH 적용", "enable-agent-ssh"),
            ):
                button = Gtk.Button(label=label)
                button.connect("clicked", self._on_robot_ready, action)
                actions.pack_start(button, True, True, 0)
            self._metric(box, "robot_mode", "모드", "—")
            self._metric(box, "robot_estop", "E-stop 파일", "—")
            self._metric(box, "robot_cmd", "최근 명령", "대기 중")
            self._metric(box, "robot_head", "머리", "—")
            self._metric(box, "robot_ready", "준비", "대기")
            self._metric(box, "robot_cmd_raw", "raw", "")
            return box

        def _log_panel(self) -> Any:
            box = self._panel("기록")
            body = self._panel_body(box)
            log = Gtk.Label(label="")
            log.set_xalign(0)
            log.set_yalign(0)
            log.set_line_wrap(True)
            self.labels["logs"] = log
            body.pack_start(log, True, True, 0)
            return box

        def _panel(self, title_text: str) -> Any:
            frame = Gtk.Frame()
            frame.set_label(title_text)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            box.set_border_width(12)
            frame.add(box)
            self.panel_bodies[id(frame)] = box
            return frame

        def _panel_body(self, panel: Any) -> Any:
            return self.panel_bodies.get(id(panel), panel)

        def _metric(self, box: Any, key: str, title_text: str, value: str) -> None:
            body = self._panel_body(box)
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            title = Gtk.Label(label=title_text)
            title.set_xalign(0)
            val = Gtk.Label(label=value)
            val.set_xalign(1)
            val.get_style_context().add_class("monospace")
            self.labels[key] = val
            row.pack_start(title, True, True, 0)
            row.pack_start(val, False, False, 0)
            body.pack_start(row, False, False, 0)

        def _bar(self, box: Any, key: str, value: float, bipolar: bool = True) -> None:
            body = self._panel_body(box)
            bar = Gtk.LevelBar()
            bar.set_min_value(0.0)
            bar.set_max_value(1.0)
            bar.set_value(max(0.0, min(1.0, value)))
            bar.set_size_request(-1, 12)
            if not bipolar:
                bar.get_style_context().add_class("warning")
            self.bars[key] = bar
            body.pack_start(bar, False, False, 0)

        def _on_action(self, _button: Any, action: str) -> None:
            try:
                ok = client.action(action)
                self.status_bar.set_text(f"{action}: {'OK' if ok else '실패'}")
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                self.status_bar.set_text(f"{action} 실패: {exc}")

        def _on_preset(self, _button: Any, preset: dict[str, Any], label: str) -> None:
            try:
                ok = client.update_config(preset)
                self.labels["preset"].set_text(label if ok else "적용 실패")
                self.status_bar.set_text(
                    f"{label}: {'적용됨 · agent 재시작 필요' if ok else '실패'}"
                )
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                self.status_bar.set_text(f"{label} 실패: {exc}")

        def _on_restart_agent(self, _button: Any) -> None:
            try:
                ok = client.service_action("agent", "restart")
                self.status_bar.set_text(f"agent 재시작: {'OK' if ok else '실패'}")
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                self.status_bar.set_text(f"agent 재시작 실패: {exc}")

        def _on_robot_ready(self, _button: Any, action: str) -> None:
            self.labels["robot_ready"].set_text(f"{action} 실행 중")
            self.status_bar.set_text(f"{action} 실행 중 · 로봇이 walk-ready 상태인지 확인하세요.")
            thread = threading.Thread(target=self._run_robot_ready, args=(action,), daemon=True)
            thread.start()

        def _run_robot_ready(self, action: str) -> None:
            try:
                result = client.robot_ready_result(action)
                summary = robot_ready_summary(result)
                GLib.idle_add(self._finish_robot_ready, summary, bool(result.get("ok")))
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
                GLib.idle_add(self._finish_robot_ready, f"{action}: 실패 · {exc}", False)

        def _finish_robot_ready(self, summary: str, ok: bool) -> bool:
            self.labels["robot_ready"].set_text(summary)
            self.status_bar.set_text("로봇 준비 명령 완료" if ok else "로봇 준비 명령 실패")
            return False

        def _on_native_acceptance(self, _button: Any) -> None:
            self.labels["acceptance"].set_text("측정 중")
            self.status_bar.set_text(acceptance_start_instruction(self.latest_state, self.command_status))
            thread = threading.Thread(target=self._run_native_acceptance, daemon=True)
            thread.start()

        def _run_native_acceptance(self) -> None:
            try:
                report = client.native_acceptance(sample_seconds=6.0)
                if not isinstance(report, dict):
                    report = {"level": "bad", "checks": [{"level": "bad", "title": "검증", "detail": "invalid response"}]}
                text, status = acceptance_ui_summary(report)
                GLib.idle_add(self._finish_native_acceptance, text, status)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
                GLib.idle_add(self._finish_native_acceptance, "실패", f"조종 검증 실패: {exc}")

        def _finish_native_acceptance(self, label: str, status: str) -> bool:
            self.labels["acceptance"].set_text(label)
            self.status_bar.set_text(status)
            return False

        def refresh(self) -> bool:
            try:
                state = client.get_state()
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                self.status_bar.set_text(f"agent 대기 중: {exc}")
                self.labels["link"].set_text("연결 끊김")
                return True
            self.latest_state = state
            self._render(state)
            return True

        def refresh_robot_command(self) -> bool:
            try:
                self.command_status = client.get_robot_command()
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
                self.command_status = RobotCommandStatus(ok=False, error=str(exc))
            self._render_robot_command()
            return True

        def _render(self, state: NativeState) -> None:
            self.labels["link"].set_text("SSH 연결됨" if state.link_ok else "연결 대기")
            self._set_badge("link", "ok" if state.link_ok else "warn")
            self.labels["mode"].set_text(state.mode)
            self.labels["target"].set_text(state.target)
            self.labels["speed"].set_text(f"{state.drive_speed_pct}%")
            self._set_bar("speed_bar", state.drive_speed_pct / 100.0)
            self.labels["direction"].set_text(state.direction_label)
            self.labels["stride"].set_text(f"{state.stride_mm:.1f} mm")
            self._set_bar("stride_bar", bar_fraction(state.stride_mm, 38.0))
            self.labels["side"].set_text(f"{state.side_mm:.1f} mm")
            self._set_bar("side_bar", bar_fraction(state.side_mm, 22.0))
            self.labels["turn"].set_text(f"{state.turn_deg:.1f}°")
            self._set_bar("turn_bar", bar_fraction(state.turn_deg, 14.0))
            self.labels["pan"].set_text(f"{state.head_pan_deg:.1f}°")
            self._set_bar("pan_bar", bar_fraction(state.head_pan_deg, 70.0))
            self.labels["tilt"].set_text(f"{state.head_tilt_deg:.1f}°")
            self._set_bar("tilt_bar", bar_fraction(state.head_tilt_deg, 35.0))
            self.labels["armed"].set_text("준비됨" if state.armed else "잠김")
            self.labels["deadman"].set_text("켜짐" if state.deadman else "꺼짐")
            self.labels["moving"].set_text("이동 중" if state.moving else "정지")
            self.labels["estop"].set_text("작동" if state.estopped else "정상")
            self._set_status_danger(state.estopped)
            self.labels["watchdog"].set_text(state.watchdog_label)
            self.labels["input"].set_text(state.input_status)
            self.labels["left"].set_text(f"{state.left_x:.2f} / {state.left_y:.2f}")
            self.labels["right"].set_text(f"{state.right_x:.2f} / {state.right_y:.2f}")
            self.labels["latency"].set_text("—" if state.latency_ms is None else f"{state.latency_ms} ms")
            self.labels["battery"].set_text("—" if state.battery_pct is None else f"{state.battery_pct}%")
            self.labels["logs"].set_text("\n".join(state.logs))
            self._render_robot_command()
            level, hint = live_control_hint(state, self.command_status)
            self.status_bar.set_text(hint)
            self._set_status_level(level)

        def _set_bar(self, key: str, value: float) -> None:
            bar = self.bars.get(key)
            if bar is not None:
                bar.set_value(max(0.0, min(1.0, value)))

        def _set_badge(self, key: str, level: str) -> None:
            label = self.labels.get(key)
            if label is None:
                return
            ctx = label.get_style_context()
            for name in ("badge-ok", "badge-warn", "badge-bad"):
                ctx.remove_class(name)
            ctx.add_class(f"badge-{level}")

        def _set_status_danger(self, danger: bool) -> None:
            self._set_status_level("bad" if danger else "ok")

        def _set_status_level(self, level: str) -> None:
            ctx = self.status_bar.get_style_context()
            for name in ("badge-ok", "badge-warn", "badge-bad"):
                ctx.remove_class(name)
            ctx.add_class(f"badge-{level}")

        def _render_robot_command(self) -> None:
            status = self.command_status
            self.labels["robot_mode"].set_text(status.mode or "—")
            self.labels["robot_estop"].set_text("있음" if status.estop else ("없음" if status.ok else "—"))
            self.labels["robot_cmd"].set_text(status.summary)
            if status.head_pan_deg is None and status.head_tilt_deg is None:
                self.labels["robot_head"].set_text("—")
            else:
                pan = status.head_pan_deg if status.head_pan_deg is not None else 0.0
                tilt = status.head_tilt_deg if status.head_tilt_deg is not None else 0.0
                self.labels["robot_head"].set_text(f"{pan:.1f}° / {tilt:.1f}°")
            self.labels["robot_cmd_raw"].set_text(status.raw[:96])

    class DarwinNativeApp(Gtk.Application):  # type: ignore[misc]
        def do_activate(self) -> None:
            window = DarwinNativeWindow(self)
            window.show_all()
            if not args.windowed:
                window.fullscreen()
            window.present()

    app = DarwinNativeApp(application_id="com.darwin.switch.nativecockpit")
    return int(app.run([]))


def _install_css(Gdk: Any, Gtk: Any, css: str) -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(css.encode("utf-8"))
    screen = Gdk.Screen.get_default()
    if screen is not None:
        Gtk.StyleContext.add_provider_for_screen(
            screen,
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )


if __name__ == "__main__":
    raise SystemExit(main())
