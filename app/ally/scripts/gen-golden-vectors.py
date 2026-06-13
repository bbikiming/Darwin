#!/usr/bin/env python3
"""df-wire 골든 벡터 생성기 — Python 원본(df_udp.py)을 실행해 패리티 픽스처를 만든다.

실기 검증된 Switch 구현(tools/switch-pilot/src/darwin_switch_agent/)이 진실원이다.
이 스크립트는 그 코드를 import 해 실제로 실행하고, (입력 → 기대 출력) 쌍을
crates/df-wire/tests/fixtures/*.txt 로 기록한다. Rust 쪽 tests/parity.rs 가
동일 입력에 대해 바이트/캐노니컬 동일성을 검증한다.

결정적이다(난수 없음) — 재실행 시 항상 같은 픽스처가 나온다.

사용법:
    python3 app/ally/scripts/gen-golden-vectors.py
"""

from __future__ import annotations

import pathlib
import sys

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
ALLY_ROOT = SCRIPT_DIR.parent                      # app/ally
REPO_ROOT = ALLY_ROOT.parent.parent                # Darwin
FIXTURES = ALLY_ROOT / "crates/df-wire/tests/fixtures"

sys.path.insert(0, str(REPO_ROOT / "tools/switch-pilot/src"))

# Windows 호환 심: switch-pilot 패키지는 Linux 전용 모듈(fcntl)과 POSIX 전용
# os.getuid 를 모듈 레벨에서 참조한다(입력 백엔드·SSH ControlPath — 이 생성기는
# 순함수만 쓰므로 둘 다 실행 경로에 없다). Ally(Windows)에서 픽스처를 재생성할
# 수 있도록 import 전에 무해한 스텁을 깔아 둔다.
import os  # noqa: E402
import types  # noqa: E402

if "fcntl" not in sys.modules:
    try:
        import fcntl  # noqa: F401
    except ModuleNotFoundError:
        sys.modules["fcntl"] = types.ModuleType("fcntl")
if not hasattr(os, "getuid"):
    os.getuid = lambda: 0  # type: ignore[attr-defined]

from darwin_switch_agent import df_udp  # noqa: E402
from darwin_switch_agent.mapping import MotionCommand  # noqa: E402
from darwin_switch_agent.ssh_control_client import SshControlClient  # noqa: E402

TOKEN = "AbC123xYz0PqRsT9"


def hx(data: bytes) -> str:
    return data.hex()


def canon_tel2(d: dict | None) -> str:
    """TEL2 파싱 결과의 캐노니컬 직렬화 — Rust `Tel2::canonical()` 과 핀 고정 거울.

    형식을 바꾸면 양쪽을 함께 바꿔야 한다. 부동소수점은 %.6f 로 고정해
    Python repr / Rust Display 차이를 제거한다.
    """
    if d is None:
        return "none"

    def f6(x: float) -> str:
        return f"{x:.6f}"

    def b(x: bool) -> str:
        return "1" if x else "0"

    fsr = "-" if d["fsr"] is None else ",".join(str(c) for c in d["fsr"])
    cop = "-" if d["cop"] is None else ",".join(str(c) for c in d["cop"])
    risk = "-" if d["risk"] is None else f6(d["risk"])
    volt = "-" if d["voltage_v"] is None else f6(d["voltage_v"])
    pct = "-" if d["battery_pct"] is None else str(d["battery_pct"])
    return (
        f"ts={d['ts_ms']} seq={d['seq_applied']} phase={d['phase']} "
        f"x={f6(d['latch']['x'])} y={f6(d['latch']['y'])} "
        f"a={f6(d['latch']['a'])} period={f6(d['latch']['period'])} "
        f"gx={d['gyro']['x']} gy={d['gyro']['y']} gz={d['gyro']['z']} "
        f"ax={d['accel']['x']} ay={d['accel']['y']} az={d['accel']['z']} "
        f"fsr={fsr} cop={cop} ground={b(d['ground'])} "
        f"lc={b(d['left_contact'])} rc={b(d['right_contact'])} "
        f"fallen={d['fallen']} risk={risk} v={volt} pct={pct} "
        f"src={d['active_source']} loop={d['loop_ms']} walking={b(d['walking'])}"
    )


def gen_handshake() -> list[str]:
    cases = [
        (TOKEN, 17372, 17374),
        ("aaaaaaaaaaaaaaaa", 1, 65535),
        ("Z9y8X7w6V5u4T3s2", 17372, 17374),
    ]
    return [
        f"{token}|{estop}|{cmd}|{hx(df_udp.handshake_line(token, estop, cmd).encode('ascii'))}"
        for token, estop, cmd in cases
    ]


