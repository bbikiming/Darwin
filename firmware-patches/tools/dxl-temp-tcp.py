#!/usr/bin/env python3
"""dxl-temp-tcp — 로봇 socat 브리지(tcp:5530)로 서보 전압/온도 일괄 read.

DXL protocol 1.0 READ(0x02), addr 42(PRESENT_VOLTAGE)+43(PRESENT_TEMPERATURE) 2바이트.
P6 실기(서보 온도 10분) 측정용 — Mac 에서 실행, 로봇측 빌드 불요.

⚠️ 반드시 demo(또는 다른 버스 소유자)가 정지된 상태에서 실행할 것 — CM730 시리얼은
   단일 소유 전제. 보행/관절편집 세션과 동시 실행 금지 (버스 충돌).

사용: python3 dxl-temp-tcp.py [--host 192.168.123.1] [--port 5530] [--ids 1-20]
"""

import argparse
import json
import socket
import sys
import time

JOINT_NAMES = {
    1: "R_SHO_PITCH", 2: "L_SHO_PITCH", 3: "R_SHO_ROLL", 4: "L_SHO_ROLL",
    5: "R_ELBOW", 6: "L_ELBOW", 7: "R_HIP_YAW", 8: "L_HIP_YAW",
    9: "R_HIP_ROLL", 10: "L_HIP_ROLL", 11: "R_HIP_PITCH", 12: "L_HIP_PITCH",
    13: "R_KNEE", 14: "L_KNEE", 15: "R_ANK_PITCH", 16: "L_ANK_PITCH",
    17: "R_ANK_ROLL", 18: "L_ANK_ROLL", 19: "HEAD_PAN", 20: "HEAD_TILT",
}


def dxl_read_packet(dxl_id, addr, length):
    body = [dxl_id, 4, 0x02, addr, length]
    checksum = (~sum(body)) & 0xFF
    return bytes([0xFF, 0xFF] + body + [checksum])


def parse_status(buf, dxl_id):
    """버퍼에서 id 의 status packet 탐색 → (err, params) 또는 None."""
    i = 0
    while i + 5 < len(buf):
        if buf[i] == 0xFF and buf[i + 1] == 0xFF and buf[i + 2] == dxl_id:
            length = buf[i + 3]
            end = i + 4 + length
            if end > len(buf):
                return None
            err = buf[i + 4]
            params = list(buf[i + 5:end - 1])
            return (err, params)
        i += 1
    return None


def read_servo(sock, dxl_id, addr=42, length=2, timeout=0.4):
    sock.sendall(dxl_read_packet(dxl_id, addr, length))
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        sock.settimeout(max(0.05, deadline - time.time()))
        try:
            chunk = sock.recv(64)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        st = parse_status(buf, dxl_id)
        if st:
            return st
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="192.168.123.1")
    ap.add_argument("--port", type=int, default=5530)
    ap.add_argument("--ids", default="1-20")
    args = ap.parse_args()

    lo, hi = (int(x) for x in args.ids.split("-"))
    sock = socket.create_connection((args.host, args.port), timeout=3)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    out = {}
    for dxl_id in range(lo, hi + 1):
        st = read_servo(sock, dxl_id)
        if st is None:
            st = read_servo(sock, dxl_id)  # 1회 재시도
        if st and len(st[1]) >= 2:
            err, (volt, temp) = st[0], st[1][:2]
            out[dxl_id] = {"name": JOINT_NAMES.get(dxl_id, "?"),
                           "temp_c": temp, "volt_dV": volt, "err": err}
        else:
            out[dxl_id] = {"name": JOINT_NAMES.get(dxl_id, "?"), "temp_c": None}
        time.sleep(0.01)
    sock.close()

    temps = [v["temp_c"] for v in out.values() if v["temp_c"] is not None]
    print(json.dumps({"ts": time.strftime("%H:%M:%S"), "servos": out,
                      "max_temp": max(temps) if temps else None,
                      "read_ok": len(temps)}, ensure_ascii=False, indent=1))
    return 0 if temps else 1


if __name__ == "__main__":
    sys.exit(main())
