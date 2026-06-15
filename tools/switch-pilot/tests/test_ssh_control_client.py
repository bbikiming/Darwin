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
import time
import unittest
from unittest import mock

from darwin_switch_agent.mapping import MotionCommand
from darwin_switch_agent import ssh_control_client as scc
from darwin_switch_agent.ssh_control_client import SshControlClient, ssh_args


def _cmd(enabled=True, stride=12.34, turn=-5.6, pan=10.0, tilt=-3.0, side=0.0):
    return MotionCommand(
        enabled=enabled,
        stride_mm=stride,
        side_mm=side,
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

    def test_custom_port_emitted_before_target(self):
        args = ssh_args("h", "u", "x", None, 6, port=2222)
        self.assertIn("-p", args)
        self.assertEqual(args[args.index("-p") + 1], "2222")
        # user@host and command remain the last two elements.
        self.assertEqual(args[-2:], ["u@h", "x"])

    def test_default_port_22(self):
        args = ssh_args("h", "u", "x", None, 6)
        self.assertEqual(args[args.index("-p") + 1], "22")


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
        self.assertEqual(tokens[3], "0.00")     # y = side (now a real .2f float)
        self.assertEqual(tokens[4], "-5.60")    # a = turn
        self.assertEqual(tokens[5], "621")      # dynamic period
        self.assertEqual(tokens[6], "31")       # dynamic foot
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
        self.assertEqual(line.split()[3], "0.00")
        self.assertEqual(line.split()[5], "600")
        self.assertEqual(line.split()[6], "40")

    def test_gait_params_scale_with_input_intensity(self):
        slow = self.client._build_line(_cmd(stride=2.0, turn=0.0)).split()
        fast = self.client._build_line(_cmd(stride=25.0, turn=0.0)).split()
        self.assertGreater(int(slow[5]), int(fast[5]))  # slower cadence
        self.assertLess(int(slow[6]), int(fast[6]))     # lower foot lift
        self.assertEqual(fast[5], "520")
        self.assertEqual(fast[6], "40")

    def test_side_motion_affects_line_and_gait_intensity(self):
        line = self.client._build_line(_cmd(stride=0.0, side=12.0, turn=0.0)).split()
        self.assertEqual(line[2], "0.00")
        self.assertEqual(line[3], "12.00")
        self.assertLess(int(line[5]), 780)
        self.assertGreater(int(line[6]), 18)


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

    def test_connect_uses_short_connect_timeout(self):
        client = SshControlClient({"identity_file": None, "connect_timeout_seconds": 2})
        calls = []

        def fake_ssh(command, input_data=None, timeout=None):
            calls.append((command, timeout))
            return _ok()

        client._ssh = fake_ssh  # type: ignore[assignment]
        self.assertTrue(client.connect())
        self.assertEqual(calls[0], ("echo ok", 2))


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
        self.assertEqual(tel["gyro"], {"x": 500, "y": 500, "z": 500})
        self.assertEqual(tel["accel"], {"x": 512, "y": 512, "z": 512})

    def test_unknown_voltage(self):
        tel = self._poll(b"TEL 1 0 0 0 0 0 0 0 0 1\n")
        self.assertIsNone(tel["voltage_v"])
        self.assertIsNone(tel["battery_pct"])
        self.assertEqual(tel["fallen"], 1)
        self.assertEqual(tel["gyro"], {"x": 0, "y": 0, "z": 0})
        self.assertEqual(tel["accel"], {"x": 0, "y": 0, "z": 0})

    def test_battery_clamped(self):
        tel = self._poll(b"TEL 1 0 0 0 0 0 0 90 0 0\n")   # 9.0V below window
        self.assertEqual(tel["battery_pct"], 0)

    def test_malformed_returns_none(self):
        self.assertIsNone(self._poll(b"garbage line\n"))
        self.assertIsNone(self._poll(b""))


class CommandStatusTests(unittest.TestCase):
    def test_parse_command_status(self):
        parsed = scc._parse_command_status(
            b"MODE=walklab\nESTOP=0\nSTAT=1780819000 68\n"
            b"CMD=abc 1 12.50 -7.00 -3.00 621 31 13 1.0 0 2 15.00 -8.00 0\n"
        )
        self.assertEqual(parsed["mode"], "walklab")
        self.assertFalse(parsed["estop"])
        self.assertEqual(parsed["mtime"], 1780819000)
        self.assertEqual(parsed["parsed"]["side_mm"], -7.0)
        self.assertEqual(parsed["parsed"]["period_ms"], 621.0)


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


class PortRuntimeTests(unittest.TestCase):
    def test_client_ssh_call_uses_configured_port(self):
        client = SshControlClient({"port": 2222, "identity_file": None})
        captured = {}

        def fake_run(args, **kw):
            captured["args"] = args
            return subprocess.CompletedProcess(args=args, returncode=0, stdout=b"", stderr=b"")

        with mock.patch.object(scc.subprocess, "run", side_effect=fake_run):
            client._ssh("echo ok")
        self.assertIn("-p", captured["args"])
        self.assertEqual(captured["args"][captured["args"].index("-p") + 1], "2222")

    def test_default_client_uses_port_22(self):
        client = SshControlClient({"identity_file": None})
        self.assertEqual(client.port, 22)


class _FakeUdp:
    """Minimal UdpControlTransport stand-in for the auto state-machine tests."""

    def __init__(self):
        self.token = "FAKETOKEN0000000"
        self.last_ack_at = None
        self.last_rtt_ms = None
        self.last_tel = None
        self._tel_age = None
        self.estop_bursts = 0
        self.sent: list[str] = []
        self.closed = False

    def uplink_value(self):
        return "10.0.0.5:40000"

    def send_command(self, line):
        self.sent.append(line)
        return len(self.sent)

    def send_estop(self):
        self.estop_bursts += 1

    def pump(self):
        return self.last_tel

    def tel_age_s(self):
        return self._tel_age

    def metrics(self):
        return {"transport": "udp", "effective_hz": 20.0, "rtt_ms": self.last_rtt_ms}

    def close(self):
        self.closed = True


class TransportSelectionTests(unittest.TestCase):
    """The auto state machine: probing → udp on ACK, → ssh on probe timeout."""

    def _client(self, **cfg):
        client = SshControlClient({"identity_file": None, "transport": "auto", **cfg})
        self.calls = []

        def fake_ssh(command, input_data=None, timeout=None):
            self.calls.append((command, input_data))
            return _ok()

        client._ssh = fake_ssh  # type: ignore[assignment]
        return client

    def test_default_transport_is_auto(self):
        self.assertEqual(SshControlClient({"identity_file": None}).transport_mode, "auto")

    def test_invalid_transport_falls_back_to_auto(self):
        self.assertEqual(
            SshControlClient({"identity_file": None, "transport": "bogus"}).transport_mode, "auto"
        )

    def test_forced_ssh_mode(self):
        client = SshControlClient({"identity_file": None, "transport": "ssh"})
        self.assertEqual(client.transport_mode, "ssh")
        self.assertFalse(client.streaming)
        self.assertEqual(client.current_send_hz(), client.ssh_send_hz)

    def test_probing_promotes_to_udp_on_ack(self):
        client = self._client()
        client._udp = _FakeUdp()
        client._transport_state = "probing"
        client._probe_started = 1.0
        # An ACK was observed (set by the real transport's _on_ack).
        client._udp.last_ack_at = 123.0
        client.pump()
        self.assertTrue(client.udp_active)
        self.assertTrue(client.streaming)
        self.assertEqual(client.current_send_hz(), client.udp_send_hz)

    def test_probing_falls_back_to_ssh_after_timeout(self):
        client = self._client(ack_probe_ms=10)
        fake = _FakeUdp()
        client._udp = fake
        client._transport_state = "probing"
        client._probe_started = time.monotonic() - 1.0  # well past 10ms window
        client.pump()
        self.assertEqual(client.transport_label, "ssh")
        self.assertFalse(client.streaming)
        self.assertTrue(fake.closed)  # socket torn down
        # Handshake + uplink cleared so the robot returns to file-poll.
        self.assertTrue(any("rm -f" in c and scc.CHANNEL_PATH in c for c, _ in self.calls))

    def test_dispatch_uses_udp_while_streaming(self):
        client = self._client()
        fake = _FakeUdp()
        client._udp = fake
        client._transport_state = "udp"
        self.assertTrue(client.send(_cmd()))
        self.assertEqual(len(fake.sent), 1)              # went out over UDP
        # No SSH file write while streaming (the slow path is bypassed).
        self.assertFalse(any("df-walklab-cmd" in c for c, _ in self.calls))

    def test_dispatch_uses_ssh_file_when_not_streaming(self):
        client = self._client()
        client._transport_state = "ssh"
        self.assertTrue(client.send(_cmd()))
        self.assertTrue(any("df-walklab-cmd" in c for c, _ in self.calls))

    def test_estop_fires_udp_burst_and_touches_file(self):
        client = self._client()
        fake = _FakeUdp()
        client._udp = fake
        self.assertTrue(client.estop())
        self.assertEqual(fake.estop_bursts, 1)           # §G.2 burst fired
        self.assertEqual(self.calls[-1][0], f"touch {scc.ESTOP_PATH}")  # file still touched

    def test_udp_tel_fresh_window(self):
        client = self._client(udp_tel_fresh_s=1.0)
        fake = _FakeUdp()
        client._udp = fake
        fake._tel_age = 0.2
        self.assertTrue(client.udp_tel_fresh())
        fake._tel_age = 5.0
        self.assertFalse(client.udp_tel_fresh())

    def test_start_udp_writes_handshake_and_uplink(self):
        client = self._client()
        client._start_udp()
        self.addCleanup(lambda: client._udp and client._udp.close())
        wrote = [(c, i) for c, i in self.calls if scc.CHANNEL_PATH in c or scc.UPLINK_PATH in c]
        self.assertEqual(len(wrote), 2)
        # Handshake body: "TOKEN ESTOP_PORT CMD_PORT".
        channel_body = next(i for c, i in wrote if scc.CHANNEL_TMP_PATH in c)
        toks = channel_body.split()
        self.assertEqual(len(toks), 3)
        self.assertTrue(toks[0].isalnum())
        self.assertEqual(client._transport_state, "probing")


if __name__ == "__main__":
    unittest.main()