def gen_cmd_datagrams() -> list[str]:
    cases = [
        (TOKEN, 1, "cmdid0001 1 37.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0"),
        (TOKEN, 4294967296, "x"),
        (TOKEN, 20, "deadbeefcafe 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0"),
        ("tok", 7, "스트라이드 mixé ascii"),  # 비ASCII 탈락 경로
    ]
    return [
        f"{token}|{seq}|{hx(df_udp.cmd_datagram(token, seq, line))}|{line}"
        for token, seq, line in cases
    ]


def gen_estop_datagrams() -> list[str]:
    cases = [(TOKEN, 1749800000000), ("tok", 0), (TOKEN, 1)]
    return [f"{token}|{ts}|{hx(df_udp.estop_datagram(token, ts))}" for token, ts in cases]


def gen_acks() -> list[str]:
    inputs = [
        b"ACK 17 123456",
        b"ACK 17 99 extra tokens",
        b"ACK 17",
        b"NAK 1 2",
        b"ACK x y",
        b"",
        b"ACK -3 +7",
        b"\xffACK 1 2",  # 비ASCII 프리픽스 → 필터 후 정상 파싱
        b"ack 1 2",
        b"  ACK   5   6  ",
        b"TEL2 1 2",
    ]
    out = []
    for data in inputs:
        parsed = df_udp.parse_ack(data)
        expected = "none" if parsed is None else f"{parsed[0]} {parsed[1]}"
        out.append(f"{hx(data)}|{expected}")
    return out


def gen_tel2() -> list[str]:
    inputs = [
        # 풀 필드: FSR 8셀 + CoP + risk 없음
        b"TEL2 12345678 42 2 37.00 0.00 -3.25 600 -150 25 500 100 -50 10"
        b" 1 2 3 4 0 0 0 0 12 -5 0 - 110 local 21",
        # FSR/CoP/risk 전부 "-", 전압 0(미상), phase -1(비보행)
        b"TEL2 1 0 -1 0 0 0 700 0 0 0 0 0 0 - - 0 - 0 file 100",
        # 낙상 + risk float + CoP만 존재
        b"TEL2 999 7 1 10.5 -2 1.25 560 1 2 3 4 5 6 - 3 4 1 0.85 95 udp 20",
        # 오른발만 접지
        b"TEL2 5 5 0 1 1 1 600 0 0 0 0 0 0 0 0 0 0 1 2 3 4 - 0 - 124 local 19",
        # 후행 잡음 토큰은 무시 (원본 파서는 loop_ms 까지만 읽는다)
        b"TEL2 1 0 0 0 0 0 700 0 0 0 0 0 0 - - 0 - 121 local 33 junk 42",
        # 앞뒤 공백·개행
        b"  TEL2 7 1 3 2.5 0 0 620 9 8 7 6 5 4 - - 0 0.5 105 udp 18\n",
        # 형태 불량 → none
        b"TEL 1 2 3",
        b"TEL2 abc 0 0 0 0 0 700 0 0 0 0 0 0 - - 0 - 0 file 1",
        b"TEL2 1 2 3",
        b"TEL2 12 1 0 0 0 0 600 0 0 0 0 0 0 1 2 3",  # FSR 8셀 미달
        b"",
    ]
    return [f"{hx(data)}|{canon_tel2(df_udp.parse_tel2(data))}" for data in inputs]


def gen_battery() -> list[str]:
    out = []
    for dv in [0, -5, 1, 104, 105, 110, 121, 124, 126, 131]:
        volt, pct = df_udp.battery_from_dv(dv)
        v_s = "-" if volt is None else f"{volt:.6f}"
        p_s = "-" if pct is None else str(pct)
        out.append(f"{dv}|{v_s}|{p_s}")
    return out


def build_line_via_python(cfg: dict, cmd: MotionCommand, cmd_id: str) -> str:
    """검증된 _gait_params 를 실제 호출하고, _build_line 의 f-string 을 거울한다.

    _build_line 자체는 내부에서 uuid4 cmd_id 를 만들어 골든 벡터가 불가능하므로
    포맷 문자열만 원본(ssh_control_client.py L455-461)에서 복사했다 — 원본이
    바뀌면 여기도 함께 바꿔야 한다(패리티 테스트가 드리프트를 잡는다).
    """
    client = object.__new__(SshControlClient)  # __init__ 부작용 없이 게이트 필드만 주입
    for key, value in cfg.items():
        setattr(client, key, value)
    period_ms, foot_mm = client._gait_params(cmd)
    enabled = 1 if cmd.enabled else 0
    return (
        f"{cmd_id} {enabled} "
        f"{cmd.stride_mm:.2f} {cmd.side_mm:.2f} {cmd.turn_deg:.2f} "
        f"{period_ms:.0f} {foot_mm:.0f} {client.hip_deg:.0f} "
        f"1.0 0 2 "
        f"{cmd.head_pan_deg:.2f} {cmd.head_tilt_deg:.2f} 0"
    )


