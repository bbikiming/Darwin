import XCTest
@testable import ForgeCore

/// AutoConnect 테스트는 DarwinForgeUI 모듈에 있으므로 ForgeCore에서는
/// SerialPortEnumerator만 검증.
final class SerialPortListSmokeTests: XCTestCase {
    func testListPortsReturnsArrayOrThrows() throws {
        // 시스템에 실제 USB serial 디바이스가 없어도 빈 배열을 반환해야 한다.
        let ports = (try? SerialPortEnumerator.available()) ?? []
        XCTAssertTrue(ports.allSatisfy { $0.hasPrefix("/dev/") },
                      "list_ports는 모두 /dev/* 경로여야 한다")
    }

    func testForgeCoreVersionNonEmpty() {
        let v = forgeCoreVersion()
        XCTAssertFalse(v.isEmpty)
    }
}
