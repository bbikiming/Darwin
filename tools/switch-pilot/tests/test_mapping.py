"""Unit tests for ControllerMapper (stick/buttons -> MotionCommand).

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_mapping.py

Asserts the control contract: A/armed gating happens after mapping, so sticks
can produce a command without ZL/ZR; ZL/ZR request in-place walking; left/right
directions are intentionally inverted to match the robot; and head pan/tilt
track the right stick regardless of walking input.
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.input_linux import BTN_TL, BTN_TR, ControllerState
from darwin_switch_agent.mapping import ControllerMapper


MOTION = {
    "max_stride_mm": 25.0,
    "max_side_mm": 14.0,
    "max_turn_deg": 12.0,
    "turn_from_side_ratio": 0.35,
    "max_head_pan_deg": 70.0,
    "max_head_tilt_deg": 35.0,
    "hold_head_position": True,
    "speed_scale": 0.8,
}
MAPPING = {"deadzone": 0.12}


def _mapper(mapping=None, motion=None):
    return ControllerMapper(mapping or dict(MAPPING), motion or dict(MOTION))


class EnableIntentTests(unittest.TestCase):
    def test_no_input_disables_walk(self):
        cmd = _mapper().map(ControllerState())
        self.assertFalse(cmd.enabled)
        self.assertEqual(cmd.stride_mm, 0.0)

    def test_stick_enables_command_without_zl_zr(self):
        cmd = _mapper().map(ControllerState(left_y=1.0, left_x=1.0, deadman=False))
        self.assertTrue(cmd.enabled)
        self.assertNotEqual(cmd.stride_mm, 0.0)
        self.assertNotEqual(cmd.side_mm, 0.0)
        self.assertNotEqual(cmd.turn_deg, 0.0)

    def test_zl_zr_request_in_place_walk(self):
        cmd = _mapper().map(ControllerState(left_y=1.0, left_x=1.0, deadman=True))
        self.assertTrue(cmd.enabled)
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertEqual(cmd.side_mm, 0.0)
        self.assertEqual(cmd.turn_deg, 0.0)


class DirectionalMotionTests(unittest.TestCase):
    def test_full_stick_reaches_max_stride(self):
        cmd = _mapper().map(ControllerState(left_y=1.0))
        self.assertAlmostEqual(cmd.stride_mm, MOTION["max_stride_mm"], places=6)

    def test_full_negative_x_reaches_inverted_side_and_coupled_turn(self):
        cmd = _mapper().map(ControllerState(left_x=-1.0))
        self.assertAlmostEqual(cmd.side_mm, MOTION["max_side_mm"], places=6)
        self.assertAlmostEqual(
            cmd.turn_deg,
            MOTION["max_turn_deg"] * MOTION["turn_from_side_ratio"],
            places=6,
        )

    def test_l_button_turns_inverted_right_without_side_motion(self):
        cmd = _mapper().map(
            ControllerState(raw_keys={BTN_TL: True})
        )
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertEqual(cmd.side_mm, 0.0)
        self.assertAlmostEqual(cmd.turn_deg, MOTION["max_turn_deg"], places=6)

    def test_r_button_turns_inverted_left_without_side_motion(self):
        cmd = _mapper().map(
            ControllerState(raw_keys={BTN_TR: True})
        )
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertEqual(cmd.side_mm, 0.0)
        self.assertAlmostEqual(cmd.turn_deg, -MOTION["max_turn_deg"], places=6)

    def test_l_and_r_pressed_together_cancel_turn(self):
        cmd = _mapper().map(
            ControllerState(raw_keys={BTN_TL: True, BTN_TR: True})
        )
        self.assertEqual(cmd.turn_deg, 0.0)


class DeadzoneTests(unittest.TestCase):
    def test_inside_deadzone_is_zero(self):
        cmd = _mapper().map(ControllerState(left_y=0.11, left_x=-0.05))
        self.assertFalse(cmd.enabled)
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertEqual(cmd.side_mm, 0.0)
        self.assertEqual(cmd.turn_deg, 0.0)

    def test_at_deadzone_edge_is_zero(self):
        # abs(value) < deadzone is the snap rule; exactly == deadzone is NOT zeroed.
        cmd = _mapper().map(ControllerState(left_y=0.119))
        self.assertEqual(cmd.stride_mm, 0.0)

    def test_just_outside_deadzone_is_nonzero(self):
        cmd = _mapper().map(ControllerState(left_y=0.5))
        self.assertGreater(cmd.stride_mm, 0.0)


class ClampTests(unittest.TestCase):
    def test_overdriven_stick_clamps_to_max(self):
        # A controller axis that over-ranges past 1.0 must not exceed the max.
        cmd = _mapper().map(ControllerState(left_y=5.0, left_x=-5.0))
        self.assertAlmostEqual(cmd.stride_mm, MOTION["max_stride_mm"], places=6)
        self.assertAlmostEqual(cmd.side_mm, MOTION["max_side_mm"], places=6)
        self.assertAlmostEqual(
            cmd.turn_deg,
            MOTION["max_turn_deg"] * MOTION["turn_from_side_ratio"],
            places=6,
        )

    def test_speed_scale_clamped_into_band(self):
        cmd = _mapper(motion={**MOTION, "speed_scale": 9.0}).map(
            ControllerState(deadman=True)
        )
        self.assertEqual(cmd.speed_scale, 1.5)
        cmd_lo = _mapper(motion={**MOTION, "speed_scale": 0.0}).map(
            ControllerState(deadman=True)
        )
        self.assertEqual(cmd_lo.speed_scale, 0.5)


class HeadAimTests(unittest.TestCase):
    def test_head_tracks_right_stick_without_deadman(self):
        cmd = _mapper().map(
            ControllerState(right_x=1.0, right_y=-1.0, deadman=False)
        )
        self.assertAlmostEqual(cmd.head_pan_deg, MOTION["max_head_pan_deg"], places=6)
        self.assertAlmostEqual(
            cmd.head_tilt_deg, -MOTION["max_head_tilt_deg"], places=6
        )

    def test_head_tracks_right_stick_with_deadman(self):
        cmd = _mapper().map(ControllerState(right_x=1.0, deadman=True))
        self.assertAlmostEqual(cmd.head_pan_deg, MOTION["max_head_pan_deg"], places=6)

    def test_head_holds_last_position_after_stick_release(self):
        mapper = _mapper()
        first = mapper.map(ControllerState(right_x=0.5, right_y=-0.5, deadman=False))
        released = mapper.map(ControllerState(right_x=0.0, right_y=0.0, deadman=False))
        self.assertEqual(released.head_pan_deg, first.head_pan_deg)
        self.assertEqual(released.head_tilt_deg, first.head_tilt_deg)

    def test_head_can_return_to_zero_when_hold_disabled(self):
        mapper = _mapper(motion={**MOTION, "hold_head_position": False})
        mapper.map(ControllerState(right_x=0.5, deadman=False))
        released = mapper.map(ControllerState(right_x=0.0, deadman=False))
        self.assertEqual(released.head_pan_deg, 0.0)


class RunningProfileTests(unittest.TestCase):
    """2026-06-08 — 빠른 보행 프로파일(config.example.json baseline) 검증.

    자이로 안정 확인 후 ROBOTIS 안전 마진 안에서 한도를 +30~50% 올린 baseline 이
    mapper 로 정확히 흘러들어가는지 못 박는다. 한도가 의도와 다르게 적용되면 사용자가
    안전 마진을 잃을 위험.
    """

    RUNNING_MOTION = {
        "max_stride_mm": 50.0,
        "max_side_mm": 26.0,
        "max_turn_deg": 18.0,
        "turn_from_side_ratio": 0.75,
        "max_head_pan_deg": 70.0,
        "max_head_tilt_deg": 35.0,
        "max_head_tilt_up_deg": 55.0,
        "max_head_tilt_down_deg": 35.0,
        "hold_head_position": True,
        "drive_curve": 1.35,
        "speed_scale": 0.8,
    }

    def test_running_profile_full_stick_reaches_new_max_stride(self):
        m = _mapper(motion=dict(self.RUNNING_MOTION))
        cmd = m.map(ControllerState(left_y=1.0))
        # max_stride 50mm — Walking 엔진 안전 상한(~55) 안.
        self.assertAlmostEqual(cmd.stride_mm, 50.0, places=6)

    def test_running_profile_turn_at_new_max(self):
        m = _mapper(motion=dict(self.RUNNING_MOTION))
        cmd = m.map(ControllerState(raw_keys={BTN_TL: True}))
        self.assertAlmostEqual(cmd.turn_deg, 18.0, places=6)

    def test_running_profile_side_at_new_max(self):
        m = _mapper(motion=dict(self.RUNNING_MOTION))
        cmd = m.map(ControllerState(left_x=-1.0))
        self.assertAlmostEqual(cmd.side_mm, 26.0, places=6)

    def test_running_profile_overdriven_stick_clamped(self):
        # 5.0 같은 over-range 가 들어와도 새 max 를 안 넘는다 (안전 클램프).
        m = _mapper(motion=dict(self.RUNNING_MOTION))
        cmd = m.map(ControllerState(left_y=5.0, left_x=-5.0))
        self.assertAlmostEqual(cmd.stride_mm, 50.0, places=6)
        self.assertAlmostEqual(cmd.side_mm, 26.0, places=6)

    def test_running_profile_drive_curve_makes_small_stick_gentle(self):
        # drive_curve=1.35 → 작은 stick(0.3) 입력은 max 의 0.3^1.35≈0.21 → 약 21%
        # → 사용자가 stick 살짝만 기울이면 천천히, 끝까지 밀면 풀스피드.
        m = _mapper(motion=dict(self.RUNNING_MOTION))
        cmd = m.map(ControllerState(left_y=0.3))
        # deadzone 0.12 적용 → normalized = (0.3-0.12)/(1-0.12) ≈ 0.2045
        # → 0.2045^1.35 ≈ 0.122 → stride ≈ 0.122 * 50 ≈ 6.1mm
        self.assertLess(abs(cmd.stride_mm), 10.0,
                        "drive_curve 가 작은 stick 입력에서 보행을 부드럽게 해야 함")


class AsymmetricHeadTiltTests(unittest.TestCase):
    """2026-06-08 — 머리 들기(+tilt)와 숙이기(-tilt) 에 다른 한도 적용."""

    def test_tilt_up_uses_extended_limit(self):
        # right_y=+1 (after invert) → 머리 들기. max_head_tilt_up_deg 까지 허용.
        m = _mapper(motion={**MOTION, "max_head_tilt_up_deg": 55.0, "max_head_tilt_down_deg": 35.0})
        cmd = m.map(ControllerState(right_y=1.0, deadman=False))
        self.assertAlmostEqual(cmd.head_tilt_deg, 55.0, places=6)

    def test_tilt_down_uses_separate_limit(self):
        m = _mapper(motion={**MOTION, "max_head_tilt_up_deg": 55.0, "max_head_tilt_down_deg": 35.0})
        cmd = m.map(ControllerState(right_y=-1.0, deadman=False))
        self.assertAlmostEqual(cmd.head_tilt_deg, -35.0, places=6,
                               msg="머리 숙이기 한도는 기존(-35)으로 유지 — 비대칭 효과")

    def test_tilt_falls_back_to_symmetric_when_keys_missing(self):
        # max_head_tilt_up_deg 가 없으면 기존 max_head_tilt_deg(=35) 로 대칭 (호환).
        m = _mapper()  # MOTION 에 새 키 없음
        cmd_up = m.map(ControllerState(right_y=1.0, deadman=False))
        cmd_dn = m.map(ControllerState(right_y=-1.0, deadman=False))
        self.assertAlmostEqual(cmd_up.head_tilt_deg, 35.0, places=6)
        self.assertAlmostEqual(cmd_dn.head_tilt_deg, -35.0, places=6)

    def test_tilt_overdriven_clamps_to_asymmetric_limits(self):
        # stick 이 +1 을 넘어가도 새 한도 초과 안 함.
        m = _mapper(motion={**MOTION, "max_head_tilt_up_deg": 55.0, "max_head_tilt_down_deg": 35.0})
        cmd_over_up = m.map(ControllerState(right_y=5.0, deadman=False))
        cmd_over_dn = m.map(ControllerState(right_y=-5.0, deadman=False))
        self.assertAlmostEqual(cmd_over_up.head_tilt_deg, 55.0, places=6)
        self.assertAlmostEqual(cmd_over_dn.head_tilt_deg, -35.0, places=6)


if __name__ == "__main__":
    unittest.main()
