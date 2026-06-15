#!/usr/bin/env python3
"""onboard-bench — P3/P4/P9 실기 벤치 (Mac 호스트 측, stdlib 전용).

ssh-parity-contract §G(O0/O1)·§G.8(O2)·§A.2-TEL2(O4) 계약을 그대로 말하는
독립 UDP 클라이언트. DarwinForge 앱 없이 로봇 온보드 브로커리지의
실효율·RTT·E-STOP·거버너 응답을 측정한다.

사용 예 (2026-06-12 실기 벤치):
  python3 onboard-bench.py provision --ssh darwin-wifi --mac-ip 192.168.0.18
  python3 onboard-bench.py tel2 --secs 20
  python3 onboard-bench.py ack --robot 192.168.0.33 --token <T> --hz 50 --secs 20
  python3 onboard-bench.py step --robot 192.168.0.33 --token <T> --x 38 --period 600
  python3 onboard-bench.py estop --robot 192.168.0.33 --token <T>
  python3 onboard-bench.py provision --ssh darwin-wifi --clear
"""

import argparse
import json
import random
import socket
import statistics
import string
import subprocess
import sys
import threading
import time

ESTOP_PORT = 17372
CMD_PORT = 17374
TEL_PORT = 17371
SSH_NOISE = ("post-quantum", "store now", "openssh.com", "upgraded")


def now_ms():
    return time.time() * 1000.0


def pctl(values, p):
    if not values:
        return None
    s = sorted(values)
    idx = min(len(s) - 1, max(0, int(round(p / 100.0 * (len(s) - 1)))))
    return s[idx]


def run_ssh(host, command):
    proc = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=8", host, command],
        capture_output=True, text=True, timeout=30,
    )
    err_lines = [
        ln for ln in proc.stderr.splitlines()
        if ln and not any(n in ln for n in SSH_NOISE)
    ]
    return proc.returncode, proc.stdout.strip(), "\n".join(err_lines)


# ── provision ────────────────────────────────────────────────────────────────

def cmd_provision(args):
    """§G.1 핸드셰이크 + TEL 업링크 파일을 로봇에 기록(원자적 tmp+mv)."""
    if args.clear:
        code, out, err = run_ssh(args.ssh, "rm -f /tmp/df-walklab-channel && echo CLEARED")
        print(out or err)
        return 0 if code == 0 else 1
    token = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(16))
    handshake = f"{token} {args.estop_port} {args.cmd_port}"
    uplink = f"{args.mac_ip} {args.tel_port}"
    script = (
        f"printf '%s\\n' '{handshake}' > /tmp/df-walklab-channel.tmp && "
        f"mv /tmp/df-walklab-channel.tmp /tmp/df-walklab-channel && "
        f"printf '%s\\n' '{uplink}' > /tmp/df-walklab-uplink.tmp && "
        f"mv /tmp/df-walklab-uplink.tmp /tmp/df-walklab-uplink && "
        f"echo PROVISIONED"
    )
    code, out, err = run_ssh(args.ssh, script)
    if "PROVISIONED" not in out:
        print(f"provision 실패: {err or out}", file=sys.stderr)
        return 1
    print(json.dumps({"token": token, "handshake": handshake, "uplink": uplink}))
    return 0


# ── TEL2 수신 ────────────────────────────────────────────────────────────────

