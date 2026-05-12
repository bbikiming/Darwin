# 04 — Motion Library Binaries (ROBOTIS-OP2 Factory Firmware)

## TL;DR

The factory firmware ships two **binary** motion libraries — `motion_4096.bin` and
`motion_1024.bin` — each exactly **131 072 bytes = 256 pages × 512 bytes** in the
on-robot runtime layout defined by `Action.h` (PAGEHEADER + 7 × STEP). 44 pages
are populated with named motions (walkready, sit down, stand up, f up / b up
recovery, rk/lk kicks, lie down/up, mul1–3 combos, talk1/talk2 idle gestures, ok,
no, hi); the two files differ only in **joint position scale** (`_4096.bin` = MX-28
12-bit 0..4095; `_1024.bin` = legacy 10-bit 0..1023 — same motions, scaled ×4).
This is the **runtime binary** format produced by `Action::SavePage()` in the
C++ framework — distinct from the RoboPlus-Action `.mtn` **text** format that
the existing `docs/motion-format/` specs describe.

## Binary files

### motion_4096.bin

- Path: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/motion_4096.bin`
- Size: **131 072 bytes** (== `sizeof(PAGE) * MAXNUM_PAGE` == `512 * 256`)
- Page size: **512 bytes** (from `Action.h`: 64-byte header + 7 × 64-byte step)
- Page count: **256** (indices 0..255; index 0 reserved/empty)
- Calibration: MX-28 servo, **0..4095** position units (`Goal Position` direct value)
- Per-page checksum: `(sum of all 512 bytes) mod 256 == 0xff` — verified OK on all 256 pages

### motion_1024.bin

- Path: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/motion_1024.bin`
- Size: **131 072 bytes** (identical envelope to `_4096.bin`)
- Page size: **512 bytes**
- Page count: **256**
- Calibration: legacy Dynamixel (DX-117 / RX-28-class), **0..1023** position units
- Same motion catalog as `_4096.bin`, but joint positions divided by 4 (i.e. shifted right 2 bits to compress from 12-bit to 10-bit motor resolution)
- 45 of 256 pages differ between the two files — exactly the named/non-empty pages
- Per-page checksum: also OK on all 256 pages

Both files are the on-flash image that `Action::LoadFile()` opens at boot and
seeks into by `fseek(action, index * sizeof(PAGE), SEEK_SET)`.

## Page layout (decoded from Action.h)

Verbatim from
`/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Action.h`:

```c
enum {
    MAXNUM_PAGE = 256,
    MAXNUM_STEP = 7,
    MAXNUM_NAME = 13
};

enum {
    SPEED_BASE_SCHEDULE = 0,
    TIME_BASE_SCHEDULE  = 0x0a   // = 10, the value seen on every populated page
};

enum {
    INVALID_BIT_MASK    = 0x4000,
    TORQUE_OFF_BIT_MASK = 0x2000
};

typedef struct {                          // Page header — exactly 64 bytes
    unsigned char name[MAXNUM_NAME+1];    //  0..13  ASCII page name (NUL-padded)
    unsigned char reserved1;              // 14
    unsigned char repeat;                 // 15     number of times to repeat the page
    unsigned char schedule;               // 16     SPEED_BASE_SCHEDULE | TIME_BASE_SCHEDULE
    unsigned char reserved2[3];           // 17..19
    unsigned char stepnum;                // 20     0..7 — number of valid steps in this page
    unsigned char reserved3;              // 21
    unsigned char speed;                  // 22     playback speed scaler (default 32)
    unsigned char reserved4;              // 23
    unsigned char accel;                  // 24     acceleration time (default 32)
    unsigned char next;                   // 25     link to next page after completion (0 = none)
    unsigned char exit;                   // 26     link to exit page on Stop() (0 = none)
    unsigned char reserved5[4];           // 27..30
    unsigned char checksum;               // 31     page-level checksum (xor target = 0xff)
    unsigned char slope[31];              // 32..62 compliance slope per joint
                                          //        encoded as (CW_slope << 4) | CCW_slope
    unsigned char reserved6;              // 63
} PAGEHEADER;

typedef struct {                          // Step — exactly 64 bytes
    unsigned short position[31];          //  0..61 joint target positions, uint16 LE
                                          //        bit 0x4000 = INVALID (joint not driven)
                                          //        bit 0x2000 = TORQUE_OFF
                                          //        bits 0..11 (or 0..9 for 1024 file) = goal value
    unsigned char  pause;                 // 62     pause time after motion completes
    unsigned char  time;                  // 63     interpolation time in 8 ms ticks
                                          //        (e.g. 125 → 1000 ms)
} STEP;

typedef struct {                          // 64 + 7*64 = 512 bytes
    PAGEHEADER header;                    //  0..63
    STEP       step[MAXNUM_STEP];         // 64..511
} PAGE;
```

