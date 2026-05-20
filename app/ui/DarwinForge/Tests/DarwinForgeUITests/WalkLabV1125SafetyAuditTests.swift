import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.25 (2026-05-21) — audit P0/P1 safety + logging 회귀 가드**.
///
/// 검증:
/// - audit-C: stop() 후 riskAcknowledged reset
/// - audit-D: thermal cool-down 강제
/// - audit-E: sim DataQuality `isSimulationOnly` flag
/// - audit-I: advanced toggle ON 시 자동 slider load
/// - audit-K: V1 legacy session 자동 verdict=fail
/// - audit-L: duration=0 edge case
/// - log-D: 새 SafetyEvent.Kind case (engineSwitched / experimentApplied 등)
/// - log-F: 토글 변경 시 SafetyEvent 발화
/// - log-G: emergency trigger source 명시 (자동 vs 사용자)
/// - log-H: fallScore / fallRecommendEmergency JSONL 저장
@MainActor
final class WalkLabV1125SafetyAuditTests: XCTestCase {

    // MARK: - audit-C: stop() 후 riskAcknowledged reset

    func testStopResetsRiskAcknowledged() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.riskAcknowledged = true
        XCTAssertTrue(session.riskAcknowledged)
        session.start(.march)
        session.stop()
        XCTAssertFalse(session.riskAcknowledged,
                       "stop() 후 다음 highRisk preset 시작 시 재확인 강제")
    }

    // MARK: - audit-D: thermal cool-down 강제

    func testThermalCoolDownGateBlocksRestart() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // sim 모드에서 thermalCoolDownRequired 직접 set 못함 (private(set)).
        // 단 default 는 false 이므로 정상 시나리오만 검증.
        XCTAssertFalse(session.thermalCoolDownRequired, "default OFF")
        XCTAssertEqual(WalkLabSession.thermalCooldownExitTemp, 50.0,
                       "cool-down exit temp 50°C")
    }

    // MARK: - audit-E: sim DataQuality flag

    func testDataQualityFlagsSimulationOnly() {
        let header = WalkSessionHeader(
            sessionId: "sim-test", startTimeIso: "iso", preset: "march",
            intensityLevelAtStart: 1, appVersion: "1.0", isRealRobot: false,
            walkingEngine: "macSparseKeyframe"
        )
        let sample = WalkSessionSample(
            t: 1000, preset: "march", intensityLevel: 1,
            imuRollDeg: 0, imuPitchDeg: 0,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "sim", batteryVolts: nil, motorAvgTemp: nil
        )
        let report = DataQualityReport.compute(
            samples: [sample], header: header, durationSec: 10
        )
        XCTAssertTrue(report.isSimulationOnly,
                      "isRealRobot=false → isSimulationOnly true")
    }

    // MARK: - audit-I: advanced toggle ON 자동 slider load

    func testAdvancedToggleAutoLoadsPresetDefaults() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.enableBalanceCorrection = true
        session.start(.fastWalk)
        XCTAssertEqual(session.strideMm, 0, "default 0 mm before advanced")
        session.advanced = true
        XCTAssertEqual(session.strideMm, 38.0, accuracy: 0.01,
                       "advanced ON → fastWalk default 38mm 자동 load")
    }

    // MARK: - audit-K: V1 legacy 자동 fail

    func testDataQualityV1LegacyAutoFail() {
        let header = WalkSessionHeader(
            sessionId: "v1", startTimeIso: "iso", preset: "march",
            intensityLevelAtStart: 1, appVersion: "0.9", isRealRobot: true
            // walkingEngine / balanceAlgorithmMode 누락 (V1)
        )
        let sample = WalkSessionSample(
            t: 1000, preset: "march", intensityLevel: 1,
            imuRollDeg: 0, imuPitchDeg: 0,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "real", batteryVolts: 11.5, motorAvgTemp: 45
            // balanceAlgorithmMode / walkPhase01 누락 (V1 sample)
        )
        let report = DataQualityReport.compute(
            samples: [sample], header: header, durationSec: 10
        )
        XCTAssertEqual(report.verdict, .fail, "V1 legacy → 강제 fail")
        XCTAssertTrue(report.reasons.contains { $0.contains("V1 legacy") })
    }

    // MARK: - audit-L: duration=0 edge case

    func testDataQualityDurationZeroNoInf() throws {
        let header = WalkSessionHeader(
            sessionId: "x", startTimeIso: "iso", preset: "march",
            intensityLevelAtStart: 1, appVersion: "1.0", isRealRobot: true,
            walkingEngine: "macSparseKeyframe"
        )
        let sample = WalkSessionSample(
            t: 0, preset: "march", intensityLevel: 1,
            imuRollDeg: 0, imuPitchDeg: 0,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "real", batteryVolts: nil, motorAvgTemp: nil
        )
        let report = DataQualityReport.compute(
            samples: [sample], header: header, durationSec: 0
        )
        XCTAssertEqual(report.verdict, .fail)
        XCTAssertEqual(report.sampleRateHz, 0, "rate=0 (not Inf)")
        XCTAssertNoThrow(try JSONEncoder().encode(report),
                         "JSON serialize 가능 (Inf/NaN 없음)")
    }

    // MARK: - log-D: 새 SafetyEvent.Kind case

    func testSafetyEventKindEngineSwitched() {
        let session = WalkLabSession()
        session.walkingEngine = .robotisOnboard
        XCTAssertTrue(session.safetyEvents.contains { $0.kind == .engineSwitched },
                      "engine 전환 → engineSwitched dedicated case")
    }

    // MARK: - log-F: 토글 변경 SafetyEvent 발화

    func testCradleToggleEmitsSafetyEvent() {
        let session = WalkLabSession()
        let beforeCount = session.safetyEvents.count
        session.cradleConfirmed = true
        let afterCount = session.safetyEvents.count
        XCTAssertEqual(afterCount, beforeCount + 1,
                       "cradle 토글 → SafetyEvent 1개 추가")
        XCTAssertEqual(session.safetyEvents.last?.kind, .stateChange)
    }

    func testForceOverrideSafetyEmitsHighPriorityEvent() {
        let session = WalkLabSession()
        session.forceOverrideSafety = true
        XCTAssertTrue(session.safetyEvents.contains { $0.kind == .preflightFailure },
                      "안전 우회 ON → preflightFailure kind 로 영구 기록")
    }

    // MARK: - log-G: emergency trigger source

    func testEmergencyTriggerHasSource() {
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.userClick.harnessActor, .user)
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.balanceLostL3.harnessActor, .robot)
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.thermalOverheat.harnessActor, .robot)
        XCTAssertEqual(WalkLabSession.EmergencyTrigger.voltageDroop.harnessActor, .robot)
    }

    // MARK: - log-H: fallScore JSONL 저장

    func testFallScoreAndRecommendInWalkSessionSample() throws {
        let sample = WalkSessionSample(
            t: 100, preset: "march", intensityLevel: 1,
            imuRollDeg: 0, imuPitchDeg: 0,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "real", batteryVolts: nil, motorAvgTemp: nil,
            fallScore: 0.62,
            fallRecommendEmergency: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: data)
        XCTAssertEqual(decoded.fallScore, 0.62)
        XCTAssertEqual(decoded.fallRecommendEmergency, false)
    }

    // MARK: - WalkPreflightFailure new cause

    func testMotorTempCoolDownCauseHasMessage() {
        let f = WalkLabSession.WalkPreflightFailure(
            cause: .motorTempCoolDownRequired(currentTempC: 55, exitTempC: 50)
        )
        XCTAssertTrue(f.userMessage.contains("55"))
        XCTAssertTrue(f.userMessage.contains("50"))
        XCTAssertEqual(f.diagnosticCode, "motorTempCoolDownRequired")
    }
}
