"""Edge-detector tests for SafetyState — it produces arm/stop/estop/deadman
edges that drive the real STOP/ESTOP sends in main.py, so its rising/falling
edge semantics are safety-critical.

Run: PYTHONPATH=tools/switch-pilot/src python3 -m unittest discover -s tools/switch-pilot/tests
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.input_linux import ControllerState
from darwin_switch_agent.mapping import MotionCommand
from darwin_switch_agent.safety import SafetyState


def _ctl(**kw) -> ControllerState:
    return ControllerState(**kw)


def _cmd(moving: bool) -> MotionCommand:
    # moving == enabled and (|stride|>0.01 or |turn|>0.01)
    return MotionCommand(
        enabled=moving,
        stride_mm=5.0 if moving else 0.0,
        side_mm=0.0,
        turn_deg=0.0,
        head_pan_deg=0.0,
        head_tilt_deg=0.0,
        speed_scale=1.0,
    )


class SafetyEdgeTests(unittest.TestCase):
    def setUp(self):
        self.safety = SafetyState()
        self.idle = _cmd(False)

    def test_estop_fires_once_on_rising_edge(self):
        # not pressed -> no edge
        self.assertFalse(self.safety.update(_ctl(estop=False), self.idle).estop_pressed)
        # False->True -> edge fires exactly once
        self.assertTrue(self.safety.update(_ctl(estop=True), self.idle).estop_pressed)
        # held -> no repeat edge
        self.assertFalse(self.safety.update(_ctl(estop=True), self.idle).estop_pressed)
        # released then pressed again -> edge fires again
        self.safety.update(_ctl(estop=False), self.idle)
        self.assertTrue(self.safety.update(_ctl(estop=True), self.idle).estop_pressed)

    def test_deadman_released_is_falling_edge(self):
        # press deadman (rising) -> not a 'released' edge
        self.assertFalse(self.safety.update(_ctl(deadman=True), self.idle).deadman_released)
        # held -> no edge
        self.assertFalse(self.safety.update(_ctl(deadman=True), self.idle).deadman_released)
        # True->False -> released edge fires once
        self.assertTrue(self.safety.update(_ctl(deadman=False), self.idle).deadman_released)
        # stays released -> no repeat
        self.assertFalse(self.safety.update(_ctl(deadman=False), self.idle).deadman_released)

    def test_arm_and_stop_rising_edges(self):
        e = self.safety.update(_ctl(arm=True, stop=True), self.idle)
        self.assertTrue(e.arm_pressed)
        self.assertTrue(e.stop_pressed)
        # held -> no repeat
        e2 = self.safety.update(_ctl(arm=True, stop=True), self.idle)
        self.assertFalse(e2.arm_pressed)
        self.assertFalse(e2.stop_pressed)

    def test_independent_channels_do_not_cross_fire(self):
        e = self.safety.update(_ctl(estop=True), self.idle)
        self.assertTrue(e.estop_pressed)
        self.assertFalse(e.arm_pressed)
        self.assertFalse(e.stop_pressed)
        self.assertFalse(e.deadman_released)

    def test_was_moving_tracks_command(self):
        self.safety.update(_ctl(deadman=True), _cmd(True))
        self.assertTrue(self.safety.was_moving)
        self.safety.update(_ctl(deadman=True), _cmd(False))
        self.assertFalse(self.safety.was_moving)


if __name__ == "__main__":
    unittest.main()