class Tel2Listener:
    """TEL2 UDP 라인 수신·파싱 스레드. 라인 형식은 §A.2-TEL2."""

    def __init__(self, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("0.0.0.0", port))
        self.sock.settimeout(0.2)
        self.lines = []          # (recv_ms, raw, parsed dict|None)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    @staticmethod
    def parse(raw):
        t = raw.split()
        if len(t) < 8 or t[0] not in ("TEL2", "TEL"):
            return None
        if t[0] == "TEL":
            return {"v": 1, "ts": int(t[1])}
        try:
            d = {
                "v": 2, "ts": int(t[1]), "seq_applied": int(t[2]),
                "phase": int(t[3]), "x_lat": float(t[4]), "y_lat": float(t[5]),
                "a_lat": float(t[6]), "period_lat": float(t[7]),
            }
            # §A.2-TEL2 고정 위치: t[14]=fsr t[15]=cop t[19]=active_source t[20]=loop_p95
            if len(t) >= 21:
                d["fsr"] = t[14]
                d["cop"] = t[15]
                d["active_source"] = t[19]
                d["loop_p95"] = int(t[20])
            return d
        except (ValueError, IndexError):
            return None

    def _loop(self):
        while not self._stop.is_set():
            try:
                data, _ = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            for raw in data.decode("ascii", "replace").splitlines():
                self.lines.append((now_ms(), raw, self.parse(raw)))

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=1.0)
        self.sock.close()


def tel2_stats(lines, secs):
    recv_ms = [t for t, _, p in lines if p and p.get("v") == 2]
    gaps = [b - a for a, b in zip(recv_ms, recv_ms[1:])]
    loops = [p["loop_p95"] for _, _, p in lines
             if p and p.get("v") == 2 and "loop_p95" in p]
    return {
        "tel2_lines": len(recv_ms),
        "rate_hz": round(len(recv_ms) / secs, 2) if secs else None,
        "gap_p50_ms": round(pctl(gaps, 50), 1) if gaps else None,
        "gap_p95_ms": round(pctl(gaps, 95), 1) if gaps else None,
        "gap_max_ms": round(max(gaps), 1) if gaps else None,
        "gaps_over_100ms": sum(1 for g in gaps if g > 100.0),
        "loop_p95_min": min(loops) if loops else None,
        "loop_p95_max": max(loops) if loops else None,
        "loop_p95_med": round(statistics.median(loops), 1) if loops else None,
    }


def cmd_tel2(args):
    listener = Tel2Listener(args.port)
    print(f"TEL2 수신 대기 {args.secs}s (UDP :{args.port}) …", file=sys.stderr)
    time.sleep(args.secs)
    listener.stop()
    stats = tel2_stats(listener.lines, args.secs)
    sample = [raw for _, raw, p in listener.lines if p and p.get("v") == 2][-3:]
    print(json.dumps({"stats": stats, "sample": sample}, ensure_ascii=False, indent=1))
    if args.dump:
        with open(args.dump, "w") as f:
            for t, raw, _ in listener.lines:
                f.write(f"{t:.1f} {raw}\n")
    return 0


# ── DFCMD 송신 + ACK ─────────────────────────────────────────────────────────

class CmdSender:
    """§G.3 DFCMD 송신 + ACK 수신(동일 소켓). v1 14토큰 라인 사용."""

    def __init__(self, robot_ip, token, cmd_port):
        self.addr = (robot_ip, cmd_port)
        self.token = token
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(0.2)
        self.seq = int(time.time()) % 100000 * 100  # 단조 시작점
        self.acks = {}           # seq -> (send_ms, ack_recv_ms, robot_t_rx)
        self._pending = {}
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._ack_loop, daemon=True)
        self._thread.start()

    def _ack_loop(self):
        while not self._stop.is_set():
            try:
                data, _ = self.sock.recvfrom(256)
            except socket.timeout:
                continue
            except OSError:
                break
            t = data.decode("ascii", "replace").split()
            if len(t) >= 3 and t[0] == "ACK":
                seq, t_rx = int(t[1]), int(t[2])
                if seq in self._pending:
                    self.acks[seq] = (self._pending.pop(seq), now_ms(), t_rx)

    def send_v1(self, enabled=0, x=0.0, y=0.0, a=0.0, period=600,
                foot=40, hip=13.0, blevel=2, cmd_id=None):
        self.seq += 1
        cid = cmd_id or f"bench{self.seq}"
        line = (f"{cid} {enabled} {x:.2f} {y:.2f} {a:.2f} {period} {foot} "
                f"{hip:.2f} 1.00 0 {blevel} 0.00 0.00 0")
        payload = f"DFCMD {self.token} {self.seq} {line}"
        self._pending[self.seq] = now_ms()
        self.sock.sendto(payload.encode("ascii"), self.addr)
        return self.seq

    def rtt_stats(self):
        rtts = [(ack - send) for send, ack, _ in self.acks.values()]
        # 클럭 오프셋 추정: robot_t_rx − (send+ack)/2 (대칭 가정, EWMA 불필요 — 중앙값)
        offsets = [t_rx - (send + ack) / 2.0 for send, ack, t_rx in self.acks.values()]
        return {
            "acked": len(self.acks),
            "rtt_p50_ms": round(pctl(rtts, 50), 1) if rtts else None,
            "rtt_p95_ms": round(pctl(rtts, 95), 1) if rtts else None,
            "rtt_max_ms": round(max(rtts), 1) if rtts else None,
            "clock_offset_ms": round(statistics.median(offsets), 1) if offsets else None,
        }

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=1.0)
        self.sock.close()


