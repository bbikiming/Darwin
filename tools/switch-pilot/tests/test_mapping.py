"""Unit tests for ControllerMapper (stick -> MotionCommand).

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_mapping.py

Asserts the safety-relevant mapping contract: no deadman -> no walk motion at
all; full-stick deadman -> exactly the configured max stride; deadzone snaps
small inputs to zero; values clamp at the configured maxima; and head pan/tilt
track the right stick regardless of deadman (head aim is not gated).
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.input_linux import ControllerState
from darwin_switch_agent.mapping import ControllerMapper


MOTION = {
    "max_stride_mm": 25.0,
    "max_turn_deg": 12.0,
    "max_head_pan_deg": 70.0,
    "max_head_tilt_deg": 35.0,
    "speed_scale": 0.8,
}
MAPPING = {"deadzone": 0.12}


def _mapper(mapping=None, motion=None):
    return ControllerMapper(mapping or dict(MAPPING), motion or dict(MOTION))


class DeadmanGateTests(unittest.TestCase):
    def test_no_deadman_zeroes_walk_motion(self):
        cmd = _mapper().map(ControllerState(left_y=1.0, left_x=1.0, deadman=False))
        self.assertFalse(cmd.enabled)
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertEqual(cmd.turn_deg, 0.0)

    def test_deadman_enables_command(self):
        cmd = _mapper().map(ControllerState(left_y=0.5, deadman=True))
        self.assertTrue(cmd.enabled)


class StrideAndTurnTests(unittest.TestCase):
    def test_full_stick_reaches_max_stride(self):
        cmd = _mapper().map(ControllerState(left_y=1.0, deadman=True))
        self.assertAlmostEqual(cmd.stride_mm, MOTION["max_stride_mm"], places=6)

    def test_full_negative_stick_reaches_negative_max(self):
        cmd = _mapper().map(ControllerState(left_x=-1.0, deadman=True))
        self.assertAlmostEqual(cmd.turn_deg, -MOTION["max_turn_deg"], places=6)


class DeadzoneTests(unittest.TestCase):
    def test_inside_deadzone_is_zero(self):
        cmd = _mapper().map(ControllerState(left_y=0.11, left_x=-0.05, deadman=True))
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertEqual(cmd.turn_deg, 0.0)

    def test_at_deadzone_edge_is_zero(self):
        # abs(value) < deadzone is the snap rule; exactly == deadzone is NOT zeroed.
        cmd = _mapper().map(ControllerState(left_y=0.119, deadman=True))
        self.assertEqual(cmd.stride_mm, 0.0)

    def test_just_outside_deadzone_is_nonzero(self):
        cmd = _mapper().map(ControllerState(left_y=0.5, deadman=True))
        self.assertGreater(cmd.stride_mm, 0.0)


class ClampTests(unittest.TestCase):
    def test_overdriven_stick_clamps_to_max(self):
        # A controller axis that over-ranges past 1.0 must not exceed the max.
        cmd = _mapper().map(ControllerState(left_y=5.0, left_x=-5.0, deadman=True))
        self.assertAlmostEqual(cmd.stride_mm, MOTION["max_stride_mm"], places=6)
        self.assertAlmostEqual(cmd.turn_deg, -MOTION["max_turn_deg"], places=6)

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


if __name__ == "__main__":
    unittest.main()
