# AUDIT — 모션·워킹·합성·안전 일관성 감사

> **감사관**: Claude Code (Opus 4.7 1M)
> **감사일**: 2026-05-12
> **감사 범위**: `app/core/forge-core/src/{walk,motion,synth,safety,joint}` + `docs/{prd,decisions,motion-format,architecture}` + `research/robotis-official/ROBOTIS-OP2/` 비교
> **방법**: 1차 소스 직접 읽기. 모든 이슈에 `file:line` 근거. ROBOTIS 원본과 line-by-line 대조.

## TL;DR (3줄)

- **잘된 점**: `walk::params::WalkParams` 와 `walk::ini_pose::WALK_READY_DEGREES` 는 ROBOTIS-OP2 `param.yaml` / `ini_pose.yaml` 와 line-by-line 1:1; `motion::bin4096` 는 byte-preserving round-trip 통과 (공식 131,072 byte fixture); `safety::self_collision::check_step` 는 인덱싱 규약 (positions[i] = ID i) 을 정확히 명시.
- **우려**: 총 **18개 이슈**. Critical **3** / High **5** / Medium **6** / Low **4**. 핵심 문제는 (1) `synth::ops::mirror` 가 positions[ID-1] 로 off-by-one 오인덱싱 → walkready / kick 페이지 mirror 시 데이터 손상 가능, (2) `walk::engine` 이 ROBOTIS 의 wSin/ZMP 알고리즘이 아닌 단순 sin 파 stub 인데 docstring·아키텍처 문서는 "ROBOTIS 1:1" 로 광고, (3) V2 velocity 임계 (5.2 / 11.3 raw/ms) 의 calibration 데이터를 만드는 스크립트가 리포지토리에 없음 — 매직 넘버.

---

## 영역별 이슈

### 🔴 Critical (실 로봇 손상 / 데이터 유실 가능)

#### C1 — `synth::ops::mirror` 가 positions 배열을 **off-by-one** 인덱싱
- **위치**: `app/core/forge-core/src/synth/ops/mirror.rs:63-78, 95-127`
- **근거**:
  - mirror.rs 의 `MIRROR_PAIRS = &[(1,2,SwapReflect), (3,4,SwapReflect), ...]` 가 ID 1-base 임. 그리고 `r_idx = (right_id - 1) as usize` 로 ID 1 을 idx 0 으로, ID 2 를 idx 1 로 매핑함.
  - **그러나** 같은 코드베이스 내 다른 모든 위치는 `positions[i] = JointID i` (즉 idx 1 부터 ID 1) 규약을 따른다. 직접 인용:
    - `safety::self_collision::check_step` line 58: `// step.positions 는 31 slot 배열이지만 ID 0 은 미사용 — index = JointId as u8.` (`/home/user/Darwin/app/core/forge-core/src/safety/self_collision.rs:58`)
    - `synth::validator::joint_limit` line 32: `for slot in 1..=NUM_JOINTS_IN_STEP.min(20) { ... step.positions[i] ... JointId::from_byte(i as u8) }` (`/home/user/Darwin/app/core/forge-core/src/synth/validator/joint_limit.rs:32-49`)
    - `synth::validator::velocity` line 69: `for i in 1..=NUM_JOINTS_IN_STEP.min(20) { let av = a.positions[i]; ... }` (`/home/user/Darwin/app/core/forge-core/src/synth/validator/velocity.rs:69-95`)
    - `synth::validator::static_stability` line 61-62: `step.positions[JointId::RHipPitch as usize]` — JointId::RHipPitch = 11 enum repr, so positions[11] = R_HIP_PITCH.
    - `synth::ops::layer::region_for_slot` line 158-165: `1..=6 => Upper, 7..=18 => Lower, 19..=20 => Head`. (`/home/user/Darwin/app/core/forge-core/src/synth/ops/layer.rs:158-165`)
    - `forge-cli::motion_play::step_to_targets` line 148: `for slot in 1..=NUM_JOINTS_IN_STEP.min(20) { ... ROBOTIS PageData 의 positions[0] 은 reserved 라 slot in 1..=20`. (`/home/user/Darwin/app/core/forge-core/src/forge-cli/src/motion_play.rs:145-160`)
  - 그리고 공식 `motion_4096.bin` 의 page 9 walkready 의 첫 step raw 바이트는 (offset 64-): `00 40 da 05 d6 09 35 07 c8 08 4d 09 b0 06 00 08` — 첫 uint16 LE = `0x4000` (INVALID). ID 1 (R_SHOULDER_PITCH, -48°, raw≈1500) 의 실제 값은 두 번째 uint16 = `0x05da` (1498). **즉 positions[1] = ID 1**.
