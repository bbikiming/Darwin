# WalkLab 데이터 파이프라인 v2 — 핸드오프

> 워크랩 v2 데이터 스키마 / 디코더 / 로거 / 품질 분석 / A-B 비교 / UI 가 별도 worktree 에서 완성되어 있습니다.
> 본 문서는 v1.1 fall prevention 또는 v110 balance 작업을 진행하는 다음 터미널이 이 위에 보정 알고리즘 / 실 IMU 를 연결할 때 필요한 정보를 모은 것입니다.
> source-of-truth: `docs/diagnosis/CLAUDE_WALK_DATA_PIPELINE_PROMPT.md`

---

## 1. 작업 브랜치

- worktree: `claude/naughty-chebyshev-713072`
- base: `claude/robotis-darwin-op-setup-oyzTi` (main) merge 이후
- 본 worktree 는 BalanceCorrector / 실 IMU task / intensity level 이 도입되기 전 baseline 위에서 만들어졌습니다.
- v1.1 fall prevention 코드와 충돌하지 않도록 wiring 지점을 enum/string 기반으로 분리해 두었습니다.

---

## 2. 새 모듈 위치

```
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/
  WalkSessionLineType.swift          # line type / schemaVersion
  WalkSessionHeader.swift            # v1 + v2 header + Resolved
  WalkSessionSample.swift            # v1 + v2 sample + Resolved
  WalkSessionEvent.swift             # event v2 + footer
  WalkSessionSummary.swift           # summary v2
  WalkSessionDataQuality.swift       # useClass / grade / reasons / 한국어 라벨
  WalkSessionRecommendation.swift    # action / trialPurpose / 라벨
  WalkSessionComparisonTag.swift     # A/B tag
  WalkSessionDecoder.swift           # v1 자동 추정 + v2 decode
  WalkSessionLogger.swift            # v2 JSONL writer
  WalkSessionStore.swift             # 디스크 스캔 / summary read/write
  WalkSessionRecorder.swift          # WalkLabSession 이 호출하는 facade
  WalkSessionQualityAnalyzer.swift   # grade A..F + useClass
  WalkSessionMetricsAnalyzer.swift   # lagged effectiveness / phase residual / std
  WalkSessionAnalyzer.swift          # quality + metrics + recommendation 통합
  WalkSessionRecommender.swift       # quality-gate 추천 엔진
  WalkComparisonEngine.swift         # 한-변수-만 A/B 검증

app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/UI/
  WalkSessionQualityBadge.swift
  WalkSessionQualityDetailPanel.swift
  WalkSessionListView.swift
  WalkABComparisonPanel.swift
  WalkLearningView.swift              # 라이브 보행 ↔ 데이터 학습 탭의 후자

app/ui/DarwinForge/Tests/DarwinForgeUITests/WalkLabLearning/
  WalkSessionFixtures.swift           # v1/v2 JSONL 생성기
  WalkSessionDecoderTests.swift
  WalkSessionQualityTests.swift
  WalkSessionMetricsTests.swift
  WalkSessionRecommenderTests.swift
  WalkComparisonTests.swift
  WalkSessionLoggerTests.swift
  WalkSessionCodableTests.swift
  WalkSessionRealLogsTests.swift
  WalkSessionRealLogsReportTest.swift  # 21개 실 로그 재판정 report
```

수정된 파일 2개:

- `WalkLabSession.swift` — recorder 호출 + balance/thermal 이벤트
- `WalkLabView.swift` — `라이브 보행` / `데이터 학습` 탭

---

## 3. WalkLabSession 의 보정 컨텍스트 wiring 포인트

`WalkLabSession` 에 아래 public 필드가 추가되어 있습니다. 보정 알고리즘이 도입되면 corrector state 와 1:1 로 채우면 됩니다.

```swift
public var balanceAlgorithmMode: String = "off"          // off | robotisPControl | hybridBA | observeOnly
public var balanceSignConvention: String = "robotisWalkingCpp"  // robotisWalkingCpp | alternateDiagnostic
public var balanceGainProfile: String = "robotisOriginal"       // robotisOriginal | v110Recommended | custom
public var correctorIntensityLevel: Int = 1
public var correctionApplyMode: String = "simOnly"        // off | observeOnly | simOnly | robotApplied
public var imuSourceAtStart: String = "sim"               // sim | real
public var imuScaleSuspicionAtStart: String = "normal"
public var operatorNote: String?
public var comparisonTag: WalkComparisonTag?
```

값을 바꾸면 다음 `start(_:)` 부터 v2 header 에 자동 반영됩니다.

