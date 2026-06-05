from __future__ import annotations

from dataclasses import dataclass

from .input_linux import ControllerState
from .mapping import MotionCommand


@dataclass
class SafetyEdges:
    arm_pressed: bool = False
    stop_pressed: bool = False
    estop_pressed: bool = False
    deadman_released: bool = False


class SafetyState:
    def __init__(self) -> None:
        self.prev_arm = False
        self.prev_stop = False
        self.prev_estop = False
        self.prev_deadman = False
        self.was_moving = False

    def update(self, controller: ControllerState, command: MotionCommand) -> SafetyEdges:
        edges = SafetyEdges(
            arm_pressed=controller.arm and not self.prev_arm,
            stop_pressed=controller.stop and not self.prev_stop,
            estop_pressed=controller.estop and not self.prev_estop,
            deadman_released=(not controller.deadman) and self.prev_deadman,
        )
        self.prev_arm = controller.arm
        self.prev_stop = controller.stop
        self.prev_estop = controller.estop
        self.prev_deadman = controller.deadman
        self.was_moving = command.moving
        return edges
