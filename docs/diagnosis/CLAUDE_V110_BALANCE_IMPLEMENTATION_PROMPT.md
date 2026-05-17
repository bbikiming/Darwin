# Claude 구현 프롬프트: WalkLab v1.10 자이로 보정 선택형 검증 UI

> 이 문서는 Claude에게 그대로 전달하기 위한 상세 구현 프롬프트입니다.
> 목표는 "Hybrid B+A가 정답인지, ROBOTIS 부호가 정답인지"를 코드에서 단정하지 않고, 실제 UI에서 사용자가 두 경로를 안전하게 선택하고 비교 검증할 수 있게 만드는 것입니다.

---

## 0. 먼저 이해해야 할 결론

Hybrid B+A와 ROBOTIS 부호는 서로 대체 관계가 아닙니다.

- **ROBOTIS 부호**는 보정 delta가 각 관절에 어떤 방향으로 들어가는지 정하는 **sign convention**입니다.
- **Hybrid B+A**는 IMU error를 어떤 방식으로 필터링하고 phase 보정해서 `corrections()`에 넣을지 정하는 **algorithm mode**입니다.

따라서 UI와 코드도 이 둘을 분리해야 합니다.

정답을 하나로 박지 말고 아래처럼 구현하세요.

1. `보정 방식`: 꺼짐, ROBOTIS P-control, Hybrid B+A, 관찰만
2. `부호 기준`: ROBOTIS 기준, 반대 부호 실험
3. `gain profile`: ROBOTIS 원본, v1.10 추천값, 사용자 지정
4. `적용 대상`: 시뮬레이션만, 실제 로봇 적용

기본 판단은 다음과 같습니다.

- **기본 부호는 ROBOTIS 기준을 canonical/default로 둡니다.** `GYRO_BALANCE_ROOT_CAUSE_REPORT.md`와 ROBOTIS `Walking.cpp` oracle이 이 방향을 지지합니다.
- **Hybrid B+A는 유망하지만 아직 실제 로봇 검증 전이므로 experimental로 취급합니다.** 시뮬레이션 결과가 좋더라도 실제 phase, IMU freshness, bus contention, robot mounting 차이 때문에 바로 "정답"이라고 쓰면 안 됩니다.
- 사용자가 원한 방향대로, UI에서 두 모드를 모두 골라서 실제 session 로그로 비교할 수 있게 만드세요.

---

## 1. 현재 기준 상태

작업 전 반드시 아래 파일을 읽으세요.

```text
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/V110_HYBRID_REVIEW_PROMPT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/GYRO_BALANCE_ROOT_CAUSE_REPORT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/GYRO_BALANCE_SIMULATION_REPORT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/BalanceCorrector.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/GyroCorrectorControls.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift
```

2026-05-17 현재 확인한 사실:

- `swift test`는 `DarwinForge`에서 349개 테스트 모두 통과했습니다.
- 하지만 테스트 통과가 실제 로봇 안정성을 보장하지는 않습니다.
- 현재 구현은 `BalanceCorrector.robotisDefault` 이름 아래 v1.10 gain과 Hybrid default가 섞여 있어 이름이 혼란스럽습니다.
- 현재 Hybrid phase는 `sessionStartedAt` 기준 elapsed time을 사용합니다. 이것은 실제 walking cycle phase와 다를 수 있습니다.
- 현재 `periodMs`는 `currentWalkTuning()?.periodMs ?? 0`입니다. preset walking에서 tuning이 nil이면 phase-locked correction이 사실상 꺼질 수 있습니다.
- 현재 IMU 전용 50ms Task는 존재하지만 bus 직렬화가 코드로 보장되는지 확인해야 합니다. "mutex가 있을 것으로 가정"하는 주석만으로는 부족합니다.

---

## 2. 구현 목표

WalkLab의 자이로 보정 영역에 "Balance Experiment" UI를 추가하세요.