---

## 4. tick 데이터를 logger 로 흘리는 지점

`WalkLabSession.recordTick(foot:)` 안에서 `WalkSessionRecorder.TickData` 를 만들어 호출합니다.
baseline 에는 corrector 가 없어서 candidate/applied 모두 0 으로 들어갑니다. corrector 가 붙으면 아래만 채우면 됩니다.

```swift
WalkSessionRecorder.TickData(
    tMs: ...,
    walkCycleElapsedMs: ...,        // 현재 cycle 의 elapsed (NOT session start 기준)
    walkPhase01: ...,                // cycle 의 0..1 정규화 위상
    imuRollDeg: ..., imuPitchDeg: ...,
    imuSampleAgeMs: ...,             // 실 IMU sequence 기반. nil 이면 stale 판정 불가
    imuSequence: ...,                // IMU 측정 시퀀스 (있으면)
    effectivePitchErrDeg: ...,       // EMA 적용 후 corrector 가 본 err
    effectiveRollErrDeg: ...,
    candidateDeltas: [...],          // corrector.corrections() 결과
    appliedDeltas: [...],            // pose 에 실제 들어간 값 (observeOnly 면 [0...])
    correctionAppliedToRobot: ...,   // applyMode == "robotApplied"
    observeOnly: ...,                // applyMode == "observeOnly"
    balanceState: "ok" | "caution" | "danger",
    batteryVolts: ..., motorAvgTemp: ...,
    busWriteFailureCount: ..., busReadFailureCount: ...,
    intensityLevel: ...,
    expectedPitchDeg: ...,           // Hybrid 의 sin model 예측치
    expectedRollDeg: ...,
    emaPitchDeg: ..., emaRollDeg: ...
)
```

> ⚠️ `walkCycleElapsedMs` 는 반드시 **현재 cycle** 기준이어야 합니다.
> session start 기준의 elapsed 를 쓰면 Hybrid phase 검증이 무의미해집니다.
> V110_HYBRID_REVIEW_PROMPT 와 동일한 요구사항입니다.

---

## 5. 이벤트 기록 API

WalkLabSession 안에서 직접:

```swift
recorder.recordEvent(kind: .algorithmModeChange, message: "off → hybridBA",
                     payload: ["from": "off", "to": "hybridBA"])
recorder.recordEvent(kind: .signConventionChange, message: "ROBOTIS → alternateDiagnostic")
recorder.recordEvent(kind: .observeOnlyEnabled, message: "observe-only ON")
recorder.recordEvent(kind: .imuStale, severity: .warning, message: "imuSampleAgeMs=540")
recorder.recordEvent(kind: .busWriteFailure, severity: .error, message: "joint=lAnklePitch")
recorder.recordEvent(kind: .emergencyStop, severity: .critical, message: "balance lost")
```

`balanceLost` / `thermalAlarm` / `emergencyStop` / `sessionStart` / `sessionStop` 은 이미 WalkLabSession 안에서 자동 기록됩니다.

---

## 6. 자동 추천 게이트 규칙

(`WalkSessionRecommender.swift` 의 규칙 요약)

| 조건 | 추천 결과 |
|---|---|
| `emergencyCount > 0` | `doNotUseForLearning` + `safetyIncident` |
| `useClass == .rejected` (F) | `doNotUseForLearning` |
| `useClass == .inconclusive` (D) | `collectMoreData` |
| `useClass == .usableForBiasOnly` (C) | `keepCurrent` (intensity 조정 금지) |
| `usableForComparison` + lagged eff < -0.3 | `markSignSuspicious` |
| `usableForComparison` + 평균 abs tilt > 12° + lagged eff > 0.3 + stale < 10% + duplicate < 40% + level < 3 | `raiseIntensity` |
| `usableForComparison` + oscillation > 2.5Hz | `lowerIntensity` |

> **현재 21개 v1 로그 재판정 결과: 0 comparison · 2 biasOnly · 9 inconclusive · 10 rejected.**
> 자동 gain 상승은 일어날 수 없는 상태입니다.

---

## 7. A/B 비교 게이트

`WalkComparisonEngine.eligibility(baseline:experiment:)` 가 다음을 검사한 후에만 verdict 가 `.improved` / `.worsened` / `.inconclusive` 로 나옵니다. 하나라도 실패하면 `.incomparable`.

1. 두 세션 모두 `usableForComparison`
2. preset 동일
3. supportMode 동일 (둘 다 unknown 이면 경고)
4. 알고리즘 / 부호 / gain / intensity 중 **정확히 1개만** 다름

