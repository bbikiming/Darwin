import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 사이클 236 — MotionStudioCategory.categorize 분류 정확성 regression guard.
///
/// ID range 우선 매핑, name keyword fallback, 기본값 `.custom` 세 단계의
/// 분류 로직이 의도대로 동작하는지 검증. 마치 우체국 자동 분류기처럼 —
/// 우편번호(ID) 가 명확하면 즉시 분류하고, 아니면 내용(name) 을 읽어 분류한다.
final class MotionStudioCategoryTests: XCTestCase {

    // MARK: - Helper

    /// 테스트 전용 MotionPage 팩토리. id / name 외 필드는 분류에 무관.
    private func page(id: UInt8, name: String = "") -> MotionPage {
        MotionPage(id: id, name: name)
    }

    // MARK: - ID Range — Official (1...54)

    /// 공식 카탈로그 하한 (id=1) → `.official`
    func testIDRange_official_lower() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 1)),
            .official,
            "id=1 은 공식 카탈로그 범위 하한"
        )
    }

    /// 공식 카탈로그 중간 (id=30) → `.official`
    func testIDRange_official_mid() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 30)),
            .official,
            "id=30 은 공식 카탈로그 범위 중간"
        )
    }

    /// 공식 카탈로그 상한 (id=54) → `.official`
    func testIDRange_official_upper() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 54)),
            .official,
            "id=54 는 공식 카탈로그 범위 상한"
        )
    }

    // MARK: - ID Range — Walking (110...119)

    /// 보행 테스트 하한 (id=110) → `.walking`
    func testIDRange_walking_lower() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 110)),
            .walking,
            "id=110 은 walking 범위 하한"
        )
    }

    /// 보행 테스트 상한 (id=119) → `.walking`
    func testIDRange_walking_upper() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 119)),
            .walking,
            "id=119 는 walking 범위 상한"
        )
    }

    // MARK: - ID Range — Daily (120...129)

    /// 일상 하한 (id=120) → `.daily`
    func testIDRange_daily_lower() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 120)),
            .daily,
            "id=120 은 daily 범위 하한"
        )
    }

    /// 일상 상한 (id=129) → `.daily`
    func testIDRange_daily_upper() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 129)),
            .daily,
            "id=129 는 daily 범위 상한"
        )
    }

    // MARK: - ID Range — Greeting (130...149)

    /// 인사 130 대 하한 (id=130) → `.greeting`
    func testIDRange_greeting130_lower() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 130)),
            .greeting,
            "id=130 은 greeting 범위 (130...139) 하한"
        )
    }

    /// 인사 130 대 상한 (id=139) → `.greeting`
    func testIDRange_greeting130_upper() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 139)),
            .greeting,
            "id=139 는 greeting 범위 (130...139) 상한"
        )
    }

    /// 인사 140 대 하한 (id=140) → `.greeting`
    func testIDRange_greeting140_lower() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 140)),
            .greeting,
            "id=140 은 greeting 범위 (140...149) 하한"
        )
    }

    /// 인사 140 대 상한 (id=149) → `.greeting`
    func testIDRange_greeting140_upper() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 149)),
            .greeting,
            "id=149 는 greeting 범위 (140...149) 상한"
        )
    }

    // MARK: - ID Range — Basic (200...204)

    /// 기본 동작 하한 (id=200) → `.basic`
    func testIDRange_basic_lower() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 200)),
            .basic,
            "id=200 은 basic 범위 하한"
        )
    }

    /// 기본 동작 상한 (id=204) → `.basic`
    func testIDRange_basic_upper() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 204)),
            .basic,
            "id=204 는 basic 범위 상한"
        )
    }

    // MARK: - ID Boundary Edge Cases

    /// id=0 — 공식 범위 아래. keyword 없으면 `.custom` fallback.
    func testBoundary_belowOfficial() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 0)),
            .custom,
            "id=0 은 모든 ID 범위 밖 — keyword 없으면 .custom"
        )
    }

    /// id=55 — 공식 범위 직후, walking 전. keyword 없으면 `.custom`.
    func testBoundary_aboveOfficial() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 55)),
            .custom,
            "id=55 는 공식(54) 직후 — keyword 없으면 .custom"
        )
    }

    /// id=109 — walking(110) 직전. keyword 없으면 `.custom`.
    func testBoundary_belowWalking() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 109)),
            .custom,
            "id=109 는 walking(110) 직전 — keyword 없으면 .custom"
        )
    }

    /// id=150 — greeting(149) 직후, basic(200) 전. keyword 없으면 `.custom`.
    func testBoundary_aboveGreeting() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 150)),
            .custom,
            "id=150 은 greeting(149) 직후 — keyword 없으면 .custom"
        )
    }

    /// id=205 — basic(204) 직후. keyword 없으면 `.custom`.
    func testBoundary_aboveBasic() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 205)),
            .custom,
            "id=205 는 basic(204) 직후 — keyword 없으면 .custom"
        )
    }

    // MARK: - Keyword Classification (ID 220+ — range miss)

    /// 격투 keyword: "복싱 연습" → `.combat`
    func testKeyword_combat() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 220, name: "복싱 연습")),
            .combat,
            "name 에 '복싱' 포함 → .combat"
        )
    }

    /// 인사 keyword: "정중한 인사" → `.greeting`
    func testKeyword_greeting() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 221, name: "정중한 인사")),
            .greeting,
            "name 에 '인사' 포함 → .greeting"
        )
    }

    /// 감정 keyword: "좌절 표현" → `.expression`
    func testKeyword_expression() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 222, name: "좌절 표현")),
            .expression,
            "name 에 '좌절' 포함 → .expression"
        )
    }

    /// 댄스 keyword: "힙합 댄스" → `.dance`
    func testKeyword_dance() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 223, name: "힙합 댄스")),
            .dance,
            "name 에 '힙합' 포함 → .dance"
        )
    }

    /// 요가 keyword: "나무 자세" → `.yoga`
    func testKeyword_yoga() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 224, name: "나무 자세")),
            .yoga,
            "name 에 '나무 자세' 포함 → .yoga"
        )
    }

    /// 스포츠 keyword: "축구 킥" → `.sport`
    func testKeyword_sport() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 225, name: "축구 킥")),
            .sport,
            "name 에 '축구' 포함 → .sport"
        )
    }

    /// 일상 keyword: "스쿼트 운동" → `.daily`
    func testKeyword_daily() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 226, name: "스쿼트 운동")),
            .daily,
            "name 에 '스쿼트' 포함 → .daily"
        )
    }

    // MARK: - ID Range Precedence over Keyword

    /// id=5 + name="힙합 댄스" → `.official` (ID range 가 keyword 보다 우선).
    /// 마치 우편번호가 맞으면 내용물을 열어볼 필요 없는 것과 같다.
    func testIDRangeTakesPrecedenceOverKeyword() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 5, name: "힙합 댄스")),
            .official,
            "ID range(1...54) 매칭이 keyword '힙합' 보다 우선"
        )
    }

    // MARK: - Default Fallback

    /// 어떤 ID range / keyword 에도 매칭되지 않으면 `.custom`.
    func testFallback_custom() {
        XCTAssertEqual(
            MotionStudioCategory.categorize(page(id: 220, name: "알 수 없는 동작")),
            .custom,
            "매칭되는 ID range / keyword 없으면 .custom fallback"
        )
    }

    // MARK: - Label / Icon / SortOrder Completeness

    /// 모든 case 의 label 이 비어있지 않아야 함.
    func testAllCases_labelNotEmpty() {
        for category in MotionStudioCategory.allCases {
            XCTAssertFalse(
                category.label.isEmpty,
                "\(category.rawValue) 의 label 이 비어있음"
            )
        }
    }

    /// 모든 case 의 icon (SF Symbol) 이 비어있지 않아야 함.
    func testAllCases_iconNotEmpty() {
        for category in MotionStudioCategory.allCases {
            XCTAssertFalse(
                category.icon.isEmpty,
                "\(category.rawValue) 의 icon 이 비어있음"
            )
        }
    }

    /// sortOrder 가 0...10 범위에서 겹침 없이 모든 case 를 커버해야 함.
    func testAllCases_sortOrderUnique() {
        let orders = MotionStudioCategory.allCases.map(\.sortOrder)
        let uniqueOrders = Set(orders)

        XCTAssertEqual(
            orders.count, uniqueOrders.count,
            "sortOrder 에 중복이 있음: \(orders)"
        )
        XCTAssertEqual(
            uniqueOrders, Set(0...10),
            "sortOrder 가 0...10 을 빠짐없이 커버해야 함"
        )
    }

    // MARK: - CaseIterable Count

    /// MotionStudioCategory 는 정확히 11 개 case 로 구성.
    func testCaseIterable_count() {
        XCTAssertEqual(
            MotionStudioCategory.allCases.count, 11,
            "MotionStudioCategory 는 11 case 여야 함"
        )
    }
}
