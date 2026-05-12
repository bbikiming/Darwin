#!/usr/bin/env python3
"""Generate `motion_4096.bin` with 6 walk-progression test pages (slots 110~115).

Output is a full 256-page binary (131 072 byte) that is a byte-for-byte copy of
the darwinop-ens stock catalog except pages 110~115, which are newly authored
test poses derived from walkready (page 9).

Each test page:
  - Starts and ends at exact walkready pose.
  - Modifies only specific joints by small deltas (≤ ~5° for the riskier pages).
  - Has `next=0` (stop after completion) and `exit=15` (sit_down on Stop()) so
    interrupting the test never leaves the robot in a partial pose.

Page checksum: per `Framework/src/motion/modules/Action.cpp::SetChecksum`,
  total sum of all 512 bytes (with checksum field zero) % 256 == 0xFF, so
  checksum := (0xFF - sum) & 0xFF.

Joint IDs (1-based, position[i-1] = joint with ID i):
   1  R_SHOULDER_PITCH   11  R_HIP_PITCH
   2  L_SHOULDER_PITCH   12  L_HIP_PITCH
   3  R_SHOULDER_ROLL    13  R_KNEE
   4  L_SHOULDER_ROLL    14  L_KNEE
   5  R_ELBOW            15  R_ANKLE_PITCH
   6  L_ELBOW            16  L_ANKLE_PITCH
   7  R_HIP_YAW          17  R_ANKLE_ROLL
   8  L_HIP_YAW          18  L_ANKLE_ROLL
   9  R_HIP_ROLL         19  HEAD_PAN
  10  L_HIP_ROLL         20  HEAD_TILT

Unit conversions:
  - MX-28 position tick: 0..4095, center=2048, ~0.088°/tick → 11.378 tick/°.
  - Step time field: 8 ms units (so time=125 → 1000 ms).
"""
from __future__ import annotations
import argparse
import struct
import sys
from pathlib import Path

PAGE_SIZE = 512
NUM_PAGES = 256
STEP_OFF = 64
STEP_SZ = 64
NAME_LEN = 14
NUM_STEPS_MAX = 7
NUM_POS = 31

INVALID = 0x4000  # INVALID_BIT_MASK — joint not driven by this page

SIT_DOWN_PAGE = 15

TICK_PER_DEG = 4096.0 / 360.0  # 11.378


def deg(angle_deg: float) -> int:
    return int(round(angle_deg * TICK_PER_DEG))


def read_page(blob: bytes, idx: int) -> bytes:
    return blob[idx * PAGE_SIZE : (idx + 1) * PAGE_SIZE]


def get_step_positions(page: bytes, step_idx: int) -> list[int]:
    s_off = STEP_OFF + step_idx * STEP_SZ
    return list(struct.unpack("<31H", page[s_off : s_off + 62]))