이 UI는 사용자가 코드를 수정하지 않고 아래 조합을 테스트할 수 있어야 합니다.

| 축 | 선택지 | 기본값 |
|---|---|---|
| 보정 방식 | 꺼짐 / ROBOTIS P-control / Hybrid B+A / 관찰만 | ROBOTIS P-control 또는 기존 설정 유지, 단 명확히 표시 |
| 부호 기준 | ROBOTIS 기준 / 반대 부호 실험 | ROBOTIS 기준 |
| gain profile | ROBOTIS 원본 / v1.10 추천 / 사용자 지정 | v1.10 추천은 실험 라벨 표시 |
| 적용 대상 | 시뮬레이션만 / 실제 로봇 적용 | 시뮬레이션만 또는 현재 안전 정책 유지 |

핵심 UX:

- 사용자는 개발자가 아니어도 "지금 로봇에 어떤 보정이 들어가는지" 한눈에 이해해야 합니다.
- `Hybrid`, `ROBOTIS`, `sign convention` 같은 기술 용어만 노출하지 말고 쉬운 라벨을 같이 붙이세요.
- 예: `Hybrid B+A (실험)`, `ROBOTIS 기본 보정`, `ROBOTIS 부호 기준`, `반대 부호 실험`
- 실제 로봇 적용은 cradle 확인, 위험 안내, expert/diagnostic gate를 통과해야 합니다.
- 반대 부호 실험은 기본 UI에 크게 노출하지 말고 진단 섹션에 넣으세요.

---

## 3. 코드 구조 제안

### 3.1 새 configuration 타입

`WalkLabSession+Types.swift` 또는 별도 파일에 아래 개념을 추가하세요.

```swift
public enum BalanceAlgorithmMode: String, CaseIterable, Codable, Sendable {
    case off
    case robotisPControl
    case hybridBA
    case observeOnly
}

public enum BalanceSignConvention: String, CaseIterable, Codable, Sendable {
    case robotisWalkingCpp
    case alternateDiagnostic
}

public enum BalanceGainProfile: String, CaseIterable, Codable, Sendable {
    case robotisOriginal
    case v110Recommended
    case custom
}

public struct BalanceExperimentConfig: Codable, Equatable, Sendable {
    public var algorithmMode: BalanceAlgorithmMode
    public var signConvention: BalanceSignConvention
    public var gainProfile: BalanceGainProfile
    public var applyToRobot: Bool
    public var logOnly: Bool
}
```

필요하면 이름은 프로젝트 convention에 맞게 바꿔도 됩니다. 중요한 것은 **algorithm**, **sign**, **gain**, **apply/log-only**를 분리하는 것입니다.

### 3.2 `BalanceCorrector.robotisDefault` 정리

현재 `robotisDefault`라는 이름에 v1.10 Hybrid/gain이 섞이면 이후 판단이 흐려집니다.

권장:

```swift
public static let robotisOriginal = BalanceCorrector(
    hipRollGain: 0.5,
    kneeGain: 0.3,
    anklePitchGain: 0.9,
    ankleRollGain: 1.0,
    enableHybrid: false
)

public static let v110Recommended = BalanceCorrector(
    hipRollGain: 0.5,
    kneeGain: 0.3,
    anklePitchGain: 1.5,
    ankleRollGain: 0.5,
    enableHybrid: true
)
```

기존 API 호환 때문에 `robotisDefault`를 바로 지우기 어렵다면 alias로 남기되, 테스트와 UI에서는 명확한 이름을 쓰세요.

### 3.3 sign convention 적용

`BalanceCorrector.corrections()`에 sign convention을 반영하세요.

권장 방향:

- `robotisWalkingCpp`: 현재 root-cause 보고서에서 확인한 ROBOTIS oracle 부호
- `alternateDiagnostic`: pitch/roll correction 부호를 실험적으로 반전

주의:

- 반대 부호는 "추천"이 아니라 "진단 실험"입니다.
- UI와 로그에 반드시 `diagnostic` 또는 `실험`이라고 표시하세요.
- 실제 로봇 적용 시에는 cradle 확인과 명시적 적용 버튼을 요구하세요.

### 3.4 Hybrid phase source 수정

현재 Hybrid가 `sessionStartedAt` 기준 elapsed time을 쓰면 실제 walking cycle phase와 어긋날 수 있습니다.

수정 방향:

- `elapsedMs`는 session 전체 시간보다 **현재 walking cycle의 phase time**이어야 합니다.
- continuous walk loop에서 cycle start time 또는 normalized phase를 추적하세요.
- `runContinuousWalk`, cycle step scheduler, 또는 pose transform 호출 지점에서 현재 phase를 `WalkLabSession`에 저장하세요.
- `applyBalanceCorrectionIfEnabled(to:)`는 저장된 cycle phase를 읽어 Hybrid에 전달하세요.

최소 수정:

```swift
let periodMs = effectiveWalkPeriodMsForCurrentPreset()
let elapsedMs = currentCycleElapsedMsModuloPeriod()
```

`currentWalkTuning()?.periodMs ?? 0`는 그대로 두지 마세요. preset walking에서도 period가 잡혀야 합니다.

예:

```swift
private func effectiveWalkPeriodMs() -> Double {
    if let tuning = currentWalkTuning() {
        return Double(tuning.periodMs)
    }
    guard current != .idle else { return 0 }
    return Double(WalkMotionLibrary.defaultTuning(for: current).periodMs)
}
```

프로젝트 실제 API 이름에 맞게 조정하세요.

### 3.5 observe-only mode

`observeOnly`는 보정값을 계산하고 로그에 남기지만 pose에는 적용하지 않는 모드입니다.

목적:

- 실제 로봇을 위험하게 움직이지 않고 Hybrid와 alternate sign의 예상 correction을 볼 수 있게 합니다.
- 사용자가 UI에서 "이 보정이 실제로 어느 관절을 얼마나 밀려고 하는지" 확인할 수 있습니다.

동작:

- `lastCorrections`와 진단 UI에는 candidate correction을 표시
- 실제 `RobotPose`는 원본 pose 반환
- 로그에는 `correctionAppliedToRobot = false` 기록

---

## 4. UI 요구사항

`GyroCorrectorControls.swift` 또는 WalkLab 진단 섹션에 다음 컨트롤을 추가하세요.

### 4.1 Balance Experiment 패널

패널 구조:

1. 보정 방식 segmented control
2. 부호 기준 segmented control
3. gain profile picker
4. 실제 로봇 적용 toggle
5. 현재 correction preview
6. A/B 기록 버튼
7. 최근 비교 결과 table

권장 라벨:

```text
보정 방식
- 꺼짐
- ROBOTIS 기본
- Hybrid B+A 실험
- 관찰만

부호 기준
- ROBOTIS 기준
- 반대 부호 실험

Gain
- ROBOTIS 원본
- v1.10 추천
- 사용자 지정

적용
- 시뮬레이션만
- 실제 로봇에도 적용
```

UI 문구 원칙:

- "정답", "완료", "안정 보장" 같은 단정 문구를 쓰지 마세요.
- "실험", "관찰", "비교", "ROBOTIS 기준"처럼 상태를 정확히 표현하세요.
- 사용자 입장에서는 기술보다 결과가 중요합니다. 예: `앞뒤 흔들림`, `좌우 흔들림`, `진동`, `IMU 신선도`.

### 4.2 Safety gate

실제 로봇 적용이 켜질 때는 아래 조건을 만족해야 합니다.

- cradle confirmed
- current preset이 위험도가 낮은 slow/march 계열
- intensity level 4는 별도 확인 필요
- alternateDiagnostic sign은 기본적으로 `observeOnly`에서만 시작
- emergency stop 버튼이 같은 화면에서 보임