- **결과**: `mirror_step(walkready)` 는 idx 0 (unused 슬롯의 0x4000 INVALID 마커) 과 idx 1 (ID 1 의 raw 1498) 을 swap+reflect. 결과 페이지 positions[1] = `reflect(0x4000) = 0x4FFF` → robot 입장에서 R_SHOULDER_PITCH **INVALID** (= 이전 step 값 유지). 결과 페이지 positions[0] = `reflect(0x05da) = 0x0a25` → 의미 없는 자리에 12-bit 값이 들어감. **R_SHOULDER_PITCH 데이터 손실 + 의미 없는 슬롯 0 오염.**
- **왜 테스트가 통과하나**: `mirror_swaps_left_right_compliance` 는 `m.compliance[r_idx] == p.compliance[l_idx]` 라는 mirror.rs 의 **내부 로직 합치성** 만 확인 — 실제로 ID3 / ID4 가 옳게 swap 됐는지 안 봄. `mirror_step_is_involution` 는 swap+reflect 의 mathematical involution 만 확인 (어떤 idx 에서 일어나든 무관). `mirror_of_rk_approximates_lk` 는 idx 0..17 평균 절댓값 차이 < 600 raw 라는 느슨한 임계 — 한 슬롯이 2000+ 어긋나도 다른 17 슬롯이 보전하면 평균 < 600 가능.
- **권고**: MIRROR_PAIRS 의 idx 를 ID 그대로 사용 (`r_idx = right_id as usize`). 단, 동시에 `head_pan` 의 idx 19 도 20 으로 정정, compliance swap 도 마찬가지. fixture page_12_right_kick mirror → page_13_left_kick approximate 비교 임계를 < 100 raw 로 강화. (확인 필요: fixture extraction 자체가 byte-position 그대로면 정정 후 mean diff 는 더 줄어들 것)

#### C2 — `synth::library::infer_body_regions` 도 동일한 **off-by-one** 인덱싱
- **위치**: `app/core/forge-core/src/synth/library.rs:319-331`
- **근거**: 코드 `for i in 0..NUM_JOINTS_IN_STEP { ... let id = (i + 1) as u8; match id { 1..=6 => upper, 7..=18 => lower, 19..=20 => head, _ => {} } }`. 이는 idx 0 → "ID 1 upper", idx 18 → "ID 19 head" 로 해석. C1 의 잘못된 규약과 동일. 다른 코드 (layer.rs `region_for_slot` 등) 는 `slot` 자체를 ID 로 본다 (즉 idx 1 = ID 1).
- **결과**: `auto_metadata` 가 `body_regions` 를 한 칸 어긋나게 추정. UpperBody / LowerBody / Head 분류가 페이지 단위로 잘못된 메타데이터 생성. 후속 `library.by_region(BodyRegion::UpperBody)` 검색 결과 오염.
- **권고**: `let id = i as u8;` (idx 그대로 = ID 1-base), 그리고 `if id == 0 { continue; }` 추가. 또는 `for i in 1..NUM_JOINTS_IN_STEP { ... }` 루프 시작점 변경.