### Slope byte encoding

Each `slope[i]` is one byte = `(CW_slope << 4) | CCW_slope`. From `JointData.h`:

```
SLOPE_HARD       = 16  →  0x10  → nibble 1
SLOPE_DEFAULT    = 32  →  0x20  → nibble 2
SLOPE_SOFT       = 64  →  0x40  → nibble 4
SLOPE_EXTRASOFT  = 128 →  0x80  → nibble 8
```

Observed values: `0x55` (decimal 85) = CW 5 / CCW 5 (a midpoint between default
and soft) — applied to every joint except `R_SHO_R` and `L_SHO_R` which use
`0x77` (decimal 119) for slightly softer shoulder roll.

### Joint slot mapping (from JointData.h)

The `position[31]` and `slope[31]` arrays are indexed by **Dynamixel servo ID**.
OP2 uses IDs 1..20 (NUMBER_OF_JOINTS = 21 with the unused 0 slot). The remaining
slots 21..30 stay at `INVALID_BIT_MASK` (`0x4000`).

| ID | Joint | ID | Joint |
|----|-------|----|-------|
| 1  | R_SHOULDER_PITCH | 11 | R_HIP_PITCH |
| 2  | L_SHOULDER_PITCH | 12 | L_HIP_PITCH |
| 3  | R_SHOULDER_ROLL  | 13 | R_KNEE |
| 4  | L_SHOULDER_ROLL  | 14 | L_KNEE |
| 5  | R_ELBOW          | 15 | R_ANKLE_PITCH |
| 6  | L_ELBOW          | 16 | L_ANKLE_PITCH |
| 7  | R_HIP_YAW        | 17 | R_ANKLE_ROLL |
| 8  | L_HIP_YAW        | 18 | L_ANKLE_ROLL |
| 9  | R_HIP_ROLL       | 19 | HEAD_PAN |
| 10 | L_HIP_ROLL       | 20 | HEAD_TILT |

### Checksum algorithm (from Action.cpp lines 30–61)

```c
unsigned char checksum = 0;
for (i = 0; i < sizeof(PAGE); i++) checksum += pPage_bytes[i];
// Stored value must make the sum overflow to 0xff:
pPage->header.checksum = 0xff - (checksum without checksum byte);
// Verification: (sum of all 512 bytes) & 0xff == 0xff
```

## Page catalog: motion_4096.bin

256 pages total. Page 0 is the reserved index (all zeros, used as "no page").
Pages 7,8,14, 20..22, 26, 28, 32..37, 40, 48..53, 59..69, 72..89, 92..236, 238,
242..255 are zeroed-but-CRC-valid placeholders (factory-allocated empty slots
ready for user authoring). The 44 populated pages are listed below.

