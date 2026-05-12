# Implementation Guide — Porting Factory Findings into Darwin

## Purpose

This guide translates the 11 firmware-reference docs into concrete action items for the Darwin codebase. Each item maps to an exact Rust module path (`app/core/forge-core/src/...`) or Swift module (`app/swift/...`) or a doc-rewrite target under `docs/`, with priority and effort estimate.

Source docs cited throughout: [INDEX.md](INDEX.md), [01-system-os.md](01-system-os.md), [02-framework-source.md](02-framework-source.md), [03-walking-module.md](03-walking-module.md), [04-motion-library.md](04-motion-library.md), [05-vision-pipeline.md](05-vision-pipeline.md), [06-action-library.md](06-action-library.md), [07-servo-config.md](07-servo-config.md), [08-startup-services.md](08-startup-services.md), [09-network-comms.md](09-network-comms.md), [10-game-controller.md](10-game-controller.md), [11-audio-speech.md](11-audio-speech.md).

## Priority legend

- **P0 (blocking)** — Darwin won't work correctly without this fix. Symptom is observable or already observed.
- **P1 (high)** — Significant functional gap; should land in next sprint.
- **P2 (medium)** — Nice-to-have; opportunistic.
- **P3 (informational)** — No action needed; documented for completeness so future contributors don't re-investigate.

## Effort legend

- **XS** = under 1 hour (doc tweak)
- **S** = 1 day (single file change)
- **M** = 1–2 days (multi-file + tests)
- **L** = 3–5 days (new module + integration)
- **XL** = 1+ week (feature with verification on hardware)

---

## Item catalog

### [P0] FIX: Apply ×4 balance gain for MX-28 4096-res

- **Source**: [03-walking-module.md §1.2 (Walking.cpp:587-598) and §5.2 + §6.3 item 1](03-walking-module.md)
- **Symptom**: Darwin's walking is unstable — robot fails to self-correct and tips over instead of returning to vertical. The robot may also appear "stuck in walk_ready" because the engine fires the gait but IMU correction has 1/4 of its intended authority.
- **Root cause**: Factory `Walking.cpp:587-598` wraps every IMU balance correction inside `#ifdef MX28_1024 … #else …`. The 4096-res branch (active in factory) multiplies all four balance gains (`BALANCE_HIP_ROLL_GAIN`, `BALANCE_KNEE_GAIN`, `BALANCE_ANKLE_PITCH_GAIN`, `BALANCE_ANKLE_ROLL_GAIN`) by ×4. Darwin's `app/core/forge-core/src/walk/params.rs` mirrors the C++ ctor defaults (0.5 / 0.3 / 0.9 / 1.0) verbatim but the Rust engine likely applies them at their raw value, yielding only 1/4 of the factory-intended IMU response.
- **Files to change**:
  - `app/core/forge-core/src/walk/engine.rs` — at the IMU balance application step, multiply each balance gain by `4.0` when target is MX-28 4096-resolution (which is always for OP2). Recommended: introduce a constant `const MX28_4096_BALANCE_SCALE: f64 = 4.0;` so the magic number is named.
  - Alternative: bake the ×4 into `WalkParams::default()` directly (multiplying the stored gain values), but that breaks the 1:1 mapping with `op2_walking_module/config/param.yaml` and the firmware's `[Walking Config]` ini section — **don't do this**.
- **Verification**:
  1. Build forge-core and load default params.
  2. Connect to a real OP2 and start the walking module in WalkLab.
  3. Tilt the robot slightly fore/aft and side-to-side; verify the IMU-driven hip-roll, knee, ankle-pitch, ankle-roll corrections fire at roughly the visible magnitude shown by the factory `walk_tuner` (a known-good baseline).
  4. Robot should stay upright while taking 10+ steps forward/back without tipping.
- **Effort**: S (single multiplier const + 8 multiplications at gain application)

### [P0] FIX: Joint ID mapping in docs/architecture/joint-conventions.md

