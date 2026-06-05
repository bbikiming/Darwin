"""Unit tests for validate_provisioning — the device-config boundary guard.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_config.py

The localhost provisioning UI is an untrusted boundary. validate_provisioning
must accept ONLY a fixed allowlist of well-formed keys and reject everything
else (unknown top-level keys, bad mode, out-of-range ports, non-dict payloads)
with a ValueError so arbitrary config can never be injected.
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.config import validate_provisioning


class AcceptTests(unittest.TestCase):
    def test_accepts_ssh_block(self):
        out = validate_provisioning(
            {"mode": "ssh", "ssh": {"host": "1.2.3.4", "user": "robotis", "port": 22}}
        )
        self.assertEqual(out["mode"], "ssh")
        self.assertEqual(out["ssh"], {"host": "1.2.3.4", "user": "robotis", "port": 22})

    def test_accepts_mac_robot_camera(self):
        out = validate_provisioning(
            {
                "mac": {"host": "10.0.0.5", "port": 8765, "pairing_code": "1234"},
                "robot": {"host": "192.168.0.100", "port": 55310, "token": "abc"},
                "camera": {"enabled": True, "stream_url": "http://cam/stream"},
            }
        )
        self.assertEqual(out["mac"]["pairing_code"], "1234")
        self.assertEqual(out["robot"]["port"], 55310)
        self.assertTrue(out["camera"]["enabled"])

    def test_empty_payload_returns_empty_updates(self):
        self.assertEqual(validate_provisioning({}), {})

    def test_returns_new_dict_not_input(self):
        payload = {"mode": "ssh"}
        out = validate_provisioning(payload)
        self.assertIsNot(out, payload)


class RejectTests(unittest.TestCase):
    def test_rejects_unknown_top_level_key(self):
        with self.assertRaises(ValueError):
            validate_provisioning({"mode": "ssh", "evil": 1})

    def test_rejects_bad_mode(self):
        with self.assertRaises(ValueError):
            validate_provisioning({"mode": "telepathy"})

    def test_rejects_non_string_mode(self):
        with self.assertRaises(ValueError):
            validate_provisioning({"mode": 7})

    def test_rejects_ssh_port_out_of_range(self):
        with self.assertRaises(ValueError):
            validate_provisioning({"ssh": {"port": 70000}})

    def test_rejects_ssh_port_zero(self):
        # ssh.port specifically requires 1..65535 (0 is not a valid ssh port).
        with self.assertRaises(ValueError):
            validate_provisioning({"ssh": {"port": 0}})

    def test_rejects_non_dict_payload(self):
        for bad in ([], "x", 5, None):
            with self.assertRaises(ValueError):
                validate_provisioning(bad)

    def test_rejects_non_dict_section(self):
        with self.assertRaises(ValueError):
            validate_provisioning({"ssh": "not-an-object"})

    def test_rejects_non_digit_pairing_code(self):
        with self.assertRaises(ValueError):
            validate_provisioning({"mac": {"pairing_code": "abcd"}})


if __name__ == "__main__":
    unittest.main()
