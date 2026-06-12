from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

_ALLOWED_MODES = {"dry_run", "mac_relay", "robot_udp", "ssh"}


@dataclass(frozen=True)
class AgentConfig:
    raw: dict[str, Any]

    @staticmethod
    def load(path: str) -> "AgentConfig":
        with open(path, "r", encoding="utf-8") as fp:
            return AgentConfig(json.load(fp))

    @property
    def mode(self) -> str:
        return str(self.raw.get("mode", "dry_run"))

    @property
    def device_name(self) -> str:
        return str(self.raw.get("device_name", "Darwin Switch"))

    @property
    def device_id(self) -> str:
        return str(self.raw.get("device_id", "darwin-switch-001"))

    @property
    def log_level(self) -> str:
        return str(self.raw.get("log_level", "INFO"))

    def section(self, name: str) -> dict[str, Any]:
        value = self.raw.get(name, {})
        if isinstance(value, dict):
            return value
        return {}

    def write_default_if_missing(self, path: str) -> None:
        dst = Path(path)
        if dst.exists():
            return
        dst.parent.mkdir(parents=True, exist_ok=True)
        with dst.open("w", encoding="utf-8") as fp:
            json.dump(self.raw, fp, indent=2)
            fp.write("\n")


def _require_str(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string")
    return value


def _require_port(value: Any, label: str) -> int:
    # Accept ints (and bool is rejected since it subclasses int).
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{label} must be an integer")
    if not 0 <= value <= 65535:
        raise ValueError(f"{label} must be in 0..65535")
    return value


def _validate_mac(section: Any) -> dict[str, Any]:
    if not isinstance(section, dict):
        raise ValueError("mac must be an object")
    out: dict[str, Any] = {}
    if "host" in section:
        out["host"] = _require_str(section["host"], "mac.host")
    if "port" in section:
        out["port"] = _require_port(section["port"], "mac.port")
    if "pairing_code" in section:
        code = _require_str(section["pairing_code"], "mac.pairing_code")
        if not code.isdigit():
            raise ValueError("mac.pairing_code must be digits")
        out["pairing_code"] = code
    return out


def _validate_robot(section: Any) -> dict[str, Any]:
    if not isinstance(section, dict):
        raise ValueError("robot must be an object")
    out: dict[str, Any] = {}
    if "host" in section:
        out["host"] = _require_str(section["host"], "robot.host")
    if "port" in section:
        out["port"] = _require_port(section["port"], "robot.port")
    if "token" in section:
        out["token"] = _require_str(section["token"], "robot.token")
    return out


def _validate_ssh(section: Any) -> dict[str, Any]:
    if not isinstance(section, dict):
        raise ValueError("ssh must be an object")
    out: dict[str, Any] = {}
    if "host" in section:
        out["host"] = _require_str(section["host"], "ssh.host")
    if "user" in section:
        out["user"] = _require_str(section["user"], "ssh.user")
    if "port" in section:
        port = _require_port(section["port"], "ssh.port")
        if not 1 <= port <= 65535:
            raise ValueError("ssh.port must be in 1..65535")
        out["port"] = port
    if "identity_file" in section:
        out["identity_file"] = _require_str(section["identity_file"], "ssh.identity_file")
    if "transport" in section:
        transport = _require_str(section["transport"], "ssh.transport")
        if transport not in {"auto", "ssh"}:
            raise ValueError("ssh.transport must be 'auto' or 'ssh'")
        out["transport"] = transport
    for key in ("cmd_port", "estop_port", "telemetry_port"):
        if key in section:
            port = _require_port(section[key], f"ssh.{key}")
            if not 1 <= port <= 65535:
                raise ValueError(f"ssh.{key} must be in 1..65535")
            out[key] = port
    for key in ("connect_timeout_seconds", "timeout_seconds"):
        if key in section:
            value = section[key]
            if isinstance(value, bool) or not isinstance(value, int):
                raise ValueError(f"ssh.{key} must be an integer")
            if not 1 <= value <= 60:
                raise ValueError(f"ssh.{key} must be in 1..60")
            out[key] = value
    for key in (
        "send_hz",
        "udp_send_hz",
        "telemetry_hz",
        "period_ms",
        "foot_mm",
        "min_period_ms",
        "max_period_ms",
        "min_foot_mm",
        "stride_ref_mm",
        "turn_ref_deg",
        "hip_deg",
        "heartbeat_ms",
        "ack_probe_ms",
        "udp_tel_fresh_s",
    ):
        if key in section:
            value = section[key]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f"ssh.{key} must be a number")
            if float(value) <= 0:
                raise ValueError(f"ssh.{key} must be positive")
            out[key] = value
    return out


