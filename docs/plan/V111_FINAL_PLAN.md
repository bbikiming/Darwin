# v1.11 최종 구현 plan (5개 에이전트 검증 + 사용자 prompt 종합)

> **작성**: 2026-05-17
> **방법**: 5개 병렬 에이전트 (code-reviewer + Explore + debugger + critic + test-architect) 독립 검증
> **참고**: 사용자 prompt `CLAUDE_V110_BALANCE_IMPLEMENTATION_PROMPT.md` + 우리 v1.10 코드

---

## 🔴 사용자 비판 — 5/5 모두 정당함 (정직 인정)

5개 에이전트 모두 사용자 prompt 의 비판이 코드 evidence 로 정당하다고 확인:

| # | 사용자 비판 | 검증 결과 |
|---|---|---|
| 1 | `robotisDefault` 에 v1.10 값 섞임 | ✅ 정당 — anklePitchGain=1.5, ankleRollGain=0.5, enableHybrid=true 가 "robotis" 이름 하에 들어감 |
| 2 | Hybrid phase = `sessionStartedAt` 기준 | ✅ 정당 (심각) — walking cycle phase 와 무관 → A residual 위상 어긋남 |
| 3 | `periodMs ?? 0` → preset walking nil | ✅ 정당 — phase-locked correction 완전 무효, slow EMA 만 작동 |
| 4 | enableHybrid=true default → over-claim | ✅ 정당 — 실 robot 검증 전 시뮬만으로 default 채택 |
| 5 | sign convention 과 algorithm 결합 | ⚠️ 부분 정당 — sign 은 아예 옵션 없음 (단일 ROBOTIS 박힘) |

## 🚨 추가 발견 (critic + debugger agent)

### CRITICAL 1: Bus serialization 위험 — packet collision 가능
- **`BusActor` 존재하지만 사용 안 함** (debugger agent 확정)
- `ConnectionStore.runImuLoop`, `runTelemetryLoop`, `WalkLabSession.runContinuousWalk` 모두 raw `bus.xxx()` 를 `Task.detached` 로 호출
- USB-TTL half-duplex 환경 → packet collision → "보행 중 갑자기 멈춤", "IMU spike", "setPosition timeout" 의 실제 원인 가능성
- **이건 v1.11 작업 전 최우선 fix 필요**

### CRITICAL 2: 사용자 4축 UI 가 위험
- critic agent 결론: 48 조합 → cognitive overload + safety gap
- `반대 부호 × Hybrid × 실제 로봇` 같은 위험 조합 무방비
- **권고**: Profile picker (3-4 preset 묶음) + Expert disclosure
- "관찰만" mode 는 WalkDiagnostics 와 중복 — deep-link 로 통합

---

## ✅ 최종 plan (12 단계)

### Phase 0 — CRITICAL fix (다른 모든 것 이전)

**P0: Bus serialization (BusActor 통합)**
- `ConnectionStore.bus: Bus?` → `busActor: BusActor?` 교체
- 모든 `bus.xxx()` → `await busActor.xxx()`
- `Task.detached` 제거 — actor serial executor 가 자동 직렬화
- `WalkLabSession.runContinuousWalk` 도 동일
- **이 fix 없이는 다른 모든 fix 의 검증 데이터가 corruptible**

### Phase 1 — Naming + default 환원

**P1-1: BalanceCorrector 정적 상수 분리**
```swift
public static let robotisOriginal = BalanceCorrector(
    hipRollGain: 0.5, kneeGain: 0.3,
    anklePitchGain: 0.9, ankleRollGain: 1.0,  // ROBOTIS oracle 값
    enableHybrid: false                        // 실 robot 검증 전 OFF
)
public static let v110Experimental = BalanceCorrector(
    hipRollGain: 0.5, kneeGain: 0.3,
    anklePitchGain: 1.5, ankleRollGain: 0.5,  // random search 권장
    enableHybrid: true
)
public static let robotisDefault = robotisOriginal  // deprecated alias
```

