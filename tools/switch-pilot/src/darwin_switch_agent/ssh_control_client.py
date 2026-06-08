"""SSH file-protocol control client for the robot WalkLab brokerage.

The robot runs an onboard daemon ("WalkLabBrokerage") that polls files under
/tmp every ~100ms and drives the ROBOTIS Walking engine. The control protocol
is FILE-based over SSH, mirrored byte-for-byte from
firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp:

  - command   /tmp/df-walklab-cmd       14-token line, atomic temp+mv write
  - e-stop    /tmp/df-walklab-estop     presence == STOP (touch / rm -f)
  - telemetry /tmp/df-walklab-telemetry  "TEL ..." line, read with cat
  - ack       /tmp/df-walklab-ack        "OK ..." (optional)
  - mode      /tmp/df-pilot-mode         "walklab" selects the brokerage

SSH transport mirrors SSHShell.swift exactly (the robot is OpenSSH 5.9, so the
legacy +ssh-rsa algorithms and ControlMaster reuse are mandatory). Every ssh
call has a hard timeout and NEVER raises into the control loop — failures are
logged and reported as falsy/None.
"""

from __future__ import annotations

import logging
import os
import subprocess
import time
import uuid

from .mapping import MotionCommand

# Robot-side file paths — pinned to the brokerage contract.
CMD_PATH = "/tmp/df-walklab-cmd"
CMD_TMP_PATH = "/tmp/df-walklab-cmd.tmp"
ESTOP_PATH = "/tmp/df-walklab-estop"
TELEMETRY_PATH = "/tmp/df-walklab-telemetry"
PILOT_MODE_PATH = "/tmp/df-pilot-mode"

# Defaults — wired direct path is ~166x faster than wireless (see CLAUDE.md).
DEFAULT_HOST = "192.168.123.1"
DEFAULT_USER = "robotis"
DEFAULT_IDENTITY = "~/.ssh/id_rsa_darwin"  # RSA — OpenSSH 5.9 has no ed25519.
# ControlMaster master-socket path. **2026-06-07 real-hardware fix**: the agent
# runs as a systemd service with `User=root`, so `~/.ssh/df-cm-%C` expanded to
# `/root/.ssh/...` which doesn't exist -> the master socket never formed -> every
# command was a full ~1s SSH handshake over slow Wi-Fi -> send_hz timeouts ->
# `/tmp/df-walklab-estop` auto-set -> robot frozen. **2026-06-08 fix**: include
# the local uid in /tmp. Without it, a root-owned stale `/tmp/df-cm-%C` from the
# service can collide with a user-run CLI command and produce
# `Control socket ... Permission denied`. %C still isolates host/port/user.
DEFAULT_CONTROL_PATH = f"/tmp/df-cm-{os.getuid()}-%C"

# Gait engine defaults (ROBOTIS originals) used when cfg omits them.
DEFAULT_PERIOD_MS = 600.0
DEFAULT_FOOT_MM = 40.0
DEFAULT_HIP_DEG = 13.0
DEFAULT_MIN_PERIOD_MS = 520.0
DEFAULT_MAX_PERIOD_MS = 780.0
DEFAULT_MIN_FOOT_MM = 18.0
DEFAULT_STRIDE_REF_MM = 25.0
DEFAULT_TURN_REF_DEG = 12.0

# 3S LiPo voltage window for the battery-percent estimate.
BATTERY_MIN_V = 10.5
BATTERY_MAX_V = 12.6


def _expand(path: str | None) -> str | None:
    """Expand a leading ~ to the user's home; pass None through."""
    if not path:
        return path
    return os.path.expanduser(path)


def ssh_args(
    host: str,
    user: str,
    command: str,
    identity: str | None,
    timeout: int,
    port: int = 22,
) -> list[str]:
    """Build the /usr/bin/ssh argument vector — pure, testable.

    Mirrors SSHShell.sshArguments option-for-option and order-for-order:
    BatchMode/accept-new/LogLevel/ConnectTimeout/ServerAlive first, then
    ControlMaster (only when an identity exists, i.e. ~/.ssh is guaranteed),
    then the OpenSSH 5.9 legacy +ssh-rsa compat, the identity, the explicit
    `-p <port>`, and finally user@host followed by the command as the last two
    elements.
    """
    connect_timeout = min(int(timeout), 10)
    args: list[str] = [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "LogLevel=ERROR",
        "-o", f"ConnectTimeout={connect_timeout}",
        "-o", "ServerAliveInterval=2",
        "-o", "ServerAliveCountMax=2",
    ]
    if identity:
        # ControlMaster reuses one handshake per host; needs ~/.ssh present,
        # which the RSA identity guarantees.
        args += [
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={DEFAULT_CONTROL_PATH}",
            "-o", "ControlPersist=30",
        ]
    # Legacy OpenSSH 5.9 compat — required for the robot, harmless on modern.
    args += [
        "-o", "PubkeyAcceptedAlgorithms=+ssh-rsa",
        "-o", "HostKeyAlgorithms=+ssh-rsa",
    ]
    if identity:
        args += ["-i", identity, "-o", "IdentitiesOnly=yes"]
    args += ["-p", str(int(port))]
    args += [f"{user}@{host}", command]
    return args


