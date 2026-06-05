"""Unit tests for RobotUdpClient — the SWP1 UDP line protocol emitter.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_robot_udp.py

A FakeSock replaces the real UDP socket so no network is touched. Asserts the
safety-critical stop edge: send_stop emits STOP_REPEAT (3) fully-zeroed STOP
datagrams with incrementing seq; estop=True emits ESTOP; and a live send carrying
deadman includes the DEADMAN flag.
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.input_linux import ControllerState
from darwin_switch_agent.mapping import MotionCommand
from darwin_switch_agent.robot_udp_client import RobotUdpClient, STOP_REPEAT


class FakeSock:
    """Captures sendto() payloads instead of touching the network."""

    def __init__(self):
        self.sent: list[tuple[bytes, tuple]] = []

    def sendto(self, data, addr):
        self.sent.append((data, addr))
        return len(data)


def _client():
    c = RobotUdpClient({"host": "10.0.0.9", "port": 55310, "token": "tok"})
    # Close the real UDP socket the constructor opened before swapping in the
    # fake, so no OS socket leaks (no ResourceWarning) and nothing is bound.
    c.sock.close()
    fake = FakeSock()
    c.sock = fake
    return c, fake


def _lines(fake):
    return [d.decode("ascii").strip() for d, _ in fake.sent]


def _tokens(line):
    return line.split()


class StopTests(unittest.TestCase):
    def test_send_stop_emits_three_zeroed_datagrams(self):
        c, fake = _client()
        c.send_stop()
        lines = _lines(fake)
        self.assertEqual(len(lines), STOP_REPEAT)
        self.assertEqual(STOP_REPEAT, 3)
        for line in lines:
            tokens = _tokens(line)
            self.assertEqual(tokens[0], "SWP1")
            self.assertIn("STOP", tokens[4])
            # lx ly rx ry are zeroed.
            self.assertEqual(tokens[5:9], ["0.0000"] * 4)

    def test_send_stop_seq_increments(self):
        c, fake = _client()
        c.send_stop()
        seqs = [int(_tokens(line)[1]) for line in _lines(fake)]
        self.assertEqual(seqs, [1, 2, 3])

    def test_send_stop_estop_emits_estop_flag(self):
        c, fake = _client()
        c.send_stop(estop=True)
        for line in _lines(fake):
            self.assertIn("ESTOP", _tokens(line)[4])
            self.assertNotEqual(_tokens(line)[4], "STOP")

    def test_send_stop_targets_configured_host(self):
        c, fake = _client()
        c.send_stop()
        for _, addr in fake.sent:
            self.assertEqual(addr, ("10.0.0.9", 55310))


class SendTests(unittest.TestCase):
    def test_send_with_deadman_includes_flag(self):
        c, fake = _client()
        state = ControllerState(left_y=0.5, deadman=True)
        cmd = MotionCommand(
            enabled=True,
            stride_mm=10.0,
            turn_deg=0.0,
            head_pan_deg=0.0,
            head_tilt_deg=0.0,
            speed_scale=1.0,
        )
        c.send(state, cmd)
        self.assertIn("DEADMAN", _tokens(_lines(fake)[0])[4])

    def test_send_idle_when_no_flags(self):
        c, fake = _client()
        state = ControllerState()
        cmd = MotionCommand(
            enabled=False,
            stride_mm=0.0,
            turn_deg=0.0,
            head_pan_deg=0.0,
            head_tilt_deg=0.0,
            speed_scale=1.0,
        )
        c.send(state, cmd)
        self.assertEqual(_tokens(_lines(fake)[0])[4], "IDLE")


if __name__ == "__main__":
    unittest.main()
