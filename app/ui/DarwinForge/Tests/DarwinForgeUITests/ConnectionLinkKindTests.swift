import XCTest
@testable import DarwinForgeUI

/// **활성 경로 분류 (유선/무선) 단위 테스트 (2026-06-02)**.
///
/// 실측 버그 맥락: 무선이라 믿었으나 활성 host 가 유선 직결 IP(192.168.123.1)라 랜선을
/// 뽑으면 모터가 멈췄다. 분류기는 "지금 케이블에 의존하는가"를 정직하게 판정해야 한다.
final class ConnectionLinkKindTests: XCTestCase {

    func testWiredSubnetClassifiesAsWired() {
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.123.1"), .wired)
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.123.55"), .wired)
        // 공백 트림.
        XCTAssertEqual(ConnectionLinkKind.classify(host: "  192.168.123.1  "), .wired)
    }

    func testWifiSubnetClassifiesAsWireless() {
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.0.33"), .wireless)
        XCTAssertEqual(ConnectionLinkKind.classify(host: "10.0.0.5"), .wireless)
    }

    /// codex HIGH fix: 호스트명은 무선으로 단정하지 않는다(유선 IP 로 resolve 될 수 있음) → unknown.
    func testHostnamesAreUnknownNotWireless() {
        XCTAssertEqual(ConnectionLinkKind.classify(host: "op2.local"), .unknown)
        XCTAssertEqual(ConnectionLinkKind.classify(host: "darwin.lan"), .unknown)
    }

    /// codex MEDIUM fix: 잘못된 IPv4 문자열은 유선으로 오분류되면 안 됨 → unknown.
    func testMalformedIPv4IsUnknown() {
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.123.foo"), .unknown)
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.123"), .unknown)    // 옥텟 3개
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.123.1.1"), .unknown) // 5개
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.123."), .unknown)   // 빈 옥텟
        XCTAssertEqual(ConnectionLinkKind.classify(host: "192.168.300.1"), .unknown)  // 범위 초과
    }

    func testEmptyHostIsUnknown() {
        XCTAssertEqual(ConnectionLinkKind.classify(host: ""), .unknown)
        XCTAssertEqual(ConnectionLinkKind.classify(host: "   "), .unknown)
    }

    func testCableDependencyOnlyForWired() {
        XCTAssertTrue(ConnectionLinkKind.wired.requiresCable)
        XCTAssertFalse(ConnectionLinkKind.wireless.requiresCable)
        XCTAssertFalse(ConnectionLinkKind.unknown.requiresCable)
    }

    func testLabelsAreDistinct() {
        XCTAssertEqual(ConnectionLinkKind.wired.label, "유선")
        XCTAssertEqual(ConnectionLinkKind.wireless.label, "무선")
    }

    /// 직결 서브넷 접두사는 robotEthernetIP 에서 파생 — 상수와 일관되어야.
    func testWiredPrefixMatchesRobotEthernetConstant() {
        let wiredKind = ConnectionLinkKind.classify(host: DFConnectionConstants.robotEthernetIP)
        XCTAssertEqual(wiredKind, .wired, "robotEthernetIP 는 항상 유선으로 분류돼야 함")
    }
}