def cmd_ack(args):
    """DFCMD를 hz로 secs초 송신 — 전달률·RTT·(보행 중이면) seq_applied 실효율."""
    listener = Tel2Listener(args.tel_port)
    sender = CmdSender(args.robot, args.token, args.cmd_port)
    sent = 0
    interval = 1.0 / args.hz
    t_end = time.time() + args.secs
    next_at = time.time()
    while time.time() < t_end:
        sender.send_v1(enabled=args.enabled, x=args.x, period=args.period)
        sent += 1
        next_at += interval
        time.sleep(max(0.0, next_at - time.time()))
    time.sleep(0.5)
    sender.stop()
    listener.stop()

    applied = sorted({p["seq_applied"] for _, _, p in listener.lines
                      if p and p.get("v") == 2 and p.get("seq_applied", 0) > 0})
    stats = {
        "sent": sent, "send_hz": args.hz, "secs": args.secs,
        **sender.rtt_stats(),
        "delivery_pct": round(len(sender.acks) / sent * 100.0, 1) if sent else None,
        "distinct_seq_applied": len(applied),
        "applied_hz_est": round(len(applied) / args.secs, 1) if applied else 0,
        "tel2": tel2_stats(listener.lines, args.secs),
    }
    print(json.dumps(stats, indent=1))
    return 0


# ── 거버너 스텝 응답 (P4) ────────────────────────────────────────────────────

def cmd_step(args):
    """x 0→목표 스텝 입력 후 TEL2 x_lat 궤적 기록 — 슬루 계단·정착 시간 측정."""
    listener = Tel2Listener(args.tel_port)
    sender = CmdSender(args.robot, args.token, args.cmd_port)
    # 기준선: x=0 보행 명령 2s (이미 보행 중이어야 함 — enabled=1)
    t0 = now_ms()
    for _ in range(int(2 / 0.05)):
        sender.send_v1(enabled=1, x=0.0, period=args.period)
        time.sleep(0.05)
    t_step = now_ms()
    t_end = time.time() + args.hold_secs
    while time.time() < t_end:
        sender.send_v1(enabled=1, x=args.x, period=args.period)
        time.sleep(0.05)
    sender.stop()
    listener.stop()

    traj = [(t - t_step, p["x_lat"], p["period_lat"]) for t, _, p in listener.lines
            if p and p.get("v") == 2 and t >= t0]
    target = None
    settle_ms = None
    xs = [x for _, x, _ in traj]
    if xs:
        target = max(xs)  # 거버너 클램프 후 실제 도달값
        for dt, x, _ in traj:
            if dt >= 0 and abs(x - target) <= 0.5:
                settle_ms = round(dt, 1)
                break
    print(json.dumps({
        "x_cmd": args.x, "period": args.period,
        "x_lat_reached": target, "settle_ms_after_step": settle_ms,
        "trajectory": [(round(dt, 1), x, pl) for dt, x, pl in traj
                       if -500 <= dt <= 6000],
    }, indent=1))
    return 0


# ── E-STOP (P3) ──────────────────────────────────────────────────────────────