class SshControlClient:
    """File-protocol control client over SSH for the WalkLab brokerage."""

    def __init__(self, cfg: dict):
        self.host = str(cfg.get("host", DEFAULT_HOST))
        self.user = str(cfg.get("user", DEFAULT_USER))
        self.port = int(cfg.get("port", 22))
        # Resolve the identity: explicit cfg wins, else the default RSA key but
        # only if it actually exists (mirrors SSHShell.defaultOptions).
        raw_identity = cfg.get("identity_file", DEFAULT_IDENTITY)
        self.identity = self._resolve_identity(raw_identity)
        self.timeout = int(cfg.get("timeout_seconds", 6))
        self.connect_timeout = int(cfg.get("connect_timeout_seconds", 2))
        # SSH/WalkLab gait defaults — owned by the [ssh] config section.
        self.period_ms = float(cfg.get("period_ms", DEFAULT_PERIOD_MS))
        self.foot_mm = float(cfg.get("foot_mm", DEFAULT_FOOT_MM))
        self.hip_deg = float(cfg.get("hip_deg", DEFAULT_HIP_DEG))
        self.min_period_ms = float(cfg.get("min_period_ms", DEFAULT_MIN_PERIOD_MS))
        self.max_period_ms = float(cfg.get("max_period_ms", DEFAULT_MAX_PERIOD_MS))
        self.min_foot_mm = float(cfg.get("min_foot_mm", DEFAULT_MIN_FOOT_MM))
        self.stride_ref_mm = float(cfg.get("stride_ref_mm", DEFAULT_STRIDE_REF_MM))
        self.turn_ref_deg = float(cfg.get("turn_ref_deg", DEFAULT_TURN_REF_DEG))
        self.write_mode_file = bool(cfg.get("write_pilot_mode", True))
        self._connected = False
        self.log = logging.getLogger("ssh_control")

    @staticmethod
    def _resolve_identity(raw: str | None) -> str | None:
        expanded = _expand(raw) if isinstance(raw, str) else None
        if expanded and os.path.exists(expanded):
            return expanded
        return None

    @property
    def connected(self) -> bool:
        return self._connected

    def connect(self) -> bool:
        """Verify reachability and warm up the ControlMaster socket.

        Runs 'echo ok' over ssh (which establishes the multiplexed master when
        an identity is present). On success, optionally writes the pilot-mode
        file for completeness — we never restart the robot program. Returns True
        when the robot answered.
        """
        result = self._ssh("echo ok", timeout=self.connect_timeout)
        reachable = result is not None and result.returncode == 0
        self._connected = reachable
        if not reachable:
            return False
        if self.write_mode_file:
            self._write_pilot_mode()
        return True

    def _write_pilot_mode(self) -> None:
        """Best-effort write of /tmp/df-pilot-mode == walklab (atomic temp+mv).

        For completeness only; the robot reads it at startup, so we never try to
        restart the program. Failure is non-fatal.
        """
        tmp = f"{PILOT_MODE_PATH}.tmp"
        cmd = f"cat > {tmp} && mv -f {tmp} {PILOT_MODE_PATH}"
        self._ssh(cmd, input_data="walklab")

    def send(self, command: MotionCommand) -> bool:
        """Write the 14-token command line atomically over ssh.

        Token order is pinned to WalkLabBrokerage.cpp::ParseAndApply:
          {cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip}
          {bgain} {benable} {blevel} {headPan} {headTilt} {ballTrack}
        Returns True on ssh exit 0.
        """
        line = self._build_line(command)
        return self._write_cmd_line(line)

    def stop(self) -> bool:
        """Send enabled=0 with zeroed motion immediately (bypass debounce)."""
        line = self._build_line(self._zero_command())
        return self._write_cmd_line(line)

    def estop(self) -> bool:
        """Engage e-stop by creating the presence file. Returns True on exit 0."""
        result = self._ssh(f"touch {ESTOP_PATH}")
        return result is not None and result.returncode == 0

    def recover(self) -> bool:
        """Clear e-stop by removing the presence file. Returns True on exit 0."""
        result = self._ssh(f"rm -f {ESTOP_PATH}")
        return result is not None and result.returncode == 0

    def poll_telemetry(self) -> dict | None:
        """Cat the telemetry file and parse the TEL line.

        Returns a dict with battery/walking/fallen state plus the measured ssh
        round-trip latency, or None on any failure (never raises).
        """
        started = time.monotonic()
        result = self._ssh(f"cat {TELEMETRY_PATH}")
        latency_ms = int((time.monotonic() - started) * 1000)
        if result is None or result.returncode != 0:
            return None
        return _parse_telemetry(result.stdout, latency_ms)

    def command_status(self) -> dict | None:
        """Read the robot-side WalkLab command/mode/e-stop files.

        Used by the native cockpit as a field diagnostic: it proves that the
        command file the robot reads is actually changing, not merely that the
        local UI state changed.
        """
        script = (
            "printf 'MODE='; cat /tmp/df-pilot-mode 2>/dev/null; printf '\\n'; "
            "printf 'ESTOP='; test -e /tmp/df-walklab-estop && echo 1 || echo 0; "
            "printf 'STAT='; stat -c '%Y %s' /tmp/df-walklab-cmd 2>/dev/null || echo missing; "
            "printf 'CMD='; cat /tmp/df-walklab-cmd 2>/dev/null; printf '\\n'"
        )
        result = self._ssh(script, timeout=min(self.timeout, 4))
        if result is None or result.returncode != 0:
            return None
        return _parse_command_status(result.stdout)

    def close(self) -> None:
        """Tear down the ControlMaster socket (ssh -O exit), best-effort."""
        if not self.identity:
            self._connected = False
            return
        args = [
            "/usr/bin/ssh",
            "-o", f"ControlPath={DEFAULT_CONTROL_PATH}",
            "-p", str(self.port),
            "-O", "exit",
            f"{self.user}@{self.host}",
        ]
        try:
            subprocess.run(
                args,
                capture_output=True,
                timeout=self.timeout,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            self.log.debug("ssh control master teardown failed: %s", exc)
        self._connected = False

    # ----- internals --------------------------------------------------------

    def _build_line(self, command: MotionCommand) -> str:
        """Compose the 14-token command line with a unique cmd_id per send."""
        enabled = 1 if command.enabled else 0
        cmd_id = self._new_cmd_id()
        period_ms, foot_mm = self._gait_params(command)
        return (
            f"{cmd_id} {enabled} "
            f"{command.stride_mm:.2f} {command.side_mm:.2f} {command.turn_deg:.2f} "
            f"{period_ms:.0f} {foot_mm:.0f} {self.hip_deg:.0f} "
            f"1.0 0 2 "
            f"{command.head_pan_deg:.2f} {command.head_tilt_deg:.2f} 0"
        )

    def _gait_params(self, command: MotionCommand) -> tuple[float, float]:
        """Scale WalkLab period/foot with input intensity for real speed control.

        WalkLab speed is not governed by stride alone on the robot side; cadence
        (`period`) and foot lift also affect whether small stick inputs feel
        meaningfully slower. The line format only has period/foot/hip gait
        fields, so we interpolate them from stick intensity while preserving the
        existing high-speed defaults at full stick.
        """
        if not command.enabled:
            return self.period_ms, self.foot_mm
        stride_i = abs(command.stride_mm) / max(1.0, abs(self.stride_ref_mm))
        side_i = abs(command.side_mm) / max(1.0, abs(self.stride_ref_mm))
        turn_i = abs(command.turn_deg) / max(1.0, abs(self.turn_ref_deg))
        intensity = max(0.0, min(1.0, max(stride_i, side_i, turn_i)))
        # Use a curved response: small stick inputs become clearly slower, while
        # the top third still reaches the configured max gait.
        shaped = intensity ** 0.7
        min_period = min(self.min_period_ms, self.max_period_ms)
        max_period = max(self.min_period_ms, self.max_period_ms)
        period = max_period - (max_period - min_period) * shaped
        min_foot = min(self.min_foot_mm, self.foot_mm)
        max_foot = max(self.min_foot_mm, self.foot_mm)
        foot = min_foot + (max_foot - min_foot) * shaped
        return period, foot

    @staticmethod
    def _zero_command() -> MotionCommand:
        return MotionCommand(
            enabled=False,
            stride_mm=0.0,
            side_mm=0.0,
            turn_deg=0.0,
            head_pan_deg=0.0,
            head_tilt_deg=0.0,
            speed_scale=1.0,
        )

    @staticmethod
    def _new_cmd_id() -> str:
        # <=31 chars, no spaces; echoed back in the ACK file.
        return uuid.uuid4().hex[:24]

    def _write_cmd_line(self, line: str) -> bool:
        """Atomic temp+mv write of one command line via stdin piped to ssh."""
        cmd = f"cat > {CMD_TMP_PATH} && mv -f {CMD_TMP_PATH} {CMD_PATH}"
        result = self._ssh(cmd, input_data=line)
        return result is not None and result.returncode == 0

    def _ssh(
        self,
        command: str,
        input_data: str | None = None,
        timeout: int | None = None,
    ) -> subprocess.CompletedProcess | None:
        """Run one ssh command with a hard timeout. Never raises.

        Returns the CompletedProcess on completion (caller checks returncode),
        or None if the process failed to spawn or timed out.
        """
        args = ["/usr/bin/ssh"] + ssh_args(
            host=self.host,
            user=self.user,
            command=command,
            identity=self.identity,
            timeout=timeout if timeout is not None else self.timeout,
            port=self.port,
        )
        try:
            result = subprocess.run(
                args,
                input=input_data.encode("ascii") if input_data is not None else None,
                capture_output=True,
                timeout=timeout if timeout is not None else self.timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            self.log.warning("ssh timed out: %s", command)
            self._connected = False  # transport stalled — force reconnect path.
            return None
        except (OSError, subprocess.SubprocessError) as exc:
            self.log.warning("ssh failed (%s): %s", command, exc)
            self._connected = False
            return None
        # ssh uses exit 255 for transport-level failures (connection lost, auth,
        # host key) as opposed to a non-zero exit from the remote command itself.
        # Treat 255 as a disconnect so the loop re-enters the 1s reconnect path
        # instead of silently writing into the void. Remote-command non-zero
        # (e.g. cat of a missing telemetry file -> 1) does NOT drop the link.
        if result.returncode == 255:
            self._connected = False
        return result


def _parse_telemetry(raw: bytes, latency_ms: int) -> dict | None:
    """Parse a 'TEL ...' line into the telemetry dict, or None if malformed.

    Line: TEL {ts_ms} {gx} {gy} {gz} {ax} {ay} {az} {vdV} {walking01} {fallen}
    """
    text = raw.decode("ascii", errors="ignore").strip()
    if not text:
        return None
    tokens = text.split()
    # TEL + 10 fields = 11 tokens.
    if len(tokens) < 11 or tokens[0] != "TEL":
        return None
    try:
        ts_ms = int(tokens[1])
        gyro_x = int(tokens[2])
        gyro_y = int(tokens[3])
        gyro_z = int(tokens[4])
        accel_x = int(tokens[5])
        accel_y = int(tokens[6])
        accel_z = int(tokens[7])
        voltage_dv = int(tokens[8])
        walking = tokens[9] != "0"
        fallen = int(tokens[10])
    except (ValueError, IndexError):
        return None
    voltage_v, battery_pct = _battery(voltage_dv)
    return {
        "ts_ms": ts_ms,
        "voltage_v": voltage_v,
        "battery_pct": battery_pct,
        "walking": walking,
        "fallen": fallen,
        "latency_ms": latency_ms,
        "gyro": {"x": gyro_x, "y": gyro_y, "z": gyro_z},
        "accel": {"x": accel_x, "y": accel_y, "z": accel_z},
    }


def _parse_command_status(raw: bytes) -> dict:
    text = raw.decode("ascii", errors="ignore")
    out: dict[str, object] = {
        "mode": "",
        "estop": False,
        "mtime": None,
        "size": None,
        "raw": "",
        "parsed": None,
    }
    for line in text.splitlines():
        if line.startswith("MODE="):
            out["mode"] = line[len("MODE="):].strip()
        elif line.startswith("ESTOP="):
            out["estop"] = line[len("ESTOP="):].strip() == "1"
        elif line.startswith("STAT="):
            stat = line[len("STAT="):].strip().split()
            if len(stat) >= 2 and stat[0].isdigit() and stat[1].isdigit():
                out["mtime"] = int(stat[0])
                out["size"] = int(stat[1])
        elif line.startswith("CMD="):
            raw_cmd = line[len("CMD="):].strip()
            out["raw"] = raw_cmd
            out["parsed"] = _parse_command_line(raw_cmd)
    return out


def _parse_command_line(line: str) -> dict[str, object] | None:
    tokens = line.split()
    if len(tokens) < 14:
        return None
    try:
        return {
            "cmd_id": tokens[0],
            "enabled": tokens[1] != "0",
            "stride_mm": float(tokens[2]),
            "side_mm": float(tokens[3]),
            "turn_deg": float(tokens[4]),
            "period_ms": float(tokens[5]),
            "foot_mm": float(tokens[6]),
            "hip_deg": float(tokens[7]),
            "head_pan_deg": float(tokens[11]),
            "head_tilt_deg": float(tokens[12]),
        }
    except (ValueError, IndexError):
        return None


def _battery(voltage_dv: int) -> tuple[float | None, int | None]:
    """Map deci-volts to (volts, percent). 0 deci-volts == unknown."""
    if voltage_dv <= 0:
        return None, None
    voltage_v = voltage_dv / 10.0
    span = BATTERY_MAX_V - BATTERY_MIN_V
    pct = round((voltage_v - BATTERY_MIN_V) / span * 100.0)
    return voltage_v, min(max(pct, 0), 100)
