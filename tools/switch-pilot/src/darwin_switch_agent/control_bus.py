from __future__ import annotations

import copy
import glob
import queue
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .input_linux import ControllerState
from .mapping import MotionCommand


@dataclass(frozen=True)
class ControlAction:
    action: str
    source: str = "cockpit"


# Korean labels for the event log shown in the cockpit "기록" panel.
_ACTION_LABELS = {
    "arm": "조종 권한",
    "stop": "정지",
    "estop": "비상정지",
    "recover": "복구",
    "ping": "점검",
    "reconnect": "재연결",
}
_SOURCE_LABELS = {"cockpit": "화면"}


class ControlBus:
    """Thread-safe state and command bridge between agent loop and cockpit UI."""

    def __init__(self, camera: dict[str, Any] | None = None) -> None:
        self._lock = threading.Lock()
        self._actions: queue.Queue[ControlAction] = queue.Queue()
        self._logs: list[str] = []
        self._started_at = time.time()
        self._snapshot: dict[str, Any] = {
            "mode": "dry_run",
            "connected": False,
            "local_ip": "127.0.0.1",
            "target": "",
            "input_status": "입력장치 없음",
            "deadman": False,
            "armed": False,
            "estopped": False,
            "moving": False,
            "controller": {},
            "command": {},
            "camera": normalize_camera(camera or {}),
            "ssh_connected": False,
            "link_latency_ms": None,
            "battery_v": None,
            "battery_pct": None,
            "switch_battery": read_switch_battery(),
            "robot_walking": False,
            "robot_fallen": 0,
            "robot_state": "unknown",
            "imu": {
                "source": "none",
                "gyro_x": None,
                "gyro_y": None,
                "gyro_z": None,
                "accel_x": None,
                "accel_y": None,
                "accel_z": None,
            },
            "watchdog_label": "—",
            "logs": [],
            "updated_at_ms": int(time.time() * 1000),
        }

    def set_watchdog_label(self, label: str) -> None:
        """Set the honest, mode-specific stop-watchdog label shown in the cockpit.
        Set once at startup; never claim a watchdog the active path doesn't run."""
        with self._lock:
            self._snapshot["watchdog_label"] = label

    def request(self, action: str, source: str = "cockpit") -> None:
        self._actions.put(ControlAction(action=action, source=source))
        label = _ACTION_LABELS.get(action, action)
        src = _SOURCE_LABELS.get(source, source)
        self.log(f"{label} ({src})")

    def drain_actions(self) -> list[ControlAction]:
        actions: list[ControlAction] = []
        while True:
            try:
                actions.append(self._actions.get_nowait())
            except queue.Empty:
                return actions

    def log(self, message: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        with self._lock:
            self._logs.append(f"{stamp} {message}")
            self._logs = self._logs[-20:]
            self._snapshot["logs"] = list(reversed(self._logs[-8:]))

    def publish(
        self,
        *,
        mode: str,
        connected: bool,
        local_ip: str,
        target: str,
        input_status: str,
        controller: ControllerState,
        command: MotionCommand,
        armed: bool,
        estopped: bool,
    ) -> None:
        with self._lock:
            self._snapshot.update(
                {
                    "mode": mode,
                    "connected": connected,
                    "local_ip": local_ip,
                    "target": target,
                    "input_status": input_status,
                    "deadman": controller.deadman,
                    "armed": armed,
                    "estopped": estopped,
                    "moving": command.moving,
                    "uptime_sec": int(time.time() - self._started_at),
                    "controller": {
                        "left_x": round(controller.left_x, 3),
                        "left_y": round(controller.left_y, 3),
                        "right_x": round(controller.right_x, 3),
                        "right_y": round(controller.right_y, 3),
                        "buttons_mask": f"0x{controller.buttons_mask:08x}",
                    },
                    "command": {
                        "stride_mm": round(command.stride_mm, 2),
                        "side_mm": round(command.side_mm, 2),
                        "turn_deg": round(command.turn_deg, 2),
                        "head_pan_deg": round(command.head_pan_deg, 2),
                        "head_tilt_deg": round(command.head_tilt_deg, 2),
                        "speed_scale": round(command.speed_scale, 2),
                    },
                    "logs": list(reversed(self._logs[-8:])),
                    "updated_at_ms": int(time.time() * 1000),
                }
            )

    def publish_telemetry(
        self,
        *,
        ssh_connected: bool,
        link_latency_ms: int | None,
        battery_v: float | None,
        battery_pct: int | None,
        walking: bool,
        fallen: int,
        robot_state: str,
        gyro: dict[str, int] | None = None,
        accel: dict[str, int] | None = None,
    ) -> None:
        gyro = gyro or {}
        accel = accel or {}
        with self._lock:
            self._snapshot = {
                **self._snapshot,
                "ssh_connected": ssh_connected,
                "link_latency_ms": link_latency_ms,
                "battery_v": battery_v,
                "battery_pct": battery_pct,
                "robot_walking": walking,
                "robot_fallen": fallen,
                "robot_state": robot_state,
                "imu": {
                    "source": "robot",
                    "gyro_x": gyro.get("x"),
                    "gyro_y": gyro.get("y"),
                    "gyro_z": gyro.get("z"),
                    "accel_x": accel.get("x"),
                    "accel_y": accel.get("y"),
                    "accel_z": accel.get("z"),
                },
                "updated_at_ms": int(time.time() * 1000),
            }

    def snapshot(self) -> dict[str, Any]:
        # Deep copy so callers cannot mutate the bus's nested containers
        # (logs list, controller/command/camera dicts) in place. The snapshot
        # holds only JSON-like primitives, so deepcopy is cheap and total.
        with self._lock:
            snap = copy.deepcopy(self._snapshot)
        snap["switch_battery"] = read_switch_battery()
        snap["camera_runtime"] = read_camera_runtime(snap.get("camera", {}))
        return snap


def read_switch_battery(root: str = "/sys/class/power_supply") -> dict[str, Any]:
    supplies = sorted(glob.glob(f"{root}/*"))
    for supply in supplies:
        path = Path(supply)
        if not _is_battery_supply(path):
            continue
        percent = _read_int(path / "capacity")
        status = _read_text(path / "status") or "unknown"
        charging = status.lower() in {"charging", "full"}
        return {
            "percent": percent,
            "status": status,
            "charging": charging,
            "source": path.name,
        }
    return {"percent": None, "status": "unknown", "charging": False, "source": ""}


def _is_battery_supply(path: Path) -> bool:
    supply_type = (_read_text(path / "type") or "").lower()
    if supply_type == "battery":
        return True
    name = path.name.lower()
    return "battery" in name or "batt" in name or "max170" in name or "bq274" in name


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def _read_int(path: Path) -> int | None:
    text = _read_text(path)
    if text is None:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def normalize_camera(raw: dict[str, Any]) -> dict[str, Any]:
    enabled = bool(raw.get("enabled", False))
    stream_url = str(raw.get("stream_url", "")).strip()
    snapshot_url = str(raw.get("snapshot_url", "")).strip()
    route = str(raw.get("route", "ssh-tunnel")).strip() or "ssh-tunnel"
    label = str(raw.get("label", "Robot Camera")).strip() or "Robot Camera"
    return {
        "enabled": enabled,
        "stream_url": stream_url,
        "snapshot_url": snapshot_url,
        "route": route,
        "label": label,
    }


def read_camera_runtime(camera: dict[str, Any], timeout: float = 0.015) -> dict[str, Any]:
    enabled = bool(camera.get("enabled", False))
    stream_url = str(camera.get("stream_url", "")).strip()
    snapshot_url = str(camera.get("snapshot_url", "")).strip()
    probe_url = snapshot_url or stream_url
    if not enabled:
        return {"enabled": False, "status": "disabled", "local_port_open": False}
    if not probe_url:
        return {"enabled": True, "status": "missing_url", "local_port_open": False}

    parsed = urlparse(probe_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    opened = _tcp_port_open(host, port, timeout)
    return {
        "enabled": True,
        "status": "port_open" if opened else "port_closed",
        "host": host,
        "port": port,
        "local_port_open": opened,
        "url": probe_url,
    }


def _tcp_port_open(host: str, port: int, timeout: float) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False