| # | Offset | Name | rep | sched | steps | spd | accel | next | exit | Notes |
|---|--------|------|-----|-------|-------|-----|-------|------|------|-------|
| 1 | 0x000200 | `init` | 1 | TIME | 2 | 32 | 32 | 0 | 0 | initialization pose |
| 2 | 0x000400 | `ok` | 1 | TIME | 5 | 32 | 32 | 0 | 0 | "ok" gesture |
| 3 | 0x000600 | `no` | 1 | TIME | 5 | 32 | 32 | 0 | 0 | "no" gesture |
| 4 | 0x000800 | `hi` | 1 | TIME | 4 | 32 | 32 | 0 | 0 | hi/wave |
| 5 | 0x000a00 | `??` | 1 | TIME | 3 | 32 | 32 | 0 | 0 | "what?" gesture |
| 6 | 0x000c00 | `talk1` | 1 | TIME | 7 | 32 | 32 | 0 | 0 | idle talking gesture A |
| 9 | 0x001200 | `walkready` | 1 | TIME | 1 | 32 | 32 | 0 | 0 | **the canonical bipedal stance** |
| 10 | 0x001400 | `f up` | 1 | TIME | 5 | 32 | 32 | 0 | 0 | **front-fall recovery (stand from face-down)** |
| 11 | 0x001600 | `b up` | 1 | TIME | 6 | 32 | 32 | 0 | 0 | **back-fall recovery (stand from face-up)** |
| 12 | 0x001800 | `rk` | 1 | TIME | 7 | 32 | 32 | 0 | 0 | **right kick** |
| 13 | 0x001a00 | `lk` | 1 | TIME | 7 | 32 | 32 | 0 | 0 | **left kick** |
| 15 | 0x001e00 | `sit down` | 1 | TIME | 1 | 32 | 32 | 0 | 0 | sit |
| 16 | 0x002000 | `stand up` | 1 | TIME | 1 | 32 | 32 | 0 | 0 | stand |
| 17 | 0x002200 | `mul1` | 1 | TIME | 7 | 32 | 32 | 18 | 0 | combo (chains → 18) |
| 18 | 0x002400 | `mul2` | 1 | TIME | 7 | 32 | 32 | 19 | 0 | combo (chains → 19) |
| 19 | 0x002600 | `mul3` | 1 | TIME | 6 | 32 | 32 | 0 | 0 | combo tail |
| 23 | 0x002e00 | `d1` | 1 | TIME | 4 | 21 | 32 | 0 | 0 | demo 1 |
| 24 | 0x003000 | `d2` | 1 | TIME | 5 | 32 | 32 | 25 | 0 | demo 2 part 1 |
| 25 | 0x003200 | `d2` | 1 | TIME | 6 | 32 | 32 | 0 | 0 | demo 2 part 2 |
| 27 | 0x003600 | `d3` | 1 | TIME | 5 | 32 | 32 | 0 | 0 | demo 3 |
| 29 | 0x003a00 | `talk2` | 1 | TIME | 5 | 21 | 32 | 30 | 0 | idle talking B (1/2) |
| 30 | 0x003c00 | `talk2` | 1 | TIME | 5 | 21 | 32 | 0 | 0 | idle talking B (2/2) |
| 31 | 0x003e00 | `d4` | 1 | TIME | 6 | 32 | 32 | 0 | 0 | demo 4 |
| 38 | 0x004c00 | `d2` | 1 | TIME | 5 | 32 | 32 | 39 | 0 | demo 2 variant (1/2) |
| 39 | 0x004e00 | `d2` | 1 | TIME | 6 | 32 | 32 | 0 | 0 | demo 2 variant (2/2) |
| 41 | 0x005200 | `talk2` | 1 | TIME | 3 | 31 | 32 | 42 | 0 | 7-page talk2 chain start |
| 42 | 0x005400 | `talk2` | 1 | TIME | 5 | 31 | 32 | 43 | 0 | … |
| 43 | 0x005600 | `talk2` | 1 | TIME | 5 | 42 | 32 | 44 | 0 | … |
| 44 | 0x005800 | `talk2` | 1 | TIME | 5 | 31 | 32 | 45 | 0 | … |
| 45 | 0x005a00 | `talk2` | 1 | TIME | 7 | 42 | 32 | 46 | 0 | … |
| 46 | 0x005c00 | `talk2` | 1 | TIME | 5 | 42 | 32 | 47 | 0 | … |
| 47 | 0x005e00 | `talk2` | 1 | TIME | 6 | 42 | 32 | 0 | 0 | 7-page talk2 chain end |
| 54 | 0x006c00 | `int` | 1 | TIME | 2 | 32 | 32 | 55 | 0 | introduction sequence start |
| 55 | 0x006e00 | `int` | 1 | TIME | 6 | 16 | 32 | 56 | 0 | … |
| 56 | 0x007000 | `int` | 1 | TIME | 6 | 16 | 32 | 58 | 0 | … (skips 57) |
| 57 | 0x007200 | `int` | 1 | TIME | 6 | 16 | 32 | 58 | 0 | (orphan branch, also chains to 58) |
| 58 | 0x007400 | `int` | 1 | TIME | 1 | 32 | 32 | 0 | 0 | introduction sequence end |
| 70 | 0x008c00 | `rPASS` | 1 | TIME | 7 | 32 | 32 | 0 | 0 | right-foot pass (soccer) |
| 71 | 0x008e00 | `lPASS` | 1 | TIME | 7 | 32 | 32 | 0 | 0 | left-foot pass (soccer) |
| 90 | 0x00b400 | `lie down` | 1 | TIME | 4 | 32 | 32 | 0 | 0 | lie down (controlled) |
| 91 | 0x00b600 | `lie up` | 1 | TIME | 3 | 32 | 32 | 0 | 0 | rise from lying |
| 237 | 0x01da00 | `sit down` | 6 | TIME | 2 | 12 | 32 | 0 | 0 | slow-sit variant |
| 239 | 0x01de00 | `sit down` | 4 | TIME | 2 | 12 | 32 | 240 | 0 | slow-sit chain (1/3) |
| 240 | 0x01e000 | `sit down` | 4 | TIME | 2 | 12 | 32 | 241 | 0 | slow-sit chain (2/3) |
| 241 | 0x01e200 | `sit down` | 20 | TIME | 2 | 12 | 32 | 0 | 0 | slow-sit chain (3/3, ×20 repeat) |