def cmd_estop(args):
    """§G.2 DF-ESTOP ×3연발(0/50/100ms) → TEL2 위상 동결 시점으로 E2E 지연 측정."""
    listener = Tel2Listener(args.tel_port)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    time.sleep(1.0)  # 사전 TEL2 위상 샘플 확보
    t0 = now_ms()
    for delay in (0.0, 0.05, 0.10):
        time.sleep(delay if delay == 0.0 else 0.05)
        payload = f"DF-ESTOP v1 {args.token} {int(now_ms())}"
        sock.sendto(payload.encode("ascii"), (args.robot, args.estop_port))
    time.sleep(args.watch_secs)
    listener.stop()
    sock.close()

    phases = [(t - t0, p["phase"], p["x_lat"]) for t, _, p in listener.lines
              if p and p.get("v") == 2]
    # 위상 동결 = 연속 TEL2 라인에서 phase 변화 없음이 시작되는 시점
    freeze_at = None
    for i in range(1, len(phases)):
        dt, ph, _ = phases[i]
        if dt <= 0:
            continue
        if ph == phases[i - 1][1] and all(
                p == ph for _, p, _ in phases[i:i + 5]):
            freeze_at = round(dt, 1)
            break
    print(json.dumps({
        "estop_sent_at_ms0": 0,
        "phase_freeze_after_ms": freeze_at,
        "phases_around": [(round(dt, 1), ph, x) for dt, ph, x in phases
                          if -300 <= dt <= 2000],
    }, indent=1))
    return 0


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("provision", help="§G.1 핸드셰이크+업링크 기록(ssh)")
    p.add_argument("--ssh", default="darwin-wifi")
    p.add_argument("--mac-ip", default="192.168.0.18")
    p.add_argument("--estop-port", type=int, default=ESTOP_PORT)
    p.add_argument("--cmd-port", type=int, default=CMD_PORT)
    p.add_argument("--tel-port", type=int, default=TEL_PORT)
    p.add_argument("--clear", action="store_true")
    p.set_defaults(fn=cmd_provision)

    p = sub.add_parser("tel2", help="TEL2 30Hz 수신율 측정")
    p.add_argument("--port", type=int, default=TEL_PORT)
    p.add_argument("--secs", type=float, default=20)
    p.add_argument("--dump", default=None)
    p.set_defaults(fn=cmd_tel2)

    p = sub.add_parser("ack", help="DFCMD 송신/ACK 전달률·RTT·실효율")
    p.add_argument("--robot", default="192.168.0.33")
    p.add_argument("--token", required=True)
    p.add_argument("--hz", type=float, default=50)
    p.add_argument("--secs", type=float, default=20)
    p.add_argument("--enabled", type=int, default=0)
    p.add_argument("--x", type=float, default=0.0)
    p.add_argument("--period", type=int, default=600)
    p.add_argument("--cmd-port", type=int, default=CMD_PORT)
    p.add_argument("--tel-port", type=int, default=TEL_PORT)
    p.set_defaults(fn=cmd_ack)

    p = sub.add_parser("step", help="거버너 스텝 응답(x 0→목표) 궤적")
    p.add_argument("--robot", default="192.168.0.33")
    p.add_argument("--token", required=True)
    p.add_argument("--x", type=float, default=38)
    p.add_argument("--period", type=int, default=600)
    p.add_argument("--hold-secs", type=float, default=6)
    p.add_argument("--cmd-port", type=int, default=CMD_PORT)
    p.add_argument("--tel-port", type=int, default=TEL_PORT)
    p.set_defaults(fn=cmd_step)

    p = sub.add_parser("estop", help="DF-ESTOP ×3연발 E2E 지연")
    p.add_argument("--robot", default="192.168.0.33")
    p.add_argument("--token", required=True)
    p.add_argument("--estop-port", type=int, default=ESTOP_PORT)
    p.add_argument("--tel-port", type=int, default=TEL_PORT)
    p.add_argument("--watch-secs", type=float, default=3)
    p.set_defaults(fn=cmd_estop)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
