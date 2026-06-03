import SwiftUI

/// 관절편집이 필요한 화면(스튜디오·티칭)의 게이트 배너.
///
/// # 비유
///
/// 정비소 입구의 안내판 — 차가 "주행 모드"로 와 있으면 "정비하려면 모드를 바꾸세요"라고
/// 버튼까지 같이 보여주고, 아예 차가 없으면(오프라인) "먼저 입고하세요"라고 안내한다.
///
/// 동작:
///   - `.walk` (로봇 연결됐지만 보행 모드): "관절편집 모드가 필요해요" + 관절편집 안내 +
///     전환 주의 → 1탭 "관절편집으로 전환" 버튼(`switchMode(to: .jointEdit)`).
///   - `.offline`: 기존 "빠른 연결" 안내로 폴백 — 호출 화면이 넘긴 `offlineTitle`/
///     `offlineMessage` 를 그대로 사용(기존 문구 보존).
///   - `.jointEdit`: 이미 올바른 모드 — 배너 불필요(EmptyView).
public struct ConnectionModeBanner: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var remoteShell: RemoteShell

    /// 오프라인 폴백 — 기존 화면의 빈 상태 문구를 그대로 받는다.
    private let offlineTitle: String
    private let offlineMessage: String
    private let offlineIcon: String

    public init(offlineTitle: String, offlineMessage: String,
                offlineIcon: String = "antenna.radiowaves.left.and.right.slash") {
        self.offlineTitle = offlineTitle
        self.offlineMessage = offlineMessage
        self.offlineIcon = offlineIcon
    }

    public var body: some View {
        switch store.currentMode {
        case .walk:
            walkModeBanner
        case .offline:
            offlineBanner
        case .jointEdit:
            // 이미 관절편집 모드 — 게이트 통과 상태라 배너 없음.
            EmptyView()
        }
    }

    // MARK: - Walk mode (전환 유도)

    private var walkModeBanner: some View {
        DFEmptyState(
            icon: ConnectionMode.jointEdit.iconSystemName,
            title: "관절편집 모드가 필요해요",
            message: "\(ConnectionMode.jointEdit.guidance)\n\n\(ConnectionMode.switchNote)",
            tint: DFColor.accent
        ) {
            switchPhaseAction
        }
    }

    /// 전환 버튼 — 진행 중이면 ProgressView, 실패면 사유 + 재시도.
    @ViewBuilder
    private var switchPhaseAction: some View {
        switch store.modeSwitchPhase {
        case .switching(_, let step):
            HStack(spacing: DFSpace.xs) {
                ProgressView().controlSize(.small)
                Text(step)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        case .failed(let message):
            VStack(spacing: DFSpace.xs) {
                Text(message)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
                    .multilineTextAlignment(.center)
                switchButton(title: "다시 시도")
            }
        case .idle:
            switchButton(title: "관절편집으로 전환")
        }
    }

    private func switchButton(title: String) -> some View {
        let actionable = remoteShell.activeChannel == .ssh
        return DFButton(.primary) {
            guard actionable else { return }
            let shell = remoteShell
            Task { await store.switchMode(to: .jointEdit, remoteShell: shell) }
        } label: {
            Label(title, systemImage: ConnectionMode.jointEdit.iconSystemName)
        }
        .disabled(!actionable)
        .help(actionable ? ConnectionMode.switchNote
                         : "원격 셸(SSH) 연결이 필요해요. 셋업을 먼저 완료하세요.")
    }

    // MARK: - Offline fallback (기존 문구 보존)

    private var offlineBanner: some View {
        DFEmptyState(
            icon: offlineIcon,
            title: offlineTitle,
            message: offlineMessage,
            tint: DFColor.warning
        ) {
            EmptyView()
        }
    }
}
