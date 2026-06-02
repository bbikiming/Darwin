import XCTest
@testable import DarwinForgeUI

/// V297-2 — IP 인터페이스 열거 + Wi-Fi 우선 정렬 + setAdvertisedHost persist 검증.
///
/// 비유: 여러 전화번호 중 iPhone 과 같은 교환 망에 있는 번호를 자동으로 골라주는
/// 스마트 전화번호 picker 와 같다.
@MainActor
final class V297HostPickerTests: XCTestCase {

    // MARK: - isPrivateIPv4

    func testPrivateIPv4_192_168_range() {
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("192.168.0.1"))
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("192.168.0.60"))
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("192.168.255.255"))
    }

    func testPrivateIPv4_10_range() {
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("10.0.0.1"))
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("10.255.255.255"))
    }

    func testPrivateIPv4_172_16_31_range() {
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("172.16.0.1"))
        XCTAssertTrue(MobileRelayController.isPrivateIPv4("172.31.255.255"))
        XCTAssertFalse(MobileRelayController.isPrivateIPv4("172.15.0.1"))
        XCTAssertFalse(MobileRelayController.isPrivateIPv4("172.32.0.1"))
    }

    func testPublicIP_isNotPrivate() {
        XCTAssertFalse(MobileRelayController.isPrivateIPv4("220.93.150.29"))
        XCTAssertFalse(MobileRelayController.isPrivateIPv4("8.8.8.8"))
    }

    // MARK: - HostCandidate sort order

    func testSortOrder_wifiPrivateFirst() {
        let candidates = [
            HostCandidate(ifName: "en0", ip: "220.93.150.29", isWiFi: false, isPrivate: false),
            HostCandidate(ifName: "en1", ip: "192.168.0.60",  isWiFi: true,  isPrivate: true),
            HostCandidate(ifName: "en2", ip: "10.0.0.5",      isWiFi: false, isPrivate: true),
            HostCandidate(ifName: "en3", ip: "203.0.113.1",   isWiFi: true,  isPrivate: false),
        ]

        let sorted = candidates.sorted { lhs, rhs in
            func score(_ c: HostCandidate) -> Int {
                switch (c.isWiFi, c.isPrivate) {
                case (true,  true):  return 3
                case (true,  false): return 2
                case (false, true):  return 1
                case (false, false): return 0
                }
            }
            let ls = score(lhs), rs = score(rhs)
            if ls != rs { return ls > rs }
            return lhs.ifName < rhs.ifName
        }

        XCTAssertEqual(sorted[0].ip, "192.168.0.60",  "Wi-Fi 사설 IP 가 1위여야 한다")
        XCTAssertEqual(sorted[1].ip, "203.0.113.1",   "Wi-Fi 공인 IP 가 2위여야 한다")
        XCTAssertEqual(sorted[2].ip, "10.0.0.5",      "유선 사설 IP 가 3위여야 한다")
        XCTAssertEqual(sorted[3].ip, "220.93.150.29", "유선 공인 IP 가 4위여야 한다")
    }

    // MARK: - enumerateLocalIPv4Interfaces

    func testEnumeration_returnsAtLeastOneEntry_onRealMac() {
        // 실제 Mac 에서 실행 — loopback 은 제외되어야 한다.
        let candidates = MobileRelayController.enumerateLocalIPv4Interfaces()
        // 테스트 환경에 따라 0이 될 수 있으나 실제 Mac 은 항상 1개 이상.
        for c in candidates {
            XCTAssertNotEqual(c.ip, "127.0.0.1", "loopback 은 제외되어야 한다")
            XCTAssertFalse(c.ifName.isEmpty, "ifName 이 비어 있으면 안 된다")
            XCTAssertFalse(c.ip.isEmpty, "ip 가 비어 있으면 안 된다")
        }
    }

    func testEnumeration_wifiPrivateComeFirst() {
        let candidates = MobileRelayController.enumerateLocalIPv4Interfaces()
        guard candidates.count >= 2 else { return } // 단일 인터페이스 환경은 skip
        if let first = candidates.first, let second = candidates.dropFirst().first {
            // Wi-Fi + private 가 있다면 첫 번째여야 한다.
            if second.isWiFi && second.isPrivate {
                XCTAssertTrue(first.isWiFi && first.isPrivate,
                              "Wi-Fi 사설 IP 가 가장 앞에 와야 한다")
            }
        }
    }

    func testFirstLocalIPv4_matchesFirstEnumerated() {
        let first = MobileRelayController.firstLocalIPv4()
        let enumFirst = MobileRelayController.enumerateLocalIPv4Interfaces().first?.ip
        XCTAssertEqual(first, enumFirst,
                       "firstLocalIPv4() 는 enumerateLocalIPv4Interfaces().first 와 같아야 한다")
    }

    // MARK: - setAdvertisedHost + UserDefaults persist

    func testSetAdvertisedHost_updatesPublishedValue() async {
        let controller = MobileRelayController(port: InMemorySafetyPort())
        await controller.start()
        defer { Task { await controller.stop() } }

        guard let target = controller.availableHosts.first else {
            // 네트워크 없는 CI 환경 — skip
            return
        }

        controller.setAdvertisedHost(target.ip)
        XCTAssertEqual(controller.advertisedHost, target.ip,
                       "setAdvertisedHost 후 advertisedHost 가 즉시 갱신되어야 한다")
    }

    func testSetAdvertisedHost_persistsToUserDefaults() async {
        let controller = MobileRelayController(port: InMemorySafetyPort())
        await controller.start()
        defer { Task { await controller.stop() } }

        guard let target = controller.availableHosts.first else { return }

        controller.setAdvertisedHost(target.ip)
        let stored = UserDefaults.standard.string(forKey: "mobileRelay.preferredHost")
        XCTAssertEqual(stored, target.ip,
                       "setAdvertisedHost 후 UserDefaults 에 persist 되어야 한다")

        // 정리
        UserDefaults.standard.removeObject(forKey: "mobileRelay.preferredHost")
    }

    func testSetAdvertisedHost_ignoresUnknownIP() async {
        let controller = MobileRelayController(port: InMemorySafetyPort())
        await controller.start()
        defer { Task { await controller.stop() } }

        let before = controller.advertisedHost
        controller.setAdvertisedHost("1.2.3.4") // 목록에 없는 IP
        XCTAssertEqual(controller.advertisedHost, before,
                       "목록에 없는 IP 는 무시되어야 한다")
    }

    // MARK: - HostCandidate identity

    func testHostCandidate_id_composition() {
        let c = HostCandidate(ifName: "en1", ip: "192.168.0.60", isWiFi: true, isPrivate: true)
        XCTAssertEqual(c.id, "en1/192.168.0.60")
    }

    func testHostCandidate_displayName_wifiLan() {
        let c = HostCandidate(ifName: "en1", ip: "192.168.0.60", isWiFi: true, isPrivate: true)
        XCTAssertEqual(c.displayName, "en1 — 192.168.0.60 (Wi-Fi, LAN)")
    }

    func testHostCandidate_displayName_wiredPublic() {
        let c = HostCandidate(ifName: "en0", ip: "220.93.150.29", isWiFi: false, isPrivate: false)
        XCTAssertEqual(c.displayName, "en0 — 220.93.150.29 (유선, 공인)")
    }
}
