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

import tempfile
import types
import unittest
import socket
from unittest import mock
from pathlib import Path

import darwin_switch_agent.cockpit as cockpit
from darwin_switch_agent.cockpit import (
    CockpitHandler,
    merge_config,
    run_preflight,
    run_robot_command_status,
    run_robot_ready_action,
    run_service_action,
    run_system_action,
    _cockpit_browser_pids,
    run_system_health,
)


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


class StaticMetadataTests(unittest.TestCase):
    def test_webmanifest_uses_manifest_mime_type(self):
        self.assertEqual(
            CockpitHandler._content_type(types.SimpleNamespace(suffix=".webmanifest", name="manifest.webmanifest")),
            "application/manifest+json",
        )

    def test_service_worker_uses_javascript_mime_type(self):
        self.assertEqual(
            CockpitHandler._content_type(types.SimpleNamespace(suffix=".js", name="sw.js")),
            "text/javascript",
        )


class PreflightTests(unittest.TestCase):
    def test_dry_run_preflight_is_ok_with_camera_off(self):
        result = run_preflight({"mode": "dry_run", "camera": {"enabled": False}})
        self.assertTrue(result["ok"])
        self.assertEqual(result["level"], "warn")
        self.assertEqual(result["checks"][0]["level"], "good")

    def test_ssh_preflight_detects_open_tcp_port(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        try:
            result = run_preflight(
                {
                    "mode": "ssh",
                    "ssh": {"host": "127.0.0.1", "port": port, "identity_file": ""},
                    "camera": {"enabled": False},
                },
                timeout=0.2,
            )
        finally:
            listener.close()
        ssh_check = next(item for item in result["checks"] if item["id"] == "ssh")
        self.assertEqual(ssh_check["level"], "good")

    def test_camera_preflight_detects_open_stream_port(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        try:
            result = run_preflight(
                {
                    "mode": "dry_run",
                    "camera": {
                        "enabled": True,
                        "stream_url": f"http://127.0.0.1:{port}/?action=stream",
                    },
                },
                timeout=0.2,
            )
        finally:
            listener.close()
        camera_check = next(item for item in result["checks"] if item["id"] == "camera")
        self.assertEqual(camera_check["level"], "good")


class SystemHealthTests(unittest.TestCase):
    def test_health_reports_bad_when_no_kiosk_browser_exists(self):
        with tempfile.TemporaryDirectory() as tmp, \
            mock.patch.object(cockpit.shutil, "which", return_value=None), \
            mock.patch.object(cockpit, "_systemctl", return_value=(127, "")), \
            mock.patch.object(cockpit.glob, "glob", return_value=[]):
            result = run_system_health(str(Path(tmp) / "config.json"))

        self.assertFalse(result["ok"])
        self.assertEqual(result["level"], "bad")
        browser = next(item for item in result["checks"] if item["id"] == "browser")
        self.assertEqual(browser["level"], "bad")

    def test_health_is_good_when_native_runtime_bits_are_present(self):
        def fake_which(name):
            return {
                "firefox": "/usr/bin/firefox",
                "systemctl": "/usr/bin/systemctl",
                "darwin-switch-camera-tunnel": "/usr/local/bin/darwin-switch-camera-tunnel",
                "autossh": "/usr/bin/autossh",
            }.get(name)

        def fake_systemctl(*args):
            if args == ("is-active", "darwin-switch-agent.service"):
                return 0, "active"
            if args == ("is-active", "darwin-switch-camera-tunnel.service"):
                return 0, "active"
            if args == ("is-active", "joycond.service"):
                return 0, "active"
            return 1, ""

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.json"
            config_path.write_text('{"mode":"dry_run"}\n', encoding="utf-8")
            with mock.patch.object(cockpit.shutil, "which", side_effect=fake_which), \
                mock.patch.object(cockpit, "_systemctl", side_effect=fake_systemctl), \
                mock.patch.object(cockpit.glob, "glob", return_value=["/dev/input/event0"]), \
                mock.patch.object(cockpit.os, "access", return_value=True):
                result = run_system_health(str(config_path))

        self.assertTrue(result["ok"])
        self.assertEqual(result["level"], "good")
        self.assertEqual({item["level"] for item in result["checks"]}, {"good"})
        self.assertIn("camera_tunnel_service", {item["id"] for item in result["checks"]})

    def test_xdg_open_only_is_warn_not_native_kiosk_good(self):
        def fake_which(name):
            return {
                "xdg-open": "/usr/bin/xdg-open",
                "systemctl": "/usr/bin/systemctl",
                "darwin-switch-camera-tunnel": "/usr/local/bin/darwin-switch-camera-tunnel",
                "autossh": "/usr/bin/autossh",
            }.get(name)

        def fake_systemctl(*args):
            if args == ("is-active", "darwin-switch-agent.service"):
                return 0, "active"
            if args == ("is-active", "darwin-switch-camera-tunnel.service"):
                return 0, "active"
            if args == ("is-active", "joycond.service"):
                return 0, "active"
            return 1, ""

        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.json"
            config_path.write_text('{"mode":"dry_run"}\n', encoding="utf-8")
            with mock.patch.object(cockpit.shutil, "which", side_effect=fake_which), \
                mock.patch.object(cockpit, "_systemctl", side_effect=fake_systemctl), \
                mock.patch.object(cockpit.glob, "glob", return_value=["/dev/input/event0"]), \
                mock.patch.object(cockpit.os, "access", return_value=True):
                result = run_system_health(str(config_path))

        browser = next(item for item in result["checks"] if item["id"] == "browser")
        self.assertTrue(result["ok"])
        self.assertEqual(result["level"], "warn")
        self.assertEqual(browser["level"], "warn")
        self.assertIn("fullscreen kiosk", browser["detail"])


class ServiceActionTests(unittest.TestCase):
    def test_rejects_unknown_service_action(self):
        result = run_service_action("camera_tunnel", "format_disk")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "unknown service action")

    def test_rejects_unknown_service(self):
        result = run_service_action("robot_power", "enable_now")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "unknown service")

    def test_camera_tunnel_enable_now_uses_whitelisted_systemctl_command(self):
        calls = []

        def fake_systemctl(*args):
            calls.append(args)
            if args == ("is-active", "darwin-switch-camera-tunnel.service"):
                return 0, "active"
            return 1, ""

        with mock.patch.object(cockpit.shutil, "which", return_value="/usr/bin/systemctl"), \
            mock.patch.object(cockpit, "_systemctl_slow", return_value=(0, "")) as slow, \
            mock.patch.object(cockpit, "_systemctl", side_effect=fake_systemctl):
            result = run_service_action("camera_tunnel", "enable_now")

        self.assertTrue(result["ok"])
        slow.assert_called_once_with("enable", "--now", "darwin-switch-camera-tunnel.service")
        self.assertEqual(calls, [("is-active", "darwin-switch-camera-tunnel.service")])

    def test_agent_restart_uses_whitelisted_systemctl_command(self):
        calls = []

        def fake_systemctl(*args):
            calls.append(args)
            if args == ("is-active", "darwin-switch-agent.service"):
                return 0, "active"
            return 1, ""

        with mock.patch.object(cockpit.shutil, "which", return_value="/usr/bin/systemctl"), \
            mock.patch.object(cockpit, "_systemctl_slow", return_value=(0, "")) as slow, \
            mock.patch.object(cockpit, "_systemctl", side_effect=fake_systemctl):
            result = run_service_action("agent", "restart")

        self.assertTrue(result["ok"])
        slow.assert_called_once_with("restart", "darwin-switch-agent.service")
        self.assertEqual(calls, [("is-active", "darwin-switch-agent.service")])


