"""Event-driven UDP transport for the WalkLab brokerage (ssh-parity-contract §G).

This is the Switch-side O1 transport. It is **additive** to the SSH file path:
the file paths (command/estop/telemetry under /tmp) remain the permanent fallback
and the channel handshake gates the UDP path on the robot. We consume the contract
verbatim — none of these wire formats are invented here:

  - handshake  /tmp/df-walklab-channel  "TOKEN ESTOP_PORT CMD_PORT\\n"  (§G.1)
  - command    UDP cmd_port (17374)      "DFCMD {token} {seq} {line}"   (§G.3)
  - e-stop     UDP estop_port (17372)    "DF-ESTOP v1 {token} {ts}" ×3   (§G.2)
  - ack        UDP (reply to cmd src)    "ACK {seq} {t_rx}"             (§G.3)
  - telemetry  UDP (to uplink IP:port)   "TEL2 ..." 30Hz                (§A.2-TEL2)

`line` for DFCMD is the §C v1 14-token command line (cmd_id + 13) built by
`SshControlClient._build_line` — the Switch keeps the simple, verified v1 serializer
rather than the v2 twist line (the robot supports both; v1 stays permanent per §C).

The pure functions here are the host-testable wire layer. `UdpControlTransport`
wires them onto a non-blocking socket; SshControlClient composes it.
"""

from __future__ import annotations

import logging
import secrets
import socket
import string
import threading
import time
from collections import deque

# Contract-pinned UDP ports (§G.7). The handshake conveys them to the robot, so
# these are the single Switch-side source; do not hard-code elsewhere.
DEFAULT_ESTOP_PORT = 17372
DEFAULT_CMD_PORT = 17374
DEFAULT_TELEMETRY_PORT = 17371

# E-STOP burst schedule (§G.2): three datagrams at 0/50/100ms in parallel with
# the SSH/file path (first to land wins). Sent off-thread so the control loop
# never blocks on the spacing.
ESTOP_BURST_OFFSETS_MS = (0, 50, 100)

# Token: 16 alphanumerics, shell-safe (§G.1) — it lands in the handshake file and
# is echoed in every datagram, so it must never contain a space or shell metachar.
TOKEN_ALPHABET = string.ascii_letters + string.digits
TOKEN_LENGTH = 16

# 3S LiPo voltage window for the battery-percent estimate (mirrors ssh client).
BATTERY_MIN_V = 10.5
BATTERY_MAX_V = 12.6

# Fixed TEL2 prefix is 14 tokens: TEL2 ts seq phase x y a period gx gy gz ax ay az.
# The FSR group (8 cells | "-") and CoP group (2 cells | "-") follow at variable
# offsets, then fallen, risk("-"|float), vdV, active_source, loop_ms.
_TEL2_FIXED = 14


def gen_token(length: int = TOKEN_LENGTH) -> str:
    """Generate a fresh handshake token — `length` shell-safe alphanumerics."""
    return "".join(secrets.choice(TOKEN_ALPHABET) for _ in range(length))


def handshake_line(token: str, estop_port: int, cmd_port: int) -> str:
    """Compose the §G.1 channel handshake file body (trailing newline)."""
    return f"{token} {int(estop_port)} {int(cmd_port)}\n"


def cmd_datagram(token: str, seq: int, line: str) -> bytes:
    """Compose a §G.3 command datagram. `line` is the §C v1 14-token command line."""
    return f"DFCMD {token} {int(seq)} {line}".encode("ascii", errors="ignore")


def estop_datagram(token: str, ts_ms: int) -> bytes:
    """Compose a §G.2 E-STOP datagram."""
    return f"DF-ESTOP v1 {token} {int(ts_ms)}".encode("ascii", errors="ignore")


def parse_ack(data: bytes) -> tuple[int, int] | None:
    """Parse an "ACK {seq} {t_rx}" reply. Returns (seq, t_rx) or None."""
    try:
        tokens = data.decode("ascii", errors="ignore").split()
    except (UnicodeError, AttributeError):
        return None
    if len(tokens) < 3 or tokens[0] != "ACK":
        return None
    try:
        return int(tokens[1]), int(tokens[2])
    except ValueError:
        return None


