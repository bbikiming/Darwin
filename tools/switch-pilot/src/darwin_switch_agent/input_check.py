from __future__ import annotations

import argparse
import json
import logging
import os
import selectors
import struct
import sys
import time
import fcntl
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .config import AgentConfig
from .input_linux import (
    ABS_X,
    ABS_Y,
    DEFAULT_PREFER_NAMES,
    EV_ABS,
    EV_KEY,
    AxisInfo,
    DeviceProfile,
    eviocgabs,
    inspect_input_profiles,
    resolve_role_codes,
    select_controller_profile,
)


DEFAULT_ROOT = Path("/opt/darwin-switch-agent")
DEFAULT_CONFIG = Path("/etc/darwin-switch-agent/config.json")
EVENT_STRUCT = struct.Struct("llHHi")

ROLE_LABELS = {
    "deadman_key_codes": "in-place walk / ZL or ZR",
    "arm_key_codes": "arm / A",
    "stop_key_codes": "stop / B",
    "estop_key_codes": "estop / Home",
}

KEY_LABELS = {
    304: "BTN_SOUTH / Nintendo B",
    305: "BTN_EAST / Nintendo A",
    310: "BTN_TL / L",
    311: "BTN_TR / R",
    312: "BTN_TL2 / ZL",
    313: "BTN_TR2 / ZR",
    314: "BTN_SELECT / Minus",
    315: "BTN_START / Plus",
    316: "BTN_MODE / Home",
}

AXIS_LABELS = {
    "left_x_abs_codes": "left stick X / walk turn",
    "left_y_abs_codes": "left stick Y / stride",
    "right_x_abs_codes": "right stick X / head pan",
    "right_y_abs_codes": "right stick Y / head tilt",
}


@dataclass
class CaptureSummary:
    seconds: float
    event_count: int = 0
    key_events: dict[int, int] = field(default_factory=dict)
    axis_events: dict[int, int] = field(default_factory=dict)
    axis_peak: dict[int, float] = field(default_factory=dict)
    role_seen: dict[str, bool] = field(default_factory=dict)
    axis_seen: dict[str, bool] = field(default_factory=dict)


def load_config(config_path: Path, root: Path) -> AgentConfig:
    if config_path.is_file():
        return AgentConfig.load(str(config_path))
    fallback = root / "config.example.json"
    if fallback.is_file():
        return AgentConfig.load(str(fallback))
    return AgentConfig({"mode": "dry_run"})


def _prefer_names(input_config: dict[str, Any]) -> list[str]:
    names = input_config.get("prefer_names", DEFAULT_PREFER_NAMES)
    if not isinstance(names, (list, tuple)):
        return list(DEFAULT_PREFER_NAMES)
    return [str(name) for name in names if str(name).strip()] or list(DEFAULT_PREFER_NAMES)


def _code_set(mapping_config: dict[str, Any], key: str, defaults: tuple[int, ...] = ()) -> set[int]:
    values = mapping_config.get(key, defaults)
    try:
        return {int(value) for value in values}
    except TypeError:
        return set(defaults)


def _axis_code_map(mapping_config: dict[str, Any]) -> dict[str, set[int]]:
    return {
        "left_x_abs_codes": _code_set(mapping_config, "left_x_abs_codes", (ABS_X,)),
        "left_y_abs_codes": _code_set(mapping_config, "left_y_abs_codes", (ABS_Y,)),
        "right_x_abs_codes": _code_set(mapping_config, "right_x_abs_codes", (3,)),
        "right_y_abs_codes": _code_set(mapping_config, "right_y_abs_codes", (4,)),
    }


def _load_axis_info(fd: int, axes: set[int]) -> dict[int, AxisInfo]:
    out: dict[int, AxisInfo] = {}
    for axis in axes:
        buf = bytearray(24)
        try:
            fcntl.ioctl(fd, eviocgabs(axis), buf, True)
            _, minimum, maximum, _, _, _ = struct.unpack("iiiiii", buf)
            out[axis] = AxisInfo(minimum, maximum)
        except OSError:
            out[axis] = AxisInfo()
    return out


def _axis_name(axis_code: int, axis_codes: dict[str, set[int]]) -> str:
    labels = [AXIS_LABELS[key] for key, codes in axis_codes.items() if axis_code in codes]
    return ", ".join(labels) if labels else f"ABS_{axis_code}"


