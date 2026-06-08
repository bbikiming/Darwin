from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from darwin_switch_agent.native_acceptance import run_native_acceptance


class NativeAcceptanceTests(unittest.TestCase):
    def test_rejects_tilde_identity_for_systemd_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "mode": "ssh",
                        "ssh": {"host": "192.168.0.33", "user": "robotis", "identity_file": "~/.ssh/id_rsa_darwin"},
                        "motion": {
                            "max_stride_mm": 25,
                            "max_side_mm": 14,
                            "max_turn_deg": 18,
                            "max_head_pan_deg": 45,
                            "max_head_tilt_deg": 25,
                            "turn_from_side_ratio": 0.4,
                            "hold_head_position": True,
                            "drive_curve": 1.35,
                        },
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch("darwin_switch_agent.native_acceptance._gtk_check") as gtk, \
                mock.patch("darwin_switch_agent.native_acceptance._launcher_check") as launcher, \
                mock.patch("darwin_switch_agent.native_acceptance._http_json") as http_json:
                gtk.return_value = _good("gtk")
                launcher.return_value = _good("native_launcher")
                http_json.side_effect = [
                    {
                        "ok": True,
                        "json": {
                            "mode": "ssh",
                            "connected": True,
                            "ssh_connected": True,
                            "target": "robotis@192.168.0.33",
                            "input_status": "/dev/input/event8",
                            "command": {"stride_mm": 1.0, "side_mm": 2.0},
                        },
                    },
                    {
                        "ok": True,
                        "json": {
                            "ok": True,
                            "status": {
                                "mode": "walklab",
                                "estop_present": False,
                                "parsed_command": {
                                    "enabled": True,
                                    "stride_mm": 1.0,
                                    "side_mm": 2.0,
                                    "turn_deg": 3.0,
                                    "period_ms": 540,
                                    "foot_mm": 44,
                                    "head_pan_deg": 12.0,
                                    "head_tilt_deg": -5.0,
                                },
                            },
                        },
                    },
                ]

                result = run_native_acceptance(config_path=config_path)

        identity = next(item for item in result["checks"] if item["id"] == "ssh_identity_absolute")
        self.assertEqual(result["level"], "bad")
        self.assertEqual(identity["level"], "bad")

    def test_good_when_state_and_robot_command_have_new_motion_tokens(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path = Path(tmp) / "id_rsa_darwin"
            key_path.write_text("dummy", encoding="utf-8")
            config_path = Path(tmp) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "mode": "ssh",
                        "ssh": {"host": "192.168.0.33", "user": "robotis", "identity_file": str(key_path)},
                        "motion": {
                            "max_stride_mm": 25,
                            "max_side_mm": 14,
                            "max_turn_deg": 18,
                            "max_head_pan_deg": 45,
                            "max_head_tilt_deg": 25,
                            "turn_from_side_ratio": 0.4,
                            "hold_head_position": True,
                            "drive_curve": 1.35,
                        },
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch("darwin_switch_agent.native_acceptance._gtk_check") as gtk, \
                mock.patch("darwin_switch_agent.native_acceptance._launcher_check") as launcher, \
                mock.patch("darwin_switch_agent.native_acceptance._http_json") as http_json:
                gtk.return_value = _good("gtk")
                launcher.return_value = _good("native_launcher")
                http_json.side_effect = [
                    {
                        "ok": True,
                        "json": {
                            "mode": "ssh",
                            "connected": True,
                            "ssh_connected": True,
                            "target": "robotis@192.168.0.33",
                            "input_status": "/dev/input/event8",
                            "command": {"stride_mm": 9.5, "side_mm": -6.0},
                        },
                    },
                    {
                        "ok": True,
                        "json": {
                            "ok": True,
                            "status": {
                                "mode": "walklab",
                                "estop_present": False,
                                "parsed_command": {
                                    "enabled": True,
                                    "stride_mm": 9.5,
                                    "side_mm": -6.0,
                                    "turn_deg": -4.0,
                                    "period_ms": 540,
                                    "foot_mm": 44,
                                    "head_pan_deg": 18.0,
                                    "head_tilt_deg": -6.0,
                                },
                            },
                        },
                    },
                ]

                result = run_native_acceptance(config_path=config_path)

        self.assertEqual(result["level"], "good")
        self.assertTrue(result["ok"])
        check_ids = {item["id"]: item["level"] for item in result["checks"]}
        self.assertEqual(check_ids["robot_side_token"], "good")
        self.assertEqual(check_ids["robot_head_tokens"], "good")

    def test_good_with_actual_robot_command_api_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path = Path(tmp) / "id_rsa_darwin"
            key_path.write_text("dummy", encoding="utf-8")
            config_path = Path(tmp) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "mode": "ssh",
                        "ssh": {"host": "192.168.0.33", "user": "robotis", "identity_file": str(key_path)},
                        "motion": {
                            "max_stride_mm": 25,
                            "max_side_mm": 14,
                            "max_turn_deg": 18,
                            "max_head_pan_deg": 45,
                            "max_head_tilt_deg": 25,
                            "turn_from_side_ratio": 0.4,
                            "hold_head_position": True,
                            "drive_curve": 1.35,
                        },
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch("darwin_switch_agent.native_acceptance._gtk_check") as gtk, \
                mock.patch("darwin_switch_agent.native_acceptance._launcher_check") as launcher, \
                mock.patch("darwin_switch_agent.native_acceptance._http_json") as http_json:
                gtk.return_value = _good("gtk")
                launcher.return_value = _good("native_launcher")
                http_json.side_effect = [
                    _state(stride=9.5, side=-6.0, turn=-4.0, pan=18.0, tilt=-6.0),
                    {
                        "ok": True,
                        "json": {
                            "ok": True,
                            "status": {
                                "mode": "walklab",
                                "estop": False,
                                "raw": "abc 1 9.50 -6.00 -4.00 540 44 13 1.0 0 2 18.00 -6.00 0",
                                "parsed": {
                                    "enabled": True,
                                    "stride_mm": 9.5,
                                    "side_mm": -6.0,
                                    "turn_deg": -4.0,
                                    "period_ms": 540,
                                    "foot_mm": 44,
                                    "head_pan_deg": 18.0,
                                    "head_tilt_deg": -6.0,
                                },
                            },
                        },
                    },
                ]

                result = run_native_acceptance(config_path=config_path)

        self.assertEqual(result["level"], "good")
        check_ids = {item["id"]: item["level"] for item in result["checks"]}
        self.assertEqual(check_ids["robot_command_parse"], "good")
        self.assertEqual(check_ids["robot_side_token"], "good")

    def test_sampling_detects_motion_gait_and_head_variation(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path = Path(tmp) / "id_rsa_darwin"
            key_path.write_text("dummy", encoding="utf-8")
            config_path = Path(tmp) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "mode": "ssh",
                        "ssh": {"host": "192.168.0.33", "user": "robotis", "identity_file": str(key_path)},
                        "motion": {
                            "max_stride_mm": 25,
                            "max_side_mm": 14,
                            "max_turn_deg": 18,
                            "max_head_pan_deg": 45,
                            "max_head_tilt_deg": 25,
                            "turn_from_side_ratio": 0.4,
                            "hold_head_position": True,
                            "drive_curve": 1.35,
                        },
                    }
                ),
                encoding="utf-8",
            )
            responses = [
                _state(stride=0, side=0, turn=0, pan=0, tilt=0),
                _robot(stride=0, side=0, turn=0, period=780, foot=18, pan=0, tilt=0, api_shape="parsed"),
                _state(stride=0, side=0, turn=0, pan=0, tilt=0),
                _robot(stride=0, side=0, turn=0, period=780, foot=18, pan=0, tilt=0, api_shape="parsed"),
                _state(stride=12, side=-5, turn=-2, pan=18, tilt=-5, right_x=0.5, right_y=-0.3),
                _robot(stride=12, side=-5, turn=-2, period=610, foot=33, pan=18, tilt=-5, api_shape="parsed"),
                _state(stride=24, side=-11, turn=-4, pan=18, tilt=-5),
                _robot(stride=24, side=-11, turn=-4, period=520, foot=40, pan=18, tilt=-5, api_shape="parsed"),
            ]

            with mock.patch("darwin_switch_agent.native_acceptance._gtk_check") as gtk, \
                mock.patch("darwin_switch_agent.native_acceptance._launcher_check") as launcher, \
                mock.patch("darwin_switch_agent.native_acceptance._http_json") as http_json, \
                mock.patch("darwin_switch_agent.native_acceptance.time.sleep"):
                gtk.return_value = _good("gtk")
                launcher.return_value = _good("native_launcher")
                http_json.side_effect = responses

                result = run_native_acceptance(
                    config_path=config_path,
                    sample_seconds=0.3,
                    sample_interval=0.1,
                )

        check_ids = {item["id"]: item["level"] for item in result["checks"]}
        self.assertEqual(check_ids["sample_stride_variation"], "good")
        self.assertEqual(check_ids["sample_side_variation"], "good")
        self.assertEqual(check_ids["sample_agent_mapping"], "good")
        self.assertEqual(check_ids["sample_robot_file_propagation"], "good")
        self.assertEqual(check_ids["sample_gait_variation"], "good")
        self.assertEqual(check_ids["sample_head_hold"], "good")
        self.assertGreaterEqual(result["sample_summary"]["robot_period_span"], 90)
        self.assertGreaterEqual(result["sample_summary"]["state_drive_span"], 12)
        self.assertGreaterEqual(result["sample_summary"]["robot_drive_span"], 12)
        self.assertGreaterEqual(result["sample_summary"]["robot_head_hold_count"], 1)

    def test_sampling_warns_when_agent_moves_but_robot_file_does_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            key_path = Path(tmp) / "id_rsa_darwin"
            key_path.write_text("dummy", encoding="utf-8")
            config_path = Path(tmp) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "mode": "ssh",
                        "ssh": {"host": "192.168.0.33", "user": "robotis", "identity_file": str(key_path)},
                        "motion": {
                            "max_stride_mm": 25,
                            "max_side_mm": 14,
                            "max_turn_deg": 18,
                            "max_head_pan_deg": 45,
                            "max_head_tilt_deg": 25,
                            "turn_from_side_ratio": 0.4,
                            "hold_head_position": True,
                            "drive_curve": 1.35,
                        },
                    }
                ),
                encoding="utf-8",
            )
            responses = [
                _state(stride=0, side=0, turn=0, pan=0, tilt=0),
                _robot(stride=0, side=0, turn=0, period=780, foot=18, pan=0, tilt=0, api_shape="parsed"),
                _state(stride=0, side=0, turn=0, pan=0, tilt=0),
                _robot(stride=0, side=0, turn=0, period=780, foot=18, pan=0, tilt=0, api_shape="parsed"),
                _state(stride=20, side=-8, turn=-3, pan=15, tilt=-4),
                _robot(stride=0, side=0, turn=0, period=780, foot=18, pan=0, tilt=0, api_shape="parsed"),
            ]

            with mock.patch("darwin_switch_agent.native_acceptance._gtk_check") as gtk, \
                mock.patch("darwin_switch_agent.native_acceptance._launcher_check") as launcher, \
                mock.patch("darwin_switch_agent.native_acceptance._http_json") as http_json, \
                mock.patch("darwin_switch_agent.native_acceptance.time.sleep"):
                gtk.return_value = _good("gtk")
                launcher.return_value = _good("native_launcher")
                http_json.side_effect = responses

                result = run_native_acceptance(
                    config_path=config_path,
                    sample_seconds=0.2,
                    sample_interval=0.1,
                )

        check_ids = {item["id"]: item["level"] for item in result["checks"]}
        self.assertEqual(check_ids["sample_agent_mapping"], "good")
        self.assertEqual(check_ids["sample_robot_file_propagation"], "warn")
        self.assertGreaterEqual(result["sample_summary"]["state_drive_span"], 20)
        self.assertEqual(result["sample_summary"]["robot_drive_span"], 0.0)


