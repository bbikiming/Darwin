import SwiftUI

/// 좌측 퀵 액션 패널 — 검색 + 최근 + 섹션 리스트 + 위험 명령 격리(기획 1·2장).
///
/// 설계 근거:
///   - 33개 액션 전수 세로 노출(종전 가로 스크롤 + 세그먼트는 발견성 0) —
///     320pt 1열 리스트 행이라 세로 스캔 1회로 전체 파악.
///   - danger 는 일반 섹션 흐름에서 분리된 최하단 GroupBox(공간 격리 + 큰 갭) —
///     인접 오클릭(slip) 차단. octagon 심볼·danger 색은 이 화면에서 위험 전용.
///   - 검색(⌘F): 이름·설명·명령어 부분 일치.
struct QuickActionPanel: View {
    @ObservedObject var runner: QuickActionRunner
    let onTrigger: (QuickAction) -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: DFSpace.none) {
            searchField
                .padding(.horizontal, DFSpace.sm2)
                .padding(.vertical, DFSpace.sm)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    if filtered.isEmpty {
                        Text("\"\(query)\"와 맞는 명령이 없어요 — 아래 입력창에 직접 입력할 수 있어요")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                            .padding(DFSpace.sm2)
                    } else {
                        if query.isEmpty { recentSection }
                        ForEach(normalSections, id: \.self) { category in
                            section(category)
                        }
                        dangerSection
                    }
                }
                .padding(.horizontal, DFSpace.sm2)
                .padding(.vertical, DFSpace.sm)
            }
        }
        .background(DFColor.canvas)
    }

    // MARK: - 검색

    private var searchField: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DFFontSize.s11))
                .foregroundStyle(DFColor.textSecondary)
            TextField("명령 검색 — 이름·설명·명령어", text: $query)
                .textFieldStyle(.plain)
                .font(DFFont.body)
                .focused($searchFocused)
                .onExitCommand { query = "" }   // Esc = 클리어
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                }
                .buttonStyle(.plain)
            } else {
                DFKeyboardHint("⌘", "F")
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
        .background(
            // ⌘F → 검색 포커스 (숨김 버튼 — 시각 chrome 없이 단축키만).
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
        )
    }

    private var filtered: [QuickAction] {
        guard !query.isEmpty else { return QuickActionCatalog.all }
        let q = query.lowercased()
        return QuickActionCatalog.all.filter {
            $0.label.lowercased().contains(q)
                || $0.detail.lowercased().contains(q)
                || $0.command.lowercased().contains(q)
                || $0.id.contains(q)
        }
    }

    private var normalSections: [QuickActionCategory] {
        QuickActionCatalog.sectionOrder.filter { $0 != .danger }
    }

    private func filteredActions(in category: QuickActionCategory) -> [QuickAction] {
        filtered.filter { $0.category == category }
    }

    // MARK: - 섹션

    @ViewBuilder
    private var recentSection: some View {
        let recents = runner.recentActionIDs.compactMap { QuickActionCatalog.action(id: $0) }
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                DFSectionHeader("최근", icon: "clock.arrow.circlepath")
                ForEach(recents) { action in
                    QuickActionRow(action: action, runner: runner,
                                   isFeatured: false, onTrigger: onTrigger)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ category: QuickActionCategory) -> some View {
        let actions = filteredActions(in: category)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                DFSectionHeader(category.label, icon: category.icon, tint: category.tint)
                ForEach(actions) { action in
                    QuickActionRow(action: action, runner: runner,
                                   isFeatured: action.id == "gamepad-pilot-start",
                                   onTrigger: onTrigger)
                }
            }
        }
    }

    @ViewBuilder
    private var dangerSection: some View {
        let actions = filteredActions(in: .danger)
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                DFSectionHeader(QuickActionCategory.danger.label,
                                icon: QuickActionCategory.danger.icon,
                                tint: DFColor.danger)
                ForEach(actions) { action in
                    QuickActionRow(action: action, runner: runner,
                                   isFeatured: false, onTrigger: onTrigger)
                }
            }
            .padding(DFSpace.sm)
            .background(DFColor.danger.opacity(DFOpacity.ghost))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(DFColor.danger.opacity(DFOpacity.o30), lineWidth: DFSize.borderStrong)
            )
            // 인접 오클릭(slip) 차단 — 위 일반 섹션과 큰 갭(기획 5.2).
            .padding(.top, DFSpace.lg)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("위험 명령 그룹")
        }
    }
}

/// 액션 리스트 행 — 아이콘 + 라벨 + 결과 중심 설명 + 확인 티어 뱃지.
struct QuickActionRow: View {
    let action: QuickAction
    @ObservedObject var runner: QuickActionRunner
    let isFeatured: Bool
    let onTrigger: (QuickAction) -> Void

    @State private var hovering = false

    private var isRunning: Bool { runner.runningActionID == action.id }
    private var isLocked: Bool { runner.runningActionID != nil && !isRunning }

    var body: some View {
        Button { onTrigger(action) } label: {
            HStack(spacing: DFSpace.sm) {
                statusIcon
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action.label)
                        .font(DFFont.body)
                        .foregroundStyle(DFColor.textPrimary)
                        .lineLimit(1)
                    Text(action.detail)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                tierBadge
            }
            .padding(.horizontal, DFSpace.sm)
            .frame(height: DFSize.buttonHLarge)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(isFeatured ? DFColor.forge.opacity(DFOpacity.o30) : .clear,
                            lineWidth: DFSize.borderHairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1)
        .onHover { hovering = $0 }
        .dfPointerCursor()
        .help(tooltip)
        .contextMenu {
            Button("명령 복사") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(action.command, forType: .string)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            ProgressView().controlSize(.small)
        } else if let flash = runner.lastFlash, flash.id == action.id {
            Image(systemName: flash.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: DFFontSize.s13, weight: .semibold))
                .foregroundStyle(flash.ok ? DFColor.success : DFColor.danger)
        } else {
            Image(systemName: action.icon)
                .font(.system(size: DFFontSize.s13, weight: .semibold))
                .foregroundStyle(action.category == .danger ? DFColor.danger : action.category.tint)
        }
    }

    @ViewBuilder
    private var tierBadge: some View {
        switch action.confirmTier {
        case .none:
            EmptyView()
        case .sheet:
            // 색+모양 2중 부호(색각 대응) — triangle=확인 필요(주의).
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.warning)
                .help("실행 전 확인 단계가 있어요")
        case .hold:
            // octagon 은 danger 전용(화면 전역 불변식).
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.danger)
                .help("위험 — 확인 후 1.5초 홀드로만 실행돼요")
        }
    }

    private var rowBackground: Color {
        if hovering && !isLocked { return DFColor.hoverBg }
        if isFeatured { return DFColor.forge.opacity(DFOpacity.ghost) }
        return .clear
    }

    /// 툴팁 계약(기획 2.3): 1줄 명령은 원문, 멀티라인은 첫 줄 + " …".
    private var tooltip: String {
        let lines = action.command.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return action.command }
        return lines.count > 1 ? "\(first) …" : String(first)
    }

    private var accessibilityText: String {
        var parts = [action.label, action.detail]
        if action.category == .danger { parts.append("위험 명령") }
        if action.confirmTier != .none { parts.append("확인 필요") }
        return parts.joined(separator: ", ")
    }
}
