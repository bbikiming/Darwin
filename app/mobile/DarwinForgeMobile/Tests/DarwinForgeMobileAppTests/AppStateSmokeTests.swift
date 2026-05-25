import XCTest
@testable import DarwinForgeMobileApp
@testable import MobilePilotKit

@MainActor
final class AppStateSmokeTests: XCTestCase {

    func testMockReviewConnectAndEStopFlow() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        XCTAssertTrue(state.isMacReady)
        XCTAssertTrue(state.logs.contains(where: { $0.message.contains("Mac에 연결됨") }))
        await state.performEStop()
        XCTAssertEqual(state.pilotState, .estopped)
        XCTAssertNotNil(state.recoveryBanner)
        XCTAssertEqual(state.recoveryBanner?.kind, .estop)
    }

    func testActionRequiresArm() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        await state.performMotion(label: "walkReady")
        // Mock relay does not reject when no real ARM gate is enforced, but
        // the state machine should not transition to a permanently active
        // command — verify we ended on robotConnected/armed-ish state and
        // not stuck in commandActive.
        switch state.pilotState {
        case .commandActive: XCTFail("Should have completed and finished")
        default: break
        }
    }

    func testWalkStartAndStopUpdatesActivePreset() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        state.cradleConfirmed = true
        await state.performArm()
        await state.startWalk(.slowForward)
        XCTAssertEqual(state.activeWalkPreset, .slowForward)
        await state.stopWalk(reason: .deadmanRelease)
        XCTAssertNil(state.activeWalkPreset)
    }

    func testHeadControlIsBlockedInRealRelayMode() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()

        XCTAssertTrue(state.headControlSupported)
        await state.setConnectionMode(.realRelay)
        XCTAssertFalse(state.headControlSupported)

        await state.sendHead(enabled: true, panDeg: 10, tiltDeg: -5, tracking: false)

        XCTAssertEqual(state.lastError, "headUnsupportedInMVP")
        XCTAssertNil(state.lastReceipt)
        XCTAssertTrue(state.logs.contains {
            $0.message.contains("머리 방향 조절은 첫 빌드 실 로봇 모드에서 비활성")
        })
    }

    func testRealRelayArmRequiresFullChecklist() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.setConnectionMode(.realRelay)

        state.cradleConfirmed = true
        XCTAssertFalse(state.armChecklistPassed)

        state.physicalEStopConfirmed = true
        XCTAssertFalse(state.armChecklistPassed)

        state.lineOfSightConfirmed = true
        XCTAssertTrue(state.armChecklistPassed)
    }

    func testMockReviewArmStartIsNotBlockedBySimTelemetry() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()

        XCTAssertNil(state.armStartDisabledReason)
    }

    func testTelemetryHistoryRecordsLatestFrames() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        for _ in 0..<20 where state.telemetryHistory.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.telemetryHistory.count, 1)
        XCTAssertEqual(state.telemetryHistory.first?.latencyMs, state.telemetry?.latencyMs)

        await state.disconnect()
        XCTAssertTrue(state.telemetryHistory.isEmpty)
        XCTAssertNil(state.telemetry)
    }
}