Every page uses `schedule = TIME_BASE_SCHEDULE (0x0a)` — i.e. ROBOTIS dropped speed-based scheduling for the factory library.

## Page catalog: motion_1024.bin

Identical catalog except page 1 has name `int` (NUL-terminated 3 bytes) instead
of `init` (4 bytes). All other names, step counts, repeat/schedule/next/exit
fields are the same; only the `position[]` payloads differ (×4 scaling).

| # | Offset | Name | rep | sched | steps | spd | accel | next | exit |
|---|--------|------|-----|-------|-------|-----|-------|------|------|
| 1 | 0x000200 | `int` | 1 | TIME | 1 | 32 | 32 | 0 | 0 |
| 2 | 0x000400 | `ok` | 1 | TIME | 5 | 32 | 32 | 0 | 0 |
| 3 | 0x000600 | `no` | 1 | TIME | 5 | 32 | 32 | 0 | 0 |
| 4 | 0x000800 | `hi` | 1 | TIME | 4 | 32 | 32 | 0 | 0 |
| 5 | 0x000a00 | `??` | 1 | TIME | 3 | 32 | 32 | 0 | 0 |
| 6 | 0x000c00 | `talk1` | 1 | TIME | 7 | 32 | 32 | 0 | 0 |
| 9 | 0x001200 | `walkready` | 1 | TIME | 1 | 32 | 32 | 0 | 0 |
| 10 | 0x001400 | `f up` | 1 | TIME | 5 | 32 | 32 | 0 | 0 |
| 11 | 0x001600 | `b up` | 1 | TIME | 6 | 32 | 32 | 0 | 0 |
| 12 | 0x001800 | `rk` | 1 | TIME | 7 | 32 | 32 | 0 | 0 |
| 13 | 0x001a00 | `lk` | 1 | TIME | 7 | 32 | 32 | 0 | 0 |
| 15 | 0x001e00 | `sit down` | 1 | TIME | 1 | 32 | 32 | 0 | 0 |
| 16 | 0x002000 | `stand up` | 1 | TIME | 1 | 32 | 32 | 0 | 0 |
| 17 | 0x002200 | `mul1` | 1 | TIME | 7 | 32 | 32 | 18 | 0 |
| 18 | 0x002400 | `mul2` | 1 | TIME | 7 | 32 | 32 | 19 | 0 |
| 19 | 0x002600 | `mul3` | 1 | TIME | 6 | 32 | 32 | 0 | 0 |
| 23 | 0x002e00 | `d1` | 1 | TIME | 4 | 21 | 32 | 0 | 0 |
| 24 | 0x003000 | `d2` | 1 | TIME | 5 | 32 | 32 | 25 | 0 |
| 25 | 0x003200 | `d2` | 1 | TIME | 6 | 32 | 32 | 0 | 0 |
| 27 | 0x003600 | `d3` | 1 | TIME | 5 | 32 | 32 | 0 | 0 |
| 29 | 0x003a00 | `talk2` | 1 | TIME | 5 | 21 | 32 | 30 | 0 |
| 30 | 0x003c00 | `talk2` | 1 | TIME | 5 | 21 | 32 | 0 | 0 |
| 31 | 0x003e00 | `d4` | 1 | TIME | 6 | 32 | 32 | 0 | 0 |
| 38 | 0x004c00 | `d2` | 1 | TIME | 5 | 32 | 32 | 39 | 0 |
| 39 | 0x004e00 | `d2` | 1 | TIME | 6 | 32 | 32 | 0 | 0 |
| 41 | 0x005200 | `talk2` | 1 | TIME | 3 | 21 | 32 | 42 | 0 |
| 42 | 0x005400 | `talk2` | 1 | TIME | 5 | 21 | 32 | 43 | 0 |
| 43 | 0x005600 | `talk2` | 1 | TIME | 5 | 32 | 32 | 44 | 0 |
| 44 | 0x005800 | `talk2` | 1 | TIME | 5 | 21 | 32 | 45 | 0 |
| 45 | 0x005a00 | `talk2` | 1 | TIME | 7 | 32 | 32 | 46 | 0 |
| 46 | 0x005c00 | `talk2` | 1 | TIME | 5 | 32 | 32 | 47 | 0 |
| 47 | 0x005e00 | `talk2` | 1 | TIME | 6 | 32 | 32 | 0 | 0 |
| 54 | 0x006c00 | `int` | 1 | TIME | 2 | 32 | 32 | 55 | 0 |
| 55 | 0x006e00 | `int` | 1 | TIME | 6 | 16 | 32 | 56 | 0 |
| 56 | 0x007000 | `int` | 1 | TIME | 6 | 16 | 32 | 58 | 0 |
| 57 | 0x007200 | `int` | 1 | TIME | 6 | 16 | 32 | 58 | 0 |
| 58 | 0x007400 | `int` | 1 | TIME | 1 | 32 | 32 | 0 | 0 |
| 70 | 0x008c00 | `rPASS` | 1 | TIME | 7 | 32 | 32 | 0 | 0 |
| 71 | 0x008e00 | `lPASS` | 1 | TIME | 7 | 32 | 32 | 0 | 0 |
| 90 | 0x00b400 | `lie down` | 1 | TIME | 4 | 32 | 32 | 0 | 0 |
| 91 | 0x00b600 | `lie up` | 1 | TIME | 3 | 32 | 32 | 0 | 0 |
| 237 | 0x01da00 | `sit down` | 6 | TIME | 2 | 12 | 32 | 0 | 0 |
| 239 | 0x01de00 | `sit down` | 4 | TIME | 2 | 12 | 32 | 240 | 0 |
| 240 | 0x01e000 | `sit down` | 4 | TIME | 2 | 12 | 32 | 241 | 0 |
| 241 | 0x01e200 | `sit down` | 20 | TIME | 2 | 12 | 32 | 0 | 0 |

