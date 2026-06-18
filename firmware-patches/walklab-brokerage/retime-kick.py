#!/usr/bin/env python3
"""retime-kick.py — 다리스윙 Action 페이지(킥 12/13 + 패스 70/71) 스냅 감속 (안정성).

왜: 공장 motion_4096.bin 의 사커킥·패스는 스냅 스텝이 각 ~72ms(play_time=9)로 매우
빨라, 온보드 Action 재생이 개루프(킥/패스 중 능동 자이로 밸런스 없음 — MotionManager 는
balance 미적용, BALANCE_*_GAIN 은 Walking 전용)인 DARwIn-OP 에서 반동을 못 잡고 넘어질
수 있다. 스냅 스텝의 play_time 을 늘려(기본 9→18, 72→144ms) 각속도를 절반으로 낮추면
동작 형태는 유지하면서 안정 마진을 회복한다. (Action 엔 런타임 speed 노브 없음 → 페이지
타이밍 자체를 수정해야 함.)

**B1 (2026-06-15)**: 종전엔 킥(12/13)만 감속했다. D-패드 패스(70=rPASS/71=lPASS)는
킥과 동일한 다리스윙·개루프 재생인데 스냅 스텝이 오히려 더 많다(킥 2,3,4 = 3개 vs
패스 1,2,3,4,6 = 5개, 전부 play_time=9 실측). 동일 낙상 위험이므로 함께 감속한다.
페이지별 스냅 스텝 인덱스가 다르므로 **자동 탐지**(stepnum 범위 내 1≤play_time≤snap-max)
한다 — 하드코딩 인덱스보다 견고. (--steps 로 명시 override 가능.)

**B3 (2026-06-18)**: 패스를 킥보다 **더 강하게** 감속한다(킥 144ms < 패스 192ms,
`--pass-play-time`). 근거(공장 bin 실측): 킥은 [496,200,72,72,72,112,496]ms 로 느린
윈드업/착지(496ms)가 무게중심을 잡아주지만, 패스는 [200,72,72,72,72,200,72]ms 로
느린 윈드업이 없고 7스텝 중 5개가 빠르며 마지막 복귀 스텝까지 72ms 다. 게다가 측면
무게이동(횡 스윙)이라 복원 마진이 작다 → 실기서 "패스만 넘어짐". 최종값은 요람 스윕으로
확정(입회) — 너무 느리면 동작이 어색하므로 192ms 부터 시작해 안정 확인 후 미세조정.

무엇을: pages 12/13/70/71 의 스냅 스텝 play_time(byte) 만 바꾸고 **페이지 체크섬을 재계산**
한다 (ROBOTIS Action.cpp: 페이지 512바이트 합 ≡ 0xFF, checksum byte = header offset 31,
SetChecksum = 0xFF - sum). 다른 페이지는 byte-identical 로 보존. 체크섬을 안 고치면
Action::LoadPage 가 조용히 거부 → 무동작이 되므로 필수.

사용:
  python3 retime-kick.py <factory_motion_4096.bin> <output.bin> [--play-time 18] [--pass-play-time 24] [--snap-max 9]
  python3 retime-kick.py in.bin out.bin --pass-play-time 27   # 패스 216ms — 192ms 로도 넘어지면
  python3 retime-kick.py in.bin out.bin --steps 2,3,4    # 자동탐지 대신 명시 인덱스(전 페이지 공통)
  # 배포: scp output.bin → robot:/robotis/Data/motion_4096.bin (원본 백업 후), 데모 재기동.
  # ★ retimed 산출물은 git 에 보존되지 않는다(B2) — 공장초기화/재셋업 시 이 단계를 반드시
  #   재실행해야 킥·패스 감속이 유지된다. INTEGRATION.md '모션 페이지 감속' 절 참조.

검증: 변경 바이트 수(스텝당 1 + 페이지당 체크섬 1), 페이지 합 ≡ 0xFF, 그리고 대상 외
페이지가 입력과 동일한지 자동 확인한다.
"""
import argparse
import sys

PAGE = 512
HDR = 64
STEP = 64
NUM_PAGES = 256
CHECKSUM_OFF = 31          # PAGEHEADER.checksum (Action.h)
STEPNUM_OFF = 20           # PAGEHEADER.stepnum (Action.h) — 유효 스텝 수
STEP_TIME_OFF = 63         # STEP.time (play_time, ×8ms) — 스텝 내 오프셋
KICK_PAGES = (12, 13)             # 12=rk · 13=lk (전진 스윙, 느린 윈드업/착지 496ms가 잡아줌)
PASS_PAGES = (70, 71)             # 70=rPASS · 71=lPASS (측면 스윙)
RETIME_PAGES = KICK_PAGES + PASS_PAGES   # 다리스윙·개루프 페이지 전체


def step_time_off(pg, i):
    """페이지 pg, 스텝 i 의 play_time(byte) 파일 오프셋."""
    return pg * PAGE + HDR + i * STEP + STEP_TIME_OFF


def page_stepnum(buf, pg):
    """페이지 pg 의 유효 스텝 수(헤더 stepnum)."""
    return buf[pg * PAGE + STEPNUM_OFF]


