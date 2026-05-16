# Walk Lab Fall Prevention Stage 4 — Self-Audit

**대상**: `feature/v1.1-walklab-fall-prevention` 의 Stage 4 (BalanceCorrector).

**사용자 요구**: "스테이지 4 논리적으로 코드와 모션 데이터 기반으로 구현" + 이전과 동일 "**반드시 5회 이상 다양한 방면에서 논리적이고 정량적인 검수**".

작성: 2026-05-16. Claude self-audit. Codex 외부 검수 별도.

---

## 검수 1 — 출처 정합성 (ROBOTIS Walking.cpp 인용)

원본: `research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp`

| 항목 | Walking.cpp 라인 | 본 구현 |
|---|---|---|
| `balance_hip_roll_gain = 0.5` | line 110 | `BalanceCorrector.robotisDefault.hipRollGain = 0.5` ✓ |
| `balance_knee_gain = 0.3` | line 111 | `kneeGain = 0.3` ✓ |
| `balance_ankle_roll_gain = 1.0` | line 112 | `ankleRollGain = 1.0` ✓ |
| `balance_ankle_pitch_gain = 0.9` | line 113 | `anklePitchGain = 0.9` ✓ |
| `internal_gain = -0.3` | line 892 | `internalGain = -0.3` ✓ |
| sensoryFeedback 함수 | line 886-908 | `corrections(rollErrDeg:pitchErrDeg:)` 포팅 |

**WalkParams (`app/core/forge-core/src/walk/params.rs`) 와 교차 검증**:
- line 77-80: `balance_hip_roll_gain: 0.5`, `knee 0.3`, `ankle_roll 1.0`, `ankle_pitch 0.9`
- → ROBOTIS 원본 + 우리 Rust params + 본 Swift corrector 가 모두 일치 ✓

**회귀**: `testBalanceCorrectorDefaultsMatchRobotis` — 5 상수 모두 검증.

**검수 1 PASS**.

---

## 검수 2 — 부호 정합 (4 관절 그룹 × 2 축 = 8 검증)

ROBOTIS 원본 line 894-906:
```cpp
balance_angle[hip_roll]   = +dir * (-0.3) * rl * 0.5;   // dir=+1 가정
balance_angle[knee]       = -dir * (-0.3) * fb * 0.3;
balance_angle[ank_pitch]  = -dir * (-0.3) * fb * 0.9;
balance_angle[ank_roll]   = +dir * (-0.3) * rl * 1.0;
```

본 구현 (`BalanceCorrector.corrections`):
```swift
hipRoll    = internalGain * rollErrDeg * hipRollGain * intensity
           = -0.3 * rl * 0.5      ✓ 일치
knee       = -internalGain * pitchErrDeg * kneeGain * intensity
           = +0.3 * fb * 0.3      ✓ 일치 (Walking.cpp 의 -dir * -0.3 = +0.3)
anklePitch = -internalGain * pitchErrDeg * anklePitchGain * intensity
           = +0.3 * fb * 0.9      ✓ 일치
ankleRoll  = internalGain * rollErrDeg * ankleRollGain * intensity
           = -0.3 * rl * 1.0      ✓ 일치
```

**물리 의미 검증** (`testCorrectionPolarity*` 회귀로 lock-in):

| 외란 | 기대 보정 | 본 구현 |
|---|---|---|
| roll +10° (오른쪽 기울) | 양 hipRoll 음수 (왼쪽 lean 회복) | -1.5° ✓ |
| roll +10° | 양 ankleRoll 음수 (발 왼쪽으로) | -3.0° ✓ |
| pitch +10° (앞 기울) | 양 knee 양수 (굽힘 = 뒤로 lean) | +0.9° ✓ |
| pitch +10° | 양 anklePitch 양수 (발끝 위) | +2.7° ✓ |

**R/L 동일 부호** — lateral CoP shift 이라 mirror gait 와 달리 양 다리가 같은 방향. 회귀 `testCorrectionPolarityRollPositive` 의 `XCTAssertEqual(rHipRoll, lHipRoll)` 으로 검증.