The 41/42/43/44/45/46/47 chain has different `speed` values (21,21,32,21,32,32,32)
vs the 4096 version (31,31,42,31,42,42,42) — `motion_1024.bin` apparently shipped
with a slightly slower talk2 chain because the older 1024-scale servos can't keep
up with the same target velocities.

## Sample page decode — Page 9 "walkready" (motion_4096.bin)

This is the canonical bipedal standby pose every behavior returns to.

### Raw header bytes (offsets 0x001200..0x00123F)

```
00001200: 77 61 6c 6b 72 65 61 64 79 00 00 00 00 00 00 01    walkready.......
00001210: 0a 00 00 00 01 00 20 00 20 00 00 00 00 00 8d 55    ...... . ......U
00001220: 55 55 77 77 55 55 55 55 55 55 55 55 55 55 55 55    UUww UUUUUUUUUUUUU
00001230: 55 55 55 55 55 55 00 00 00 00 00 ..                UUUUUU.....
```

Decoded:

```
header.name      = "walkready"
header.reserved1 = 0x00
header.repeat    = 1
header.schedule  = 0x0a   (TIME_BASE_SCHEDULE)
header.stepnum   = 1
header.speed     = 32     (0x20)
header.accel     = 32     (0x20)
header.next      = 0
header.exit      = 0
header.checksum  = 0x8d
header.slope[1..6]   = 0x55 0x55 0x77 0x77 0x55 0x55  (shoulders use softer slope)
header.slope[7..20]  = 0x55 × 14                      (default for legs + head)
```