def make_page(
    name: str,
    steps: list[dict],  # [{positions:[31], pause:int, time:int}, ...]
    *,
    next_page: int = 0,
    exit_page: int = 0,
    repeat: int = 1,
    speed: int = 32,
    accel: int = 32,
    schedule: int = 0x0A,  # TIME_BASE
) -> bytes:
    assert 1 <= len(steps) <= NUM_STEPS_MAX
    assert len(name) <= NAME_LEN - 1, f"name '{name}' too long"

    page = bytearray(PAGE_SIZE)

    # Header (64 bytes)
    name_bytes = name.encode("ascii")
    page[0 : len(name_bytes)] = name_bytes
    page[14] = 0  # reserved1
    page[15] = repeat
    page[16] = schedule
    # 17..19 reserved2
    page[20] = len(steps)
    # 21 reserved3
    page[22] = speed
    # 23 reserved4
    page[24] = accel
    page[25] = next_page
    page[26] = exit_page
    # 27..30 reserved5
    # 31 checksum (set later)
    # 32..62 slope[31] — leave 0x00 (default, unused in latest MX-28 firmwares)
    # 63 reserved6

    # Steps
    for i, step in enumerate(steps):
        positions = step["positions"]
        assert len(positions) == NUM_POS, f"positions len {len(positions)} != 31"
        s_off = STEP_OFF + i * STEP_SZ
        page[s_off : s_off + 62] = struct.pack("<31H", *positions)
        page[s_off + 62] = step.get("pause", 0)
        page[s_off + 63] = step["time"]

    # Checksum: 0xFF - (sum of all 512 bytes with checksum field=0) % 256
    page[31] = 0
    total = sum(page) & 0xFF
    page[31] = (0xFF - total) & 0xFF

    # Verify
    assert (sum(page) & 0xFF) == 0xFF, "checksum verify failed"

    return bytes(page)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--source",
        type=Path,
        default=Path("research/community/darwinop-ens-darwin-op/Data/motion_4096.bin"),
        help="Stock motion bin to derive walkready from and inherit all unmodified pages.",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("motions/test/walk-progression-v1.bin"),
        help="Output motion_4096.bin (full 256-page).",
    )
    args = ap.parse_args()

    stock = args.source.read_bytes()
    assert len(stock) == PAGE_SIZE * NUM_PAGES, f"source size mismatch: {len(stock)}"

    walkready_page = read_page(stock, 9)
    wk_pose = get_step_positions(walkready_page, 0)
    print(f"walkready pose (ID 1..20):", " ".join(str(wk_pose[i]) for i in range(20)))
    # Confirm INVALID on ID 1 (R_SHOULDER_PITCH) — owned by Walking module
    assert wk_pose[0] == INVALID, f"expected ID 1 = INVALID, got {wk_pose[0]:#x}"

    def base():
        """Return a fresh copy of the walkready 31-slot position list."""
        return list(wk_pose)

    def modify(deltas: dict[int, int]) -> list[int]:
        """Apply {id: delta} (ticks) to a fresh walkready base."""
        pose = base()
        for joint_id, delta in deltas.items():
            assert 1 <= joint_id <= 20, f"invalid joint ID {joint_id}"
            idx = joint_id - 1
            if pose[idx] == INVALID:
                # Don't drive an INVALID joint — keep it owned by Walking.
                # Caller should not pass deltas for INVALID joints, but be defensive.
                continue
            pose[idx] = max(0, min(4095, pose[idx] + delta))
        return pose

    # === Page 110: wk_hold ============================================
    # 1 step, pure walkready, 2s hold. Verifies servo command + pose stability.
    p110 = make_page(
        "wk_hold",
        [{"positions": base(), "pause": 0, "time": 250}],  # 250 × 8 ms = 2000 ms
        next_page=0,
        exit_page=SIT_DOWN_PAGE,
    )

    # === Page 111: wk_arms (arms-only, no leg motion) ================
    # Safest dynamic test. R_SHOULDER_PITCH stays INVALID.
    # L_SHOULDER_PITCH and both elbows move ~10°.
    arms_fwd = modify({
        2: deg(-10),   # L_SHOULDER_PITCH -10°
        # ID 3,4: SHOULDER_ROLL — leave (lateral stability)
        5: deg(+15),   # R_ELBOW slight bend
        6: deg(-15),   # L_ELBOW slight bend (sign opposite due to mirrored joint axis)
    })
    p111 = make_page(
        "wk_arms",
        [
            {"positions": base(),     "pause": 0, "time": 125},   # 1.0 s settle
            {"positions": arms_fwd,   "pause": 0, "time": 125},   # 1.0 s extend
            {"positions": base(),     "pause": 0, "time": 125},   # 1.0 s return
        ],
        next_page=0,
        exit_page=SIT_DOWN_PAGE,
    )

    # === Page 112: wk_knee (gentle squat, ~3°) =======================
    # Knees + hip_pitch + ankle_pitch coordinated so torso stays vertical.
    # 3° knee bend = ~34 ticks; hip_pitch -1.5°, ankle_pitch +1.5° to compensate.
    squat_3 = modify({
        11: deg(-1.5),   # R_HIP_PITCH lean forward slightly
        12: deg(+1.5),   # L_HIP_PITCH (sign opposite — mirrored)
        13: deg(+3.0),   # R_KNEE bend
        14: deg(-3.0),   # L_KNEE bend (sign opposite)
        15: deg(+1.5),   # R_ANKLE_PITCH compensate
        16: deg(-1.5),   # L_ANKLE_PITCH compensate (sign opposite)
    })
    p112 = make_page(
        "wk_knee",
        [
            {"positions": base(),    "pause": 0, "time": 125},   # 1.0 s settle
            {"positions": squat_3,   "pause": 0, "time": 125},   # 1.0 s squat
            {"positions": base(),    "pause": 0, "time": 125},   # 1.0 s return
        ],
        next_page=0,
        exit_page=SIT_DOWN_PAGE,
    )

    # === Page 113: wk_hip_r (hip sway right, NO ankle change) =========
    # Hip roll only — body sways laterally with feet planted flat.
    # 2.5° hip_roll = ~28 ticks. Both hips shift in same direction.
    hip_sway_r = modify({
        9:  deg(+2.5),   # R_HIP_ROLL right
        10: deg(+2.5),   # L_HIP_ROLL right (same sign — body shifts right as a unit)
    })
    p113 = make_page(
        "wk_hip_r",
        [
            {"positions": base(),       "pause": 0, "time": 125},
            {"positions": hip_sway_r,   "pause": 0, "time": 125},
            {"positions": base(),       "pause": 0, "time": 125},
        ],
        next_page=0,
        exit_page=SIT_DOWN_PAGE,
    )

    # === Page 114: wk_hip_l (mirror of 113) ==========================
    hip_sway_l = modify({
        9:  deg(-2.5),   # R_HIP_ROLL left
        10: deg(-2.5),   # L_HIP_ROLL left
    })
    p114 = make_page(
        "wk_hip_l",
        [
            {"positions": base(),       "pause": 0, "time": 125},
            {"positions": hip_sway_l,   "pause": 0, "time": 125},
            {"positions": base(),       "pause": 0, "time": 125},
        ],
        next_page=0,
        exit_page=SIT_DOWN_PAGE,
    )

    # === Page 115: wk_lean_pitch (gentle fore/aft lean, ankle+hip) =====
    # Tests pitch-axis IMU feedback. 2° forward, 2° back, total ~ankle range.
    lean_fwd = modify({
        11: deg(-2.0),   # R_HIP_PITCH forward
        12: deg(+2.0),   # L_HIP_PITCH forward
        15: deg(+2.0),   # R_ANKLE_PITCH compensate
        16: deg(-2.0),   # L_ANKLE_PITCH compensate
    })
    lean_back = modify({
        11: deg(+2.0),
        12: deg(-2.0),
        15: deg(-2.0),
        16: deg(+2.0),
    })
    p115 = make_page(
        "wk_lean_pitch",
        [
            {"positions": base(),       "pause": 0, "time": 125},
            {"positions": lean_fwd,     "pause": 0, "time": 125},
            {"positions": base(),       "pause": 0, "time": 125},
            {"positions": lean_back,    "pause": 0, "time": 125},
            {"positions": base(),       "pause": 0, "time": 125},
        ],
        next_page=0,
        exit_page=SIT_DOWN_PAGE,
    )

    # Build output: stock copy + replace pages 110..115
    out = bytearray(stock)
    for idx, page in [(110, p110), (111, p111), (112, p112), (113, p113), (114, p114), (115, p115)]:
        out[idx * PAGE_SIZE : (idx + 1) * PAGE_SIZE] = page

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(bytes(out))
    print(f"Wrote {args.out}  ({len(out)} byte = {len(out)//PAGE_SIZE} pages)")

    # Verify all 256 page checksums
    bad = []
    for i in range(NUM_PAGES):
        p = out[i * PAGE_SIZE : (i + 1) * PAGE_SIZE]
        if (sum(p) & 0xFF) != 0xFF:
            # The framework only verifies pages that get loaded — empty pages may
            # be 0x00 throughout (sum=0, !=0xFF). Stock catalog tolerates this.
            # But our 6 new pages MUST verify.
            bad.append(i)
    new_bad = [i for i in bad if i in {110, 111, 112, 113, 114, 115}]
    if new_bad:
        print(f"!!! authored pages with bad checksum: {new_bad}", file=sys.stderr)
        sys.exit(1)
    print(f"Authored pages 110..115 checksums verified.")
    print(f"Stock pages with default zero-fill checksum (informational): {len(bad)}")


if __name__ == "__main__":
    main()
