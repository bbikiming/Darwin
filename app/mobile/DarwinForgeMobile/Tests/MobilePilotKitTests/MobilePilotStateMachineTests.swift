import XCTest
@testable import MobilePilotKit

final class MobilePilotStateMachineTests: XCTestCase {

    func testHappyArmFlow() {
        var sm = MobilePilotStateMachine(initial: .notPaired)
        XCTAssertEqual(sm.apply(.pairingStarted).nextState, .pairing)
        XCTAssertEqual(sm.apply(.pairingSucceeded).nextState, .macConnectedNoRobot)
        sm.apply(.telemetry(makeTelemetry(robot: .connected, armed: false)))
        XCTAssertEqual(sm.state, .robotConnectedLocked)
        XCTAssertEqual(sm.apply(.armRequested).nextState, .arming)
        XCTAssertEqual(sm.apply(.armed).nextState, .armedReady)
    }

    func testEStopAlwaysAvailable() {
        var sm = MobilePilotStateMachine(initial: .commandActive(commandId: "cmd_x"))
        let result = sm.apply(.estopRequested)
        XCTAssertEqual(result.nextState, .estopped)
        XCTAssertTrue(result.sideEffects.contains(.stopActiveCommand(reason: .user)))
        XCTAssertTrue(result.sideEffects.contains(.openRecoveryBanner))
    }

    func testWatchdogTransitionsToStaleStop() {
        var sm = MobilePilotStateMachine(initial: .commandActive(commandId: "cmd_walk"))
        let result = sm.apply(.watchdogStopped(.heartbeatTimeout))
        XCTAssertEqual(result.nextState, .staleStop)
        XCTAssertTrue(result.sideEffects.contains(.stopActiveCommand(reason: .latencyGate)))
    }

    func testTransportCloseStopsActiveCommand() {
        var sm = MobilePilotStateMachine(initial: .commandActive(commandId: "cmd_y"))
        let result = sm.apply(.transportClosed)
        XCTAssertEqual(result.nextState, .pairedNoMac)
        XCTAssertTrue(result.sideEffects.contains(.stopActiveCommand(reason: .latencyGate)))
    }

    func testTelemetryStaleProducesStaleStop() {
        var sm = MobilePilotStateMachine(initial: .armedReady)
        sm.apply(.telemetry(makeTelemetry(robot: .stale, armed: true)))
        XCTAssertEqual(sm.state, .staleStop)
    }

    func testTelemetryBusBusyLocksOut() {
        var sm = MobilePilotStateMachine(initial: .armedReady)
        sm.apply(.telemetry(makeTelemetry(robot: .busBusy, armed: false)))
        XCTAssertEqual(sm.state, .robotConnectedLocked)
    }

    func testCommandPermissionRespectsLatencyGate() {
        let highLatency = makeTelemetry(robot: .connected, armed: true, latencyMs: 220)
        let reason = CommandPermission.reason(forWalk: .armedReady,
                                              telemetry: highLatency,
                                              latencyWarningMs: 150)
        guard case .latencyGate(let ms) = reason else {
            XCTFail("expected latencyGate, got \(String(describing: reason))")
            return
        }
        XCTAssertEqual(ms, 220)
    }

    func testCommandPermissionBlocksWhenNotArmed() {
        let safe = makeTelemetry(robot: .connected, armed: false, latencyMs: 30)
        XCTAssertEqual(CommandPermission.reason(forSafeAction: .robotConnectedLocked,
                                                telemetry: safe),
                       .notArmed)
    }

    func testArmPermissionDoesNotBlockBecauseRobotIsNotArmedYet() {
        let safe = makeTelemetry(robot: .connected, armed: false, latencyMs: 30)
        XCTAssertNil(CommandPermission.reason(forArm: .robotConnectedLocked,
                                              telemetry: safe))
        XCTAssertEqual(CommandPermission.reason(forSafeAction: .robotConnectedLocked,
                                                telemetry: safe),
                       .notArmed)
    }

    func testCommandPermissionReportsBusBusy() {
        let busy = makeTelemetry(robot: .busBusy, armed: false)
        XCTAssertEqual(CommandPermission.reason(forSafeAction: .robotConnectedLocked,
                                                telemetry: busy),
                       .busBusy)
    }

    func testCommandPermissionReportsRobotMissing() {
        let sim = makeTelemetry(robot: .sim, armed: false)
        let reason = CommandPermission.reason(forSafeAction: .macConnectedNoRobot,
                                              telemetry: sim)
        guard case .robotDisconnected(let simAvailable) = reason else {
            XCTFail("expected robotDisconnected, got \(String(describing: reason))")
            return
        }
        XCTAssertTrue(simAvailable)
    }

    // MARK: - helpers

    private func makeTelemetry(mac: MacConnectionState = .connected,
                               robot: RobotConnectionState,
                               armed: Bool,
                               latencyMs: Int = 30) -> TelemetryStatePayload {
        TelemetryStatePayload(
            mac: mac, robot: robot,
            endpoint: "tcp://test", armed: armed, dxlPower: armed,
            batteryV: 11.6, maxTempC: 42,
            latencyMs: latencyMs, lastAckAgeMs: nil,
            safety: armed ? .ready : .ready,
            uiState: armed ? .armedReady : .robotConnectedLocked)
    }
}