#### C3 — `walk::engine` 이 ROBOTIS 알고리즘과 동치 아님 (docstring 은 1:1 라고 광고)
- **위치**: `app/core/forge-core/src/walk/engine.rs:113-141`
- **근거**:
  - DarwinForge `WalkEngine::foot_targets()` 는 단일 `theta = 2π·t` 의 cos/sin 으로 좌/우 발을 단일 위상 차이 (sin(θ+π/2) vs sin(θ-π/2)) 로 생성.
  - ROBOTIS-OP2 `op2_walking_module.cpp:631-859` (`computeLegAngle`) 은 **6 segment 시간축** (`t ≤ l_ssp_start`, `t ≤ l_ssp_end`, `t ≤ r_ssp_start`, `t ≤ r_ssp_end`, else) 으로 분기하여 **swap.{x,y,z}** + **left_leg_move.{x,y,z,yaw}** + **right_leg_move.{x,y,z,yaw}** + **pelvis_offset_{l,r}** 를 `wSin(time, period, phase_shift, mag, mag_shift)` 호출 13개로 계산. 그리고 `calcInverseKinematicsForRightLeg` / `LeftLeg` 를 호출해 6 관절각을 푼다.
  - DarwinForge 의 `foot_targets()` 는 **IK 가 없다**. 그냥 (x,y,z) 위치만 반환한다. 후속 6 관절 변환 로직 부재.
  - `docs/architecture/walking-engine.md:74-79` 는 "역기구학으로 20관절 (사실상 다리 12관절) 목표 위치 계산" 명시. 그러나 코드에 IK 없음.
  - `walk::engine::engine.rs:1-3` docstring: "MVP: 다리 IK는 간단한 mapping. 실 IK는 후속 사이클." — 코드 자체는 MVP 라고 솔직하나, `docs/architecture/walking-algorithm-design.md` 와 `walking-engine.md` 는 "ROBOTIS 1:1 포팅" 으로 광고.
- **결과**: 만약 사용자가 `forge walk` 를 활성화하면 보행은 **ROBOTIS 와 전혀 다른 모션** 을 생성한다 — `wSin` swap/move 분리 없음, pelvis_offset 없음, arm_swing 없음, IMU sensoryFeedback 없음. 안전 평가가 ROBOTIS 기반이라면 가정이 무너진다.
- **권고**: walk::engine 의 docstring 에 "stub — 실 사용 금지" 명시. `forge walk` CLI 가 있다면 `--unsupported` 플래그 강제. ROBOTIS 알고리즘 포팅은 별도 sprint 로 분리. 동시에 walking-engine.md 의 "ROBOTIS 1:1" 표현을 "v1 stub, 실 ROBOTIS 동치는 Sprint X 후속" 로 약화.

---

### 🟠 High (정확성 또는 안전 게이트 누락)

#### H1 — `safety::self_collision::check_step` 가 docstring 의 5종 룰 중 **4종만** 구현
- **위치**: `app/core/forge-core/src/safety/self_collision.rs:7-12, 59-133`
- **근거**: docstring 은 5종 룰 광고: (1) knee hyperextension, (2) hip_roll, (3) shoulder_roll, (4) arm-head, (5) **hip_pitch > 90° + knee < 0 = 다리가 몸통과 충돌**. 그러나 코드 본문은 1-4 만 구현. 5번 (hip+knee 결합) 누락. `synth::validator::self_collision::SelfCollisionValidator` 는 thin wrapper 라 자동으로 룰 누락 영향 받음. ADR-014 D4 의 "rule 위반 = FAIL" 보장이 약화.
- **근거 보조**: PRD-001 §5.3 V3 "v1은 단순 휴리스틱 (joint pair ranges)" 는 정확한 룰 수를 명시 안 함, 그러나 docs/HARDWARE_VERIFICATION_PROTOCOL.md:36 은 **"5 종 룰 위반 없음"** 명시.
- **권고**: 5번 룰 추가 또는 docstring 4종으로 정정. **HighRisk 페이지가 추가 룰 없이 통과**할 수 있으므로 룰 누락은 안전 영향 큼.

#### H2 — V2 velocity 임계 (5.2 / 11.3 raw/ms) 의 **calibration 스크립트 부재**
- **위치**: `app/core/forge-core/src/synth/validator/velocity.rs:28-42`, `docs/HARDWARE_VERIFICATION_PROTOCOL.md:185-191`, `docs/reports/SPRINT_9_10_12_REPORT.md:212`
- **근거**: velocity.rs 는 "p99 = 4.74 raw/ms, max = 10.26 raw/ms (page 12 R_ANKLE_PITCH)" 를 인용하나, 이 측정을 만드는 **스크립트가 리포지토리에 없음**. `grep -r "raw/ms\|4\.74\|10\.26" /home/user/Darwin/scripts` → 0 hit. Sprint report 의 후속 작업 목록에 "Validator calibration (PRD §17.4) — V1/V2 임계를 실 robot 한계로 보정" 라고 후속 ToDo 로 명시 → 측정은 아직 안 한 상태인데 코드는 이미 측정값을 인용.
- **결과**: 임계가 사실상 매직 넘버. 실 robot 측정 없이 ROBOTIS 페이지를 기준으로 잡았다 하지만, 16 OFFICIAL_CATALOG vs 45 점유 페이지 중 어느 집합인지, 어떻게 추출했는지 추적 불가.
- **권고**: `scripts/calibrate_velocity.py` (또는 `forge-core` test integration) 추가 — `motion_4096.bin` 의 모든 페이지 step pair × 20 관절 의 raw_change / play_ms 분포를 출력. p99 / max 를 동적으로 인쇄하고 velocity.rs 의 상수와 비교하는 `#[cfg(test)]` integration test 추가. 또는 임계를 derived constant 로 만들고 위 fixture 데이터로부터 산출.

