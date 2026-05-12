# Walk Lab — 커뮤니티 보행 reference

> Sprint 5 walk-engine + Walk Lab 튜닝의 reference 모음. 각 알고리즘 / 파라미터의
> **출처 · 라이선스 · 우리 적용 방식**을 묶어 둔다. 코드 / 패치 본문은 원 저장소 위치에서
> 읽고, 우리 Rust 재구현은 알고리즘만 인용.
>
> 갱신: 2026-05-12.
> 자매 문서: [`V1_DESIGN.md`](V1_DESIGN.md) — 8 프리셋, 안전 게이트 / [`docs/motion-format/EXTERNAL_MOTION_LIBRARIES.md`](../motion-format/EXTERNAL_MOTION_LIBRARIES.md) — 페이지 라이브러리.

## 0. reference 분류

| 출처 | 라이선스 | 우리 적용 방식 |
|------|----------|---------------|
| `research/robotis-official/ROBOTIS-OP2/op2_walking_module/` | Apache 2.0 | **1차 reference** — 직역 + Mac 추상 |
| `research/community/darwinop-ens-darwin-op/Framework/src/motion/modules/Walking.cpp` | Apache 2.0 | OP1 정본 — OP2 와 비교용 |
| `research/community/nimbro-op/software/patches-essential/0012-Walking-tuned-for-NimbRo-OP.patch` | BSD-3 | **알고리즘 인용** — smooth start, spline pitch balance |
| `research/community/nimbro-op/software/patches-essential/0010-Simple-angle-estimator.patch` | BSD-3 | **알고리즘 인용** — complementary filter |
| `research/community/nimbro-op/software/patches-essential/0016-Fall-protection-implementation.patch` | BSD-3 | **알고리즘 인용** — fall recovery 트리거 |
| `research/community/_gpl-isolated/HROS5-Framework/.../Walking.cpp` | GPL v3 | **❌ 코드 인용 금지** — 알고리즘 학습만 |

## 1. ZMP LIPM 보행 — 코어 알고리즘

ROBOTIS DARwIn-OP framework 의 `Walking::Process()` 가 사실상 모든 OP/OP2 보행의 reference.
한 사이클의 흐름:

```
1. 위상 (m_Time) 진입 — period_time 기반.
2. 양발 좌표 (m_X_*, m_Y_*, m_Z_*) 를 cosine 보간으로 산출.
3. Kinematics 역기구학 → 각 다리 6-joint 각도.
4. 자세 보상 (balance_*_gain, lean_*_gain) — IMU pitch/roll 융합.
5. 팔 스윙 (arm_swing_gain) — 보행 phase 와 반대 위상.
6. Sync_Write → 모든 관절 동시 송출.
```

| 구현 위치 | 참고 |
|-----------|------|
| `research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp` | ROS 노드 wrapper |
| `research/robotis-official/ROBOTIS-OP2/op2_walking_module/config/param.yaml` | 기본 파라미터 (period_time=600 등) — Walk Lab 프리셋 기준 |
| `research/community/darwinop-ens-darwin-op/Framework/src/motion/modules/Walking.cpp` | 비-ROS 풀 구현 (OP1, ~600 라인) |

## 2. 파라미터 — 출처별 비교

| 파라미터 | ROBOTIS-OP2 (기본) | darwinop-ens (OP1 기본) | NimbRo (TeenSize 튜닝) | Walk Lab 권장 |
|----------|--------------------:|------------------------:|----------------------:|---------------|
| `period_time` (ms) | 600 | 600 | **900** (큰 관성) | OP1/OP2: 600. fastWalk 프리셋: 500 |
| `dsp_ratio` | 0.10 | 0.10 | 0.10 | 동일 |
| `step_forward_back_ratio` | — | 0.28 | 0.26 | 0.26~0.28 |
| `foot_height` (mm) | 40 | 40 | **120** | 40 유지 (OP1/OP2) |
| `swing_right_left` | 30 | 30 | 1.4 (다른 단위계) | 30 |
| `swing_top_down` | 0 | 0 | 0 | 0 |
| `arm_swing_gain` | 1.5 | 1.5 | 1.5 | 1.5 |
| `pelvis_offset` (deg) | 0 | 5.0 | 0 | 0~5 (실측 캘리브레이션) |
| `hip_pitch_offset` | 13 | 13 | **2.5** | 13 (OP1/OP2) |
| `y_offset` (mm) | 30 | 30 | **55** | 30 |
| `z_offset` (mm) | 30 | 30 | 10 | 30 |
| `lean_fb_gain` | 0 | 0 | **5.0** | 0 → 안정성 부족 시 1~5 시도 |
| `balance_knee_gain` | 0.3 | 0.3 | 0 | 0.3 |
| `balance_ankle_pitch_gain` | 0.9 | 0.9 | 0 | 0.9 |
| `balance_hip_roll_gain` | 0.5 | 0.5 | 0 | 0.5 |
| `balance_ankle_roll_gain` | 0.3 | 0.3 | 0 | 0.3 |
| `balance_angle_smooth_gain` | 없음 | 없음 | **0.91** (LPF) | **NimbRo 알고리즘 인용** — IMU 각도 1차 LPF |
| `balance_angle_gain` | 없음 | 없음 | **0.10** | 0.10 |
| `p_gain` / `i_gain` / `d_gain` | 32/0/16 | 32/0/16 | 50/0/0 | 32/0/16 (스톡) |
| `start_step_factor` | — | — | 1.0 (smooth start) | **알고리즘 인용** — 첫 step amplitude 점진 증가 |

## 3. NimbRo 핵심 contribution — 우리 Rust 재구현 가이드

### 3-A. Smooth start (patch 12, `Walking.cpp` ramp 로직)

