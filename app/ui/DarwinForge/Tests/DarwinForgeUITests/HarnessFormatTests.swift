import XCTest
@testable import DarwinForgeUI

// MARK: - HarnessFormatTests (V289-4, 2026-05-25)
//
// NIST SP 811 + ISO 80000-1 + Nielsen #9 표기 규칙 검증.
// 각 규칙별 최소 5개 케이스 (양수 / 음수 / 0 / 경계 / 임계).

final class HarnessFormatTests: XCTestCase {

    // MARK: - formatGyro (ISO 80000-1 §7.3.1 부호 항상 표시, 소수 1자리, 공백)

    func test_formatGyro_positive() {
        XCTAssertEqual(HarnessFormat.formatGyro(12.3), "+12.3 °/s")
    }

    func test_formatGyro_negative() {
        XCTAssertEqual(HarnessFormat.formatGyro(-12.3), "−12.3 °/s")
    }

    func test_formatGyro_zero() {
        XCTAssertEqual(HarnessFormat.formatGyro(0.0), "+0.0 °/s")
    }

    func test_formatGyro_largePositive() {
        XCTAssertEqual(HarnessFormat.formatGyro(123.45), "+123.5 °/s")
    }

    func test_formatGyro_smallNegative() {
        XCTAssertEqual(HarnessFormat.formatGyro(-0.05), "−0.1 °/s")
    }

    // MARK: - formatAngle (소수 1자리, ° 붙임)

    func test_formatAngle_positive() {
        XCTAssertEqual(HarnessFormat.formatAngle(12.7), "+12.7°")
    }

    func test_formatAngle_negative() {
        XCTAssertEqual(HarnessFormat.formatAngle(-12.7), "−12.7°")
    }

    func test_formatAngle_zero() {
        XCTAssertEqual(HarnessFormat.formatAngle(0.0), "+0.0°")
    }

    func test_formatAngle_largeNegative() {
        XCTAssertEqual(HarnessFormat.formatAngle(-180.0), "−180.0°")
    }

    func test_formatAngle_rounding() {
        // %.1f bankers rounding: 3.25 → "3.2" (round half to even)
        XCTAssertEqual(HarnessFormat.formatAngle(3.25), "+3.2°")
    }

    // MARK: - formatVoltage (소수 2자리, 공백)

    func test_formatVoltage_normal() {
        XCTAssertEqual(HarnessFormat.formatVoltage(11.85), "11.85 V")
    }

    func test_formatVoltage_critical() {
        XCTAssertEqual(HarnessFormat.formatVoltage(11.10), "11.10 V")
    }

    func test_formatVoltage_full() {
        XCTAssertEqual(HarnessFormat.formatVoltage(12.60), "12.60 V")
    }

    func test_formatVoltage_zero() {
        XCTAssertEqual(HarnessFormat.formatVoltage(0.0), "0.00 V")
    }

    func test_formatVoltage_rounding() {
        XCTAssertEqual(HarnessFormat.formatVoltage(11.855), "11.86 V")
    }

    // MARK: - formatTemp (소수 1자리, 공백)

    func test_formatTemp_normal() {
        XCTAssertEqual(HarnessFormat.formatTemp(42.3), "42.3 °C")
    }

    func test_formatTemp_warn() {
        XCTAssertEqual(HarnessFormat.formatTemp(75.0), "75.0 °C")
    }

    func test_formatTemp_crit() {
        XCTAssertEqual(HarnessFormat.formatTemp(90.0), "90.0 °C")
    }

    func test_formatTemp_zero() {
        XCTAssertEqual(HarnessFormat.formatTemp(0.0), "0.0 °C")
    }

    func test_formatTemp_rounding() {
        XCTAssertEqual(HarnessFormat.formatTemp(36.85), "36.9 °C")
    }

    // MARK: - formatLatency (소수 1자리, 공백)

    func test_formatLatency_normal() {
        XCTAssertEqual(HarnessFormat.formatLatency(8.2), "8.2 ms")
    }

    func test_formatLatency_warn() {
        XCTAssertEqual(HarnessFormat.formatLatency(10.0), "10.0 ms")
    }

    func test_formatLatency_crit() {
        XCTAssertEqual(HarnessFormat.formatLatency(20.5), "20.5 ms")
    }

    func test_formatLatency_zero() {
        XCTAssertEqual(HarnessFormat.formatLatency(0.0), "0.0 ms")
    }

    func test_formatLatency_sub1() {
        // %.1f bankers rounding: 0.35 → "0.3" (round half to even)
        XCTAssertEqual(HarnessFormat.formatLatency(0.35), "0.3 ms")
    }

    // MARK: - formatPacketLoss (소수 1자리, 공백)

    func test_formatPacketLoss_normal() {
        XCTAssertEqual(HarnessFormat.formatPacketLoss(0.3), "0.3 %")
    }

    func test_formatPacketLoss_warn() {
        XCTAssertEqual(HarnessFormat.formatPacketLoss(1.5), "1.5 %")
    }

    func test_formatPacketLoss_crit() {
        XCTAssertEqual(HarnessFormat.formatPacketLoss(5.0), "5.0 %")
    }

    func test_formatPacketLoss_zero() {
        XCTAssertEqual(HarnessFormat.formatPacketLoss(0.0), "0.0 %")
    }

    func test_formatPacketLoss_rounding() {
        XCTAssertEqual(HarnessFormat.formatPacketLoss(3.85), "3.9 %")
    }

    // MARK: - staleLabel / freshLabel

    func test_staleLabel() {
        XCTAssertEqual(HarnessFormat.staleLabel(secondsAgo: 2.3), "갱신 지연 2.3초 전")
    }

    func test_freshLabel_recent() {
        XCTAssertEqual(HarnessFormat.freshLabel(secondsAgo: 0.4), "방금 갱신")
    }

    func test_freshLabel_seconds() {
        XCTAssertEqual(HarnessFormat.freshLabel(secondsAgo: 3.1), "갱신 3.1초 전")
    }

    // MARK: - EmptyState messages (Nielsen #9)

    func test_noEvents_withFilter() {
        let msg = HarnessFormat.EmptyState.noEvents(filter: "walklab")
        XCTAssertTrue(msg.contains("walklab"), "필터 검색어가 메시지에 포함되어야 함")
        XCTAssertTrue(msg.contains("이벤트 없음"))
    }

    func test_noEvents_emptyFilter() {
        let msg = HarnessFormat.EmptyState.noEvents(filter: "")
        XCTAssertTrue(msg.contains("이벤트 없음"))
        XCTAssertFalse(msg.contains("[]"), "빈 필터는 검색어를 표시하지 않아야 함")
    }

    // MARK: - ErrorMessage templates

    func test_batteryBelowThreshold() {
        let msg = HarnessFormat.ErrorMessage.batteryBelowThreshold(voltage: 11.2, threshold: 11.5)
        XCTAssertTrue(msg.contains("11.20 V"))
        XCTAssertTrue(msg.contains("11.5 V"))
        XCTAssertTrue(msg.contains("충전"))
    }

    func test_dxlBusTimeout() {
        let msg = HarnessFormat.ErrorMessage.dxlBusTimeout(secondsAgo: 4.7)
        XCTAssertTrue(msg.contains("4.7초 전"))
        XCTAssertTrue(msg.contains("DXL"))
    }

    func test_gyroNotCalibrated() {
        XCTAssertTrue(HarnessFormat.ErrorMessage.gyroNotCalibrated.contains("자이로"))
        XCTAssertTrue(HarnessFormat.ErrorMessage.gyroNotCalibrated.contains("보정"))
    }
}