#### H3 — `joint::JointLimits::for_joint` 의 raw 한계가 ROBOTIS 공식 모션을 **거부**
- **위치**: `app/core/forge-core/src/joint/state.rs:98-124` + `synth::integration::pipeline_validator_failure_then_mutate_recovery` 의 주석 line 70-78 + `synth::integration::pipeline_sequence_kick_routine_with_manifest` line 249-251.
- **근거**: integration test 가 자체적으로 인정: "**kick 은 V1/V2 fail 가능** — ROBOTIS 데이터의 큰 진폭·빠른 변화 때문, PRD §17.4 후속 보강". 즉 **공식 ROBOTIS Page 12 (right kick) 가 DarwinForge 의 V1 (JointLimitValidator) 를 통과 못 한다.** 이는 모순 — ROBOTIS 공식 페이지가 robot 의 안전 한계를 초과한다면 한쪽 (DarwinForge 한계 or ROBOTIS 페이지) 이 틀린 것. 보통 ROBOTIS 공식 페이지가 정상 동작이므로 DarwinForge 한계가 보수적임을 의미.
- **결과**: HVP G1 게이트가 ROBOTIS reference 페이지 자체를 거부 → 사용자가 합리적 합성 (예: kick mutation) 시도 시 false-positive FAIL. Mutate 회복 패턴 (factor=0.0 으로 모든 관절을 중립으로) 도 부자연스러움.
- **권고**: `JointLimits::for_joint` 의 한계를 (a) `ini_pose.yaml` 의 양끝값 + 10% margin, 또는 (b) `motion_4096.bin` 의 16 OFFICIAL_CATALOG 모든 raw 값의 min/max + buffer, 중 하나로 dynamic 산출. 또는 V1 임계를 데이터 기반으로 자동 calibration 하고 hard-coded 보수값을 폐기.

#### H4 — `synth::ops::procedural::Curve::Bezier` 는 표준 cubic Bezier 가 **아님**
- **위치**: `app/core/forge-core/src/synth/ops/procedural.rs:121-128`
- **근거**: 코드 `(3.0 * one_t * one_t * x * p1.1 + 3.0 * one_t * x * x * p2.1 + x * x * x).clamp(0.0, 1.0)`. 이는 (a) y-좌표만 사용 (p1.0, p2.0 무시), (b) `(1-t)^3 * 0` 항 누락 (= 0 이지만 명시 안 됨), (c) `x` 를 그대로 t-축으로 사용. 표준 cubic Bezier 는 `B(t) = (1-t)^3·P0 + 3(1-t)^2·t·P1 + 3(1-t)·t^2·P2 + t^3·P3` 인데, 사용자가 (x,y) 컨트롤 포인트를 주는 것은 두 번 적분이 필요한 implicit form. 본 코드는 p1.0, p2.0 을 받지만 사용하지 않음.
- **결과**: 사용자가 CSS-style `cubic-bezier(0.4, 0, 0.2, 1)` 처럼 호출하면 x-축 컨트롤이 무시됨. ease 함수가 사용자 의도와 다르게 동작. PRD-001 §5.2 FR-OP-6 "함수 라이브러리: bezier(p1, p2)" — p1/p2 의 의미가 불명확하게 구현됨.
- **권고**: (a) 1D-Bezier 만 받음을 명시 (`p1: f32, p2: f32` 로 시그니처 변경), 또는 (b) CSS-style 2D cubic Bezier 의 t-축 numerical inversion (Newton-Raphson 또는 binary search) 추가. 현 상태 docstring 은 "0, p1, p2, 1 제어점" 으로 표현하나 p1, p2 는 4-tuple 인지 2-tuple 인지 모호.

