import XCTest
@testable import DarwinForgeUI

/// 유무선 링크 — WiFi IP 자동탐지 파싱 (ConnectionWizardView.parseWifiIP) 검증.
/// SSH combined 출력(WIFI_IP 라인 + exit suffix/stderr)에서 IPv4 만 견고하게 추출.
final class ConnectionLinkTests: XCTestCase {

    func testParsesWifiIPFromCombinedOutput() {
        let out = "WIFI_IP=192.168.0.33\n--- exit 0 ---"
        XCTAssertEqual(ConnectionWizardView.parseWifiIP(out), "192.168.0.33")
    }

    func testParsesWithLeadingStderr() {
        let out = "warning: x\nWIFI_IP=192.168.0.41\n--- exit 0 ---"
        XCTAssertEqual(ConnectionWizardView.parseWifiIP(out), "192.168.0.41")
    }

    func testEmptyWifiIPReturnsNil() {
        XCTAssertNil(ConnectionWizardView.parseWifiIP("WIFI_IP=\n--- exit 0 ---"))
    }

    func testNoLineReturnsNil() {
        XCTAssertNil(ConnectionWizardView.parseWifiIP("no wlan here\n--- exit 1 ---"))
    }

    func testMalformedIPReturnsNil() {
        XCTAssertNil(ConnectionWizardView.parseWifiIP("WIFI_IP=999.1.1\n"))
        XCTAssertNil(ConnectionWizardView.parseWifiIP("WIFI_IP=300.1.1.1\n"))
        XCTAssertNil(ConnectionWizardView.parseWifiIP("WIFI_IP=abc\n"))
    }

    func testConnectionLinkDisplay() {
        XCTAssertEqual(ConnectionLink.wired.title, "유선")
        XCTAssertEqual(ConnectionLink.wireless.title, "무선")
        XCTAssertEqual(ConnectionLink.allCases.count, 2)
    }

    // 무선 호스트 검증 — 빈/형식오류는 reject (유선 silent fallback 방지).
    func testIsLikelyValidHost() {
        XCTAssertTrue(ConnectionWizardView.isLikelyValidHost("192.168.0.33"))
        XCTAssertTrue(ConnectionWizardView.isLikelyValidHost("op2.local"))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost(""))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("   "))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("300.1.1.1"))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("nohostdot"))
        // codex LOW — 형식 깨진 호스트명 거부.
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("foo..local"))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("bad_.local"))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("-op2.local"))
        // codex 2차 LOW — 빈 옥텟 IP 거부.
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("192..168.0.33"))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost(".192.168.0.33"))
        XCTAssertFalse(ConnectionWizardView.isLikelyValidHost("192.168.0.33."))
    }
}