**P1-2: WalkLabSession default 환원**
- `correctorIntensityLevel: Int = 3` → `= 2` (ROBOTIS 권장으로 환원)
- `balanceCorrector = .robotisOriginal` (init 에서)

### Phase 2 — Phase calculation fix

**P2-1: cycleStartedAt 추가 + truncatingRemainder wrap**
```swift
private var cycleStartedAt: Date?

// runContinuousWalk 진입 시:
await MainActor.run { self.cycleStartedAt = Date() }

// applyBalanceCorrectionIfEnabled 안에서:
let totalElapsed = Date().timeIntervalSince(cycleStart) * 1000.0
let periodMs = effectiveWalkPeriodMs()
let elapsedMs = periodMs > 0
    ? totalElapsed.truncatingRemainder(dividingBy: periodMs)
    : 0
```

**P2-2: effectiveWalkPeriodMs() helper**
```swift
private func effectiveWalkPeriodMs() -> Double {
    if let tuning = currentWalkTuning() {
        return tuning.periodMs
    }
    guard current != .idle else { return 0 }
    return WalkMotionLibrary.defaultTuning(for: current).periodMs
}
```

### Phase 3 — Config struct + algorithm/sign 분리

**P3-1: 신규 enum + struct** (`WalkLabSession+Types.swift`)
```swift
public enum BalanceAlgorithmMode: String, CaseIterable, Codable, Sendable {
    case off                // 보정 없음
    case robotisPControl    // 종전 P-control + LPF + deadband
    case hybridBA           // v1.10 Hybrid B+A (실험)
    case observeOnly        // 계산만, pose 적용 X (로그 기록)
}

public enum BalanceSignConvention: String, CaseIterable, Codable, Sendable {
    case robotisWalkingCpp     // ROBOTIS Walking.cpp oracle (default)
    case alternateDiagnostic   // 진단용 부호 반전 (knee/ankle_pitch 4관절만)
}

public enum BalanceGainProfile: String, CaseIterable, Codable, Sendable {
    case robotisOriginal       // hipR 0.5, knee 0.3, ankP 0.9, ankR 1.0
    case v110Experimental      // hipR 0.5, knee 0.3, ankP 1.5, ankR 0.5
    case custom                // 사용자 슬라이더
}

public struct BalanceExperimentConfig: Codable, Equatable, Sendable {
    public var algorithmMode: BalanceAlgorithmMode = .robotisPControl
    public var signConvention: BalanceSignConvention = .robotisWalkingCpp
    public var gainProfile: BalanceGainProfile = .robotisOriginal
    public var applyToRobot: Bool = false  // observe-only default
}
```

**P3-2: BalanceCorrector 에 sign convention 적용**
- `corrections()` 가 sign convention 인자 받음
- `alternateDiagnostic` → knee R/L + anklePitch R/L 4개의 부호만 반전 (lateral 은 안전상 유지)
- 명시적 doc + 테스트 lock-in

### Phase 4 — observe-only mode

**P4: observeOnly 구현**
- `applyBalanceCorrectionIfEnabled` 에서 `algorithmMode == .observeOnly` → corrections 계산 + 로그 + pose 그대로 반환
- `lastCorrections` 는 계산값 표시 (UI inspection)
- `correctionAppliedToRobot = false` 로깅

### Phase 5 — UI (Profile picker, critic 권고 반영)

**P5-1: Balance Experiment 패널** (critic 의 Pattern B 채택)
- Default UI: **Profile picker** 3개
  - "🛡️ ROBOTIS 기본 (안정 검증)" → algorithm=pControl, sign=robotis, gain=robotisOriginal, apply=true
  - "🧪 v1.10 Hybrid 실험 (관찰)" → algorithm=hybridBA, sign=robotis, gain=v110Experimental, apply=false (observe-only)
  - "⚙️ 사용자 정의" → expand 시 4축 segmented control 노출
- **Expert disclosure** (`DisclosureGroup`): 4축 individual control + safety warnings

