"""Unit tests for merge_config — the config write-merge in the cockpit API.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_cockpit.py

merge_config folds validated provisioning updates into the on-disk config.
Top-level scalars (e.g. 'mode') replace outright, but the known nested sections
(mac/robot/camera/ssh) must merge one level deep so a *partial* section update
keeps the sub-keys it did not touch. ssh is the regression guard here: it used
to be missing from _NESTED_SECTIONS, so a partial ssh update silently wiped the
untouched host/user/port instead of preserving them.
"""

from __future__ import annotations

import types
import unittest

from darwin_switch_agent.cockpit import CockpitHandler, merge_config


class LoopbackGuardTests(unittest.TestCase):
    """/api/config (reads+writes device config incl. secrets) must accept only
    loopback clients, even if gui.host is ever set to 0.0.0.0."""

    @staticmethod
    def _is_loopback(addr: str) -> bool:
        fake = types.SimpleNamespace(client_address=(addr, 50000))
        return CockpitHandler._is_loopback(fake)

    def test_loopback_clients_allowed(self):
        for addr in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
            self.assertTrue(self._is_loopback(addr), addr)

    def test_lan_clients_rejected(self):
        for addr in ("192.168.0.50", "10.0.0.1", "192.168.123.50", ""):
            self.assertFalse(self._is_loopback(addr), addr)


class MergeScalarTests(unittest.TestCase):
    def test_top_level_scalar_replaces(self):
        merged = merge_config({"mode": "dry_run"}, {"mode": "ssh"})
        self.assertEqual(merged["mode"], "ssh")

    def test_does_not_mutate_inputs(self):
        existing = {"ssh": {"host": "1.2.3.4", "user": "robotis"}}
        updates = {"ssh": {"user": "darwin"}}
        merge_config(existing, updates)
        # Both arguments are left untouched (immutability contract).
        self.assertEqual(existing, {"ssh": {"host": "1.2.3.4", "user": "robotis"}})
        self.assertEqual(updates, {"ssh": {"user": "darwin"}})


class PartialSectionMergeTests(unittest.TestCase):
    """A partial update to a nested section must preserve untouched sub-keys."""

    def test_partial_ssh_update_preserves_untouched_sub_keys(self):
        existing = {
            "ssh": {
                "host": "192.168.123.1",
                "user": "robotis",
                "port": 22,
                "identity_file": "/etc/darwin/id_ed25519",
            }
        }
        # Caller changes only identity_file via /api/config.
        merged = merge_config(existing, {"ssh": {"identity_file": "/etc/darwin/new_key"}})
        self.assertEqual(
            merged["ssh"],
            {
                "host": "192.168.123.1",
                "user": "robotis",
                "port": 22,
                "identity_file": "/etc/darwin/new_key",
            },
        )

    def test_partial_mac_update_preserves_untouched_sub_keys(self):
        existing = {"mac": {"host": "10.0.0.5", "port": 8765, "pairing_code": "1234"}}
        merged = merge_config(existing, {"mac": {"pairing_code": "9999"}})
        self.assertEqual(
            merged["mac"], {"host": "10.0.0.5", "port": 8765, "pairing_code": "9999"}
        )

    def test_partial_robot_update_preserves_untouched_sub_keys(self):
        existing = {"robot": {"host": "192.168.0.100", "port": 55310, "token": "abc"}}
        merged = merge_config(existing, {"robot": {"token": "xyz"}})
        self.assertEqual(
            merged["robot"], {"host": "192.168.0.100", "port": 55310, "token": "xyz"}
        )

    def test_partial_camera_update_preserves_untouched_sub_keys(self):
        existing = {"camera": {"enabled": True, "stream_url": "http://cam/stream"}}
        merged = merge_config(existing, {"camera": {"enabled": False}})
        self.assertEqual(
            merged["camera"], {"enabled": False, "stream_url": "http://cam/stream"}
        )


class MergeEdgeCaseTests(unittest.TestCase):
    def test_ssh_section_created_when_absent_in_existing(self):
        merged = merge_config({"mode": "ssh"}, {"ssh": {"host": "1.2.3.4"}})
        self.assertEqual(merged["ssh"], {"host": "1.2.3.4"})
        self.assertEqual(merged["mode"], "ssh")

    def test_non_dict_existing_ssh_is_replaced_not_crash(self):
        # If a corrupt config stored ssh as a scalar, merge must not blow up.
        merged = merge_config({"ssh": "corrupt"}, {"ssh": {"host": "1.2.3.4"}})
        self.assertEqual(merged["ssh"], {"host": "1.2.3.4"})

    def test_unrelated_sections_pass_through_untouched(self):
        existing = {"mac": {"host": "10.0.0.5"}, "ssh": {"host": "1.2.3.4"}}
        merged = merge_config(existing, {"ssh": {"user": "robotis"}})
        # mac is not in the update, so it must survive verbatim.
        self.assertEqual(merged["mac"], {"host": "10.0.0.5"})
        self.assertEqual(merged["ssh"], {"host": "1.2.3.4", "user": "robotis"})


if __name__ == "__main__":
    unittest.main()
