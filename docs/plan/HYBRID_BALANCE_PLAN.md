# Hybrid B+A 자이로 보정 구현 기획 (v1.10)

> **목표**: 시뮬상 mean signed pitch −8.98° → **−0.20° (45배 개선)** 달성
> **근거**: 5개 병렬 에이전트 시뮬레이션 (1,749 sample × 10 변형) + 350 trial parameter search
> **참고**: `docs/diagnosis/GYRO_BALANCE_SIMULATION_REPORT.md`

---

## 1. 알고리즘 설계

### Hybrid B+A 공식

```
B (Slow drift compensation) — chronic bias 제거:
  pitch_ema = α_slow × imuPitch + (1 − α_slow) × pitch_ema_prev
  roll_ema  = α_slow × imuRoll  + (1 − α_slow) × roll_ema_prev
  // α_slow = 0.02 (tau ≈ 10s @ 5Hz IMU)

A (Phase-locked residual) — walking 의도된 sway 제거:
  expected_pitch = sagittal_sway_amp × sin(2π × t/period)  // ≈ 5° sin
  expected_roll  = 0                                         // lateral 은 ROBOTIS 가정 = 0
  residual_pitch = (imuPitch − pitch_ema) − expected_pitch
  residual_roll  = (imuRoll  − roll_ema)  − expected_roll

Combined corrector input:
  effective_pitch_err = slow_gain × pitch_ema  + fast_gain × residual_pitch
  effective_roll_err  = slow_gain × roll_ema   + fast_gain × residual_roll
  // 기존 BalanceCorrector.corrections() 에 effective_*_err 전달
```

### 파라미터

| 파라미터 | 값 | 이유 |
|---|---|---|
| `α_slow` (slow EMA alpha) | 0.02 | tau 10s @ 5Hz IMU |
| `slow_gain` | 1.0 | drift 완전 보정 |
| `fast_gain` | 0.27 | ROBOTIS internal_gain × ankle_pitch_gain ≈ 0.3 × 0.9 |
| `sagittal_sway_amp` | 5° | 사용자 실 robot 측정 (slowWalk peak ~5-8°) |
| `lateral_sway_amp` | 0° (사용 안 함) | ROBOTIS Walking.cpp 가정 (lateral 평균 0) |
| `enable_hybrid` | true | 사용자 토글 가능 (legacy P-control fallback) |

### 효과 (시뮬 결과)

| Metric | P-current | Hybrid B+A |
|---|---|---|
| mean signed pitch | −8.98° | **−0.20°** (45배 개선) |
| mean \|x\| pitch | 9.02° | 3.98° |
| max tilt | 16.08° | 13.27° |
| recovery time | 0.05s | 0.00s |
| osc RMS | 4.38 | 4.57 (수용 가능) |

---

## 2. 변경 파일 list

### 신규 파일
1. `Tests/.../HybridBalanceCorrectorTests.swift` — 새 알고리즘 단위 테스트

### 수정 파일

| 파일 | 변경 | 라인 추정 |
|---|---|---|
| `BalanceCorrector.swift` | Hybrid B+A logic + state struct | +60 |
| `WalkLabSession.swift` | hybrid state hook + intensity default 3 | +20 |
| `ConnectionStore.swift` | IMU 전용 별도 Task (50ms polling) | +30 |
| `GyroCorrectorControls.swift` | level 3 라벨 "권장" 변경 | +5 |
| `WalkLabFallPreventionTests.swift` | intensity default test 업데이트 | +5 |

총 ~120 라인 변경 (신규 + 수정).

---

## 3. API 변경

### BalanceCorrector 확장

```swift
public struct BalanceCorrector {
    // 기존 필드 (변경 없음)
    public let intensity: Double
    public let maxCorrectionDeg: Double
    public let hipRollGain, kneeGain, anklePitchGain, ankleRollGain: Double
    public let internalGain: Double
    
    // v1.10 (Hybrid B+A) 신규 필드
    /// Hybrid mode ON/OFF. true = slow EMA + phase-locked residual.
    public let enableHybrid: Bool
    /// Slow EMA time constant (초). chronic bias 의 회복 속도.
    public let slowDriftTauSec: Double
    /// Slow EMA gain — drift 완전 보정 시 1.0.
    public let slowGain: Double
    /// Fast residual gain — walking 의 의도된 sway 외 빠른 외란 보정.
    public let fastGain: Double
    /// 예상 sagittal sway amplitude (°). walking pose 의 의도된 pitch 흔들림.
    public let sagittalSwayAmpDeg: Double
    /// 예상 lateral sway amplitude (°). 보통 0 (ROBOTIS 가정).
    public let lateralSwayAmpDeg: Double
}

/// Hybrid mode state — caller (WalkLabSession) 가 유지.
public struct HybridBalanceState {
    public var pitchEma: Double = 0   // slow drift EMA
    public var rollEma: Double = 0
    public var lastUpdateAt: Date? = nil
}

extension BalanceCorrector {
    /// Hybrid B+A — slow drift + phase-locked residual 결합.
    /// caller 가 imu sample + walking phase 정보 + state 전달.
    public func hybridCorrections(
        imuRollDeg: Double,
        imuPitchDeg: Double,
        elapsedMs: Double,         // walking cycle 의 t (0..period)
        periodMs: Double,          // walking cycle period (예: 600ms)
        state: inout HybridBalanceState,
        now: Date = Date()
    ) -> (rollErr: Double, pitchErr: Double, corrections: Corrections)
}
```