#### H5 — `synth::ops::mirror::mirror_page` 가 모든 페이지에 무조건 `_mirror` 접미사 추가 (idempotent 깨짐 + safety 분류 처리 모호)
- **위치**: `app/core/forge-core/src/synth/ops/mirror.rs:142-153`
- **근거**: `name: format!("{}_mirror", page.name.trim_end_matches('\0').trim())` 라 mirror(mirror(page)) 의 이름은 `"foo_mirror_mirror"` 가 됨. `mirror_page_is_involution` 테스트 (line 259) 는 step.positions 만 비교하고 name 은 비교 안 함 → 회귀 안 잡힘. 추가로 `safety_class: page.safety_class` 로 그대로 전파하나, mirror 결과의 안전 분류가 원본과 다를 수 있는 경우 (예: 우측 단발 지지 페이지를 mirror 하면 좌측 단발 지지가 되는데 metadata.single_foot_ok 도 전파되어야 자연스러움) 를 처리 안 함.
- **결과**: mirror 두 번 하면 이름이 누적, 메타데이터 동기화 안 됨.
- **권고**: 이름이 이미 `_mirror` 로 끝나면 제거 (involution preserving name). `synth::library` 의 PageMetadata 도 mirror 시 mirror_pair 를 교환하는 helper 추가.

---

### 🟡 Medium (출처 / 인용 부족, 학술적 검증 안 됨)

#### M1 — `walk::imu::ComplementaryFilter` 의 게인 0.98 출처 부재
- **위치**: `app/core/forge-core/src/walk/imu.rs:18-35`
- **근거**: docstring "게인 0.98 = 자이로 weight, 0.02 = 가속도" — 출처 없음. complementary filter 의 표준 게인은 application-specific 이며, 100 Hz 샘플링 + DARwIn-OP IMU 의 typical bias 에서 0.98 은 합리적 default 이나 ROBOTIS 코드 어디에도 매칭 없음 (`op2_walking_module.cpp` 는 별도의 sensoryFeedback 함수에서 gyro_err × balance_gain 직접 적용, complementary filter 사용 안 함).
- **권고**: docstring 에 (a) "ROBOTIS 사용 안 함, DarwinForge 자체 보완" 또는 (b) 학술 출처 (예: "Smith 2012, complementary filter for legged robots, ω_c=0.5 rad/s, dt=10ms → α=0.98") 추가. 또는 dt 와 cut-off freq 에서 derived 로 만들기.

#### M2 — `walk::ini_pose::WALK_READY_MOV_STEPS = 750` 의 derivation 미인용
- **위치**: `app/core/forge-core/src/walk/ini_pose.rs:79-83`
- **근거**: `pub const WALK_READY_MOV_STEPS: usize = 750; // 6000 ms / 8 ms`. mov_time=6.0s (ini_pose.yaml) / control_cycle=8 ms = 750. control_cycle 출처는 OP2.robot:1 `control_cycle = 8`. 인라인 주석으론 충분하나 const 가 derived 임을 노출하면 더 안전.
- **권고**: `pub const CONTROL_CYCLE_MS: u64 = 8;` 와 `pub const WALK_READY_MOV_TIME_S: f64 = 6.0;` 를 별도 const 로 노출하고 `WALK_READY_MOV_STEPS` 는 `(WALK_READY_MOV_TIME_S * 1000.0 / CONTROL_CYCLE_MS as f64) as usize` 로 계산 (const fn 가능).

#### M3 — `safety::torque_ramp` 의 P_GAIN ramp `[0, 8, 16, 32]` × 200 ms 출처 부재
- **위치**: `app/core/forge-core/src/safety/torque_ramp.rs:46-51`
- **근거**: gentle profile docstring 은 "권장 default — 4 단계 800 ms 총. 첫 step P=0 = 무토크에서 TORQUE_ENABLE 켜기. 마지막 P=32 = 공식 default" — 마지막 P=32 는 param.yaml:20 와 일치. 그러나 중간값 8, 16 의 출처 / 측정 / 학술 근거 없음. ROBOTIS framework 는 P_GAIN ramp 를 자체적으로 안 함 — `op2_walking_module.cpp` 는 init 시 P_GAIN 을 한 번에 32 설정. ramp 자체는 DarwinForge 가 자체 추가한 안전 메커니즘.
- **권고**: docstring 에 "ROBOTIS 원본은 ramp 안 함 — DarwinForge 자체 추가 메커니즘, MX-28 PWM 가속 한계 (`MX-28T datasheet, max torque 24 V × 2.5 A = 60 W`) 기준 200 ms 분할" 같은 derivation 명시. 또는 실측 (`forge joint state` polling 으로 P_GAIN 변경 시 motor temperature / current spike) 기반.

