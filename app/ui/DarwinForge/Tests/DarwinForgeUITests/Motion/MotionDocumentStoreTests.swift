import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// 사이클 250 (Wave 4.3.2) — `MotionDocumentStore` 회귀 가드.
///
/// MotionStudioView 에서 추출한 12개 @State 의 초기값 / 기본 동작 보존을 보장.
/// view 동작 변화 없어야 함 — 초기 상태는 이전 @State default 와 동일해야 함.
@MainActor
final class MotionDocumentStoreTests: XCTestCase {

    func testInitWithDefaultMotion() {
        let store = MotionDocumentStore()
        XCTAssertGreaterThan(store.motion.pages.count, 0,
                             "default motion 은 StarterMotionLibrary.starterDoc")
    }

    func testInitWithCustomMotion() {
        let custom = MotionDoc(version: 1, robotGeneration: "op2", pages: [])
        let store = MotionDocumentStore(initialMotion: custom)
        XCTAssertEqual(store.motion.pages.count, 0)
    }

    func testInitialState() {
        let store = MotionDocumentStore()
        XCTAssertEqual(store.selectedPageIdx, 0)
        XCTAssertEqual(store.selectedStep, 0)
        XCTAssertFalse(store.isDirty)
        XCTAssertTrue(store.undoStack.isEmpty)
        XCTAssertTrue(store.redoStack.isEmpty)
        XCTAssertNil(store.copiedStep)
        XCTAssertNil(store.renamingPageIdx)
        XCTAssertNil(store.deletingPageIdx)
        XCTAssertNil(store.hoveredPageIdx)
        XCTAssertFalse(store.executingOnRobot)
        XCTAssertEqual(store.renameDraft, "")
    }

    func testMaxUndoDepthIs50() {
        let store = MotionDocumentStore()
        XCTAssertEqual(store.maxUndoDepth, 50)
    }
}
