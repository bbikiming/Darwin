# Walk Lab Fall Prevention — Phase A-F 정정 (5 Agent Audit 후)

**대상**: `feature/v1.1-walklab-fall-prevention` PR #25.

**사용자 요구**: "개선 권고 항목 냉정하게 파악하고 조치".

**5 병렬 Agent 검수 결과 종합 → 6 단계 정정 적용**.

---

## Agent 검수 종합

| Agent | 영역 | 핵심 발견 |
|---|---|---|
| 1 | Swift concurrency | Mac 빌드 통과 95% (Swift 5.10 모드). BalanceCorrector: Sendable 추가 권장 |
| 2 | 알고리즘 수식 | B-1: ankle_roll 부호 오류 (CRITICAL) + B-2: dps→deg semantic 변경 (HIGH) + B-3: ramp 300ms 미발동 + B-5: rawLimits 우회 + B-7: lastCorrections ramp 미반영 |
| 3 | 부호 cross-check | **4 관절 부호 P0** (knee R/L + ankle_roll 양쪽) — fall 가속 위험 + `applyDelta` 타입 mismatch (컴파일 실패) |
| 4 | 6-Layer interaction | **Stage 2 실 motor 미적용 P0** (warning 감속 / danger 동결 sim 만) + P1 start() reset 누락 4건 |
| 5 | 회귀 강도 | 300+ assertion 실효 ~54% + 약한 회귀 9건 + 누락 invariant 6+건 |

**총 P0 발견: 6건. P1 발견: 4건. 정량 분석으로 의심 가능성 큰 영역 모두 식별**.

---

## Phase A — Mac 빌드 가능 (P0)

**문제**: `BalanceCorrector.applyDelta` 가 `UInt16` 반환 → `RobotPose.positions: [JointID: Int]` 와 타입 mismatch → 컴파일 실패.

**정정**: 반환 타입 `Int` (Kinematics.raw 가 이미 Int 반환).

---

## Phase B — 부호 4 관절 정정 (P0)

**문제**: 4-source (doc + URDF + walkReady + corrector) cross-check 결과 4 관절 부호 fall 가속 방향:
- r_knee, l_knee — sagittal recovery 의 R/L mirror 부호 반대
- r_ank_roll, l_ank_roll — lateral 회복의 hip_roll 과 정합 안 됨 (hip_roll 음수 / ankle_roll 양수 = inconsistent)

**정정** (`BalanceCorrector.corrections`):
```diff
- let kneeR           = -m * pitchErrDeg * kneeGain        // -0.09 (fall 가속)
+ let kneeR           = +m * pitchErrDeg * kneeGain        // +0.09 (R 굽힘 회복)
- let kneeL           = +m * pitchErrDeg * kneeGain        // +0.09 (fall 가속)
+ let kneeL           = -m * pitchErrDeg * kneeGain        // -0.09 (L 굽힘 mirror)
- let ankleRollBoth   = +m * rollErrDeg * ankleRollGain    // +0.30 (fall 가속)
+ let ankleRollBoth   = -m * rollErrDeg * ankleRollGain    // -0.30 (lateral 회복, hip_roll 동일 부호)
```

회귀 갱신:
- `testCorrectionFullSignTableLockIn` — 8 관절 새 값 lock-in
- `testCorrectionPolarityRoll/Pitch*` — 부호 정정 반영
- `testCorrectionClampedAtMax` — ankleRoll clamp 부호 정정
- `test50CellsCorrectorRecoveryDirection` — 정정 부호 매트릭스 적용

---

## Phase C — Stage 2 실 motor 경로 적용 (P0)

**문제** (Agent 4 P0): `applyBalanceMitigation()` 의 `engine.setCommand(x*0.7, ...)` 는 sim engine 만 영향. 실 motor 경로 (`runWalkCycle`/`runContinuousWalk`) 는 `Task.detached` 라 engine 상태 무관 → **22°+ 자동 감속 / 28°+ 자세 동결이 실 robot 에서 무효**.

**정정** (`applyBalanceCorrectionIfEnabled`):
- `balanceState == .danger` (28°+) 시 **`lastSafePose` 반환** = 마지막 안전 pose 동결. 실 motor 송출 단계에서 동결 효과.
- `.warning` 의 70% 감속은 pose 변환으로 표현 불가 (실 motor 의 cycle plan 은 미리 합성됨) → sim engine 감속 + corrector 적용으로 부분 완화.

**완전한 dynamic stride 변경** (Agent 4 P0 의 warning 감속) 은 별도 Sprint 추가 작업 — `WalkMotionLibrary` 가 동적 stride 재합성 지원해야. 본 PR 은 corrector + 동결로 대체.

---

## Phase D — start() reset 보강 + applyBalanceMitigation 회복 (P1)

**문제** (Agent 4 P1):
- `start()` 가 `imuRollDeg/Pitch` 초기화 X → 첫 tick 에 stale 28° 로 잘못된 balanceState
- `applyBalanceMitigation` warning → normal 회복 후 engine 명령 0.7× 영구 잔존
- `start()` 가 `lastPreflightFailure`/`lastCycleResult` 미초기화 → stale UI banner

