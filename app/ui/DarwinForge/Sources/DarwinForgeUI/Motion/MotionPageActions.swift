import Foundation
import ForgeCore

/// 사이클 256 (Wave 4.3.3) — MotionStudioView 의 page/step mutation 정적 함수 분리.
///
/// **배경**: Wave 4.3.1 (StarterMotionLibrary) + Wave 4.3.2 (MotionDocumentStore)
/// 이후 MotionStudioView 가 여전히 1404 LOC. page/step mutation 메서드 (`addPage`,
/// `duplicatePage`, `deletePage`, `renamePage`, `copySelectedStep`, `pasteStep`,
/// `splitSelectedStep`, `removeSelectedStep`, `addStepFromCurrentPose`,
/// `saveCurrentStepFromPose`, `pushUndoSnapshot`, `undo`, `redo`, `markDirty`,
/// `exportPageData`, `documentJSON`) 14개를 본 namespace 로 추출.
///
/// **설계 원칙**:
/// - 모든 메서드 `static func` — 상태 없음, 순수 transform.
/// - `MotionDocumentStore` 는 `@Observable` reference type 이므로 `inout` 없이 그대로
///   인자로 받아 mutate. SwiftUI Observation framework 가 자동으로 변경 감지.
/// - undo snapshot push 책임은 각 메서드 내부 (mutation 직전).
/// - 텔레메트리는 호출자가 emit (분리 후에도 동일한 telemetry kind/payload 유지).
///   본 enum 은 mutation 만 책임, side-effect (telemetry / pose update) 는 분리.
/// - 파일 dialog (NSSavePanel 등) 는 view 에 잔류. 본 enum 은 export 시 Data 만 반환.
///
/// **동작 보존 보장**:
/// - undo snapshot 위치 / mutation 순서 / selection 보정 로직 모두 원본과 byte-for-byte 동일.
/// - 호출 사이트는 `MotionPageActions.addPage(in: doc)` 로만 변경. semantic 차이 0.
///
/// **MainActor isolation**: `MotionDocumentStore` 가 `@MainActor` 이므로 모든 메서드도
/// `@MainActor`. SwiftUI view 가 main thread 에서 호출하므로 isolation hop 없음.
@MainActor
public enum MotionPageActions {

    // MARK: - Page CRUD

    /// 신규 페이지 추가 — id 자동 (max+1), name "새 동작 N", steps [walkReady].
    /// undo snapshot push + selection 갱신 + isDirty set.
    ///
    /// - Returns: 새로 추가된 페이지의 id (telemetry payload 용).
    @discardableResult
    public static func addPage(in doc: MotionDocumentStore) -> UInt8 {
        pushUndoSnapshot(in: doc)
        let nextId = (doc.motion.pages.map { $0.id }.max() ?? 0) + 1
        let newPage = MotionPage(
            id: nextId,
            name: "새 동작 \(nextId)",
            steps: [.from(pose: .walkReady, playMs: 256, pauseMs: 0)]
        )
        doc.motion.pages.append(newPage)
        doc.selectedPageIdx = doc.motion.pages.count - 1
        doc.selectedStep = 0
        markDirty(in: doc)
        return nextId
    }

    /// 페이지 복제 — 같은 step 시퀀스, 새 ID, "<name> 복사본" suffix.
    /// 원본 idx + 1 위치에 삽입. next/exit 체인은 끊음 (안전).
    public static func duplicatePage(at idx: Int, in doc: MotionDocumentStore) {
        guard idx >= 0, idx < doc.motion.pages.count else { return }
        pushUndoSnapshot(in: doc)
        let src = doc.motion.pages[idx]
        let nextId = (doc.motion.pages.map { $0.id }.max() ?? 0) + 1
        let copyName = src.name.isEmpty ? "동작 \(src.id) 복사본" : "\(src.name) 복사본"
        let copy = MotionPage(
            id: nextId,
            name: copyName,
            compliance: src.compliance,
            nextPage: 0,        // 복제본은 next/exit 체인 끊음 — 안전.
            exitPage: 0,
            repeat: src.repeat,
            speed: src.speed,
            accel: src.accel,
            steps: src.steps
        )
        doc.motion.pages.insert(copy, at: idx + 1)
        doc.selectedPageIdx = idx + 1
        doc.selectedStep = 0
        markDirty(in: doc)
    }

    /// 페이지 삭제 — 1개 미만으로 줄지 않도록 보호.
    /// selectedPageIdx 보정 (최대 idx 로 clamp).
    ///
    /// - Returns: 삭제된 페이지 (telemetry 용 — id / name). nil 이면 삭제 안 일어남.
    @discardableResult
    public static func deletePage(at idx: Int, in doc: MotionDocumentStore) -> MotionPage? {
        guard doc.motion.pages.count > 1, idx >= 0, idx < doc.motion.pages.count else { return nil }
        let removed = doc.motion.pages[idx]
        pushUndoSnapshot(in: doc)
        doc.motion.pages.remove(at: idx)
        doc.selectedPageIdx = max(0, min(doc.selectedPageIdx, doc.motion.pages.count - 1))
        doc.selectedStep = 0
        markDirty(in: doc)
        return removed
    }

