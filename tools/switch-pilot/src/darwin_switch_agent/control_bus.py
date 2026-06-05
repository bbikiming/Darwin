from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass
from typing import Any

from .input_linux import ControllerState
from .mapping import MotionCommand


@dataclass(frozen=True)
class ControlAction:
    action: str
    source: str = "cockpit"


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
            "input_status": "No input device",
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
            "robot_walking": False,
            "robot_fallen": 0,
            "robot_state": "unknown",
            "logs": [],
            "updated_at_ms": int(time.time() * 1000),
        }

    def request(self, action: str, source: str = "cockpit") -> None:
        self._actions.put(ControlAction(action=action, source=source))
        self.log(f"{source}: {action}")

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
    ) -> None:
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
                "updated_at_ms": int(time.time() * 1000),
            }

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._snapshot)


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
