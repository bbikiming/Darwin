import SwiftUI

/// 보행 ↔ 관절편집 원클릭 전환 토글 (toolbar).
///
/// # 비유
///
/// 자동차의 "주행/정비" 모드 다이얼 — 한 번 돌리면 차가 알아서 반대 모드를 끄고
/// 새 모드를 준비한다. 진행 중에는 다이얼이 잠기고 "준비 중…" 표시.
///
/// 동작:
///   - 현재 모드(`store.currentMode`)를 반영하는 2-세그먼트 컨트롤.
///   - 세그먼트를 누르면 `store.switchMode(to:remoteShell:)` 비동기 호출.
///   - 전환 중에는 ProgressView + 단계 라벨 + 비활성.
///   - 실패 시 사유를 danger tint 로 표시.
///   - remoteShell 미존재(미셋업) 시 비활성 + 힌트.
public struct ConnectionModeSwitcher: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var remoteShell: RemoteShell

    public init() {}

    public var body: some View {
        HStack(spacing: DFSpace.xs2) {
            switch store.modeSwitchPhase {
            case .switching(_, let step):
                switchingIndicator(step: step)
            case .failed(let message):
                failureIndicator(message: message)
            case .idle:
                segmentControl
            }
        }
    }

    // MARK: - Segment control (idle)

    private var segmentControl: some View {
        HStack(spacing: DFSpace.none) {
            segment(for: .walk)
            segment(for: .jointEdit)
        }
        .background(DFColor.elev2)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: 0.5)
        )
        .opacity(isActionable ? 1 : DFOpacity.disabled)
        .help(helpText)
    }

    private func segment(for mode: ConnectionMode) -> some View {
        let selected = store.currentMode == mode
        return Button {
            guard isActionable, !selected else { return }
            let shell = remoteShell
            Task { await store.switchMode(to: mode, remoteShell: shell) }
        } label: {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: mode.iconSystemName)
                    .font(.system(size: 10, weight: .bold))
                Text(mode.label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs)
            .foregroundStyle(selected ? DFColor.canvas : DFColor.textSecondary)
            .background(selected ? mode.tint : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isActionable || selected)
        .help(mode.guidance)
    }

    // MARK: - Switching / failure

    private func switchingIndicator(step: String) -> some View {
        HStack(spacing: DFSpace.xs) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text(step)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs)
        .background(DFColor.elev2)
        .clipShape(Capsule())
    }

    private func failureIndicator(message: String) -> some View {
        Button {
            store.clearModeSwitchPhase()
        } label: {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(message)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs)
            .foregroundStyle(DFColor.danger)
            .background(DFColor.danger.opacity(DFOpacity.subtle))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(message) — 눌러서 닫기")
    }

    // MARK: - State

    /// 전환 가능 조건 — 원격 셸이 도달 가능(SSH) 해야 SSH 명령을 보낼 수 있다.
    private var isActionable: Bool {
        remoteShell.activeChannel == .ssh
    }

    private var helpText: String {
        isActionable
            ? "보행 ↔ 관절편집 전환 — \(ConnectionMode.switchNote)"
            : "원격 셸(SSH) 연결이 필요해요. 셋업을 먼저 완료하세요."
    }
}

// MARK: - ConnectionMode tint (UI 전용 확장)

private extension ConnectionMode {
    /// 세그먼트 선택 배경색 — 모드별 상태색.
    var tint: Color {
        switch self {
        case .walk:      return DFColor.success
        case .jointEdit: return DFColor.accent
        case .offline:   return DFColor.textSecondary
        }
    }
}
