"""Unit tests for the Linux input role-resolution logic.

Run (no pytest needed):
  PYTHONPATH=tools/switch-pilot/src python3 -m unittest \
    tools/switch-pilot/tests/test_input_roles.py

No /dev access: the reader is constructed against a glob that matches nothing,
then _resolve_roles is driven with a synthetic DeviceProfile. Asserts device
preference ranking, IMU exclusion, axis normalization, the Nintendo default
role->code mapping, and that a config override naming a code the device lacks
falls back to the present defaults (so a typo can't disarm the deadman).
"""

from __future__ import annotations

import unittest

from darwin_switch_agent.input_linux import (
    DEFAULT_PREFER_NAMES,
    AxisInfo,
    DeviceProfile,
    LinuxInputReader,
    _prefer_rank,
)


COMBINED = "Nintendo Switch Combined Joy-Cons"
# A combined Joy-Con device: ZL=312 ZR=313 (deadman), A=305 (arm), B=304 (stop),
# Home=316 (estop), plus left/right stick axes.
COMBINED_KEYS = frozenset({304, 305, 312, 313, 316})
COMBINED_AXES = frozenset({0, 1, 3, 4})


def _combined_profile():
    return DeviceProfile(
        path="p", name=COMBINED, keys=COMBINED_KEYS, axes=COMBINED_AXES
    )


def _reader(mapping=None):
    # Glob matches nothing -> no devices opened, no /dev touched.
    return LinuxInputReader({"event_globs": ["/nope/event*"]}, mapping or {})


class PreferRankTests(unittest.TestCase):
    def test_combined_ranks_before_single(self):
        combined = _prefer_rank(COMBINED, DEFAULT_PREFER_NAMES)
        single = _prefer_rank("Joy-Con (R)", DEFAULT_PREFER_NAMES)
        unknown = _prefer_rank("Some Random Pad", DEFAULT_PREFER_NAMES)
        self.assertLess(combined, single)
        self.assertLess(single, unknown)

    def test_unknown_is_large(self):
        self.assertGreaterEqual(
            _prefer_rank("Some Random Pad", DEFAULT_PREFER_NAMES),
            len(DEFAULT_PREFER_NAMES),
        )


class DeviceProfileTests(unittest.TestCase):
    def test_imu_node_detected(self):
        imu = DeviceProfile(
            path="p", name="Joy-Cons (IMU)", keys=frozenset(), axes=frozenset({0, 1})
        )
        self.assertTrue(imu.is_imu)

    def test_combined_is_not_imu(self):
        self.assertFalse(_combined_profile().is_imu)

    def test_combined_is_controller(self):
        self.assertTrue(_combined_profile().is_controller)


class AxisInfoTests(unittest.TestCase):
    def test_center_normalizes_to_zero(self):
        self.assertAlmostEqual(AxisInfo(-32768, 32767).normalize(0), 0.0, places=3)

    def test_max_normalizes_to_one(self):
        self.assertAlmostEqual(AxisInfo(-32768, 32767).normalize(32767), 1.0, places=3)

    def test_min_normalizes_to_minus_one(self):
        self.assertAlmostEqual(AxisInfo(-32768, 32767).normalize(-32768), -1.0, places=3)


class ResolveRolesTests(unittest.TestCase):
    def test_default_nintendo_role_codes(self):
        reader = _reader()
        reader._resolve_roles(_combined_profile())
        roles = reader.role_codes
        self.assertEqual(roles["deadman_key_codes"], {312, 313})
        self.assertEqual(roles["arm_key_codes"], {305})
        self.assertEqual(roles["stop_key_codes"], {304})
        self.assertEqual(roles["estop_key_codes"], {316})

    def test_override_of_absent_code_falls_back_to_defaults(self):
        # Operator overrides deadman to code 999, which the device does NOT have.
        # The resolver must fall back to the present defaults rather than leaving
        # the deadman unbound.
        reader = _reader({"deadman_key_codes": [999]})
        reader._resolve_roles(_combined_profile())
        self.assertEqual(reader.role_codes["deadman_key_codes"], {312, 313})

    def test_override_of_present_code_is_honored(self):
        # 304 is on the device, so an explicit override is respected.
        reader = _reader({"arm_key_codes": [304]})
        reader._resolve_roles(_combined_profile())
        self.assertEqual(reader.role_codes["arm_key_codes"], {304})


if __name__ == "__main__":
    unittest.main()