- **Source**: [07-servo-config.md §"Joint ID map"](07-servo-config.md) (quoting `JointData.h:13-35` verbatim) + [04-motion-library.md §"Joint slot mapping"](04-motion-library.md) (independent confirmation)
- **Symptom**: Darwin docs claim wrong leg joint IDs. Current doc says "IDs 7–10 unused (구버전 ID 흔적)" and lists HIP_YAW at 11/12, HIP_ROLL at 13/14, HIP_PITCH at 15/16, KNEE at 17/18, and omits ankle joints entirely. The factory `JointData.h` shows IDs 7/8 = HIP_YAW, 9/10 = HIP_ROLL, 11/12 = HIP_PITCH, 13/14 = KNEE, 15/16 = ANKLE_PITCH, 17/18 = ANKLE_ROLL.
- **Root cause**: Doc drift. The Darwin doc was written before the factory image was unpacked; it appears to be based on a community wiki that conflicted with the canonical `JointData.h`.
- **Files to change**:
  - `docs/architecture/joint-conventions.md` — replace the ID table (currently lines 8-26 of the existing doc) with the corrected mapping shown in [INDEX.md §"Joint ID mapping error"](INDEX.md). Remove the misleading "7~10은 사용 안 함 (구버전 ID 흔적)" sentence on line 27. Add ankle joints (15–18) which are currently missing entirely.
- **Verification**: visual diff against `Framework/include/JointData.h` enum lines 13-35. The doc should match `R_SHOULDER_PITCH=1 … L_ANKLE_ROLL=18, HEAD_PAN=19, HEAD_TILT=20` exactly.
- **Effort**: XS (doc edit)

### [P0] FIX: Motion format docs (page-format.md is wrong)