**P5-2: Safety gate (DiagConfigValidator)**
- `alternateDiagnostic` sign + `applyToRobot=true` → 차단 (alert + 자동 observe-only 전환)
- `hybridBA` + `applyToRobot=true` → cradle confirmed 필수 + warning toast
- `intensityLevel=4` + `applyToRobot=true` → 별도 확인

### Phase 6 — Logging 확장

**P6: WalkSessionSample 신규 필드**
```swift
public let balanceAlgorithmMode: String       // "off" / "robotisPControl" / ...
public let balanceSignConvention: String       // "robotisWalkingCpp" / ...
public let balanceGainProfile: String          // "robotisOriginal" / ...
public let correctionAppliedToRobot: Bool      // observe-only vs real
public let walkCycleElapsedMs: Double          // cycle 내 phase time
public let walkPeriodMs: Double                // current cycle period
public let imuSampleAgeMs: Double              // IMU staleness
public let expectedPitchDeg: Double            // phase-locked baseline
public let expectedRollDeg: Double
public let emaPitchDeg: Double                 // slow EMA
public let emaRollDeg: Double
public let effectivePitchErrDeg: Double        // corrector 입력
public let effectiveRollErrDeg: Double
```

### Phase 7 — Tests (10 사용자 + 6 missing = 16)

**TDD 순서** (test-architect agent 권고):
1. **enum Codable** (3 tests) — algorithmMode, signConvention, gainProfile
2. **BalanceCorrector pure function** (5 tests) — ROBOTIS sign oracle, alternate sign, Hybrid + alternate 조합, clamp boundary, IMU stale
3. **WalkLabSession integration** (5 tests) — observe-only pose unchanged, preset periodMs ≠ 0, phase = cycle (not session), cradle gate, A/B 비교
4. **UI + Logging** (3 tests) — SafetyEvent 신규 필드, profile picker selection, e-stop race

**기존 349 tests 회귀 가드** (`v110` 관련 테스트 v1.11 값으로 update).

---

## 🎯 사용자 prompt 와 차이점 (critic 반영)

| 사용자 prompt | v1.11 plan | 이유 |
|---|---|---|
| 4축 평면 segmented control | Profile picker + Expert disclosure | critic: 48 조합 cognitive overload |
| `observeOnly` 가 algorithm mode | 동일 (algorithm 의 한 case) | 사용자 prompt 그대로 |
| 4축 모두 main UI | 기본은 profile, expert 토글 시 4축 | macOS HIG: matrix 패턴 회피 |
| 안전 gate "cradle confirmed" | DiagConfigValidator 신규 도입 | critic: 위험 조합 hard-block 필요 |
| 10 tests | 16 tests (10+6 missing) | test-architect: safety gate, e-stop race 등 critical 누락 |

---

## 🔴 Phase 0 (Bus serialization) 의 critical 함

이건 v1.11 작업 시작 전 절대 우선:
1. 우리 실 robot session 데이터 (89.8% IMU duplicate) 의 일부 원인일 가능성
2. v1.11 의 모든 검증 (observe-only 비교, A/B) 가 corrupted bus 위에서 진행되면 무의미
3. 데이터 신뢰성의 root 입니다.

**Step 1**: BusActor 통합 → fresh session 데이터 수집 → IMU duplicate 줄어드는지 확인 → v1.11 진행

---

## 완료 기준 (사용자 prompt §10 + 추가)

- ✅ Bus serialization → BusActor 통합 완료
- ✅ Naming 정리 (robotisOriginal / v110Experimental 분리)
- ✅ Default = ROBOTIS (실 검증 전)
- ✅ Phase = walking cycle (not session)
- ✅ Config struct (algorithm / sign / gain / apply)
- ✅ Profile picker UI + Expert disclosure
- ✅ Safety gate (DiagConfigValidator)
- ✅ observe-only mode 작동
- ✅ Logging mode/sign/gain/phase/effective err/applied
- ✅ 16 tests pass (TDD 순서)
- ✅ `swift test` 통과
- ✅ 문서에 "Hybrid 실험, ROBOTIS 기본" 명시

---

다음: 구현 시작. Phase 0 (Bus serialization) → 1-7.
