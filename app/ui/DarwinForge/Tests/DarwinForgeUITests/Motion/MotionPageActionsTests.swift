import Foundation
import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// 사이클 256 (Wave 4.3.3) — `MotionPageActions` 회귀 가드.
///
/// MotionStudioView 에서 추출한 14개 page/step mutation 함수의 동작 보존을 보장.
/// 추출 전후 동일 input → 동일 doc state 변경이어야 함.
///
/// 5개 시나리오 + 추가 엣지 케이스:
/// 1. addPage — count 증가, id 자동 할당, selection 갱신
/// 2. deletePage — 경계 조건 (1개 미만 거부, 잘못된 idx 거부)
/// 3. copy/paste step 사이클 — 클립보드 → 새 step 삽입
/// 4. undo/redo 사이클 — stack push/pop + selection 보정
/// 5. renamePage — id 보존, 동일 이름 거부, 트림된 빈 이름 거부
@MainActor
final class MotionPageActionsTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeDoc() -> MotionDocumentStore {
        // Starter library 의 동작 (>= 1 페이지) 사용.
        return MotionDocumentStore()
    }

    private func makeEmptyDoc() -> MotionDocumentStore {
        let custom = MotionDoc(
            version: 1,
            robotGeneration: "op2",
            pages: [
                MotionPage(
                    id: 1,
                    name: "테스트 페이지",
                    steps: [.from(pose: .walkReady, playMs: 256, pauseMs: 0)]
                )
            ]
        )
        return MotionDocumentStore(initialMotion: custom)
    }

    // MARK: - 1. addPage

    func testAddPageIncreasesCount() {
        let doc = makeDoc()
        let beforeCount = doc.motion.pages.count

        let newId = MotionPageActions.addPage(in: doc)

        XCTAssertEqual(doc.motion.pages.count, beforeCount + 1,
                       "addPage 는 페이지 count 를 정확히 1 증가시켜야 함")
        XCTAssertGreaterThan(newId, 0, "새 페이지 id 는 양수 (max+1)")
        XCTAssertEqual(doc.selectedPageIdx, doc.motion.pages.count - 1,
                       "selectedPageIdx 가 새 페이지를 가리켜야 함")
        XCTAssertEqual(doc.selectedStep, 0, "새 페이지 선택 시 selectedStep 은 0 리셋")
        XCTAssertTrue(doc.isDirty, "addPage 후 dirty flag set")
        XCTAssertEqual(doc.undoStack.count, 1, "undo snapshot 1개 push")
    }

    func testAddPageAutoAssignsUniqueId() {
        let doc = makeEmptyDoc()
        let maxBefore = doc.motion.pages.map { Int($0.id) }.max() ?? 0

        let newId = MotionPageActions.addPage(in: doc)

        XCTAssertEqual(Int(newId), maxBefore + 1,
                       "신규 id 는 기존 max + 1 (id 충돌 방지)")
    }

    // MARK: - 2. deletePage 경계 조건

    func testDeletePageBoundaryRejectsLastPage() {
        let doc = makeEmptyDoc()
        XCTAssertEqual(doc.motion.pages.count, 1, "preconditions: 1 페이지")

        let removed = MotionPageActions.deletePage(at: 0, in: doc)

        XCTAssertNil(removed, "1개 미만으로 줄지 않도록 거부 — nil 반환")
        XCTAssertEqual(doc.motion.pages.count, 1, "삭제 안 일어남")
        XCTAssertFalse(doc.isDirty, "거부 시 dirty 변경 없음")
        XCTAssertTrue(doc.undoStack.isEmpty, "거부 시 undo snapshot push 안 함")
    }

    func testDeletePageRejectsOutOfRangeIdx() {
        let doc = makeDoc()
        let countBefore = doc.motion.pages.count

        // 음수 idx
        XCTAssertNil(MotionPageActions.deletePage(at: -1, in: doc),
                     "음수 idx 거부")
        // 범위 초과 idx
        XCTAssertNil(MotionPageActions.deletePage(at: countBefore, in: doc),
                     "범위 초과 idx 거부")

        XCTAssertEqual(doc.motion.pages.count, countBefore,
                       "잘못된 idx 모두 거부 — count 불변")
    }

    func testDeletePageRemovesValidIdx() {
        let doc = makeDoc()
        // 2개 보장 (starter library 에 충분히 있음)
        guard doc.motion.pages.count >= 2 else {
            XCTFail("starter doc 에 최소 2 페이지 필요")
            return
        }
        let targetIdx = 0
        let targetName = doc.motion.pages[targetIdx].name
        let targetId = doc.motion.pages[targetIdx].id
        let countBefore = doc.motion.pages.count

        let removed = MotionPageActions.deletePage(at: targetIdx, in: doc)

        XCTAssertNotNil(removed, "유효 idx 삭제 성공 — MotionPage 반환")
        XCTAssertEqual(removed?.id, targetId, "반환된 페이지 id 일치")
        XCTAssertEqual(removed?.name, targetName, "반환된 페이지 name 일치")
        XCTAssertEqual(doc.motion.pages.count, countBefore - 1, "count 1 감소")
        XCTAssertTrue(doc.isDirty, "dirty flag set")
        XCTAssertEqual(doc.selectedStep, 0, "selectedStep 리셋")
    }

    // MARK: - 3. copy/paste step 사이클

    func testCopyPasteStepCycle() {
        let doc = makeEmptyDoc()
        // 첫 페이지의 0번 step 을 copy → paste → 같은 페이지에 2개 step.
        let originalStep = doc.motion.pages[0].steps[0]
        let stepsCountBefore = doc.motion.pages[0].steps.count

        // Copy
        MotionPageActions.copySelectedStep(in: doc)
        XCTAssertNotNil(doc.copiedStep, "copiedStep 가 set 됨")
        XCTAssertEqual(doc.copiedStep, originalStep,
                       "copiedStep 은 byte-exact 원본 copy")

        // Paste
        MotionPageActions.pasteStep(in: doc)

        XCTAssertEqual(doc.motion.pages[0].steps.count, stepsCountBefore + 1,
                       "paste 는 step 1개 추가")
        XCTAssertEqual(doc.selectedStep, 1, "새 step 위치로 selection 이동")
        XCTAssertEqual(doc.motion.pages[0].steps[1], originalStep,
                       "삽입된 step 은 copy 와 동일")
        XCTAssertTrue(doc.isDirty, "paste 후 dirty")
    }

    func testPasteWithoutCopyIsNoop() {
        let doc = makeEmptyDoc()
        let stepsBefore = doc.motion.pages[0].steps.count

        // copiedStep == nil 상태에서 paste
        MotionPageActions.pasteStep(in: doc)

        XCTAssertEqual(doc.motion.pages[0].steps.count, stepsBefore,
                       "copy 없이 paste 는 no-op")
        XCTAssertFalse(doc.isDirty, "no-op 시 dirty 변경 없음")
        XCTAssertTrue(doc.undoStack.isEmpty, "no-op 시 undo push 없음")
    }

    // MARK: - 4. undo/redo 사이클

    func testUndoRedoCycle() {
        let doc = makeEmptyDoc()
        let initialPageCount = doc.motion.pages.count
        let initialName = doc.motion.pages[0].name

        // 변경 1: 페이지 추가
        let newId = MotionPageActions.addPage(in: doc)
        XCTAssertEqual(doc.motion.pages.count, initialPageCount + 1)
        XCTAssertEqual(doc.undoStack.count, 1, "변경 후 undo stack 에 1개")

        // Undo
        let undoApplied = MotionPageActions.undo(in: doc)
        XCTAssertTrue(undoApplied, "undo 성공")
        XCTAssertEqual(doc.motion.pages.count, initialPageCount,
                       "undo 후 페이지 count 원복")
        XCTAssertTrue(doc.undoStack.isEmpty, "undo stack 비워짐")
        XCTAssertEqual(doc.redoStack.count, 1, "redo stack 에 1개 push")
        XCTAssertEqual(doc.motion.pages[0].name, initialName,
                       "undo 후 페이지 내용 원복")

        // Redo
        let redoApplied = MotionPageActions.redo(in: doc)
        XCTAssertTrue(redoApplied, "redo 성공")
        XCTAssertEqual(doc.motion.pages.count, initialPageCount + 1,
                       "redo 후 페이지 count 다시 증가")
        XCTAssertTrue(doc.redoStack.isEmpty, "redo stack 비워짐")
        XCTAssertEqual(doc.undoStack.count, 1, "undo stack 에 1개 다시")
        XCTAssertEqual(doc.motion.pages.last?.id, newId,
                       "redo 후 새 페이지 id 동일")
    }

    func testUndoOnEmptyStackIsNoop() {
        let doc = makeEmptyDoc()

        let applied = MotionPageActions.undo(in: doc)

        XCTAssertFalse(applied, "빈 undo stack — false 반환")
        XCTAssertFalse(doc.isDirty, "no-op 시 dirty 변경 없음")
    }

    // MARK: - 5. renamePage

    func testRenamePagePreservesIDs() {
        let doc = makeEmptyDoc()
        let originalId = doc.motion.pages[0].id
        let originalName = doc.motion.pages[0].name
        let newName = "이름 변경 테스트"

        let result = MotionPageActions.renamePage(at: 0, to: newName, in: doc)

        XCTAssertNotNil(result, "유효 변경 — result 반환")
        XCTAssertEqual(result?.pageId, originalId, "id 보존")
        XCTAssertEqual(result?.oldName, originalName, "oldName 반환 정확")
        XCTAssertEqual(result?.newName, newName, "newName 반환 정확")
        XCTAssertEqual(doc.motion.pages[0].name, newName, "page name 실제 변경")
        XCTAssertEqual(doc.motion.pages[0].id, originalId, "id 변경 안 됨")
        XCTAssertTrue(doc.isDirty, "rename 후 dirty")
        XCTAssertEqual(doc.undoStack.count, 1, "undo snapshot push")
    }

    func testRenamePageRejectsEmptyAndDuplicate() {
        let doc = makeEmptyDoc()
        let originalName = doc.motion.pages[0].name

        // 빈 이름 거부
        XCTAssertNil(MotionPageActions.renamePage(at: 0, to: "", in: doc),
                     "빈 이름 거부")
        // 공백만 거부
        XCTAssertNil(MotionPageActions.renamePage(at: 0, to: "   ", in: doc),
                     "공백만 거부")
        // 동일 이름 거부 (no-op)
        XCTAssertNil(MotionPageActions.renamePage(at: 0, to: originalName, in: doc),
                     "동일 이름 거부 (undo 폭주 방지)")

        XCTAssertEqual(doc.motion.pages[0].name, originalName,
                       "거부 시 name 변경 없음")
        XCTAssertFalse(doc.isDirty, "거부 시 dirty 변경 없음")
        XCTAssertTrue(doc.undoStack.isEmpty, "거부 시 undo push 없음")
    }

    // MARK: - 추가: duplicatePage / splitSelectedStep / removeSelectedStep

    func testDuplicatePagePreservesStepsAndAssignsNewId() {
        let doc = makeEmptyDoc()
        let srcId = doc.motion.pages[0].id
        let srcSteps = doc.motion.pages[0].steps
        let countBefore = doc.motion.pages.count

        MotionPageActions.duplicatePage(at: 0, in: doc)

        XCTAssertEqual(doc.motion.pages.count, countBefore + 1, "복제 페이지 추가")
        XCTAssertEqual(doc.selectedPageIdx, 1, "복제본 선택 (원본 idx+1)")
        XCTAssertEqual(doc.motion.pages[1].steps, srcSteps,
                       "복제본의 steps 가 원본과 동일")
        XCTAssertNotEqual(doc.motion.pages[1].id, srcId,
                          "복제본은 새 id (충돌 방지)")
        XCTAssertEqual(doc.motion.pages[1].nextPage, 0,
                       "복제본은 nextPage 체인 끊김 (안전)")
        XCTAssertEqual(doc.motion.pages[1].exitPage, 0,
                       "복제본은 exitPage 체인 끊김 (안전)")
    }

    func testRemoveSelectedStepProtectsLastStep() {
        let doc = makeEmptyDoc()
        // 페이지에 step 1개만 (preconditions).
        XCTAssertEqual(doc.motion.pages[0].steps.count, 1,
                       "preconditions: 1 step")

        MotionPageActions.removeSelectedStep(in: doc)

        XCTAssertEqual(doc.motion.pages[0].steps.count, 1,
                       "최소 1 step 유지 — 거부")
        XCTAssertFalse(doc.isDirty, "거부 시 dirty 변경 없음")
    }

    func testSplitSelectedStepRequires16MsMinimum() {
        let doc = makeEmptyDoc()
        // playMs < 16 인 step 으로 교체 (playTime=1 → 8ms).
        let shortStep = MotionStep(
            positions: Array(repeating: 2048, count: 31),
            pauseTime: 0,
            playTime: 1  // 8ms < 16ms 임계.
        )
        doc.motion.pages[0].steps = [shortStep]
        doc.selectedStep = 0

        MotionPageActions.splitSelectedStep(in: doc)

        XCTAssertEqual(doc.motion.pages[0].steps.count, 1,
                       "playMs<16 인 step 은 분할 거부")
    }

    // MARK: - JSON export (data-only)

    func testExportPageJSONRoundTrip() throws {
        let doc = makeEmptyDoc()

        let json = try MotionPageActions.exportPageJSON(at: 0, in: doc)
        XCTAssertFalse(json.isEmpty, "JSON 출력 비어 있지 않음")

        // round trip — decode 가능해야 함.
        let decoded = try MotionDoc.from(json: json)
        XCTAssertEqual(decoded.pages.count, 1, "단일 페이지 doc 로 export")
        XCTAssertEqual(decoded.pages[0].id, doc.motion.pages[0].id,
                       "round trip 후 id 보존")
    }

    func testExportPageJSONOutOfRangeThrows() {
        let doc = makeEmptyDoc()

        XCTAssertThrowsError(
            try MotionPageActions.exportPageJSON(at: 99, in: doc),
            "out-of-range idx 는 throw"
        )
    }

    func testDocumentJSONRoundTrip() throws {
        let doc = makeDoc()

        let json = try MotionPageActions.documentJSON(of: doc)
        let decoded = try MotionDoc.from(json: json)

        XCTAssertEqual(decoded.pages.count, doc.motion.pages.count,
                       "전체 doc round trip — 페이지 수 동일")
    }

    // MARK: - pushUndoSnapshot max depth

    func testPushUndoSnapshotEnforcesMaxDepth() {
        let doc = makeEmptyDoc()
        let maxDepth = doc.maxUndoDepth

        // maxDepth + 5 회 push.
        for _ in 0..<(maxDepth + 5) {
            MotionPageActions.pushUndoSnapshot(in: doc)
        }

        XCTAssertEqual(doc.undoStack.count, maxDepth,
                       "undo stack 은 maxUndoDepth 로 cap (가장 오래된 항목 drop)")
    }

    func testPushUndoSnapshotClearsRedoStack() {
        let doc = makeEmptyDoc()

        // 변경 → undo → redo stack 에 1개
        MotionPageActions.addPage(in: doc)
        _ = MotionPageActions.undo(in: doc)
        XCTAssertEqual(doc.redoStack.count, 1, "preconditions: redo 1개")

        // 새 변경 push → redo invalidate (새 분기)
        MotionPageActions.pushUndoSnapshot(in: doc)

        XCTAssertTrue(doc.redoStack.isEmpty,
                      "새 변경 push 시 redo stack invalidate")
    }
}