class SystemActionTests(unittest.TestCase):
    def test_rejects_unknown_system_action(self):
        result = run_system_action("reboot")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "unknown system action")

    def test_exit_app_terminates_detected_cockpit_browser_pids(self):
        with mock.patch.object(cockpit, "_cockpit_browser_pids", return_value=[123, 456]), \
            mock.patch.object(cockpit.subprocess, "Popen") as popen:
            result = run_system_action("exit_app")

        self.assertTrue(result["ok"])
        self.assertEqual(result["pids"], [123, 456])
        popen.assert_called_once()
        command = popen.call_args.args[0]
        self.assertEqual(command[:2], ["sh", "-c"])
        self.assertIn("kill -TERM 123 456", command[2])

    def test_cockpit_browser_pid_detection_from_proc_cmdline(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            (proc / "100").mkdir()
            (proc / "100" / "cmdline").write_bytes(
                b"/opt/chromium/chrome\0--user-data-dir=/home/yuseok/.cache/darwin-switch-cockpit/chromium\0http://127.0.0.1:8765/\0"
            )
            (proc / "101").mkdir()
            (proc / "101" / "cmdline").write_bytes(b"/usr/bin/python3\0-m\0darwin_switch_agent.main\0")

            self.assertEqual(_cockpit_browser_pids(str(proc)), [100])


class RobotReadyActionTests(unittest.TestCase):
    def test_rejects_interactive_copy_key_action(self):
        result = run_robot_ready_action("copy-key")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "unknown robot-ready action")

    def test_runs_whitelisted_robot_ready_action(self):
        captured = {}

        def fake_run(args, **kwargs):
            captured["args"] = args
            captured["kwargs"] = kwargs
            return cockpit.subprocess.CompletedProcess(args=args, returncode=0, stdout="Robot SSH target: x\n", stderr="")

        with mock.patch.object(cockpit.shutil, "which", return_value="/usr/local/bin/darwin-switch-robot-ready"), \
            mock.patch.object(cockpit.subprocess, "run", side_effect=fake_run):
            result = run_robot_ready_action("plan", "/tmp/config.json")

        self.assertTrue(result["ok"])
        self.assertEqual(result["stdout"], "Robot SSH target: x\n")
        self.assertEqual(captured["args"], ["/usr/local/bin/darwin-switch-robot-ready", "--config", "/tmp/config.json", "plan"])
        self.assertGreaterEqual(captured["kwargs"]["timeout"], 1.0)