또한 experiment 의 stale ratio 또는 duplicate ratio 가 baseline 의 1.5배를 넘으면 평균 tilt 가 줄어도 `.inconclusive` 로 강등합니다 (품질이 같이 떨어지면 개선이라 부르지 않음).

---

## 8. 호환성 보장

- v1 (기존 21개) JSONL: decoder 가 line type 없어도 첫 줄=header / 나머지=sample 로 처리. `schemaVersion = .v1` 로 표시.
- 새 v2 로그: `"type"` + `"schemaVersion": 2` 명시.
- 같은 디렉토리 (`~/Library/Application Support/DarwinForge/sessions/`) 에서 v1/v2 가 섞여도 OK.
- 알고리즘 필드가 없는 v1 은 항상 `algorithmFieldsMissing` reason → comparison 분류에서 자동 제외.

---

## 9. 테스트 결과 (worktree 시점)

| 영역 | 통과 | 비고 |
|---|---:|---|
| swift test (DarwinForgeUITests + ForgeCoreTests) | 108 / 108 | Learning 35개 포함, prompt §11 의 11개 named test 전부 |
| cargo test (forge-core + cli + ffi + integ) | 331 / 331 | 변경 없음 (Rust 미수정) |
| 실 로그 재판정 (21개) | 통과 | 0 comparison · 2 biasOnly · 9 inconclusive · 10 rejected |

특히 다음 named test 가 prompt 요구사항을 직접 검증합니다:

```
testV1SessionLogStillDecodes
testV2SessionLogIncludesSchemaAndLineTypes
testDataQualityRejectsHighDuplicateRatio
testDataQualityUsesIndependentImuSampleCount
testShortSessionIsInconclusive
testMissingAlgorithmFieldsPreventsComparisonUse
testObserveOnlySeparatesCandidateAndAppliedDeltas
testLaggedEffectivenessIgnoresDuplicateSamples
testLowQualitySessionDoesNotRaiseIntensity
testABComparisonRequiresSingleChangedVariable
testHybridSummaryRequiresPhaseFields
```

---

## 10. 다음 담당이 해야 할 일 (순서 권장)

1. **BalanceCorrector 도입** (v1.1 fall prevention 또는 v110 balance 브랜치 merge)
   - `WalkLabSession.balanceAlgorithmMode` / `Sign` / `GainProfile` 을 corrector state 로 채우기
   - `correctorIntensityLevel`, `correctionApplyMode` 도 corrector / UI toggle 과 binding

2. **실 IMU sequence/age 노출**
   - 50ms IMU task 가 `(roll, pitch, sequence, sampledAtMs)` 를 발행하도록
   - `recordTick` 에서 `imuSampleAgeMs = now - sampledAtMs`, `imuSequence = sequence` 로 채우기
   - 이게 채워지면 quality 가 `staleRatio` 와 `medianImuAgeMs` 를 정확히 계산

3. **walk cycle phase 노출**
   - 현재는 `tMs mod periodMs / periodMs` 로 대충 추정
   - WalkEngine 이 cycle start 시각을 보고할 수 있게 되면 그 값을 `recordTick` 에 넣어주기

4. **A/B 워크플로 버튼**
   - 현재 UI 는 선택 picker 만 있음
   - `A 기록 시작` / `B 기록 시작` 버튼이 `comparisonTag.arm` 을 `"A"` / `"B"` 로 설정한 뒤 `start()` 하도록 wiring

5. **operator note 입력**
   - 표면 / cradle vs floor / 배터리 상태 등을 한 줄 메모로 받아 `WalkLabSession.operatorNote` 에 흘리기

---

## 11. 절대 하지 말 것

(prompt §13 + 본 작업 합의)

- `sampleCount` 만 보고 데이터 양이 충분하다고 결론 짓기
- v1 로그를 새 schema 로 억지 migration 해서 algorithm/sign 을 채워넣기 (decoder 가 명시적으로 nil 로 보존)
- low quality 세션에서 intensity 자동 상승 (recommender 가 이미 차단 — 우회하지 마세요)
- 같은 tick correction/IMU correlation 만 보고 보정 효과라고 주장 (lagged 만 신뢰)
- `walkPhase01` 없이 Hybrid 성능 평가
- 실 로봇에 alternateDiagnostic 부호를 바로 적용하는 UI

---

이 정보로 다음 담당이 본 worktree 의 v2 파이프라인 위에 corrector / 실 IMU 를 충돌 없이 얹을 수 있습니다.
