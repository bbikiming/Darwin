import Foundation
import XCTest
@testable import DarwinForgeUI

/// **사이클 60 — WalkLabSession+Pilot facade 회귀 가드**.
///
/// refactoring-specialist agent 가 추출한 facade method 의 동작 검증.
/// architect agent CRITICAL "god object surface 좁힘" 의 결과를 보존.
@MainActor
final class WalkLabSessionPilotFacadeTests: XCTestCase {

    var session: WalkLabSession!

    override func setUp() async throws {
        try await super.setUp()
        session = WalkLabSession()
    }

    override func tearDown() async throws {
        session = nil
        try await super.tearDown()
    }

    func testPilotSafetyContextComposition() {
        let ctx = session.pilotSafetyContext()
        XCTAssertEqual(ctx.balanceState, session.balanceState, "balanceState 동일")
        XCTAssertEqual(ctx.robotConnected, session.store?.bus != nil, "bus 연결 동일")
        XCTAssertEqual(ctx.riskAcknowledged, session.riskAcknowledged, "risk ack 동일")
    }

    func testPilotCurrentAmplitudeReflectsSliders() {
        session.advanced = true
        session.strideMm = 25
        session.sideMm = 10
        session.turnDeg = 5
        let cmd = session.pilotCurrentAmplitude
        XCTAssertEqual(cmd.strideMm, 25, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, 10, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, 5, accuracy: 1e-9)
    }

    func testPilotIsEmergencyReflectsState() {
        XCTAssertFalse(session.pilotIsEmergency)
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertTrue(session.pilotIsEmergency)
        session.exitEmergencyMode()
        XCTAssertFalse(session.pilotIsEmergency)
    }

    func testPilotApplyAmplitudeBlockedDuringEmergency() {
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertTrue(session.emergencyStopActive)
        let result = session.pilotApplyAmplitude(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0))
        XCTAssertFalse(result, "emergency 중 write skip → false")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "amplitude 유지 (zero)")
    }
}
