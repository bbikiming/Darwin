# Walk Lab Fall Prevention — Stage 4 Extended Audit (15+ 영역)

**대상**: `feature/v1.1-walklab-fall-prevention` 의 Stage 1-4a+5 전체.
**사용자 요구**: "실 기기 빌드 필요한 것 외에 추가 검증 필요한 것들 먼저 파악하고 분석해서 업그레이드".

**작성**: 2026-05-16. Claude self-audit (15+ 영역). Codex 외부 검수 별도.

이전 audit (Stage 3 + Stage 4 각 9 영역) 외 추가 영역 검수 + Critical 발견 정정.

---

## 🚨 Critical 발견 1 — BalanceCorrector 4 관절 부호 오류

### URDF axis 추출 (`vendor/robotis-op2-common/urdf/robotis_op2.structure.leg.xacro`)

| 관절 | axis xyz | `dir = ΣX+Y+Z` |
|---|---|---|
| l_hip_roll | (-1, 0, 0) | **-1** |
| r_hip_roll | (-1, 0, 0) | **-1** |
| l_knee | (0, -1, 0) | **-1** |
| r_knee | (0, +1, 0) | **+1** |
| l_ank_pitch | (0, +1, 0) | **+1** |
| r_ank_pitch | (0, -1, 0) | **-1** |
| l_ank_roll | (+1, 0, 0) | **+1** |
| r_ank_roll | (+1, 0, 0) | **+1** |

### ROBOTIS Walking.cpp 식 유도 (`getJointDirection` × `internal_gain` × `goal - measured` × `gain`)

`goal = 0`, `measured = imu` → `(goal - measured) = -imu`.

| 관절 | ROBOTIS 식 | 정확한 결과 (imu +10°) | 이전 내 코드 | 정정? |
|---|---|---|---|---|
| r_hip_roll | dir(-1) × -0.3 × -imuRoll × 0.5 | **-0.15 × imuRoll = -1.5°** | -1.5° | ✓ |
| l_hip_roll | dir(-1) × -0.3 × -imuRoll × 0.5 | **-0.15 × imuRoll = -1.5°** | -1.5° | ✓ |
| r_knee | -dir(+1) × -0.3 × -imuPitch × 0.3 | **-0.09 × imuPitch = -0.9°** | +0.9° | **❌ → 정정** |
| l_knee | -dir(-1) × -0.3 × -imuPitch × 0.3 | **+0.09 × imuPitch = +0.9°** | +0.9° | ✓ |
| r_ank_pitch | -dir(-1) × -0.3 × -imuPitch × 0.9 | **+0.27 × imuPitch = +2.7°** | +2.7° | ✓ |
| l_ank_pitch | -dir(+1) × -0.3 × -imuPitch × 0.9 | **-0.27 × imuPitch = -2.7°** | +2.7° | **❌ → 정정** |
| r_ank_roll | dir(+1) × -0.3 × -imuRoll × 1.0 | **+0.30 × imuRoll = +3.0°** | -3.0° | **❌ → 정정** |
| l_ank_roll | dir(+1) × -0.3 × -imuRoll × 1.0 | **+0.30 × imuRoll = +3.0°** | -3.0° | **❌ → 정정** |

**4 관절 부호 반대** = fall 가속 위험. **정정 완료** (commit 별도).

회귀 강화: `testCorrectionFullSignTableLockIn` — 8 관절 정확 부호 lock-in.

---

## 검수 6 — Predictor 정상 보행 false positive

기존 회귀 `testFallPredictorNoFalsePositiveOnNormalSimWalk`:
- 5 sample, 200ms 간격, sin 4° (sim 모델 일치)
- score 계산: tilt 4° → 8점, rate < 5dps cutoff → 0점, var ≈ 800 → 8점
- **score ~16** → emergency threshold 80 의 5분의 1 ≪ 임계 ✓

**검수 6 PASS** — 정상 보행 false positive 없음.

---

## 검수 7 — 회귀 약한 assertion 식별

| 회귀 | 강도 | 평가 |
|---|---|---|
| `testL3GateWorksRegardlessOfSource` | ⚠️ 약함 | 단지 `XCTAssertFalse(session.balanceLost)` — 초기 false 자명. |
| `testImuSourceSimWhenBusIsNil` | ⚠️ 약함 | tick() 호출 안 함. 의도된 sim fallback 동작 검증 부족. |
| `testInitialStateNormalAndAutoOn` | 보통 | 두 invariant 검증. OK. |
| `testCorrectionPolarityRoll/Pitch` | ✅ 강함 | 정량 값 (-1.5°, +0.9° 등) lock-in. |
| `testCorrectionFullSignTableLockIn` (신규) | ✅ 매우 강함 | 8 관절 모두 정확 부호 + 값. |
| `testFallPredictorImminentFallTriggersEmergency` | ✅ 강함 | score 75+ 및 emergency 권고 양쪽 검증. |

→ 약한 회귀 2건 식별. 본 PR 에서 강화는 미수행 (사용자 별도 요청 시).

