from __future__ import annotations

import subprocess
import tempfile
import unittest
import contextlib
import io
from pathlib import Path
from unittest import mock

from darwin_switch_agent.config import AgentConfig
from darwin_switch_agent import robot_ready


class RobotReadyConfigTests(unittest.TestCase):
    def test_defaults_match_darwinforge_robot(self):
        cfg = robot_ready.robot_ssh_config(AgentConfig({"ssh": {}}))
        self.assertEqual(cfg.host, "192.168.123.1")
        self.assertEqual(cfg.user, "robotis")
        self.assertEqual(cfg.port, 22)
        self.assertEqual(cfg.identity_file, "~/.ssh/id_rsa_darwin")

    def test_copy_key_command_uses_legacy_rsa_options(self):
        cfg = robot_ready.RobotSshConfig(
            host="10.0.0.7",
            user="robotis",
            port=2222,
            identity_file="~/.ssh/id_rsa_darwin",
            timeout_seconds=6,
            connect_timeout_seconds=2,
        )
        cmd = robot_ready.copy_key_command(cfg)
        joined = " ".join(cmd)
        self.assertIn("PubkeyAcceptedAlgorithms=+ssh-rsa", joined)
        self.assertIn("HostKeyAlgorithms=+ssh-rsa", joined)
        self.assertIn("2222", cmd)
        self.assertEqual(cmd[-1], "robotis@10.0.0.7")


class RobotReadySshTests(unittest.TestCase):
    def test_run_ssh_uses_shared_darwinforge_args(self):
        cfg = robot_ready.RobotSshConfig(
            host="h",
            user="u",
            port=22,
            identity_file=None,
            timeout_seconds=6,
            connect_timeout_seconds=2,
        )
        captured = {}

        def fake_run(args, **kwargs):
            captured["args"] = args
            captured["kwargs"] = kwargs
            return subprocess.CompletedProcess(args=args, returncode=0, stdout="ok\n", stderr="")

        with mock.patch.object(robot_ready.subprocess, "run", side_effect=fake_run):
            proc = robot_ready.run_ssh(cfg, "echo ok")
        self.assertEqual(proc.stdout, "ok\n")
        joined = " ".join(captured["args"])
        self.assertIn("BatchMode=yes", joined)
        self.assertIn("StrictHostKeyChecking=accept-new", joined)
        self.assertIn("ServerAliveInterval=2", joined)
        self.assertIn("HostKeyAlgorithms=+ssh-rsa", joined)
        self.assertEqual(captured["args"][-2:], ["u@h", "echo ok"])

    def test_run_ssh_timeout_degrades_cleanly(self):
        # 느린 링크에서 traceback 으로 죽지 말고 returncode=124 로 신호.
        cfg = robot_ready.RobotSshConfig(
            host="h", user="u", port=22, identity_file=None,
            timeout_seconds=6, connect_timeout_seconds=2,
        )
        with mock.patch.object(
            robot_ready.subprocess, "run",
            side_effect=subprocess.TimeoutExpired(cmd=["ssh"], timeout=10, output="", stderr=""),
        ):
            proc = robot_ready.run_ssh(cfg, "slow command", timeout=10)
        self.assertEqual(proc.returncode, 124)
        self.assertIn("timed out", proc.stderr)

    def test_keygen_skips_existing_identity_pair(self):
        with mock.patch.object(Path, "is_file", return_value=True), \
             mock.patch.object(robot_ready.subprocess, "run") as run:
            created = robot_ready.ensure_identity(Path("/tmp/id_rsa_darwin"))
        self.assertFalse(created)
        run.assert_not_called()


