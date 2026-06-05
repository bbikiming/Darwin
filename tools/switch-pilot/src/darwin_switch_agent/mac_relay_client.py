from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timezone
from typing import Any

from .mapping import MotionCommand
from .websocket_client import SimpleWebSocket


class MacRelayClient:
    def __init__(self, cfg: dict, device_name: str, device_id: str):
        self.log = logging.getLogger("mac")
        self.cfg = cfg
        self.device_name = device_name
        self.device_id = device_id
        self.ws: SimpleWebSocket | None = None
        self.counter = 0
        self.connected = False
        self.last_heartbeat = 0.0

    def connect(self) -> None:
        host = str(self.cfg.get("host", "127.0.0.1"))
        port = int(self.cfg.get("port", 0))
        if port <= 0:
            raise RuntimeError("mac.port must be configured for mac_relay mode")
        path = str(self.cfg.get("path", "/mobile-relay"))
        timeout = float(self.cfg.get("connect_timeout_sec", 5.0))
        url = f"ws://{host}:{port}{path}"
        self.ws = SimpleWebSocket(url, timeout=timeout)
        self.ws.connect()
        self.ws.send_text(json.dumps(self._envelope("session.hello", {
            "app": "switch",
            "appVersion": "0.1.0",
            "protocolVersion": 1,
            "deviceName": self.device_name,
            "deviceId": self.device_id,
            "pairingCode": str(self.cfg.get("pairing_code", "000000")),
        }), separators=(",", ":")))
        welcome = self.ws.recv_text(timeout=timeout)
        if not welcome:
            raise RuntimeError("no session welcome from Mac relay")
        parsed = json.loads(welcome)
        if parsed.get("type") == "session.rejected":
            reason = parsed.get("payload", {}).get("reason", "unknown")
            raise RuntimeError(f"Mac relay rejected session: {reason}")
        if parsed.get("type") != "session.welcome":
            raise RuntimeError(f"unexpected first Mac relay frame: {parsed.get('type')}")
        self.connected = True
        self.log.info("connected to Mac relay at %s", url)

    def close(self) -> None:
        if self.ws:
            self.ws.close()
        self.connected = False

    def heartbeat(self, ui_state: str = "armedReady") -> None:
        interval = int(self.cfg.get("heartbeat_ms", 100)) / 1000.0
        now = time.monotonic()
        if now - self.last_heartbeat < interval:
            return
        self._send("pilot.heartbeat", {
            "uiState": ui_state,
            "activeCommandId": None,
        })
        self.last_heartbeat = now

    def arm(self) -> None:
        self._send("pilot.arm", {
            "cradleConfirmed": True,
            "operator": self.device_name,
        })

    def stop(self, reason: str = "deadmanRelease") -> None:
        self._send("pilot.stop", {"reason": reason})

    def estop(self, reason: str = "switchScreen") -> None:
        self._send("pilot.estop", {"reason": reason})

    def recover(self) -> None:
        self._send("pilot.recover", {
            "cradleConfirmed": True,
            "operator": self.device_name,
        })

    def walk(self, command: MotionCommand) -> None:
        self._send("pilot.walk", {
            "preset": "freeform",
            "enabled": command.moving,
            "xMm": round(command.stride_mm, 2),
            "yMm": 0.0,
            "aDeg": round(command.turn_deg, 2),
            "periodMs": 700,
            "footMm": 35.0,
            "hipPitchDeg": 13.0,
            "speedScale": round(command.speed_scale, 2),
        })

    def head(self, command: MotionCommand) -> None:
        if not bool(self.cfg.get("send_head", False)):
            return
        self._send("pilot.head", {
            "enabled": True,
            "panDeg": round(command.head_pan_deg, 2),
            "tiltDeg": round(command.head_tilt_deg, 2),
            "tracking": False,
        })

    def _send(self, command_type: str, payload: dict[str, Any]) -> None:
        if not self.ws:
            raise RuntimeError("Mac relay is not connected")
        self.ws.send_text(json.dumps(self._envelope(command_type, payload), separators=(",", ":")))

    def _envelope(self, command_type: str, payload: dict[str, Any]) -> dict[str, Any]:
        self.counter += 1
        return {
            "v": 1,
            "id": f"switch_{self.counter:06d}",
            "type": command_type,
            "sentAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "payload": payload,
        }
