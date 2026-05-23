import XCTest
@testable import DarwinForgeUI

/// 사이클 181 (P1 #3.4 fix, cycle 177 audit): Claude / Conversation telemetry kind
/// regression guard.
///
/// # 비유
///
/// 도서관 의 카탈로그 번호 — 책 (이벤트) 마다 유일 식별자 필요. 두 책 이 같은 번호면 검색
/// 혼란 + 분석 시 잘못된 집계. 본 테스트 는 새로운 catalog 번호 들이 (1) 존재 + (2) 의미
/// 있는 prefix `claude.` + (3) 모두 distinct 인지 확인.
///
/// # 검증
///
/// 1. 신규 4 case 가 모두 정의됨 (compile-time).
/// 2. raw value 가 `claude.` prefix.
/// 3. 6 case 가 모두 distinct (cycle 181 신규 + 기존 3 합산).
final class ClaudeTelemetryKindsTests: XCTestCase {

    /// **분류 검증 #1**: 모든 cycle 181 신규 kind 가 `claude.` prefix.
    /// 분석 도구 (Inspector / SessionAnalysis) 가 namespace 기준 grouping.
    func testNewKindsHaveClaudePrefix() {
        let newKinds: [TelemetryKind] = [
            .claudePlanApproved,
            .claudePlanRejected,
            .claudePlanExecutionFailed,
            .claudePlanExecuted,
            .claudeSessionCleared
        ]
        for k in newKinds {
            XCTAssertTrue(k.rawValue.hasPrefix("claude."),
                          "kind=\(k.rawValue) 가 claude. prefix 없음")
        }
    }

    /// **분류 검증 #2**: 기존 + 신규 8 case 모두 distinct.
    /// 같은 rawValue 두 번 정의되면 분석 시 false grouping.
    func testAllClaudeKindsAreUnique() {
        let kinds: [TelemetryKind] = [
            .claudePromptSent,
            .claudeResponseReceived,
            .claudeError,
            .claudePlanApproved,
            .claudePlanRejected,
            .claudePlanExecutionFailed,
            .claudePlanExecuted,
            .claudeSessionCleared
        ]
        let raws = Set(kinds.map { $0.rawValue })
        XCTAssertEqual(raws.count, kinds.count,
                       "Claude kind raw value 중복 — count=\(kinds.count) unique=\(raws.count)")
    }

    /// **분류 검증 #3**: 신규 kind 의 raw value 가 의도된 명명.
    /// Inspector UI / SessionMarkdownReport / HarnessInsights 의 hardcoded 매칭과 일관.
    func testNewKindRawValuesMatchExpectedNames() {
        XCTAssertEqual(TelemetryKind.claudePlanApproved.rawValue, "claude.plan_approved")
        XCTAssertEqual(TelemetryKind.claudePlanRejected.rawValue, "claude.plan_rejected")
        XCTAssertEqual(TelemetryKind.claudePlanExecutionFailed.rawValue,
                       "claude.plan_execution_failed")
        XCTAssertEqual(TelemetryKind.claudePlanExecuted.rawValue, "claude.plan_executed")
        XCTAssertEqual(TelemetryKind.claudeSessionCleared.rawValue, "claude.session_cleared")
    }

    /// **유기 검증 #4**: snake_case 일관성 — period 후 단어 분리는 underscore (기존 패턴).
    func testKindsUseSnakeCaseAfterPeriod() {
        let snake = TelemetryKind.claudePlanExecutionFailed.rawValue
        XCTAssertTrue(snake.contains("_"), "신규 kind 는 snake_case: \(snake)")
        XCTAssertFalse(snake.contains("-"), "kebab-case 금지: \(snake)")
    }

    /// **유기 검증 #5**: 신규 5 case + 기존 3 case 합산 = 8 — count regression guard.
    /// cycle 181 이후 사용자 가 Claude telemetry 확장 시 본 카운트 변경 강제.
    func testTotalClaudeKindCount() {
        let allClaude: [TelemetryKind] = [
            .claudePromptSent,
            .claudeResponseReceived,
            .claudeError,
            .claudePlanApproved,
            .claudePlanRejected,
            .claudePlanExecutionFailed,
            .claudePlanExecuted,
            .claudeSessionCleared
        ]
        XCTAssertEqual(allClaude.count, 8,
                       "Claude telemetry kind 총 8 — cycle 181 신규 추가 후. " +
                       "본 카운트 변경 시 USER_PILOT_GUIDE + harness/telemetry-harness.md 동기화.")
    }
}