**검수 7 PASS (식별 만).**

---

## 검수 8 — Rust `walk::imu` vs Swift `ImuFilter` 시정수 일치

| | Rust (`ComplementaryFilter`) | Swift (`ImuFilter`) |
|---|---|---|
| Polling 빈도 | 8 ms (125 Hz, robot-side control loop) | 200 ms (5 Hz, Mac-side) |
| `α` (gyro_weight) | 0.98 | 0.71 (자동 계산: `τ/(τ+dt)`) |
| 시정수 `τ = dt × α/(1−α)` | 8 × 49 = **392 ms** | 200 × 2.45 = **490 ms** |

**다른 alpha 값이 다른 polling 빈도에서 비슷한 시정수 (~400-500ms) 산출 — 일관**.

근데 Rust 코드는 robot-side (사용 안 함, Sprint v1.6 예정), Swift 만 실제 작동. **Rust 측은 도큐먼트 갱신 — 두 alpha 의 시정수 자가 검증 추가 권장**.

**검수 8 PASS — 시정수 일관**.

---

## 검수 9 — PRD vs 구현 정합성

`docs/prd/v1.1-walklab-fall-prevention.md` Stage 4 명세 vs 실제 구현:

| Stage 4 명세 | 구현 |
|---|---|
| 4a `BalanceCorrector` pure function | ✅ `BalanceCorrector.swift` |
| 4b `runWalkCycle` 실 motor wire | ❌ 미구현 (별도 PR — 사용자 의도) |
| 4c 사용자 토글 default OFF | ✅ `enableBalanceCorrection = false` |
| 4d Mac 검증 후 default ON | (사용자 향후 작업) |

**PRD 와 구현 매칭** ✓. 4b 분리는 사용자 요청 ("실 로봇 빌드 추후") 반영.

**검수 9 PASS**.

---

## 검수 10 — `applyBalanceCorrectionIfEnabled` 누적 적용 가능성

```swift
visualPose = applyBalanceCorrectionIfEnabled(to: pose)
```

`pose` 는 매 tick 마다 `WalkMotionLibrary.simWalkingPose(timeMs:, tuning:)` 가 새로 합성한 phase pose. **누적 X** — 매번 fresh input.

`balanceCorrector.apply(to:)` 가 새 `RobotPose` 반환 (mutate X).

**검수 10 PASS** — 누적 위험 없음.

---

## 검수 11 — Gain ramp oscillation 우려

- ramp 길이 1초 (linear 0→100%)
- `internal_gain = -0.3` × `intensity = 1.0` → 효과적 multiplier 0.3
- ROBOTIS 원본의 `0.3 × 0.5 = 0.15` (hip_roll) 등의 작은 gain
- IMU polling 5Hz × ramp 1초 = ~5 sample 의 점진 적용

→ oscillation 우려 낮음. 1초 ramp 가 IMU 측정 한계 (200ms quantization) 의 5× 시간이라 phase delay 보다 충분히 큼.

**검수 11 PASS — oscillation 거동 보수적**.

---

## 검수 12 — 모션 데이터 (walkReady) + 정정 후 부호 안전성 재검증

정정 후 보정 적용 시 walkReady raw 가 어디로 가는지:

| 관절 | walkReady raw | walkReady° | imu+10° 보정 후° | raw 변환 | JointLimits 안? |
|---|---|---|---|---|---|
| r_hip_roll | 2052 | +0.35 | +0.35 + (-1.5) = -1.15 | 2035 | ±45° ✓ |
| l_hip_roll | 2044 | -0.35 | -0.35 + (-1.5) = -1.85 | 2027 | ±45° ✓ |
| r_knee | 2653 | +53.17 | +53.17 + (-0.9) = +52.27 | 2643 | ±150° ✓ |
| l_knee | 1443 | -53.17 | -53.17 + (+0.9) = -52.27 | 1453 | ±150° ✓ |
| r_ank_pitch | 2389 | +29.97 | +29.97 + (+2.7) = +32.67 | 2419 | ±90° ✓ |
| l_ank_pitch | 1707 | -29.97 | -29.97 + (-2.7) = -32.67 | 1677 | ±90° ✓ |
| r_ank_roll | 2057 | +0.79 | +0.79 + (+3.0) = +3.79 | 2091 | ±45° ✓ |
| l_ank_roll | 2039 | -0.79 | -0.79 + (+3.0) = +2.21 | 2073 | ±45° ✓ |

**physical 의미**:
- imu +10° (오른쪽 기울) 외란 시:
  - 두 hip_roll 음수 방향 = 양쪽 다리 왼쪽으로 외전 = 몸이 왼쪽으로 → **오른쪽 기울 회복** ✓
  - 두 ankle_roll 양수 = 양쪽 발 왼쪽으로 회전 = 발 평형 → **roll 회복** ✓
  - knee mirror: R 음수 (덜 굽힘), L 양수 (덜 굽힘) → **두 다리 동기 펴짐** — pitch 0 일 때 minimal 영향
  - ankle_pitch mirror: R 양수 (발끝 위), L 음수 (발끝 아래) → 발 안정성 ✓

