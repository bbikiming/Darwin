from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest import mock

from darwin_switch_agent.config import AgentConfig
import darwin_switch_agent.network_check as network_check


class FakeHttpResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc, _tb):
        return False

    def read(self, _size):
        return b'{"ok":true}'


class FakePrefixSocket:
    def __init__(self, response: bytes):
        self.response = response
        self.sent = b""

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc, _tb):
        return False

    def settimeout(self, _timeout):
        pass

    def sendall(self, data: bytes):
        self.sent += data

    def recv(self, _size: int) -> bytes:
        return self.response


class NetworkCheckTests(unittest.TestCase):
    def test_dry_run_reports_camera_disabled_as_warning_not_failure(self):
        config = AgentConfig(
            {
                "mode": "dry_run",
                "gui": {"port": 8765},
                "camera": {"enabled": False},
            }
        )
        with mock.patch.object(network_check, "local_ip_hint", return_value="192.168.1.40"), \
            mock.patch.object(network_check, "urlopen", return_value=FakeHttpResponse()):
            report = network_check.run_network_report(config)

        checks = {check["id"]: check for check in report["checks"]}
        self.assertTrue(report["ok"])
        self.assertEqual(report["level"], "warn")
        self.assertEqual(checks["cockpit_api"]["level"], "good")
        self.assertEqual(checks["mode_target"]["level"], "good")
        self.assertEqual(checks["camera"]["level"], "warn")

    def test_invalid_robot_udp_target_is_bad(self):
        config = AgentConfig(
            {
                "mode": "robot_udp",
                "gui": {"port": 8765},
                "robot": {"host": "", "port": 0},
                "camera": {"enabled": False},
            }
        )
        with mock.patch.object(network_check, "local_ip_hint", return_value="192.168.1.40"), \
            mock.patch.object(network_check, "urlopen", return_value=FakeHttpResponse()):
            report = network_check.run_network_report(config)

        checks = {check["id"]: check for check in report["checks"]}
        self.assertFalse(report["ok"])
        self.assertEqual(report["level"], "bad")
        self.assertEqual(checks["robot_udp"]["level"], "bad")

    def test_ssh_probe_is_read_only_echo_check(self):
        captured: dict[str, list[str]] = {}

        def fake_run(args, **_kwargs):
            captured["args"] = args
            return SimpleNamespace(returncode=0, stdout=b"ok\n", stderr=b"")

        with mock.patch.object(network_check.subprocess, "run", side_effect=fake_run):
            check = network_check._ssh_probe("192.168.123.1", "robotis", 22, "/tmp/id_rsa", 1.5)

        self.assertEqual(check.level, "good")
        args = captured["args"]
        self.assertEqual(args[-2:], ["robotis@192.168.123.1", "echo ok"])
        self.assertNotIn("/tmp/df-walklab-cmd", " ".join(args))
        self.assertIn("PubkeyAcceptedAlgorithms=+ssh-rsa", args)

    def test_camera_http_prefix_probe_accepts_initial_mjpeg_bytes(self):
        fake_sock = FakePrefixSocket(
            b"HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=boundarydonotcross\r\n\r\n"
            b"--boundarydonotcross\r\nContent-Type: image/jpeg\r\n"
        )
        with mock.patch.object(network_check.socket, "create_connection", return_value=fake_sock):
            check = network_check._http_prefix_check(
                "http://127.0.0.1:18080/?action=stream",
                "camera_stream_url",
                "Camera stream URL",
                1.5,
            )

        self.assertEqual(check.level, "good")
        self.assertIn("HTTP 200", check.detail)
        self.assertIn(b"GET /?action=stream HTTP/1.1", fake_sock.sent)


if __name__ == "__main__":
    unittest.main()
