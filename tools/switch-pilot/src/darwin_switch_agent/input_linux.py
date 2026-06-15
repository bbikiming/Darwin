from __future__ import annotations

import glob
import logging
import os
import selectors
import struct
import fcntl
from dataclasses import dataclass, field
from typing import Iterable


EV_KEY = 0x01
EV_ABS = 0x03

# evdev button constants. NOTE the Nintendo A/B swap: on hid-nintendo the
# physical A button reports BTN_EAST (305) and physical B reports BTN_SOUTH
# (304) — the opposite of an Xbox layout. ZL/ZR are the shoulder triggers.
BTN_SOUTH = 0x130  # 304  physical B (Nintendo)
BTN_EAST = 0x131  # 305  physical A (Nintendo)
BTN_TL = 0x136  # 310  L
BTN_TR = 0x137  # 311  R
BTN_TL2 = 0x138  # 312  ZL
BTN_TR2 = 0x139  # 313  ZR
BTN_SELECT = 0x13A  # 314  Minus
BTN_START = 0x13B  # 315  Plus
BTN_MODE = 0x13C  # 316  Home

ABS_X = 0
ABS_Y = 1

KEY_COUNT = 0x300  # KEY_MAX (0x2ff) + 1
ABS_COUNT = 0x40  # ABS_MAX (0x3f) + 1

# Default controller name preference, highest first. The combined virtual
# device created by joycond exposes BOTH rails' buttons, so it is preferred
# over a single rail (a lone right Joy-Con has no ZL deadman).
DEFAULT_PREFER_NAMES = (
    "Nintendo Switch Combined Joy-Cons",
    "Joycon (Combined)",
    "Pro Controller",
    "Joy-Con (R)",
    "Joy-Con (L)",
    "Nintendo",
)

# Role -> default evdev codes, resolved at runtime against the device's actual
# capabilities. Config-provided codes (if any) take precedence as an override.
DEFAULT_ROLE_CODES = {
    "deadman_key_codes": (BTN_TL2, BTN_TR2),  # ZL or ZR — either trigger
    "arm_key_codes": (BTN_EAST,),  # A
    "stop_key_codes": (BTN_SOUTH,),  # B
    "estop_key_codes": (BTN_MODE,),  # Home
}

_IOC_READ = 2