class AgentConfigWriteTests(unittest.TestCase):
    def test_enable_agent_ssh_writes_mode_and_transport(self):
        cfg = robot_ready.RobotSshConfig(
            host="192.168.123.1",
            user="robotis",
            port=22,
            identity_file="~/.ssh/id_rsa_darwin",
            timeout_seconds=6,
            connect_timeout_seconds=2,
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text('{"mode":"dry_run","ssh":{"send_hz":5},"camera":{"enabled":true}}\n', encoding="utf-8")
            robot_ready.write_agent_ssh_mode(path, cfg)
            data = __import__("json").loads(path.read_text(encoding="utf-8"))
        self.assertEqual(data["mode"], "ssh")
        self.assertEqual(data["ssh"]["host"], "192.168.123.1")
        self.assertEqual(data["ssh"]["user"], "robotis")
        # 2026-06-07: identity 는 절대경로로 저장 (~ 는 systemd 에서 /root 로 풀려 실패).
        self.assertFalse(data["ssh"]["identity_file"].startswith("~"))
        self.assertTrue(data["ssh"]["identity_file"].endswith("/.ssh/id_rsa_darwin"))
        self.assertEqual(data["ssh"]["send_hz"], 5)
        self.assertTrue(data["camera"]["enabled"])

    def test_enable_agent_ssh_command_restarts_service_when_requested(self):
        cfg = robot_ready.RobotSshConfig(
            host="h",
            user="u",
            port=22,
            identity_file=None,
            timeout_seconds=6,
            connect_timeout_seconds=2,
        )
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(robot_ready, "restart_agent_service", return_value=True) as restart:
            path = Path(tmp) / "config.json"
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = robot_ready.cmd_enable_agent_ssh(cfg, path, restart=True)
        self.assertEqual(code, 0)
        restart.assert_called_once()


class RobotHostOverrideTests(unittest.TestCase):
    def test_host_override_replaces_config_host(self):
        cfg = robot_ready.robot_ssh_config(
            AgentConfig({"ssh": {"host": "192.168.123.1", "user": "robotis", "port": 22}}),
            host_override="192.168.0.100",
        )
        self.assertEqual(cfg.host, "192.168.0.100")
        self.assertEqual(cfg.user, "robotis")

    def test_blank_override_falls_back_to_config(self):
        cfg = robot_ready.robot_ssh_config(
            AgentConfig({"ssh": {"host": "10.0.0.7"}}),
            host_override="   ",
        )
        self.assertEqual(cfg.host, "10.0.0.7")

    def test_user_and_port_override(self):
        cfg = robot_ready.robot_ssh_config(
            AgentConfig({"ssh": {"host": "h", "user": "robotis", "port": 22}}),
            user_override="darwin",
            port_override=2222,
        )
        self.assertEqual(cfg.user, "darwin")
        self.assertEqual(cfg.port, 2222)

    def test_enable_agent_ssh_persists_overridden_host(self):
        # 핵심: --robot-host 로 닿는 IP 를 주면 그게 config 에 영구 기록되어야 함.
        cfg = robot_ready.robot_ssh_config(
            AgentConfig({"ssh": {"host": "192.168.123.1"}}),
            host_override="192.168.0.100",
        )
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text('{"mode": "dry_run", "ssh": {"host": "192.168.123.1"}}', encoding="utf-8")
            code = robot_ready.cmd_enable_agent_ssh(cfg, path, restart=False)
            self.assertEqual(code, 0)
            import json as _json
            written = _json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(written["mode"], "ssh")
            self.assertEqual(written["ssh"]["host"], "192.168.0.100")


class IdentityAbsolutePathTests(unittest.TestCase):
    def test_absolute_identity_expands_tilde(self):
        out = robot_ready.absolute_identity_file("~/.ssh/id_rsa_darwin")
        self.assertFalse(out.startswith("~"), "~ 가 남으면 systemd 가 /root 로 풀어 실패")
        self.assertTrue(out.startswith("/"), "절대경로여야 함")
        self.assertTrue(out.endswith("/.ssh/id_rsa_darwin"))

    def test_absolute_identity_keeps_existing_absolute(self):
        out = robot_ready.absolute_identity_file("/home/yuseok/.ssh/id_rsa_darwin")
        self.assertEqual(out, "/home/yuseok/.ssh/id_rsa_darwin")

    def test_enable_agent_ssh_never_persists_tilde(self):
        # 실기기 버그 회귀 차단: config 에 ~ 가 저장되면 안 됨.
        cfg = robot_ready.robot_ssh_config(
            AgentConfig({"ssh": {"host": "192.168.0.33", "identity_file": "~/.ssh/id_rsa_darwin"}}),
            host_override="192.168.0.33",
        )
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text('{"mode": "dry_run", "ssh": {}}', encoding="utf-8")
            robot_ready.cmd_enable_agent_ssh(cfg, path, restart=False)
            import json as _json
            written = _json.loads(path.read_text(encoding="utf-8"))
            idf = written["ssh"]["identity_file"]
            self.assertFalse(idf.startswith("~"), f"~ 저장 금지, got {idf}")
            self.assertTrue(idf.startswith("/"), "절대경로 저장")


class StabilizeTests(unittest.TestCase):
    def test_stabilize_writes_tuning_and_absolute_identity(self):
        cfg = robot_ready.robot_ssh_config(
            AgentConfig({"ssh": {"host": "192.168.0.33", "identity_file": "~/.ssh/id_rsa_darwin"}}),
            host_override="192.168.0.33",
        )
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text('{"mode": "ssh", "ssh": {}}', encoding="utf-8")
            code = robot_ready.cmd_stabilize(cfg, path, restart=False)
            self.assertEqual(code, 0)
            import json as _json
            written = _json.loads(path.read_text(encoding="utf-8"))
            ssh = written["ssh"]
            motion = written["motion"]
            self.assertEqual(ssh["send_hz"], 5)
            self.assertEqual(ssh["telemetry_hz"], 1)
            self.assertEqual(ssh["heartbeat_ms"], 900)
            self.assertEqual(ssh["connect_timeout_seconds"], 3)
            self.assertEqual(ssh["min_period_ms"], 500)
            self.assertEqual(ssh["max_period_ms"], 860)
            self.assertEqual(ssh["host"], "192.168.0.33")
            self.assertFalse(ssh["identity_file"].startswith("~"))
            self.assertEqual(motion["max_stride_mm"], 38)
            self.assertEqual(motion["max_side_mm"], 22)
            self.assertTrue(motion["hold_head_position"])

    def test_atomic_write_raises_clean_permission_error_when_sudo_needs_password(self):
        # 비대화형 SSH(터미널 없음)에서 sudo -n 이 실패하면 traceback 이 아니라
        # PermissionError 로 깔끔히 신호 → caller 가 fallback 안내.
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text('{"ssh":{}}', encoding="utf-8")
            with mock.patch.object(robot_ready.os, "replace", side_effect=PermissionError()):
                with mock.patch.object(
                    robot_ready.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 1, "", "sudo: a password is required"),
                ):
                    with self.assertRaises(PermissionError):
                        robot_ready._atomic_write_config(path, "x")

    def test_stabilize_returns_clean_code_when_no_sudo(self):
        # crash 가 아니라 exit code 2 + 안내 메시지.
        cfg = robot_ready.robot_ssh_config(AgentConfig({"ssh": {}}), host_override="192.168.0.33")
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "config.json"
            path.write_text('{"ssh":{}}', encoding="utf-8")
            with mock.patch.object(robot_ready, "_atomic_write_config",
                                   side_effect=PermissionError(str(path))):
                code = robot_ready.cmd_stabilize(cfg, path, restart=False)
        self.assertEqual(code, 2)


