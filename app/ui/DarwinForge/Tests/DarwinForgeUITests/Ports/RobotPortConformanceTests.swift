import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **V287-3** — RobotPort protocol conformance + safety gate test.
///
/// 본 cycle 은 protocol 정의만 — MockRobotAdapter 동작 + dxlPower gate 의 contract
/// 검증. V288 에서 실 DXLAdapter 가 추가되면 동일 test fixture 재사용.
final class RobotPortConformanceTests: XCTestCase {

    func testMockAdapter_PowerOff_WriteThrowsDxlPowerOff() async {
        let adapter = MockRobotAdapter()
        adapter.simulatedDxlPower = false
        do {
            _ = try await adapter.writeJointPosition(.rHipRoll, raw: 2048)
            XCTFail("expected RobotPortError.dxlPowerOff")
        } catch RobotPortError.dxlPowerOff {
            // OK
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(adapter.writeCount, 0, "차단된 write 는 count 안 됨")
    }

    func testMockAdapter_PowerOn_WriteSucceeds() async throws {
        let adapter = MockRobotAdapter()
        adapter.simulatedDxlPower = true
        let echoed = try await adapter.writeJointPosition(.lKnee, raw: 1024)
        XCTAssertEqual(echoed, 1024, "echo-style return")
        XCTAssertEqual(adapter.writeCount, 1)
        XCTAssertEqual(adapter.lastWrite?.joint, .lKnee)
        XCTAssertEqual(adapter.lastWrite?.raw, 1024)
    }

    func testMockAdapter_EmergencyStop_ChainsDxlPowerOff() async {
        let adapter = MockRobotAdapter()
        adapter.simulatedDxlPower = true
        await adapter.emergencyStop()
        let powerAfter = await adapter.isDxlPowerOn
        XCTAssertFalse(powerAfter, "e-stop = dxlPower OFF 강제")
        XCTAssertEqual(adapter.emergencyStopCount, 1)
        let status = await adapter.connectionStatus
        XCTAssertEqual(status, .emergencyStopped)
    }

    func testMockAdapter_Recover_RestoresPowerAndStatus() async throws {
        let adapter = MockRobotAdapter()
        await adapter.emergencyStop()
        try await adapter.recover()
        let powerAfter = await adapter.isDxlPowerOn
        XCTAssertTrue(powerAfter)
        let status = await adapter.connectionStatus
        if case .connected = status { /* OK */ }
        else { XCTFail("expected .connected, got \(status)") }
    }
}
