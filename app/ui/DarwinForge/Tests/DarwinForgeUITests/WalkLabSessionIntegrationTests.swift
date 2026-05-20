import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 2026-05-17 T3.1 prerequisite — WalkLabSession 통합 테스트.
///
/// 목적: god object 분리 (extension file 추출) 전에 observable behavior 회귀
/// 가드. 분리 작업 (private → internal 33+ symbols 변환) 시 무심코 의미가 깨지지
/// 않도록.
///
/// 검증 범위: public API 통과 시나리오만. Private 함수 직접 호출 안 함.
@MainActor
final class WalkLabSessionIntegrationTests: XCTestCase {

    // MARK: - Lifecycle

    /// **start without cradleConfirmed → no-op** — 안전 가드.
    func testStartWithoutCradleConfirmedNoOp() {
        let session = WalkLabSession()
        XCTAssertFalse(session.cradleConfirmed,
            "default cradleConfirmed false")
        XCTAssertEqual(session.current, .idle, "default current idle")

        session.start(.slowWalk)
        XCTAssertEqual(session.current, .idle,
            "cradleConfirmed false → start 가 current 변경 안 함 (안전 가드)")
    }

    /// **start with cradleConfirmed → current transitions to preset**.
    func testStartWithCradleConfirmedTransitionsCurrent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        XCTAssertEqual(session.current, .march,
            "cradleConfirmed true + start → current 갱신")
    }

    /// **stop after start → current returns to idle**.
    func testStopReturnsToIdle() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        session.stop()
        XCTAssertEqual(session.current, .idle,
            "stop 후 current idle 로 복귀")
    }

    /// **emergencyStop → current idle + balanceLost 리셋 + riskAcknowledged 리셋**.
    /// 정정: balanceLost 는 IMU 30° 도달 시 tick 안에서 set. emergencyStop 은
    /// reset 만 (false). emergencyStop 의 진짜 invariant 는 current=idle + 안전 reset.
    func testEmergencyStopResetsStateAndIdles() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.riskAcknowledged = true   // jog/highRisk 시뮬
        session.start(.normalWalk)
        session.emergencyStop()
        XCTAssertEqual(session.current, .idle,
            "emergencyStop 후 current idle")
        XCTAssertFalse(session.balanceLost,
            "emergencyStop 는 balanceLost reset (false)")
        XCTAssertFalse(session.riskAcknowledged,
            "emergencyStop 후 riskAcknowledged reset")
    }

    /// **preset switching cancels previous walkCycleTask** (관찰: current 갱신).
    func testPresetSwitchUpdatesCurrent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.slowWalk)
        XCTAssertEqual(session.current, .slowWalk)
        session.start(.normalWalk)
        XCTAssertEqual(session.current, .normalWalk,
            "preset 변경 → current 즉시 반영 (cancel + restart)")
    }

    // MARK: - Safety

    /// **emergencyStop → safety event 누적** (.sessionStop 또는 .emergencyTriggered).
    func testEmergencyStopAddsSafetyEvent() {
        let session = WalkLabSession()
        let initialCount = session.safetyEvents.count
        session.cradleConfirmed = true
        session.emergencyStop()
        XCTAssertGreaterThan(session.safetyEvents.count, initialCount,
            "emergencyStop 후 safetyEvents 가 늘어야 함")
    }

    /// **enableBalanceCorrection ON/OFF → safety event 로그** (.correctorOn/.correctorOff).
    /// **v1.11.4 (2026-05-18)**: default OFF → ON 먼저, 그 다음 OFF 두 이벤트 확인.
    func testBalanceCorrectionToggleLogsEvent() {
        let session = WalkLabSession()
        let initialCount = session.safetyEvents.count
        // v1.11.4: default OFF → ON 으로 전환하면 correctorOn event.
        session.enableBalanceCorrection = true
        XCTAssertGreaterThan(session.safetyEvents.count, initialCount,
            "corrector ON → safety event 추가")
        XCTAssertTrue(
            session.safetyEvents.contains { $0.kind == .correctorOn },
            "correctorOn event 존재"
        )

        let afterOnCount = session.safetyEvents.count
        session.enableBalanceCorrection = false
        XCTAssertGreaterThan(session.safetyEvents.count, afterOnCount,
            "corrector OFF → safety event 추가")
        XCTAssertTrue(
            session.safetyEvents.contains { $0.kind == .correctorOff },
            "correctorOff event 존재"
        )
    }

    /// **enableBalanceCorrection 같은 값 set → 이벤트 중복 안 됨** (didSet guard).
    /// v1.7 default ON 기준 — 다른 값으로 한 번 전환 후 같은 값 재set.
    func testBalanceCorrectionIdempotent() {
        let session = WalkLabSession()
        // v1.7: default ON. 명시 OFF 로 한 번 전환 → 그 다음 OFF idempotent.
        session.enableBalanceCorrection = false
        let countAfterFirstSet = session.safetyEvents.count

        // 같은 값 (false) 다시 set — didSet guard 로 이벤트 중복 안 함.
        session.enableBalanceCorrection = false
        XCTAssertEqual(session.safetyEvents.count, countAfterFirstSet,
            "동일 값 set 은 didSet 가드로 이벤트 중복 안 함")
    }

    /// **autoFallPrevention default true** — 안전 default.
    func testAutoFallPreventionDefault() {
        let session = WalkLabSession()
        XCTAssertTrue(session.autoFallPrevention,
            "default true — 자동 fall prevention 활성")
    }

    // MARK: - Real telemetry expose

    /// **store 미attach → imuScaleSuspicion .unknown** (T3 user report fix invariant).
    func testImuScaleSuspicionWithoutStore() {
        let session = WalkLabSession()
        XCTAssertEqual(session.imuScaleSuspicion, .unknown,
            "store 미attach → unknown")
        XCTAssertEqual(session.imuAccelZMagnitude, 0,
            "store 미attach → 0 magnitude")
    }

    /// **store attach 후 imuScaleSuspicion passthrough**.
    func testImuScaleSuspicionWithStoreAttached() {
        let session = WalkLabSession()
        let store = ConnectionStore()
        session.attach(store: store)
        // 신규 store 의 default unknown 그대로 expose.
        XCTAssertEqual(session.imuScaleSuspicion, .unknown,
            "신규 store — unknown")
    }

    // MARK: - Public state invariants

    /// **start 후 lastRobotEvent 갱신** (sim/실 robot 무관).
    func testStartSetsLastRobotEvent() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        XCTAssertNil(session.lastRobotEvent, "default nil")
        session.start(.march)
        XCTAssertNotNil(session.lastRobotEvent,
            "start 후 lastRobotEvent set (sim mode 안내)")
    }

    /// **WalkLabSession 의 monitoringExpanded 초기 false (UserDefaults clean)**.
    func testMonitoringExpandedInitialState() {
        // **v1.11.6 (2026-05-18)**: default true 로 변경 (UX 개선).
        let key = "df.walklab.monitoringExpanded"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let session = WalkLabSession()
        XCTAssertTrue(session.monitoringExpanded,
            "UserDefaults 미설정 — default true (v1.11.6 UX fix)")
    }

    /// **strideMm/sideMm/turnDeg/balanceGain 기본값 정합** (advanced 모드 default).
    func testAdvancedDefaults() {
        let session = WalkLabSession()
        XCTAssertEqual(session.strideMm, 0, "stride default 0")
        XCTAssertEqual(session.sideMm, 0, "side default 0")
        XCTAssertEqual(session.turnDeg, 0, "turn default 0")
        XCTAssertEqual(session.balanceGain, 1.0,
            "balanceGain default 1.0 (full)")
        XCTAssertEqual(session.customPeriodMs, 600,
            "customPeriodMs default 600ms (ROBOTIS 표준)")
        XCTAssertEqual(session.footHeightMm, 40,
            "footHeightMm default 40mm")
        XCTAssertFalse(session.forceOverrideSafety,
            "안전 한도 해제 default OFF")
        XCTAssertFalse(session.riskAcknowledged,
            "위험 인정 default false")
    }

    /// **walkReady visualPose default** — start 전 상태.
    func testVisualPoseDefault() {
        let session = WalkLabSession()
        XCTAssertEqual(session.visualPose, .walkReady,
            "default visualPose = walkReady (T-pose 아닌 정상 보행 시작 자세)")
    }
}
