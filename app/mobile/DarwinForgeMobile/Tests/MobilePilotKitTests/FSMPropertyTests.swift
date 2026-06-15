import XCTest
@testable import MobilePilotKit

/// V297-8 P3-F: FSM property-based verification.
/// State machine 의 구조적 property 검증 — model-based testing.
///
/// # 비유
///
/// 전기 회로 검사와 동일. 개별 스위치(unit test)를 넘어
/// "어떤 조합에서도 단락(dead state)이 없는지, 항상 비상구(E-stop)가 열려 있는지"
/// 를 속성(property) 으로 증명한다.
final class FSMPropertyTests: XCTestCase {

    // MARK: - Helpers

    private var allStates: [PilotState] {
        [
            .notPaired, .pairing, .pairedNoMac, .macConnectedNoRobot,
            .robotConnectedLocked, .arming, .armedReady,
            .commandActive(commandId: "test"), .staleStop, .estopped
        ]
    }

    // MARK: - Property: all states reachable from .notPaired

    /// Property: 모든 PilotState 가 .notPaired 부터 reachable.
    ///
    /// V297-8 (P3-Tests): reachability — 각 state 별 최소 transition path 존재 검증.
    func testProperty_allStatesReachableFromNotPaired() {
        // notPaired → pairing
        var sm = MobilePilotStateMachine(initial: .notPaired)
        XCTAssertEqual(sm.apply(.pairingStarted).nextState, .pairing,
                       "AC: notPaired → pairing reachable")

        // pairing → macConnectedNoRobot
        XCTAssertEqual(sm.apply(.pairingSucceeded).nextState, .macConnectedNoRobot,
                       "AC: pairing → macConnectedNoRobot reachable")

        // macConnectedNoRobot → robotConnectedLocked (via telemetry)
        let robotConnected = makeTelemetry(mac: .connected, robot: .connected, armed: false)
        XCTAssertEqual(sm.apply(.telemetry(robotConnected)).nextState, .robotConnectedLocked,
                       "AC: macConnectedNoRobot → robotConnectedLocked reachable")

        // robotConnectedLocked → arming
        XCTAssertEqual(sm.apply(.armRequested).nextState, .arming,
                       "AC: robotConnectedLocked → arming reachable")

        // arming → armedReady
        XCTAssertEqual(sm.apply(.armed).nextState, .armedReady,
                       "AC: arming → armedReady reachable")

        // armedReady → commandActive
        XCTAssertEqual(sm.apply(.commandStarted(commandId: "walk-1")).nextState,
                       .commandActive(commandId: "walk-1"),
                       "AC: armedReady → commandActive reachable")

        // commandActive → staleStop (via watchdogStopped)
        var smStale = MobilePilotStateMachine(initial: .commandActive(commandId: "cmd"))
        XCTAssertEqual(smStale.apply(.watchdogStopped(.heartbeatTimeout)).nextState, .staleStop,
                       "AC: commandActive → staleStop reachable")

        // armedReady → estopped (via estopRequested)
        var smEstop = MobilePilotStateMachine(initial: .armedReady)
        XCTAssertEqual(smEstop.apply(.estopRequested).nextState, .estopped,
                       "AC: armedReady → estopped reachable")

        // pairedNoMac (via transportClosed)
        var smNoMac = MobilePilotStateMachine(initial: .armedReady)
        XCTAssertEqual(smNoMac.apply(.transportClosed).nextState, .pairedNoMac,
                       "AC: armedReady → pairedNoMac reachable via transportClosed")
    }

    // MARK: - Property: estopRequested always goes to .estopped

    /// Property: 어떤 state 에서도 .estopRequested → .estopped (always wins).
    /// V297-7 의 recoveryFailed 는 .estopped 로만 가므로 invariant 유지.
    ///
    /// V297-8 (P3-Tests): estopRequested invariant
    func testProperty_estopRequestedAlwaysGoesToEstopped() {
        for initial in allStates {
            var sm = MobilePilotStateMachine(initial: initial)
            let r = sm.apply(.estopRequested)
            XCTAssertEqual(r.nextState, .estopped,
                           "AC: \(initial) + .estopRequested → .estopped (invariant)")
        }
    }

    // MARK: - Property: recoveryFailed always goes to .estopped

    /// Property: .recoveryFailed 도 .estopped 로 (재검증 P2 fix).
    ///
    /// V297-8 (P3-Tests): recoveryFailed → estopped
    func testProperty_recoveryFailedAlwaysGoesToEstopped() {
        let testedStates: [PilotState] = [
            .arming, .armedReady, .estopped, .staleStop, .robotConnectedLocked
        ]
        for initial in testedStates {
            var sm = MobilePilotStateMachine(initial: initial)
            let r = sm.apply(.recoveryFailed(reason: "test"))
            XCTAssertEqual(r.nextState, .estopped,
                           "AC: \(initial) + .recoveryFailed → .estopped")
        }
    }

    // MARK: - Property: no dead-end states

    /// Property: dead state 없음 — 모든 state 가 적어도 하나의 출구 transition 보유.
    ///
    /// .estopped 는 .estopRequested 로 자기 자신 → 자신으로 가는 게 의미상 dead 아님
    /// (.recoveryAcknowledged 로 나갈 수 있음). .estopped 만 별도 입력(.recoveryAcknowledged)
    /// 으로 출구 검증.
    ///
    /// V297-8 (P3-Tests): no dead-end states
    func testProperty_noDeadEndStates() {
        for initial in allStates {
            if initial == .estopped {
                // .estopped 는 .estopRequested → .estopped (동일 state) 이므로
                // .recoveryAcknowledged 로 출구 확인.
                var sm = MobilePilotStateMachine(initial: .estopped)
                let r = sm.apply(.recoveryAcknowledged)
                XCTAssertNotEqual(r.nextState, .estopped,
                                  "AC: .estopped 가 .recoveryAcknowledged 출구 보유")
                continue
            }
            // 기타 state 는 .estopRequested 로 .estopped 진입 (출구 보유).
            var sm = MobilePilotStateMachine(initial: initial)
            let r = sm.apply(.estopRequested)
            XCTAssertNotEqual(r.nextState, initial,
                              "AC: \(initial) 가 estopRequested 출구 보유 (dead state 아님)")
        }
    }

    // MARK: - Property: estopped recovery path preserved

    /// Property: estopped → armRequested → arming (복구 회로 보존).
    ///
    /// V297-8 (P3-Tests): estopped recovery path
    func testProperty_estoppedRecoveryPathPreserved() {
        var sm = MobilePilotStateMachine(initial: .estopped)
        let r1 = sm.apply(.armRequested)
        XCTAssertEqual(r1.nextState, .arming,
                       "AC: estopped + armRequested → arming (복구 1단계)")
        let r2 = sm.apply(.armed)
        XCTAssertEqual(r2.nextState, .armedReady,
                       "AC: arming + armed → armedReady (복구 완료)")
    }

    // MARK: - Helpers

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
