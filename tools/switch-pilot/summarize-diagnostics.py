#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tarfile
import tempfile
from pathlib import Path
from typing import Any


LEVEL_ORDER = {"good": 0, "warn": 1, "bad": 2}


def load_diagnostics(path: Path) -> dict[str, str]:
    if path.is_dir():
        root = _diagnostics_root(path)
        return {
            item.relative_to(root).as_posix(): item.read_text(encoding="utf-8", errors="replace")
            for item in root.rglob("*")
            if item.is_file()
        }
    if tarfile.is_tarfile(path):
        out: dict[str, str] = {}
        with tarfile.open(path, "r:*") as tf:
            root_name = _tar_root_name(tf.getnames())
            for member in tf.getmembers():
                if not member.isfile():
                    continue
                name = _tar_member_key(member.name, root_name)
                fp = tf.extractfile(member)
                if fp is None:
                    continue
                out[name] = fp.read().decode("utf-8", "replace")
        return out
    raise SystemExit(f"ERROR: not a diagnostics directory or tarball: {path}")


def _diagnostics_root(path: Path) -> Path:
    if (path / "summary.txt").is_file():
        return path
    children = [item for item in path.iterdir() if item.is_dir() and item.name.startswith("darwin-switch-diagnostics-")]
    if len(children) == 1:
        return children[0]
    return path


def _tar_root_name(names: list[str]) -> str:
    roots = {name.split("/", 1)[0] for name in names if name}
    diagnostics = [name for name in roots if name.startswith("darwin-switch-diagnostics-")]
    if len(diagnostics) == 1:
        return diagnostics[0]
    return ""


def _tar_member_key(name: str, root_name: str) -> str:
    if root_name and name.startswith(f"{root_name}/"):
        return name[len(root_name) + 1 :]
    return Path(name).name