def _key_name(code: int) -> str:
    return KEY_LABELS.get(code, f"KEY_{code}")


def capture_events(
    profile: DeviceProfile,
    mapping_config: dict[str, Any],
    role_codes: dict[str, set[int]],
    seconds: float,
) -> CaptureSummary:
    summary = CaptureSummary(seconds=seconds)
    summary.role_seen = {role: False for role in ROLE_LABELS}
    summary.axis_seen = {key: False for key in AXIS_LABELS}
    if seconds <= 0:
        return summary

    axis_codes = _axis_code_map(mapping_config)
    interesting_axes = set().union(*axis_codes.values()) if axis_codes else set()
    end_at = time.monotonic() + seconds
    selector = selectors.DefaultSelector()

    fd = os.open(profile.path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        selector.register(fd, selectors.EVENT_READ)
        axis_info = _load_axis_info(fd, interesting_axes)
        while True:
            remaining = end_at - time.monotonic()
            if remaining <= 0:
                break
            for key, _ in selector.select(min(0.05, remaining)):
                while True:
                    try:
                        data = os.read(key.fd, EVENT_STRUCT.size)
                    except BlockingIOError:
                        break
                    except OSError:
                        break
                    if len(data) != EVENT_STRUCT.size:
                        break
                    summary.event_count += 1
                    _, _, event_type, code, value = EVENT_STRUCT.unpack(data)
                    if event_type == EV_KEY:
                        summary.key_events[code] = summary.key_events.get(code, 0) + 1
                        if value:
                            for role, codes in role_codes.items():
                                if code in codes:
                                    summary.role_seen[role] = True
                    elif event_type == EV_ABS:
                        summary.axis_events[code] = summary.axis_events.get(code, 0) + 1
                        normalized = axis_info.get(code, AxisInfo()).normalize(value)
                        previous = summary.axis_peak.get(code, 0.0)
                        if abs(normalized) > abs(previous):
                            summary.axis_peak[code] = normalized
                        for axis_key, codes in axis_codes.items():
                            if code in codes and abs(normalized) >= 0.18:
                                summary.axis_seen[axis_key] = True
    finally:
        try:
            selector.close()
        finally:
            os.close(fd)
    return summary


def build_report(config: AgentConfig, seconds: float) -> dict[str, Any]:
    input_config = config.section("input")
    mapping_config = config.section("mapping")
    prefer = _prefer_names(input_config)
    log = logging.getLogger("input-check")
    profiles = inspect_input_profiles(input_config, log)
    selected = select_controller_profile(profiles, prefer)
    role_codes = resolve_role_codes(selected, mapping_config) if selected else {}

    capture = CaptureSummary(seconds=seconds)
    error = ""
    if selected and seconds > 0:
        try:
            capture = capture_events(selected, mapping_config, role_codes, seconds)
        except PermissionError as exc:
            error = f"permission denied: {exc}"
        except OSError as exc:
            error = f"capture failed: {exc}"

    level = "good" if selected else "warn"
    if error:
        level = "bad"
    elif seconds > 0 and selected:
        missing_roles = [role for role, seen in capture.role_seen.items() if not seen]
        missing_axes = [axis for axis, seen in capture.axis_seen.items() if not seen]
        if missing_roles or missing_axes:
            level = "warn"

    return {
        "level": level,
        "ok": level != "bad",
        "device_count": len(profiles),
        "profiles": [_profile_dict(profile, prefer) for profile in profiles],
        "selected": _profile_dict(selected, prefer) if selected else None,
        "role_codes": {role: sorted(codes) for role, codes in role_codes.items()},
        "axis_codes": {key: sorted(codes) for key, codes in _axis_code_map(mapping_config).items()},
        "capture": _capture_dict(capture, mapping_config, role_codes),
        "error": error,
    }


def _profile_dict(profile: DeviceProfile | None, prefer: list[str]) -> dict[str, Any] | None:
    if not profile:
        return None
    return {
        "path": profile.path,
        "name": profile.name,
        "is_controller": profile.is_controller,
        "is_imu": profile.is_imu,
        "prefer_rank": next(
            (i for i, wanted in enumerate(prefer) if wanted.lower() in profile.name.lower()),
            len(prefer) + 10,
        ),
        "key_count": len(profile.keys),
        "axis_count": len(profile.axes),
        "known_keys": {str(code): _key_name(code) for code in sorted(profile.keys) if code in KEY_LABELS},
        "known_axes": sorted(profile.axes),
    }


def _capture_dict(
    capture: CaptureSummary,
    mapping_config: dict[str, Any],
    role_codes: dict[str, set[int]],
) -> dict[str, Any]:
    axis_codes = _axis_code_map(mapping_config)
    return {
        "seconds": capture.seconds,
        "event_count": capture.event_count,
        "roles": {
            role: {
                "label": ROLE_LABELS[role],
                "codes": sorted(role_codes.get(role, set())),
                "seen": bool(capture.role_seen.get(role, False)),
            }
            for role in ROLE_LABELS
        },
        "axes": {
            axis_key: {
                "label": AXIS_LABELS[axis_key],
                "codes": sorted(codes),
                "seen": bool(capture.axis_seen.get(axis_key, False)),
            }
            for axis_key, codes in axis_codes.items()
        },
        "key_events": {str(code): {"label": _key_name(code), "count": count} for code, count in sorted(capture.key_events.items())},
        "axis_events": {
            str(code): {
                "label": _axis_name(code, axis_codes),
                "count": capture.axis_events.get(code, 0),
                "peak": round(capture.axis_peak.get(code, 0.0), 3),
            }
            for code in sorted(capture.axis_events)
        },
    }


def print_human(report: dict[str, Any], strict: bool) -> None:
    level = str(report["level"]).upper()
    print(f"Darwin Switch input check: {level}")
    if strict:
        print("mode: strict")
    print("")
    print(f"devices: {report['device_count']}")
    for profile in report["profiles"]:
        flags = []
        if profile["is_controller"]:
            flags.append("controller")
        if profile["is_imu"]:
            flags.append("IMU skipped")
        flag_text = f" [{' / '.join(flags)}]" if flags else ""
        print(f"- {profile['path']}: {profile['name'] or 'unnamed'}{flag_text}")
        if profile["known_keys"]:
            known = ", ".join(f"{code}={label}" for code, label in profile["known_keys"].items())
            print(f"  keys: {known}")
    selected = report["selected"]
    if selected:
        print("")
        print(f"selected: {selected['path']} ({selected['name'] or 'unnamed'})")
        print("roles:")
        for role, info in report["capture"]["roles"].items():
            codes = ", ".join(f"{code} {_key_name(int(code))}" for code in info["codes"]) or "-"
            seen = "seen" if info["seen"] else "not seen"
            print(f"  - {ROLE_LABELS[role]}: {codes} · {seen}")
        print("axes:")
        for axis_key, info in report["capture"]["axes"].items():
            codes = ", ".join(str(code) for code in info["codes"]) or "-"
            seen = "seen" if info["seen"] else "not seen"
            print(f"  - {AXIS_LABELS[axis_key]}: {codes} · {seen}")
    else:
        print("")
        print("selected: none")
        print("fix: pair Joy-Cons/Pro Controller, combine Joy-Cons with joycond, then rerun.")

    capture = report["capture"]
    if float(capture["seconds"]) > 0:
        print("")
        print(f"capture: {capture['seconds']} sec · {capture['event_count']} raw events")
        if capture["key_events"]:
            print("key events:")
            for code, info in capture["key_events"].items():
                print(f"  - {code} {info['label']}: {info['count']}")
        if capture["axis_events"]:
            print("axis peaks:")
            for code, info in capture["axis_events"].items():
                print(f"  - {code} {info['label']}: peak={info['peak']} count={info['count']}")
    if report.get("error"):
        print("")
        print(f"error: {report['error']}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Read-only Joy-Con/evdev input checker for Darwin Switch")
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="runtime root, used for config fallback")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="agent config path")
    parser.add_argument("--seconds", type=float, default=0.0, help="capture raw input events for N seconds")
    parser.add_argument("--strict", action="store_true", help="exit non-zero on WARN as well as BAD")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON")
    parser.add_argument("--event-glob", action="append", help="override input.event_globs; may be repeated")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.WARNING, format="%(levelname)s: %(message)s")
    root = Path(args.root)
    config = load_config(Path(args.config), root)
    if args.event_glob:
        raw = dict(config.raw)
        input_section = dict(raw.get("input", {}) if isinstance(raw.get("input"), dict) else {})
        input_section["event_globs"] = args.event_glob
        raw["input"] = input_section
        config = AgentConfig(raw)

    report = build_report(config, max(0.0, float(args.seconds)))
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
