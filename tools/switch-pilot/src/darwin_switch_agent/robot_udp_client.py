from __future__ import annotations

import logging
import socket
import time

from .input_linux import ControllerState
from .mapping import MotionCommand


# Number of times an explicit STOP datagram is repeated. UDP can drop packets,
# and a lost stop is a safety hazard, so the stop edge is sent a few times.
STOP_REPEAT = 3


class RobotUdpClient:
    """Sends the SWP1 line protocol to the robot's UDP command receiver.

    SAFETY CONTRACT (robot-side, firmware-patches/walklab-brokerage): the
    receiver MUST hold a ~500ms staleness watchdog and zero all motion if no
    fresh DEADMAN-flagged datagram arrives, and MUST treat a STOP/ESTOP flag as
    an immediate zero. This client additionally pushes an explicit zero datagram
    on the deadman-release / stop edge (see send_stop) so a stop does not wait
    for the next periodic tick.
    """

    def __init__(self, cfg: dict):
        self.host = str(cfg.get("host", "192.168.0.100"))
        self.port = int(cfg.get("port", 55310))
        self.token = str(cfg.get("token", "change-me"))
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.seq = 0
        self.log = logging.getLogger("robot_udp")

    def send(self, state: ControllerState, command: MotionCommand) -> None:
        flags: list[str] = []
        if state.deadman:
            flags.append("DEADMAN")
        if state.arm:
            flags.append("ARM")
        if state.stop:
            flags.append("STOP")
        if state.estop:
            flags.append("ESTOP")
        if not flags:
            flags.append("IDLE")
        line = self._line(
            flags,
            state.left_x,
            state.left_y,
            state.right_x,
            state.right_y,
            state.buttons_mask,
            command.speed_scale,
        )
        self._emit(line)

    def send_stop(self, *, estop: bool = False) -> None:
        """Immediately send a zero-motion STOP (or ESTOP) datagram, repeated.

        Called on the deadman-release / stop / estop edge so motion ceases now
        rather than at the next periodic send. All stick values are zeroed.
        """
        flag = "ESTOP" if estop else "STOP"
        for _ in range(STOP_REPEAT):
            line = self._line([flag], 0.0, 0.0, 0.0, 0.0, 0, 0.0)
            if not self._emit(line):
                break

    def _line(
        self,
        flags: list[str],
        lx: float,
        ly: float,
        rx: float,
        ry: float,
        buttons: int,
        speed: float,
    ) -> str:
        self.seq += 1
        ts_ms = int(time.time() * 1000)
        return (
            f"SWP1 {self.seq} {ts_ms} {self.token} {'|'.join(flags)} "
            f"{lx:.4f} {ly:.4f} {rx:.4f} {ry:.4f} "
            f"0x{buttons:08x} {speed:.2f}\n"
        )

    def _emit(self, line: str) -> bool:
        # Never let a transient network error crash the control loop.
        try:
            self.sock.sendto(line.encode("ascii"), (self.host, self.port))
            return True
        except OSError as exc:
            self.log.warning("robot UDP send failed: %s", exc)
            return False