def parse_kv(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def parse_json_capture(text: str | None) -> dict[str, Any] | None:
    if not text:
        return None
    start = text.find("{")
    if start < 0:
        return None
    try:
        data, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def build_summary(files: dict[str, str], source: str) -> dict[str, Any]:
    summary = parse_kv(files.get("summary.txt", ""))
    preflight = parse_json_capture(files.get("preflight-json.txt"))
    input_check = parse_json_capture(files.get("input-check-json.txt"))
    network = parse_json_capture(files.get("network-check-json.txt"))
    native = parse_json_capture(files.get("native-acceptance-json.txt"))
    cockpit_state = parse_json_capture(files.get("cockpit-api-state.txt"))
    robot_command = parse_json_capture(files.get("cockpit-api-robot-command.txt"))

    report = {
        "source": source,
        "created_at": summary.get("created_at", ""),
        "root": summary.get("root", ""),
        "config": summary.get("config", ""),
        "kernel": summary.get("kernel", ""),
        "preflight": summarize_checks(preflight),
        "input": summarize_input(input_check),
        "network": summarize_checks(network),
        "native": summarize_checks(native),
        "cockpit_api": summarize_cockpit_api(cockpit_state, robot_command),
        "install_evidence": summarize_install_evidence(files),
        "present_files": sorted(files),
    }
    report["overall_level"] = overall_level(report)
    return report


def summarize_checks(data: dict[str, Any] | None) -> dict[str, Any]:
    if not data:
        return {"level": "missing", "bad": [], "warn": [], "good_count": 0, "sample_summary": {}}
    checks = data.get("checks", [])
    if not isinstance(checks, list):
        checks = []
    bad = [check_line(item) for item in checks if item.get("level") == "bad"]
    warn = [check_line(item) for item in checks if item.get("level") == "warn"]
    good = [item for item in checks if item.get("level") == "good"]
    return {
        "level": str(data.get("level", "warn")),
        "bad": bad,
        "warn": warn,
        "good_count": len(good),
        "mode": data.get("mode", ""),
        "sample_summary": summarize_sample_summary(data.get("sample_summary")),
    }


def summarize_sample_summary(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict):
        return {}
    state_drive = _float_or_zero(data.get("state_drive_span"))
    robot_drive = _float_or_zero(data.get("robot_drive_span"))
    period = _float_or_zero(data.get("robot_period_span"))
    return {
        "state_drive_span": state_drive,
        "robot_drive_span": robot_drive,
        "robot_period_span": period,
        "robot_foot_span": _float_or_zero(data.get("robot_foot_span")),
        "robot_head_nonzero_count": int(data.get("robot_head_nonzero_count", 0) or 0),
        "robot_head_hold_count": int(data.get("robot_head_hold_count", 0) or 0),
        "propagation": propagation_label(state_drive, robot_drive),
        "speed_variable": period >= 20.0 or _float_or_zero(data.get("robot_foot_span")) >= 3.0,
        "head_hold": int(data.get("robot_head_hold_count", 0) or 0) > 0,
    }


def propagation_label(state_drive: float, robot_drive: float) -> str:
    if state_drive < 2.0 and robot_drive < 2.0:
        return "no_agent_motion"
    if state_drive >= 2.0 and robot_drive < max(1.5, state_drive * 0.45):
        return "agent_only"
    if robot_drive >= 2.0:
        return "agent_to_robot"
    return "unknown"


def _float_or_zero(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def check_line(item: dict[str, Any]) -> dict[str, str]:
    return {
        "id": str(item.get("id", "")),
        "title": str(item.get("title", "")),
        "detail": str(item.get("detail", "")),
        "fix": str(item.get("fix", "")),
    }


def summarize_input(data: dict[str, Any] | None) -> dict[str, Any]:
    if not data:
        return {"level": "missing", "selected": "", "device_count": 0, "missing_roles": [], "missing_axes": [], "error": ""}
    selected = data.get("selected") or {}
    capture = data.get("capture") or {}
    roles = capture.get("roles") if isinstance(capture, dict) else {}
    axes = capture.get("axes") if isinstance(capture, dict) else {}
    missing_roles = [str(item.get("label", key)) for key, item in (roles or {}).items() if not item.get("seen")]
    missing_axes = [str(item.get("label", key)) for key, item in (axes or {}).items() if not item.get("seen")]
    selected_label = ""
    if isinstance(selected, dict) and selected:
        selected_label = f"{selected.get('name', '')} ({selected.get('path', '')})"
    return {
        "level": str(data.get("level", "warn")),
        "selected": selected_label,
        "device_count": int(data.get("device_count", 0) or 0),
        "missing_roles": missing_roles,
        "missing_axes": missing_axes,
        "error": str(data.get("error", "")),
    }


def summarize_cockpit_api(state: dict[str, Any] | None, robot_command: dict[str, Any] | None) -> dict[str, Any]:
    command = state.get("command") if isinstance(state, dict) and isinstance(state.get("command"), dict) else {}
    controller = state.get("controller") if isinstance(state, dict) and isinstance(state.get("controller"), dict) else {}
    robot_status = robot_command.get("status") if isinstance(robot_command, dict) and isinstance(robot_command.get("status"), dict) else {}
    parsed = robot_status.get("parsed") if isinstance(robot_status.get("parsed"), dict) else {}
    if not parsed:
        parsed = robot_status.get("parsed_command") if isinstance(robot_status.get("parsed_command"), dict) else {}
    state_ok = isinstance(state, dict) and bool(state)
    robot_ok = isinstance(robot_command, dict) and bool(robot_command.get("ok"))
    level = "good" if state_ok and robot_ok else ("warn" if state_ok or robot_ok else "missing")
    return {
        "level": level,
        "mode": str(state.get("mode", "")) if isinstance(state, dict) else "",
        "target": str(state.get("target", "")) if isinstance(state, dict) else "",
        "connected": bool(state.get("connected", False)) if isinstance(state, dict) else False,
        "ssh_connected": bool(state.get("ssh_connected", False)) if isinstance(state, dict) else False,
        "input_status": str(state.get("input_status", "")) if isinstance(state, dict) else "",
        "controller": {
            "left_x": controller.get("left_x"),
            "left_y": controller.get("left_y"),
            "right_x": controller.get("right_x"),
            "right_y": controller.get("right_y"),
        },
        "command": {
            "stride_mm": command.get("stride_mm"),
            "side_mm": command.get("side_mm"),
            "turn_deg": command.get("turn_deg"),
            "head_pan_deg": command.get("head_pan_deg"),
            "head_tilt_deg": command.get("head_tilt_deg"),
        },
        "robot_command_ok": robot_ok,
        "robot_mode": str(robot_status.get("mode", "")),
        "robot_parsed": {
            "enabled": parsed.get("enabled"),
            "stride_mm": parsed.get("stride_mm"),
            "side_mm": parsed.get("side_mm"),
            "turn_deg": parsed.get("turn_deg"),
            "period_ms": parsed.get("period_ms"),
            "foot_mm": parsed.get("foot_mm"),
            "head_pan_deg": parsed.get("head_pan_deg"),
            "head_tilt_deg": parsed.get("head_tilt_deg"),
        },
    }


def overall_level(report: dict[str, Any]) -> str:
    levels = []
    for key in ("preflight", "input", "network", "native", "cockpit_api"):
        level = report[key].get("level", "missing")
        if level != "missing":
            levels.append(str(level))
    if not levels:
        return "missing"
    return max(levels, key=lambda level: LEVEL_ORDER.get(level, 1))


def summarize_install_evidence(files: dict[str, str]) -> dict[str, Any]:
    install_logs = sorted(name for name in files if name.startswith("install-logs/") and name.endswith(".log"))
    manifests = sorted(name for name in files if name.startswith("install-kit/") and name.endswith("manifest.json"))
    bootstrap_logs = sorted(name for name in files if name.startswith("bootstrap-logs/") and "bootstrap.log" in name)
    launcher_logs = sorted(name for name in files if name.startswith("launcher-logs/") and "launcher.log" in name)
    return {
        "install_logs": install_logs,
        "manifest_files": manifests,
        "bootstrap_logs": bootstrap_logs,
        "launcher_logs": launcher_logs,
        "has_install_log": bool(install_logs),
        "has_manifest": bool(manifests),
        "has_bootstrap_log": bool(bootstrap_logs),
        "has_launcher_log": bool(launcher_logs),
    }


def print_human(report: dict[str, Any]) -> None:
    print(f"Darwin Switch diagnostics: {report['overall_level'].upper()}")
    print(f"source: {report['source']}")
    if report.get("created_at"):
        print(f"created: {report['created_at']}")
    if report.get("kernel"):
        print(f"kernel: {report['kernel']}")
    print("")
    print_check_section("Preflight", report["preflight"])
    print_input_section(report["input"])
    print_check_section("Network", report["network"])
    print_check_section("Native", report["native"])
    print_cockpit_api_section(report["cockpit_api"])
    print_install_evidence(report["install_evidence"])


def print_check_section(title: str, data: dict[str, Any]) -> None:
    print(f"{title}: {str(data.get('level', 'missing')).upper()}")
    sample = data.get("sample_summary", {})
    if sample:
        print(
            "  sample: "
            f"agentΔ={sample.get('state_drive_span', 0):.1f} "
            f"robotΔ={sample.get('robot_drive_span', 0):.1f} "
            f"periodΔ={sample.get('robot_period_span', 0):.0f} "
            f"speedVar={sample.get('speed_variable', False)} "
            f"headHold={sample.get('head_hold', False)} "
            f"propagation={sample.get('propagation', '-')}"
        )
    for label in ("bad", "warn"):
        items = data.get(label, [])
        if not items:
            continue
        print(f"  {label.upper()}:")
        for item in items:
            print(f"  - {item['title']}: {item['detail']}")
            if item.get("fix"):
                print(f"    fix: {item['fix']}")
    if not data.get("bad") and not data.get("warn") and data.get("good_count"):
        print(f"  OK checks: {data['good_count']}")


def print_input_section(data: dict[str, Any]) -> None:
    print(f"Input: {str(data.get('level', 'missing')).upper()}")
    if data.get("selected"):
        print(f"  selected: {data['selected']}")
    else:
        print(f"  selected: none (devices={data.get('device_count', 0)})")
    if data.get("error"):
        print(f"  error: {data['error']}")
    for key, label in (("missing_roles", "missing roles"), ("missing_axes", "missing axes")):
        values = data.get(key, [])
        if values:
            print(f"  {label}: {', '.join(values)}")


def print_cockpit_api_section(data: dict[str, Any]) -> None:
    print(f"Cockpit API: {str(data.get('level', 'missing')).upper()}")
    if data.get("level") == "missing":
        return
    print(f"  mode: {data.get('mode') or '-'}")
    print(f"  target: {data.get('target') or '-'}")
    print(f"  connected: {data.get('connected')} / ssh={data.get('ssh_connected')}")
    print(f"  input: {data.get('input_status') or '-'}")
    command = data.get("command", {})
    robot = data.get("robot_parsed", {})
    print(
        "  command: "
        f"x={command.get('stride_mm')} y={command.get('side_mm')} "
        f"a={command.get('turn_deg')} head=({command.get('head_pan_deg')},{command.get('head_tilt_deg')})"
    )
    print(
        "  robot file: "
        f"ok={data.get('robot_command_ok')} mode={data.get('robot_mode') or '-'} "
        f"x={robot.get('stride_mm')} y={robot.get('side_mm')} "
        f"p={robot.get('period_ms')} f={robot.get('foot_mm')}"
    )


def print_install_evidence(data: dict[str, Any]) -> None:
    print("Install evidence:")
    logs = data.get("install_logs", [])
    manifests = data.get("manifest_files", [])
    bootstrap_logs = data.get("bootstrap_logs", [])
    launcher_logs = data.get("launcher_logs", [])
    print(f"  logs: {', '.join(logs) if logs else 'none'}")
    print(f"  manifests: {', '.join(manifests) if manifests else 'none'}")
    print(f"  bootstrap logs: {', '.join(bootstrap_logs) if bootstrap_logs else 'none'}")
    print(f"  launcher logs: {', '.join(launcher_logs) if launcher_logs else 'none'}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Summarize a Darwin Switch diagnostics tarball or extracted directory")
    parser.add_argument("diagnostics", help="darwin-switch-diagnostics-*.tar.gz or extracted diagnostics directory")
    parser.add_argument("--json", action="store_true", help="print machine-readable JSON summary")
    args = parser.parse_args(argv)

    path = Path(args.diagnostics)
    files = load_diagnostics(path)
    report = build_summary(files, str(path))
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_human(report)
    return 2 if report["overall_level"] == "bad" else 0


if __name__ == "__main__":
    raise SystemExit(main())
