from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import darwin_switch_agent.preflight as preflight


class PreflightBundleTests(unittest.TestCase):
    def test_current_source_bundle_has_required_runtime_files(self):
        root = Path(__file__).resolve().parents[1]
        result = preflight.run_preinstall_audit(root, root / "config.example.json")
        bundle = next(check for check in result["checks"] if check["id"] == "bundle")
        config = next(check for check in result["checks"] if check["id"] == "config")
        self.assertEqual(bundle["level"], "good")
        self.assertEqual(config["level"], "good")

    def test_missing_required_file_is_bad(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "config.example.json").write_text('{"mode":"dry_run"}\n', encoding="utf-8")
            result = preflight.run_preinstall_audit(root, root / "config.example.json")
        bundle = next(check for check in result["checks"] if check["id"] == "bundle")
        self.assertEqual(bundle["level"], "bad")
        self.assertIn("누락", bundle["detail"])

    def test_bundle_only_skips_switch_environment_checks(self):
        root = Path(__file__).resolve().parents[1]
        with mock.patch.object(preflight.shutil, "which", return_value=None):
            result = preflight.run_preinstall_audit(
                root,
                root / "config.example.json",
                bundle_only=True,
            )
        checks = {check["id"]: check for check in result["checks"]}
        self.assertTrue(result["ok"])
        self.assertEqual(result["level"], "good")
        self.assertIn("bundle", checks)
        self.assertNotIn("systemd", checks)
        self.assertNotIn("browser", checks)


class PreflightEnvironmentTests(unittest.TestCase):
    def test_good_switch_like_environment(self):
        root = Path(__file__).resolve().parents[1]

        def fake_which(name):
            return {
                "systemctl": "/usr/bin/systemctl",
                "firefox": "/usr/bin/firefox",
                "ssh": "/usr/bin/ssh",
                "autossh": "/usr/bin/autossh",
            }.get(name)

        def fake_systemctl(*args):
            if args == ("is-active", "joycond.service"):
                return 0, "active"
            return 1, ""

        with mock.patch.object(preflight.sys, "platform", "linux"), \
            mock.patch.object(preflight.platform, "machine", return_value="aarch64"), \
            mock.patch.object(preflight, "_os_release", return_value={"ID": "ubuntu", "VERSION_ID": "24.04", "PRETTY_NAME": "L4T Ubuntu Noble"}), \
            mock.patch.object(preflight, "_gtk_runtime_check", return_value=preflight._check("gtk_runtime", "good", "GTK native runtime", "mock")), \
            mock.patch.object(preflight.shutil, "which", side_effect=fake_which), \
            mock.patch.object(preflight, "_systemctl", side_effect=fake_systemctl), \
            mock.patch.object(preflight.Path, "exists", return_value=True), \
            mock.patch.object(preflight.os, "access", return_value=True):
            result = preflight.run_preinstall_audit(root, root / "config.example.json")

        checks = {check["id"]: check for check in result["checks"]}
        self.assertEqual(checks["os"]["level"], "good")
        self.assertEqual(checks["l4t_ubuntu"]["level"], "good")
        self.assertEqual(checks["arch"]["level"], "good")
        self.assertEqual(checks["systemd"]["level"], "good")
        self.assertEqual(checks["browser"]["level"], "good")
        self.assertEqual(checks["gtk_runtime"]["level"], "good")
        self.assertEqual(checks["ssh_client"]["level"], "good")
        self.assertEqual(checks["autossh"]["level"], "good")
        self.assertEqual(checks["joycond"]["level"], "good")

    def test_installed_mode_checks_launchers_and_units(self):
        root = Path(__file__).resolve().parents[1]
        with mock.patch.object(preflight, "_installed_file_check", side_effect=lambda _path, check_id, title: preflight._check(check_id, "good", title, "mock")), \
            mock.patch.object(preflight, "_service_state_check", side_effect=lambda _unit, check_id, title: preflight._check(check_id, "good", title, "active")):
            result = preflight.run_preinstall_audit(root, root / "config.example.json", installed=True)
        ids = {check["id"] for check in result["checks"]}
        self.assertIn("bootstrap_launcher", ids)
        self.assertIn("diagnostics_launcher", ids)
        self.assertIn("input_check_launcher", ids)
        self.assertIn("network_check_launcher", ids)
        self.assertIn("preflight_launcher", ids)
        self.assertIn("robot_ready_launcher", ids)
        self.assertIn("smoke_test_launcher", ids)
        self.assertIn("agent_unit", ids)
        self.assertIn("camera_service", ids)

    def test_firefox_esr_counts_as_kiosk_browser(self):
        def fake_which(name):
            return {"firefox-esr": "/usr/bin/firefox-esr"}.get(name)

        with mock.patch.object(preflight.shutil, "which", side_effect=fake_which):
            check = preflight._browser_check()

        self.assertEqual(check.level, "good")
        self.assertIn("firefox-esr", check.detail)

    def test_missing_gtk_runtime_warns_not_bad(self):
        with mock.patch.dict("sys.modules", {"gi": None}):
            check = preflight._gtk_runtime_check()

        self.assertEqual(check.id, "gtk_runtime")
        self.assertEqual(check.level, "warn")
        self.assertIn("python3-gi", check.fix)

    def test_plain_ubuntu_without_l4t_marker_warns(self):
        root = Path(__file__).resolve().parents[1]
        with mock.patch.object(preflight.sys, "platform", "linux"), \
            mock.patch.object(preflight, "_os_release", return_value={"ID": "ubuntu", "VERSION_ID": "24.04", "PRETTY_NAME": "Ubuntu 24.04"}), \
            mock.patch.object(preflight.Path, "exists", return_value=False):
            result = preflight.run_preinstall_audit(root, root / "config.example.json")
        checks = {check["id"]: check for check in result["checks"]}
        self.assertEqual(checks["l4t_ubuntu"]["level"], "warn")
        self.assertIn("L4T marker 미확인", checks["l4t_ubuntu"]["detail"])


if __name__ == "__main__":
    unittest.main()
