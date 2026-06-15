from __future__ import annotations

import unittest

from darwin_switch_agent.native_cockpit import (
    NativeState,
    RobotCommandStatus,
    acceptance_start_instruction,
    acceptance_ui_summary,
    bar_fraction,
    command_status_from_payload,
    live_control_hint,
    robot_ready_summary,
    state_from_payload,
)


class NativeStateTests(unittest.TestCase):
    def test_state_maps_drive_vector_and_link(self):
        state = state_from_payload(
            {
                "mode": "ssh",
                "target": "robotis@192.168.0.33",
                "connected": False,
                "ssh_connected": True,
                "input_status": "/dev/input/event8",
                "armed": True,
                "deadman": True,
                "moving": True,
                "command": {
                    "stride_mm": 12.5,
                    "side_mm": -7.0,
                    "turn_deg": -3.0,
                    "head_pan_deg": 15.0,
                    "head_tilt_deg": -8.0,
                },
                "controller": {"left_x": -0.5, "left_y": 0.5},
                "logs": ["ready"],
            }
        )
        self.assertTrue(state.link_ok)
        self.assertEqual(state.target, "robotis@192.168.0.33")
        self.assertEqual(state.direction_label, "전진·좌측")
        self.assertGreater(state.drive_speed_pct, 45)
        self.assertEqual(state.logs, ["ready"])

    def test_missing_nested_payload_is_safe(self):
        state = state_from_payload({})
        self.assertFalse(state.link_ok)
        self.assertEqual(state.direction_label, "정지")
        self.assertEqual(state.drive_speed_pct, 0)

    def test_bar_fraction_maps_bipolar_values_to_centered_gauge(self):
        self.assertEqual(bar_fraction(0, 10), 0.5)
        self.assertEqual(bar_fraction(10, 10), 1.0)
        self.assertEqual(bar_fraction(-10, 10), 0.0)
        self.assertEqual(bar_fraction(20, 10), 1.0)
        self.assertEqual(bar_fraction(-20, 10), 0.0)

    def test_bar_fraction_maps_unipolar_values(self):
        self.assertEqual(bar_fraction(0, 100, bipolar=False), 0.0)
        self.assertEqual(bar_fraction(50, 100, bipolar=False), 0.5)
        self.assertEqual(bar_fraction(120, 100, bipolar=False), 1.0)


class NativeRobotCommandStatusTests(unittest.TestCase):
    def test_command_status_summary_from_payload(self):
        status = command_status_from_payload(
            {
                "ok": True,
                "status": {
                    "mode": "walklab",
                    "estop": False,
                    "mtime": 1780819000,
                    "raw": "abc 1 12.50 -7.00 -3.00 621 31 13 1.0 0 2 15.0 -8.0 0",
                    "parsed": {
                        "cmd_id": "abc",
                        "enabled": True,
                        "stride_mm": 12.5,
                        "side_mm": -7.0,
                        "turn_deg": -3.0,
                        "period_ms": 621,
                        "foot_mm": 31,
                        "head_pan_deg": 15.0,
                        "head_tilt_deg": -8.0,
                    },
                },
            }
        )
        self.assertTrue(status.ok)
        self.assertEqual(status.mode, "walklab")
        self.assertEqual(status.summary, "ON x=12.5 y=-7.0 a=-3.0 p=621 f=31")
        self.assertEqual(status.head_pan_deg, 15.0)
        self.assertEqual(status.head_tilt_deg, -8.0)

    def test_command_status_accepts_parsed_command_shape(self):
        status = command_status_from_payload(
            {
                "ok": True,
                "status": {
                    "mode": "walklab",
                    "estop_present": False,
                    "raw_command": "abc 1 9.00 4.00 2.00 700 20 13 1.0 0 2 22.0 -6.0 0",
                    "parsed_command": {
                        "cmd_id": "abc",
                        "enabled": True,
                        "stride_mm": 9.0,
                        "side_mm": 4.0,
                        "turn_deg": 2.0,
                        "period_ms": 700,
                        "foot_mm": 20,
                        "head_pan_deg": 22.0,
                        "head_tilt_deg": -6.0,
                    },
                },
            }
        )
        self.assertTrue(status.ok)
        self.assertFalse(status.estop)
        self.assertEqual(status.raw, "abc 1 9.00 4.00 2.00 700 20 13 1.0 0 2 22.0 -6.0 0")
        self.assertEqual(status.summary, "ON x=9.0 y=4.0 a=2.0 p=700 f=20")
        self.assertEqual(status.head_pan_deg, 22.0)
        self.assertEqual(status.head_tilt_deg, -6.0)

    def test_command_status_error_is_human_readable(self):
        status = command_status_from_payload({"ok": False, "error": "mode is not ssh"})
        self.assertFalse(status.ok)
        self.assertEqual(status.summary, "mode is not ssh")


