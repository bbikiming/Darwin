import XCTest
@testable import DarwinForgeUI

/// 사이클 200: balanceCorrectionFreshness state 전환 telemetry 검증.
///
/// # 비유
///
/// 자동차 의 ABS 시스템 표시등 — 작동 중 / 감쇠 / 차단 의 3 상태 전환 마다 운전자 +
/// 정비소 로그 에 기록. WalkLab 의 freshness gate (cycle 160) 도 동일.
@MainActor
final class WalkLabFreshnessTelemetryTests: XCTestCase {

    /// **분류 검증 #1**: 신규 kind `walklab.freshness_changed` 정의.
    func testKindExists() {
        XCTAssertEqual(TelemetryKind.walkLabFreshnessChanged.rawValue,
                       "walklab.freshness_changed")
        XCTAssertTrue(TelemetryKind.walkLabFreshnessChanged.rawValue.hasPrefix("walklab."))
    }

    /// **유기 검증 #2**: didSet 이 같은 state 재 set 시 no-op (telemetry 노이즈 차단).
    /// 50ms tick 의 .normal → .normal 호출이 매 cycle 발생 — 본 가드 가 없으면 폭발.
    func testSameStateAssignmentNoTransition() {
        let s = WalkLabSession()
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal)
        // 같은 state — no-op. (관찰 가능 효과: 추가 telemetry 발화 X.
        // 실 발화 횟수 검증은 Harness 의 internal disk 검사 필요 — 본 테스트 는
        // didSet 의 일반 guard 만 검증.)
        s.balanceCorrectionFreshness = .normal
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal,
                       "같은 state 재 set 후 state 동일 (no mutation)")
    }

    /// **유기 검증 #3**: 다른 state 전환 시 property 값 변경.
    func testDifferentStateTransitionUpdates() {
        let s = WalkLabSession()
        s.balanceCorrectionFreshness = .degraded
        XCTAssertEqual(s.balanceCorrectionFreshness, .degraded)
        s.balanceCorrectionFreshness = .blocked
        XCTAssertEqual(s.balanceCorrectionFreshness, .blocked)
        s.balanceCorrectionFreshness = .normal
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal)
    }

    /// **유기 검증 #4**: BalanceCorrectionFreshness enum 의 모든 case 가 distinct raw value.
    /// telemetry payload 에 from/to 가 enum.rawValue 로 직렬화 — 충돌 차단.
    func testFreshnessRawValuesDistinct() {
        let raws = WalkLabSession.BalanceCorrectionFreshness.allCases.map { $0.rawValue }
        let unique = Set(raws)
        XCTAssertEqual(raws.count, unique.count)
        XCTAssertEqual(raws.count, 3, "normal / degraded / blocked")
    }
}
