import XCTest
@testable import DarwinForgeMobileApp
@testable import MobilePilotKit

// MARK: - SafetyGateTests
//
// V292-B 3-gate 안전 흐름 단위 테스트:
//   - SafetyBriefModal: 3 체크 모두 → 통과, 부분 → 차단
//   - PreflightChecklistView: 자동 체크 logic + 수동 토글
//   - EStopDrillView: 첫 페어링 only (UserDefaults), drill 후 skip
//   - AppState safetyGateState 전환 검증

@MainActor
final class SafetyGateTests: XCTestCase {

    // MARK: - SafetyGateState transitions (AppState)

    func testSafetyGate_initiallyNone() {
        let state = AppState(initialMode: .mockReview)
        XCTAssertEqual(state.safetyGateState, .none)
    }

    func testBeginSafetyGate_setsBrief() async {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        state.beginSafetyGate()
        XCTAssertEqual(state.safetyGateState, .brief)
    }

    func testCompleteSafetyBrief_fromBrief_advancesToPreflight() {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        state.beginSafetyGate()
        state.completeSafetyBrief()
        XCTAssertEqual(state.safetyGateState, .preflight)
    }

    func testCompleteSafetyBrief_fromNone_isNoop() {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        // 잘못된 순서: brief 없이 completeSafetyBrief 호출
        state.completeSafetyBrief()
        XCTAssertEqual(state.safetyGateState, .none)
    }

    func testCompletePreflightChecklist_drillAlreadyDone_advancesToReady() {
        // eStopDrillCompleted = true → drill skip → ready
        UserDefaults.standard.set(true, forKey: SafetyGateKeys.eStopDrillCompleted)
        defer { UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted) }

        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        state.beginSafetyGate()
        state.completeSafetyBrief()
        state.completePreflightChecklist()
        XCTAssertEqual(state.safetyGateState, .ready)
    }

    func testCompletePreflightChecklist_drillNotDone_advancesToDrill() {
        // eStopDrillCompleted = false (첫 페어링) → drill 표시
        UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted)

        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        state.beginSafetyGate()
        state.completeSafetyBrief()
        state.completePreflightChecklist()
        XCTAssertEqual(state.safetyGateState, .drill)
    }

    func testCompleteEStopDrill_setsReady_andPersists() {
        UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted)
        defer { UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted) }

        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        state.beginSafetyGate()
        state.completeSafetyBrief()
        state.completePreflightChecklist()
        XCTAssertEqual(state.safetyGateState, .drill)

        state.completeEStopDrill()
        XCTAssertEqual(state.safetyGateState, .ready)

        // UserDefaults 에 저장됐는지 확인
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SafetyGateKeys.eStopDrillCompleted))
    }

    func testDisconnect_resetsGateToNone() async {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        state.beginSafetyGate()
        state.completeSafetyBrief()
        XCTAssertEqual(state.safetyGateState, .preflight)

        await state.disconnect()
        XCTAssertEqual(state.safetyGateState, .none)
    }

    // MARK: - PreflightEvaluator 자동 체크 logic

    func testPreflightEvaluator_nilTelemetry_allFail() {
        let items = PreflightEvaluator.evaluate(telemetry: nil)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.isPassed },
                      "텔레메트리 없으면 모든 자동 체크 실패여야 함")
    }

    func testPreflightEvaluator_simRobot_imuAndCalibPass() {
        let payload = TelemetryStatePayload(
            mac: .connected,
            robot: .sim,
            endpoint: nil,
            armed: false,
            dxlPower: false,
            batteryV: 11.8,
            maxTempC: 35.0,
            latencyMs: 20,
            lastAckAgeMs: nil,
            safety: .ready,
            uiState: .robotConnectedLocked
        )
        let items = PreflightEvaluator.evaluate(telemetry: payload)
        let imu = items.first(where: { $0.id == "imu" })
        let calib = items.first(where: { $0.id == "calibration" })
        XCTAssertEqual(imu?.isPassed, true, "sim 로봇 → IMU pass")
        XCTAssertEqual(calib?.isPassed, true, "sim 로봇 → calibration pass")
    }

    func testPreflightEvaluator_batteryLow_batteryFail() {
        let payload = TelemetryStatePayload(
            mac: .connected,
            robot: .connected,
            endpoint: nil,
            armed: false,
            dxlPower: false,
            batteryV: 9.8,   // 10.5V 미만 → fail
            maxTempC: 35.0,
            latencyMs: 20,
            lastAckAgeMs: nil,
            safety: .ready,
            uiState: .robotConnectedLocked
        )
        let items = PreflightEvaluator.evaluate(telemetry: payload)
        let battery = items.first(where: { $0.id == "battery" })
        XCTAssertEqual(battery?.isPassed, false, "낮은 배터리 → fail")
        if case .fail(let reason) = battery?.status {
            XCTAssertTrue(reason.contains("충전"), "실패 안내에 '충전' 포함: \(reason)")
        } else {
            XCTFail("battery status should be .fail")
        }
    }

    func testPreflightEvaluator_dxlPowerOn_dxlFail() {
        let payload = TelemetryStatePayload(
            mac: .connected,
            robot: .connected,
            endpoint: nil,
            armed: false,
            dxlPower: true,   // ON → fail (safe baseline 위반)
            batteryV: 12.0,
            maxTempC: 35.0,
            latencyMs: 20,
            lastAckAgeMs: nil,
            safety: .ready,
            uiState: .robotConnectedLocked
        )
        let items = PreflightEvaluator.evaluate(telemetry: payload)
        let dxl = items.first(where: { $0.id == "dxlPower" })
        XCTAssertEqual(dxl?.isPassed, false, "dxlPower ON → fail")
    }

    func testPreflightEvaluator_dxlPowerOff_pass() {
        let payload = TelemetryStatePayload(
            mac: .connected,
            robot: .connected,
            endpoint: nil,
            armed: false,
            dxlPower: false,   // OFF → pass
            batteryV: 12.0,
            maxTempC: 35.0,
            latencyMs: 20,
            lastAckAgeMs: nil,
            safety: .ready,
            uiState: .robotConnectedLocked
        )
        let items = PreflightEvaluator.evaluate(telemetry: payload)
        let dxl = items.first(where: { $0.id == "dxlPower" })
        XCTAssertEqual(dxl?.isPassed, true, "dxlPower OFF → pass")
    }

    // MARK: - Full 3-gate flow (첫 페어링 vs 재페어링)

    func testFullGateFlow_firstPairing_includesDrill() {
        UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted)
        defer { UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted) }

        let state = AppState(initialMode: .mockReview)
        state.bootstrap()

        state.beginSafetyGate()
        XCTAssertEqual(state.safetyGateState, .brief)

        state.completeSafetyBrief()
        XCTAssertEqual(state.safetyGateState, .preflight)

        state.completePreflightChecklist()
        XCTAssertEqual(state.safetyGateState, .drill,
                       "첫 페어링: drill 게이트 포함되어야 함")

        state.completeEStopDrill()
        XCTAssertEqual(state.safetyGateState, .ready)
    }

    func testFullGateFlow_subsequentPairing_skipsDrill() {
        UserDefaults.standard.set(true, forKey: SafetyGateKeys.eStopDrillCompleted)
        defer { UserDefaults.standard.removeObject(forKey: SafetyGateKeys.eStopDrillCompleted) }

        let state = AppState(initialMode: .mockReview)
        state.bootstrap()

        state.beginSafetyGate()
        state.completeSafetyBrief()
        state.completePreflightChecklist()

        XCTAssertEqual(state.safetyGateState, .ready,
                       "재페어링: drill skip, 바로 ready")
    }
}
