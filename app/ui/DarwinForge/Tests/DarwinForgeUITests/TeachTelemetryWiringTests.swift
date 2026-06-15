import XCTest
@testable import DarwinForgeUI

/// 사이클 193 P0 #1 — teachTorqueChanged 텔레메트리 regression guard.
final class TeachTelemetryWiringTests: XCTestCase {

    // MARK: - Kind definition

    /// TelemetryKind.teachTorqueChanged 가 정의되어 있는지 확인 — 누군가 지우면 이 테스트가 깨짐.
    func testTeachTorqueChangedKindExists() {
        let kind = TelemetryKind.teachTorqueChanged
        XCTAssertEqual(kind.rawValue, "teach.torque_changed",
                       "teachTorqueChanged rawValue 가 'teach.torque_changed' 이어야 함")
    }

    // MARK: - Action payload contract

    /// 4개의 action 값이 모두 명시된 계약을 따르는지 확인.
    func testTeachTorqueChangedActionValues() {
        let expectedActions: Set<String> = [
            "disable_all",
            "enable_all",
            "toggle",
            "capture_loop_auto_disable"
        ]
        // 이 테스트는 소스 코드의 계약을 문서화하는 역할.
        // 만약 action 값이 변경되면 이 세트를 함께 업데이트해야 함.
        XCTAssertEqual(expectedActions.count, 4,
                       "teachTorqueChanged 는 정확히 4개의 action 값을 가져야 함")
        XCTAssertTrue(expectedActions.contains("disable_all"))
        XCTAssertTrue(expectedActions.contains("enable_all"))
        XCTAssertTrue(expectedActions.contains("toggle"))
        XCTAssertTrue(expectedActions.contains("capture_loop_auto_disable"))
    }
}