def _ioc(direction: int, type_: int, nr: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (type_ << 8) | nr


def eviocgname(length: int) -> int:
    return _ioc(_IOC_READ, ord("E"), 0x06, length)


def eviocgbit(ev_type: int, length: int) -> int:
    return _ioc(_IOC_READ, ord("E"), 0x20 + ev_type, length)


def eviocgabs(abs_code: int) -> int:
    return _ioc(_IOC_READ, ord("E"), 0x40 + int(abs_code), 24)


@dataclass
class ControllerState:
    left_x: float = 0.0
    left_y: float = 0.0
    right_x: float = 0.0
    right_y: float = 0.0
    deadman: bool = False
    arm: bool = False
    stop: bool = False
    estop: bool = False
    buttons_mask: int = 0
    raw_keys: dict[int, bool] = field(default_factory=dict)


@dataclass(frozen=True)
class AxisInfo:
    minimum: int = -32768
    maximum: int = 32767

    def normalize(self, value: int) -> float:
        lo = self.minimum
        hi = self.maximum
        if hi <= lo:
            if -32768 <= value <= 32767:
                return max(-1.0, min(1.0, value / 32767.0))
            return 0.0
        center = (hi + lo) / 2.0
        half = max(1.0, (hi - lo) / 2.0)
        return max(-1.0, min(1.0, (float(value) - center) / half))


@dataclass(frozen=True)
class DeviceProfile:
    """Inspected capabilities of one /dev/input/event* node."""

    path: str
    name: str
    keys: frozenset[int]
    axes: frozenset[int]

    @property
    def is_imu(self) -> bool:
        # hid-nintendo exposes the gyro/accel as a separate "<base> (IMU)" node
        # whose stray ABS axes must never be read as joystick sticks.
        return "imu" in self.name.lower()

    @property
    def is_controller(self) -> bool:
        return (BTN_SOUTH in self.keys or BTN_EAST in self.keys) or (ABS_X in self.axes)


def _read_name(fd: int) -> str:
    buf = bytearray(256)
    try:
        fcntl.ioctl(fd, eviocgname(len(buf)), buf)
    except OSError:
        return ""
    return bytes(buf).split(b"\x00", 1)[0].decode("utf-8", "replace")


def _read_codes(fd: int, ev_type: int, count: int) -> frozenset[int]:
    nbytes = (count // 8) + 1
    buf = bytearray(nbytes)
    try:
        fcntl.ioctl(fd, eviocgbit(ev_type, nbytes), buf)
    except OSError:
        return frozenset()
    return frozenset(c for c in range(count) if buf[c >> 3] & (1 << (c & 7)))


def _prefer_rank(name: str, prefer_names: Iterable[str]) -> int:
    """Lower is better. Returns position in the preference list, else a big number."""
    lowered = name.lower()
    for index, wanted in enumerate(prefer_names):
        if wanted and wanted.lower() in lowered:
            return index
    return len(tuple(prefer_names)) + 10


def inspect_input_profiles(input_config: dict, log: logging.Logger | None = None) -> list[DeviceProfile]:
    """Inspect configured /dev/input/event* nodes without registering them.

    Shared by the live controller reader and the read-only field input checker
    so both tools see identical device names/capabilities.
    """
    patterns = input_config.get("event_globs", ["/dev/input/event*"])
    paths: list[str] = []
    for pattern in patterns:
        paths.extend(sorted(glob.glob(str(pattern))))
    profiles: list[DeviceProfile] = []
    for path in paths:
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except PermissionError:
            if log:
                log.warning("permission denied for %s; run as root or add the input group", path)
            continue
        except OSError as exc:
            if log:
                log.debug("skipping input device %s: %s", path, exc)
            continue
        try:
            profiles.append(
                DeviceProfile(
                    path=path,
                    name=_read_name(fd),
                    keys=_read_codes(fd, EV_KEY, KEY_COUNT),
                    axes=_read_codes(fd, EV_ABS, ABS_COUNT),
                )
            )
        finally:
            os.close(fd)
    return profiles


def select_controller_profile(
    profiles: Iterable[DeviceProfile],
    prefer_names: Iterable[str] = DEFAULT_PREFER_NAMES,
) -> DeviceProfile | None:
    controllers = [p for p in profiles if p.is_controller and not p.is_imu]
    if not controllers:
        return None
    return min(controllers, key=lambda p: (_prefer_rank(p.name, prefer_names), p.path))


def resolve_role_codes(profile: DeviceProfile, mapping_config: dict) -> dict[str, set[int]]:
    """Resolve controller role codes against the device's actual keys."""
    roles: dict[str, set[int]] = {}
    for role, defaults in DEFAULT_ROLE_CODES.items():
        cfg = {int(v) for v in mapping_config.get(role, [])}
        wanted = cfg or set(defaults)
        present = {c for c in wanted if not profile.keys or c in profile.keys}
        roles[role] = present or set(defaults)
    return roles


class LinuxInputReader:
    """Small Linux input_event reader with no third-party dependencies.

    Selects the single best controller device (honoring prefer_names, excluding
    IMU nodes) and resolves button roles against the device's real capabilities
    at runtime instead of trusting hardcoded codes.
    """

    def __init__(self, input_config: dict, mapping_config: dict):
        self.log = logging.getLogger("input")
        self.input_config = input_config
        self.mapping_config = mapping_config
        self.selector = selectors.DefaultSelector()
        self.state = ControllerState()
        self.axis_info: dict[tuple[int, int], AxisInfo] = {}
        self.device_paths: list[str] = []
        self.role_codes: dict[str, set[int]] = {}
        self.event_struct = struct.Struct("llHHi")
        self._open_devices()

    def close(self) -> None:
        for key in list(self.selector.get_map().values()):
            try:
                os.close(key.fd)
            except OSError:
                pass

    def poll(self, timeout: float = 0.0) -> ControllerState:
        for key, _ in self.selector.select(timeout):
            fd = key.fd
            while True:
                try:
                    data = os.read(fd, self.event_struct.size)
                except BlockingIOError:
                    break
                except OSError:
                    break
                if len(data) != self.event_struct.size:
                    break
                _, _, event_type, code, value = self.event_struct.unpack(data)
                self._apply_event(fd, event_type, code, value)
        return self.state

    # --- device selection -----------------------------------------------------

    def _open_devices(self) -> None:
        prefer = list(self.input_config.get("prefer_names", DEFAULT_PREFER_NAMES)) or list(DEFAULT_PREFER_NAMES)
        profiles = self._inspect_candidates()
        skipped = [p for p in profiles if p.is_imu]
        for p in skipped:
            self.log.info("excluding IMU/non-stick device %s (%s)", p.path, p.name)
        chosen = select_controller_profile(profiles, prefer)
        if not chosen:
            self.log.warning("no controller-like input device found; agent will see no input")
            return
        self._register(chosen)
        self._resolve_roles(chosen)

    def _inspect_candidates(self) -> list[DeviceProfile]:
        return inspect_input_profiles(self.input_config, self.log)

    def _register(self, profile: DeviceProfile) -> None:
        try:
            fd = os.open(profile.path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            self.log.warning("could not reopen selected device %s: %s", profile.path, exc)
            return
        self.selector.register(fd, selectors.EVENT_READ, profile.path)
        self.device_paths.append(profile.path)
        self._load_axis_info(fd)
        self.log.info("selected input device %s (%s)", profile.path, profile.name or "unnamed")

    def _resolve_roles(self, profile: DeviceProfile) -> None:
        """Resolve each button role to codes the device actually reports.

        Config-supplied codes win (operator override); otherwise the Nintendo
        defaults are used, filtered to the device's real capability set.
        """
        self.role_codes = resolve_role_codes(profile, self.mapping_config)
        self.log.info(
            "resolved roles deadman=%s arm=%s stop=%s estop=%s",
            sorted(self.role_codes["deadman_key_codes"]),
            sorted(self.role_codes["arm_key_codes"]),
            sorted(self.role_codes["stop_key_codes"]),
            sorted(self.role_codes["estop_key_codes"]),
        )

    def _load_axis_info(self, fd: int) -> None:
        for axis in self._all_axis_codes():
            buf = bytearray(24)
            try:
                fcntl.ioctl(fd, eviocgabs(axis), buf, True)
                value, minimum, maximum, _, _, _ = struct.unpack("iiiiii", buf)
                _ = value
                self.axis_info[(fd, axis)] = AxisInfo(minimum, maximum)
            except OSError:
                continue

    def _all_axis_codes(self) -> Iterable[int]:
        keys = [
            "left_x_abs_codes",
            "left_y_abs_codes",
            "right_x_abs_codes",
            "right_y_abs_codes",
        ]
        seen: set[int] = set()
        for key in keys:
            for value in self.mapping_config.get(key, []):
                code = int(value)
                if code not in seen:
                    seen.add(code)
                    yield code

    # --- event handling -------------------------------------------------------

    def _apply_event(self, fd: int, event_type: int, code: int, value: int) -> None:
        if event_type == EV_KEY:
            down = value != 0
            self.state.raw_keys[code] = down
            self.state.deadman = self._role_down("deadman_key_codes")
            self.state.arm = self._role_down("arm_key_codes")
            self.state.stop = self._role_down("stop_key_codes")
            self.state.estop = self._role_down("estop_key_codes")
            if down:
                self.state.buttons_mask |= 1 << (code % 32)
            else:
                self.state.buttons_mask &= ~(1 << (code % 32))
            return

        if event_type == EV_ABS:
            normalized = self.axis_info.get((fd, code), AxisInfo()).normalize(value)
            if code in self._codes("left_x_abs_codes"):
                self.state.left_x = normalized
            elif code in self._codes("left_y_abs_codes"):
                self.state.left_y = -normalized if self._bool("invert_left_y", True) else normalized
            elif code in self._codes("right_x_abs_codes"):
                # 2026-06-08 — 헤드 pan 좌우가 반대로 동작한다는 사용자 보고에 따라
                # invert_right_x 옵션 추가(default False — 기존 동작 보존). config 에서
                # 켜면 실로봇 헤드가 의도와 같은 방향으로 회전.
                self.state.right_x = -normalized if self._bool("invert_right_x", False) else normalized
            elif code in self._codes("right_y_abs_codes"):
                self.state.right_y = -normalized if self._bool("invert_right_y", True) else normalized

    def _codes(self, key: str) -> set[int]:
        return {int(v) for v in self.mapping_config.get(key, [])}

    def _bool(self, key: str, default: bool) -> bool:
        return bool(self.mapping_config.get(key, default))

    def _role_down(self, role: str) -> bool:
        return any(self.state.raw_keys.get(code, False) for code in self.role_codes.get(role, set()))


class NullInputReader:
    def __init__(self) -> None:
        self.state = ControllerState()
        self.device_paths: list[str] = []

    def poll(self, timeout: float = 0.0) -> ControllerState:
        _ = timeout
        return self.state

    def close(self) -> None:
        pass
