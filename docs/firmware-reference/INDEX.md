# Firmware Reference — ROBOTIS-OP2 Factory Image (2015-03-26)

## What this is

The Darwin project includes an official ROBOTIS-OP2 factory recovery image (Clonezilla disk image, 2015-03-26 09:03 UTC). This `firmware-reference/` directory documents the operational state of that factory firmware as **ground truth** that complements the source-only view in `research/robotis-official/`. Where the vendored sources tell us "what the code does", these docs tell us "what the factory ran, with what values".

The actual image lives under `firmware-backups/` (gitignored), restored selectively at 387 MB across 13,868 files. The compressed Clonezilla blob preserves the exact 25 GiB ext4 filesystem; see `firmware-backups/MANIFEST.md` for provenance.

## Source attribution & licensing

- **Source image**: ROBOTIS-OP2 Recovery 2015-03-26 — official proprietary recovery
- **Framework source within image**: GPL (ROBOTIS-OP2 darwinop SF.net SVN trunk @ rev 90, dated 2015-03-25)
- **Linux kernel**: GPL2 (Ubuntu 12.04 Precise + ROBOTIS custom build `3.2.66-op2` with `SMP PREEMPT`)
- **This documentation**: derived facts only, free to consume internally; do NOT redistribute the image or extracted filesystem publicly
- Each child doc cites paths into `firmware-backups/sda1-rootfs/` for traceability

## Doc table

| # | Doc | Scope | Key finding |
|---|---|---|---|
| 01 | [01-system-os.md](01-system-os.md) | OS, kernel, packages | Ubuntu 12.04.5 LTS i386 with custom kernel `3.2.66-op2 SMP PREEMPT` (built 2015-02-13 KST). 1035 dpkg packages — **zero are ROBOTIS-packaged**; OpenCV, Dynamixel SDK, MJPG-Streamer are all source-built. Logitech UVC camera `046d:080a`, CM-740 via `ftdi_sio` → `/dev/ttyUSB0`. |
| 02 | [02-framework-source.md](02-framework-source.md) | Framework C++ source on robot | Full ROBOTIS-OP2 v1.7.0 SVN working copy at `/robotis/` (rev 90 of `svn://svn.code.sf.net/p/darwinop/code/trunk/robotisop2`). All `.cpp` → `.o`, `darwin.a` pre-archived, `demo` binary pre-compiled (32-bit ELF, 182 KB). 7 projects: `demo`, `walk_tuner`, `action_editor`, `offset_tuner`, `roboplus`, `firmware_installer`, `dxl_monitor`. |
| 03 | [03-walking-module.md](03-walking-module.md) | Walking engine | Closed-form sinusoidal ZMP gait + 6-DOF analytical leg IK. Single `wsin()` builds every trajectory; 4-phase (PHASE0–PHASE3) state machine. **MX-28 4096-res builds multiply all 4 balance gains by ×4** (Walking.cpp:587-598). Darwin `WalkParams::default()` matches C++ ctor 100% — but Darwin engine may be missing the ×4 scale. |
| 04 | [04-motion-library.md](04-motion-library.md) | motion_*.bin format | `motion_4096.bin` and `motion_1024.bin` = 131,072 bytes each = 256 pages × 512 bytes. 64-byte PAGEHEADER + 7 × 64-byte STEP. **44 named pages** out of 256. `docs/motion-format/page-format.md` has wrong field offsets and is missing `slope[31]` + `checksum` fields. |
| 05 | [05-vision-pipeline.md](05-vision-pipeline.md) | Vision/camera | V4L2 YUYV 320×240 @ 30 FPS → YUV→RGB→HSV → single-color hue/tol filter + erosion + dilation + centroid. Up to 4 `ColorFinder` instances running in parallel. **No goal/field/line detection** — only ball + 3 RGB color cards. MJPG streamer on TCP 8080. Factory orange-ball thresholds: hue=355, tol=15, min_sat=60. |
| 06 | [06-action-library.md](06-action-library.md) | Action playback + scripts | `Action::GetInstance()->Start(pageNum)` invokes pages. Only **14 of 256 pages are referenced by C++ source**. `script.asc` is `(page,mp3)` tuples played via `LinuxActionScript` (forks `madplay`). Boot pose = page 15 (sit). No `#define PAGE_X` constants — page numbers are inlined as magic numbers. |
| 07 | [07-servo-config.md](07-servo-config.md) | Dynamixel + CM-730 setup | 20 MX-28T servos (IDs 1–20) + 2 FSR (111, 112) + CM-740 (200) on `/dev/ttyUSB0` @ 1 Mbps. SYNC_WRITE at MX-28 addr 26 (7-byte D-I-P-rsv-goalL-goalH). BULK_READ scope is **CM-730 RAM + 2 FSR only — NOT per-joint position** (correcting `docs/protocols/dynamixel-1.0.md`). Factory FW: CM-740 = 0x14, MX-28 = 0x1E, FSR = 0x11. |
| 08 | [08-startup-services.md](08-startup-services.md) | Boot + init | Two-line `/etc/rc.local` = `sleep 10; /robotis/Linux/project/demo/demo`. No dedicated upstart job. LightDM autologs `robotis` user into Lubuntu/LXDE session in parallel. Robot acts as DHCP server on `192.168.123.0/24` (range .100–.200). SSH `respawn` on runlevels 2–5. |
| 09 | [09-network-comms.md](09-network-comms.md) | Network + SSH | Hostname `robotis`, static eth0 `192.168.123.1/24`, no gateway, no DNS. **No WiFi pre-configured** (no `wpa_supplicant.conf`). sshd port 22, `PermitRootLogin yes`, `PasswordAuthentication yes` (default). 3 host keys: RSA, DSA, ECDSA — fingerprints only documented (no private bytes copied). No firewall. |
| 10 | [10-game-controller.md](10-game-controller.md) | RoboCup GC | **ABSENT**. Zero hits for GameController/RGme/3838/team-number/SPL across all framework, projects, and `demo` binary strings. The shipped demo is a ball-following + color-card showcase, not a RoboCup competition agent. |
| 11 | [11-audio-speech.md](11-audio-speech.md) | Audio + speech | **No TTS engine** (no espeak/festival/flite). 25 pre-recorded MP3s under `robotis/Data/mp3/` played by **`madplay` invoked directly via `fork()`+`execl()`** — not via `mpg321`. ALSA defaults (no `/etc/asound.conf`). All "speech" is human-recorded English with Korean accent. |