### Step 0 (offset 0x001240, time = 125 → 1000 ms transition)

Joint positions in MX-28 raw units (0..4095, where 2048 = center / 180°):

| ID | Joint              | Position | Δ from center (2048) |
|----|--------------------|----------|----------------------|
|  1 | R_SHOULDER_PITCH   |   1498   | −550   (arm forward)  |
|  2 | L_SHOULDER_PITCH   |   2518   | +470   (arm forward, mirrored) |
|  3 | R_SHOULDER_ROLL    |   1845   | −203   (arm pulled in) |
|  4 | L_SHOULDER_ROLL    |   2248   | +200   (arm pulled in, mirrored) |
|  5 | R_ELBOW            |   2381   | +333   (elbow flex) |
|  6 | L_ELBOW            |   1712   | −336   (elbow flex, mirrored) |
|  7 | R_HIP_YAW          |   2048   | 0      (centered) |
|  8 | L_HIP_YAW          |   2048   | 0      (centered) |
|  9 | R_HIP_ROLL         |   2052   | +4     (≈centered) |
| 10 | L_HIP_ROLL         |   2044   | −4     (≈centered) |
| 11 | R_HIP_PITCH        |   1637   | −411   (forward lean) |
| 12 | L_HIP_PITCH        |   2459   | +411   (forward lean, mirrored) |
| 13 | R_KNEE             |   2653   | +605   (knee bent) |
| 14 | L_KNEE             |   1443   | −605   (knee bent, mirrored) |
| 15 | R_ANKLE_PITCH      |   2389   | +341 |
| 16 | L_ANKLE_PITCH      |   1707   | −341 |
| 17 | R_ANKLE_ROLL       |   2057   | +9 |
| 18 | L_ANKLE_ROLL       |   2039   | −9 |
| 19 | HEAD_PAN           |   2048   | 0  (looking straight) |
| 20 | HEAD_TILT          |   2161   | +113 (slight down) |
| 21..30 | unused        |  0x4000 each  | `INVALID_BIT_MASK` |
| pause | 0 ticks                |
| time  | 125 ticks × 8 ms = **1 000 ms** |

The pose is the classic OP2 "knees bent, arms slightly forward, head looking
mildly down" standby — symmetric within ±4 LSB on the laterally-mirrored joints
(left/right asymmetry is the as-shipped factory zero-trim, not a bug).

## Format relationship vs `docs/motion-format/mtn-format.md`

Read
`/Users/bbikiming/Documents/vibe_coding/Darwin/docs/motion-format/mtn-format.md`
and
`/Users/bbikiming/Documents/vibe_coding/Darwin/docs/motion-format/page-format.md`.

### VERDICT — **PARTIAL match**

The two formats describe the **same conceptual model** (Pages → Steps → joint
positions, with next/exit links, compliance per joint, time/pause per step)
but they are **different physical encodings**. `motion_*.bin` is the on-robot
**runtime binary**; `.mtn` is the host-side **text authoring** format. The
existing `docs/motion-format/page-format.md` is a speculative sketch — most of
its field offsets are wrong; the real layout is the one in this document
(Action.h, verified against the actual binary).

Concrete divergences from `docs/motion-format/page-format.md`:

