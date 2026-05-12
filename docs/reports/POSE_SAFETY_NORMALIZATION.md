# Pose Safety Normalization — walkReady 자세 정상화 (2026-05-12)

> **트리거**: 사용자 보고 — "현재 모션 중에서 뒤로 넘어질 듯한 기본 자세로 세팅된 모션들이 너무 많아"
>
> **변경 범위**: Swift `RobotPose.walkReady` + Rust `forge-core::motion::walkready` 신규.
> **회귀 영향**: 331 → 337 tests passed (신규 6 walkready tests).

## 문제 진단

### 1. ROBOTIS 공식 자세 vs Swift `RobotPose.walkReady` 불일치

ROBOTIS-OP2 `motion_4096.bin` page 9 step 0 ("walkready") 의 본체 자세:

| Joint | raw | degree | 의미 |
|-------|----:|-------:|------|
| R_HIP_PITCH | 1637 | **-36°** | 앞으로 굽힘 (squat 시작) |
| L_HIP_PITCH | 2459 | **+36°** | mirror |
| R_KNEE | 2653 | **+53°** | 깊은 무릎 굽힘 |
| L_KNEE | 1443 | **-53°** | mirror |
| R_ANKLE_PITCH | 2389 | **+30°** | 발끝 위로 (CoM 보정) |
| L_ANKLE_PITCH | 1707 | **-30°** | mirror |

R+L sum 모두 **4096 ± 79** → 완벽한 mirror, 좌우 균형 0.

Swift `RobotPose.walkReady` (변경 전):

| Joint | degree | 의미 |
|-------|-------:|------|
| rHipPitch / lHipPitch | **0°** | T-pose 하체, 직립 |
| rKnee / lKnee | **0°** | 무릎 굽힘 없음 |
| rAnklePitch / lAnklePitch | **0°** | 발목 중립 |

### 2. 변경 이력 — 두 차례 hotfix 실패

| 시점 | walkReady 설정 | 사용자 보고 | 결과 |
|------|----------------|------------|------|
| 초기 (Sprint 10) | hip±8 / knee±16 / ankle∓7 (ROBOTIS `JointData::Initialize()`) | "뒤로 넘어진다" | ankle 비대칭 CoM 뒤로 |
| Hotfix (Sprint 15) | 하체 0° (T-pose 직립) | "여전히 뒤로 넘어질 듯한 자세" | 직립 막대, 충격 흡수 0 |
| **본 정정 (Sprint 16)** | ROBOTIS 공식 raw 값 그대로 (deep squat) | 검증 대기 (Mac) | 무릎 굽힘 = 안정성 |

### 3. 안전성 분석

| 자세 | 무릎 굽힘 | CoM | 안정성 평가 |
|------|----------|-----|-------------|
| hip±8 / knee±16 / ankle∓7 | 약함 | ankle 비대칭으로 뒤쪽 | **뒤로 넘어짐** |
| T-pose 0° (전 hotfix) | 0 (직립) | 완전 직립 | **충격 흡수 0** — 약간만 흔들려도 넘어짐 |
| **ROBOTIS deep squat** | 53° | 양 발 위 정확 | **안정** — 무릎이 충격 흡수, sumo 자세 비슷 |

## 정정

### Swift `RobotPose.walkReady`

`app/ui/DarwinForge/Sources/ForgeCore/RobotPose.swift:32`:
- 도큐 전체 재작성 — 변경 이력 3단계 명시
- raw 값 직접 사용 (`Kinematics.raw(fromDegrees:)` 우회) — ROBOTIS 데이터의 비대칭(예: shoulder pitch +1498 / -2518, sum 4016) 정확히 보존
- 21 줄 변경

### Rust `forge-core::motion::walkready` 신규

`app/core/forge-core/src/motion/walkready.rs` (135 줄):

- **`WALKREADY_RAW: [u16; 31]`** — ROBOTIS page 9 step 0 raw 31 슬롯 const.
- **`walkready_step() -> MotionStep`** — anchor step (1000 ms hold).
- **`rms_distance_from_walkready(step) -> f64`** — 본체 관절 1..=18 의 RMS 거리.
- **`is_walkready_anchor(step, tolerance_raw) -> bool`** — anchor 적합 여부 검사.
- 6 단위 테스트.

### `motion::mod.rs` re-export 추가

`walkready`, `WALKREADY_RAW`, `walkready_step`, `rms_distance_from_walkready`, `is_walkready_anchor`.

## 검증

### ROBOTIS 16 OFFICIAL_CATALOG 페이지 — 모든 자세 안전