def parse_tel2(data: bytes) -> dict | None:
    """Parse a §A.2-TEL2 line into a telemetry dict, or None if malformed.

    Variable token count: the FSR group is 8 integer cells OR a single "-", and
    the CoP group is 2 integer cells OR a single "-". A cursor walks the line so
    both presence cases parse without index math leaking out. Out-of-shape input
    returns None (drop the sample — never raise into the loop, never feed garbage).
    """
    text = data.decode("ascii", errors="ignore").strip()
    if not text:
        return None
    t = text.split()
    if len(t) < _TEL2_FIXED or t[0] != "TEL2":
        return None
    try:
        ts_ms = int(t[1])
        seq_applied = int(t[2])
        phase = int(t[3])
        x_lat, y_lat, a_lat, period_lat = (float(t[4]), float(t[5]), float(t[6]), float(t[7]))
        gx, gy, gz = int(t[8]), int(t[9]), int(t[10])
        ax, ay, az = int(t[11]), int(t[12]), int(t[13])
        cur = _TEL2_FIXED
        if t[cur] == "-":
            fsr = None
            cur += 1
        else:
            fsr = [int(t[cur + i]) for i in range(8)]
            cur += 8
        if t[cur] == "-":
            cop = None
            cur += 1
        else:
            cop = [int(t[cur]), int(t[cur + 1])]
            cur += 2
        fallen = int(t[cur]); cur += 1
        risk = None if t[cur] == "-" else float(t[cur]); cur += 1
        voltage_dv = int(t[cur]); cur += 1
        active_source = t[cur]; cur += 1
        loop_ms = int(t[cur])
    except (ValueError, IndexError):
        return None
    voltage_v, battery_pct = battery_from_dv(voltage_dv)
    # Per-foot ground contact derived from the FSR group; the CoP group is the
    # robot's whole-body contact signal (- when no foot loaded) — see §A.2-TEL2.
    left_contact = bool(fsr) and any(c > 0 for c in fsr[0:4])
    right_contact = bool(fsr) and any(c > 0 for c in fsr[4:8])
    return {
        "ts_ms": ts_ms,
        "seq_applied": seq_applied,
        "phase": phase,
        "latch": {"x": x_lat, "y": y_lat, "a": a_lat, "period": period_lat},
        "gyro": {"x": gx, "y": gy, "z": gz},
        "accel": {"x": ax, "y": ay, "z": az},
        "fsr": fsr,
        "cop": cop,
        "ground": cop is not None,
        "left_contact": left_contact,
        "right_contact": right_contact,
        "fallen": fallen,
        "risk": risk,
        "voltage_v": voltage_v,
        "battery_pct": battery_pct,
        "active_source": active_source,
        "loop_ms": loop_ms,
        # TEL2 has no walking01; derive from the gait phase (>=0 = in a gait cycle).
        "walking": phase >= 0,
    }


def battery_from_dv(voltage_dv: int) -> tuple[float | None, int | None]:
    """Map deci-volts to (volts, percent). 0 deci-volts == unknown."""
    if voltage_dv <= 0:
        return None, None
    voltage_v = voltage_dv / 10.0
    span = BATTERY_MAX_V - BATTERY_MIN_V
    pct = round((voltage_v - BATTERY_MIN_V) / span * 100.0)
    return voltage_v, min(max(pct, 0), 100)


