"""Unit tests for the O1 UDP transport wire layer (ssh-parity-contract §G).

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_df_udp.py

Covers the pure datagram serializers/parsers (DFCMD / DF-ESTOP / ACK / TEL2) and
the UdpControlTransport over a UDP loopback: seq monotonicity, ACK→RTT/effective
rate, and TEL2 receive. No robot, no SSH — the robot/Mac contract is consumed, not
exercised here.
"""

from __future__ import annotations

import socket
import time
import unittest

from darwin_switch_agent import df_udp
from darwin_switch_agent.df_udp import UdpControlTransport


# §A.2-TEL2 examples lifted verbatim from the contract (docs/ssh-parity-contract.md).
TEL2_FSR = (
    b"TEL2 1748736000123 42 2 28.00 10.00 5.00 600.00 511 530 498 512 489 760 "
    b"100 110 120 130 140 150 160 170 20 -5 0 - 122 udp 18"
)
TEL2_NO_FSR = b"TEL2 1000 7 0 0.00 0.00 0.00 600.00 512 512 512 512 512 700 - - -1 - 0 file 5"


class WireFormatTests(unittest.TestCase):
    def test_token_is_16_shell_safe_alnum(self):
        token = df_udp.gen_token()
        self.assertEqual(len(token), 16)
        self.assertTrue(token.isalnum())
        # Fresh each call (vanishingly small collision odds at 62^16).
        self.assertNotEqual(df_udp.gen_token(), df_udp.gen_token())

    def test_handshake_line_format(self):
        self.assertEqual(df_udp.handshake_line("ABC123", 17372, 17374), "ABC123 17372 17374\n")

    def test_cmd_datagram_prefix_and_line(self):
        dg = df_udp.cmd_datagram("tok", 7, "cid 1 12.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0")
        self.assertTrue(dg.startswith(b"DFCMD tok 7 "))
        self.assertTrue(dg.endswith(b" 0"))

    def test_estop_datagram_format(self):
        self.assertEqual(df_udp.estop_datagram("tok", 1748736000123), b"DF-ESTOP v1 tok 1748736000123")

    def test_parse_ack_ok_and_bad(self):
        self.assertEqual(df_udp.parse_ack(b"ACK 42 1748736000999"), (42, 1748736000999))
        self.assertIsNone(df_udp.parse_ack(b"NOPE 1 2"))
        self.assertIsNone(df_udp.parse_ack(b"ACK 42"))
        self.assertIsNone(df_udp.parse_ack(b"ACK x y"))


class Tel2ParseTests(unittest.TestCase):
    def test_parse_full_fsr_present(self):
        t = df_udp.parse_tel2(TEL2_FSR)
        self.assertIsNotNone(t)
        self.assertEqual(t["seq_applied"], 42)
        self.assertEqual(t["phase"], 2)
        self.assertEqual(t["latch"], {"x": 28.0, "y": 10.0, "a": 5.0, "period": 600.0})
        self.assertEqual(t["gyro"], {"x": 511, "y": 530, "z": 498})
        self.assertEqual(t["accel"], {"x": 512, "y": 489, "z": 760})
        self.assertEqual(t["fsr"], [100, 110, 120, 130, 140, 150, 160, 170])
        self.assertEqual(t["cop"], [20, -5])
        self.assertTrue(t["ground"])
        self.assertTrue(t["left_contact"])
        self.assertTrue(t["right_contact"])
        self.assertEqual(t["fallen"], 0)
        self.assertIsNone(t["risk"])
        self.assertEqual(t["active_source"], "udp")
        self.assertEqual(t["loop_ms"], 18)
        self.assertAlmostEqual(t["voltage_v"], 12.2, places=3)
        self.assertTrue(t["walking"])  # phase 2 >= 0

    def test_parse_no_fsr_no_cop(self):
        t = df_udp.parse_tel2(TEL2_NO_FSR)
        self.assertIsNotNone(t)
        self.assertEqual(t["seq_applied"], 7)
        self.assertEqual(t["phase"], 0)
        self.assertIsNone(t["fsr"])
        self.assertIsNone(t["cop"])
        self.assertFalse(t["ground"])
        self.assertFalse(t["left_contact"])
        self.assertFalse(t["right_contact"])
        self.assertEqual(t["fallen"], -1)
        self.assertEqual(t["active_source"], "file")
        self.assertEqual(t["loop_ms"], 5)
        self.assertIsNone(t["voltage_v"])  # vdV 0 == unknown

    def test_malformed_returns_none(self):
        self.assertIsNone(df_udp.parse_tel2(b""))
        self.assertIsNone(df_udp.parse_tel2(b"TEL 1 2 3"))           # wrong prefix
        self.assertIsNone(df_udp.parse_tel2(b"TEL2 only four toks"))  # too short
        # Non-numeric in a numeric slot drops the whole sample.
        self.assertIsNone(df_udp.parse_tel2(TEL2_NO_FSR.replace(b"700", b"xx")))


class UdpTransportLoopbackTests(unittest.TestCase):
    """Exercise the transport against a local UDP echo that ACKs and streams TEL2."""

    def setUp(self):
        # A stand-in "robot": one socket receives DFCMD and can send ACK/TEL2.
        self.robot = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.robot.bind(("127.0.0.1", 0))
        self.robot.settimeout(1.0)
        self.robot_port = self.robot.getsockname()[1]
        self.t = UdpControlTransport("127.0.0.1", cmd_port=self.robot_port)
        self.addCleanup(self.t.close)
        self.addCleanup(self.robot.close)

    def _recv_cmd(self):
        data, addr = self.robot.recvfrom(2048)
        return data, addr

    def test_seq_strictly_monotonic(self):
        s1 = self.t.send_command("line one")
        s2 = self.t.send_command("line two")
        s3 = self.t.send_command("line three")
        self.assertEqual([s1, s2, s3], [1, 2, 3])
        d1, _ = self._recv_cmd()
        self.assertTrue(d1.startswith(b"DFCMD "))
        self.assertEqual(d1.split()[2], b"1")

    def test_ack_updates_rtt_and_effective_rate(self):
        seq = self.t.send_command("go")
        _data, addr = self._recv_cmd()
        # Robot replies ACK to the datagram's source addr.
        self.robot.sendto(f"ACK {seq} {int(time.time()*1000)}".encode("ascii"), addr)
        time.sleep(0.02)
        tel = self.t.pump()
        self.assertIsNone(tel)  # an ACK is not telemetry
        self.assertEqual(self.t.last_ack_seq, seq)
        self.assertIsNotNone(self.t.last_rtt_ms)
        self.assertGreaterEqual(self.t.effective_hz(), 1.0)
        self.assertIsNotNone(self.t.ack_age_s())

    def test_pump_parses_tel2_stream(self):
        # Robot streams TEL2 to our registered uplink (the transport's own socket).
        self.robot.sendto(TEL2_FSR, (self.t.local_ip, self.t.local_port))
        time.sleep(0.02)
        tel = self.t.pump()
        self.assertIsNotNone(tel)
        self.assertEqual(tel["seq_applied"], 42)
        self.assertIsNotNone(self.t.tel_age_s())
        self.assertEqual(self.t.last_tel["seq_applied"], 42)

    def test_pump_never_raises_when_idle(self):
        self.assertIsNone(self.t.pump())  # nothing queued — clean no-op

    def test_metrics_shape(self):
        m = self.t.metrics()
        self.assertEqual(m["transport"], "udp")
        self.assertIn("effective_hz", m)
        self.assertIn("rtt_ms", m)

    def test_uplink_value_is_ip_port(self):
        host, port = self.t.uplink_value().split(":")
        self.assertEqual(host, self.t.local_ip)
        self.assertEqual(int(port), self.t.local_port)


if __name__ == "__main__":
    unittest.main()
