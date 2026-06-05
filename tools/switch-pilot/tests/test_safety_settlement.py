"""P1 safety: a Stop/E-stop in a tick must never be followed by a nonzero
command in the SAME tick. These tests pin the loop's settle->command ordering
via the pure helpers extracted from main.py (settle_safety_state + zero_motion +
gate_motion), so they fail on the old "command computed before E-stop" ordering.

Run: PYTHONPATH=tools/switch-pilot/src python3 -m unittest discover -s tools/switch-pilot/tests
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.control_bus import ControlAction
from darwin_switch_agent.mapping import MotionCommand
from darwin_switch_agent.safety import SafetyEdges
from darwin_switch_agent.main import gate_motion, settle_safety_state, zero_motion


def _moving() -> MotionCommand:
    return MotionCommand(
        enabled=True, stride_mm=15.0, turn_deg=4.0,
        head_pan_deg=0.0, head_tilt_deg=0.0, speed_scale=1.0,
    )


def _final(raw, armed, estopped, actions, edges):
    """Mirror main.py's tick ordering: settle safety FIRST, then command."""
    s = settle_safety_state(armed, estopped, actions, edges)
    cmd = gate_motion(raw, armed=s.armed, estopped=s.estopped)
    if s.force_stop_this_tick:
        cmd = zero_motion(cmd)
    return s, cmd


def _no_edges(**kw) -> SafetyEdges:
    return SafetyEdges(**kw)


class SettlementTests(unittest.TestCase):
    def test_cockpit_estop_action_zeros_same_tick(self):
        s, cmd = _final(_moving(), armed=True, estopped=False,
                        actions=[ControlAction(action="estop")], edges=_no_edges())
        self.assertTrue(s.estopped)
        self.assertFalse(cmd.enabled)
        self.assertEqual(cmd.stride_mm, 0.0)
        self.assertFalse(cmd.moving)

    def test_physical_estop_edge_zeros_same_tick(self):
        s, cmd = _final(_moving(), armed=True, estopped=False,
                        actions=[], edges=_no_edges(estop_pressed=True))
        self.assertTrue(s.estopped)
        self.assertFalse(cmd.moving)
        self.assertEqual((cmd.stride_mm, cmd.turn_deg), (0.0, 0.0))

    def test_cockpit_stop_action_forces_zero_this_tick(self):
        s, cmd = _final(_moving(), armed=True, estopped=False,
                        actions=[ControlAction(action="stop")], edges=_no_edges())
        self.assertTrue(s.force_stop_this_tick)
        self.assertFalse(s.estopped)   # Stop need not latch E-stop...
        self.assertFalse(cmd.moving)   # ...but it must zero motion this tick.

    def test_deadman_release_forces_zero(self):
        s, cmd = _final(_moving(), armed=True, estopped=False,
                        actions=[], edges=_no_edges(deadman_released=True))
        self.assertTrue(s.force_stop_this_tick)
        self.assertFalse(cmd.moving)

    def test_estop_dominates_arm_in_same_tick(self):
        # Arm action + E-stop edge in one tick -> E-stop wins (stays stopped).
        s, cmd = _final(_moving(), armed=False, estopped=False,
                        actions=[ControlAction(action="arm")],
                        edges=_no_edges(estop_pressed=True))
        self.assertTrue(s.estopped)
        self.assertFalse(s.armed)
        self.assertFalse(cmd.moving)

    def test_recover_clears_estop_when_no_estop_this_tick(self):
        s, _cmd = _final(_moving(), armed=False, estopped=True,
                         actions=[ControlAction(action="recover")], edges=_no_edges())
        self.assertFalse(s.estopped)
        self.assertTrue(s.armed)

    def test_normal_armed_deadman_held_passes_through(self):
        # No stop/estop -> the moving command survives (proves we don't over-zero).
        s, cmd = _final(_moving(), armed=True, estopped=False,
                        actions=[], edges=_no_edges())
        self.assertFalse(s.force_stop_this_tick)
        self.assertTrue(cmd.moving)
        self.assertEqual(cmd.stride_mm, 15.0)

    def test_zero_motion_helper(self):
        z = zero_motion(_moving())
        self.assertFalse(z.enabled)
        self.assertEqual((z.stride_mm, z.turn_deg, z.head_pan_deg, z.head_tilt_deg),
                         (0.0, 0.0, 0.0, 0.0))


if __name__ == "__main__":
    unittest.main()
