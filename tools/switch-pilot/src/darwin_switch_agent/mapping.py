from __future__ import annotations

from dataclasses import dataclass

from .input_linux import BTN_TL, BTN_TR, ControllerState


@dataclass(frozen=True)
class MotionCommand:
    enabled: bool
    stride_mm: float
    side_mm: float
    turn_deg: float
    head_pan_deg: float
    head_tilt_deg: float
    speed_scale: float

    @property
    def moving(self) -> bool:
        return self.enabled


class ControllerMapper:
    def __init__(self, mapping_config: dict, motion_config: dict):
        self.deadzone = float(mapping_config.get("deadzone", 0.12))
        self.max_stride = float(motion_config.get("max_stride_mm", 25.0))
        self.max_side = float(motion_config.get("max_side_mm", 18.0))
        self.max_turn = float(motion_config.get("max_turn_deg", 12.0))
        self.turn_from_side = float(motion_config.get("turn_from_side_ratio", 0.35))
        self.max_head_pan = float(motion_config.get("max_head_pan_deg", 70.0))
        self.max_head_tilt = float(motion_config.get("max_head_tilt_deg", 35.0))
        # 2026-06-08 — 머리 들기 (위쪽 tilt) 만 더 허용해 달라는 사용자 보고에 따라 비대칭
        # 한도 도입. up/down 키가 없으면 기존 대칭 동작 그대로(=max_head_tilt) 유지.
        # 부호 약속: invert_right_y(default true) 거친 후 stick UP → +tilt → 머리 들기.
        self.max_head_tilt_up = float(
            motion_config.get("max_head_tilt_up_deg", self.max_head_tilt))
        self.max_head_tilt_down = float(
            motion_config.get("max_head_tilt_down_deg", self.max_head_tilt))
        self.speed_scale = float(motion_config.get("speed_scale", 0.8))
        self.hold_head = bool(motion_config.get("hold_head_position", True))
        self.drive_curve = float(motion_config.get("drive_curve", 1.0))
        self.side_sign = -1.0 if bool(mapping_config.get("invert_side", True)) else 1.0
        self.turn_sign = -1.0 if bool(mapping_config.get("invert_turn", True)) else 1.0
        self.turn_left_keys = tuple(
            int(code) for code in mapping_config.get("turn_left_key_codes", (BTN_TL,))
        )
        self.turn_right_keys = tuple(
            int(code) for code in mapping_config.get("turn_right_key_codes", (BTN_TR,))
        )
        self._head_pan = 0.0
        self._head_tilt = 0.0

    def map(self, state: ControllerState) -> MotionCommand:
        left_y = self._drive_axis(state.left_y)
        left_x = self._drive_axis(state.left_x)
        right_x = self._deadzone(state.right_x)
        right_y = self._deadzone(state.right_y)
        jog_in_place = bool(state.deadman)
        head_pan = self._head_value("pan", right_x, self.max_head_pan)
        # 2026-06-08 비대칭 tilt — stick UP(+y after invert) 쪽이 max_head_tilt_up,
        # stick DOWN(-y) 쪽이 max_head_tilt_down 으로 잘림. 기본값은 둘 다 max_head_tilt 로
        # 대칭 동작 보존(기존 호환).
        tilt_limit = self.max_head_tilt_up if right_y >= 0 else self.max_head_tilt_down
        head_tilt = self._head_value("tilt", right_y, tilt_limit)
        shoulder_turn = self._shoulder_turn_axis(state)
        side = self.side_sign * left_x * self.max_side
        turn = (
            self.turn_sign * left_x * self.max_turn * self.turn_from_side
            + self.turn_sign * shoulder_turn * self.max_turn
        )
        turn = self._clamp(turn, -self.max_turn, self.max_turn)
        enabled = jog_in_place or abs(left_y) > 0.0 or abs(side) > 0.0 or abs(turn) > 0.0
        return MotionCommand(
            enabled=enabled,
            stride_mm=left_y * self.max_stride if enabled and not jog_in_place else 0.0,
            side_mm=side if enabled and not jog_in_place else 0.0,
            turn_deg=turn if enabled and not jog_in_place else 0.0,
            head_pan_deg=head_pan,
            head_tilt_deg=head_tilt,
            speed_scale=self._clamp(self.speed_scale, 0.5, 1.5),
        )

    def _deadzone(self, value: float) -> float:
        if abs(value) < self.deadzone:
            return 0.0
        sign = 1.0 if value >= 0 else -1.0
        scaled = (abs(value) - self.deadzone) / max(0.001, 1.0 - self.deadzone)
        return sign * self._clamp(scaled, 0.0, 1.0)

    def _drive_axis(self, value: float) -> float:
        normalized = self._deadzone(value)
        if normalized == 0.0:
            return 0.0
        curve = max(0.35, min(2.5, self.drive_curve))
        sign = 1.0 if normalized >= 0 else -1.0
        return sign * (abs(normalized) ** curve)

    def _head_value(self, axis: str, value: float, maximum: float) -> float:
        target = value * maximum
        if axis == "pan":
            if not self.hold_head or value != 0.0:
                self._head_pan = target
            return self._head_pan
        if not self.hold_head or value != 0.0:
            self._head_tilt = target
        return self._head_tilt

    def _shoulder_turn_axis(self, state: ControllerState) -> float:
        left = any(state.raw_keys.get(code, False) for code in self.turn_left_keys)
        right = any(state.raw_keys.get(code, False) for code in self.turn_right_keys)
        return (1.0 if right else 0.0) - (1.0 if left else 0.0)

    @staticmethod
    def _clamp(value: float, lo: float, hi: float) -> float:
        return min(max(value, lo), hi)
