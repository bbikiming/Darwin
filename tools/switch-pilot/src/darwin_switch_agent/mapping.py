from __future__ import annotations

from dataclasses import dataclass

from .input_linux import ControllerState


@dataclass(frozen=True)
class MotionCommand:
    enabled: bool
    stride_mm: float
    turn_deg: float
    head_pan_deg: float
    head_tilt_deg: float
    speed_scale: float

    @property
    def moving(self) -> bool:
        return self.enabled and (
            abs(self.stride_mm) > 0.01
            or abs(self.turn_deg) > 0.01
        )


class ControllerMapper:
    def __init__(self, mapping_config: dict, motion_config: dict):
        self.deadzone = float(mapping_config.get("deadzone", 0.12))
        self.max_stride = float(motion_config.get("max_stride_mm", 25.0))
        self.max_turn = float(motion_config.get("max_turn_deg", 12.0))
        self.max_head_pan = float(motion_config.get("max_head_pan_deg", 70.0))
        self.max_head_tilt = float(motion_config.get("max_head_tilt_deg", 35.0))
        self.speed_scale = float(motion_config.get("speed_scale", 0.8))

    def map(self, state: ControllerState) -> MotionCommand:
        left_y = self._deadzone(state.left_y)
        left_x = self._deadzone(state.left_x)
        right_x = self._deadzone(state.right_x)
        right_y = self._deadzone(state.right_y)
        enabled = bool(state.deadman)
        return MotionCommand(
            enabled=enabled,
            stride_mm=left_y * self.max_stride if enabled else 0.0,
            turn_deg=left_x * self.max_turn if enabled else 0.0,
            head_pan_deg=right_x * self.max_head_pan,
            head_tilt_deg=right_y * self.max_head_tilt,
            speed_scale=self._clamp(self.speed_scale, 0.5, 1.5),
        )

    def _deadzone(self, value: float) -> float:
        if abs(value) < self.deadzone:
            return 0.0
        sign = 1.0 if value >= 0 else -1.0
        scaled = (abs(value) - self.deadzone) / max(0.001, 1.0 - self.deadzone)
        return sign * self._clamp(scaled, 0.0, 1.0)

    @staticmethod
    def _clamp(value: float, lo: float, hi: float) -> float:
        return min(max(value, lo), hi)