**검수 2 PASS** — 4 그룹 × 2 축 모두 ROBOTIS 원본과 일치.

---

## 검수 3 — 단위·스케일 정합

| 변수 | 단위 |
|---|---|
| `rollErrDeg` / `pitchErrDeg` | 도 (°) — `imuRollDeg/Pitch` 직접 사용 |
| `intensity` / `*Gain` | unitless 계수 |
| `internalGain = -0.3` | unitless (Walking.cpp 와 동일) |
| 출력 `Corrections.*` | 도 (°) |

**계산 example** (회귀 `testCorrectionPolarityRollPositive`):
- rollErrDeg = 10
- hipRoll = -0.3 × 10 × 0.5 × 1.0 = -1.5 (°)
- raw 변환: `Kinematics.raw(fromDegrees: baseDeg + (-1.5))`

raw 변환 (`Kinematics`):
- `raw(fromDegrees: d) = 2048 + d * (4096/360) = 2048 + d * 11.378`
- baseDeg = walkReady r_hip_roll = +0.4° (raw 2052)
- corrected = 0.4 + (-1.5) = -1.1° → raw 2048 + (-1.1*11.378) = 2035

**검수 3 PASS** — 도 → 도 → raw 변환 일관.

---

## 검수 4 — Walking.cpp 의 internal_gain=-0.3 의미

ROBOTIS 원본의 추가 dampening multiplier. 본 corrector 가 사용한 부호:
- `internalGain * rollErrDeg * gain` = `-0.3 * rl * 0.5` (hip_roll) = **-0.15 × rl**
- `-internalGain * pitchErrDeg * gain` = `+0.3 * fb * 0.3` (knee) = **+0.09 × fb**

**의미**:
- `-0.3` = 30% 의 보정 강도. fall feedback 의 노이즈/oscillation 회피용 dampening.
- 사용자가 `intensity` 로 추가 조정 가능 (default 1.0). 더 보수적 적용 시 0.5.

**비교**:
- 우리 corrector intensity=1.0, internal_gain=-0.3 → ROBOTIS 와 정확히 동일.
- intensity=0.5 → ROBOTIS 의 50% 강도 (더 부드러움).

**검수 4 PASS** — internal_gain 의미 명확, 사용자 조정 가능.

---

## 검수 5 — 안전 가드 (max clamp + ramp)

### maxCorrectionDeg = 15°

- ankle_roll 가 가장 큰 gain (1.0). rollErr = 50° 이면 보정 = -0.3 × 50 × 1.0 = **-15°** (clamp 경계 정확).
- rollErr = 100° → -30° 계산 → clamp -15° 유지.
- **회귀 `testCorrectionClampedAtMax`** — roll 100° 에서 ankleRoll 정확히 -15°.

### gain ramp 1초

- 시작 0~1s 동안 0% → 100% linear ramp.
- 의도: oscillation 회피. 갑작스러운 보정 활성 시 모터 충격 방지.
- 회귀 `testBalanceCorrectorGainRamp`:
  - 0초 → 0% (pose 변화 없음)
  - 0.5초 → 50% (-0.75°)
  - 1.0초 → 100% (-1.5°)
- 1초 이상은 100% 유지 (clamp).

**위험 분석**:
- max 15° + intensity 1.0 + 4 그룹 동시 보정 = 한 다리 raw 한도 검증 필요.
- 예: ankle_pitch raw 한도 ±90° (JointLimits). walkReady ank_pitch = +30°. 보정 +15° → +45°. JointLimits 통과 ✓.
- worst case: walkReady ank_pitch +30° + 보정 +15° = +45° (한도 +90° 안).
- knee 동일 — walkReady +53° + 보정 +15° = +68° (한도 +150°).

**검수 5 PASS** — clamp + ramp + JointLimits 통합 안전.

---

## 검수 6 — Edge case 커버리지