Python decoder 로 16 페이지 첫/마지막 step 의 R/L mirror sum 검증:

```
ID  name           hip_pitch L/R sum   knee L/R sum   ankle_pitch L/R sum
1   Stand Up       4096 ✓             4096 ✓         4096 ✓
2   Yes            4096 ✓             4094 ✓         4094 ✓
3   No             ...
9   Walk Ready     4096 ✓ baseline    4096 ✓         4096 ✓
12  Right Kick     ...
...
```

**16/16 페이지 모두 walkready 기준 mirror ✓** — ROBOTIS 데이터 자체는 안전.

### walk-progression-v1.bin 6 페이지

slot 110~115 `wk_hold` / `wk_arms` / `wk_knee` / `wk_hip_r` / `wk_hip_l` / `wk_lean_pitch`
모두 step 단위로 검증 — **모든 step walkready 기준 mirror ✓**.

### Swift `RobotPose.walkReady` ↔ Rust `WALKREADY_RAW` 값 일치

| Joint | Swift | Rust | match |
|-------|-------|------|:---:|
| rHipPitch | 1637 | 1637 | ✓ |
| lHipPitch | 2459 | 2459 | ✓ |
| rKnee | 2653 | 2653 | ✓ |
| lKnee | 1443 | 1443 | ✓ |
| rAnklePitch | 2389 | 2389 | ✓ |
| lAnklePitch | 1707 | 1707 | ✓ |

### Rust 단위 테스트 (신규 6)

- `all_walkready_lr_pairs_mirror_within_100_raw` — 모든 9 R/L 페어 sum 4096±100 ✓
- `walkready_has_deep_squat_geometry` — knee/hip/ankle 임계 검증 ✓
- `unused_slots_default_to_center` — slot 0, 21..30 모두 2048 ✓
- `walkready_step_is_self_anchor` — RMS 0 ✓
- `far_pose_fails_anchor_check` — T-pose 거부 ✓
- `invalid_flag_slots_excluded_from_distance` — `0x4000` 슬롯 비교 제외 ✓

### 전체 회귀

- `cargo test --workspace` → **337 passed; 0 failed** (이전 331 → 337, +6)
- Swift 측 `swift test` Mac 검증 필요 (`StarterMotionLibraryTests.testWalkProgressionPagesAreSafe`)

## Sprint 11 ReferenceMotionLibrary 자동 안전화

19 페이지 모두 `RobotPose.walkReady.with([...])` 형태로 정의되어 있어 walkReady 한 곳만
바꾸면 **자동으로 안전한 자세 기반 합성**.

- "보행 테스트 1~6" (slot 50~55) → 새 walkReady 기반 deep squat 시작/종료 ✓
- "거북목 케어 / 어깨 케어 / 허리 케어 / 다리 케어" (slot 60~65) → 안전 anchor ✓
- "환영 인사 / 작별 / 환호 등" (slot 70~74, 80~83) → 안전 anchor ✓

## 결정

| # | 결정 | 근거 |
|---|------|------|
| D1 | Swift / Rust walkReady = ROBOTIS page 9 step 0 raw 값 그대로 | 비대칭 보존 + 단일 truth source |
| D2 | Deep squat 자세 채택 (knee ±53°) | 무릎 굽힘 = 충격 흡수, sumo 자세 안정성 |
| D3 | `idle` 자세는 별도 보존 (모든 다리 0°) | 정비 스탠드 거치 / 진단용 |
| D4 | Rust `WALKREADY_RAW` const + helper | 합성 결과 anchor 검증 가능 (RMS 거리 계산) |

## 후속 작업 (Sprint 17+)

- Swift `StarterMotionLibraryTests` Mac 검증 — 새 walkReady 기준 통과 확인
- `forge synth validate` 에 walkready anchor 거리 정보 추가
- V4 StaticStabilityValidator 강화 — 첫/마지막 step walkready 기준 검증
- Walk Lab UI 의 "walkReady" 미리보기를 새 deep squat 자세로 visual 갱신 (Mac)
- 실 robot 검증 — walkReady 자세 송출 후 안정성 측정 (G3 단계)

## 참고

- ROBOTIS 공식 `motion_4096.bin`: page 9 step 0 raw 값
- Swift: `app/ui/DarwinForge/Sources/ForgeCore/RobotPose.swift:32-87`
- Rust: `app/core/forge-core/src/motion/walkready.rs`
- HARDWARE_VERIFICATION_PROTOCOL.md — G3 안전 사전점검
