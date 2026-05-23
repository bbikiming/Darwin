import Foundation
import ForgeCore

/// 사이클 257 (Wave 4.3.4) — MotionStudioView 의 import-related 정적 함수 분리.
///
/// **배경**: Wave 4.3.3 (MotionPageActions) 직후 MotionStudioView 가 1289 LOC.
/// import 메서드 3개 (`importSynthPages`, `importPoseAsMotionPage`,
/// `importMotionPanel` 의 데이터 부분) 를 본 namespace 로 추출.
///
/// **설계 원칙** (W4.3.3 pattern 응용):
/// - 모든 메서드 `static func` — 상태 없음, 순수 transform.
/// - `MotionDocumentStore` 는 `@Observable` reference type 이므로 `inout` 없이 그대로
///   인자로 받아 mutate. SwiftUI Observation framework 가 자동으로 변경 감지.
/// - undo snapshot push 책임은 본 enum 내부 (mutation 직전).
/// - **NSOpenPanel / file dialog 는 view 잔류** — UI 책임. 본 enum 은 데이터만 처리.
/// - **Telemetry / Toast 는 view 잔류** — 반환값으로 payload 노출, view 가 emit.
/// - **applySelectedStepToPose 는 view 잔류** — stagedPose 는 view-state.
///
/// **동작 보존 보장**:
/// - undo snapshot 위치 / mutation 순서 / selection 보정 / lastError 매핑 패턴
///   모두 원본과 byte-for-byte 동일.
/// - 호출 사이트는 view 가 `MotionImportActions.foo(...)` 결과를 받아 후속
///   side-effect (toast, telemetry, pose update) 수행.
///
/// **MainActor isolation**: `MotionDocumentStore` 가 `@MainActor` 이므로 모든 메서드도
/// `@MainActor`. SwiftUI view 가 main thread 에서 호출하므로 isolation hop 없음.
@MainActor
public enum MotionImportActions {

    // MARK: - 반환 타입

    /// Synth / Teach import 성공 시 view 가 후속 처리 (telemetry / toast) 에 필요한 payload.
    public struct ImportResult: Equatable {
        /// 신규 추가된 페이지들의 motion.pages 내 first index.
        /// view 는 이 값으로 `selectedPageIdx` 설정 + 첫 페이지 자동 선택.
        public let firstAddedIdx: Int

        /// 추가된 페이지 수 (selection range 계산 + telemetry "added" count).
        public let addedCount: Int

        /// 첫 신규 페이지의 ID (telemetry "new_id" payload).
        public let firstAddedId: UInt8

        public init(firstAddedIdx: Int, addedCount: Int, firstAddedId: UInt8) {
            self.firstAddedIdx = firstAddedIdx
            self.addedCount = addedCount
            self.firstAddedId = firstAddedId
        }
    }

    // MARK: - Synth → MotionStudio import