#### M4 — `synth::validator::static_stability` 의 `MAX_HIP_PITCH_DIFF_RAW = 1700` 의 보수 margin 미인용
- **위치**: `app/core/forge-core/src/synth/validator/static_stability.rs:30-33`
- **근거**: "walkReady r=-65°/l=+65° 차이 130° ≈ raw 1480 → 약간 여유 1700" — "약간 여유" 의 정량적 기준 (15% margin? walkReady 외 다른 합법 자세는?) 모호. PRD-001 §5.3 V4 는 "CoM in support polygon" 명시하나 본 implementation 은 proxy 휴리스틱.
- **권고**: docstring 에 "양발 지지 자세 중 가장 큰 hip_pitch 차이를 보이는 페이지 (e.g., page 16 stand up 의 step 0) 의 측정값 + 15% buffer" 로 derivation 명시. 또는 measurement script 로 dynamic 산출.

#### M5 — `motion::library::OFFICIAL_CATALOG` "Sit Down" vs ROBOTIS 원본 "Sit downn" 차이
- **위치**: `app/core/forge-core/src/motion/library.rs:163-166`, `research/robotis-official/ROBOTIS-OP2/op2_gui_demo/config/gui_motion.yaml:6`
- **근거**: gui_motion.yaml 는 `Sit downn` (오타) / `Clap plaese` (오타) 으로 적힌 그대로. library.rs 는 "Sit Down" / "Clap Please" 로 **정정**. 정상적 UX 결정이나 "1:1 카탈로그" 원칙과 충돌. provenance 추적 시 어느 쪽이 ground truth 인지 모호.
- **권고**: docstring 에 "ROBOTIS 원본 오타는 정정. 원본은 'Sit downn', 'Clap plaese'" 명시. 또는 별도 `raw_name` 필드 추가 (이미 page-metadata-motion4096.toml 에는 `raw_name` 있음 — 코드에는 없음).

#### M6 — `docs/motion-format/page-format.md` 가 `> TODO: verify` 의 추측 layout 인데 `synth::library::decode_raw_page` 는 이미 확정 layout 사용
- **위치**: `docs/motion-format/page-format.md:25-49`, `app/core/forge-core/src/synth/library.rs:36-49`
- **근거**: page-format.md 는 "위 offset은 추정. Sprint 3 작업 시 `Framework/src/motion/Action.cpp`를 직접 읽고 확정한다." 라고 명시. 그러나 library.rs 는 `HEADER_OFFSET_REPEAT = 15, ... HEADER_OFFSET_SLOPE = 32, ...` 를 확정 offset 으로 사용. 두 문서 충돌. page-catalog-motion4096.md 는 더 정확한 offset 표 가짐.
- **권고**: page-format.md 를 page-catalog-motion4096.md 의 표 (정확 layout) 와 일치시켜 `> TODO` 마커 제거. 또는 page-format.md 를 deprecated 표시.

---

### 🟢 Low (스타일, 가독성, naming)

#### L1 — `walk::params::WalkParams::default()` 와 `walk::engine::WalkEngine::initialize` 의 단위 일관성 모호
- **위치**: `walk/params.rs:62-86`, `walk/engine.rs:113-141`
- **근거**: param.yaml 은 `period_time: 600` (cpp 의 `period_time * 0.001` 로 ms → s 변환). DarwinForge `period_time_ms: 600.0` 는 ms 단위 유지 (혼란 없음). 그러나 `swing_right_left: 0.020`, `swing_top_down: 0.005` 도 m 단위인데 engine.rs `foot_targets()` 는 `y_swing`, `z_swing` 을 m 단위로 직접 더한다. ROBOTIS cpp 의 IK 입력은 m, DarwinForge 도 m — 일치하나 단위 docstring 미상 unit comment 일관성 부족 (어떤 곳은 `(m)`, 어떤 곳은 unit 누락).