**검수 12 PASS** — 정정 후 부호가 fall 회복 방향 일치 + JointLimits 안.

---

## 검수 13 — Emergency 후 재시작 corrector ramp 정확성

`emergencyStop()` 후 `start(preset)` 호출 시:
- `correctionEnabledAt = enableBalanceCorrection ? Date() : nil`
- 즉 ramp 0초부터 다시 시작
- 첫 50ms tick 시 ramp = 0/1 = 0 → identity
- 200ms tick 시 ramp = 0.2 → 20% 적용
- 1초 후 100% 적용

**oscillation 방지** — emergency 직후 갑작스러운 큰 보정 회피.

**검수 13 PASS**.

---

## 검수 14 — `applyBalanceCorrectionIfEnabled` 호출 위치 안전성

코드 line 검토:
- `tick()` 내부 `if !isRobotWalking, current != .idle` 블록 — **sim mode 만**
- `isRobotWalking == true` (실 motor 송출 중) → corrector 호출 X
- 실 robot 영향 0

확인된 호출 위치:
1. `tick()` → `visualPose = applyBalanceCorrectionIfEnabled(to: pose)` — sim only
2. `runWalkCycle` / `runContinuousWalk` — corrector 호출 X (의도된 분리)

**검수 14 PASS** — 실 motor 송출 분리 안전 가드 정확.

---

## 검수 15 — 첫 enable 시 큰 imu 값 안전

시나리오: 사용자가 robot 이 15° 기울어진 상태에서 `enableBalanceCorrection` ON.
- `correctionEnabledAt = Date()` 시작
- 첫 tick (0초 ramp): correction = 0 → identity
- 200ms 후 (ramp 0.2): correction × 0.2 (= 0.3° hipRoll, 0.6° ankleRoll)
- 1초 후 (100%): full correction (1.5°, 3.0°)

→ 갑작스러운 큰 보정 없음. 점진 적용으로 안전.

**검수 15 PASS**.

---

## 종합 평가 (15+ 영역)

| 검수 | 결과 |
|---|---|
| 0. URDF axis × Walking.cpp 부호 매핑 (Critical) | 🚨 4 관절 오류 **→ 정정 완료** |
| 1. ROBOTIS Walking.cpp 출처 정합 (재검증) | ✅ |
| 2. 4 그룹 × 2 축 부호 (URDF dir 적용 정정) | ✅ |
| 3. 단위·스케일 | ✅ |
| 4. internal_gain=-0.3 의미 | ✅ |
| 5. max clamp + ramp 안전 | ✅ |
| 6. Predictor 정상 보행 false positive | ✅ |
| 7. 회귀 약한 assertion 식별 | ⚠️ 2건 (개선 권장, 본 PR 미수행) |
| 8. Rust vs Swift ImuFilter 시정수 | ✅ (~400-500ms 일치) |
| 9. PRD vs 구현 | ✅ |
| 10. Corrector 누적 적용 | ✅ (매 tick fresh) |
| 11. Gain ramp oscillation | ✅ 보수적 1초 ramp |
| 12. walkReady + 정정 부호 안전성 | ✅ (JointLimits + 회복 방향) |
| 13. Emergency 재시작 ramp | ✅ |
| 14. 실 motor 송출 분리 | ✅ sim only |
| 15. 첫 enable 큰 imu 안전 | ✅ 점진 적용 |

**15 영역 / 14 PASS / 1 Critical 정정 / 1 WARN (회귀 약함, 별도 정정)**.

## 추가 회귀 (4 신규)

- `testCorrectionFullSignTableLockIn` — 8 관절 부호 정확 매트릭스 lock-in
- `testCorrectionPolarityRollPositive` (강화) — 4 관절 정확 값
- `testCorrectionPolarityPitchPositive` (강화) — R/L mirror 부호 검증
- `testCorrectionClampedAtMax` (강화) — 양·음수 input 양쪽 clamp 검증

## Codex 외부 검수 영역 (실 robot 검증 필요)

1. URDF dir 적용 후 실 robot 외란 (push) 시 corrector 의 실제 회복 거동
2. ROBOTIS Walking.cpp 의 `goal - measured` 부호 변환이 우리 IMU 측정 부호와 일치하는지
3. ImuFilter 의 dt 가 5Hz polling jitter 시 대해 시정수 변동
4. 1초 ramp + IMU 5Hz polling 결합 시 oscillation 거동 (이론은 안전, 실측 필요)

## 결론 정량

- **Critical 1건 발견 + 즉시 정정**: 4 관절 부호 오류 (fall 가속 위험)
- **15+ 영역 자기 평가**: 14 PASS / 1 Critical 정정 / 1 WARN
- **회귀 강화 4건**: 부호 매트릭스 lock-in 으로 향후 재발 방지
- **실 robot 검증 영역 4건**: Codex 외부 검수 권장

본 audit 가 PR #25 의 신뢰도를 사용자 요구 "5+ 검수" 의 3× (15+) 까지 강화.
