import XCTest
@testable import DarwinForgeUI

/// `ControllerDeviceKind` — 통합 「컨트롤러 연결」 시트의 장치 세그먼트 식별자.
/// 자동 선택 우선순위(DJI 우선, 게임패드 폴백)·라벨·아이콘 검증.
final class ControllerDeviceKindTests: XCTestCase {

    // MARK: - autoSelect 우선순위

    func test_autoSelect_prefers_dji_when_connected() {
        XCTAssertEqual(
            ControllerDeviceKind.autoSelect(djiConnected: true, gamepadConnected: false),
            .djiRC)
        // 둘 다 연결돼 있어도 DJI 우선 (실 RC 가 명시적 의도라고 본다).
        XCTAssertEqual(
            ControllerDeviceKind.autoSelect(djiConnected: true, gamepadConnected: true),
            .djiRC)
    }

    func test_autoSelect_falls_back_to_gamepad() {
        XCTAssertEqual(
            ControllerDeviceKind.autoSelect(djiConnected: false, gamepadConnected: true),
            .gamepad)
        // 아무것도 연결 안 됨 → 게임패드 (가상 패드 폴백이 있어 의미 있는 기본값).
        XCTAssertEqual(
            ControllerDeviceKind.autoSelect(djiConnected: false, gamepadConnected: false),
            .gamepad)
    }

    // MARK: - 표기

    func test_labels_are_korean_and_distinct() {
        XCTAssertEqual(ControllerDeviceKind.gamepad.label, "게임패드")
        XCTAssertEqual(ControllerDeviceKind.djiRC.label, "DJI RC")
    }

    func test_each_kind_has_a_symbol_and_two_cases() {
        XCTAssertEqual(ControllerDeviceKind.allCases.count, 2)
        XCTAssertFalse(ControllerDeviceKind.gamepad.systemImage.isEmpty)
        XCTAssertFalse(ControllerDeviceKind.djiRC.systemImage.isEmpty)
    }

    func test_identifiable_id_matches_raw_value() {
        XCTAssertEqual(ControllerDeviceKind.gamepad.id, ControllerDeviceKind.gamepad.rawValue)
        XCTAssertEqual(ControllerDeviceKind.djiRC.id, ControllerDeviceKind.djiRC.rawValue)
    }
}
