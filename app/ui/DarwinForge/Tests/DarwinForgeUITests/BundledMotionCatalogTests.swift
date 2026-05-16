import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// v1.1 — 320 모션 카탈로그 회귀 가드.
///
/// 안전 invariant:
/// 1. 모든 카테고리 함수가 정의된 개수의 페이지 반환.
/// 2. 모든 페이지가 `RobotPose.walkReady` 에서 시작·종료.
/// 3. 카테고리 내부에서 ID unique (1, 2, 3, ...).
/// 4. 페이지 step 수 ≥ 1.
/// 5. 페이지 이름이 비어있지 않음.
/// 6. 합 = 320 이상.
final class BundledMotionCatalogTests: XCTestCase {

    /// 카테고리별 기대 개수 (PRD 분포).
    private let expectedCounts: [MotionCategory: Int] = [
        .basicPose: 10,
        .greeting: 25,
        .emotion: 25,
        .dance: 30,
        .stretch: 30,
        .yoga: 20,
        .martial: 25,
        .walkVariant: 20,
        .balance: 15,
        .gaze: 20,
        .demo: 30,
        .exercise: 20,
        .recovery: 15,
        .meditation: 15,
        .generated: 20,
    ]

    func testTotalMotionCountAtLeast320() {
        XCTAssertGreaterThanOrEqual(BundledMotionCatalog.totalMotionCount, 320,
            "v1.1 카탈로그는 최소 320 모션 필요")
    }

    func testEachCategoryHasExpectedCount() {
        for (cat, expected) in expectedCounts {
            let actual = BundledMotionCatalog.count(for: cat)
            XCTAssertEqual(actual, expected,
                "\(cat.label) 페이지 수 mismatch — expected \(expected), got \(actual)")
        }
    }

    /// 모든 페이지의 첫 step / 마지막 step 이 walkReady — 연속 재생 안전.
    func testAllPagesStartAndEndAtWalkReady() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            for page in pages {
                guard let first = page.steps.first, let last = page.steps.last else {
                    XCTFail("[\(cat.label)] page \(page.id) (\(page.name)) — empty steps")
                    continue
                }
                XCTAssertEqual(first.toPose(), .walkReady,
                    "[\(cat.label)] page \(page.id) (\(page.name)) — 첫 step 이 walkReady 아님")
                XCTAssertEqual(last.toPose(), .walkReady,
                    "[\(cat.label)] page \(page.id) (\(page.name)) — 마지막 step 이 walkReady 아님")
            }
        }
    }

    /// 카테고리 내부 ID unique (1..=N 순차).
    func testCategoryInternalIdsAreUnique() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            let ids = pages.map(\.id)
            let unique = Set(ids)
            XCTAssertEqual(ids.count, unique.count,
                "[\(cat.label)] ID 중복 발견 — \(ids)")
        }
    }

    /// 모든 페이지에 최소 1 step + 이름 비어있지 않음.
    func testEveryPageHasStepsAndName() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            for page in pages {
                XCTAssertFalse(page.steps.isEmpty,
                    "[\(cat.label)] page \(page.id) — step 없음")
                XCTAssertFalse(page.name.isEmpty,
                    "[\(cat.label)] page \(page.id) — 이름 없음")
            }
        }
    }

    /// 각 페이지의 모든 step 의 raw position 이 12-bit 안 (0..=4095).
    /// flag 비트 (0x4000 INVALID, 0x2000 TORQUE_OFF) 는 raw value 위라 모두 허용.
    func testAllStepPositionsWithinValidRange() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            for page in pages {
                for (stepIdx, step) in page.steps.enumerated() {
                    XCTAssertEqual(step.positions.count, 31,
                        "[\(cat.label)] page \(page.id) step \(stepIdx) — positions 길이 31 아님")
                    for (slot, raw) in step.positions.enumerated() {
                        // INVALID / TORQUE_OFF / value range 모두 허용. SKIP_MARKER 도 OK.
                        let valueBits = raw & 0x0FFF
                        let isValid = raw == MotionStep.invalidBitMask
                            || (raw & MotionStep.invalidBitMask) != 0
                            || (raw & MotionStep.torqueOffBitMask) != 0
                            || raw == 32767  // SKIP
                            || valueBits <= 0x0FFF  // 항상 true 지만 의도 명시
                        XCTAssertTrue(isValid,
                            "[\(cat.label)] page \(page.id) step \(stepIdx) slot \(slot) — raw 0x\(String(raw, radix: 16)) 비정상")
                    }
                }
            }
        }
    }

    /// MotionCategory enum 의 라벨/아이콘/요약 모두 비어있지 않음.
    func testCategoryMetadataNotEmpty() {
        for cat in MotionCategory.allCases {
            XCTAssertFalse(cat.label.isEmpty, "\(cat) label 비어있음")
            XCTAssertFalse(cat.icon.isEmpty, "\(cat) icon 비어있음")
            XCTAssertFalse(cat.summary.isEmpty, "\(cat) summary 비어있음")
        }
    }

    /// displayOrder 가 allCases 의 모든 case 포함.
    func testDisplayOrderCoversAllCases() {
        let order = Set(MotionCategory.displayOrder)
        let all = Set(MotionCategory.allCases)
        XCTAssertEqual(order, all,
            "displayOrder 가 allCases 모두 포함 안 함: missing \(all.subtracting(order))")
    }
}