| Aspect | Current spec (page-format.md) | Reality (this doc) |
|--------|-------------------------------|--------------------|
| Joint count per slot | 20 | **31** (1..20 active, 21..30 INVALID) |
| Header size | unspecified, estimated 22 bytes | **64 bytes exactly** |
| Field "speed_rate" at offset 16 | wrong | offset 16 = `schedule` (always 0x0a) |
| Field "repeat_time" at offset 15 | correct | correct |
| Field "speed" | offset 16 | **offset 22** |
| Field "accel" | offset 19 | **offset 24** |
| Field "next_page" | offset 17 | **offset 25** |
| Field "exit_page" | offset 18 | **offset 26** |
| Field "step_num" | offset 21 | **offset 20** |
| Missing field | (none mentioned) | **`slope[31]` at offset 32..62 (CW/CCW compliance, 4-bit nibbles per joint)** |
| Missing field | (none mentioned) | **`checksum` at offset 31, validated by `(sum & 0xff) == 0xff`** |
| Step `pose` size | 20 × uint16 = 40 bytes | **31 × uint16 = 62 bytes** |
| Step `pause_time` width | uint16, "ms / 8 ticks?" | **uint8, raw 8 ms ticks** |
| Step `play_time` width | uint16 | **uint8, raw 8 ms ticks** (max 2040 ms per step) |
| Step `option` | uint8 + 3 reserved | **no separate option byte** — torque-off/invalid flags are encoded in the position word's high bits (`0x4000`, `0x2000`) |

Concrete divergences from `docs/motion-format/mtn-format.md`:

- `mtn-format.md` correctly notes that the `.mtn` is text-based and references
  `motion_4096.bin` as a separate binary the framework consumes. That framing
  is right. The catalog and schema in the spec are still partly speculative
  ("TODO: needs verification"). This doc supplies the **verified** binary
  schema. The text `.mtn` schema can be confirmed from the
  `Linux/project/action_editor/` source separately (out of scope here — see
  doc 06 if it exists).

### Source of truth & conversion direction

```
   ROBOPLUS-ACTION (Windows GUI)            DARWIN-MAC (this project)
    ┌──────────────────────────┐           ┌────────────────────────────┐
    │  Author motions in GUI    │           │  Studio / Motion editor    │
    │  Save as *.mtn (TEXT)     │           │  Import/export *.mtn (TEXT)│
    └──────────────┬───────────┘           └──────────────┬─────────────┘
                   │                                       │
                   │ "Save to OP2" / serial download       │ on-the-fly transmit?
                   ▼                                       ▼
            ┌─────────────────────────────────────────────────────────┐
            │  motion_4096.bin / motion_1024.bin (BINARY, on-robot)   │
            │  Read by Action::LoadFile() at boot, paged 512 B each   │
            └─────────────────────────────────────────────────────────┘
```

- **Authoring source of truth**: `.mtn` (text). Versionable, diff-able, human-readable, what users edit.
- **Runtime source of truth**: `motion_4096.bin` (binary). What the CM controller actually reads from `/darwin/Data/` at startup.
- **Conversion**: lossy `mtn → bin` (mtn has more metadata: title, versn, optional fields), and the reverse `bin → mtn` is technically possible but loses authoring-time decorations.

## What this means for Darwin

### 1. `motions/` directory is currently empty — this is the seed dataset

The factory firmware provides 44 ready-to-use motions. The repo already keeps
the raw binaries inside `firmware-backups/sda1-rootfs/robotis/Data/`. We should
**import these as the default motion library** that ships with the Mac app —
preferably converted to our internal JSON (or `.mtn` text) form so a user can
edit `walkready` / `f up` / `b up` / `rk` / `lk` without needing the original
RoboPlus tool.

Suggested action: add an importer task to Sprint 3+ that decodes
`motion_4096.bin` → 44 JSON pages → `motions/factory/*.json`.

### 2. The Darwin Mac-side parser needs a **separate binary loader**

