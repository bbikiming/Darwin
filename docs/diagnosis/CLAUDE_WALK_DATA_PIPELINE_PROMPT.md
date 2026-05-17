# Claude 구현 프롬프트: WalkLab 보행 데이터 저장·분류·학습 반영 파이프라인

> 이 문서는 Claude에게 그대로 전달하기 위한 상세 구현 프롬프트입니다.
> 목표는 WalkLab이 수집하는 보행 데이터를 "그럴듯한 로그"가 아니라, 실제 보정 알고리즘 개선에 쓸 수 있는 신뢰 가능한 데이터셋으로 만드는 것입니다.

---

## 0. 작업 태도

이 작업에서는 절대 낙관적으로 단정하지 마세요.

- 데이터가 많아 보여도 IMU가 중복이면 유효 샘플은 적습니다.
- 테스트가 통과해도 실제 로봇 안정성이 증명된 것은 아닙니다.
- 평균 tilt 하나만 보고 보정 강도를 자동 변경하면 위험합니다.
- "좋아졌다/나빠졌다"는 같은 조건의 A/B 비교와 데이터 품질 게이트를 통과한 뒤에만 말하세요.

Claude는 솔직하게 판단해야 합니다.

- 품질이 낮은 데이터는 `inconclusive`로 분류하세요.
- 알고리즘 개선에 쓰면 안 되는 데이터는 명확히 제외하세요.
- 사용자에게는 "왜 이 데이터가 유용하지 않은지"를 UI와 summary에 보여주세요.

---

## 1. 현재 확인된 데이터 상태

현재 저장 위치:

```text
~/Library/Application Support/DarwinForge/sessions/*.jsonl
~/Library/Application Support/DarwinForge/sessions/*.summary.json
```

2026-05-17 기준 현재 로그 진단 결과:

| 항목 | 값 |
|---|---:|
| JSONL session 파일 수 | 21 |
| 총 sample 수 | 1,749 |
| parse error | 0 |
| 전체 평균 roll | +1.09 deg |
| 전체 평균 pitch | -12.89 deg |
| 전체 평균 abs roll | 8.99 deg |
| 전체 평균 abs pitch | 13.09 deg |
| peak abs roll | 37.10 deg |
| peak abs pitch | 37.22 deg |
| nominal sample rate | 약 14.8 Hz |
| 실제 IMU 값 변화율 | 약 1.5 Hz |
| 연속 IMU 중복률 | 약 90.9% |
| 60 sample 이상 session | 7 / 21 |
| normalWalk sample | 2개뿐 |

냉정한 결론:

- 현재 데이터는 **만성 pitch bias 확인용 baseline**으로는 유용합니다.
- 그러나 **Hybrid vs ROBOTIS P-control**, **ROBOTIS 부호 vs 반대 부호**, **gain 자동 튜닝**을 판정하기에는 부족합니다.
- 가장 큰 문제는 `50ms tick마다 기록`은 하지만 실제 IMU 값이 대부분 반복된다는 점입니다.
- 지금 summary의 `sampleCount >= 60` 기준은 과대평가될 수 있습니다. 60 sample이라도 IMU가 90% 중복이면 독립 샘플은 6개 수준입니다.

---

## 2. 반드시 읽을 파일

작업 전 아래 파일을 먼저 확인하세요.

```text
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/CLAUDE_V110_BALANCE_IMPLEMENTATION_PROMPT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/V110_HYBRID_REVIEW_PROMPT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/GYRO_BALANCE_ROOT_CAUSE_REPORT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/docs/diagnosis/GYRO_BALANCE_SIMULATION_REPORT.md
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionSample.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionLogger.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkSessionAnalyzer.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift
```

현재 `WalkSessionSample`에는 기본 필드만 있습니다:

- `t`
- `preset`
- `intensityLevel`
- `imuRollDeg`
- `imuPitchDeg`
- `correctorRollErrDeg`
- `correctorPitchErrDeg`
- `balanceState`
- `correctorDeltas`
- `imuSource`
- `batteryVolts`
- `motorAvgTemp`

이것만으로는 보정 알고리즘 개선에 충분하지 않습니다.

---

## 3. 구현 목표

WalkLab 데이터 파이프라인을 v2로 올리세요.

목표는 네 가지입니다.