### 4.3 A/B 비교 UX

사용자가 한 번에 한 변수만 바꿔 비교하도록 유도하세요.

버튼 예:

```text
A 기준 기록
B 실험 기록
비교 보기
초기화
```

비교 테이블 metric:

- 평균 앞뒤 기울기 `meanAbsPitch`
- 평균 좌우 기울기 `meanAbsRoll`
- 최대 tilt
- oscillation score
- correction effectiveness score
- IMU stale ratio
- emergency / danger count
- 적용 mode, sign, gain profile

---

## 5. 로그 요구사항

session JSONL 또는 기존 persistent event에 아래 필드를 추가하세요.

```json
{
  "balanceAlgorithmMode": "hybridBA",
  "balanceSignConvention": "robotisWalkingCpp",
  "balanceGainProfile": "v110Recommended",
  "correctionAppliedToRobot": true,
  "observeOnly": false,
  "imuSampleAgeMs": 42,
  "walkPeriodMs": 600,
  "walkCycleElapsedMs": 184,
  "expectedPitchDeg": 4.68,
  "expectedRollDeg": 0.0,
  "emaPitchDeg": -11.9,
  "emaRollDeg": 1.2,
  "effectivePitchErrDeg": 0.7,
  "effectiveRollErrDeg": -0.3,
  "rKneeCorrectionDeg": -0.08,
  "lKneeCorrectionDeg": 0.08,
  "rAnklePitchCorrectionDeg": 0.19,
  "lAnklePitchCorrectionDeg": -0.19
}
```

중요:

- mode/sign/gain이 로그에 없으면 나중에 어떤 실험이 효과적이었는지 판단할 수 없습니다.
- Hybrid phase 값도 반드시 남기세요. phase가 틀리면 Hybrid 성능 평가 자체가 무의미합니다.
- `correctionAppliedToRobot`을 남겨 observe-only와 실제 적용 데이터를 분리하세요.

---

## 6. IMU polling과 bus 직렬화

현재 문서에는 IMU 전용 50ms Task가 있다고 되어 있습니다. 구현도 확인해야 합니다.

주의점:

- USB-TTL half-duplex bus에서 joint read/write와 IMU read가 동시에 나가면 packet collision이나 latency spike가 날 수 있습니다.
- `Task.detached`를 여러 곳에서 쓰는 것만으로는 안전이 보장되지 않습니다.
- bus access는 actor, serial queue, mutex 중 하나로 **코드 레벨에서 직렬화**해야 합니다.

구현 기준:

- 모든 `bus.readImu()`, `bus.readState()`, `bus.write*()` 경로가 같은 serialization boundary를 거치는지 확인
- IMU sample에 timestamp를 붙임
- WalkLab correction에서 `imuSampleAgeMs`가 너무 오래되면 correction을 줄이거나 observe-only로 기록
- stale threshold를 테스트로 고정

---

## 7. 테스트 요구사항

반드시 테스트를 추가하거나 기존 테스트를 수정하세요.

필수 테스트:

1. `BalanceAlgorithmMode`와 `BalanceSignConvention`이 Codable round-trip 됩니다.
2. ROBOTIS sign convention에서 `pitchErrDeg > 0`일 때 knee/ankle pitch 부호가 ROBOTIS oracle과 일치합니다.
3. alternateDiagnostic sign이 ROBOTIS와 반대 방향 correction을 만듭니다.
4. Hybrid mode와 ROBOTIS P-control mode를 UI/session config로 선택할 수 있습니다.
5. observe-only mode는 correction을 계산하지만 pose를 바꾸지 않습니다.
6. preset walking에서도 Hybrid `periodMs`가 0이 되지 않습니다.
7. Hybrid phase는 session start wall-clock이 아니라 walking cycle phase를 사용합니다.
8. 로그에 algorithm/sign/gain/phase/effective error/applied flag가 포함됩니다.
9. IMU stale sample에서는 correction이 과하게 적용되지 않습니다.
10. `swift test` 전체가 통과합니다.

