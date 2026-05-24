import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// V283-4 — dxlPower OFF gate 단위 검증 (V282-2 CRITICAL-3 fix).
///
/// # 비유
///
/// 시동이 꺼진 차에서 악셀을 밟아도 게이트가 차단하는지 확인하는 안전 점검.
/// gate 는 (1) dxlPower OFF 시 throw, (2) emergencyStop 발동, (3) harness 기록
/// 의 세 가지를 동시에 수행해야 한다.
@MainActor
final class DxlPowerGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(bus: MockBus? = nil) -> ConnectionStore {
        let store = ConnectionStore()
        if let bus {
            store.bus = bus
        }
        return store
    }

    // MARK: - isDxlPowerOn 초기 상태

    /// 신규 ConnectionStore 는 dxlPower OFF 가 기본 — 의도치 않은 gate 통과 방지.
    func testIsDxlPowerOn_InitialState_IsFalse() {
        let store = makeStore()
        XCTAssertFalse(store.isDxlPowerOn, "초기 상태는 dxlPower OFF — gate 차단 준비")
    }

    // MARK: - writeJointPosition gate: dxlPower OFF

    /// dxlPower OFF 상태에서 writeJointPosition 호출 → DxlGateError.dxlPowerOff throw.
    func testWriteJointPosition_DxlPowerOff_ThrowsDxlGateError() throws {
        let store = makeStore(bus: MockBus())
        XCTAssertThrowsError(try store.writeJointPosition(.lHipRoll, raw: 2048)) { err in
            XCTAssertTrue(err is DxlGateError,
                          "dxlPower OFF 시 DxlGateError 를 throw 해야 함. 실제: \(err)")
            XCTAssertEqual(err as? DxlGateError, DxlGateError.dxlPowerOff)
        }
    }

    /// dxlPower OFF + writeJointPosition → emergencyStop 발동 확인.
    func testWriteJointPosition_DxlPowerOff_TriggersEmergencyStop() throws {
        let bus = MockBus()
        let store = makeStore(bus: bus)
        _ = try? store.writeJointPosition(.rKnee, raw: 2048)
        XCTAssertEqual(bus.emergencyStopCount, 1,
                       "dxlPower OFF 시 emergencyStop 을 1회 호출해야 함")
    }

    // MARK: - writeJointPosition gate: dxlPower ON

    /// dxlPower ON 상태 → writeJointPosition 이 bus.setPosition 으로 위임, throw 없음.
    func testWriteJointPosition_DxlPowerOn_Succeeds() throws {
        let bus = MockBus()
        let store = makeStore(bus: bus)
        store._setDxlPowerState(true)
        _ = try store.writeJointPosition(.headPan, raw: 2048)
        XCTAssertEqual(bus.positionWrites.count, 1,
                       "dxlPower ON 시 bus.setPosition 을 1회 호출해야 함")
        XCTAssertEqual(bus.positionWrites.first?.joint, .headPan)
        XCTAssertEqual(bus.positionWrites.first?.raw, 2048)
    }

    // MARK: - emergencyStop 이 isDxlPowerOn 을 리셋

    /// emergencyStop 호출 후 isDxlPowerOn = false — gate 일관성.
    func testEmergencyStop_ResetsDxlPowerState() {
        let bus = MockBus()
        let store = makeStore(bus: bus)
        store._setDxlPowerState(true)
        XCTAssertTrue(store.isDxlPowerOn)
        store.emergencyStop()
        XCTAssertFalse(store.isDxlPowerOn,
                       "emergencyStop 후 isDxlPowerOn 은 false 여야 함")
    }

    // MARK: - _setDxlPowerState 상태 갱신

    /// _setDxlPowerState(true) → isDxlPowerOn = true.
    func testSetDxlPowerState_True_UpdatesFlag() {
        let store = makeStore()
        store._setDxlPowerState(true)
        XCTAssertTrue(store.isDxlPowerOn)
    }

    /// _setDxlPowerState(false) → isDxlPowerOn = false.
    func testSetDxlPowerState_False_UpdatesFlag() {
        let store = makeStore()
        store._setDxlPowerState(true)
        store._setDxlPowerState(false)
        XCTAssertFalse(store.isDxlPowerOn)
    }

    // MARK: - bus nil 시 gate 동작

    /// bus 가 nil 이고 dxlPower ON 이어도 writeJointPosition → DxlGateError.dxlPowerOff.
    func testWriteJointPosition_BusNil_ThrowsEvenWhenPowerOn() throws {
        let store = makeStore(bus: nil)
        store._setDxlPowerState(true)
        XCTAssertThrowsError(try store.writeJointPosition(.rKnee, raw: 2048)) { err in
            XCTAssertEqual(err as? DxlGateError, DxlGateError.dxlPowerOff,
                           "bus nil 시 dxlPowerOff 를 throw 해야 함")
        }
    }
}