- 보행 시작 시 첫 N 사이클 (~3) 동안 step amplitude 를 0 → 1 로 선형/spline 증가.
- 효과: 정지 → 보행 진입 시 관성 충격 감소, 첫 step 에서 넘어지는 사례 제거.
- 적용: 우리 `walk::engine` 의 `start()` 호출 후 `m_Phase * start_step_factor` 보정.

### 3-B. Spline pitch balance (patch 12, `QuadraticStateTransform.cpp` 신규)

- IMU pitch 측정 → 다음 step 까지의 시간을 quadratic 으로 보간 → 컬렉티브 ankle pitch 보상.
- 알고리즘: `output = a·t² + b·t + c`, target=measured.pitch, t=remaining_phase.
- 효과: 단순 P 게인 보다 oscillation 적음.
- 적용: 우리 `walk::balance::QuadraticStateTransform` 모듈로 구현 (Rust no-std).

### 3-C. Complementary filter (patch 10, `AngleEstimator.h` 신규)

- 자이로 적분 + 가속도 중력 벡터 → 1차 LPF 융합.
- 공식: `angle_t = α · (angle_{t-1} + gyro·dt) + (1-α) · acc_angle`, α ≈ 0.95.
- 적용: 우리 `imu::AngleEstimator` (Rust no-std) — `MotionStatus::FB_GYRO` 대체.

### 3-D. Fall protection (patch 16)

- 매 사이클 IMU pitch/roll 절대값 측정.
- |pitch| > 60° 또는 |roll| > 60° → Walking::Stop() + Action::Start(page=10 or 11) 자동 호출.
- 자세 → 페이지 매핑:
  - pitch > +60°: page 10 (`f up` — 앞으로 넘어진 상태에서 복귀)
  - pitch < -60°: page 11 (`b up` — 뒤로 넘어진 상태에서 복귀)
- 적용: 우리 `safety::FallGuard` 가 `MotionManager` tick 마다 임계값 검사 + 자동 dispatch.

### 3-E. MotionManager torque mask (patch 7)

- 페이지 실행 중에도 개별 관절 torque ON/OFF 가능.
- 사용 사례: 보행 중에도 머리는 별도 제어, 또는 부상 관절 OFF 후 안전 보행 계속.
- 적용: 우리 `motion::TorqueMask = [bool; 20]` 비트마스크. `Sync_Write` 시 마스크 통과한 관절만.

## 4. Action Editor 좌우 미러 — 보행에도 적용

NimbRo `patches-optional/0024-ActionEditor-added-fuction-to-apply-mirrored-pages.patch`:
- Action 페이지 좌우 미러 자동 생성 — `R_*` ↔ `L_*` 짝 교환.
- 보행 페이지 (walkready, walk-forward 등) 의 좌우 대칭 검증에 유용.

우리 `forge-cli synth mirror` (Sprint 9~13) 가 직접 대응. 자세히 →
[`docs/motion-format/EXTERNAL_MOTION_LIBRARIES.md §6`](../motion-format/EXTERNAL_MOTION_LIBRARIES.md).

## 5. Walk Lab 통합 — 외부 reference 적용 흐름

| Walk Lab 프리셋 | 영향 받는 외부 reference | 동작 |
|-----------------|---------------------------|------|
| `idle` | — | 모터 idle |
| `march` (제자리) | 스톡 OP2 params, NimbRo smooth start | 첫 3 사이클 amplitude ramp |
| `slowWalk` (천천히) | 스톡 OP2 params + complementary filter (IMU) | period=600, x_amp=15mm |
| `normalWalk` | 동일 | x_amp=25mm |
| `fastWalk` | period=500, NimbRo lean_fb_gain=2 | **Caution** — 30s 자동 cool-down |
| `jog` (달리기) | period=450, balance_angle_smooth_gain LPF | **HighRisk** confirm + 15s |
| `turnLeft` / `turnRight` | spline pitch balance | dsp_ratio 동일 |
| `backward` | spline pitch balance + fall protection 강화 | rear lean 보정 |

## 6. fall protection 와 페이지 라이브러리

- 우리 페이지 라이브러리는 page 10 (`f up`) / 11 (`b up`) 를 보존 — `darwinop-ens` 정본 그대로.
- Walk Lab 의 모든 보행 프리셋이 fall protection 활성. 임계값 초과 시 page 10/11 자동 호출.
- 사용자에게는 "보호 동작 발생" 토스트 + 1 회 acknowledge 후 cradle 점검 권고.

## 7. 검증 흐름 (Sprint 5 → Sprint 6)

1. **시뮬** — `WalkSimView` 의 sin 파 baseline → ZMP LIPM 모델로 교체. 파라미터 슬라이더 → 발 trail 실시간 갱신.
2. **dry-run** — 실 모터 미연결 상태에서 forge-core `walk::engine` 의 sync-write 패킷을 capture & verify.
3. **cradle** — 거치 상태에서 idle/march 만. fall protection 동작 확인.
4. **slow walk** — 평평한 매트, period=700 (보다 안전), 5 step 후 정지.
5. **normal walk** — period=600.
6. **fastWalk / jog / backward** — 위험 등급 confirm 후만.

## 8. 추가 reference (Phase 1 미수집)

| 후보 | 가치 | 우선순위 |
|------|------|----------|
| `darwinop-ens/kinematics` | OP1 정확 DH 파라미터 — Sprint 5 IK 검증 | 중 |
| UPennalizers Lua walk engine | Hong et al. 의 OP 보행 알고리즘 변형 | 낮 |
| Hambot Springer 논문 | TeenSize 변형 RoboCup | 낮 |
| Webots DARwIn-OP 빌트인 | 시뮬레이션 cross-check | 중 (Sprint 5+) |