#### L2 — `synth::ops::mirror::reflect_12bit` 의 `MAX_POSITION` 상수가 `POSITION_MASK` 와 동값이라 헷갈림
- **위치**: `app/core/forge-core/src/synth/ops/mirror.rs:44-48`
- **근거**: `FLAG_MASK = 0xF000; POSITION_MASK = 0x0FFF; MAX_POSITION = 0x0FFF;` 둘 다 0x0FFF. 의미 (mask vs max) 는 다르나 값이 같음. `(MAX_POSITION - val) & POSITION_MASK` 는 의도 명확하나 중복.
- **권고**: 둘을 하나로 통합 (`POSITION_MAX_VALUE = POSITION_MASK = 0x0FFF`) 또는 const 의 도메인 의미 docstring 추가.

#### L3 — `joint::degrees_to_position` 의 ±180° 매핑이 round-down 으로 4095 도달 못 함
- **위치**: `app/core/forge-core/src/joint/mod.rs:190-198, 277-280`
- **근거**: `radians_to_position(PI)` = π × (2048/π) + 2048 = 4096 → clamp(4095). `radians_to_position(-PI)` = -2048 + 2048 = 0. 양 극단이 비대칭 (0 / 4095) — 의도된 동작이나 ±180° 가 같은 자세인지 다른 자세인지 docstring 부재.

#### L4 — `synth::ops::layer::region_for_slot(0)` 가 `Region::Other` 로 fall-through, fallback 으로 priority 첫 입력 사용
- **위치**: `app/core/forge-core/src/synth/ops/layer.rs:158-219`
- **근거**: slot 0 (unused) 에 대해 `pick_region_value` 는 priority 첫 입력 step 의 positions[0] 을 채택. fixture 들이 slot 0 = 0x4000 INVALID 라 결과적으로 mostly OK 이나, 정상적인 페이지가 slot 0 에 의미 있는 값을 넣었다면 Layer 결과에 leak. 사소함.
- **권고**: `region_for_slot(0) => Region::Reserved` 신설하고 무조건 INVALID flag (0x4000) 출력하도록 변경. byte-preserving 원칙과 더 부합.

---

## 잘 한 점 (간결)

- **byte-preserving round-trip 검증** (`motion::bin4096::tests::round_trip_official_bin_is_byte_identical`, line 181-190): `include_bytes!` 로 ROBOTIS 공식 `motion_4096.bin` (131,072 byte) 임베드 후 parse → write → 바이트 동일 비교. 강력한 진리값.
- **walk::ini_pose::WALK_READY_DEGREES** (`walk/ini_pose.rs:18-39`) 는 ROBOTIS `ini_pose.yaml:36-56` 의 20 entry 와 **각도·순서 line-by-line 1:1**. unit test `walk_ready_critical_angles_match_yaml` 가 회귀 검출.
- **safety::self_collision::check_step** 는 indexing 규약을 docstring (line 58) 에서 **명시적으로 선언** 하고 그대로 따른다 — 코드베이스 내 유일하게 정확.

---

## 권고 후속 작업 우선순위 (P0~P3)

- **P0 (블로커, 즉시 fix)**: 
  - **C1 mirror.rs off-by-one 정정** — `(right_id - 1)` → `right_id`, head_pan idx 정정, compliance swap idx 정정. fixture 기반 회귀 테스트 추가 (`mirror_swaps_id3_and_id4_compliance_byte_exact`).
  - **C2 library.rs::infer_body_regions off-by-one 정정** — `let id = (i + 1)` → `let id = i`, slot 0 skip.

- **P1 (안전성 / 정확성, 다음 sprint)**:
  - **H1 self_collision 5번 룰 (hip_pitch + knee) 구현** 또는 docstring 4종으로 정정.
  - **H2 velocity calibration script 추가** — `scripts/calibrate_v2_velocity.py` (또는 `tests/calibration.rs`) 가 OFFICIAL_CATALOG p99 / max 를 dynamic 산출 + velocity.rs 상수와 어긋나면 fail.
  - **C3 walk::engine docstring "stub" 마커** — 사용자 / Claude CLI 가 미완성 알고리즘인 줄 알도록.

