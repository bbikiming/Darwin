import XCTest
import SwiftUI
@testable import DarwinForgeUI

// MARK: - HarnessShortcutsTests (V289-5, 2026-05-25)
//
// 비유: 조종사 훈련 체크리스트 — 각 조작 레버가 올바른 위치에 있는지
// 지상에서 한 번씩 당겨본다.
//
// 기술: HarnessShortcuts enum 의 4가지 단축키가 올바른 KeyEquivalent +
// EventModifiers 를 갖는지 단위 검증.
// SwiftUI View 마운트 불필요 — KeyboardShortcut 값 비교만 수행.

@MainActor
final class HarnessShortcutsTests: XCTestCase {

    // MARK: - ⌘. E-Stop

    func test_eStop_hasCommandPeriodShortcut() {
        let s = HarnessShortcuts.eStop
        XCTAssertEqual(s.key, KeyEquivalent("."),
                       "E-Stop 단축키 key 가 '.' 이어야 함")
        XCTAssertEqual(s.modifiers, EventModifiers.command,
                       "E-Stop 단축키 modifier 가 .command 이어야 함")
    }

    // MARK: - Space pause/resume

    func test_pauseResume_hasSpaceShortcut() {
        let s = HarnessShortcuts.pauseResume
        XCTAssertEqual(s.key, KeyEquivalent.space,
                       "pause/resume 단축키 key 가 .space 이어야 함")
        XCTAssertEqual(s.modifiers, EventModifiers(),
                       "pause/resume 단축키 modifier 가 없어야 함 (단순 Space)")
    }

    // MARK: - ⌘B bookmark

    func test_bookmark_hasCommandBShortcut() {
        let s = HarnessShortcuts.bookmark
        XCTAssertEqual(s.key, KeyEquivalent("b"),
                       "북마크 단축키 key 가 'b' 이어야 함")
        XCTAssertEqual(s.modifiers, EventModifiers.command,
                       "북마크 단축키 modifier 가 .command 이어야 함")
    }

    // MARK: - ⌘F search focus

    func test_focusSearch_hasCommandFShortcut() {
        let s = HarnessShortcuts.focusSearch
        XCTAssertEqual(s.key, KeyEquivalent("f"),
                       "검색 포커스 단축키 key 가 'f' 이어야 함")
        XCTAssertEqual(s.modifiers, EventModifiers.command,
                       "검색 포커스 단축키 modifier 가 .command 이어야 함")
    }

    // MARK: - 충돌 없음 검증 (4 단축키가 모두 다름)

    func test_allShortcuts_areDistinct() {
        let shortcuts: [KeyboardShortcut] = [
            HarnessShortcuts.eStop,
            HarnessShortcuts.pauseResume,
            HarnessShortcuts.bookmark,
            HarnessShortcuts.focusSearch
        ]
        // 키 + modifier 조합을 문자열로 비교
        let combos = shortcuts.map { "\($0.key.character)|\($0.modifiers)" }
        let unique = Set(combos)
        XCTAssertEqual(unique.count, shortcuts.count,
                       "4개 단축키는 모두 고유한 키+modifier 조합이어야 함")
    }
}