1. **저장**: 원본 측정값, 보정 계산값, 알고리즘 설정값, 사용자/안전 이벤트를 누락 없이 저장
2. **분류**: 각 session을 usable / inconclusive / rejected / safetyIncident 등으로 자동 분류
3. **분석**: 단순 평균이 아니라 데이터 품질, IMU freshness, phase, lagged correction effect까지 계산
4. **알고리즘 반영**: 품질 좋은 데이터만 보정 강도, sign 검증, Hybrid phase/gain 개선에 반영

---

## 4. 데이터 저장 v2 설계

### 4.1 파일 포맷

기존 JSONL은 유지하되 line type을 명시하세요.

```json
{"type":"header","schemaVersion":2,...}
{"type":"sample","schemaVersion":2,...}
{"type":"event","schemaVersion":2,...}
{"type":"footer","schemaVersion":2,...}
```

이유:

- 현재는 첫 줄 header, 나머지 sample이라는 암묵 규칙입니다.
- 앞으로 event, footer, quality report를 넣으려면 line type이 있어야 합니다.
- 기존 v1 로그도 계속 decode 가능해야 합니다.

### 4.2 Header v2 필드

`WalkSessionHeaderV2` 또는 기존 header 확장으로 아래 필드를 추가하세요.

```swift
public struct WalkSessionHeaderV2: Codable, Sendable {
    public let type: String
    public let schemaVersion: Int
    public let sessionId: String
    public let startTimeIso: String
    public let appVersion: String
    public let gitCommit: String?

    public let isRealRobot: Bool
    public let robotProfileId: String?
    public let operatorNote: String?
    public let surfaceType: String?
    public let supportMode: String? // cradle, handSupport, floor, unknown

    public let preset: String
    public let walkTuning: WalkTuningSnapshot

    public let balanceAlgorithmMode: String
    public let balanceSignConvention: String
    public let balanceGainProfile: String
    public let correctorIntensityLevelAtStart: Int
    public let correctionApplyMode: String // off, observeOnly, simOnly, robotApplied

    public let imuSourceAtStart: String
    public let imuCalibrationId: String?
    public let imuScaleSuspicionAtStart: String

    public let safetyPolicy: SafetyPolicySnapshot
}
```

필수 의도:

- 나중에 파일 하나만 봐도 어떤 알고리즘, 어떤 부호, 어떤 gain으로 걸었는지 알아야 합니다.
- `intensityLevel`만 저장하면 Hybrid인지 ROBOTIS인지 알 수 없습니다.
- `supportMode`가 없으면 cradle 테스트와 실제 floor walk가 섞입니다.

### 4.3 Sample v2 필드

`WalkSessionSampleV2`에는 현재 필드에 아래를 추가하세요.

```swift
public struct WalkSessionSampleV2: Codable, Sendable {
    public let type: String
    public let schemaVersion: Int

    public let tMs: Double
    public let wallTimeIso: String
    public let tickIndex: Int
    public let tickDtMs: Double

    public let preset: String
    public let walkPeriodMs: Double
    public let walkCycleElapsedMs: Double
    public let walkPhase01: Double
    public let plannedStepIndex: Int?

    public let imuSource: String
    public let imuSequence: UInt64?
    public let imuReadAtMs: Double?
    public let imuSampleAgeMs: Double?
    public let imuDuplicate: Bool
    public let imuStale: Bool

    public let rawAccelX: Double?
    public let rawAccelY: Double?
    public let rawAccelZ: Double?
    public let rawGyroX: Double?
    public let rawGyroY: Double?
    public let rawGyroZ: Double?
    public let imuRollDeg: Double
    public let imuPitchDeg: Double

    public let balanceAlgorithmMode: String
    public let balanceSignConvention: String
    public let balanceGainProfile: String
    public let correctionAppliedToRobot: Bool
    public let observeOnly: Bool

    public let expectedPitchDeg: Double?
    public let expectedRollDeg: Double?
    public let emaPitchDeg: Double?
    public let emaRollDeg: Double?
    public let effectivePitchErrDeg: Double
    public let effectiveRollErrDeg: Double

    public let correctorDeltas: [Double]
    public let candidateDeltas: [Double]?
    public let appliedDeltas: [Double]
    public let maxCorrectionDeg: Double

    public let targetPoseLowerBodyDeg: [String: Double]?
    public let appliedPoseLowerBodyDeg: [String: Double]?

    public let balanceState: String
    public let batteryVolts: Double?
    public let motorAvgTemp: Double?
    public let busWriteFailureCount: Int
    public let busReadFailureCount: Int
}
```