def _validate_motion(section: Any) -> dict[str, Any]:
    if not isinstance(section, dict):
        raise ValueError("motion must be an object")
    out: dict[str, Any] = {}
    for key in (
        "max_stride_mm",
        "max_side_mm",
        "max_turn_deg",
        "max_head_pan_deg",
        "max_head_tilt_deg",
        "max_head_tilt_up_deg",
        "max_head_tilt_down_deg",
        "speed_scale",
        "send_hz",
        "turn_from_side_ratio",
        "drive_curve",
    ):
        if key in section:
            value = section[key]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ValueError(f"motion.{key} must be a number")
            if float(value) < 0:
                raise ValueError(f"motion.{key} must be non-negative")
            out[key] = value
    if "hold_head_position" in section:
        if not isinstance(section["hold_head_position"], bool):
            raise ValueError("motion.hold_head_position must be a boolean")
        out["hold_head_position"] = section["hold_head_position"]
    return out


def _validate_camera(section: Any) -> dict[str, Any]:
    if not isinstance(section, dict):
        raise ValueError("camera must be an object")
    out: dict[str, Any] = {}
    if "enabled" in section:
        if not isinstance(section["enabled"], bool):
            raise ValueError("camera.enabled must be a boolean")
        out["enabled"] = section["enabled"]
    for key in ("label", "route", "stream_url", "snapshot_url"):
        if key in section:
            out[key] = _require_str(section[key], f"camera.{key}")
    for key in ("local_port", "remote_port"):
        if key in section:
            port = _require_port(section[key], f"camera.{key}")
            if not 1 <= port <= 65535:
                raise ValueError(f"camera.{key} must be in 1..65535")
            out[key] = port
    return out


def validate_provisioning(payload: Any) -> dict[str, Any]:
    """Strictly validate a first-boot provisioning payload at the boundary.

    Accepts ONLY a fixed allowlist of keys; unknown keys are rejected so the
    localhost device-config UI can never inject arbitrary config. Returns a new
    dict of validated updates; raises ValueError on any invalid input.
    """
    if not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")

    allowed = {"mode", "mac", "robot", "camera", "ssh", "motion"}
    unknown = set(payload) - allowed
    if unknown:
        raise ValueError(f"unknown keys: {', '.join(sorted(unknown))}")

    updates: dict[str, Any] = {}
    if "mode" in payload:
        mode = _require_str(payload["mode"], "mode")
        if mode not in _ALLOWED_MODES:
            raise ValueError(f"mode must be one of {sorted(_ALLOWED_MODES)}")
        updates["mode"] = mode
    if "mac" in payload:
        mac = _validate_mac(payload["mac"])
        if mac:
            updates["mac"] = mac
    if "robot" in payload:
        robot = _validate_robot(payload["robot"])
        if robot:
            updates["robot"] = robot
    if "camera" in payload:
        camera = _validate_camera(payload["camera"])
        if camera:
            updates["camera"] = camera
    if "ssh" in payload:
        ssh = _validate_ssh(payload["ssh"])
        if ssh:
            updates["ssh"] = ssh
    if "motion" in payload:
        motion = _validate_motion(payload["motion"])
        if motion:
            updates["motion"] = motion
    return updates