def local_ip_toward(host: str) -> str:
    """Best-effort source IP this host would use to reach `host` (no packet sent).

    A connected UDP socket only resolves the egress interface — getsockname then
    reports the source address the robot will see, which is what the uplink file
    must carry so TEL2 comes back to us. Falls back to loopback on any error.
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((host, 9))
        return probe.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        probe.close()


class UdpControlTransport:
    """Non-blocking UDP command/estop send + ACK/TEL2 receive on one socket.

    Single socket: it sends DFCMD to cmd_port and DF-ESTOP to estop_port, and the
    robot replies ACK to this socket's source addr and streams TEL2 to the uplink
    IP:port we register — so one `pump()` drains both. Send/receive never raise
    into the control loop; transport errors are logged and surface as falsy/empty.
    """

    def __init__(
        self,
        host: str,
        *,
        cmd_port: int = DEFAULT_CMD_PORT,
        estop_port: int = DEFAULT_ESTOP_PORT,
        telemetry_port: int = DEFAULT_TELEMETRY_PORT,
        token: str | None = None,
        rtt_alpha: float = 0.3,
        rate_window_s: float = 1.0,
    ):
        self.host = host
        self.cmd_port = int(cmd_port)
        self.estop_port = int(estop_port)
        self.telemetry_port = int(telemetry_port)
        self.token = token or gen_token()
        self.rtt_alpha = float(rtt_alpha)
        self.rate_window_s = float(rate_window_s)
        self.log = logging.getLogger("df_udp")

        self.seq = 0
        self.last_ack_seq = 0
        self.last_rtt_ms: float | None = None
        self.last_tel: dict | None = None
        self.last_tel_at: float | None = None
        self.last_ack_at: float | None = None

        self._sent_at: dict[int, float] = {}
        self._ack_times: deque[float] = deque()

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        self.sock.bind(("", 0))
        self.local_ip = local_ip_toward(host)
        self.local_port = self.sock.getsockname()[1]

    def uplink_value(self) -> str:
        """The IP:port to write into /tmp/df-walklab-uplink so TEL2 reaches us."""
        return f"{self.local_ip}:{self.local_port}"

    def send_command(self, line: str) -> int:
        """Send one DFCMD datagram with a strictly monotonic seq. Returns the seq.

        The robot drops reordered/old seq (§G.3), so seq only ever increases. We
        stamp the send time per seq to compute RTT when its ACK returns.
        """
        self.seq += 1
        self._sent_at[self.seq] = time.monotonic()
        # Bound the pending-send map so a long run with lost ACKs cannot grow it.
        if len(self._sent_at) > 256:
            for old in sorted(self._sent_at)[:128]:
                self._sent_at.pop(old, None)
        self._emit(cmd_datagram(self.token, self.seq, line), self.cmd_port)
        return self.seq

    def send_estop(self) -> None:
        """Fire the §G.2 ×3 burst (0/50/100ms) off-thread (non-blocking)."""
        token = self.token

        def _burst() -> None:
            start = time.monotonic()
            for offset_ms in ESTOP_BURST_OFFSETS_MS:
                target = start + offset_ms / 1000.0
                delay = target - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                self._emit(estop_datagram(token, int(time.time() * 1000)), self.estop_port)

        threading.Thread(target=_burst, name="df-udp-estop", daemon=True).start()

    def pump(self, max_datagrams: int = 64) -> dict | None:
        """Drain pending ACK/TEL2 datagrams (non-blocking). Returns latest TEL2.

        Dispatches by prefix: "ACK ..." updates RTT/effective-rate, "TEL2 ..."
        is stored as the freshest telemetry. Bounded per call so a flood cannot
        starve the control loop. Never raises.
        """
        latest_tel: dict | None = None
        for _ in range(max_datagrams):
            try:
                data, _addr = self.sock.recvfrom(2048)
            except BlockingIOError:
                break
            except OSError as exc:
                self.log.debug("udp recv failed: %s", exc)
                break
            if data.startswith(b"ACK"):
                self._on_ack(data)
            elif data.startswith(b"TEL2"):
                parsed = parse_tel2(data)
                if parsed is not None:
                    latest_tel = parsed
                    self.last_tel = parsed
                    self.last_tel_at = time.monotonic()
        return latest_tel

    def _on_ack(self, data: bytes) -> None:
        parsed = parse_ack(data)
        if parsed is None:
            return
        seq, _t_rx = parsed
        now = time.monotonic()
        self.last_ack_at = now
        if seq > self.last_ack_seq:
            self.last_ack_seq = seq
        sent = self._sent_at.pop(seq, None)
        if sent is not None:
            rtt = (now - sent) * 1000.0
            self.last_rtt_ms = (
                rtt if self.last_rtt_ms is None
                else self.rtt_alpha * rtt + (1 - self.rtt_alpha) * self.last_rtt_ms
            )
        self._ack_times.append(now)
        self._trim_rate(now)

    def _trim_rate(self, now: float) -> None:
        cutoff = now - self.rate_window_s
        while self._ack_times and self._ack_times[0] < cutoff:
            self._ack_times.popleft()

    def effective_hz(self) -> float:
        """Applied-command throughput: ACKs received within the rate window."""
        now = time.monotonic()
        self._trim_rate(now)
        if self.rate_window_s <= 0:
            return 0.0
        return len(self._ack_times) / self.rate_window_s

    def tel_age_s(self) -> float | None:
        if self.last_tel_at is None:
            return None
        return time.monotonic() - self.last_tel_at

    def ack_age_s(self) -> float | None:
        if self.last_ack_at is None:
            return None
        return time.monotonic() - self.last_ack_at

    def metrics(self) -> dict:
        return {
            "transport": "udp",
            "effective_hz": round(self.effective_hz(), 1),
            "rtt_ms": None if self.last_rtt_ms is None else round(self.last_rtt_ms, 1),
            "last_ack_seq": self.last_ack_seq,
            "tx_seq": self.seq,
        }

    def _emit(self, datagram: bytes, port: int) -> bool:
        try:
            self.sock.sendto(datagram, (self.host, port))
            return True
        except OSError as exc:
            self.log.warning("udp send failed (port %d): %s", port, exc)
            return False

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass
