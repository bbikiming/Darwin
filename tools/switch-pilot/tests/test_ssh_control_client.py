"""Unit tests for the safety-critical SSH WalkLab control client.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_ssh_control_client.py

These assert the byte-for-byte command contract (token order, atomic write,
estop/recover commands), the SSH option order (vs SSHShell.swift), telemetry
parsing, and the never-raise / disconnect-on-transport-failure behavior.
"""

from __future__ import annotations

import subprocess
import unittest
from unittest import mock

from darwin_switch_agent.mapping import MotionCommand
from darwin_switch_agent import ssh_control_client as scc
from darwin_switch_agent.ssh_control_client import SshControlClient, ssh_args


def _cmd(enabled=True, stride=12.34, turn=-5.6, pan=10.0, tilt=-3.0):
    return MotionCommand(
        enabled=enabled,
        stride_mm=stride,
        turn_deg=turn,
        head_pan_deg=pan,
        head_tilt_deg=tilt,
        speed_scale=1.0,
    )


def _ok(stdout: bytes = b"") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout, stderr=b"")


class SshArgsTests(unittest.TestCase):
    def test_option_order_with_identity(self):
        args = ssh_args("192.168.123.1", "robotis", "echo ok", "/k/id_rsa_darwin", 6)
        # user@host and command are the last two elements.
        self.assertEqual(args[-2:], ["robotis@192.168.123.1", "echo ok"])
        joined = " ".join(args)
        self.assertIn("BatchMode=yes", joined)
        self.assertIn("StrictHostKeyChecking=accept-new", joined)
        self.assertIn("ServerAliveInterval=2", joined)
        self.assertIn("ServerAliveCountMax=2", joined)
        # ControlMaster trio present only when an identity exists.
        self.assertIn("ControlMaster=auto", joined)
        self.assertIn("ControlPersist=30", joined)
        # OpenSSH 5.9 legacy compat — both axes required.
        self.assertIn("PubkeyAcceptedAlgorithms=+ssh-rsa", joined)
        self.assertIn("HostKeyAlgorithms=+ssh-rsa", joined)
        self.assertIn("IdentitiesOnly=yes", joined)
        self.assertIn("-i", args)

    def test_no_controlmaster_without_identity(self):
        args = ssh_args("h", "u", "echo ok", None, 6)
        joined = " ".join(args)
        self.assertNotIn("ControlMaster=auto", joined)
        self.assertNotIn("-i", args)
        # legacy compat is still applied (harmless on modern servers).
        self.assertIn("HostKeyAlgorithms=+ssh-rsa", joined)

    def test_connect_timeout_clamped(self):
        args = ssh_args("h", "u", "x", None, 99)
        self.assertIn("ConnectTimeout=10", " ".join(args))


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        # identity_file unset -> no disk dependency.
        self.client = SshControlClient({"identity_file": None, "period_ms": 600,
                                        "foot_mm": 40, "hip_deg": 13})

    def test_build_line_14_tokens_exact(self):
        line = self.client._build_line(_cmd())
        tokens = line.split()
        self.assertEqual(len(tokens), 14, line)
        # tokens[0] is the random cmd_id.
        self.assertEqual(tokens[1], "1")        # enabled
        self.assertEqual(tokens[2], "12.34")    # x = stride
        self.assertEqual(tokens[3], "0")        # y
        self.assertEqual(tokens[4], "-5.60")    # a = turn
        self.assertEqual(tokens[5], "600")      # period
        self.assertEqual(tokens[6], "40")       # foot
        self.assertEqual(tokens[7], "13")       # hip
        self.assertEqual(tokens[8], "1.0")      # bgain
        self.assertEqual(tokens[9], "0")        # benable
        self.assertEqual(tokens[10], "2")       # blevel
        self.assertEqual(tokens[11], "10.00")   # headPan
        self.assertEqual(tokens[12], "-3.00")   # headTilt
        self.assertEqual(tokens[13], "0")       # ballTrack

    def test_cmd_id_unique_and_short(self):
        a = self.client._build_line(_cmd()).split()[0]
        b = self.client._build_line(_cmd()).split()[0]
        self.assertNotEqual(a, b)
        self.assertLessEqual(len(a), 31)
        self.assertNotIn(" ", a)

    def test_disabled_command_sends_enabled_zero(self):
        line = self.client._build_line(_cmd(enabled=False))
        self.assertEqual(line.split()[1], "0")


class RemoteCommandTests(unittest.TestCase):
    def setUp(self):
        self.client = SshControlClient({"identity_file": None})
        self.calls = []

        def fake_ssh(command, input_data=None, timeout=None):
            self.calls.append((command, input_data))
            return _ok()

        self.client._ssh = fake_ssh  # type: ignore[assignment]

    def test_send_atomic_temp_mv(self):
        self.assertTrue(self.client.send(_cmd()))
        command, input_data = self.calls[-1]
        self.assertEqual(
            command,
            "cat > /tmp/df-walklab-cmd.tmp && mv -f /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd",
        )
        self.assertEqual(len(input_data.split()), 14)

    def test_stop_sends_enabled_zero(self):
        self.assertTrue(self.client.stop())
        _, input_data = self.calls[-1]
        self.assertEqual(input_data.split()[1], "0")

    def test_estop_touches_file(self):
        self.assertTrue(self.client.estop())
        self.assertEqual(self.calls[-1][0], "touch /tmp/df-walklab-estop")

    def test_recover_removes_file(self):
        self.assertTrue(self.client.recover())
        self.assertEqual(self.calls[-1][0], "rm -f /tmp/df-walklab-estop")


class TelemetryTests(unittest.TestCase):
    def setUp(self):
        self.client = SshControlClient({"identity_file": None})

    def _poll(self, stdout: bytes):
        self.client._ssh = lambda *a, **k: _ok(stdout)  # type: ignore[assignment]
        return self.client.poll_telemetry()

    def test_parse_nominal(self):
        tel = self._poll(b"TEL 1700000000000 500 500 500 512 512 512 122 1 0\n")
        self.assertAlmostEqual(tel["voltage_v"], 12.2, places=3)
        self.assertEqual(tel["battery_pct"], 81)  # (12.2-10.5)/2.1*100
        self.assertTrue(tel["walking"])
        self.assertEqual(tel["fallen"], 0)

    def test_unknown_voltage(self):
        tel = self._poll(b"TEL 1 0 0 0 0 0 0 0 0 1\n")
        self.assertIsNone(tel["voltage_v"])
        self.assertIsNone(tel["battery_pct"])
        self.assertEqual(tel["fallen"], 1)

    def test_battery_clamped(self):
        tel = self._poll(b"TEL 1 0 0 0 0 0 0 90 0 0\n")   # 9.0V below window
        self.assertEqual(tel["battery_pct"], 0)

    def test_malformed_returns_none(self):
        self.assertIsNone(self._poll(b"garbage line\n"))
        self.assertIsNone(self._poll(b""))


class NeverRaiseTests(unittest.TestCase):
    def test_timeout_returns_none_and_disconnects(self):
        client = SshControlClient({"identity_file": None})
        client._connected = True
        with mock.patch.object(scc.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired("ssh", 6)):
            self.assertIsNone(client._ssh("echo ok"))
        self.assertFalse(client.connected)

    def test_exit_255_marks_disconnect(self):
        client = SshControlClient({"identity_file": None})
        client._connected = True
        bad = subprocess.CompletedProcess(args=[], returncode=255, stdout=b"", stderr=b"")
        with mock.patch.object(scc.subprocess, "run", return_value=bad):
            res = client._ssh("echo ok")
        self.assertEqual(res.returncode, 255)
        self.assertFalse(client.connected)

    def test_remote_nonzero_keeps_link(self):
        # A remote command exiting non-zero (e.g. cat of a missing file) is NOT
        # a transport failure and must not drop the link.
        client = SshControlClient({"identity_file": None})
        client._connected = True
        miss = subprocess.CompletedProcess(args=[], returncode=1, stdout=b"", stderr=b"")
        with mock.patch.object(scc.subprocess, "run", return_value=miss):
            client._ssh("cat /tmp/df-walklab-telemetry")
        self.assertTrue(client.connected)


if __name__ == "__main__":
    unittest.main()