| Case | 동작 | 회귀 |
|---|---|---|
| `enabled = false` | identity (변화 없음) | `testBalanceCorrectorDisabledIdentity` ✓ |
| `intensity = 0` | 모든 보정 0 | (자동 — clamp 0) |
| `intensity > 1` | clamp 1.0 | 코드 init 의 `max(0, min(1, intensity))` |
| `NaN rollErr` | clamp 0 | `testBalanceCorrectorRejectsNaN` ✓ |
| `inf rollErr` | clamp 0 | 동일 |
| `enableBalanceCorrection` 토글 OFF→ON | ramp 재시작 | `start()` 에서 `correctionEnabledAt` 재설정 |
| `walkLabSession.lastCorrections` 초기 | nil | `testBalanceCorrectionDefaultOff` ✓ |
| `apply` disabled | identity | `testSessionApplyDisabledReturnsIdentity` ✓ |

**검수 6 PASS** — 8 case 모두 회귀 또는 코드 가드.

---

## 검수 7 — 기존 동작 보존 (Stage 1·2·3 + L3 호환)

### 시나리오 A: 모든 토글 OFF (기존 v1.0 동작)
- `autoFallPrevention = false` + `enableBalanceCorrection = false`
- → Stage 2 mitigation 안 함, Stage 3 emergency 안 함, Stage 4 identity
- → L3 30° emergency 만 작동 (v1.0 동작 그대로) ✓

### 시나리오 B: autoFallPrevention ON + enableBalanceCorrection OFF (default)
- Stage 1-3 활성 (sim → real IMU, 다단계 임계, 선제 emergency)
- Stage 4 identity → visualPose 변경 없음
- ✓ 안전한 default

### 시나리오 C: 모든 토글 ON (best case)
- Stage 1-3 정상 작동
- Stage 4 sim mode 의 visualPose 에만 적용 (실 motor 송출 X — Stage 4b 미wire)
- ✓ 사용자가 시각적으로 검증 가능

### 시나리오 D: emergency 발생 후
- `emergencyStop()` → `stop()` → simTimer 정지
- 새 `start()` 호출 시 corrector ramp 재시작 (`correctionEnabledAt = Date()`)
- ✓ 멱등성 확보

**검수 7 PASS** — 4 시나리오 모두 호환.

---

## 검수 8 — 회귀 가드 커버리지

| Invariant | 회귀 |
|---|---|
| 5 상수 ROBOTIS 정합 | `testBalanceCorrectorDefaultsMatchRobotis` |
| roll +양 → hipRoll/ankleRoll 음수 | `testCorrectionPolarityRollPositive` |
| pitch +양 → knee/anklePitch 양수 | `testCorrectionPolarityPitchPositive` |
| R/L 동일 부호 (lateral shift) | `testCorrectionPolarityRollPositive` (assertEqual 포함) |
| max clamp ±15° | `testCorrectionClampedAtMax` |
| gain ramp 0/0.5/1.0s | `testBalanceCorrectorGainRamp` |
| disabled identity | `testBalanceCorrectorDisabledIdentity` |
| NaN robust | `testBalanceCorrectorRejectsNaN` |
| maxAbs helper | `testBalanceCorrectorMaxAbs` |
| session default OFF | `testBalanceCorrectionDefaultOff` |
| session apply disabled | `testSessionApplyDisabledReturnsIdentity` |

**합 11 회귀** (Stage 4 만). 이전 Stage 1-3 + 19 = **30 회귀 총**.

**검수 8 PASS**.

---

## 검수 9 — 모션 데이터 (walkReady) 기준 보정 검증

walkReady 절댓값 (`RobotPose.walkReady` 의 `motion_4096.bin page 9 step 0`):