중요:

- `imuSampleAgeMs`는 필수입니다. 없으면 stale 데이터를 구분할 수 없습니다.
- `imuDuplicate`는 필수입니다. 중복 sample을 독립 데이터처럼 쓰면 안 됩니다.
- `walkCycleElapsedMs`와 `walkPhase01`은 Hybrid 검증의 핵심입니다.
- `candidateDeltas`와 `appliedDeltas`를 분리하세요. observe-only에서는 candidate만 있고 applied는 0이어야 합니다.
- raw IMU는 가능하면 저장하세요. 나중에 scale/axis 문제를 재검증할 수 있습니다.

### 4.4 Event v2 필드

보행 중 사용자와 안전 이벤트를 sample과 별도로 저장하세요.

```swift
public struct WalkSessionEventV2: Codable, Sendable {
    public let type: String
    public let schemaVersion: Int
    public let tMs: Double
    public let wallTimeIso: String
    public let kind: String
    public let severity: String
    public let message: String
    public let payload: [String: String]
}
```

이벤트 예:

- sessionStart
- sessionStop
- presetChange
- algorithmModeChange
- signConventionChange
- intensityChange
- observeOnlyEnabled
- robotApplyEnabled
- imuStale
- imuRecovered
- busWriteFailure
- emergencyStop
- userNote

---

## 5. 데이터 품질 분류

`WalkSessionDataQuality` 타입을 추가하세요.

```swift
public enum WalkSessionUseClass: String, Codable, Sendable {
    case usableForComparison
    case usableForBiasOnly
    case usableForSafetyReview
    case inconclusive
    case rejected
}

public struct WalkSessionDataQuality: Codable, Sendable {
    public let useClass: WalkSessionUseClass
    public let grade: String // A, B, C, D, F
    public let reasons: [String]

    public let durationSec: Double
    public let sampleCount: Int
    public let independentImuSampleCount: Int
    public let imuDuplicateRatio: Double
    public let nominalSampleRateHz: Double
    public let effectiveImuRateHz: Double

    public let medianImuAgeMs: Double?
    public let p95ImuAgeMs: Double?
    public let staleRatio: Double

    public let busFailureCount: Int
    public let emergencyCount: Int
}
```

### 5.1 품질 등급 기준

초기 기준은 보수적으로 잡으세요.

| Grade | 조건 | 사용처 |
|---|---|---|
| A | 10초 이상, independent IMU 100개 이상, stale < 5%, duplicate < 20%, 같은 조건 A/B 가능 | 알고리즘 비교 가능 |
| B | 8초 이상, independent IMU 60개 이상, stale < 10%, duplicate < 40% | 조심스러운 비교 가능 |
| C | 5초 이상, independent IMU 25개 이상 | bias 확인 가능 |
| D | 2초 이상 또는 중복률 높음 | 참고만 가능 |
| F | 2초 미만, emergency, schema 불완전, IMU stale 심함 | 분석 제외 |

현재 기존 로그는 대부분 C/D/F로 분류되어야 합니다. 특히 IMU 중복률 90%인 session은 알고리즘 비교에 쓰면 안 됩니다.

### 5.2 분류 원칙

- `sampleCount`가 아니라 `independentImuSampleCount`를 기준으로 판단하세요.
- 같은 IMU 값이 반복된 tick은 시간축 분석과 correlation에서 가중치를 낮추거나 제외하세요.
- `imuSampleAgeMs > 250ms`는 stale 후보입니다.
- `imuSampleAgeMs > 500ms`는 보정 알고리즘 검증에서 제외하세요.
- emergency stop이 발생한 session은 `safetyReview`로 분리하고 자동 튜닝에 쓰지 마세요.
- cradle/hand support/floor 조건이 섞이면 비교 데이터로 쓰지 마세요.

---

## 6. 분석 알고리즘 개선

