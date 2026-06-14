import XCTest
import SwiftUI
@testable import DarwinForgeUI

/// 퀵 액션 확인 다이얼로그 표시 계약 (실기 UI 결함 fix, 2026-06-12).
///
/// 근거: 종전 `.alert(message: Text(action.command))` 가 수백 줄 스크립트를 본문에
/// 노출 → 다이얼로그가 화면을 넘어 실행/취소 버튼 클릭 불가(실기 브링업에서 앱 채널
/// 배포 불능). 회귀 가드: 본문엔 어떤 명령 길이에서도 전문이 들어가지 않는다.
final class QuickActionConfirmTests: XCTestCase {

    private func makeAction(command: String,
                            category: QuickActionCategory = .robotis,
                            summary: String? = nil) -> QuickAction {
        QuickAction(id: "t", category: category, label: "테스트 액션",
                    detail: "디테일", icon: "hammer.fill",
                    command: command, requiresConfirm: true,
                    confirmSummary: summary)
    }

    // MARK: - 본문에 스크립트 전문 비포함 (핵심 회귀 가드)

    func testDialogBodyExcludes500LineCommand() {
        let longCommand = (1...500).map { "echo line-\($0) && do_something_\($0)" }
            .joined(separator: "\n")
        let model = QuickActionConfirmModel(action: makeAction(command: longCommand))
        XCTAssertFalse(model.dialogBodyText.contains("echo line-1"),
                       "다이얼로그 본문에 명령 전문이 포함되면 버튼 잘림이 재발한다")
        XCTAssertFalse(model.dialogBodyText.contains(longCommand))
        // 본문은 요약 수준으로 짧아야 한다 — 화면을 넘길 수 없는 길이.
        XCTAssertLessThan(model.dialogBodyText.count, 300)
    }

    func testDialogBodyExcludesLongScriptCommand() {
        // 긴 스크립트 액션 — 메뉴 정리(13→9) 후 demo-patch-build 제거됨.
        // 현재 카탈로그에서 가장 긴 command(walkLabRobotisStart, 수백 줄)를 쓰는
        // gamepad-pilot-start 로 동일 의도(긴 명령이 다이얼로그 본문에 안 들어감) 검증.
        guard let action = QuickActionCatalog.all.first(where: { $0.id == "gamepad-pilot-start" })
        else { return XCTFail("gamepad-pilot-start 액션이 카탈로그에 없음") }
        let model = QuickActionConfirmModel(action: action)
        XCTAssertGreaterThan(action.command.count, 1000, "전제: 수백 줄 스크립트")
        XCTAssertFalse(model.dialogBodyText.contains(action.command))
        XCTAssertLessThan(model.dialogBodyText.count, 300)
    }

    // MARK: - destructive 의미는 danger 카테고리만

    func testDestructiveOnlyForDangerCategory() {
        for category in QuickActionCategory.allCases {
            let model = QuickActionConfirmModel(
                action: makeAction(command: "x", category: category))
            XCTAssertEqual(model.isDestructive, category == .danger,
                           "\(category) destructive 불일치")
        }
    }

    // MARK: - 요약 문구

    func testExplicitSummaryWins() {
        let model = QuickActionConfirmModel(
            action: makeAction(command: "x", summary: "로봇에서 demo 를 재빌드합니다"))
        XCTAssertEqual(model.summaryText, "로봇에서 demo 를 재빌드합니다")
    }

    func testCategoryFallbackSummaryNonEmpty() {
        for category in QuickActionCategory.allCases {
            let model = QuickActionConfirmModel(
                action: makeAction(command: "x", category: category))
            XCTAssertFalse(model.summaryText.isEmpty)
            XCTAssertFalse(model.summaryText.contains("\n"), "요약은 한 줄")
        }
    }

    /// 카탈로그의 모든 confirm 액션은 명시 요약을 갖는다 (새 confirm 액션 추가 시 가드).
    func testAllCatalogConfirmActionsHaveExplicitSummary() {
        for action in QuickActionCatalog.all where action.requiresConfirm {
            XCTAssertNotNil(action.confirmSummary,
                            "\(action.id): requiresConfirm 액션은 confirmSummary 지정")
            XCTAssertFalse(action.confirmSummary?.isEmpty ?? true)
        }
    }

    // MARK: - 시트 렌더 (긴 명령에서도 본문 구성 가능)

    @MainActor
    func testSheetRendersWith500LineCommand() {
        let longCommand = (1...500).map { "echo line-\($0)" }.joined(separator: "\n")
        let sheet = QuickActionConfirmSheet(
            model: QuickActionConfirmModel(action: makeAction(command: longCommand)),
            onRun: {}, onCancel: {})
        // ImageRenderer 로 고정 폭 렌더가 성립하는지(레이아웃 폭주 없음) 확인.
        let renderer = ImageRenderer(content: sheet)
        renderer.proposedSize = .init(width: 460, height: nil)
        XCTAssertNotNil(renderer.nsImage, "긴 명령에서 시트 렌더 실패")
        if let img = renderer.nsImage {
            // 명령 전문이 접혀 있으므로 시트 높이는 화면 상한(900pt) 안 — 버튼 잘림 불가.
            XCTAssertLessThan(img.size.height, 900,
                              "시트가 화면 세로를 넘으면 버튼 잘림 재발")
        }
    }
}
