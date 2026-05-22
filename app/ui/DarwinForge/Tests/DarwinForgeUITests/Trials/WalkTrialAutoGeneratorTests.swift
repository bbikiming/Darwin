import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.19.0 (2026-05-21) 사이클 3 — auto-generation 단위 테스트**.
@MainActor
final class WalkTrialAutoGeneratorTests: XCTestCase {

    func testProgressInitiallyNil() {
        let gen = WalkTrialAutoGenerator()
        XCTAssertNil(gen.progress)
    }

    func testProgressPercentZero() {
        let p = WalkTrialAutoGenerator.Progress(current: 0, total: 10, lastTrial: nil)
        XCTAssertEqual(p.percentComplete, 0)
    }

    func testProgressPercentHalf() {
        let p = WalkTrialAutoGenerator.Progress(current: 5, total: 10, lastTrial: "test")
        XCTAssertEqual(p.percentComplete, 0.5, accuracy: 1e-9)
    }

    func testProgressPercentFull() {
        let p = WalkTrialAutoGenerator.Progress(current: 10, total: 10, lastTrial: "done")
        XCTAssertEqual(p.percentComplete, 1.0)
    }

    func testProgressDivisionByZero() {
        let p = WalkTrialAutoGenerator.Progress(current: 0, total: 0, lastTrial: nil)
        XCTAssertEqual(p.percentComplete, 0)
    }

    func testGenerateSingleSimMode() async {
        let session = WalkLabSession()
        let gen = WalkTrialAutoGenerator()
        XCTAssertNil(session.store)

        await gen.generateSingle(
            session: session,
            preset: .slowWalk,
            intensity: 2,
            durationSec: 0.2
        )
        XCTAssertEqual(session.current, .idle)
        XCTAssertEqual(session.correctorIntensityLevel, 2)
    }

    func testGenerateBatchProgresses() async {
        let session = WalkLabSession()
        let gen = WalkTrialAutoGenerator()
        await gen.generateBatch(
            session: session,
            presetSet: [.slowWalk],
            intensityRange: 2...2,
            trialsPerCombo: 1,
            durationSec: 0.1
        )
        XCTAssertNotNil(gen.progress)
        XCTAssertEqual(gen.progress?.total, 1)
        XCTAssertEqual(gen.progress?.current, 1)
    }

    // MARK: - 사이클 66 — 코덱스 HIGH-1 회귀 가드 (emergency silent breakage 차단)

    /// **사이클 66 코덱스 HIGH-1**: emergency 활성 상태에서 generateBatch 호출 시
    /// silent breakage 차단 검증 — 사용자에게 명확 안내 후 즉시 return.
    func testGenerateBatchBlockedDuringEmergency() async {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertTrue(session.emergencyStopActive, "사전: emergency 활성")

        let gen = WalkTrialAutoGenerator()
        await gen.generateBatch(
            session: session,
            presetSet: [.march],
            intensityRange: 2...2,
            trialsPerCombo: 1,
            durationSec: 0.1
        )

        // 차단 증거: total=0, current=0, lastTrial 메시지에 emergency 안내.
        XCTAssertEqual(gen.progress?.total, 0, "emergency 차단 → progress 시작 안 함")
        XCTAssertEqual(gen.progress?.current, 0)
        XCTAssertTrue(gen.progress?.lastTrial?.contains("emergency") ?? false,
                      "lastTrial 에 emergency 사유 노출")
        XCTAssertTrue(session.lastRobotEvent?.contains("긴급 정지") ?? false,
                      "session.lastRobotEvent 에 사용자 안내")
    }

    /// **사이클 66 코덱스 HIGH-1**: generateSingle 도 동일 emergency 차단.
    func testGenerateSingleBlockedDuringEmergency() async {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)

        let gen = WalkTrialAutoGenerator()
        await gen.generateSingle(session: session, preset: .march, intensity: 2, durationSec: 0.1)

        // session.start(_:) 호출 안 됨 → current 변경 없음.
        XCTAssertEqual(session.current, .idle, "emergency 차단 → start 미진행")
        XCTAssertTrue(session.lastRobotEvent?.contains("긴급 정지") ?? false)
    }

    /// **사이클 66 회귀**: recovery 후 generateBatch 재호출 시 정상 진행 (가드 일회성 확인).
    func testGenerateBatchResumesAfterRecovery() async {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        session.exitEmergencyMode()
        XCTAssertFalse(session.emergencyStopActive, "사전: recovery 완료")

        let gen = WalkTrialAutoGenerator()
        await gen.generateBatch(
            session: session,
            presetSet: [.slowWalk],
            intensityRange: 2...2,
            trialsPerCombo: 1,
            durationSec: 0.1
        )
        XCTAssertEqual(gen.progress?.total, 1, "recovery 후 정상 진행")
        XCTAssertEqual(gen.progress?.current, 1)
    }
}

// MARK: - 사이클 66 — 코덱스 CRITICAL-1 회귀 가드 (emergencyActive 전용 cause)

/// **사이클 66 코덱스 CRITICAL-1 회귀**: WalkLabSession.start 의 root-level emergency
/// guard 가 `.noConnection` reuse 대신 신규 `.emergencyActive` cause 사용 검증.
@MainActor
final class WalkLabSessionEmergencyCauseTests: XCTestCase {

    func testStartDuringEmergencyUsesEmergencyActiveCause() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertTrue(session.emergencyStopActive)

        // emergency 중 재시작 시도.
        session.start(.march)

        // CRITICAL-1: 종전은 .noConnection ("시뮬 모드" 메시지) → 사용자 mental model corruption.
        // 신규: .emergencyActive 의 명확 메시지.
        XCTAssertEqual(session.lastPreflightFailure?.cause, .emergencyActive,
                       "전용 cause case 사용 (noConnection reuse 금지)")
        XCTAssertEqual(session.startBlockedReason, "emergencyActive",
                       "diagnosticCode = emergencyActive (telemetry 정확성)")
        XCTAssertFalse(session.lastRobotEvent?.contains("시뮬 모드") ?? true,
                       "사용자 안내가 '시뮬 모드' 가 아닌 emergency 안내")
        XCTAssertTrue(session.lastRobotEvent?.contains("긴급 정지") ?? false,
                      "사용자 안내가 '긴급 정지' 명시")
    }

    func testEmergencyActiveCauseHasCorrectUserMessage() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .emergencyActive)
        XCTAssertTrue(f.userMessage.contains("긴급 정지"),
                      "userMessage 에 '긴급 정지' 명시")
        XCTAssertTrue(f.userMessage.contains("recovery") || f.userMessage.contains("Recover"),
                      "recovery 액션 가이드 포함")
    }

    func testEmergencyActiveCauseDiagnosticCode() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .emergencyActive)
        XCTAssertEqual(f.diagnosticCode, "emergencyActive")
    }
}
