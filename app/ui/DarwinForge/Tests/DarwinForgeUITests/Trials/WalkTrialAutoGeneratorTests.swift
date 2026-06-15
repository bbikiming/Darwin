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
                      "session.lastRobotEvent 에 사용자 안내 (pilotPostEvent facade 경유)")

        // 사이클 71 CRITICAL-2: generator 의 guard 자체가 lastPreflightFailure 설정 검증.
        // 사이클 67 (MEDIUM-3): trigger payload 도 명시 검증 — externalEStop 출처 보존.
        XCTAssertEqual(session.lastPreflightFailure?.cause, .emergencyActive(trigger: .externalEStop),
                       "generator guard 가 lastPreflightFailure 명시 set (payload 포함)")
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_externalEStop",
                       "generator guard 가 diagnosticCode 명시 set (trigger suffix)")
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
        // 사이클 71 CRITICAL-2 + 사이클 67 MEDIUM-3: facade 일관성 + trigger payload 보존.
        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .externalEStop))
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
        // 신규 (MEDIUM-3 payload): .emergencyActive(trigger:) 의 명확 메시지 + trigger 추적.
        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .externalEStop),
                       "전용 cause case + trigger payload")
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_externalEStop",
                       "diagnosticCode = emergencyActive_<trigger> (telemetry 정확성)")
        XCTAssertFalse(session.lastRobotEvent?.contains("시뮬 모드") ?? true,
                       "사용자 안내가 '시뮬 모드' 가 아닌 emergency 안내")
        XCTAssertTrue(session.lastRobotEvent?.contains("긴급 정지") ?? false,
                      "사용자 안내가 '긴급 정지' 명시")
    }

    func testEmergencyActiveCauseHasCorrectUserMessage() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .emergencyActive(trigger: .userClick))
        XCTAssertTrue(f.userMessage.contains("긴급 정지"),
                      "userMessage 에 '긴급 정지' 명시")
        XCTAssertTrue(f.userMessage.contains("recovery") || f.userMessage.contains("Recover"),
                      "recovery 액션 가이드 포함")
        // MEDIUM-3 payload: trigger label 도 메시지에 노출.
        XCTAssertTrue(f.userMessage.contains("사용자 정지") || f.userMessage.contains("userClick"),
                      "trigger 한국어 라벨 노출")
    }

    func testEmergencyActiveCauseDiagnosticCode() {
        let f = WalkLabSession.WalkPreflightFailure(cause: .emergencyActive(trigger: .balanceLostL3))
        XCTAssertEqual(f.diagnosticCode, "emergencyActive_balanceLostL3",
                       "diagnosticCode 가 trigger suffix 포함")
    }

    // MARK: - 사이클 67 — 코덱스 MEDIUM-3 회귀 가드 (trigger payload 보존 — 모든 trigger)

    /// **사이클 67 (MEDIUM-3)**: emergencyStop(.externalEStop) → start() → cause payload
    /// 가 externalEStop 보존 검증.
    func testEmergencyActivePreservesExternalEStopTrigger() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        session.start(.march)

        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .externalEStop))
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_externalEStop")
        XCTAssertTrue(session.lastRobotEvent?.contains("외부 E-Stop") ?? false)
    }

    /// **사이클 67**: balanceLostL3 trigger 도 동일 보존 검증.
    func testEmergencyActivePreservesBalanceLostL3Trigger() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .balanceLostL3)
        session.start(.march)

        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .balanceLostL3))
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_balanceLostL3")
        XCTAssertTrue(session.lastRobotEvent?.contains("L3 균형 손실") ?? false)
    }

    /// **사이클 67**: userClick trigger 도 동일 보존 검증.
    func testEmergencyActivePreservesUserClickTrigger() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .userClick)
        session.start(.march)

        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .userClick))
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_userClick")
        XCTAssertTrue(session.lastRobotEvent?.contains("사용자 정지") ?? false)
    }

    /// **사이클 67**: thermalOverheat trigger 도 동일 보존 검증.
    func testEmergencyActivePreservesThermalTrigger() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .thermalOverheat)
        session.start(.march)

        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .thermalOverheat))
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_thermalOverheat")
        XCTAssertTrue(session.lastRobotEvent?.contains("모터 과열") ?? false)
    }

    /// **사이클 67**: voltageDroop trigger 도 동일 보존 검증.
    func testEmergencyActivePreservesVoltageDroopTrigger() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .voltageDroop)
        session.start(.march)

        XCTAssertEqual(session.lastPreflightFailure?.cause,
                       .emergencyActive(trigger: .voltageDroop))
        XCTAssertEqual(session.startBlockedReason, "emergencyActive_voltageDroop")
        XCTAssertTrue(session.lastRobotEvent?.contains("전압 droop") ?? false)
    }

    /// **사이클 67**: lastEmergencyTrigger accessor 가 emergencyStop 후 trigger 노출.
    func testLastEmergencyTriggerExposedAfterStop() {
        let session = WalkLabSession()
        XCTAssertNil(session.lastEmergencyTrigger, "초기값 nil")

        session.start(.march)
        session.emergencyStop(trigger: .fallPredictorRecommend)
        XCTAssertEqual(session.lastEmergencyTrigger, .fallPredictorRecommend)
    }

    /// **사이클 67**: exitEmergencyMode 시 trigger 초기화.
    func testLastEmergencyTriggerClearedOnRecovery() {
        let session = WalkLabSession()
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertNotNil(session.lastEmergencyTrigger)

        session.exitEmergencyMode()
        XCTAssertNil(session.lastEmergencyTrigger, "recovery 시 trigger nil reset")
    }

    /// **사이클 67**: harnessActor / koreanLabel 의 `.unknown` case mapping 검증.
    func testUnknownTriggerHarnessActorAndLabel() {
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.unknown.harnessActor, .robot,
                       "unknown 은 자동 trigger 로 분류 (.robot)")
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.unknown.koreanLabel, "출처 미상")
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.unknown.rawValue, "unknown")
    }
}