**정정**:
- `start()` 에 `imuRollDeg=0; imuPitchDeg=0; imuSource=.sim; lastPreflightFailure=nil; lastCycleResult=nil; lastSafePose=nil` 추가
- `applyBalanceMitigation` 의 `.normal/.caution` 분기에서 `engine.setCommand(cmd.x, ...)` 복원

---

## Phase E — toggle OFF→ON 시 ramp 재시작 (Agent 2 B-3)

**문제**: `enableBalanceCorrection` 토글 OFF 시 `correctionEnabledAt` 잔존 → 다음 ON 시 즉시 100% (ramp 우회).

**정정**: `enableBalanceCorrection.didSet` 에서 toggle 전환 시 `correctionEnabledAt = enableBalanceCorrection ? Date() : nil`.

---

## Phase F — joint.rawLimits 안전 clamp (Agent 2 B-5)

**문제**: `applyDelta` 가 `Kinematics.raw(fromDegrees:)` 의 0..4095 한도만 적용 → joint 별 안전 한도 (예: hip_roll ±45°) 우회 가능.

**정정**: `BalanceCorrector.apply(to:)` 가 `pose.with([JointID: Int])` 사용 → `RobotPose.with` 가 자동으로 `joint.rawLimits` clamp.

---

## 부수 정정 (Agent 2 B-7)

`lastCorrections` 가 ramp 미반영 → UI 표시 delta 가 실 motor delta 보다 큼 (ramp 30% 시 3.3× 큼).

**정정**: `corrections(rollErrDeg: imuRollDeg * ramp, pitchErrDeg: imuPitchDeg * ramp)` 로 ramp 적용된 delta UI publish.

---

## 추가 미해결 항목 (별도 작업 권장)

| # | 발견 | Agent | 미해결 사유 |
|---|---|---|---|
| HIGH | Agent 2 B-2: dps→deg semantic 변경 — ROBOTIS gain 이 dps 입력 가정 | 2 | gain 재 calibration 또는 별도 알고리즘. 별도 Sprint 권장 |
| HIGH | Agent 2 B-3: 300ms fall 시 ramp 30% 만 작동 | 2 | ramp 시간 단축 또는 risk-based bypass — 별도 결정 필요 |
| MEDIUM | Agent 2 B-6: 보행 cycle + corrector 진동 위험 | 2 | 실 robot 검증 필수 |
| HIGH | Agent 4 P0: Stage 2 warning 감속 실 motor 미적용 | 4 | `WalkMotionLibrary` dynamic stride 재합성 — 별도 Sprint |
| 약함 | Agent 5: 9 약한 회귀 + 6+ 누락 invariant | 5 | 별도 회귀 강화 PR 권장 |

---

## 정정 후 실 잘 될 확률 추정 (재평가)

| Stage | 정정 전 | 정정 후 |
|---|:-:|:-:|
| Stage 1 실 IMU wire | 70% | **85%** (imu reset 보강) |
| Stage 2 다단계 임계 | 20% | **45%** (Phase C 자세 동결만 실 motor 적용 — 감속은 미적용 잔존) |
| Stage 3 predictor | 45% | 45% (변경 없음) |
| Stage 4a corrector pure | 30% | **75%** (부호 정정 + 컴파일 + rawLimits 안전) |
| Stage 4b 실 motor wire | 5% | **50%** (전체 정정 통합) |
| **종합** | **20-35%** | **55-70%** |

여전히 50% 이하 확률은 아니지만 의도대로 동작 확률 향상. 실 robot 검증 + Agent 2 의 B-2/B-3 정정 + Agent 5 회귀 강화 후 80%+ 가능.

---

## 모든 정정 회귀 lock-in

| 회귀 | 검증 |
|---|---|
| `testCorrectionFullSignTableLockIn` | 8 관절 새 부호 (knee R+ / L- / ankleRoll 양쪽 -) |
| `testCorrectionPolarityRollPositive` | hipRoll/ankleRoll 둘 다 -1.5°/-3.0° (동일 부호 lateral) |
| `testCorrectionPolarityPitchPositive` | knee R+0.9° / L-0.9° (mirror) |
| `testCorrectionClampedAtMax` | ankleRoll roll+100° → -15° clamp |
| `test50CellsCorrectorRecoveryDirection` | 50-cell 정정 부호 매트릭스 |

---

## Codex 외부 검수 권장

본 audit + 정정 후에도 다음은 실 robot 검증 필요:
1. **Agent 2 B-2 (dps→deg semantic)**: 실 robot 외란 (push) 시 corrector 의 magnitude 가 적절한지
2. **Agent 2 B-3 (ramp 300ms)**: 빠른 fall 시 30% ramp 가 회복 부족인지
3. **Agent 2 B-6 (보행 cycle + corrector 진동)**: 정상 보행 sin sway 와 corrector delta 의 phase 간섭 oscillation
4. **Agent 4 warning 감속**: `WalkMotionLibrary` dynamic stride 재합성 필요성

이 4 영역은 본 PR 범위 외 — 별도 Sprint.