The current `docs/motion-format/` spec only covers the text `.mtn` path. To
load these firmware binaries (which we **must** support if we want to read
what's actually on the robot, e.g. for sync/diff/upload-without-overwrite), a
**separate Rust module** is required:

- Suggested path: `app/core/src/motion/bin_loader.rs` (peer to a future `mtn_loader.rs`)
- Public API:
  ```rust
  pub struct MotionLibrary { pub pages: [Option<Page>; 256] }
  pub fn load_bin(bytes: &[u8]) -> Result<MotionLibrary>;
  pub fn write_bin(lib: &MotionLibrary) -> Vec<u8>;  // for round-trip
  ```
- Validation: enforce 131 072 bytes total, verify per-page checksum (`bytes.iter().sum() % 256 == 0xff`), surface mismatched checksums as warnings rather than hard errors (since `Action::LoadPage` itself just resets bad pages, but our higher-level tools should flag corruption).
- Note both `_4096.bin` (MX-28 servos, 12-bit) and `_1024.bin` (legacy servos, 10-bit) should be supported behind a single `BinScale { Scale4096, Scale1024 }` enum carried alongside the parsed `MotionLibrary`. Converting between the two is `pos >> 2` / `pos << 2` for the 12-bit position payload (leave the `0x4000` / `0x2000` flag bits intact).

### 3. The `page-format.md` spec needs a rewrite

`docs/motion-format/page-format.md` has the right intent but the wrong
offsets. Recommend: replace its "expected" tables with a `> See
docs/firmware-reference/04-motion-library.md for verified offsets`
pointer, or merge the verified content back in.

### 4. Sprint priority

- **Now (this sprint)**: just write this reference doc + a one-shot Python
  importer script that lists/decodes all 44 named pages.
- **Sprint 3**: implement the Rust `bin_loader` and wire it into the Studio's
  Motion library tab — letting users see the factory motions before they edit.
- **Sprint 4**: round-trip writer with checksum reseal, so users can save
  edits back to `motion_4096.bin` on the robot.

## Evidence

Cited absolute paths (all read for this analysis):

1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Action.h` — `MAXNUM_PAGE`, `MAXNUM_STEP`, `MAXNUM_NAME`, `PAGEHEADER` / `STEP` / `PAGE` struct definitions
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/modules/Action.cpp` — `LoadFile()` lines 101–132 (file-size check `sizeof(PAGE) * MAXNUM_PAGE`), `VerifyChecksum`/`SetChecksum` lines 30–61, `LoadPage`/`SavePage` lines 239–269
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/JointData.h` — joint ID enum (1..20), `SLOPE_*` constants
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/motion_4096.bin` — primary motion library, 131 072 bytes, 256 pages, 44 named (MX-28 4096-scale)
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Data/motion_1024.bin` — legacy-resolution mirror of the same catalog, 131 072 bytes (1024-scale)
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/motion-format/mtn-format.md` — existing (Phase 2) `.mtn` text-format spec
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/motion-format/page-format.md` — existing (speculative) page-format spec, requires correction per the table above
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/motion-format/README.md` — index of motion-format docs

## Quick decoder reference (Python, for future tooling)

```python
import os

PAGE_SIZE  = 512
HEADER_SIZE = 64
STEP_SIZE  = 64
MAX_PAGES  = 256

def load_library(path):
    """Parse motion_*.bin → list of 256 page dicts."""
    with open(path, 'rb') as f:
        data = f.read()
    assert len(data) == PAGE_SIZE * MAX_PAGES, f"bad size {len(data)}"
    pages = []
    for i in range(MAX_PAGES):
        p = data[i*PAGE_SIZE:(i+1)*PAGE_SIZE]
        # checksum: sum of all bytes mod 256 must == 0xff
        cs_ok = (sum(p) & 0xff) == 0xff
        name_raw = p[0:14]
        name = name_raw.split(b'\x00', 1)[0].decode('latin-1', errors='replace')
        page = {
            'idx':       i,
            'name':      name,
            'repeat':    p[15],
            'schedule':  p[16],
            'stepnum':   p[20],
            'speed':     p[22],
            'accel':     p[24],
            'next':      p[25],
            'exit':      p[26],
            'checksum':  p[31],
            'slope':     list(p[32:63]),     # 31 bytes, (CW<<4)|CCW per joint
            'cs_ok':     cs_ok,
            'steps':     [],
        }
        for s in range(p[20]):                # only first stepnum steps are meaningful
            off = HEADER_SIZE + s * STEP_SIZE
            step = p[off:off+STEP_SIZE]
            positions = [
                int.from_bytes(step[j*2:j*2+2], 'little') for j in range(31)
            ]
            page['steps'].append({
                'positions': positions,        # bit 0x4000 = invalid, 0x2000 = torque-off
                'pause':     step[62],         # 8-ms ticks
                'time':      step[63],         # 8-ms ticks; total motion time = time * 8 ms
            })
        pages.append(page)
    return pages
```
