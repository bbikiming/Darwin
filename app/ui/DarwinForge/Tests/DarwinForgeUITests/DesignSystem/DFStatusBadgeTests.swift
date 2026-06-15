import XCTest
@testable import DarwinForgeUI

/// 사이클 152 — DFStatusBadge enum 단위 테스트.
final class DFStatusBadgeTests: XCTestCase {

    /// 모든 case 가 non-empty 한국어 라벨 반환.
    func testAllCasesHaveKoreanLabel() {
        for badge in DFStatusBadge.allCases {
            XCTAssertFalse(badge.koreanLabel.isEmpty,
                           "\(badge) 의 koreanLabel 이 비어 있음")
        }
    }

    /// 모든 case 가 non-empty SF Symbol 반환.
    func testAllCasesHaveIcon() {
        for badge in DFStatusBadge.allCases {
            XCTAssertFalse(badge.icon.isEmpty,
                           "\(badge) 의 icon 이 비어 있음")
        }
    }

    /// 모든 case 가 accessibilityLabel 에 "상태:" prefix 포함.
    func testAccessibilityLabelHasStatusPrefix() {
        for badge in DFStatusBadge.allCases {
            XCTAssertTrue(badge.accessibilityLabel.hasPrefix("상태:"),
                          "\(badge) 의 accessibilityLabel 이 '상태:' prefix 없음")
        }
    }

    /// 안전 분류 검증 — appliedToRobot 만 true, 나머지 false.
    func testSafeForRealRobotOnlyAppliedTrue() {
        XCTAssertTrue(DFStatusBadge.appliedToRobot.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.simulationOnly.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.estimatedProgress.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.previewOnly.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.unverified.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.sdkUnavailable.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.placeholder.safeForRealRobot)
        XCTAssertFalse(DFStatusBadge.futureIntegration.safeForRealRobot)
    }

    /// 8 case 모두 정의되어 있는지.
    func testEightCases() {
        XCTAssertEqual(DFStatusBadge.allCases.count, 8,
                       "DFStatusBadge 는 8 case (cycle 152 권고)")
    }

    /// rawValue 가 case 이름과 일치 — 디버깅 / persistence 일관성.
    func testRawValueMatchesCaseName() {
        XCTAssertEqual(DFStatusBadge.appliedToRobot.rawValue, "appliedToRobot")
        XCTAssertEqual(DFStatusBadge.placeholder.rawValue, "placeholder")
    }

    /// Hashable + Equatable — Set 에 추가 가능.
    func testHashableEquatable() {
        let s: Set<DFStatusBadge> = [.appliedToRobot, .simulationOnly, .appliedToRobot]
        XCTAssertEqual(s.count, 2)
    }
}
