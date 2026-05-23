import Foundation
import ForgeCore

/// 사이클 250 — Wave 4.3.2: MotionStudioView 의 document 라이프사이클 state 추출.
///
/// MotionStudioView 분할 두 번째 단계 (W4.3.1 StarterMotionLibrary 분리 후).
///
/// 책임:
/// - MotionDoc 보유 + 페이지/스텝 selection 관리
/// - 편집 plumbing (isDirty / undo / redo / clipboard)
/// - 페이지 rename / delete 임시 state
/// - 호버 / 진행 상태
///
/// **사이클 250 (W4.3.2) 부터**: MotionStudioView 가 @StateObject 로 보유.
/// ObservableObject (Combine) 으로 SwiftUI iOS 13+ 호환 유지.
@MainActor
public final class MotionDocumentStore: ObservableObject {

    /// 현재 편집 중 motion document.
    @Published public var motion: MotionDoc
    @Published public var selectedPageIdx: Int = 0
    @Published public var selectedStep: Int = 0

    /// 마지막 저장 이후 변경 있음.
    @Published public var isDirty: Bool = false

    /// 이름 변경 sheet 의 대상 페이지 idx + 임시 이름. nil = sheet 닫힘.
    @Published public var renamingPageIdx: Int? = nil
    @Published public var renameDraft: String = ""

    /// 삭제 확인 alert 의 대상 페이지 idx.
    @Published public var deletingPageIdx: Int? = nil

    /// 로봇 실행 진행 중.
    @Published public var executingOnRobot: Bool = false

    /// 호버한 페이지 idx — `⋯` 메뉴 버튼 표시용.
    @Published public var hoveredPageIdx: Int? = nil

    // MARK: - Undo / Redo / clipboard

    /// 변경 history — 모든 mutation 직전 `pushUndoSnapshot()` 이 motion 을 push.
    /// 50 개 제한.
    @Published public var undoStack: [MotionDoc] = []
    @Published public var redoStack: [MotionDoc] = []

    /// 키프레임 복사 — selected step 의 byte-exact copy.
    @Published public var copiedStep: MotionStep? = nil

    public let maxUndoDepth: Int = 50

    public init(initialMotion: MotionDoc = StarterMotionLibrary.starterDoc()) {
        self.motion = initialMotion
    }
}