def set_page_checksum(buf, pg):
    """ROBOTIS SetChecksum: checksum=0 후 512바이트 합, checksum = 0xFF - sum."""
    o = pg * PAGE
    buf[o + CHECKSUM_OFF] = 0
    s = sum(buf[o:o + PAGE]) & 0xFF
    buf[o + CHECKSUM_OFF] = (0xFF - s) & 0xFF


def snap_steps(buf, pg, snap_max):
    """페이지 pg 에서 감속 대상 스냅 스텝 인덱스(stepnum 범위 내 1≤play_time≤snap_max)."""
    n = page_stepnum(buf, pg)
    out = []
    for i in range(n):
        t = buf[step_time_off(pg, i)]
        if 1 <= t <= snap_max:
            out.append(i)
    return out


def main():
    ap = argparse.ArgumentParser(description="다리스윙 페이지(킥 12/13 + 패스 70/71) 스냅 감속 + 체크섬 재계산")
    ap.add_argument("input", help="입력 motion_4096.bin (공장/현행)")
    ap.add_argument("output", help="출력 motion_4096.bin (감속본)")
    ap.add_argument("--play-time", type=int, default=18,
                    help="킥(12/13) 스냅 스텝의 새 play_time (×8ms). 기본 18 = 144ms (공장 9=72ms).")
    ap.add_argument("--pass-play-time", type=int, default=24,
                    help="패스(70/71) 스냅 스텝의 새 play_time (×8ms). 기본 24 = 192ms. "
                         "패스는 측면 무게이동 + 느린 윈드업 부재(7스텝 중 5개가 빠름)로 킥보다 "
                         "더 잘 넘어지므로 더 강하게 감속(킥 144ms < 패스 192ms).")
    ap.add_argument("--snap-max", type=int, default=9,
                    help="이 값 이하 play_time 스텝을 '스냅'으로 보고 감속(자동탐지). 기본 9=72ms.")
    ap.add_argument("--steps", default="",
                    help="자동탐지 대신 감속할 스텝 인덱스를 명시(쉼표구분, 전 대상 페이지 공통). "
                         "비우면 페이지별 자동탐지(권장).")
    args = ap.parse_args()

    if not (1 <= args.play_time <= 255):
        sys.exit(f"--play-time 은 1..255 (받음 {args.play_time})")
    if not (1 <= args.pass_play_time <= 255):
        sys.exit(f"--pass-play-time 은 1..255 (받음 {args.pass_play_time})")
    explicit_steps = None
    if args.steps.strip():
        explicit_steps = tuple(int(s) for s in args.steps.split(","))

    data = bytearray(open(args.input, "rb").read())
    if len(data) != PAGE * NUM_PAGES:
        sys.exit(f"motion_4096.bin 크기는 {PAGE * NUM_PAGES} 여야 함 (받음 {len(data)})")
    orig = bytes(data)

    changed = []
    for pg in RETIME_PAGES:
        # 패스(70/71)는 킥(12/13)보다 더 강하게 감속 — 측면 무게이동 + 빠른 스텝 비율이
        # 높아 낙상 마진이 더 작다(킥 play-time < 패스 pass-play-time).
        new_pt = args.pass_play_time if pg in PASS_PAGES else args.play_time
        steps = explicit_steps if explicit_steps is not None else snap_steps(data, pg, args.snap_max)
        for i in steps:
            off = step_time_off(pg, i)
            old = data[off]
            data[off] = new_pt
            changed.append((pg, i, old, new_pt))
        set_page_checksum(data, pg)

    open(args.output, "wb").write(bytes(data))

    # ---- 검증 ----
    print("== 변경 스텝 play_time (페이지별 자동탐지/명시) ==")
    for pg, i, old, new in changed:
        print(f"  page{pg} step{i}: {old} -> {new}  ({old * 8}ms -> {new * 8}ms)")
    if not changed:
        sys.exit("변경 없음 — snap-max/steps 확인(입력이 이미 감속본일 수 있음)")

    print("== 페이지 체크섬 (합 ≡ 0xFF 이어야 Action 수락) ==")
    ok = True
    for pg in RETIME_PAGES:
        o = pg * PAGE
        s = sum(data[o:o + PAGE]) & 0xFF
        good = (s == 0xFF)
        ok = ok and good
        print(f"  page{pg}: sum&0xFF=0x{s:02x} {'OK' if good else 'BAD'}")

    outside = sum(1 for idx in range(len(data))
                  if orig[idx] != data[idx] and (idx // PAGE) not in RETIME_PAGES)
    total = sum(1 for idx in range(len(data)) if orig[idx] != data[idx])
    print(f"== 대상(12/13/70/71) 외 변경 바이트: {outside} (0 이어야 함) / 총 변경: {total} ==")
    if outside != 0 or not ok:
        sys.exit("검증 실패 — 출력 폐기 권장")
    print(f"✓ {args.output} 생성 — 킥·패스 스냅 감속 완료(타 모션 무손상).")


if __name__ == "__main__":
    main()