def _good(check_id: str):
    from darwin_switch_agent.native_acceptance import NativeCheck

    return NativeCheck(check_id, "good", check_id, "ok")


def _state(
    *,
    stride: float,
    side: float,
    turn: float,
    pan: float,
    tilt: float,
    right_x: float = 0.0,
    right_y: float = 0.0,
):
    return {
        "ok": True,
        "json": {
            "mode": "ssh",
            "connected": True,
            "ssh_connected": True,
            "target": "robotis@192.168.0.33",
            "input_status": "/dev/input/event8",
            "armed": True,
            "deadman": True,
            "moving": bool(stride or side or turn),
            "controller": {"right_x": right_x, "right_y": right_y},
            "command": {
                "stride_mm": stride,
                "side_mm": side,
                "turn_deg": turn,
                "head_pan_deg": pan,
                "head_tilt_deg": tilt,
            },
        },
    }


def _robot(*, stride: float, side: float, turn: float, period: float, foot: float, pan: float, tilt: float, api_shape: str = "parsed_command"):
    parsed_key = "parsed" if api_shape == "parsed" else "parsed_command"
    return {
        "ok": True,
        "json": {
            "ok": True,
            "status": {
                "mode": "walklab",
                "estop": False,
                "raw": f"abc 1 {stride:.2f} {side:.2f} {turn:.2f} {period:.0f} {foot:.0f} 13 1.0 0 2 {pan:.2f} {tilt:.2f} 0",
                parsed_key: {
                    "enabled": True,
                    "stride_mm": stride,
                    "side_mm": side,
                    "turn_deg": turn,
                    "period_ms": period,
                    "foot_mm": foot,
                    "head_pan_deg": pan,
                    "head_tilt_deg": tilt,
                },
            },
        },
    }


if __name__ == "__main__":
    unittest.main()