## Critical findings (flag at top — these are what matter for porting)

### 🚨 1. Walking instability hypothesis — MX-28 4096-res ×4 balance gain

The factory walking module (`Framework/src/motion/modules/Walking.cpp:571-599`) wraps every IMU balance correction inside `#ifdef MX28_1024 … #else …`. **The 4096-resolution branch (active in factory) multiplies all 4 balance gains by ×4**:

```cpp
#else
// MX28 4096 res: 게인을 ×4 한다
outValue[1] += (int)(dir[1] * rlGyroErr * BALANCE_HIP_ROLL_GAIN*4);
/* ...동일 패턴, gain*4 ... */
#endif
```

See [03-walking-module.md §1.2](03-walking-module.md) for the verbatim quote and [§6.3 item 1](03-walking-module.md) for the porting flag.

**Why this matters for Darwin**: `app/core/forge-core/src/walk/params.rs` already mirrors the factory ctor defaults perfectly (balance_hip_roll_gain=0.5, balance_knee_gain=0.3, balance_ankle_pitch_gain=0.9, balance_ankle_roll_gain=1.0 — see [03-walking-module.md §4](03-walking-module.md) diff table). But Darwin targets the MX-28T 4096-resolution servos (12-bit), so the **effective gain must be ×4 these values**. If Darwin's `walk/engine.rs` applies the params verbatim without the ×4, IMU feedback runs at one-quarter the intended strength — a strong candidate for the "stuck in walk-ready" instability we've observed when the robot tips over instead of self-correcting.

### 🚨 2. Joint ID mapping error in current Darwin docs

`docs/architecture/joint-conventions.md:16-27` currently claims:

| ID range | Darwin doc says | Factory `JointData.h` says |
|---|---|---|
| 7–10 | "사용 안 함 (구버전 ID 흔적)" | **HIP_YAW R/L (7, 8) + HIP_ROLL R/L (9, 10)** |
| 11–12 | HIP_YAW R/L | HIP_PITCH R/L |
| 13–14 | HIP_ROLL R/L | KNEE R/L |
| 15–16 | HIP_PITCH R/L | **ANKLE_PITCH R/L** |
| 17–18 | KNEE R/L | **ANKLE_ROLL R/L** |
| 19–20 | HEAD_PAN / HEAD_TILT | HEAD_PAN / HEAD_TILT (✓) |

Both `04-motion-library.md` (motion library agent, citing `JointData.h`) and `07-servo-config.md` (servo-config agent, citing `JointData.h` verbatim) confirm the corrected table. The Darwin doc's "7–10 unused" comment is **factually wrong** for OP2 firmware — IDs 7–10 are hip-yaw + hip-roll, and **ankle joints (15–18) are entirely missing** from the current Darwin doc.

**Corrected mapping** (canonical, per `Framework/include/JointData.h`):