class ReachabilityTests(unittest.TestCase):
    def test_tcp_reachable_true_for_open_port(self):
        import socket

        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        try:
            self.assertTrue(robot_ready.tcp_reachable("127.0.0.1", port, 1.0))
        finally:
            srv.close()

    def test_tcp_reachable_false_for_closed_port(self):
        # 0.x 테스트망의 닫힌 포트 — 빠른 실패.
        self.assertFalse(robot_ready.tcp_reachable("127.0.0.1", 1, 0.3))

    def test_cmd_reachability_reports_first_open(self):
        # tcp_reachable 를 패치해 결정적으로 — 두 번째만 open.
        def fake(host, port, timeout):
            return host == "192.168.0.100"

        out = io.StringIO()
        with mock.patch.object(robot_ready, "tcp_reachable", side_effect=fake):
            with contextlib.redirect_stdout(out):
                code = robot_ready.cmd_reachability(["192.168.123.1", "192.168.0.100"], 22, 1.0)
        text = out.getvalue()
        self.assertEqual(code, 0)
        self.assertIn("DF_REACHABLE=192.168.0.100", text)
        self.assertIn("reach=192.168.123.1:22 closed", text)

    def test_cmd_reachability_none_when_all_closed(self):
        out = io.StringIO()
        with mock.patch.object(robot_ready, "tcp_reachable", side_effect=lambda *a: False):
            with contextlib.redirect_stdout(out):
                code = robot_ready.cmd_reachability(["a", "b"], 22, 0.5)
        self.assertEqual(code, 1)
        self.assertIn("DF_REACHABLE=none", out.getvalue())

    def test_main_reachability_requires_candidates(self):
        code = robot_ready.main(["reachability", "--config", "/nonexistent", "--candidates", ""])
        self.assertEqual(code, 2)


class RemoteScriptTests(unittest.TestCase):
    def test_status_script_requires_switch_fix_binary_content_not_filename(self):
        self.assertIn('grep -qa "ROBOTIS onboard brokerage, switch fix"', robot_ready.REMOTE_STATUS_SCRIPT)
        self.assertIn("walklab_patch=old", robot_ready.REMOTE_STATUS_SCRIPT)
        self.assertIn("walklab_patch=present", robot_ready.REMOTE_STATUS_SCRIPT)

    def test_start_script_refuses_old_or_unpatched_demo(self):
        self.assertIn("DF_READY_START=old_walklab_patch", robot_ready.REMOTE_START_WALKLAB_SCRIPT)
        self.assertIn("DF_READY_START=missing_walklab_patch", robot_ready.REMOTE_START_WALKLAB_SCRIPT)
        self.assertIn('grep -qa "ROBOTIS onboard brokerage, switch fix"', robot_ready.REMOTE_START_WALKLAB_SCRIPT)
        self.assertIn("echo walklab > /tmp/df-pilot-mode", robot_ready.REMOTE_START_WALKLAB_SCRIPT)
        self.assertIn(": > /tmp/df-walklab-cmd", robot_ready.REMOTE_START_WALKLAB_SCRIPT)
        self.assertIn("DF_READY_CAMERA_STOP=begin", robot_ready.REMOTE_START_WALKLAB_SCRIPT)
        self.assertIn("DF_READY_CAMERA=running", robot_ready.REMOTE_START_WALKLAB_SCRIPT)


if __name__ == "__main__":
    unittest.main()