class RobotCommandStatusTests(unittest.TestCase):
    def test_rejects_when_config_not_ssh_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text('{"mode":"dry_run"}\n', encoding="utf-8")
            result = run_robot_command_status(str(path))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "mode is not ssh")

    def test_reads_command_status_with_ssh_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(
                '{"mode":"ssh","ssh":{"host":"192.168.0.33","identity_file":""}}\n',
                encoding="utf-8",
            )
            with mock.patch.object(cockpit.SshControlClient, "command_status", return_value={"raw": "abc"}), \
                mock.patch.object(cockpit.SshControlClient, "close", return_value=None):
                result = run_robot_command_status(str(path))
        self.assertTrue(result["ok"])
        self.assertEqual(result["status"], {"raw": "abc"})


class ProvisioningStateTests(unittest.TestCase):
    @staticmethod
    def _fake_handler(config_path: str):
        return types.SimpleNamespace(config_path=config_path)

    def test_unprovisioned_when_marker_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = self._fake_handler(str(Path(tmp) / "config.json"))
            self.assertFalse(CockpitHandler._is_provisioned(fake))

    def test_provisioned_when_marker_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, ".provisioned").write_text("1\n", encoding="utf-8")
            fake = self._fake_handler(str(Path(tmp) / "config.json"))
            self.assertTrue(CockpitHandler._is_provisioned(fake))

    def test_write_config_drops_provisioning_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "config.json"
            config_path.write_text('{"mode":"dry_run"}\n', encoding="utf-8")
            fake = self._fake_handler(str(config_path))
            CockpitHandler._write_config(fake, {"mode": "ssh"})
            self.assertTrue((Path(tmp) / ".provisioned").is_file())


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