### WalkLabSession 변경

```swift
// 새 state
private var hybridBalanceState = HybridBalanceState()

// applyBalanceCorrectionIfEnabled 안에서:
if balanceCorrector.enableHybrid {
    let result = balanceCorrector.hybridCorrections(
        imuRollDeg: imuRollDeg,
        imuPitchDeg: imuPitchDeg,
        elapsedMs: walkingCycleElapsedMs,  // sessionStartedAt 부터
        periodMs: currentWalkTuning().periodMs,
        state: &hybridBalanceState
    )
    // result.corrections 를 pose 에 적용
} else {
    // 기존 P-control path
}

// intensity default 변경
@Published public var correctorIntensityLevel: Int = 3  // 종전 2 → 3 ("적극적", ROBOTIS 권장)
```

### ConnectionStore 변경

```swift
private var imuPollTask: Task<Void, Never>?

public func startTelemetry(cadence: TelemetryCadence) {
    // 기존 pollTask (joint/board)
    pollTask = Task { ... }
    
    // 신규: IMU 전용 50ms
    imuPollTask = Task { [weak self] in
        await self?.runImuLoop(periodNs: 50_000_000)
    }
}

private func runImuLoop(periodNs: UInt64) async {
    while !Task.isCancelled {
        // 기존 readImu 로직만 추출
        await readImuAndUpdateFilter()
        try? await Task.sleep(nanoseconds: periodNs)
    }
}
```

---

## 4. 안전 가드 (5가지)

1. **maxCorrectionDeg ±15° clamp** — 기존 유지. hybrid 결과도 동일 clamp.
2. **periodMs 가 0 이면 phase-locked 무효 (slow EMA 만)** — 보행 idle 시 safe fallback.
3. **state.lastUpdateAt > 5초 stale** → state reset (chronic drift 가 stale 이면 의미 없음).
4. **enableHybrid = false** 시 기존 P-control path → backward compatible.
5. **사용자 슬라이더 level 0** → corrector 자체 OFF (hybrid 무관).

---

## 5. 테스트 케이스 (6가지)

1. **`testHybridSlowEmaConvergence`** — chronic bias +13° 입력 → 10초 후 ema 가 ~13° 도달, slow_delta = −13°
2. **`testHybridPhaseLockedExpectedSway`** — sin sway 만 입력 → residual = 0 (expected 가 정확히 빼짐)
3. **`testHybridSimulatedRealRobot`** — 사용자 실 데이터 (slowWalk session) 입력 → mean signed pitch 가 P-current 보다 작음
4. **`testHybridDisabledFallback`** — enableHybrid=false → 기존 corrections() 와 동일 결과
5. **`testHybridStateReset`** — stale 5초+ 후 state reset
6. **`testHybridClampSafety`** — 큰 imuRoll (예: 30°) → 결과 ±15° clamp 적용

---

## 6. 구현 순서 (단계별)

```
[1] BalanceCorrector 에 Hybrid B+A logic + state 추가
       ↓
[2] WalkLabSession 에 hybrid state hook + 호출
       ↓
[3] ConnectionStore IMU 별도 Task
       ↓
[4] intensityLevel default 2 → 3 + slider 라벨 업데이트
       ↓
[5] BalanceCorrector default gain 조정 (anklePitch 0.9 → 1.5)
       ↓
[6] 테스트 추가 + 빌드 + 344+ test pass 확인
       ↓
[7] Install + 사용자 robot 1-2회 보행 → 새 session 데이터 분석
       ↓
[8] Python 분석 — Hybrid 효과 확인 (mean pitch 개선, oscillation 감소)
```

---

## 7. 검증 metric

사용자 robot 의 새 session 데이터에서 다음 확인:

| Metric | 종전 (P-current) | 목표 (Hybrid B+A) |
|---|---|---|
| `mean signed pitch` | −12.89° | **\|x\| < 3°** |
| `mean |pitch|` | 13.09° | < 6° |
| `peak |roll|` | 35° | < 25° |
| `correctorEffectivenessScore` | 0.24 | > 0.5 |
| Lateral corrector active rate | 53% | > 80% (IMU 별도 task 효과) |
| IMU duplicate rate | 89.8% | < 20% |

---

## 8. Rollback plan

만약 사용자 robot 에서 hybrid 가 더 안 좋으면:

1. `balanceCorrector.enableHybrid = false` 토글 (UI 또는 코드 1줄)
2. → 기존 P-control 로 즉시 복귀
3. 데이터는 계속 logging → 추가 분석

UI 에 `Toggle("Hybrid 보정 (시뮬상 권장)")` 추가 — 사용자가 직접 비교 가능.

---

## 9. 한계 (정직)

- **시뮬은 LIPM 단일 자유도 모델** — 실 robot 의 bilateral asymmetry, joint backlash 다 못 잡음
- **`sagittalSwayAmpDeg = 5°`** 는 사용자 robot 평균 — 다른 robot 에서는 다를 수 있음
- **EMA tau 10s 가 chronic drift 의 회복 시간** — push 같은 빠른 외란은 fast loop 가 잡지만 EMA 자체는 느림 (의도된 거동)
- **5Hz IMU 의 Nyquist 한계는 여전** — robot-side 125Hz loop (Phase 2) 가 진짜 해결

---

다음: 코드 구현 시작.