| ID | Symbol | ID | Symbol |
|----|--------|----|--------|
| 1 | R_SHOULDER_PITCH | 11 | R_HIP_PITCH |
| 2 | L_SHOULDER_PITCH | 12 | L_HIP_PITCH |
| 3 | R_SHOULDER_ROLL | 13 | R_KNEE |
| 4 | L_SHOULDER_ROLL | 14 | L_KNEE |
| 5 | R_ELBOW | 15 | R_ANKLE_PITCH |
| 6 | L_ELBOW | 16 | L_ANKLE_PITCH |
| 7 | R_HIP_YAW | 17 | R_ANKLE_ROLL |
| 8 | L_HIP_YAW | 18 | L_ANKLE_ROLL |
| 9 | R_HIP_ROLL | 19 | HEAD_PAN |
| 10 | L_HIP_ROLL | 20 | HEAD_TILT |

**Impact if not fixed**: any Rust port of Walking/Action/MotionManager that consumes the Darwin doc as ID mapping will send goal positions to **the wrong joints** — IDs 7–10 think they're "alt hip-yaw / unused" but are actually moving the hip yaw + roll on a live robot. Result: visible mis-mapping of arms and legs (e.g., the ankle commands go to nothing or to imaginary slots), and motion playback that looks nothing like the page authoring intent.

### 🚨 3. Motion format docs need rewrite

`docs/motion-format/page-format.md` documents a speculative "20 joints, ~22-byte header" layout with explicit "TODO: needs verification" caveats. The reality (verified in `Framework/include/Action.h` + decoded against `motion_4096.bin`):

| Aspect | Current spec (page-format.md) | Reality (per [04-motion-library.md](04-motion-library.md)) |
|---|---|---|
| Joint count per slot | 20 | **31** (1–20 active, 21–30 carry `INVALID_BIT_MASK`) |
| Header size | "estimated 22 bytes" | **64 bytes exactly** |
| Field `speed_rate` at offset 16 | wrong | offset 16 = `schedule` (always 0x0a for time-based) |
| Field `speed` | offset 16 | **offset 22** |
| Field `accel` | offset 19 | **offset 24** |
| Field `next_page` | offset 17 | **offset 25** |
| Field `exit_page` | offset 18 | **offset 26** |
| Field `step_num` | offset 21 | **offset 20** |
| Missing field | (not mentioned) | **`slope[31]` at offset 32–62 — CW/CCW compliance, 4-bit nibbles per joint** |
| Missing field | (not mentioned) | **`checksum` at offset 31, validated by `(sum of all 512 bytes) & 0xff == 0xff`** |
| Step `pose` size | 20 × uint16 = 40 bytes | **31 × uint16 = 62 bytes** |
| Step `pause_time` / `play_time` width | uint16 each | **uint8 each (raw 8 ms ticks)** |
| Step `option` byte | uint8 + 3 reserved | **no separate option byte** — invalid/torque-off encoded in position-word high bits (`0x4000` / `0x2000`) |

[04-motion-library.md](04-motion-library.md) has the full verified spec with a Python decoder. **Impact if not fixed**: any attempt to load on-robot `motion_4096.bin` via the current Darwin format docs will misread every field, since header sizes and step sizes are wrong by tens of bytes.

### 🚨 4. RoboCup Game Controller is absent (informational)

Per [10-game-controller.md](10-game-controller.md), no RoboCup GC client exists anywhere in the factory firmware — no UDP 3838 listener, no `RGme`/`RGrt` magic headers, no team-number config, no game-state machine. Not a bug, just a fact: if RoboCup support is ever added to Darwin, **no in-firmware reference exists**; the canonical spec is the upstream `RoboCup-Humanoid-TC/GameController` repo.

## Cross-doc themes

### Theme: "Most ROBOTIS code is source-built, not packaged"

[01-system-os.md](01-system-os.md) confirms no dpkg `dxl|dynamixel|robotis|opencv` packages exist (only `linux-image-3.2.66-op2`). [02-framework-source.md](02-framework-source.md) shows the live SVN working copy at `/robotis/` with all `.cpp` → `.o` artifacts present. [11-audio-speech.md](11-audio-speech.md) confirms even MP3 playback uses `madplay` invoked via direct `execl()` rather than any wrapper daemon, and there is no TTS engine packaged. **Implication for Darwin port**: don't expect `apt-get install` to resurrect anything; the on-robot stack is a single-tree GNU Make build sitting on top of a stock Ubuntu base.

### Theme: "Factory uses 4096-res MX-28 (12-bit), Darwin code paths must match"

[03-walking-module.md §5](03-walking-module.md) shows balance gain ×4 multiplier in the MX-28 4096 branch. [04-motion-library.md](04-motion-library.md) confirms `motion_4096.bin` (active) vs `motion_1024.bin` (legacy) differ only by `pos = pos << 2` scaling. [07-servo-config.md](07-servo-config.md) confirms `#define MX28_1024` is commented out at `MX28.h:11` and the firmware-installer ships MX-28 v0x1E (≥0x1B = 4096-res). All three docs converge: **Darwin must target 4096 throughout** (4-byte SYNC_WRITE payload size, CENTER_VALUE = 2048, RATIO_ANGLE2VALUE = 11.378, and ×4 balance gain).

