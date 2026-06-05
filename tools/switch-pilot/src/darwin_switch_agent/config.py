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
    return out


def _validate_camera(section: Any) -> dict[str, Any]:
    if not isinstance(section, dict):
        raise ValueError("camera must be an object")
    out: dict[str, Any] = {}
    if "enabled" in section:
        if not isinstance(section["enabled"], bool):
            raise ValueError("camera.enabled must be a boolean")
        out["enabled"] = section["enabled"]
    for key in ("stream_url", "snapshot_url"):
        if key in section:
            out[key] = _require_str(section[key], f"camera.{key}")
    return out


def validate_provisioning(payload: Any) -> dict[str, Any]:
    """Strictly validate a first-boot provisioning payload at the boundary.

    Accepts ONLY a fixed allowlist of keys; unknown keys are rejected so the
    localhost device-config UI can never inject arbitrary config. Returns a new
    dict of validated updates; raises ValueError on any invalid input.
    """
    if not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")

    allowed = {"mode", "mac", "robot", "camera", "ssh"}
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
    return updates
