import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **Wave 2 — J2 머리 SYNC_WRITE + detached coalesce (2026-06-11)** 회귀 가드.
///
/// `writeHeadPose` 가 (a) headPan/headTilt 를 setPositions 1패킷(SYNC_WRITE)으로 묶고,
/// (b) freshSession 일 때만 moving speed 를 설정하며, (c) dxlPower 게이트를 position
/// write 와 동일하게 집행(OFF 시 E-STOP)하는지 검증.
@MainActor
final class WriteHeadPoseTests: XCTestCase {

    private func makeStore(bus: MockBus, powerOn: Bool = true) -> ConnectionStore {
        let store = ConnectionStore()
        store.bus = bus
        if powerOn { store._setDxlPowerState(true) }
        return store
    }

    // MARK: - SYNC_WRITE 배치

    func testWriteHeadPose_PowerOn_UsesSingleBatchSetPositions() async {
        let bus = MockBus()
        let store = makeStore(bus: bus)
        store.writeHeadPose(panRaw: 2100, tiltRaw: 1900, panSpeed: nil, tiltSpeed: nil)
        await store._testAwaitHeadDispatch()

        XCTAssertEqual(bus.batchPositionCalls.count, 1, "머리 pan/tilt 는 1패킷 SYNC_WRITE")
        let batch = bus.batchPositionCalls.first ?? []
        XCTAssertEqual(Set(batch.map { $0.joint }), [.headPan, .headTilt],
                       "한 배치에 headPan + headTilt")
        let dict = Dictionary(uniqueKeysWithValues: batch.map { ($0.joint, $0.raw) })
        XCTAssertEqual(dict[.headPan], 2100)
        XCTAssertEqual(dict[.headTilt], 1900)
    }

    // MARK: - freshSession moving speed

    func testWriteHeadPose_FreshSession_SetsBothMovingSpeeds() async {
        let bus = MockBus()
        let store = makeStore(bus: bus)
        store.writeHeadPose(panRaw: 2048, tiltRaw: 2048, panSpeed: 70, tiltSpeed: 90)
        await store._testAwaitHeadDispatch()

        let speedJoints = Dictionary(uniqueKeysWithValues: bus.speedWrites.map { ($0.joint, $0.speed) })
        XCTAssertEqual(speedJoints[.headPan], 70, "freshSession 에 headPan moving speed 설정")
        XCTAssertEqual(speedJoints[.headTilt], 90, "freshSession 에 headTilt moving speed 설정")
    }

    func testWriteHeadPose_NonFresh_SkipsMovingSpeeds() async {
        let bus = MockBus()
        let store = makeStore(bus: bus)
        store.writeHeadPose(panRaw: 2048, tiltRaw: 2048, panSpeed: nil, tiltSpeed: nil)
        await store._testAwaitHeadDispatch()

        XCTAssertTrue(bus.speedWrites.isEmpty, "연속 조종(non-fresh) 은 moving speed 재설정 안 함")
        XCTAssertEqual(bus.batchPositionCalls.count, 1, "위치는 여전히 송출")
    }

    // MARK: - dxlPower 게이트

    func testWriteHeadPose_DxlPowerOff_TriggersEmergencyStop_NoWrite() async {
        let bus = MockBus()
        let store = makeStore(bus: bus, powerOn: false)
        store.writeHeadPose(panRaw: 2048, tiltRaw: 2048, panSpeed: nil, tiltSpeed: nil)
        await store._testAwaitHeadDispatch()

        XCTAssertEqual(bus.emergencyStopCount, 1, "dxlPower OFF → E-STOP (position write 와 동일)")
        XCTAssertTrue(bus.batchPositionCalls.isEmpty, "게이트 차단 시 머리 write 미실행")
    }

    func testWriteHeadPose_BusNil_NoCrash() async {
        let store = ConnectionStore()
        store._setDxlPowerState(true)   // bus 는 nil
        store.writeHeadPose(panRaw: 2048, tiltRaw: 2048, panSpeed: nil, tiltSpeed: nil)
        await store._testAwaitHeadDispatch()
        // bus nil → 게이트가 차단(E-STOP 경로), crash 없음.
    }
}