### Theme: "Robot is a self-contained DHCP server, not a network client"

[08-startup-services.md](08-startup-services.md) shows `isc-dhcp-server.conf` is enabled on runlevel 2345 with `INTERFACES="eth0"` and a 192.168.123.100–.200 range. [09-network-comms.md](09-network-comms.md) confirms the matching static `eth0` config (no gateway, no DNS), no WiFi pre-config, no `/etc/wpa_supplicant.conf`. **Implication**: the operator plugs an Ethernet cable directly into the robot; the robot serves DHCP to the laptop. We must NOT plug the robot into a shared LAN without disabling its DHCP server — it would compete with the existing router.

### Theme: "Boot sequence is dirt simple — one line in /etc/rc.local"

[08-startup-services.md](08-startup-services.md) shows `/etc/rc.local` contains exactly `sleep 10; /robotis/Linux/project/demo/demo`. [06-action-library.md](06-action-library.md) traces what `demo` does on startup: plays `Demonstration ready mode.mp3` then page 15 (sit pose). [02-framework-source.md](02-framework-source.md) confirms `demo` is a pre-compiled 32-bit ELF at `/robotis/Linux/project/demo/demo` (182 KB, build ID `4a2b6d3…`). **Implication**: replicating the factory "boot animation" in a Darwin-managed image requires nothing more than two lines and one MP3 file.

## Next-step recommendations

1. **Apply ×4 balance gain in Darwin walk engine** — single biggest fix likely to resolve walking instability. See [03-walking-module.md §6.3](03-walking-module.md). One multiplier, ~8 lines of code in `app/core/forge-core/src/walk/engine.rs`.

2. **Fix `docs/architecture/joint-conventions.md` ID table** — current doc is wrong for IDs 7–18. Replace with the canonical table in [07-servo-config.md §1](07-servo-config.md). Zero code change, doc-only edit.

3. **Rewrite `docs/motion-format/page-format.md`** — current offsets are wrong. Replace with the verified 64-byte header + 31-slot step layout from [04-motion-library.md §"Page layout"](04-motion-library.md). Add a new `docs/motion-format/bin-format.md` for the on-robot binary encoding.

4. **Add `bin_loader.rs` to forge-core** — required to read/write on-robot `motion_4096.bin`. Spec in [04-motion-library.md §"What this means for Darwin"](04-motion-library.md); includes `BinScale::{Res4096, Res1024}` enum and per-page checksum validation.

5. **Add `PresetAction` enum + 14 factory-page constants** — these are the 14 motion pages the factory firmware actually invokes (1=stand_up, 4=thank_you, 9=soccer_ready, 10/11=get_up_fwd/bwd, 12/13=kick_r/l, 15=sit_down, 23=yes_go, 24=wow, 27=oops, 38=bye_bye, 41=introduction, 54=clap_please). Spec in [06-action-library.md §"What this means for Darwin"](06-action-library.md).

## How to extend

To add a new firmware-reference doc:

1. Pick a topic not covered (candidates: USB driver behavior under `ftdi_sio`, button GPIO via CM-730 register 30, FSR sensor calibration, eye/head RGB LED protocol via CM-730 RAM 26–29).
2. Cite **≥3 absolute paths** under `firmware-backups/sda1-rootfs/`.
3. Follow the section structure of the existing docs: TL;DR → key files → algorithm/protocol → factory values → "what this means for Darwin" → Evidence list.
4. Add a row to the doc table above and a line item to the appropriate Critical Findings or Cross-doc theme if relevant.

## How to restore the backup

See [`firmware-backups/MANIFEST.md`](../../firmware-backups/MANIFEST.md) + `/Users/bbikiming/.claude/plans/sprightly-jingling-wozniak.md` Phase B for the Docker commands. Outer ZIP sha256 should be `246c90b4070705f1cfe577bffd359d358578c590527eccebe06715aa659db290`.

## Privacy & secrets

- [09-network-comms.md](09-network-comms.md) uses **fingerprint-only SSH key reporting**; no private keys were extracted or copied.
- **No WPA PSK exists** in the image (verified absent — `/etc/wpa_supplicant/wpa_supplicant.conf` does not exist).
- The user account is `robotis` (UID 1000); the image ships with `PermitRootLogin yes` and the default robotis password is documented separately under user-accounts privacy rules — **never expose the robot to untrusted networks without changing this**.
- The recovery image and `sda1-rootfs/` tree are gitignored and proprietary to ROBOTIS; do not redistribute publicly.
