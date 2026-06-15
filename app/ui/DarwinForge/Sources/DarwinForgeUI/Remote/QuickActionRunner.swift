import SwiftUI

/// 퀵 액션 실행 라우터 — 확인 티어 분기·실행 중 상태·최근 실행·텔레메트리 시점.
///
/// UX 리디자인 (2026-06-13):
///   - `.remoteQuickAction` 텔레메트리는 **실행 확정 시점**에 1회(T1=클릭, T2/T3=시트
///     승인). 종전엔 confirm 분기 전에 기록돼 "취소한 위험 액션"도 실행으로 집계됐다.
///   - `runningActionID` 로 액션 행 스피너 + 패널 잠금(직렬 SSH 채널 — 동시 발사 차단).
///   - 최근 실행 5개(중복 제거) — 브링업 루프(상태→시작→종료) 반복 가속.
///
/// RemoteShell 공개 API 는 건드리지 않는다(실행은 전부 `shell.send` 경유 —
/// 승인→실행→히스토리 시맨틱 불변).
@MainActor
final class QuickActionRunner: ObservableObject {
    /// 실행 중인 액션 id (스피너·패널 잠금). nil = 유휴.
    @Published private(set) var runningActionID: String?
    /// 직전 완료 액션의 (id, 성공 여부) — 행 플래시 0.8초.
    @Published private(set) var lastFlash: (id: String, ok: Bool)?
    /// 최근 실행 액션 id (최신순, 최대 5, 중복 제거).
    @Published private(set) var recentActionIDs: [String] = []

    static let recentLimit = 5

    /// 실행 확정된 액션을 보내고 상태를 추적한다. 호출 전 confirm 위계는 뷰가 처리.
    func run(_ action: QuickAction, shell: RemoteShell, harness: any HarnessFacade) async {
        guard runningActionID == nil else { return }   // 직렬 채널 — 재진입 차단
        harness.record(
            .remoteQuickAction,
            level: action.category == .danger ? .warn : .info,
            actor: .user,
            data: ["action_id": AnyCodable(action.id),
                   "category": AnyCodable(action.category.rawValue)]
        )
        noteRecent(action.id)
        runningActionID = action.id
        let ex = await shell.send(action.command)
        runningActionID = nil
        let ok = (ex?.error == nil) && ((ex?.exitCode ?? 0) == 0)
        flash(id: action.id, ok: ok)
    }

    private func noteRecent(_ id: String) {
        var ids = recentActionIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        if ids.count > Self.recentLimit { ids.removeLast(ids.count - Self.recentLimit) }
        recentActionIDs = ids
    }

    private func flash(id: String, ok: Bool) {
        lastFlash = (id, ok)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if self?.lastFlash?.id == id { self?.lastFlash = nil }
        }
    }
}