class NativeRobotReadySummaryTests(unittest.TestCase):
    def test_success_summary_uses_stdout_tail(self):
        summary = robot_ready_summary(
            {
                "ok": True,
                "action": "status",
                "stdout": "line one\nRobot SSH auth: OK\n",
            }
        )
        self.assertEqual(summary, "status: OK · Robot SSH auth: OK")

    def test_failure_summary_prefers_error(self):
        summary = robot_ready_summary(
            {
                "ok": False,
                "action": "start-walklab",
                "error": "timeout",
                "stderr": "ignored",
            }
        )
        self.assertEqual(summary, "start-walklab: 실패 · timeout")


class NativeAcceptanceSummaryTests(unittest.TestCase):
    def _ready_state(self, **overrides):
        fields = {
            "mode": "ssh",
            "target": "robotis@192.168.0.33",
            "connected": False,
            "ssh_connected": True,
            "input_status": "/dev/input/event8",
            "armed": True,
            "deadman": True,
            "estopped": False,
            "moving": True,
            "stride_mm": 12.0,
            "side_mm": -4.0,
            "turn_deg": -2.0,
            "head_pan_deg": 14.0,
            "head_tilt_deg": -4.0,
            "left_x": -0.4,
            "left_y": 0.6,
            "right_x": 0.0,
            "right_y": 0.0,
            "latency_ms": 20,
            "battery_pct": None,
            "watchdog_label": "OK",
            "logs": [],
        }
        fields.update(overrides)
        return NativeState(**fields)

    def test_live_control_hint_warns_when_agent_moves_but_robot_file_does_not(self):
        state = self._ready_state(stride_mm=20.0)
        robot = RobotCommandStatus(
            ok=True,
            mode="walklab",
            estop=False,
            enabled=True,
            stride_mm=0.0,
            side_mm=0.0,
            turn_deg=0.0,
            period_ms=780,
            foot_mm=18,
            head_pan_deg=0.0,
            head_tilt_deg=0.0,
        )

        level, text = live_control_hint(state, robot)

        self.assertEqual(level, "warn")
        self.assertIn("agent 입력만 변함", text)

    def test_live_control_hint_reports_ok_when_robot_file_tracks_agent(self):
        state = self._ready_state(stride_mm=20.0, side_mm=-8.0, turn_deg=-4.0)
        robot = RobotCommandStatus(
            ok=True,
            mode="walklab",
            estop=False,
            enabled=True,
            stride_mm=19.0,
            side_mm=-8.0,
            turn_deg=-4.0,
            period_ms=540,
            foot_mm=36,
            head_pan_deg=14.0,
            head_tilt_deg=-4.0,
        )

        level, text = live_control_hint(state, robot)

        self.assertEqual(level, "ok")
        self.assertIn("조종 경로 정상", text)

    def test_live_control_hint_warns_when_head_hold_not_in_robot_file(self):
        state = self._ready_state(stride_mm=0.0, side_mm=0.0, turn_deg=0.0, head_pan_deg=18.0, head_tilt_deg=-5.0)
        robot = RobotCommandStatus(
            ok=True,
            mode="walklab",
            estop=False,
            enabled=False,
            stride_mm=0.0,
            side_mm=0.0,
            turn_deg=0.0,
            period_ms=780,
            foot_mm=18,
            head_pan_deg=0.0,
            head_tilt_deg=0.0,
        )

        level, text = live_control_hint(state, robot)

        self.assertEqual(level, "warn")
        self.assertIn("머리 유지값", text)

    def test_acceptance_start_instruction_lists_missing_control_conditions(self):
        state = NativeState(
            mode="ssh",
            target="robotis@192.168.0.33",
            connected=False,
            ssh_connected=True,
            input_status="/dev/input/event8",
            armed=False,
            deadman=False,
            estopped=False,
            moving=False,
            stride_mm=0,
            side_mm=0,
            turn_deg=0,
            head_pan_deg=0,
            head_tilt_deg=0,
            left_x=0,
            left_y=0,
            right_x=0,
            right_y=0,
            latency_ms=None,
            battery_pct=None,
            watchdog_label="로봇 정지 5s",
            logs=[],
        )
        status = RobotCommandStatus(ok=True, mode="idle", estop=False)

        text = acceptance_start_instruction(state, status)

        self.assertIn("A 조종 시작", text)
        self.assertIn("WalkLab 시작", text)
        self.assertIn("왼쪽 스틱을 약/강/좌우", text)

    def test_acceptance_start_instruction_ready_drill_mentions_head_hold(self):
        state = NativeState(
            mode="ssh",
            target="robotis@192.168.0.33",
            connected=False,
            ssh_connected=True,
            input_status="/dev/input/event8",
            armed=True,
            deadman=True,
            estopped=False,
            moving=True,
            stride_mm=0,
            side_mm=0,
            turn_deg=0,
            head_pan_deg=14,
            head_tilt_deg=-4,
            left_x=0,
            left_y=0,
            right_x=0,
            right_y=0,
            latency_ms=20,
            battery_pct=None,
            watchdog_label="OK",
            logs=[],
        )
        status = RobotCommandStatus(ok=True, mode="walklab", estop=False)

        text = acceptance_start_instruction(state, status)

        self.assertTrue(text.startswith("6초 측정 중"))
        self.assertIn("오른쪽 스틱을 움직였다 놓으세요", text)

    def test_acceptance_summary_surfaces_first_warning_fix(self):
        label, status = acceptance_ui_summary(
            {
                "level": "warn",
                "sample_summary": {
                    "state_drive_span": 20.0,
                    "robot_drive_span": 0.0,
                    "robot_period_span": 0.0,
                },
                "checks": [
                    {"level": "good", "title": "State", "detail": "ok"},
                    {
                        "level": "warn",
                        "title": "Sample agent to robot file propagation",
                        "detail": "state_drive=20.00, robot_drive=0.00",
                        "fix": "SSH write, 권한, WalkLab 파일 경로를 확인하세요.",
                    },
                ],
            }
        )
        self.assertEqual(label, "WARN · agentΔ 20.0 robotΔ 0.0 periodΔ 0")
        self.assertIn("Sample agent to robot file propagation", status)
        self.assertIn("SSH write", status)

    def test_acceptance_summary_good_has_clear_success_message(self):
        label, status = acceptance_ui_summary(
            {
                "level": "good",
                "sample_summary": {
                    "state_drive_span": 22.0,
                    "robot_drive_span": 21.0,
                    "robot_period_span": 120.0,
                },
                "checks": [{"level": "good", "title": "ok", "detail": "ok"}],
            }
        )
        self.assertEqual(label, "GOOD · agentΔ 22.0 robotΔ 21.0 periodΔ 120")
        self.assertIn("조종 검증 통과", status)


if __name__ == "__main__":
    unittest.main()