def gen_build_lines() -> list[str]:
    # Switch 기본 게이트(ssh_control_client DEFAULT_*)와 G01 온보드 스케줄 등가.
    cfg_default = dict(
        period_ms=600.0, foot_mm=40.0, hip_deg=13.0,
        min_period_ms=520.0, max_period_ms=780.0, min_foot_mm=18.0,
        stride_ref_mm=25.0, turn_ref_deg=12.0,
    )
    cfg_g01 = dict(
        period_ms=700.0, foot_mm=40.0, hip_deg=13.0,
        min_period_ms=560.0, max_period_ms=700.0, min_foot_mm=18.0,
        stride_ref_mm=38.0, turn_ref_deg=12.0,
    )

    def mc(enabled, stride, side, turn, pan, tilt):
        return MotionCommand(
            enabled=enabled, stride_mm=stride, side_mm=side, turn_deg=turn,
            head_pan_deg=pan, head_tilt_deg=tilt, speed_scale=1.0,
        )

    cases = [
        ("id00", cfg_default, mc(False, 0.0, 0.0, 0.0, 0.0, 0.0)),
        ("id01", cfg_default, mc(True, 25.0, 0.0, 0.0, 0.0, 0.0)),
        ("id02", cfg_default, mc(True, 12.5, 0.0, 0.0, 0.0, 0.0)),
        ("id03", cfg_default, mc(True, 30.0, 0.0, 0.0, 0.0, 0.0)),  # ref 초과 → clamp
        ("id04", cfg_default, mc(True, 0.0, 0.0, 6.0, 0.0, 0.0)),   # 턴 지배
        ("id05", cfg_default, mc(True, -25.0, -10.0, -12.0, -70.0, 35.0)),
        ("id06", cfg_default, mc(True, 0.0, 0.0, 0.0, 0.0, 0.0)),   # enabled+무입력
        ("id07", cfg_default, mc(True, 12.345, -0.005, 1.005, 12.345, -0.005)),
        ("id08", cfg_default, mc(True, 0.3, 0.0, 0.0, 0.0, 0.0)),
        ("id09", cfg_g01, mc(True, 38.0, 0.0, 0.0, 0.0, 0.0)),
        ("id10", cfg_g01, mc(True, 19.0, 0.0, 0.0, 0.0, 0.0)),
        ("id11", cfg_g01, mc(False, 0.0, 0.0, 0.0, 70.0, -35.0)),   # 정지 중 헤드만
    ]
    out = []
    for cmd_id, cfg, cmd in cases:
        expected = build_line_via_python(cfg, cmd, cmd_id)
        out.append(
            f"{cmd_id}|{cfg['period_ms']}|{cfg['foot_mm']}|{cfg['hip_deg']}"
            f"|{cfg['min_period_ms']}|{cfg['max_period_ms']}|{cfg['min_foot_mm']}"
            f"|{cfg['stride_ref_mm']}|{cfg['turn_ref_deg']}"
            f"|{1 if cmd.enabled else 0}|{cmd.stride_mm}|{cmd.side_mm}|{cmd.turn_deg}"
            f"|{cmd.head_pan_deg}|{cmd.head_tilt_deg}|{expected}"
        )
    return out


def write_fixture(name: str, header: str, lines: list[str]) -> None:
    path = FIXTURES / name
    body = "\n".join([f"# {header}", "# generated by scripts/gen-golden-vectors.py — do not edit"] + lines)
    # newline="\n" — Windows 재생성 시에도 LF 고정 (CRLF 변환 경고·디스크 바이트 차이 방지)
    path.write_text(body + "\n", encoding="utf-8", newline="\n")
    print(f"  {path.relative_to(REPO_ROOT)} ({len(lines)} cases)")


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    print("golden vectors:")
    write_fixture("handshake.txt", "token|estop_port|cmd_port|hex(expected)", gen_handshake())
    write_fixture("cmd_datagram.txt", "token|seq|hex(expected)|line", gen_cmd_datagrams())
    write_fixture("estop_datagram.txt", "token|ts_ms|hex(expected)", gen_estop_datagrams())
    write_fixture("ack.txt", "hex(input)|expected('none' or 'seq t_rx')", gen_acks())
    write_fixture("tel2.txt", "hex(input)|canonical-or-none", gen_tel2())
    write_fixture("battery.txt", "dv|voltage(%.6f or -)|pct(int or -)", gen_battery())
    write_fixture(
        "build_line.txt",
        "cmd_id|period|foot|hip|min_period|max_period|min_foot|stride_ref|turn_ref"
        "|enabled|stride|side|turn|pan|tilt|expected_line",
        gen_build_lines(),
    )
    print("done.")


if __name__ == "__main__":
    main()
