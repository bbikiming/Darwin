from __future__ import annotations

import unittest

from darwin_switch_agent.input_check import _capture_dict, _prefer_names
from darwin_switch_agent.input_check import CaptureSummary
from darwin_switch_agent.input_linux import DeviceProfile, resolve_role_codes, select_controller_profile


class InputCheckTests(unittest.TestCase):
    def test_prefer_names_falls_back_when_config_is_invalid(self):
        names = _prefer_names({"prefer_names": "Joy-Con"})
        self.assertIn("Nintendo Switch Combined Joy-Cons", names)

    def test_selected_profile_excludes_imu(self):
        imu = DeviceProfile("/dev/input/event1", "Nintendo Switch Combined Joy-Cons (IMU)", frozenset(), frozenset({0, 1}))
        combined = DeviceProfile("/dev/input/event2", "Nintendo Switch Combined Joy-Cons", frozenset({304, 305, 312, 313, 316}), frozenset({0, 1, 3, 4}))
        self.assertEqual(select_controller_profile([imu, combined]).path, "/dev/input/event2")

    def test_capture_dict_reports_seen_roles_and_axes(self):
        profile = DeviceProfile("/dev/input/event2", "Nintendo Switch Combined Joy-Cons", frozenset({304, 305, 312, 313, 316}), frozenset({0, 1, 3, 4}))
        mapping = {
            "deadman_key_codes": [312, 313],
            "arm_key_codes": [305],
            "stop_key_codes": [304],
            "estop_key_codes": [316],
            "left_x_abs_codes": [0],
            "left_y_abs_codes": [1],
            "right_x_abs_codes": [3],
            "right_y_abs_codes": [4],
        }
        roles = resolve_role_codes(profile, mapping)
        capture = CaptureSummary(seconds=8, event_count=4)
        capture.role_seen = {
            "deadman_key_codes": True,
            "arm_key_codes": True,
            "stop_key_codes": False,
            "estop_key_codes": False,
        }
        capture.axis_seen = {
            "left_x_abs_codes": True,
            "left_y_abs_codes": True,
            "right_x_abs_codes": False,
            "right_y_abs_codes": False,
        }
        capture.key_events = {312: 2, 305: 2}
        capture.axis_events = {0: 3, 1: 3}
        capture.axis_peak = {0: 0.5, 1: -0.75}
        result = _capture_dict(capture, mapping, roles)
        self.assertTrue(result["roles"]["deadman_key_codes"]["seen"])
        self.assertFalse(result["roles"]["stop_key_codes"]["seen"])
        self.assertTrue(result["axes"]["left_y_abs_codes"]["seen"])
        self.assertEqual(result["axis_events"]["1"]["peak"], -0.75)


if __name__ == "__main__":
    unittest.main()
