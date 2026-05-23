import XCTest
@testable import ForgeCore

/// 사이클 235 — MotorSpeedProfile 연산 정확성 regression guard.
final class MotorSpeedProfileTests: XCTestCase {

    // MARK: - Duration

    /// 각 프로파일의 durationSeconds 고정 값 확인.
    func testDurationSecondsValues() {
        XCTAssertEqual(MotorSpeedProfile.instant.durationSeconds, 0)
        XCTAssertEqual(MotorSpeedProfile.fast.durationSeconds, 0.5)
        XCTAssertEqual(MotorSpeedProfile.smooth.durationSeconds, 1.0)
        XCTAssertEqual(MotorSpeedProfile.slow.durationSeconds, 2.5)
        XCTAssertEqual(MotorSpeedProfile.verySlow.durationSeconds, 5.0)
    }

    /// durationSeconds 는 instant→verySlow 단조 증가.
    func testDurationMonotonicallyIncreasing() {
        let profiles = MotorSpeedProfile.allCases
        for i in 1..<profiles.count {
            XCTAssertGreaterThan(
                profiles[i].durationSeconds,
                profiles[i - 1].durationSeconds,
                "\(profiles[i]) 는 \(profiles[i - 1]) 보다 느려야 함"
            )
        }
    }

    // MARK: - Step Count

    /// instant 는 최소 1 step (보간 없이 1번에).
    func testInstantStepCountIsOne() {
        XCTAssertEqual(MotorSpeedProfile.instant.stepCount, 1,
                       "instant 는 duration=0 이지만 stepCount ≥ 1 (max(1, ...) 보장)")
    }

    /// smooth (1초) → 1.0 / 0.05 = 20 steps.
    func testSmoothStepCountIs20() {
        XCTAssertEqual(MotorSpeedProfile.smooth.stepCount, 20)
    }

    /// fast (0.5초) → 0.5 / 0.05 = 10 steps.
    func testFastStepCountIs10() {
        XCTAssertEqual(MotorSpeedProfile.fast.stepCount, 10)
    }

    /// slow (2.5초) → 2.5 / 0.05 = 50 steps.
    func testSlowStepCountIs50() {
        XCTAssertEqual(MotorSpeedProfile.slow.stepCount, 50)
    }

    /// verySlow (5.0초) → 5.0 / 0.05 = 100 steps.
    func testVerySlowStepCountIs100() {
        XCTAssertEqual(MotorSpeedProfile.verySlow.stepCount, 100)
    }

    /// stepCount 는 항상 ≥ 1.
    func testStepCountAlwaysPositive() {
        for profile in MotorSpeedProfile.allCases {
            XCTAssertGreaterThanOrEqual(profile.stepCount, 1,
                                        "\(profile) stepCount 는 최소 1 이어야 함")
        }
    }

    // MARK: - Raw Speed Value (Dynamixel MX-28T)

    /// instant = 0 (무제한), 나머지 > 0.
    func testRawSpeedValues() {
        XCTAssertEqual(MotorSpeedProfile.instant.rawSpeedValue, 0)
        XCTAssertEqual(MotorSpeedProfile.fast.rawSpeedValue, 600)
        XCTAssertEqual(MotorSpeedProfile.smooth.rawSpeedValue, 300)
        XCTAssertEqual(MotorSpeedProfile.slow.rawSpeedValue, 120)
        XCTAssertEqual(MotorSpeedProfile.verySlow.rawSpeedValue, 60)
    }

    /// rawSpeedValue 는 instant 제외 시 fast→verySlow 단조 감소 (느릴수록 작은 값).
    func testRawSpeedMonotonicallyDecreasingExceptInstant() {
        let ordered: [MotorSpeedProfile] = [.fast, .smooth, .slow, .verySlow]
        for i in 1..<ordered.count {
            XCTAssertLessThan(
                ordered[i].rawSpeedValue,
                ordered[i - 1].rawSpeedValue,
                "\(ordered[i]) rawSpeedValue 는 \(ordered[i - 1]) 보다 작아야 함"
            )
        }
    }

    /// rawSpeedValue 범위 확인 (0-1023, Dynamixel MX-28T 사양).
    func testRawSpeedWithinDynamixelRange() {
        for profile in MotorSpeedProfile.allCases {
            XCTAssertLessThanOrEqual(profile.rawSpeedValue, 1023,
                                     "\(profile) rawSpeedValue 는 Dynamixel 최대 1023 이내여야 함")
        }
    }

    // MARK: - Label / Icon Completeness

    /// 모든 프로파일에 비어있지 않은 koreanLabel 존재.
    func testKoreanLabelNotEmpty() {
        for profile in MotorSpeedProfile.allCases {
            XCTAssertFalse(profile.koreanLabel.isEmpty,
                           "\(profile) koreanLabel 이 비어 있으면 안 됨")
        }
    }

    /// 모든 프로파일에 비어있지 않은 icon 존재.
    func testIconNotEmpty() {
        for profile in MotorSpeedProfile.allCases {
            XCTAssertFalse(profile.icon.isEmpty,
                           "\(profile) icon 이 비어 있으면 안 됨")
        }
    }

    /// 모든 프로파일에 비어있지 않은 subtitle 존재.
    func testSubtitleNotEmpty() {
        for profile in MotorSpeedProfile.allCases {
            XCTAssertFalse(profile.subtitle.isEmpty,
                           "\(profile) subtitle 이 비어 있으면 안 됨")
        }
    }

    // MARK: - Identifiable / Codable

    /// id 는 rawValue 와 동일.
    func testIdEqualsRawValue() {
        for profile in MotorSpeedProfile.allCases {
            XCTAssertEqual(profile.id, profile.rawValue)
        }
    }

    /// JSON round-trip 검증.
    func testCodableRoundTrip() throws {
        let original = MotorSpeedProfile.smooth
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MotorSpeedProfile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Step Interval

    /// stepIntervalSeconds 는 50ms (20Hz).
    func testStepIntervalIs50ms() {
        XCTAssertEqual(MotorSpeedProfile.stepIntervalSeconds, 0.05,
                       "step interval 은 50ms (20Hz 갱신) 이어야 함")
    }
}
