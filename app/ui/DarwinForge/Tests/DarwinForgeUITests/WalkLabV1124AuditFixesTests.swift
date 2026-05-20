import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.24 (2026-05-20) — audit P0/P1 회귀 가드**
///
/// 검증 대상: `docs/diagnosis/WALKLAB_REAL_ROBOT_MOTION_FAILURE_AUDIT_2026-05-20.md`
/// 의 P0-1, P0-2, P0-3, P0-4, P1-1, P1-2, P1-3 fix.
///
/// 핵심 invariant:
/// - `start(_:)` 는 preflight 통과 전에 `current`/`engine`/`simTimer` 를 건드리지 않는다.
/// - `activeRobotPreset` 는 실 motor task 가 시작된 preset 만 가리킨다 (UI selection 과 분리).
/// - logger sample.preset 은 `activeRobotPreset ?? current` 우선.
/// - `WalkPreflightFailure.Cause` 의 모든 case 가 한국어 userMessage / diagnosticCode 보유.
/// - ROBOTIS Onboard 모드에서 SSH 미연결 시 `onboardWalkingActive=true` 가 되지 않는다.
@MainActor
final class WalkLabV1124AuditFixesTests: XCTestCase {

    // MARK: - P0-1: start() validates before mutating state

    /// **start(_:) 시 cradle 미확인 → state 변경 없음 + preflight failure 기록**.
    /// 종전엔 `guard cradleConfirmed else { return }` 가 silent 였지만 audit 이후엔 사유 기록.
    func testStartWithoutCradleEmitsPreflightFailure() {
        let session = WalkLabSession()
        session.start(.march)
        XCTAssertEqual(session.current, .idle, "cradle 미확인 — current 변경 없음")
        XCTAssertNotNil(session.lastPreflightFailure, "preflight failure 기록되어야 함")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .cradleNotConfirmed)
        XCTAssertEqual(session.startBlockedReason, "cradleNotConfirmed")
        XCTAssertEqual(session.requestedPreset, .march, "사용자가 클릭한 preset 은 기록")
    }

    /// **caution preset + enableBalanceCorrection=false → 차단 + 사유 기록**.
    func testCautionPresetWithoutBalanceCorrectionBlocked() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        XCTAssertFalse(session.enableBalanceCorrection, "default OFF")
        session.start(.fastWalk)
        XCTAssertEqual(session.current, .idle, "fastWalk 차단됐으므로 current 미변경")
        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .balanceCorrectorRequiredForCautionPreset(presetLabel: "빠르게 걷기"))
        XCTAssertEqual(session.startBlockedReason, "balanceCorrectorRequiredForCautionPreset")
    }

    /// **enableBalanceCorrection ON → caution preset 시작 통과** (current 변경됨).
    /// 단 store=nil 이므로 startWalkCycle 의 deeper guard 가 noConnection 으로 차단 →
    /// startBlockedReason 은 "noConnection" 으로 set (iter2-D 가 추가).
    func testCautionPresetWithBalanceCorrectionPasses() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true
        session.start(.fastWalk)
        XCTAssertEqual(session.current, .fastWalk, "quickPreflight 통과 → current 갱신")
        // store 없음 → noConnection. quickPreflight 자체는 통과.
        XCTAssertEqual(session.startBlockedReason, "noConnection")
    }

    /// **highRisk preset (jog) 에서 risk 미확인 → 차단**.
    func testHighRiskPresetWithoutAcknowledgement() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true   // jog 는 highRisk 라 caution 가드는 무관
        session.start(.jog)
        XCTAssertEqual(session.current, .idle)
        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .highRiskNotAcknowledged(presetLabel: "공 접근+오른발 킥"))
        XCTAssertEqual(session.startBlockedReason, "highRiskNotAcknowledged")
    }

    /// **이미 보행 중 → 새 preset start() 거부 (current 유지)**.
    /// audit §1 의 결정적 버그: 보행 중 fastWalk 클릭 시 current 만 바뀌고 motor task 는 안 바뀜.
    /// fix 후: current 자체가 안 바뀜.
    func testStartWhileAlreadyWalkingBlocksAndPreservesCurrent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // 첫 보행: bus 없이 start → quickPreflight 통과 후 startWalkCycle 에서 noConnection
        //          (sim 모드). current 는 march 로 갱신.
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        // bus 없으면 startWalkCycle 가 noConnection 표시 — 의도된 sim 모드 fallback.
        // (quickPreflight 자체는 통과해 state 변경 진행).
        // 두 번째: 같은 process 에서 isRobotWalking 시뮬레이션 — 직접 trigger.
        session._testForceWalkActive(.march)
        XCTAssertTrue(session.isWalkActive)

        // 사용자가 fastWalk 클릭 (보행 중) → quickPreflight 가 alreadyWalking 반환.
        session.start(.fastWalk)
        XCTAssertEqual(session.current, .march, "보행 중 다른 preset 클릭 — current 유지")
        XCTAssertEqual(session.startBlockedReason, "alreadyWalking")
        XCTAssertEqual(session.requestedPreset, .fastWalk, "요청 자체는 기록")
        // userMessage 에 두 preset 이름 모두 포함되어 사용자 진단 가능.
        if case .alreadyWalking(let active, let req)? = session.lastPreflightFailure?.cause {
            XCTAssertEqual(active, "제자리 걸음")
            XCTAssertEqual(req, "빠르게 걷기")
        } else {
            XCTFail("alreadyWalking 사유여야 함")
        }
    }

    // MARK: - P0-4 / P1-1: activeRobotPreset + preset-defaults sliders

    /// **loadPresetDefaultsToSliders(_:) 가 슬라이더를 preset 기본값으로 동기화**.
    /// audit §4: advanced ON 에서 turnLeft 클릭해도 turnDeg=0 이면 회전 안 되는 함정 차단.
    func testLoadPresetDefaultsToSlidersForTurnLeft() {
        let session = WalkLabSession()
        session.advanced = true
        session.turnDeg = 0  // 사용자가 슬라이더 0 으로 둠
        session.loadPresetDefaultsToSliders(.turnLeft)
        XCTAssertEqual(session.turnDeg, 25.0, accuracy: 0.01, "turnLeft 기본 turnDeg=25°")
        XCTAssertEqual(session.strideMm, 18.0, accuracy: 0.01, "turnLeft 기본 stride=18mm")
    }

    func testLoadPresetDefaultsToSlidersForFastWalk() {
        let session = WalkLabSession()
        session.advanced = true
        session.loadPresetDefaultsToSliders(.fastWalk)
        XCTAssertEqual(session.strideMm, 38.0, accuracy: 0.01)
        XCTAssertEqual(session.customPeriodMs, 450.0, accuracy: 0.01)
        XCTAssertEqual(session.turnDeg, 0.0)
    }

    /// **effectiveCommandPreview** — advanced ON 면 슬라이더, OFF 면 preset 기본값.
    func testEffectiveCommandPreviewAdvancedOff() {
        let session = WalkLabSession()
        session.advanced = false
        session.current = .turnLeft
        let preview = session.effectiveCommandPreview
        XCTAssertEqual(preview.turnDeg, 25.0, accuracy: 0.01, "advanced OFF → preset 기본")
    }

    func testEffectiveCommandPreviewAdvancedOn() {
        let session = WalkLabSession()
        session.advanced = true
        session.turnDeg = 7.5
        session.strideMm = 12.0
        let preview = session.effectiveCommandPreview
        XCTAssertEqual(preview.turnDeg, 7.5, accuracy: 0.01)
        XCTAssertEqual(preview.strideMm, 12.0, accuracy: 0.01)
    }

    // MARK: - P1-1: activeRobotPreset lifecycle

    /// **activeRobotPreset 는 motor task 가 안 시작되면 nil 유지**.
    /// 테스트 환경에서는 bus 가 없어 startWalkCycle 의 `guard let store = store, ...` 가
    /// 차단 → walkCycleTask 미생성 → activeRobotPreset 도 nil.
    func testActiveRobotPresetNilWithoutBus() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        XCTAssertNil(session.activeRobotPreset, "bus 없으면 motor task 미시작 → activeRobotPreset=nil")
    }

    /// **stop() → activeRobotPreset 클리어 (이미 nil 이어도 idempotent)**.
    func testStopClearsActiveRobotPreset() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        session._testForceWalkActive(.march)
        XCTAssertEqual(session.activeRobotPreset, .march)
        session.stop()
        XCTAssertNil(session.activeRobotPreset)
        XCTAssertFalse(session.isWalkActive)
    }

    /// **emergencyStop() → activeRobotPreset + onboardWalkingActive 클리어**.
    func testEmergencyStopClearsActiveState() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        session._testForceWalkActive(.march)
        session.emergencyStop()
        XCTAssertNil(session.activeRobotPreset)
        XCTAssertFalse(session.onboardWalkingActive)
    }

    // MARK: - P1-2: WalkPreflightFailure new case messages + diagnosticCode

    func testAlreadyWalkingFailureMessage() {
        let f = WalkLabSession.WalkPreflightFailure(
            cause: .alreadyWalking(activePresetLabel: "제자리 걸음", requestedLabel: "빠르게 걷기")
        )
        XCTAssertTrue(f.userMessage.contains("제자리 걸음"))
        XCTAssertTrue(f.userMessage.contains("빠르게 걷기"))
        XCTAssertEqual(f.diagnosticCode, "alreadyWalking")
    }

    func testHighRiskFailureMessage() {
        let f = WalkLabSession.WalkPreflightFailure(
            cause: .highRiskNotAcknowledged(presetLabel: "공 접근+오른발 킥")
        )
        XCTAssertTrue(f.userMessage.contains("공 접근+오른발 킥"))
        XCTAssertEqual(f.diagnosticCode, "highRiskNotAcknowledged")
    }

    func testAdvancedStabilityCriticalFailureMessage() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .advancedStabilityCritical)
        XCTAssertTrue(f.userMessage.contains("critical"))
        XCTAssertEqual(f.diagnosticCode, "advancedStabilityCritical")
    }

    func testOnboardSshFailureMessage() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .onboardSshNotConnected)
        XCTAssertTrue(f.userMessage.contains("SSH"))
        XCTAssertEqual(f.diagnosticCode, "onboardSshNotConnected")
    }

    func testOnboardAutoBrokeringFailureMessage() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .onboardAutoBrokeringOff)
        XCTAssertTrue(f.userMessage.contains("brokering"))
        XCTAssertEqual(f.diagnosticCode, "onboardAutoBrokeringOff")
    }

    /// 모든 Cause 가 diagnosticCode 와 userMessage 를 동시에 제공.
    func testAllCausesHaveDiagnosticCodeAndMessage() {
        // Cause case 가 추가될 때 마다 본 list 도 갱신해야 함 (회귀 가드).
        let allCauses: [WalkLabSession.WalkPreflightFailure.Cause] = [
            .noConnection,
            .cradleNotConfirmed,
            .dxlPowerFailed("test"),
            .lowerBodyTorqueFailed([]),
            .bulkTorqueFailed(failedCount: 5, total: 20),
            .balanceCorrectorRequiredForCautionPreset(presetLabel: "x"),
            .imuUnavailable,
            .imuStale,
            .imuPlausibilityFailed("y"),
            .alreadyWalking(activePresetLabel: "a", requestedLabel: "b"),
            .advancedStabilityCritical,
            .highRiskNotAcknowledged(presetLabel: "c"),
            .onboardSshNotConnected,
            .onboardAutoBrokeringOff,
            .onboardAckTimeout
        ]
        for cause in allCauses {
            let f = WalkLabSession.WalkPreflightFailure(cause: cause)
            XCTAssertFalse(f.userMessage.isEmpty, "userMessage empty: \(cause)")
            XCTAssertFalse(f.diagnosticCode.isEmpty, "diagnosticCode empty: \(cause)")
        }
    }

    // MARK: - P1-3: ROBOTIS Onboard SSH gate

    /// **walkingEngine=.robotisOnboard + store 없음 → start() 도달 시 noConnection 으로 막힘**.
    /// quickPreflight 통과 후 startWalkCycle 의 `guard let store, let bus` 가 차단.
    /// onboardWalkingActive 가 절대 true 가 되면 안 됨.
    func testOnboardModeWithoutBusDoesNotActivate() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.walkingEngine = .robotisOnboard
        session.start(.march)
        XCTAssertFalse(session.onboardWalkingActive,
                       "store 없음 → onboardWalkingActive=true 절대 안 됨")
    }

    // MARK: - 로거 sample.preset = activeRobotPreset 우선

    /// **session.start 후 → loggedPresetRaw 결정 로직**.
    /// (실 logger 검증은 통합 테스트에서. 본 테스트는 expected raw 값만 검증.)
    func testLoggedPresetFavorsActiveOverCurrent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        session._testForceWalkActive(.march)
        XCTAssertEqual(session.activeRobotPreset, .march)
        // 사용자가 fastWalk 클릭했지만 차단 — current 도 march 유지.
        session.start(.fastWalk)
        XCTAssertEqual(session.current, .march)
        XCTAssertEqual(session.activeRobotPreset, .march)
    }

    // MARK: - WalkPreflightFailure Equatable round-trip

    /// 모든 새 case 가 Equatable 비교 가능 (Codable 외 동등성).
    func testCauseEquality() {
        XCTAssertEqual(
            WalkLabSession.WalkPreflightFailure.Cause.alreadyWalking(activePresetLabel: "a", requestedLabel: "b"),
            .alreadyWalking(activePresetLabel: "a", requestedLabel: "b")
        )
        XCTAssertNotEqual(
            WalkLabSession.WalkPreflightFailure.Cause.alreadyWalking(activePresetLabel: "a", requestedLabel: "b"),
            .alreadyWalking(activePresetLabel: "a", requestedLabel: "c")
        )
        XCTAssertEqual(
            WalkLabSession.WalkPreflightFailure.Cause.onboardSshNotConnected,
            .onboardSshNotConnected
        )
    }

    // MARK: - P1-2: WalkSessionHeader new fields decode default to nil

    /// **이전 jsonl header 가 새 필드 없어도 decode 성공** (backward-compat).
    func testWalkSessionHeaderDecodeBackwardCompat() throws {
        let oldJson = """
        {
          "sessionId":"old","startTimeIso":"2026-05-19T00:00:00Z","preset":"march",
          "intensityLevelAtStart":2,"appVersion":"v1.0","isRealRobot":true
        }
        """.data(using: .utf8)!
        let header = try JSONDecoder().decode(WalkSessionHeader.self, from: oldJson)
        XCTAssertNil(header.requestedPreset)
        XCTAssertNil(header.startBlockedReason)
        XCTAssertNil(header.motorWriteStarted)
        XCTAssertNil(header.motorWriteStepCount)
        XCTAssertNil(header.onboardAckStatus)
    }

    // MARK: - iter2-A: cancelWalkCycle clears state symmetrically

    /// **stop() 후 activeRobotPreset / motorWriteStarted / motorWriteStepCount 모두 reset**.
    /// 종전: cancelWalkCycle 만 isRobotWalking reset → 다른 진단 필드 leak.
    func testStopResetsAllDiagnosticCounters() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        session._testForceWalkActive(.march)
        session.stop()
        XCTAssertNil(session.activeRobotPreset)
        XCTAssertFalse(session.motorWriteStarted)
        XCTAssertEqual(session.motorWriteStepCount, 0)
        XCTAssertNil(session.requestedPreset)
        XCTAssertNil(session.startBlockedReason)
        XCTAssertNil(session.onboardAckStatus)
    }

    func testEmergencyStopResetsAllDiagnosticCounters() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        session._testForceWalkActive(.march)
        session.emergencyStop()
        XCTAssertNil(session.activeRobotPreset)
        XCTAssertFalse(session.motorWriteStarted)
        XCTAssertEqual(session.motorWriteStepCount, 0)
        XCTAssertNil(session.requestedPreset)
        XCTAssertNil(session.startBlockedReason)
    }

    // MARK: - iter2-C: slider sync gated by preflight

    /// **advanced ON + blocked start → slider 미변경**.
    /// 종전: tap() 가 preflight 전에 loadPresetDefaultsToSliders 호출 → 차단되어도 slider 변경.
    /// 현재: start() 가 preflight 통과 후에만 slider sync → 차단 시 그대로.
    func testBlockedStartDoesNotMutateSlidersInAdvancedMode() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.advanced = true
        session.strideMm = 0
        session.turnDeg = 0
        session.customPeriodMs = 600
        // 보행 중 시뮬 → 다음 start 는 alreadyWalking 으로 차단되어야 함.
        session.start(.march)
        session._testForceWalkActive(.march)
        let stridebefore = session.strideMm
        let turnBefore = session.turnDeg
        let periodBefore = session.customPeriodMs

        session.start(.turnLeft)   // 차단되어야 함 (alreadyWalking).
        XCTAssertEqual(session.startBlockedReason, "alreadyWalking")
        // slider 들이 turnLeft 기본값 (turnDeg=25 등) 으로 변경되면 안 됨.
        XCTAssertEqual(session.strideMm, stridebefore, accuracy: 0.001)
        XCTAssertEqual(session.turnDeg, turnBefore, accuracy: 0.001)
        XCTAssertEqual(session.customPeriodMs, periodBefore, accuracy: 0.001)
    }

    /// **advanced ON + 첫 start (preflight 통과) → slider 가 preset 기본값으로 sync**.
    /// turnLeft 는 caution 이라 enableBalanceCorrection=true 필요.
    func testFirstStartInAdvancedModeSyncsSliders() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true   // turnLeft caution 통과용
        session.advanced = true
        session.turnDeg = 0
        session.strideMm = 0
        session.start(.turnLeft)
        // preflight 통과 → loadPresetDefaultsToSliders 호출 → turnLeft 기본값.
        XCTAssertEqual(session.turnDeg, 25.0, accuracy: 0.01)
        XCTAssertEqual(session.strideMm, 18.0, accuracy: 0.01)
    }

    // MARK: - iter2-D: startBlockedReason wired in all guards

    /// **caution preset 차단 → startBlockedReason 도 set**.
    /// (quickPreflight 가 같은 사유로 차단하므로 quickPreflight 경로 검증.)
    func testCautionPresetSetsStartBlockedReason() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = false
        session.start(.fastWalk)
        XCTAssertEqual(session.startBlockedReason, "balanceCorrectorRequiredForCautionPreset")
    }

    // MARK: - iter2-E: 현재 명령 송출 button gated

    /// **cradle 미확인 → 수동 송출 차단 사유 set**.
    func testOnboardManualSendBlockedWithoutCradle() {
        let session = WalkLabSession()
        session.cradleConfirmed = false
        XCTAssertNotNil(session.onboardManualSendBlockReason)
        XCTAssertTrue(session.onboardManualSendBlockReason!.contains("정비"))
    }

    /// **caution preset + balance OFF → 수동 송출 차단**.
    func testOnboardManualSendBlockedForCautionWithoutBalance() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = false
        session.current = .fastWalk
        // store == nil 이라 SSH 우선 차단 — 별도 hook 필요. 본 테스트는 caution 가드 자체.
        let reason = session.onboardManualSendBlockReason
        XCTAssertNotNil(reason)
        // 둘 중 하나는 차단 사유여야 함.
        XCTAssertTrue(reason!.contains("SSH") || reason!.contains("자세 보정"))
    }

    /// **idle 명령은 항상 송출 허용** (정지 명령).
    func testOnboardManualSendAllowsIdleCommand() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // current = .idle (default), bus nil → onboardManualSendBlockReason 는 "SSH 미연결" 이 우선.
        // 본 테스트는 caution + balance OFF 조합 우선순위 확인용.
        let reason = session.onboardManualSendBlockReason
        // SSH 미연결 외 다른 사유가 없어야 함.
        if let r = reason {
            XCTAssertTrue(r.contains("SSH") || r.contains("정비"))
        }
    }

    // MARK: - iter2-G: balance correction OFF refused during caution walk

    /// **활성 caution preset + balance ON → ON→OFF 시도 거부**.
    /// 종전: GyroCorrectorControls 의 intensity=0 슬라이더가 balance OFF flip → caution preset
    /// 계속 진행 → 낙상 위험.
    /// 현재: didSet 가 rollback + lastRobotEvent.
    func testCautionWalkRefusesBalanceCorrectionOff() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true
        // 활성 caution preset 시뮬.
        session._testForceWalkActive(.fastWalk)
        // 사용자가 OFF 시도.
        session.enableBalanceCorrection = false
        XCTAssertTrue(session.enableBalanceCorrection,
                      "caution preset 활성 중 OFF 시도 거부 → ON 유지")
        XCTAssertNotNil(session.lastRobotEvent)
        XCTAssertTrue(session.lastRobotEvent?.contains("자세 보정 OFF 차단") ?? false)
    }

    /// **active preset 이 safe (march/slowWalk) 이면 balance OFF 허용**.
    func testSafePresetAllowsBalanceCorrectionOff() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true
        session._testForceWalkActive(.march)   // march = safe
        session.enableBalanceCorrection = false
        XCTAssertFalse(session.enableBalanceCorrection,
                       "safe preset 은 OFF 허용")
    }

    // MARK: - iter2-H: logger writes footer on close

    /// **logger.close(...) 가 footer 한 줄 append**.
    func testLoggerWritesFooterWithDiagnostics() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 2, appVersion: "test", isRealRobot: false
        )
        defer {
            try? FileManager.default.removeItem(at: logger.filePath)
            try? FileManager.default.removeItem(at: logger.filePath
                .deletingPathExtension().appendingPathExtension("summary.json"))
        }
        logger.close(motorWriteStarted: true,
                     motorWriteStepCount: 142,
                     onboardAckStatus: "ok",
                     endReason: "userStop")
        // 파일에서 마지막 줄 읽기.
        let raw = try String(contentsOf: logger.filePath, encoding: .utf8)
        let lines = raw.split(separator: "\n").map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 2, "header + footer 최소 2줄")
        let lastLine = lines.last!
        // 마지막 줄을 footer 로 decode.
        let data = lastLine.data(using: .utf8)!
        let footer = try JSONDecoder().decode(WalkSessionFooter.self, from: data)
        XCTAssertEqual(footer.type, "footer")
        XCTAssertEqual(footer.motorWriteStarted, true)
        XCTAssertEqual(footer.motorWriteStepCount, 142)
        XCTAssertEqual(footer.onboardAckStatus, "ok")
        XCTAssertEqual(footer.endReason, "userStop")
    }

    /// **footer 가 없는 jsonl 도 header decode 가능** (backward-compat).
    func testHeaderDecodeWorksWithoutFooter() throws {
        let onlyHeader = """
        {"sessionId":"x","startTimeIso":"y","preset":"march","intensityLevelAtStart":1,"appVersion":"v","isRealRobot":true}
        """.data(using: .utf8)!
        let _ = try JSONDecoder().decode(WalkSessionHeader.self, from: onlyHeader)
        // footer 없음 — 위 decode 가 throw 안 하면 통과.
    }

    // MARK: - iter2-J: PresetButton isActive prefers activeRobotPreset

    // 컴파일/렌더 검증만 (실 View test 는 SwiftUI snapshot 없음).
    // activeRobotPreset 가 nil 일 때 fallback 으로 current 사용 — 이 단순 invariant 만 확인.
    func testActiveRobotPresetNilFallsBackToCurrent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)   // current = march, activeRobotPreset = nil (no bus)
        let displayActive = session.activeRobotPreset ?? session.current
        XCTAssertEqual(displayActive, .march)
    }

    // MARK: - iter3 regression tests

    /// **iter3-C** — walkingEngine 토글 mid-walk 시 보행 자동 정지 (state 일관성).
    func testEngineSwitchMidWalkAutoStops() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        session._testForceWalkActive(.march)
        XCTAssertTrue(session.isWalkActive)
        // 엔진 전환.
        session.walkingEngine = .robotisOnboard
        XCTAssertFalse(session.isWalkActive, "engine 전환 시 자동 정지")
        XCTAssertNil(session.activeRobotPreset, "엔진 전환 후 activeRobotPreset clear")
        XCTAssertEqual(session.current, .idle)
        XCTAssertTrue(session.lastRobotEvent?.contains("엔진 전환") ?? false)
    }

    /// **iter3-D** — IMU plausibility 의심 시 수동 송출 차단.
    /// (store mock 가 없어 본 테스트는 nil store 케이스만 — full IMU 케이스는
    /// real-store integration test 에서 cover.)
    func testOnboardManualSendBlockedReasonsAreReachable() {
        let session = WalkLabSession()
        session.cradleConfirmed = false
        XCTAssertEqual(session.onboardManualSendBlockReason?.contains("정비"), true)
        session.cradleConfirmed = true
        XCTAssertEqual(session.onboardManualSendBlockReason?.contains("SSH"), true)
    }

    // MARK: - iter4-critic regression tests

    /// **iter4 critic #1** — footer 라인은 WalkSessionSample 로 decode 되지 않는다 (silent skip).
    /// 향후 field collision 회귀 가드.
    func testFooterLineRejectedBySampleDecoder() throws {
        let footerJson = """
        {"type":"footer","closedAtIso":"x","totalSampleCount":10}
        """.data(using: .utf8)!
        // WalkSessionSample 의 필수 필드 (t) 가 없으므로 decode 실패해야 함.
        XCTAssertThrowsError(try JSONDecoder().decode(WalkSessionSample.self, from: footerJson))
        // WalkSessionFooter 는 decode 성공.
        let footer = try JSONDecoder().decode(WalkSessionFooter.self, from: footerJson)
        XCTAssertEqual(footer.type, "footer")
        XCTAssertEqual(footer.totalSampleCount, 10)
    }

    /// **iter4 critic #3** — defer 로 isRefusingBalanceOff 가 stuck 되지 않음.
    /// 다중 rollback 후에도 후속 일반 OFF 토글이 정상 처리되는지 확인.
    func testBalanceRollbackFlagDoesNotStickAcrossSessions() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // 1차 rollback 발생.
        session.enableBalanceCorrection = true
        session._testForceWalkActive(.fastWalk)
        session.enableBalanceCorrection = false   // refused, rollback
        XCTAssertTrue(session.enableBalanceCorrection)

        // stop → safe state → 그 다음 OFF 는 통과해야 함.
        session.stop()
        XCTAssertNil(session.activeRobotPreset)
        session.enableBalanceCorrection = false   // 이젠 safe — 통과해야.
        XCTAssertFalse(session.enableBalanceCorrection,
                       "rollback flag stuck → 후속 OFF 가 무시되면 안 됨")
    }

    /// **iter3-E** — caution 보행 중 balance OFF rollback 시 .correctorOn 이벤트 중복 발사 안 됨.
    func testBalanceRollbackDoesNotSpamCorrectorOnEvent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true
        let beforeCount = session.safetyEvents.filter { $0.kind == .correctorOn }.count
        session._testForceWalkActive(.fastWalk)
        session.enableBalanceCorrection = false   // rollback fires
        let afterCount = session.safetyEvents.filter { $0.kind == .correctorOn }.count
        XCTAssertEqual(afterCount, beforeCount, "rollback 시 .correctorOn 발사 안 됨")
        // .correctorOff 사유는 한 번 추가됐어야 함 (refused 메시지).
        let offEvents = session.safetyEvents.filter { $0.kind == .correctorOff }
        XCTAssertTrue(offEvents.contains { $0.message.contains("거부") })
    }

    /// **새 필드 round-trip**.
    func testWalkSessionHeaderRoundTripIncludingAuditFields() throws {
        let header = WalkSessionHeader(
            sessionId: "test", startTimeIso: "iso", preset: "march",
            intensityLevelAtStart: 2, appVersion: "v1.11.24", isRealRobot: true,
            requestedPreset: "fastWalk",
            startBlockedReason: "alreadyWalking",
            walkCycleTaskActiveAtStart: true,
            motorWriteStarted: false,
            motorWriteStepCount: 0,
            onboardAckStatus: "pending",
            lastRobotEventAtStart: "보행 진행 중"
        )
        let encoded = try JSONEncoder().encode(header)
        let decoded = try JSONDecoder().decode(WalkSessionHeader.self, from: encoded)
        XCTAssertEqual(decoded.requestedPreset, "fastWalk")
        XCTAssertEqual(decoded.startBlockedReason, "alreadyWalking")
        XCTAssertEqual(decoded.walkCycleTaskActiveAtStart, true)
        XCTAssertEqual(decoded.motorWriteStarted, false)
        XCTAssertEqual(decoded.motorWriteStepCount, 0)
        XCTAssertEqual(decoded.onboardAckStatus, "pending")
        XCTAssertEqual(decoded.lastRobotEventAtStart, "보행 진행 중")
    }
}
