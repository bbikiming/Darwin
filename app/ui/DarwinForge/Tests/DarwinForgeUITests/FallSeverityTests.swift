import XCTest
@testable import DarwinForgeUI

/// **V276-4 (2026-05-24) — FallSeverity 순수 enum logic 테스트 (분리)**.
///
/// V274-6 `ViewInspectorPoCTests` 에 합쳐져 있던 6 개 test 를 분리. 본 6 test 는
/// `FallSeverity.icon(score:)` / `label(score:)` 의 4-tier 분기 + 경계값만 검증
/// — **ViewInspector 미사용** (View body 검사 없음). PoC 검증 목적상 inflation 으로
/// 판단되어 별도 file 로 이관 (V275-3 critic 5차 MINOR-3).
///
/// # 비유
///
/// FallSeverity 는 도로 표지판 색 (녹/황/적) — 운전자가 차창 너머로 본 색만 보고
/// "이 구간 위험도가 어디인가" 즉시 판단. 본 test 는 표지판 자체가 점수 → 색 매핑을
/// 올바르게 하는지 (운전자 = View 까지 갈 필요 없음) 만 검증.
///
/// # Tier 계약
///
/// | 점수 | tier | icon | 한국어 라벨 |
/// |------|------|------|-------------|
/// | 0..29 | 안정 | checkmark.circle.fill | 안정 |
/// | 30..59 | 주의 | exclamationmark.circle.fill | 주의 |
/// | 60..79 | 경고 | exclamationmark.triangle.fill | 경고 |
/// | 80..∞ | 위험 | octagon.fill | 위험 |
@MainActor
final class FallSeverityTests: XCTestCase {

    // MARK: - 4-tier 분기 — 각 tier 의 중앙값

    /// 점수 0..29 범위는 '안정' 아이콘 + 한국어 라벨을 반환해야 한다.
    func testFallSeverity_점수29_안정_아이콘과_라벨반환() {
        XCTAssertEqual(
            FallSeverity.icon(score: 29),
            "checkmark.circle.fill",
            "점수 29: 안정 아이콘"
        )
        XCTAssertEqual(
            FallSeverity.label(score: 29),
            "안정",
            "점수 29: 안정 라벨"
        )
    }

    /// 점수 30..59 범위는 '주의' 아이콘 + 한국어 라벨을 반환해야 한다.
    func testFallSeverity_점수45_주의_아이콘과_라벨반환() {
        XCTAssertEqual(FallSeverity.icon(score: 45), "exclamationmark.circle.fill")
        XCTAssertEqual(FallSeverity.label(score: 45), "주의")
    }

    /// 점수 60..79 범위는 '경고' 아이콘 + 한국어 라벨을 반환해야 한다.
    func testFallSeverity_점수70_경고_아이콘과_라벨반환() {
        XCTAssertEqual(FallSeverity.icon(score: 70), "exclamationmark.triangle.fill")
        XCTAssertEqual(FallSeverity.label(score: 70), "경고")
    }

    /// 점수 80 이상은 '위험' 아이콘 + 한국어 라벨을 반환해야 한다.
    func testFallSeverity_점수100_위험_아이콘과_라벨반환() {
        XCTAssertEqual(FallSeverity.icon(score: 100), "octagon.fill")
        XCTAssertEqual(FallSeverity.label(score: 100), "위험")
    }

    // MARK: - 경계값 — tier 전환 지점 (off-by-one 회귀 가드)

    /// 경계값 — 점수 정확히 80 은 '위험' tier 에 포함되어야 한다.
    func testFallSeverity_경계값80_위험_tier에_포함() {
        XCTAssertEqual(FallSeverity.icon(score: 80), "octagon.fill", "점수 80: 위험 tier 시작")
        XCTAssertEqual(FallSeverity.label(score: 80), "위험")
    }

    /// 경계값 — 점수 정확히 30 은 '주의' tier 에 포함되어야 한다 (안정 아님).
    func testFallSeverity_경계값30_주의_tier에_포함() {
        XCTAssertEqual(FallSeverity.icon(score: 30), "exclamationmark.circle.fill",
                       "점수 30: 주의 tier 시작 (안정 아님)")
    }
}
