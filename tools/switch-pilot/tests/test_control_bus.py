"""Unit tests for ControlBus — the agent/cockpit state + command bridge.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_control_bus.py

Asserts: actions queue round-trips a request through drain_actions; telemetry
publishes the robot-state keys the cockpit reads; the log ring stays bounded in
the snapshot; and snapshot() hands back a copy so callers cannot mutate bus
state in place.
"""

from __future__ import annotations

import unittest
import tempfile
import socket
from pathlib import Path

from darwin_switch_agent.control_bus import ControlAction, ControlBus, read_camera_runtime, read_switch_battery


class ActionQueueTests(unittest.TestCase):
    def test_request_then_drain_returns_one_action(self):
        bus = ControlBus()
        bus.request("arm")
        actions = bus.drain_actions()
        self.assertEqual(actions, [ControlAction(action="arm", source="cockpit")])

    def test_drain_is_exhaustive_and_repeatable(self):
        bus = ControlBus()
        bus.request("arm")
        bus.request("estop", source="watchdog")
        first = bus.drain_actions()
        self.assertEqual([a.action for a in first], ["arm", "estop"])
        self.assertEqual(first[1].source, "watchdog")
        self.assertEqual(bus.drain_actions(), [])


class TelemetryTests(unittest.TestCase):
    def test_publish_telemetry_sets_robot_keys(self):
        bus = ControlBus()
        bus.publish_telemetry(
            ssh_connected=True,
            link_latency_ms=12,
            battery_v=12.2,
            battery_pct=81,
            walking=True,
            fallen=0,
            robot_state="walking",
            gyro={"x": 11, "y": -22, "z": 33},
            accel={"x": 444, "y": 555, "z": 666},
        )
        snap = bus.snapshot()
        self.assertTrue(snap["ssh_connected"])
        self.assertEqual(snap["link_latency_ms"], 12)
        self.assertEqual(snap["battery_v"], 12.2)
        self.assertEqual(snap["battery_pct"], 81)
        self.assertTrue(snap["robot_walking"])
        self.assertEqual(snap["robot_fallen"], 0)
        self.assertEqual(snap["robot_state"], "walking")
        self.assertEqual(snap["imu"]["source"], "robot")
        self.assertEqual(snap["imu"]["gyro_z"], 33)
        self.assertEqual(snap["imu"]["accel_z"], 666)

    def test_default_telemetry_keys_present(self):
        snap = ControlBus().snapshot()
        for key in (
            "ssh_connected",
            "link_latency_ms",
            "battery_v",
            "battery_pct",
            "robot_walking",
            "robot_fallen",
            "robot_state",
            "imu",
            "switch_battery",
            "camera_runtime",
        ):
            self.assertIn(key, snap)


class SwitchBatteryTests(unittest.TestCase):
    def test_reads_switch_battery_from_power_supply(self):
        with tempfile.TemporaryDirectory() as tmp:
            ac = Path(tmp) / "usb"
            ac.mkdir()
            (ac / "type").write_text("USB\n", encoding="utf-8")
            batt = Path(tmp) / "max170xx_battery"
            batt.mkdir()
            (batt / "type").write_text("Battery\n", encoding="utf-8")
            (batt / "capacity").write_text("73\n", encoding="utf-8")
            (batt / "status").write_text("Charging\n", encoding="utf-8")

            result = read_switch_battery(tmp)

        self.assertEqual(result["percent"], 73)
        self.assertTrue(result["charging"])
        self.assertEqual(result["source"], "max170xx_battery")


class CameraRuntimeTests(unittest.TestCase):
    def test_reports_camera_port_closed(self):
        result = read_camera_runtime(
            {"enabled": True, "snapshot_url": "http://127.0.0.1:1/?action=snapshot"},
            timeout=0.001,
        )
        self.assertEqual(result["status"], "port_closed")
        self.assertFalse(result["local_port_open"])
        self.assertEqual(result["port"], 1)

    def test_reports_camera_port_open(self):
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        sock.listen(1)
        port = sock.getsockname()[1]
        try:
            result = read_camera_runtime(
                {"enabled": True, "snapshot_url": f"http://127.0.0.1:{port}/?action=snapshot"},
                timeout=0.05,
            )
        finally:
            sock.close()
        self.assertEqual(result["status"], "port_open")
        self.assertTrue(result["local_port_open"])
        self.assertEqual(result["port"], port)


class LogRingTests(unittest.TestCase):
    def test_snapshot_logs_bounded_to_eight(self):
        bus = ControlBus()
        for i in range(20):
            bus.log(f"line {i}")
        self.assertLessEqual(len(bus.snapshot()["logs"]), 8)

    def test_logs_newest_first(self):
        bus = ControlBus()
        bus.log("oldest")
        bus.log("newest")
        logs = bus.snapshot()["logs"]
        self.assertIn("newest", logs[0])


class ImmutabilityTests(unittest.TestCase):
    def test_snapshot_is_a_copy(self):
        bus = ControlBus()
        snap = bus.snapshot()
        self.assertIsNot(snap, bus.snapshot())
        snap["robot_state"] = "tampered"
        self.assertNotEqual(bus.snapshot()["robot_state"], "tampered")

    def test_top_level_key_set_does_not_leak(self):
        # snapshot() returns a fresh top-level dict, so replacing a key on the
        # returned dict must not change what the next snapshot reports.
        bus = ControlBus()
        snap = bus.snapshot()
        snap["robot_walking"] = True
        snap["logs"] = ["replaced"]
        nxt = bus.snapshot()
        self.assertFalse(nxt["robot_walking"])
        self.assertNotIn("replaced", nxt["logs"])

    def test_in_place_log_mutation_does_not_leak(self):
        # The nested log list must be a copy: a cockpit caller doing
        # snapshot()["logs"].append(...) must not mutate the bus's log ring.
        bus = ControlBus()
        bus.log("first")
        snap = bus.snapshot()
        snap["logs"].append("injected by caller")
        nxt = bus.snapshot()
        self.assertNotIn("injected by caller", nxt["logs"])

    def test_in_place_nested_dict_mutation_does_not_leak(self):
        # controller/command/camera are nested dicts; mutating them on the
        # returned snapshot must not bleed into the bus's internal state.
        bus = ControlBus()
        snap = bus.snapshot()
        snap["camera"]["label"] = "tampered"
        snap["controller"]["left_x"] = 99.0
        nxt = bus.snapshot()
        self.assertNotEqual(nxt["camera"].get("label"), "tampered")
        self.assertNotIn("left_x", nxt["controller"])


if __name__ == "__main__":
    unittest.main()
