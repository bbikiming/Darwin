#!/usr/bin/env python3
"""retime-kick.py — 킥 모션 페이지(12=R/13=L) 스냅 감속 (안정성, 2026-06-13).

왜: 공장 motion_4096.bin 의 사커킥은 스냅 스텝(2~4)이 각 ~72ms(play_time=9)로 매우
빨라, 온보드 Action 재생이 개루프(킥 중 능동 자이로 밸런스 없음 — MotionManager 는
balance 미적용, BALANCE_*_GAIN 은 Walking 전용)인 DARwIn-OP 에서 반동을 못 잡고 넘어질
수 있다. 스냅 스텝의 play_time 을 늘려(기본 9→18, 72→144ms) 각속도를 절반으로 낮추면
동작 형태는 유지하면서 안정 마진을 회복한다. (Action 엔 런타임 speed 노브 없음 → 페이지
타이밍 자체를 수정해야 함.)

무엇을: pages 12/13 의 지정 스텝 play_time(byte) 만 바꾸고 **페이지 체크섬을 재계산**한다
(ROBOTIS Action.cpp: 페이지 512바이트 합 ≡ 0xFF, checksum byte = header offset 31,
SetChecksum = 0xFF - sum). 다른 페이지는 byte-identical 로 보존. 체크섬을 안 고치면
Action::LoadPage 가 조용히 거부 → 킥 무동작이 되므로 필수.

사용:
  python3 retime-kick.py <factory_motion_4096.bin> <output.bin> [--play-time 18] [--steps 2,3,4]
  # 배포: scp output.bin → robot:/robotis/Data/motion_4096.bin (원본 백업 후), 데모 재기동.

검증: 변경 바이트 수(스텝당 1 + 페이지당 체크섬 1), 페이지 합 ≡ 0xFF, 그리고 12/13 외
페이지가 입력과 동일한지 자동 확인한다.
"""
import argparse
import sys

PAGE = 512
HDR = 64
STEP = 64
NUM_PAGES = 256
CHECKSUM_OFF = 31          # PAGEHEADER.checksum (Action.h)
KICK_PAGES = (12, 13)      # 12 = R kick(rk), 13 = L kick(lk)


def step_time_off(pg, i):
    """페이지 pg, 스텝 i 의 play_time(byte) 파일 오프셋. (STEP.time = offset 63)."""
    return pg * PAGE + HDR + i * STEP + 63


def set_page_checksum(buf, pg):
    """ROBOTIS SetChecksum: checksum=0 후 512바이트 합, checksum = 0xFF - sum."""
    o = pg * PAGE
    buf[o + CHECKSUM_OFF] = 0
    s = sum(buf[o:o + PAGE]) & 0xFF
    buf[o + CHECKSUM_OFF] = (0xFF - s) & 0xFF


def main():
    ap = argparse.ArgumentParser(description="킥 페이지(12/13) 스냅 감속 + 체크섬 재계산")
    ap.add_argument("input", help="입력 motion_4096.bin (공장/현행)")
    ap.add_argument("output", help="출력 motion_4096.bin (감속본)")
    ap.add_argument("--play-time", type=int, default=18,
                    help="스냅 스텝의 새 play_time (×8ms). 기본 18 = 144ms (공장 9=72ms).")
    ap.add_argument("--steps", default="2,3,4",
                    help="감속할 스텝 인덱스 (쉼표구분). 기본 2,3,4 (킥 스냅).")
    args = ap.parse_args()

    slow_steps = tuple(int(s) for s in args.steps.split(","))
    if not (1 <= args.play_time <= 255):
        sys.exit(f"--play-time 은 1..255 (받음 {args.play_time})")

    data = bytearray(open(args.input, "rb").read())
    if len(data) != PAGE * NUM_PAGES:
        sys.exit(f"motion_4096.bin 크기는 {PAGE * NUM_PAGES} 여야 함 (받음 {len(data)})")
    orig = bytes(data)

    changed = []
    for pg in KICK_PAGES:
        for i in slow_steps:
            off = step_time_off(pg, i)
            old = data[off]
            data[off] = args.play_time
            changed.append((pg, i, old, args.play_time))
        set_page_checksum(data, pg)

    open(args.output, "wb").write(bytes(data))

    # ---- 검증 ----
    print("== 변경 스텝 play_time ==")
    for pg, i, old, new in changed:
        print(f"  page{pg} step{i}: {old} -> {new}  ({old * 8}ms -> {new * 8}ms)")

    print("== 페이지 체크섬 (합 ≡ 0xFF 이어야 Action 수락) ==")
    ok = True
    for pg in KICK_PAGES:
        o = pg * PAGE
        s = sum(data[o:o + PAGE]) & 0xFF
        good = (s == 0xFF)
        ok = ok and good
        print(f"  page{pg}: sum&0xFF=0x{s:02x} {'OK' if good else 'BAD'}")

    outside = sum(1 for idx in range(len(data))
                  if orig[idx] != data[idx] and (idx // PAGE) not in KICK_PAGES)
    total = sum(1 for idx in range(len(data)) if orig[idx] != data[idx])
    print(f"== 12/13 외 변경 바이트: {outside} (0 이어야 함) / 총 변경: {total} ==")
    if outside != 0 or not ok:
        sys.exit("검증 실패 — 출력 폐기 권장")
    print(f"✓ {args.output} 생성 — 킥 스냅 감속 완료(타 모션 무손상).")


if __name__ == "__main__":
    main()