현재 `WalkSessionAnalyzer`는 평균 tilt, zero-crossing, same-sample correlation 중심입니다.
이 방식은 baseline 표시용으로는 괜찮지만 자동 튜닝에는 부족합니다.

### 6.1 분석 metric 추가

`WalkSessionSummaryV2`에 아래 metric을 추가하세요.

```swift
public struct WalkSessionSummaryV2: Codable, Sendable, Identifiable {
    public let id: String
    public let schemaVersion: Int
    public let preset: String
    public let startTimeIso: String
    public let durationSec: Double

    public let dataQuality: WalkSessionDataQuality

    public let meanRollDeg: Double
    public let meanPitchDeg: Double
    public let meanAbsRollDeg: Double
    public let meanAbsPitchDeg: Double
    public let peakAbsRollDeg: Double
    public let peakAbsPitchDeg: Double
    public let rollStdevDeg: Double
    public let pitchStdevDeg: Double

    public let pitchBiasDeg: Double
    public let rollBiasDeg: Double

    public let oscillationPitchHz: Double
    public let oscillationRollHz: Double

    public let laggedPitchEffectiveness: Double?
    public let laggedRollEffectiveness: Double?
    public let bestLagMs: Double?

    public let phaseResidualPitchRms: Double?
    public let phaseResidualRollRms: Double?

    public let recommendation: WalkSessionRecommendation
}
```

### 6.2 lagged effectiveness

same-sample correlation만으로 보정 효과를 판단하지 마세요.

이유:

- correction은 IMU 값을 입력으로 계산되므로 같은 tick correlation은 기계적으로 높게 나올 수 있습니다.
- 실제 효과는 correction 이후 100-500ms 뒤 tilt가 줄었는지 봐야 합니다.

구현:

1. correction(t)와 `-deltaTilt(t + lag)`의 correlation을 계산
2. lag 후보: 100ms, 150ms, 200ms, 250ms, 300ms, 400ms, 500ms
3. 가장 좋은 lag와 score를 summary에 저장
4. stale/duplicate sample은 제외

판정:

- `laggedEffectiveness > +0.3`: 회복 방향 가능성
- `-0.3...+0.3`: 불명확
- `< -0.3`: 반대 방향 또는 phase 오류 의심

### 6.3 phase residual 분석

Hybrid 검증에는 phase 분석이 필요합니다.

계산:

```text
expectedPitch = swayAmp * sin(2π * walkPhase01 + phaseOffset)
residualPitch = imuPitchDeg - pitchEma - expectedPitch
```

해야 할 일:

- phase bin 12개 또는 16개로 나눠 pitch/roll 평균을 저장
- expectedPitch와 실제 pitch의 phase offset을 추정
- phase가 맞지 않으면 Hybrid 개선이 아니라 악화가 될 수 있음을 summary에 표시

주의:

- phase offset 추정은 A/B 실험용으로만 쓰세요.
- 바로 실시간 제어에 자동 적용하지 마세요.

---

## 7. 데이터 분류 체계

세션마다 아래 classification을 붙이세요.

### 7.1 Trial purpose

```swift
public enum WalkTrialPurpose: String, Codable, Sendable {
    case calibrationIdle
    case baselineLegacy
    case robotisPControl
    case hybridObserveOnly
    case hybridApplied
    case signDiagnosticObserveOnly
    case signDiagnosticApplied
    case safetyIncident
    case unknown
}
```

### 7.2 Comparison group

A/B 비교를 위해 group id를 저장하세요.

```swift
public struct WalkComparisonTag: Codable, Sendable {
    public let groupId: String
    public let arm: String // A or B
    public let variableChanged: String // algorithm, sign, gain, intensity
    public let baselineSessionId: String?
}
```

원칙:

- A/B는 한 번에 하나의 변수만 바꾸세요.
- preset, support mode, surface, battery range가 다르면 같은 group으로 묶지 마세요.
- A/B 간 시간이 너무 멀면 비교 신뢰도를 낮추세요.

### 7.3 Recommendation class

```swift
public enum RecommendationAction: String, Codable, Sendable {
    case keepCurrent
    case lowerIntensity
    case raiseIntensity
    case switchToObserveOnly
    case markSignSuspicious
    case markHybridPhaseSuspicious
    case collectMoreData
    case doNotUseForLearning
}
```

중요:

- low quality session은 항상 `collectMoreData` 또는 `doNotUseForLearning`이어야 합니다.
- `raiseIntensity`는 stale/duplicate가 적고 lagged effectiveness가 양수일 때만 허용하세요.
- sign suspicious는 한 session만으로 확정하지 말고, 같은 preset에서 2-3개 이상 반복 확인이 필요합니다.

---

## 8. 알고리즘에 반영하는 규칙

자동 개선은 단계적으로만 허용하세요.

### 8.1 Bias 보정

사용 가능한 데이터:

- `usableForBiasOnly` 이상
- floor/support mode가 명확함
- IMU scale suspicion 정상
- pitch mean이 여러 session에서 같은 방향으로 반복

반영:

- chronic pitch bias 추정에 사용
- Hybrid EMA 초기값 또는 calibration hint로만 사용
- 즉시 큰 correction offset으로 적용하지 않음

### 8.2 Gain tuning

사용 가능한 데이터:

- `usableForComparison`만
- A/B group이 있고 한 변수만 변경
- stale ratio 낮음
- emergency 없음

반영:

- intensity recommendation만 제안
- 자동 적용은 사용자가 켠 경우에도 conservative step만 허용
- level 4 또는 experimental sign은 자동 적용 금지

### 8.3 Sign convention 검증

사용 가능한 데이터:

- observe-only 또는 low-risk applied test
- lagged effectiveness가 충분함
- 같은 preset/조건에서 반복됨

반영:

- 기본값은 계속 ROBOTIS sign
- alternate sign이 좋아 보여도 바로 기본값 변경 금지
- UI에 `ROBOTIS 부호 의심`, `반대 부호 실험 필요` 정도로 표시

### 8.4 Hybrid phase/gain 개선

사용 가능한 데이터:

- Hybrid observe-only와 applied session이 분리되어 있음
- walk phase가 저장되어 있음
- expectedPitch, residual, EMA 값이 저장되어 있음

반영:

- phase offset / sway amplitude 후보를 summary에 제안
- 실시간 Hybrid 파라미터 자동 변경은 금지
- 사용자가 실험 profile로 선택할 수 있게만 함

---

## 9. UI 요구사항

데이터 UI는 개발자용 숫자판이 아니라, 사용자가 판단할 수 있는 실험 노트여야 합니다.

### 9.1 Session list

각 session row에 표시:

- preset
- duration
- data quality grade
- usable / inconclusive / rejected
- algorithm mode
- sign convention
- gain profile
- mean abs pitch/roll
- IMU duplicate ratio
- stale ratio
- recommendation

라벨 예:

```text
데이터 품질 C · bias 확인만 가능
IMU 중복 91% · 알고리즘 비교에는 사용 안 함
Hybrid 실험 · observe-only · 실제 로봇 미적용
```

### 9.2 Quality detail panel

사용자가 왜 데이터가 탈락했는지 봐야 합니다.

표시:

- 독립 IMU 샘플 수
- nominal rate vs effective rate
- IMU sample age median/p95
- duplicate ratio
- bus failure count
- emergency count
- 누락 필드

### 9.3 A/B workflow

버튼:

- `A 기준 기록 시작`
- `B 실험 기록 시작`
- `한 변수만 바꾸기`
- `비교 결과 보기`

비교 결과:

- 좋아짐 / 나빠짐 / 판단 불가
- 판단 근거
- 데이터 품질 부족 사유
- 다음 추천 실험

중요:

- A/B 비교가 불가능하면 UI가 솔직히 `판단 불가`라고 말해야 합니다.
- 평균 tilt가 낮아져도 stale/duplicate가 심하면 개선으로 표시하지 마세요.

---

## 10. 기존 데이터 처리

기존 v1 로그는 버리지 마세요.

해야 할 일:

1. v1 decoder 유지
2. v1 로그를 `schemaVersion = 1`로 분류
3. v1에는 없는 필드를 nil로 처리
4. v1 데이터는 대부분 `usableForBiasOnly` 또는 `inconclusive`로 분류
5. v1 summary에는 `legacySchemaMissingFields` reason 추가

기존 21개 로그에 대한 예상 분류:

- 만성 pitch bias 확인: 가능
- 보정 강도 자동 튜닝: 보류
- Hybrid 효과 판정: 불가
- ROBOTIS sign 판정: 불가
- normalWalk 평가: sample 2개라 불가