- **Source**: [04-motion-library.md §"Format relationship vs docs/motion-format/mtn-format.md"](04-motion-library.md) — the verdict table with current-spec-vs-reality columns.
- **Symptom**: Darwin currently cannot read on-robot `motion_*.bin` files because `docs/motion-format/page-format.md` documents speculative offsets that are wrong by tens of bytes. Step `pose` size is documented as 20 × uint16 = 40 bytes; actual is 31 × uint16 = 62 bytes. Header is documented as ~22 bytes; actual is 64 bytes. Critical fields `slope[31]` and `checksum` are missing from the doc entirely.
- **Root cause**: The Darwin doc was a Sprint-3 placeholder with explicit "TODO: needs verification" markers. The verified spec lives in `Framework/include/Action.h` (`PAGEHEADER` / `STEP` / `PAGE` structs) and has now been decoded byte-by-byte against the live `motion_4096.bin`.
- **Files to change**:
  - **Rewrite** `docs/motion-format/page-format.md` — replace the speculative offset tables with the verified layout from [04-motion-library.md §"Page layout (decoded from Action.h)"](04-motion-library.md). Include the `slope[31]` 4-bit nibble encoding (CW<<4 | CCW) and the `checksum` calculation (`sum of all 512 bytes % 256 == 0xff`).
  - **New file** `docs/motion-format/bin-format.md` — covers the on-robot binary `motion_*.bin` encoding specifically: 256 pages × 512 bytes = 131,072 bytes, page checksum algorithm, INVALID_BIT_MASK (`0x4000`) / TORQUE_OFF_BIT_MASK (`0x2000`) flags in position high bits, the two scale variants (4096 / 1024) and how `pos = pos << 2` / `pos >> 2` converts between them. The existing `mtn-format.md` (text RoboPlus authoring format) stays; this new doc fills the binary-runtime gap.
  - **New Rust module** `app/core/forge-core/src/motion/bin_loader.rs` — public API:
    ```rust
    pub enum BinScale { Res4096, Res1024 }
    pub struct MotionLibrary { pub pages: [Option<Page>; 256], pub scale: BinScale }
    pub fn load_bin(bytes: &[u8]) -> Result<MotionLibrary>;
    pub fn write_bin(lib: &MotionLibrary) -> Vec<u8>;  // round-trip
    ```
  - Enforce 131,072-byte total size on parse; surface per-page checksum mismatches as warnings (the firmware's `Action::LoadPage` itself just resets bad pages, but our higher-level tools should flag corruption).
- **Verification**:
  1. Load `firmware-backups/sda1-rootfs/robotis/Data/motion_4096.bin` via `bin_loader::load_bin()`.
  2. Confirm 256 pages parsed.
  3. Confirm checksum-OK on all 256 pages.
  4. Confirm 44 pages have non-empty names matching the catalog in [04-motion-library.md §"Page catalog"](04-motion-library.md) (walkready, sit down, stand up, f up, b up, rk, lk, mul1/2/3, talk1, talk2, …).
  5. Decode page 9 ("walkready") step 0 — joint positions should match the sample table in [04-motion-library.md §"Sample page decode"](04-motion-library.md) (R_SHOULDER_PITCH=1498, L_SHOULDER_PITCH=2518, …).
  6. Round-trip: `write_bin(load_bin(orig))` should produce a byte-identical file modulo checksum reseal.
- **Effort**: M (1–2 days: doc rewrites + Rust loader + tests)

### [P1] ADD: A_MOVE_AIM_ON yaw reversal mode in WalkParams

- **Source**: [03-walking-module.md §6.2 (table row "A_MOVE_AIM_ON")](03-walking-module.md) and `Walking.cpp:282-297`
- **Symptom**: Darwin can't reproduce the factory "turn-aim" mode where the robot rotates to face a target while walking. Visual symptom: when commanding pure yaw without translation, Darwin would walk in a circle the wrong way (or not at all) because `m_A_Move_Aim_On` controls the sign of the yaw component injected into the foot endpoint.
- **Files to change**:
  - `app/core/forge-core/src/walk/params.rs` — add `pub a_move_aim_on: bool` to `WalkParams`; set `false` in `Default`.
  - `app/core/forge-core/src/walk/engine.rs` — at the c_move_r / c_move_l yaw-amplitude shift calculation, branch on `params.a_move_aim_on` to flip sign exactly as factory Walking.cpp:282-297 does.
- **Verification**: command yaw-only turn in WalkLab with `a_move_aim_on = true` vs `false`; rotation direction should reverse.
- **Effort**: S

### [P1] ADD: HIP_PITCH_OFFSET deg→raw conversion in walk engine

- **Source**: [03-walking-module.md §2.7 "HIP_PITCH_OFFSET application" + §6.3 item 2](03-walking-module.md). Factory `Walking.cpp:564-565` applies `offset -= (double)dir[i] * HIP_PITCH_OFFSET * MX28::RATIO_ANGLE2VALUE` at joints R_HIP_PITCH and L_HIP_PITCH.
- **Symptom**: Walking pose may have wrong forward lean — too upright or too hunched — if the deg→raw conversion is dropped or applied at the wrong scale. The factory value is 13.0 degrees, converted via `RATIO_ANGLE2VALUE = 11.378` (= 4096/360) to ~148 raw counts.
- **Files to change**: `app/core/forge-core/src/walk/engine.rs` — verify and add the `params.hip_pitch_offset_deg * RATIO_ANGLE2VALUE` conversion at hip-pitch joint output. `RATIO_ANGLE2VALUE` should be a module-level constant derived from `MX28_MAX_POSITION / 360.0`.
- **Verification**: command `WalkParams { hip_pitch_offset_deg: 0.0, .. default() }` vs the default 13.0. Robot torso should visibly tilt forward when hip_pitch_offset_deg is non-zero.
- **Effort**: S

### [P1] ADD: PELVIS_OFFSET × 0.35 swing magic factor

- **Source**: [03-walking-module.md §2.5 + §6.3 item 3](03-walking-module.md). Factory `Walking.cpp:257-258`: `m_Pelvis_Offset = PELVIS_OFFSET × MX28::RATIO_ANGLE2VALUE` and `m_Pelvis_Swing = m_Pelvis_Offset × 0.35`. The swing is applied during SSP_L only — `+Pelvis_Swing/2` to left hip-roll, `−Pelvis_Offset/2` to right hip-roll (post-IK, applied to raw motor counts).
- **Symptom**: Without this, lateral hip-roll behavior during single-support phase differs from factory — the robot doesn't shift its center of mass laterally as the factory tuning intends, leading to drift during long forward walks.
- **Files to change**: `app/core/forge-core/src/walk/engine.rs` — at the per-tick raw-motor-counts output stage, after IK, apply the asymmetric pelvis swing using the 0.35 multiplier. Track which phase (SSP_L vs SSP_R vs DSP) we're in.
- **Verification**: log hip-roll raw counts over a 600 ms walk cycle; pattern should show the asymmetric +/− offset only during the SSP_L window (between SSP_Start_L and SSP_End_L).
- **Effort**: S

### [P1] ADD: Walking arm initial pose (6 joint targets)

- **Source**: [03-walking-module.md §4.1 conclusion 4](03-walking-module.md). Factory `Walking.cpp:55-60` sets at construction:
  ```cpp
  R_SHOULDER_PITCH = -48.345
  L_SHOULDER_PITCH = 41.313
  R_SHOULDER_ROLL  = -17.873
  L_SHOULDER_ROLL  = 17.580
  R_ELBOW          = 29.300
  L_ELBOW          = -29.593
  ```
  (degrees, applied to joint angle before motor conversion)
- **Symptom**: Without these explicit arm-pose targets, the robot starts walking with arms in unknown positions — possibly hanging straight down or in motion-page residuals — instead of the factory "elbows-bent-slightly-forward" walking stance. Visually noticeable mismatch with factory videos.
- **Files to change**: `app/core/forge-core/src/walk/engine.rs` or a new `app/core/forge-core/src/walk/pose.rs` — at Walking start (`Walking::Initialize` equivalent), set R/L shoulder pitch/roll and R/L elbow to these 6 values. Keep them as module-level `const`s (deg) so they're discoverable; also expose as part of `WalkParams` if needed for tuning.
- **Verification**: visually compare robot arm pose at walk-ready against a factory-firmware reference video.
- **Effort**: S

### [P1] ADD: Walking arm soft P-gain (P=8 for shoulder/elbow)

- **Source**: [07-servo-config.md §"Default PID / compliance constants"](07-servo-config.md) and [03-walking-module.md §6.2 row "팔 P_GAIN = 8"](03-walking-module.md). Factory `Walking.cpp:72-77` overrides the default P=32 for 6 arm joints down to P=8 (soft, to absorb impact during gait).
- **Symptom**: Walking causes shoulder/elbow servos to overshoot or chatter when impacts happen (e.g., arm brushes torso) because the gain is 4× too stiff.
- **Files to change**: `app/core/forge-core/src/walk/engine.rs` — at Walking start, issue `SetPGain(id, 8)` for `R_SHOULDER_PITCH`, `L_SHOULDER_PITCH`, `R_SHOULDER_ROLL`, `L_SHOULDER_ROLL`, `R_ELBOW`, `L_ELBOW`. Restore P=32 on Walking stop if needed for action playback.
- **Verification**: read back MX-28 P-gain register (P_P_GAIN, address 28) on arm joints during walking; should be 8, not 32.
- **Effort**: XS

### [P1] FIX: Walking stop only at DSP phase boundary

- **Source**: [03-walking-module.md §6.3 item 4](03-walking-module.md). Factory `Walking.cpp:374-388, 396-411`: walking stops only at PHASE0 / PHASE2 (double-support) boundary, never mid-step.
- **Symptom**: If Darwin's stop logic flips `m_Real_Running = false` immediately on `Stop()` call, the robot may finish in single-support phase with one foot in the air — instant fall.
- **Files to change**: `app/core/forge-core/src/walk/engine.rs` — gate the actual "stop walking" transition on `m_Phase == PHASE0 || m_Phase == PHASE2` AND input commands (X/Y/A move amplitudes) are zero.
- **Verification**: command Stop() during PHASE1 (single-support right); observe walking continues for the remainder of the cycle and only stops at the next DSP boundary.
- **Effort**: S

### [P1] FIX: PHASE2 time jump for phase accuracy

- **Source**: [03-walking-module.md §6.3 item 5](03-walking-module.md). Factory `Walking.cpp:397` forces `m_Time = m_Phase_Time2` on entering PHASE2 to prevent gradual phase drift.
- **Symptom**: Over many walking cycles, the timing of leg-swap can drift forward in time, accumulating into visible asymmetric step length.
- **Files to change**: `app/core/forge-core/src/walk/engine.rs` — at phase transition into PHASE2, hard-set the local time variable to the canonical phase-2 start time.
- **Verification**: log `m_Time` and `m_Phase` over 100+ cycles; phase boundaries should remain at fixed ms offsets from the cycle start, no drift.
- **Effort**: S

### [P1] FIX: docs/protocols/cm-730-740.md baudrate folklore

- **Source**: [07-servo-config.md §"Cross-check against docs/protocols/cm-730-740.md"](07-servo-config.md). The Darwin doc says "Baud 1 = 1 Mbps, 7 = 576 kbps" but the formula in `LinuxCM730::SetBaud` is `baudrate = 2_000_000 / (baud + 1)`, so baud=7 yields 250 kbps, not 576 kbps. The 576 kbps fallback claim is folklore.
- **Files to change**: `docs/protocols/cm-730-740.md` — correct the baud register value examples. Recommended replacement table: `baud=0 → 2 Mbps, baud=1 → 1 Mbps, baud=3 → 500 kbps, baud=7 → 250 kbps, baud=15 → 125 kbps, baud=34 → 57.6 kbps`, derived from `2_000_000 / (baud + 1)`.
- **Effort**: XS

### [P1] FIX: docs/protocols/dynamixel-1.0.md BULK_READ scope claim

- **Source**: [07-servo-config.md §"Cross-check against docs/protocols/dynamixel-1.0.md"](07-servo-config.md). The Darwin doc says "The Walking / Motion loop uses BULK_READ every cycle to read all 20 joint positions + IMU + FSR." The factory firmware actually reads **only** CM-730 RAM (24..53) + 2 × FSR (26..35). Per-joint position reads are commented out in production `CM730::MakeBulkReadPacket` (`Framework/src/CM730.cpp:407-415`); they only exist in the Webots simulator path.
- **Files to change**: `docs/protocols/dynamixel-1.0.md` — replace the inaccurate hot-path paragraph with: "BULK_READ in production reads CM-730 RAM (`P_DXL_POWER`..`P_VOLTAGE + mic_L_L`, addresses 24..53) plus optional FSR boards 111/112 (addresses 26..35 each). Per-joint position reads are issued one-off at `MotionManager::Initialize` and on demand, not in the hot loop. The Webots-build alternative `MakeBulkReadPacketWb` adds per-joint position reads for simulator compatibility."
- **Effort**: XS

### [P2] ADD: Vision color thresholds (factory defaults) as Rust consts

- **Source**: [05-vision-pipeline.md §"Factory color thresholds" + §"Rust 포트 경로 제안"](05-vision-pipeline.md). Factory ships with explicit thresholds for orange ball, red, yellow, blue color cards.
- **Files to change**:
  - **New file** `app/core/forge-core/src/vision/presets.rs`:
    ```rust
    pub const ORANGE_BALL: ColorFinder = ColorFinder {
        hue: 355, hue_tolerance: 15,
        min_saturation: 60, min_value: 15,
        min_percent: 0.1, max_percent: 50.0,
    };
    pub const RED:    ColorFinder = ColorFinder { hue: 0,   hue_tolerance: 15, min_saturation: 45, min_value: 0, min_percent: 0.3, max_percent: 50.0 };
    pub const YELLOW: ColorFinder = ColorFinder { hue: 60,  hue_tolerance: 15, min_saturation: 45, min_value: 0, min_percent: 0.3, max_percent: 50.0 };
    pub const BLUE:   ColorFinder = ColorFinder { hue: 225, hue_tolerance: 15, min_saturation: 45, min_value: 0, min_percent: 0.3, max_percent: 50.0 };
    ```
  - Add `ColorFinder` struct itself in a new `app/core/forge-core/src/vision/color_finder.rs` (peer to existing `segmentation.rs`).
  - Hue wrap-around handling per `ColorFinder.cpp:51-82`.
- **Verification**: synthetic frame (single bright orange blob centered) → `ColorFinder::find(frame)` returns Point2D near image center.
- **Effort**: S

### [P2] ADD: 3×3 Erosion/Dilation morphology + centroid

- **Source**: [05-vision-pipeline.md §"이미지 처리 파이프라인"](05-vision-pipeline.md). Factory pipeline is HSV mask → 1× erode (3×3 AND) → 1× dilate (3×3 OR) → centroid from average of on-pixel coordinates.
- **Files to change**: `app/core/forge-core/src/vision/morphology.rs` (new) — `erode_3x3`, `dilate_3x3` operating on binary `Vec<u8>` mask. Centroid logic in `ColorFinder::find`.
- **Effort**: S

### [P2] ADD: Pixel-to-camera-angle conversion

- **Source**: [05-vision-pipeline.md §"출력 좌표 → 카메라각 변환"](05-vision-pipeline.md). Factory `BallTracker.cpp:115-120`: `offset = (pos - center) * -1; offset.X *= 58/320; offset.Y *= 46/240`.
- **Files to change**: `app/core/forge-core/src/vision/tracker.rs` (new) — `pixel_to_camera_angle(p: Point2D, fov_h: f64, fov_v: f64, img_w: u32, img_h: u32) -> (f64, f64)` returning (pan_deg, tilt_deg). Use Camera FOV constants `VIEW_H_ANGLE = 58.0°, VIEW_V_ANGLE = 46.0°`.
- **Effort**: S

### [P2] ADD: PresetAction enum + 14 factory motion pages

- **Source**: [06-action-library.md §"Predefined action sequences" + §"Suggested Rust API"](06-action-library.md). Factory code references exactly 14 of 256 pages.
- **Files to change**: `app/core/forge-core/src/motion/preset.rs` (new):
  ```rust
  pub enum PresetAction {
      StandUp,         // page 1
      ThankYou,        // page 4
      SoccerReady,     // page 9
      GetUpForward,    // page 10
      GetUpBackward,   // page 11
      KickRight,       // page 12
      KickLeft,        // page 13
      SitDown,         // page 15
      YesGo,           // page 23
      Wow,             // page 24
      Oops,            // page 27
      ByeBye,          // page 38
      Introduction,    // page 41
      ClapPlease,      // page 54
  }

  impl PresetAction {
      pub const fn page(&self) -> u8 { /* match */ }
      pub const fn label(&self) -> &'static str { /* match */ }
      pub const fn mp3(&self) -> Option<&'static str> { /* match */ }
  }
  ```
- **Verification**: each preset's `page()` returns the documented page number; SwiftUI Studio shows 14 buttons that each call `Action::start(PresetAction::X.page())`.
- **Effort**: S

### [P2] ADD: Action playback module (mirror Action.h)

- **Source**: [06-action-library.md §"Action.h class API" + §"Suggested Rust API"](06-action-library.md). Factory `Framework/src/motion/modules/Action.cpp` provides `Start(int page)`, `Start(char* name)`, `Stop()`, `Brake()`, `IsRunning()`, `LoadPage()`, `SavePage()`.
- **Files to change**: `app/core/forge-core/src/motion/action.rs` (new) — Rust port of the Action module. Depends on `bin_loader.rs` (P0 item) being landed first.
- **Effort**: M (depends on P0 bin_loader)

### [P2] ADD: Factory motion library import script

- **Source**: [04-motion-library.md §"What this means for Darwin" point 1](04-motion-library.md). Suggested action: convert `motion_4096.bin` → 44 JSON pages at `motions/factory/*.json`.
- **Files to change**: one-off importer script (Rust binary `tools/motion-importer/` or a Python helper); output directory `motions/factory/` (gitignored if it duplicates firmware-backups content, or tracked if we add provenance attribution).
- **Verification**: 44 JSON files, one per named page; each file readable by Darwin Studio's Motion editor.
- **Effort**: S (once bin_loader.rs exists)

### [P2] ADD: Per-joint EEPROM reset table (firmware_installer parity)

- **Source**: [07-servo-config.md §"Joint EEPROM reset values"](07-servo-config.md). Factory `firmware_installer/main.cpp:153-239` sets per-joint CW/CCW angle limits, temperature limit 80°C, voltage 6.0/14.0 V, max torque 4095, alarm 0x24.
- **Files to change**: `app/core/forge-core/src/dynamixel/factory_defaults.rs` (new) — module-level `const FACTORY_JOINT_EEPROM: [JointEepromDefaults; 21]` table indexed by joint ID. Add a `restore_factory_defaults()` admin command in `dxl_monitor` equivalent.
- **Use case**: when a robot is suspected of being mis-tuned, a single CLI command can write the factory EEPROM values back.
- **Effort**: M

### [P2] ADD: Boot-pose convention (page 15 sit on connect)

- **Source**: [06-action-library.md §"What this means for Darwin → Boot animation"](06-action-library.md). Factory plays page 15 (sit pose) on power-on.
- **Files to change**: `app/swift/.../ConnectionFlow.swift` or equivalent — when a user-initiated "Connect" succeeds, send `Action::Start(PresetAction::SitDown.page())` so the bot returns to a known-safe pose. Optional: a UI confirmation prompt before doing so, since the bot may be in storage.
- **Effort**: S

### [P3] INFO: GC client absent

- **Source**: [10-game-controller.md](10-game-controller.md).
- **Action**: none. Documented for future contributors so they don't waste time grepping for a non-existent reference. If RoboCup support is ever requested, write a fresh `app/core/forge-core/src/gc_client/` against the upstream `RoboCup-Humanoid-TC/GameController` spec (UDP 3838 in, 3939 out, `RGme`/`RGrt` headers).
- **Effort**: N/A

### [P3] INFO: Robot acts as DHCP server on 192.168.123.0/24

- **Source**: [08-startup-services.md §"DHCP server"](08-startup-services.md) and [09-network-comms.md §"Network interfaces"](09-network-comms.md).
- **Action**: document in Darwin user guide ("plug Ethernet cable directly between Mac and robot; set Mac to DHCP or static `192.168.123.x`; do NOT plug robot into shared LAN router"). No code change needed.
- **Effort**: XS (user-guide note)

### [P3] INFO: madplay (not mpg321) for MP3 playback

- **Source**: [11-audio-speech.md §"Playback mechanism"](11-audio-speech.md). Factory uses `madplay` invoked directly via `fork()+execl("/usr/bin/madplay", ...)`. `mpg321` is installed but unreferenced.
- **Action**: if Darwin ever ships a replacement on-robot agent that plays audio cues, mirror this pattern (one-line `execl` is simpler than spawning an audio daemon). For Mac-side audio, use `AVAudioPlayer` or Apple's TTS via `AVSpeechSynthesizer`.
- **Effort**: N/A

### [P3] INFO: No TTS engine on robot

- **Source**: [11-audio-speech.md §"TTS (if present)"](11-audio-speech.md). No `espeak`, `festival`, `flite`. Speech is 25 pre-recorded MP3 clips.
- **Action**: any "speak arbitrary string" Darwin feature must generate audio off-board (Mac TTS or cloud) and stream/pre-render. Don't propose on-robot TTS without first justifying a heavy package install on the Atom N2600.
- **Effort**: N/A

### [P3] INFO: Custom kernel `3.2.66-op2` with SMP PREEMPT

- **Source**: [01-system-os.md §"Kernels (CRITICAL)"](01-system-os.md). Factory boots `Linux 3.2.66-op2 SMP PREEMPT` built 2015-02-13 KST on the manufacturer's machine.
- **Action**: if Darwin ever ships a replacement onboard image, rebuild the same `op2` kernel from `linux-source-3.2.66-op2` (headers preserved at `/usr/src/linux-headers-3.2.66-op2/`) or accept the latency hit from a non-preemptive kernel. Don't blindly flash stock Ubuntu — the motion thread requires preemption for the 8 ms deadline.
- **Effort**: N/A (only relevant if we ever re-image the robot)

### [P3] INFO: 32-bit (i386) userland on a 64-bit-capable CPU

- **Source**: [01-system-os.md §"Distribution"](01-system-os.md). CPU is Atom N2600 (64-bit capable), userland is i386 only.
- **Action**: any pre-built ROBOTIS binary from this image is 32-bit ELF and won't run on modern macOS or x86_64 Linux without `lib32` shims. All porting must be source-rebuild ports.
- **Effort**: N/A

### [P3] INFO: SSH default password + PermitRootLogin yes

- **Source**: [09-network-comms.md §"SSH server config"](09-network-comms.md). Factory has `PermitRootLogin yes` plus password authentication enabled with the default `robotis` user password.
- **Action**: document in user guide that any production deployment must (a) change the default password, (b) disable password auth, (c) disable root login, (d) add a key to `~robotis/.ssh/authorized_keys`. Darwin Mac app should not auto-SSH unless the user has explicitly configured a key.
- **Effort**: N/A (user-guide note)

---

## Suggested sprint plan

### Sprint 9 — Factory parity + walking fix (P0 + the high-value P1s)

Goal: get walking actually stable on hardware.

- P0: Apply ×4 balance gain for MX-28 4096 in `walk/engine.rs`
- P0: Fix joint ID doc (`docs/architecture/joint-conventions.md`)
- P0: Rewrite motion-format docs + new `bin-format.md`
- P0: Add `app/core/forge-core/src/motion/bin_loader.rs`
- P1: Add A_MOVE_AIM_ON to WalkParams
- P1: Add HIP_PITCH_OFFSET deg→raw conversion
- P1: Add PELVIS_OFFSET × 0.35 swing factor
- Verification milestone: robot walks 10+ steps forward without tipping in WalkLab.

### Sprint 10 — Motion library + presets

Goal: bring the 14 factory motions into Darwin Studio.

- P2: PresetAction enum + 14 factory pages
- P2: Action playback module
- P2: Factory motion library import script → 44 `motions/factory/*.json`
- P1: Walking arm initial pose
- P1: Walking arm soft P-gain (P=8)
- P1: Walking stop at DSP-only
- P1: PHASE2 time jump
- Verification milestone: Studio has working "Stand up", "Sit down", "Wow", "Bye bye" buttons; walking continues until DSP boundary on Stop.

### Sprint 11 — Vision + protocol doc cleanup

Goal: get color-based vision working and clean up the residual doc drift.

- P2: ColorFinder + presets (orange ball, red, yellow, blue)
- P2: 3×3 erosion/dilation + centroid
- P2: Pixel-to-camera-angle conversion
- P1: Fix `docs/protocols/cm-730-740.md` baudrate table
- P1: Fix `docs/protocols/dynamixel-1.0.md` BULK_READ scope claim
- P2: Per-joint EEPROM reset table (factory-defaults restore command)
- Verification milestone: Darwin Studio shows live HSV mask overlay + centroid coordinate while pointed at an orange ball.

---

## Files-to-touch index

Deduplicated list of every file path that any P0/P1/P2 item proposes to modify or create.

| Path | Action | Item refs |
|---|---|---|
| `app/core/forge-core/src/walk/engine.rs` | modify | P0 walking ×4, P1 a_move_aim_on, P1 hip_pitch_offset conv, P1 pelvis ×0.35, P1 arm initial pose, P1 arm P=8, P1 stop at DSP, P1 PHASE2 jump |
| `app/core/forge-core/src/walk/params.rs` | modify | P1 a_move_aim_on field |
| `app/core/forge-core/src/walk/pose.rs` | new (optional) | P1 arm initial pose if extracted |
| `app/core/forge-core/src/motion/bin_loader.rs` | new | P0 bin format |
| `app/core/forge-core/src/motion/action.rs` | new | P2 Action playback |
| `app/core/forge-core/src/motion/preset.rs` | new | P2 PresetAction enum |
| `app/core/forge-core/src/dynamixel/factory_defaults.rs` | new | P2 EEPROM reset table |
| `app/core/forge-core/src/vision/presets.rs` | new | P2 ColorFinder constants |
| `app/core/forge-core/src/vision/color_finder.rs` | new | P2 ColorFinder impl |
| `app/core/forge-core/src/vision/morphology.rs` | new | P2 erosion/dilation |
| `app/core/forge-core/src/vision/tracker.rs` | new | P2 pixel→angle |
| `app/swift/.../ConnectionFlow.swift` (path TBD) | modify | P2 boot pose on connect |
| `docs/motion-format/page-format.md` | rewrite | P0 format docs |
| `docs/motion-format/bin-format.md` | new | P0 bin format spec |
| `docs/architecture/joint-conventions.md` | modify | P0 joint IDs |
| `docs/protocols/cm-730-740.md` | modify | P1 baudrate fix |
| `docs/protocols/dynamixel-1.0.md` | modify | P1 bulk-read fix |
| `motions/factory/*.json` | new (×44) | P2 motion import |
| `tools/motion-importer/` (or Python helper) | new | P2 importer script |

---

## Open questions

These came up across the 11 specialist docs and would benefit from a follow-up investigation, but none are blocking the Sprint 9 plan:

1. **`robotis/Data/config.ini` is absent from the factory image** ([03-walking-module.md §3.3](03-walking-module.md), [07-servo-config.md §"Factory offset.ini / config.ini present?"](07-servo-config.md)). The factory ships with no `[Offset]` calibration — users were expected to run `offset_tuner` after delivery. Question: does Darwin currently expect to find/load a `config.ini`-equivalent on first connect, or does it apply zero offsets by default like the factory does?

2. **mjpg-streamer on-robot duplication**: factory `demo` binary statically links the mjpg streamer on port 8080. Darwin replaces this with macOS AVFoundation + a Mac-side server. Question: if a user wants to view the robot camera from a phone (not the Mac), do we need to keep the on-robot HTTP-MJPEG path alive? If yes, document the mjpg port 8080 in firewall guidance.

3. **`script.asc` text-script format** is documented in [06-action-library.md](06-action-library.md). Question: does Darwin need to import existing `.asc` scripts, or do we replace this UX entirely with the Studio motion-bundle editor? Decide before Sprint 10 to avoid scope drift.

4. **Factory MP3 inventory** ([11-audio-speech.md](11-audio-speech.md)) — 25 voice clips with Korean-accented English. Question: do we ship these with Darwin (for parity with factory demo behavior) or do we generate fresh TTS via AVSpeechSynthesizer at preset-action play time?
