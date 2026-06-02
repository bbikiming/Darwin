import XCTest
@testable import DarwinForgeUI

/// `DJIVirtualJoystickReport.decode(_:)` 의 결정론 검증.
///
/// 본 디코더는 IOKit / HID Manager 의존성이 없으므로 CI 에서 실 디바이스 없이도
/// 모든 input 케이스를 검증할 수 있다. 13-byte input report 의 각 byte 슬롯이
/// HID 디스크립터 사양 (24 buttons + 5 axes × int16 LE, -660..+660) 과 정확히
/// 일치하는지 검증.
final class DJIVirtualJoystickReportTests: XCTestCase {

    // MARK: - Length / sanity

    func test_rejects_wrong_length() {
        XCTAssertNil(DJIVirtualJoystickReport.decode(Data()))
        XCTAssertNil(DJIVirtualJoystickReport.decode(Data(count: 12)))
        XCTAssertNil(DJIVirtualJoystickReport.decode(Data(count: 14)))
    }

    func test_accepts_exact_length() {
        let r = DJIVirtualJoystickReport.decode(Data(count: 13))
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.buttons.count, 24)
        XCTAssertEqual(r?.axisX, 0)
        XCTAssertEqual(r?.axisY, 0)
        XCTAssertEqual(r?.axisZ, 0)
        XCTAssertEqual(r?.axisRx, 0)
        XCTAssertEqual(r?.axisRy, 0)
    }

    // MARK: - Buttons

    func test_button_1_lsb_of_byte_0() {
        var data = Data(count: 13)
        data[0] = 0b0000_0001
        let r = DJIVirtualJoystickReport.decode(data)!
        XCTAssertTrue(r.buttons[0])
        XCTAssertFalse(r.buttons[1])
        XCTAssertFalse(r.buttons[7])
    }

    func test_button_8_is_msb_of_byte_0_button_9_is_lsb_of_byte_1() {
        var data = Data(count: 13)
        data[0] = 0b1000_0000
        data[1] = 0b0000_0001
        let r = DJIVirtualJoystickReport.decode(data)!
        XCTAssertTrue(r.buttons[7])
        XCTAssertTrue(r.buttons[8])
        XCTAssertFalse(r.buttons[6])
        XCTAssertFalse(r.buttons[9])
    }

    func test_all_24_buttons_pressed() {
        var data = Data(count: 13)
        data[0] = 0xFF; data[1] = 0xFF; data[2] = 0xFF
        let r = DJIVirtualJoystickReport.decode(data)!
        XCTAssertEqual(r.buttons.filter { $0 }.count, 24)
    }

    // MARK: - Axes

    /// Helper — int16 LE 를 13-byte report 의 정확한 offset 에 write.
    private func reportWith(x: Int16 = 0, y: Int16 = 0, z: Int16 = 0,
                            rx: Int16 = 0, ry: Int16 = 0) -> Data {
        var d = Data(count: 13)
        func writeLE(_ value: Int16, at offset: Int) {
            let u = UInt16(bitPattern: value)
            d[offset]     = UInt8(u & 0xFF)
            d[offset + 1] = UInt8((u >> 8) & 0xFF)
        }
        writeLE(x,  at: 3)
        writeLE(y,  at: 5)
        writeLE(z,  at: 7)
        writeLE(rx, at: 9)
        writeLE(ry, at: 11)
        return d
    }

    func test_axis_X_positive_maximum_normalises_to_1() {
        let r = DJIVirtualJoystickReport.decode(reportWith(x: 660))!
        XCTAssertEqual(r.axisX, 1.0, accuracy: 0.0001)
    }

    func test_axis_X_negative_maximum_normalises_to_minus_1() {
        let r = DJIVirtualJoystickReport.decode(reportWith(x: -660))!
        XCTAssertEqual(r.axisX, -1.0, accuracy: 0.0001)
    }

    func test_axis_X_zero_is_zero() {
        let r = DJIVirtualJoystickReport.decode(reportWith(x: 0))!
        XCTAssertEqual(r.axisX, 0.0, accuracy: 0.0001)
    }

    func test_axis_X_half_value() {
        let r = DJIVirtualJoystickReport.decode(reportWith(x: 330))!
        XCTAssertEqual(r.axisX, 0.5, accuracy: 0.001)
    }

    func test_axis_X_clamps_above_max() {
        // 디바이스가 사양 초과 값 (예: 1000) 을 보내도 정규화는 +1.0 으로 saturate.
        let r = DJIVirtualJoystickReport.decode(reportWith(x: 1000))!
        XCTAssertEqual(r.axisX, 1.0, accuracy: 0.0001)
    }

    func test_axis_Y_independent_of_X() {
        let r = DJIVirtualJoystickReport.decode(reportWith(x: 0, y: -660))!
        XCTAssertEqual(r.axisX, 0.0, accuracy: 0.0001)
        XCTAssertEqual(r.axisY, -1.0, accuracy: 0.0001)
    }

    func test_all_five_axes_independent() {
        let r = DJIVirtualJoystickReport.decode(
            reportWith(x: 660, y: -330, z: 0, rx: 330, ry: -660))!
        XCTAssertEqual(r.axisX,   1.0,  accuracy: 0.0001)
        XCTAssertEqual(r.axisY,  -0.5,  accuracy: 0.001)
        XCTAssertEqual(r.axisZ,   0.0,  accuracy: 0.0001)
        XCTAssertEqual(r.axisRx,  0.5,  accuracy: 0.001)
        XCTAssertEqual(r.axisRy, -1.0,  accuracy: 0.0001)
    }

    // MARK: - Vendor / product constants

    func test_dji_vendor_product_ids_match_observed_hardware() {
        // ioreg 출력에서 확인한 값: VendorID=11427 (0x2CA3), ProductID=4129 (0x1021).
        XCTAssertEqual(DJIVirtualJoystickReport.vendorID, 11427)
        XCTAssertEqual(DJIVirtualJoystickReport.productID, 4129)
        XCTAssertEqual(DJIVirtualJoystickReport.reportSize, 13)
    }
}