- **P2 (정확성 보강)**:
  - **H3 JointLimits dynamic calibration** — ROBOTIS 16 OFFICIAL_CATALOG raw min/max + 10% margin 으로 자동 산출.
  - **H4 Bezier 시그니처 명료화** 또는 CSS-style 2D inversion 구현.
  - **H5 mirror_page name involution + metadata mirror_pair swap helper**.
  - **M3 torque_ramp 출처 명시** — MX-28 datasheet 또는 측정.

- **P3 (문서화 / 가독성)**:
  - **M1 complementary filter α=0.98 derivation 또는 cut-off freq 명시**.
  - **M2 WALK_READY_MOV_STEPS 를 control_cycle 과 mov_time 으로 const fn 산출**.
  - **M5 OFFICIAL_CATALOG 에 raw_name 필드 추가** (page-metadata-motion4096.toml 의 raw_name 과 일치).
  - **M6 page-format.md 의 `> TODO: verify` 마커 제거** + page-catalog-motion4096.md 와 동기화.
  - **L1~L4 스타일 정리**.

---

## 부록 A — 인덱싱 규약 매트릭스

`positions[31]` 배열에서 idx i → JointID 매핑이 코드베이스에 두 가지 다른 규약 존재:

| 위치 | 규약 | 정확성 |
|------|------|--------|
| `safety::self_collision::check_step` | `positions[i] = ID i` (1-indexed, slot 0 unused) | ✓ 정확 |
| `synth::validator::joint_limit` | `positions[i] = ID i` | ✓ 정확 |
| `synth::validator::velocity` | `positions[i] = ID i` | ✓ 정확 |
| `synth::validator::static_stability` | `positions[JointId::RHipPitch as usize]` = positions[11] = ID 11 | ✓ 정확 |
| `synth::ops::layer::region_for_slot` | `1..=6 → Upper, 7..=18 → Lower, 19..=20 → Head` | ✓ 정확 |
| `forge-cli::motion_play::step_to_targets` | `for slot in 1..=20 { positions[slot] }` | ✓ 정확 |
| **`synth::ops::mirror::MIRROR_PAIRS`** | **`r_idx = (id - 1)`** | **✗ 오류 (C1)** |
| **`synth::library::infer_body_regions`** | **`let id = (i + 1)`** | **✗ 오류 (C2)** |

binary 출처: `motion_4096.bin` page 9 walkready step 0 raw bytes (offset 64-): `00 40 da 05 d6 09 35 07 c8 08 ...`. 첫 uint16 LE = `0x4000` (positions[0]) = INVALID; 두 번째 uint16 = `0x05da` = 1498 = degrees_to_position(-48°) ≈ ID 1 R_SHOULDER_PITCH. **positions[i] = ID i 확정**.

---

## 부록 B — 감사 metadata

- 감사 대상 파일 (소스): walk/{params,engine,imu,ini_pose,mod}.rs, motion/{page,bin4096,parser,writer,library,mod}.rs, joint/{map,state,mod}.rs, synth/{mod,error,library,metadata,provenance,test_fixtures,integration}.rs + ops/{mirror,sequence,morph,mutate,procedural,layer,mod}.rs + validator/{joint_limit,velocity,self_collision,static_stability,mod}.rs, safety/{self_collision,torque_ramp,mod}.rs, forge-cli/motion_play.rs. 합계 ~30 파일.
- 감사 대상 문서: docs/prd/motion-synthesis-v1.md, docs/decisions/ADR-014, docs/architecture/{walking-engine,joint-conventions}.md, docs/motion-format/{page-format,page-catalog-motion4096}.md + page-metadata-motion4096.toml, docs/HARDWARE_VERIFICATION_PROTOCOL.md, docs/reports/SPRINT_9_10_12_REPORT.md.
- ROBOTIS 1차 출처: `research/robotis-official/ROBOTIS-OP2/op2_walking_module/{config/param.yaml, src/op2_walking_module.cpp, include/}`, `op2_manager/config/{ini_pose.yaml, motion_4096.bin, OP2.robot}`, `op2_gui_demo/config/gui_motion.yaml`.
- 테스트 실행 결과: `cargo test -p forge-core --lib walk` → 27 passed; `cargo test -p forge-core --lib synth::ops::mirror` → 12 passed (그러나 C1 로 인해 의미적 정확성과 무관하게 통과).