가능하면 테스트 이름을 직관적으로 만드세요.

예:

```swift
func testRobotisSignConventionMatchesWalkingCppOracle()
func testAlternateSignConventionInvertsDiagnosticCorrections()
func testObserveOnlyComputesCorrectionsWithoutChangingPose()
func testHybridUsesPresetPeriodWhenAdvancedTuningIsNil()
func testHybridPhaseUsesWalkCycleClock()
func testBalanceExperimentLogIncludesModeAndSign()
```

---

## 8. 구현 순서

권장 순서대로 진행하세요.

1. 현재 테스트 상태 확인

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test
```

2. configuration enum/struct 추가
3. `BalanceCorrector`에 sign convention과 gain profile 분리
4. `WalkLabSession`에 `balanceExperimentConfig` 추가
5. `makeCorrector`가 config 기반으로 corrector를 만들게 변경
6. `applyBalanceCorrectionIfEnabled`에서 algorithm mode 분기
7. Hybrid `periodMs`와 `elapsedMs`를 cycle 기준으로 수정
8. observe-only mode 구현
9. JSONL/event logging에 mode/sign/gain/phase/effective error 추가
10. `GyroCorrectorControls` 또는 WalkLab 진단 UI에 선택 패널 추가
11. safety gate와 실제 로봇 적용 toggle 추가
12. 테스트 추가
13. 아래 검증 명령 실행

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test

cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/core
cargo test
```

---

## 9. 피해야 할 구현

아래는 하지 마세요.

- Hybrid를 무조건 정답으로 가정하고 기존 P-control 선택지를 제거
- ROBOTIS 부호를 무시하고 alternate sign을 기본값으로 설정
- `robotisDefault`라는 이름에 v1.10 실험값을 계속 섞어서 사용
- session start time을 walking phase로 계속 사용
- `periodMs = 0`인 상태에서 Hybrid 성능을 평가
- IMU polling을 빠르게만 만들고 bus serialization을 검증하지 않음
- 로그에 mode/sign/gain 없이 평균 tilt만 저장
- 실제 로봇에 alternate sign을 바로 적용하는 UI
- 테스트 expectation만 바꿔서 현재 구현을 통과시키는 방식

---

## 10. 완료 기준

완료라고 말하려면 아래를 만족해야 합니다.

- 사용자가 UI에서 `ROBOTIS 기본`과 `Hybrid B+A 실험`을 선택할 수 있음
- 사용자가 UI에서 `ROBOTIS 기준`과 `반대 부호 실험`을 구분해서 볼 수 있음
- 실제 로봇 적용 여부가 명확히 표시됨
- observe-only mode로 위험 없이 candidate correction을 볼 수 있음
- session 로그에 mode/sign/gain/phase/effective error/applied flag가 남음
- A/B 비교에 필요한 metric이 기록됨
- `swift test` 통과
- `cargo test` 통과
- 문서에 "Hybrid는 실험", "ROBOTIS 부호는 기본 기준"이라는 현재 판단이 명확히 남음

---

## 11. 최종 보고 형식

작업 완료 후 아래 형식으로 보고하세요.

```text
구현 요약
- 추가한 UI:
- 추가한 configuration:
- sign convention 처리:
- Hybrid phase 수정:
- observe-only 동작:
- 로그 필드:

검증
- swift test: pass/fail
- cargo test: pass/fail

남은 리스크
- 실제 로봇 검증 전까지 확정할 수 없는 항목:
- 사용자가 다음 session에서 비교해야 할 항목:
```

남은 리스크를 숨기지 마세요. 이 작업의 목적은 "정답을 미리 선언"하는 것이 아니라, 실제 데이터로 정답을 찾을 수 있는 UI와 로그 구조를 만드는 것입니다.
