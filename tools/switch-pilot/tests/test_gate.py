"""Unit tests for gate_motion — the last-line safety gate.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_gate.py

gate_motion is the final guard before a command is sent to the robot. Only an
armed AND not-estopped command may pass through unchanged; in every other state
(not armed, estopped, or both) the gate must force enabled=False and zero all
motion amplitudes. Head aim is also zeroed by the gate.
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.main import gate_motion
from darwin_switch_agent.mapping import MotionCommand


def _cmd():
    return MotionCommand(
        enabled=True,
        stride_mm=20.0,
        turn_deg=8.0,
        head_pan_deg=30.0,
        head_tilt_deg=-15.0,
        speed_scale=1.0,
    )


def _assert_zeroed(test, cmd):
    test.assertFalse(cmd.enabled)
    test.assertEqual(cmd.stride_mm, 0.0)
    test.assertEqual(cmd.turn_deg, 0.0)
    test.assertEqual(cmd.head_pan_deg, 0.0)
    test.assertEqual(cmd.head_tilt_deg, 0.0)


class GateTests(unittest.TestCase):
    def test_armed_not_estopped_passes_through(self):
        original = _cmd()
        gated = gate_motion(original, armed=True, estopped=False)
        self.assertEqual(gated, original)

    def test_not_armed_zeroes(self):
        _assert_zeroed(self, gate_motion(_cmd(), armed=False, estopped=False))

    def test_estopped_zeroes_even_when_armed(self):
        _assert_zeroed(self, gate_motion(_cmd(), armed=True, estopped=True))

    def test_not_armed_and_estopped_zeroes(self):
        _assert_zeroed(self, gate_motion(_cmd(), armed=False, estopped=True))

    def test_gate_does_not_mutate_input(self):
        original = _cmd()
        gate_motion(original, armed=False, estopped=False)
        self.assertTrue(original.enabled)
        self.assertEqual(original.stride_mm, 20.0)


if __name__ == "__main__":
    unittest.main()