    /// 사이클 180 + 187 (codex MAJOR fix): Synth 합성 결과 페이지 일괄 import.
    ///
    /// **동작 (원본과 동일)**:
    /// 1. 빈 배열이면 .success(nil) — no-op.
    /// 2. `SynthMotionExporter.reassignPageIds` 가 overflow 안전 보장 (UInt8 max=255).
    /// 3. overflow 시 `.failure(ExportError.idOverflow)` 반환, motion 무변화.
    /// 4. 성공 시 undo snapshot push + pages append + selection 갱신 + isDirty set.
    ///
    /// **view 책임**:
    /// - `.failure` 시 `lastError = SynthMotionExporter.koreanMessage(for: err)`.
    /// - `.success` 시 `applySelectedStepToPose()` 호출 (stagedPose 갱신).
    ///
    /// - Returns:
    ///   - `.success(nil)` — 빈 배열 입력 (no-op).
    ///   - `.success(ImportResult)` — 성공, selection 갱신 정보 + telemetry payload.
    ///   - `.failure(ExportError)` — overflow / 기타 (view 가 lastError 매핑).
    public static func importSynthPages(
        _ pages: [MotionPage],
        in doc: MotionDocumentStore
    ) -> Result<ImportResult?, SynthMotionExporter.ExportError> {
        guard !pages.isEmpty else { return .success(nil) }
        let existingMaxId = doc.motion.pages.map { Int($0.id) }.max() ?? 0
        let reassignResult = SynthMotionExporter.reassignPageIds(
            existingMaxId: existingMaxId,
            importPages: pages
        )
        switch reassignResult {
        case .success(let reassigned):
            MotionPageActions.pushUndoSnapshot(in: doc)
            doc.motion = MotionDoc(
                version: doc.motion.version,
                robotGeneration: doc.motion.robotGeneration,
                pages: doc.motion.pages + reassigned
            )
            // 첫 신규 페이지 선택 — 사용자 가 즉시 확인.
            let firstIdx = doc.motion.pages.count - reassigned.count
            doc.selectedPageIdx = firstIdx
            doc.selectedStep = 0
            doc.isDirty = true
            // reassigned 는 non-empty 보장 (pages non-empty 조건 + reassignPageIds 가 항등 길이).
            let firstId = reassigned.first?.id ?? 0
            return .success(ImportResult(
                firstAddedIdx: firstIdx,
                addedCount: reassigned.count,
                firstAddedId: firstId
            ))
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Teach → MotionStudio import

    /// 사이클 193 — Teach 스냅샷 자세를 단일 step MotionPage 로 import.
    ///
    /// **동작 (원본과 동일)**:
    /// 1. `SynthMotionExporter.reassignPageIds` 로 overflow-safe ID 부여.
    /// 2. overflow 시 `.failure` 반환, motion 무변화.
    /// 3. 성공 시 undo snapshot push + 페이지 1개 append + selection 갱신 + isDirty set.
    /// 4. 페이지 name = "티칭 자세 \(existingMaxId + 1)" — 원본 패턴 보존.
    ///
    /// **view 책임**:
    /// - `.failure` 시 `lastError = SynthMotionExporter.koreanMessage(for: err)`.
    /// - `.success` 시 `applySelectedStepToPose()` + `transferToast` set + telemetry emit.
    ///
    /// - Returns:
    ///   - `.success(ImportResult)` — 성공, telemetry payload 포함.
    ///   - `.failure(ExportError)` — overflow (view 가 lastError 매핑).
    public static func importPoseAsMotionPage(
        _ pose: RobotPose,
        in doc: MotionDocumentStore
    ) -> Result<ImportResult, SynthMotionExporter.ExportError> {
        let existingMaxId = doc.motion.pages.map { Int($0.id) }.max() ?? 0
        let step = MotionStep.from(pose: pose, playMs: 256, pauseMs: 0)
        let draft = MotionPage(id: 1, name: "티칭 자세 \(existingMaxId + 1)", steps: [step])
        let reassignResult = SynthMotionExporter.reassignPageIds(
            existingMaxId: existingMaxId,
            importPages: [draft]
        )
        switch reassignResult {
        case .success(let reassigned):
            MotionPageActions.pushUndoSnapshot(in: doc)
            doc.motion = MotionDoc(
                version: doc.motion.version,
                robotGeneration: doc.motion.robotGeneration,
                pages: doc.motion.pages + reassigned
            )
            let firstIdx = doc.motion.pages.count - 1
            doc.selectedPageIdx = firstIdx
            doc.selectedStep = 0
            doc.isDirty = true
            let firstId = reassigned.first?.id ?? 0
            return .success(ImportResult(
                firstAddedIdx: firstIdx,
                addedCount: 1,
                firstAddedId: firstId
            ))
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - File (.mtn / .json) → MotionStudio import

    /// 외부 `.mtn` 파일 텍스트 → MotionDoc 로 doc 전체 교체.
    ///
    /// **동작 (원본 importMotionPanel 데이터 부분과 동일)**:
    /// 1. `.mtn` 텍스트 → JSON 변환 (`Motion.mtnToJSON`).
    /// 2. JSON → MotionDoc 디코딩 (`MotionDoc.from(json:)`).
    /// 3. doc.motion 전체 교체 + selection 리셋.
    ///
    /// **view 책임**:
    /// - NSOpenPanel 로 파일 선택 + 파일 read (UI 책임).
    /// - throw 시 `lastError = error.localizedDescription` 매핑.
    /// - 성공 시 `applySelectedStepToPose()` 호출.
    ///
    /// **주의**: 본 메서드는 undo snapshot push 하지 **않음** — 원본 importMotionPanel
    /// 동작과 byte-for-byte 동일 (외부 파일 로드는 새 doc 시작이므로 undo history 무의미).
    ///
    /// - Parameters:
    ///   - mtnText: `.mtn` 포맷 텍스트 (view 가 NSOpenPanel + 파일 read 로 획득).
    ///   - generation: 로봇 세대 (기본 "op2", 원본과 동일).
    /// - Throws: `Motion.mtnToJSON` / `MotionDoc.from(json:)` 의 error 그대로 전파.
    public static func importMotionFromMTN(
        _ mtnText: String,
        generation: String = "op2",
        in doc: MotionDocumentStore
    ) throws {
        let json = try Motion.mtnToJSON(mtnText, generation: generation)
        let imported = try MotionDoc.from(json: json)
        doc.motion = imported
        doc.selectedPageIdx = 0
        doc.selectedStep = 0
    }
}