---

## 11. 테스트 요구사항

필수 테스트를 추가하세요.

```swift
func testV1SessionLogStillDecodes()
func testV2SessionLogIncludesSchemaAndLineTypes()
func testDataQualityRejectsHighDuplicateRatio()
func testDataQualityUsesIndependentImuSampleCount()
func testShortSessionIsInconclusive()
func testMissingAlgorithmFieldsPreventsComparisonUse()
func testObserveOnlySeparatesCandidateAndAppliedDeltas()
func testLaggedEffectivenessIgnoresDuplicateSamples()
func testLowQualitySessionDoesNotRaiseIntensity()
func testABComparisonRequiresSingleChangedVariable()
func testHybridSummaryRequiresPhaseFields()
```

테스트 기준:

- 현재 같은 90% duplicate 데이터는 `usableForComparison`이 되면 안 됩니다.
- sampleCount가 충분해도 independent IMU가 부족하면 추천 confidence가 낮아야 합니다.
- old log decode를 깨뜨리면 안 됩니다.

---

## 12. 구현 순서

권장 순서:

1. 현재 로그 진단 script 또는 Swift helper 추가
2. `WalkSessionSample` / `Header` / `Summary` v2 모델 설계
3. v1/v2 decoder 호환 구현
4. logger에 line type과 schemaVersion 추가
5. IMU sample timestamp, sequence, age, duplicate flag 저장
6. algorithm/sign/gain/apply mode 저장
7. walk phase, period, expected pitch, EMA, effective error 저장
8. event line 저장
9. data quality analyzer 추가
10. recommendation logic이 quality gate를 통과한 데이터만 쓰도록 수정
11. session list UI에 quality badge와 rejection reason 표시
12. A/B comparison tag와 workflow 추가
13. 테스트 추가
14. 전체 검증 실행

검증 명령:

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test

cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/core
cargo test
```

---

## 13. 피해야 할 구현

하지 마세요.

- sampleCount만 보고 데이터가 충분하다고 판단
- 같은 IMU 값이 반복된 tick을 독립 샘플로 취급
- low quality session에서 intensity를 자동으로 올림
- 같은 tick correction/IMU correlation만 보고 보정 효과라고 주장
- Hybrid phase 필드 없이 Hybrid 성능을 평가
- algorithm/sign/gain 필드 없이 A/B 비교
- 기존 v1 로그를 새 schema로 억지 migration해서 없는 정보를 채워 넣음
- UI에 `개선됨`이라고 표시하면서 품질 사유를 숨김

---

## 14. 완료 기준

완료라고 말하려면 아래 조건을 만족해야 합니다.

- 새 로그에 `schemaVersion`과 line `type`이 들어감
- 각 sample에 IMU age, duplicate, algorithm, sign, gain, phase, correction applied flag가 들어감
- 기존 v1 로그도 깨지지 않고 읽힘
- session summary에 data quality grade와 use class가 들어감
- 현재처럼 IMU 중복률이 높은 데이터는 comparison/recommendation에서 제외됨
- low quality 데이터로 자동 gain 상승이 일어나지 않음
- UI에서 사용자가 왜 데이터가 유용/무용한지 이해할 수 있음
- A/B 비교는 한 변수만 바뀐 session끼리만 허용됨
- `swift test`와 `cargo test`가 통과함

---

## 15. 최종 보고 형식

작업 완료 후 아래 형식으로 보고하세요.

```text
구현 요약
- 새 저장 schema:
- 추가된 sample 필드:
- 추가된 event/summary 필드:
- 데이터 품질 분류:
- UI 변경:
- 자동 추천 제한:

현재 기존 데이터 재판정
- usable:
- bias only:
- inconclusive:
- rejected:
- 핵심 사유:

검증
- swift test:
- cargo test:

남은 리스크
- 실제 로봇에서 추가 수집해야 할 항목:
- 아직 자동화하면 안 되는 판단:
```

마지막으로, Claude는 개선 결과를 보고할 때 반드시 "데이터 품질"을 먼저 말해야 합니다. 데이터 품질을 통과하지 못하면 알고리즘 성능에 대한 결론은 내리지 마세요.