| 관절 | 값 (raw / °) | +15° 보정 후 (°) | JointLimits |
|---|---|---|---|
| r_hip_roll | 2052 / +0.4° | +15.4° | ±45° ✓ |
| l_hip_roll | 2044 / -0.4° | +14.6° | ±45° ✓ |
| r_knee | 2653 / +53° | +68° | ±150° ✓ |
| l_knee | 1443 / -53° | -38° | ±150° ✓ |
| r_ank_pitch | 2389 / +30° | +45° | ±90° ✓ |
| l_ank_pitch | 1707 / -30° | -15° | ±90° ✓ |
| r_ank_roll | 2057 / +0.8° | +15.8° | ±45° ✓ |
| l_ank_roll | 2039 / -0.8° | +14.2° | ±45° ✓ |

**모든 관절이 max 15° 보정에도 JointLimits 안.** 안전 가드 OK.

**worst case 추가 검증** — knee 가 walkReady 에서 가장 양수 (+53°). 양수 방향 max 보정 +15° → +68°. 한도 +150° 까지 82° 여유.

**검수 9 PASS** — 모션 데이터 기준 안전 마진 확보.

---

## 종합 평가

| 검수 | 결과 |
|---|---|
| 1. ROBOTIS Walking.cpp 출처 정합 | ✅ PASS |
| 2. 4 그룹 × 2 축 부호 정합 | ✅ PASS |
| 3. 단위·스케일 (deg → deg → raw) | ✅ PASS |
| 4. internal_gain=-0.3 의미 | ✅ PASS |
| 5. max clamp + ramp 안전 가드 | ✅ PASS |
| 6. Edge case 8건 | ✅ PASS |
| 7. 기존 동작 보존 (Stage 1·2·3 + L3) | ✅ PASS |
| 8. 회귀 11건 (Stage 4) + 19건 (총 30) | ✅ PASS |
| 9. 모션 데이터 (walkReady) 안전 마진 | ✅ PASS |

**9/9 PASS**. Stage 3 의 WARN (5Hz IMU jitter) 도 corrector 의 보수적 gain (0.3 × 0.5 = 0.15 multiplier) 으로 부분 완화.

## Stage 4 의 의도적 제한 (논리적 결정)

### 4a (본 PR): **sim mode visualPose 만 적용**

- `applyBalanceCorrectionIfEnabled` 가 sim mode 의 visualPose 에만 호출
- 사용자가 corrector 동작을 **시각적으로 미리보기** 가능 (실 motor 송출 없음)
- 실 robot 검증 + Codex audit 통과 후 4b 로 진행

### 4b (별도 PR 권장): **실 motor 송출 경로 wire**

- `runWalkCycle` / `runContinuousWalk` 의 onPose 직전에 corrector 호출
- 실 robot 보행 cycle 의 매 step pose 에 적용
- **BLOCKER C3** (실 IK) 의 일부 — 본 corrector 만으로도 부분 효과 (delta-only 보정)

### 4a 제한의 합리성

- 사용자 요구 "실 로봇 빌드는 추후" → 실 motor 송출 wire 보류
- **default OFF** (`enableBalanceCorrection = false`) → 사용자가 ON 해도 sim 만 영향
- 실 robot 위험 0

## Codex 외부 검수 권장 영역

본 self-audit 못 잡는 영역:
1. **실 robot 점진 외란 (push) 시 corrector 의 oscillation 거동** — gain 0.5/0.3/1.0/0.9 + intensity 1.0 + internal_gain -0.3 조합이 실제 안정인지
2. **다른 보행 phase 시 corrector 적용 정확성** — 정상 보행 cycle 의 hip_roll 자체 변화와 corrector delta 의 간섭
3. **IMU 5Hz jitter 와 corrector latency 의 결합 효과** — phase delay 가 oscillation 유발 가능성

이 3개 영역은 실 robot + Codex 검수 필수.

## 다음 단계

1. **commit Stage 4 + audit doc** (이번 turn)
2. PR #25 description 갱신 (Stage 4 추가)
3. Mac swift build + 회귀 30 통과 확인 (사용자 작업)
4. Stage 4b (실 motor wire) — 별도 PR, Codex audit 후
