# GPT 검증 요청 프롬프트 — WalkLab v1.11.14 ~ v1.11.14.3 폐루프

생성일: 2026-05-19 (v2 — 코드 embed + 응답 형식 정형화)
PR: [#37](https://github.com/bbikiming/Darwin/pull/37)
branch: `claude/v1.11.14-experiment-feedback-loop`

---

## 사용 방법

아래 프롬프트 전체 (` ``` ` 안의 텍스트) 를 복사해 ChatGPT (GPT-4o, o1, GPT-5 등) 에 붙여넣고 응답 받으세요. 응답을 Claude 에게 paste 하면 발견된 위험에 대해 즉시 fix 또는 v1.11.15+ 분리 판단.

**v2 개선**:
- v1: 라인 번호만 → v2: 핵심 코드 직접 embed (GPT 가 코드 실제 분석 가능)
- v1: Mac sparse 질문 → v2: 제거 (GPT 가 답 못 함)
- v1: "표 + 인용 권장" → v2: 정형화된 응답 형식 (SEVERITY/WHERE/WHAT/WHY/FIX)
- v1: 워크플로우 없음 → v2: critic → 승인 → 보행 → 비교 흐름도

---

## 프롬프트 (복사용)

```
당신은 Swift/SwiftUI/Concurrency 시니어 리뷰어. DarwinForge WalkLab v1.11.14.3 의 폐루프 구현 (critic → 사용자 명시 승인 → WalkLabSession config mutation → 다음 보행 → 자동 A/B 비교) 을 cold review.

## 워크플로우

1. 사용자가 보행 (baseline session) 1회 실행 → jsonl + summary.json 디스크 저장
2. Claude critic 이 baseline 분석 → ClaudeCriticResponse (nextExperiment + forbiddenChanges)
3. WalkDataView 의 sheet 가 ExperimentApprovalUI 띄움 — proposedConfig + validationResult 미리보기
4. 사용자 명시 "실험 시작" 버튼 클릭
5. validate(currentConfig:) 통과 → ExperimentLoopController.startExperiment + WalkLabSession.applyExperimentChange (config + deltas mutation, activeExperimentId set)
6. 사용자 보행 (experiment session) → session end → 자동 폐루프:
   - controller.appendExperimentSession + compareWithBaseline (다축 verdict)
   - lastRobotEvent 에 verdict 표시
7. 사용자가 controller.finalize 또는 cancel → onCleared callback → session.clearExperimentContext

## v1.11.14.3 처리 (모두 commit + 회귀 가드)

진단 문서 1차 6건 + cold 2차 7건 = 총 13건:

[v1.11.14 1차 — 진단 문서]
1. applyExperimentChange — config mutation + safety gate
2. buildProposedConfig 현재 config 기준 (default 아님)
3. session end 자동 폐루프
4. compareWithBaseline 다축 metric
5. validate(currentConfig:) overload
6. fake CLI fail fixture wrapper

[v1.11.14.1 cold 1차]
7. activeExperimentId leak fix (onCleared)
8. reentry 가드
9. session-end disk IO 백그라운드
10. validate UI 사전 표시
11. tuning slider + customGain* axis 적용 (10 axis)
12. loadSummaryFromDisk substring → prefix

[v1.11.14.3 cold 2차 — 이번 검증 대상]
A. hipPitchOffsetTrimDeg 범위 강화 (±10°/±20° → ±5°/5..25 절대 + 8..20 권장)
B. session-end e2e 테스트 (실 disk IO, baseDir inject)
C. tuning axis 범위 가드 (strideMm -80..80, customPeriodMs 400..800 등)
D. jsonl streaming first-line read (FileHandle 8KB chunk)
E. setExperimentLoop first onAppear 로 통합
F. validationResult @autoclosure dynamic
G. (A 와 함께) trim 절대 안전 범위 (5..25) + 권장 (8..20) 명시

527 tests pass, 0 failures.

## 핵심 코드 (review 대상)

### 1. applyExperimentChange (reentry guard + deltas)

```swift
public func applyExperimentChange(
    experimentId: String,
    baselineSessionId: String,
    proposedConfig: BalanceExperimentConfig,
    deltas: ExperimentDeltas = ExperimentDeltas()
) -> ApplyExperimentResult {
    if case .blocked(let reason) = proposedConfig.safetyVerdict {
        return .failed(reason: "safetyVerdict.blocked — \(reason)")
    }
    if let existing = activeExperimentId {
        return .failed(reason: "이미 활성 실험 (\(existing)) — 종료 후 재시도")
    }
    balanceExperimentConfig = proposedConfig
    if let v = deltas.hipPitchOffsetTrimDeg { hipPitchOffsetTrimDeg = v }
    if let v = deltas.strideMm { strideMm = v }
    // ... 9 more deltas
    activeExperimentId = experimentId
    activeBaselineSessionId = baselineSessionId
    logSafetyEvent(kind: .correctorOn, message: "실험 적용: \(experimentId)")
    return .applied
}
```

### 2. ExperimentLoopController.finalize/cancel + onCleared

```swift
@MainActor
public final class ExperimentLoopController: ObservableObject {
    public var onCleared: (() -> Void)? = nil

    public func finalize() async {
        await loop.finalize()
        current = await loop.current
        history = await loop.history
        if current == nil { onCleared?() }
    }

    public func cancel() async {
        await loop.cancel()
        current = await loop.current
        if current == nil { onCleared?() }
    }
}

// WalkLabSession.setExperimentLoop:
public func setExperimentLoop(_ controller: ExperimentLoopController?) {
    self.experimentLoop = controller  // weak
    controller?.onCleared = { [weak self] in
        self?.clearExperimentContext()
    }
}
```

### 3. session-end 자동 폐루프 (concurrency)

```swift
if let expId = activeExperimentId, let baselineId = activeBaselineSessionId,
   let controller = experimentLoop {
    let summaryId = summary.id
    Task { @MainActor [weak self, weak controller] in
        let baseline = await Task.detached(priority: .userInitiated) {
            WalkLabSession.loadSummaryFromDisk(sessionId: baselineId)
        }.value
        let experimentSummaries = await Task.detached(priority: .userInitiated) {
            WalkLabSession.loadAllExperimentSummaries(experimentId: expId)
        }.value
        guard let controller = controller else { return }
        await controller.appendExperimentSession(summaryId)
        guard let b = baseline else { return }
        await controller.compareWithBaseline(
            baselineSummary: b,
            experimentSummaries: experimentSummaries
        )
        if let comp = controller.lastComparison {
            self?.lastRobotEvent =
                "🔬 A/B 비교: \(comp.verdict.rawValue) — \(comp.reason)"
        }
    }
}
```

### 4. validate(currentConfig:) — safetyVerdict 시뮬 + trim/tuning 가드

```swift
public func validate(currentConfig: BalanceExperimentConfig,
                     currentTrim: Double = 13.0) -> ValidationResult {
    var issues = self.validate().issues
    guard let exp = nextExperiment else {
        return ValidationResult(passed: issues.isEmpty, issues: issues)
    }
    // forbidden phrase
    let forbiddenPhrase = "\(exp.axis.rawValue)→\(exp.to)"
    for f in forbiddenChanges where f.contains(forbiddenPhrase) {
        issues.append("제안 변경이 응답의 forbiddenChanges 와 충돌: \(f)")
    }
    // safetyVerdict 시뮬
    let simulated = simulateChange(exp: exp, from: currentConfig)
    if case .blocked(let reason) = simulated.safetyVerdict {
        issues.append("제안 적용 시 safetyVerdict=blocked: \(reason)")
    }
    // hipPitchOffsetTrimDeg 강화 (v1.11.14.3 A+G)
    if exp.axis == .hipPitchOffsetTrimDeg, let target = Double(exp.to) {
        if abs(target - currentTrim) > 5.0 {
            issues.append("변경 폭 > 5° — 2~3° 점진 권장.")
        }
        if target < 5 || target > 25 {
            issues.append("절대 안전 범위 (5..25) 초과 — fall 위험.")
        } else if target < 8 || target > 20 {
            issues.append("권장 범위 (8..20) 밖 — 12~18 권장.")
        }
    }
    validateAxisRange(exp: exp, issues: &issues)
    return ValidationResult(passed: issues.isEmpty, issues: issues)
}

// tuning axis 범위 가드 (v1.11.14.3 C)
private func validateAxisRange(exp: NextExperiment, issues: inout [String]) {
    guard let target = Double(exp.to) else { return }
    let ranges: [(ResponseAxis, ClosedRange<Double>, String)] = [
        (.strideMm, -80...80, "보폭 (mm)"),
        (.sideMm, -50...50, "측보 (mm)"),
        (.turnDeg, -25...25, "회전 (°)"),
        (.periodMs, 400...800, "주기 (ms)"),
        (.footHeightMm, 20...60, "발 들어올림 (mm)"),
        (.balanceGain, 0.0...2.0, "balance 강도"),
        (.customGainHipRoll, 0.0...2.0, "custom hip roll gain"),
        (.customGainKnee, 0.0...2.0, "custom knee gain"),
        (.customGainAnklePitch, 0.0...2.0, "custom ankle pitch gain"),
        (.customGainAnkleRoll, 0.0...2.0, "custom ankle roll gain"),
    ]
    for (axis, range, label) in ranges where exp.axis == axis {
        if !range.contains(target) {
            issues.append("\(label) \(target) 안전 범위 \(range.lowerBound)..\(range.upperBound) 밖.")
        }
    }
}
```

### 5. jsonl streaming first-line (v1.11.14.3 D)

```swift
nonisolated static func loadAllExperimentSummaries(
    experimentId: String, baseDir: URL? = nil
) -> [WalkSessionSummary] {
    guard let dir = baseDir ?? WalkSessionStore.sessionsDir else { return [] }
    var summaries: [WalkSessionSummary] = []
    for jsonlURL in files where jsonlURL.pathExtension == "jsonl" {
        guard let firstLineData = readFirstLine(from: jsonlURL),
              let header = try? decoder.decode(WalkSessionHeader.self, from: firstLineData),
              header.experimentId == experimentId else { continue }
        // ... load summary.json
    }
    return summaries
}

nonisolated private static func readFirstLine(from url: URL) -> Data? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let chunk = try? handle.read(upToCount: 8192) else { return nil }
    guard let newlineIdx = chunk.firstIndex(of: 0x0a) else { return chunk }
    return chunk.prefix(newlineIdx)
}
```

### 6. ExperimentApprovalUI — @autoclosure dynamic (v1.11.14.3 F)

```swift
public struct ExperimentApprovalUI: View {
    private let proposedConfigProvider: () -> BalanceExperimentConfig
    private let validationResultProvider: () -> ClaudeCriticResponse.ValidationResult?

    public init(response: ClaudeCriticResponse,
                baselineSessionId: String,
                proposedConfig: @escaping @autoclosure () -> BalanceExperimentConfig,
                validationResult: @escaping @autoclosure () -> ClaudeCriticResponse.ValidationResult? = nil,
                onApprove: @escaping () -> Void,
                onCancel: @escaping () -> Void) { ... }

    private var proposedConfig: BalanceExperimentConfig { proposedConfigProvider() }
    private var validationResult: ClaudeCriticResponse.ValidationResult? { validationResultProvider() }
}
```

## 검증 요청

다음을 cold 분석해 새로운 위험 식별:

1. **Concurrency 안전성**:
   - `Task { @MainActor }` 안의 `await Task.detached.value` 패턴 — Swift 5.10 / 6 strict mode 호환?
   - `nonisolated static` 함수의 `FileHandle` 사용 — thread safety?
   - WalkLabSession 의 weak controller ref + setExperimentLoop 의 closure overwrite — race?

2. **Memory/Lifecycle**:
   - `[weak self, weak controller]` capture 패턴 — leak/silent skip 가능성?
   - sessionsDir 의 `ApplicationSupportDirectory` URL 이 `nonisolated static` 에서 안전?
   - `extractSessionIdFromSummary` 의 마지막 hyphen 분리 — preset 이 hyphen 포함하면? (현재 camelCase 만)

3. **Invariant 위반**:
   - applyExperimentChange 의 reentry guard 가 controller.startExperiment 의 guard 와 일관?
   - validate(currentConfig:) 의 simulateChange 가 axis 별 시뮬 — 누락된 axis 없나?
   - safetyVerdict.blocked 가 set 후 didSet 의 부작용 가능?

4. **데이터 무결성**:
   - jsonl 첫 줄 readFirstLine 이 8KB 이상 header 면 잘림 위험 — header 크기 estimate?
   - clearExperimentContext 가 idempotent 한가? 동시 호출 시 race?
   - WalkSessionLogger 의 filename rule "{sessionId}-{preset}" — sessionId 가 끝에 hyphen 가지면?

5. **UX 위험**:
   - validate(currentConfig:) 결과의 SwiftUI body 재평가 trigger — session 변경 시 sheet 가 실제로 갱신되는지?
   - ExperimentApprovalUI 의 disable 조건 (validationResult.passed = false) — 사용자 강제 우회 가능?
   - 자동 폐루프의 lastRobotEvent 표시 — 1초 후 다른 이벤트로 덮어쓰기 위험?

6. **Test gap**:
   - 14 + 13 = 27건 회귀 가드 — 어떤 critical path 가 여전히 mock-only?
   - 실 robot E2E 미실행 — code-only review 로 검증 가능한 silent failure 범위?

## 응답 형식 (필수)

각 발견 위험을 다음 형식으로 정확히 명시:

```
[CRITICAL | HIGH | MED | LOW]
WHERE: <file>.swift — <function or section>
WHAT: <한 줄 위험 설명>
WHY: <reproduction 시나리오 또는 invariant 위반>
FIX: <즉시 적용 가능한 패치 코드 또는 "재설계 필요 — 별도 PR">
```

마지막에 종합 평가:
- 코드 품질 등급: production-ready / 추가 fix 필요 / 본질적 재설계 필요
- 발견한 신규 위험 갯수 (CRITICAL/HIGH/MED/LOW 별)
- v1.11.14.3 의 폐루프 구현이 ROBOTIS DARwIn-OP 실 robot 에 배포 가능한 수준인가? Y/N + 근거

추측 X, 코드 인용 시 정확한 함수명 사용. 검증 못 한 부분은 "검증 못 함 (코드 부재)" 명시.
```

---

## 응답 받은 후 처리 가이드

GPT 응답을 Claude 에게 paste 하시면:

1. **CRITICAL** 발견 → 즉시 fix + 회귀 가드 추가 + commit
2. **HIGH** 발견 → 영향도 분석 후 v1.11.14.x patch 또는 v1.11.15 분리
3. **MED/LOW** 발견 → 단순한 fix 면 즉시, 복잡하면 차기 PR
4. **신규 위험 0건** + Y 등급 → 폐루프 v1.11.14.3 종결, ROBOTIS onboard 통합 작업 (v1.11.16+) 진입

GPT 의 응답이 신뢰성 높은지 검증하려면:
- 같은 프롬프트를 다른 GPT 모델 (o1, GPT-4o, GPT-5) 에 보내 비교
- 두 응답이 같은 위험 식별 → 신뢰도 ↑
- 응답 다르면 추가 cold review 필요
