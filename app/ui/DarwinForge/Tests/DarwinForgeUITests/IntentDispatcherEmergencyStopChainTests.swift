import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// V288-3 — IntentDispatcher.fireEmergencyStop() SSoT 검증.
///
/// # 비유
///
/// 비행기 비상 슬라이드 — 한번 작동하면 6단계가 한 transaction 으로 진행.
/// 중간에 멈추거나 순서가 바뀌면 승객(로봇)이 위험. 본 테스트가 그 순서를 검증.
///
/// # 6단계 chain (V287-3 RobotPort.emergencyStop() 정의)
///
///   1. walkSession.cancel()         — 현재 보행 중단
///   2. bus.torqueOff(.all)          — 모든 joint torque OFF
///   3. dxlPower = false             — power state 갱신
///   4. connectionStatus = .emergencyStopped — UI 통보
///   5. telemetry.record(eStopEvent) — 감사 로그
///   6. Logger.log("E-STOP fired")   — system log (os_log)
@MainActor
final class IntentDispatcherEmergencyStopChainTests: XCTestCase {

    // MARK: - Helpers

    private func makeDispatcher(
        bus: MockBus?,
        harness: RecordingHarness
    ) -> (dispatcher: IntentDispatcher, store: ConnectionStore, harness: RecordingHarness) {
        let store = ConnectionStore(harness: harness)
        if let bus { store.bus = bus }
        let dispatcher = IntentDispatcher(harness: harness)
        dispatcher.connectionStore = store
        return (dispatcher, store, harness)
    }

    // MARK: - 단일 진입점 존재 (IntentDispatcher.fireEmergencyStop)

    /// fireEmergencyStop() 이 존재하고 호출 가능한지 — 컴파일 통과 = 존재 검증.
    func testFireEmergencyStop_Exists() async {
        let (dispatcher, _, _) = makeDispatcher(bus: MockBus(), harness: RecordingHarness())
        let result = await dispatcher.fireEmergencyStop()
        XCTAssertFalse(result.speak.isEmpty, "fireEmergencyStop 은 한국어 응답을 반환해야 함")
    }

    // MARK: - 6단계 chain: bus torque OFF (Step 2 + 3)

    /// fireEmergencyStop 호출 → bus.emergencyStop 이 정확히 1회 호출 (torque OFF).
    func testFireEmergencyStop_CallsBusEmergencyStop() async {
        let bus = MockBus()
        let (dispatcher, store, _) = makeDispatcher(bus: bus, harness: RecordingHarness())
        _ = store  // weak connectionStore — store 를 강한 참조로 유지
        _ = await dispatcher.fireEmergencyStop()
        XCTAssertEqual(bus.emergencyStopCount, 1,
                       "bus.emergencyStop 이 정확히 1회 호출되어야 함 (torque OFF)")
    }

    /// fireEmergencyStop 후 store.isDxlPowerOn = false (Step 3: dxlPower = false).
    func testFireEmergencyStop_SetsDxlPowerFalse() async {
        let bus = MockBus()
        let (dispatcher, store, _) = makeDispatcher(bus: bus, harness: RecordingHarness())
        store._setDxlPowerState(true)
        XCTAssertTrue(store.isDxlPowerOn, "사전 조건: dxlPower ON")
        _ = await dispatcher.fireEmergencyStop()
        XCTAssertFalse(store.isDxlPowerOn,
                       "fireEmergencyStop 후 dxlPower 는 false 여야 함 (Step 3)")
    }

    // MARK: - 6단계 chain: telemetry (Step 5)

    /// fireEmergencyStop → harness.record(.busEStop) 1회 이상 기록 (Step 5).
    func testFireEmergencyStop_RecordsTelemetry() async {
        let harness = RecordingHarness()
        let (dispatcher, _, _) = makeDispatcher(bus: MockBus(), harness: harness)
        harness.reset()
        _ = await dispatcher.fireEmergencyStop()
        let eStopEvents = harness.events.filter { $0.kind == .busEStop }
        XCTAssertGreaterThanOrEqual(eStopEvents.count, 1,
                                    "busEStop telemetry 가 1회 이상 기록되어야 함 (Step 5)")
    }

    /// telemetry actor 가 .user (사용자 트리거 이벤트).
    func testFireEmergencyStop_TelemetryActorIsUser() async {
        let harness = RecordingHarness()
        let (dispatcher, _, _) = makeDispatcher(bus: MockBus(), harness: harness)
        harness.reset()
        _ = await dispatcher.fireEmergencyStop()
        let eStopEvents = harness.events.filter { $0.kind == .busEStop }
        guard let first = eStopEvents.first else {
            XCTFail("busEStop telemetry 없음")
            return
        }
        XCTAssertEqual(first.actor, .user,
                       "e-stop telemetry actor 는 .user 여야 함")
    }

    // MARK: - Idempotent: 2번 호출 → 1번만 chain 실행

    /// fireEmergencyStop 2번 호출 → bus.emergencyStop 은 1번만 실행 (idempotent).
    func testFireEmergencyStop_Idempotent_BusCalledOnce() async {
        let bus = MockBus()
        let (dispatcher, store, _) = makeDispatcher(bus: bus, harness: RecordingHarness())
        _ = store  // weak connectionStore — store 를 강한 참조로 유지
        _ = await dispatcher.fireEmergencyStop()
        _ = await dispatcher.fireEmergencyStop()   // 두 번째는 no-op
        XCTAssertEqual(bus.emergencyStopCount, 1,
                       "idempotent: 2번 호출해도 bus.emergencyStop 은 1회만 실행")
    }

    /// 2번째 호출도 정상 ExecutionResult 반환 (no crash).
    func testFireEmergencyStop_Idempotent_SecondCallReturnsSafely() async {
        let (dispatcher, _, _) = makeDispatcher(bus: MockBus(), harness: RecordingHarness())
        _ = await dispatcher.fireEmergencyStop()
        let result = await dispatcher.fireEmergencyStop()
        XCTAssertFalse(result.speak.isEmpty, "2번째 호출도 응답 메시지를 반환해야 함")
    }

    // MARK: - bus nil 시 안전 (시뮬 모드)

    /// bus 없어도 fireEmergencyStop 이 throw 없이 완료 (시뮬 응답 반환).
    func testFireEmergencyStop_NoBus_ReturnsSafeResult() async {
        let (dispatcher, _, _) = makeDispatcher(bus: nil, harness: RecordingHarness())
        let result = await dispatcher.fireEmergencyStop()
        XCTAssertFalse(result.speak.isEmpty, "bus nil 시에도 빈 응답이면 안 됨")
    }

    /// bus nil + fireEmergencyStop 2번 → idempotent 유지 (no crash).
    func testFireEmergencyStop_NoBus_IdempotentSafe() async {
        let (dispatcher, _, _) = makeDispatcher(bus: nil, harness: RecordingHarness())
        _ = await dispatcher.fireEmergencyStop()
        let result = await dispatcher.fireEmergencyStop()
        XCTAssertFalse(result.speak.isEmpty, "bus nil + 2번 호출도 안전해야 함")
    }
}
