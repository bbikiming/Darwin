import XCTest
@testable import DarwinForgeUI

/// 자동 연결 휴리스틱 단위 테스트 — 비전문가가 "자동 연결" 클릭 시
/// 가장 자주 마주하는 시나리오 5가지.
final class AutoConnectHeuristicTests: XCTestCase {

    func testUSBSerialBeatsUSBModem() {
        let result = AutoConnect.bestGuess(among: [
            "/dev/cu.usbmodem11201",
            "/dev/cu.usbserial-AB0123"
        ])
        XCTAssertEqual(result, "/dev/cu.usbserial-AB0123",
                       "FTDI 직렬 어댑터가 modem보다 점수 높아야 한다")
    }

    func testUSBModemAcceptedIfNothingBetter() {
        let result = AutoConnect.bestGuess(among: ["/dev/cu.usbmodem11201"])
        XCTAssertEqual(result, "/dev/cu.usbmodem11201")
    }

    func testBluetoothIsSkipped() {
        let result = AutoConnect.bestGuess(among: [
            "/dev/cu.Bluetooth-Incoming-Port",
            "/dev/cu.usbserial-X"
        ])
        XCTAssertEqual(result, "/dev/cu.usbserial-X",
                       "Bluetooth 채널은 USB-Serial 후보를 덮으면 안 된다")
    }

    func testOnlyBluetoothReturnsNil() {
        let result = AutoConnect.bestGuess(among: ["/dev/cu.Bluetooth-Incoming-Port"])
        XCTAssertNil(result, "양수 점수 후보가 없으면 nil")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(AutoConnect.bestGuess(among: []))
    }

    func testReasonForNoPortReadable() {
        let msg = AutoConnect.reasonForNoPort()
        XCTAssertFalse(msg.isEmpty)
        XCTAssertTrue(msg.contains("케이블") || msg.contains("전원"),
                      "비전문가가 다음 행동을 알 수 있어야 한다")
    }

    /// 모든 동작 명세 벡터 검증 (회귀 방지).
    func testTestVectorsRoundTrip() {
        for (label, ports, expected) in AutoConnectTestVectors.inputs {
            let result = AutoConnect.bestGuess(among: ports)
            XCTAssertEqual(result, expected, "\(label) 케이스가 일관성 깨짐")
        }
    }
}

/// 명령 팔레트 19개 카탈로그가 모두 한국어 라벨·설명을 가지는지 검증.
/// 비전문가가 ⌘K로 검색할 때 영어만 보이면 안 된다.
final class CommandCatalogLocalizationTests: XCTestCase {

    func testAllEntriesHaveKoreanTitle() {
        for entry in CommandCatalog.standard() {
            XCTAssertFalse(entry.title.isEmpty, "\(entry.id): 제목 비어있음")
            // 일부 한글이 포함되어야 한다.
            let hasHangul = entry.title.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
            XCTAssertTrue(hasHangul, "\(entry.id) 제목에 한글이 없음: \(entry.title)")
        }
    }

    func testAllEntriesHaveSubtitle() {
        for entry in CommandCatalog.standard() {
            XCTAssertFalse(entry.subtitle.isEmpty, "\(entry.id): 부제 비어있음")
        }
    }

    func testCatalogContainsCriticalCommands() {
        let ids = Set(CommandCatalog.standard().map { $0.id })
        let critical = ["connect", "disconnect", "estop", "wakeup", "sleep",
                        "play-page", "import-motion"]
        for id in critical {
            XCTAssertTrue(ids.contains(id), "필수 명령 누락: \(id)")
        }
    }

    func testEStopIsMarkedDangerous() {
        let estop = CommandCatalog.standard().first { $0.id == "estop" }
        XCTAssertNotNil(estop)
        XCTAssertTrue(estop!.dangerous, "긴급정지는 dangerous flag가 켜져야 한다")
    }
}