    /// 페이지 이름 변경 — trimmed empty 거부 + 동일 이름 변경 거부 (no-op).
    ///
    /// - Returns: `(oldName, newName)` 튜플 (telemetry 용). 변경 안 됐으면 nil.
    @discardableResult
    public static func renamePage(at idx: Int, to newName: String, in doc: MotionDocumentStore) -> (oldName: String, newName: String, pageId: UInt8)? {
        guard idx >= 0, idx < doc.motion.pages.count else { return nil }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, doc.motion.pages[idx].name != trimmed else { return nil }
        let oldName = doc.motion.pages[idx].name
        let pageId = doc.motion.pages[idx].id
        pushUndoSnapshot(in: doc)
        doc.motion.pages[idx].name = trimmed
        markDirty(in: doc)
        return (oldName, trimmed, pageId)
    }

    // MARK: - Export (data-only — NSSavePanel 은 view 에 잔류)

    /// 단일 페이지 → 단일 페이지 MotionDoc 의 pretty-printed JSON 텍스트.
    /// view 는 NSSavePanel 로 URL 받아 write 만 책임. mutation 0.
    public static func exportPageJSON(at idx: Int, in doc: MotionDocumentStore) throws -> String {
        guard idx >= 0, idx < doc.motion.pages.count else {
            throw NSError(domain: "MotionPageActions", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "page index out of range"])
        }
        let page = doc.motion.pages[idx]
        let single = MotionDoc(
            version: doc.motion.version,
            robotGeneration: doc.motion.robotGeneration,
            pages: [page]
        )
        return try single.toJSON(prettyPrinted: true)
    }

    /// 전체 motion doc → pretty-printed JSON. saveDocAs 의 데이터 부분.
    /// 성공 시 view 가 isDirty = false 처리.
    public static func documentJSON(of doc: MotionDocumentStore) throws -> String {
        return try doc.motion.toJSON(prettyPrinted: true)
    }

    // MARK: - Step mutation

    /// 현재 선택 step 의 자세를 인자 pose 로 갱신. 변경 없으면 no-op (undo 폭주 방지).
    /// view 가 stagedPose 보유 → 이 메서드에 전달.
    public static func saveCurrentStepFromPose(_ pose: RobotPose, in doc: MotionDocumentStore) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        var page = doc.motion.pages[doc.selectedPageIdx]
        guard doc.selectedStep >= 0, doc.selectedStep < page.steps.count else { return }
        let oldStep = page.steps[doc.selectedStep]
        let newStep = MotionStep.from(
            pose: pose,
            playMs: oldStep.playMs,
            pauseMs: oldStep.pauseMs
        )
        guard newStep != oldStep else { return }
        pushUndoSnapshot(in: doc)
        page.steps[doc.selectedStep] = newStep
        doc.motion.pages[doc.selectedPageIdx] = page
        markDirty(in: doc)
    }

    /// 인자 pose 를 새 step 으로 append. 자동으로 새 step 선택.
    public static func addStepFromPose(_ pose: RobotPose, in doc: MotionDocumentStore) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        var page = doc.motion.pages[doc.selectedPageIdx]
        pushUndoSnapshot(in: doc)
        let step = MotionStep.from(pose: pose, playMs: 256, pauseMs: 0)
        page.steps.append(step)
        doc.motion.pages[doc.selectedPageIdx] = page
        doc.selectedStep = page.steps.count - 1
        markDirty(in: doc)
    }

    /// 현재 선택 step 삭제 — 1개 미만으로 줄지 않도록 보호.
    /// selectedStep 보정 후 view 가 applySelectedStepToPose 호출 필요.
    public static func removeSelectedStep(in doc: MotionDocumentStore) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        var page = doc.motion.pages[doc.selectedPageIdx]
        guard page.steps.count > 1 else { return }
        pushUndoSnapshot(in: doc)
        page.steps.remove(at: doc.selectedStep)
        if doc.selectedStep >= page.steps.count { doc.selectedStep = page.steps.count - 1 }
        doc.motion.pages[doc.selectedPageIdx] = page
        markDirty(in: doc)
    }

    // MARK: - Clipboard (copy / paste / split)

    /// ⌘C — 현재 선택 step 을 doc.copiedStep 으로. byte-exact copy.
    public static func copySelectedStep(in doc: MotionDocumentStore) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        let page = doc.motion.pages[doc.selectedPageIdx]
        guard doc.selectedStep >= 0, doc.selectedStep < page.steps.count else { return }
        doc.copiedStep = page.steps[doc.selectedStep]
    }

    /// ⌘V — doc.copiedStep 을 현재 위치 *다음에* 삽입. 자동으로 새 step 선택.
    /// view 가 applySelectedStepToPose 호출 필요.
    public static func pasteStep(in doc: MotionDocumentStore) {
        guard let step = doc.copiedStep else { return }
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        var page = doc.motion.pages[doc.selectedPageIdx]
        pushUndoSnapshot(in: doc)
        let insertAt = min(page.steps.count, max(0, doc.selectedStep + 1))
        page.steps.insert(step, at: insertAt)
        doc.motion.pages[doc.selectedPageIdx] = page
        doc.selectedStep = insertAt
        markDirty(in: doc)
    }

    /// ⌘K — 현재 선택 step 을 두 개로 분할.
    ///
    /// 동작:
    ///   1. 이전 step (또는 walkReady) → 현재 step 의 자세를 0.5 lerp 한 *중간 자세*.
    ///   2. playMs 의 절반을 첫 step 에 부여, 중간 자세 step 으로 변환.
    ///   3. 남은 절반 playMs + 원래 자세 + 원래 pauseMs 를 두 번째 step 으로.
    ///   4. 후반부 (원래 자세) 자동 선택 — split 후에도 사용자 의도 유지.
    public static func splitSelectedStep(in doc: MotionDocumentStore) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        var page = doc.motion.pages[doc.selectedPageIdx]
        guard doc.selectedStep >= 0, doc.selectedStep < page.steps.count else { return }
        let original = page.steps[doc.selectedStep]
        // playMs 가 16ms 미만이면 분할 무의미 (8ms × 2 단위).
        guard original.playMs >= 16 else { return }
        pushUndoSnapshot(in: doc)

        // 이전 자세 — selectedStep > 0 면 이전 step 의 toPose(), 아니면 walkReady.
        let prevPose: RobotPose = doc.selectedStep > 0
            ? page.steps[doc.selectedStep - 1].toPose()
            : .walkReady
        let curPose = original.toPose()
        let midPose = prevPose.lerp(to: curPose, t: 0.5)

        // 8ms quantize. playMs/2 → /16 × 8 단위 (.mtn raw quantize).
        let halfPlay = (original.playMs / 16) * 8
        let remainPlay = original.playMs - halfPlay

        let firstHalf = MotionStep.from(
            pose: midPose,
            playMs: halfPlay,
            pauseMs: 0
        )
        var secondHalf = original
        secondHalf.playTime = UInt8(clamping: remainPlay / 8)
        // pauseTime 은 원래 step 의 것 유지.

        page.steps[doc.selectedStep] = firstHalf
        page.steps.insert(secondHalf, at: doc.selectedStep + 1)
        doc.motion.pages[doc.selectedPageIdx] = page

        // 후반부 (원본 자세) 자동 선택.
        doc.selectedStep += 1
        markDirty(in: doc)
    }

    // MARK: - Undo / Redo

    /// 모든 mutation 함수 시작에 호출 — 현재 motion 을 undo stack 에 push.
    /// maxUndoDepth 초과 시 가장 오래된 항목 drop. redo stack 은 invalidate (새 분기).
    public static func pushUndoSnapshot(in doc: MotionDocumentStore) {
        doc.undoStack.append(doc.motion)
        if doc.undoStack.count > doc.maxUndoDepth { doc.undoStack.removeFirst() }
        doc.redoStack.removeAll()
    }

    /// ⌘Z — 마지막 변경 되돌리기. 변경 없으면 noop.
    /// view 가 applySelectedStepToPose 호출 필요.
    ///
    /// - Returns: undo 가 적용됐는지 (view 의 후속 pose update 트리거 용).
    @discardableResult
    public static func undo(in doc: MotionDocumentStore) -> Bool {
        guard let prev = doc.undoStack.popLast() else { return false }
        doc.redoStack.append(doc.motion)
        doc.motion = prev
        // 인덱스 안전 보정 — pages / steps 가 줄어들 수 있음.
        doc.selectedPageIdx = min(doc.selectedPageIdx, max(0, doc.motion.pages.count - 1))
        if doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count {
            doc.selectedStep = min(doc.selectedStep, max(0, doc.motion.pages[doc.selectedPageIdx].steps.count - 1))
        } else {
            doc.selectedStep = 0
        }
        doc.isDirty = true
        return true
    }

    /// ⌘⇧Z — 되돌린 변경을 다시 앞으로.
    /// view 가 applySelectedStepToPose 호출 필요.
    ///
    /// - Returns: redo 가 적용됐는지 (view 의 후속 pose update 트리거 용).
    @discardableResult
    public static func redo(in doc: MotionDocumentStore) -> Bool {
        guard let next = doc.redoStack.popLast() else { return false }
        doc.undoStack.append(doc.motion)
        doc.motion = next
        doc.selectedPageIdx = min(doc.selectedPageIdx, max(0, doc.motion.pages.count - 1))
        if doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count {
            doc.selectedStep = min(doc.selectedStep, max(0, doc.motion.pages[doc.selectedPageIdx].steps.count - 1))
        } else {
            doc.selectedStep = 0
        }
        doc.isDirty = true
        return true
    }

    // MARK: - Internal helpers

    /// motion doc 변경 시 dirty flag set — UI 의 저장 버튼 활성화.
    public static func markDirty(in doc: MotionDocumentStore) {
        doc.isDirty = true
    }
}
