import SwiftUI

/// **v1.11.15 (2026-05-19)** — 사이드바 / 설정 화면용 테마 picker.
///
/// 3개 옵션 (system / lightFlat / dark) 을 가로 segmented icon row 로 표시.
/// 활성 옵션은 accent tint + 채움, 그 외는 옅은 회색.
///
/// 사용:
/// ```swift
/// DFThemePicker()                        // sidebar inline (compact)
/// DFThemePicker(layout: .vertical)       // settings panel (full)
/// ```
public struct DFThemePicker: View {
    public enum Layout {
        /// 가로 segmented icon row — 사이드바 / 컴팩트 영역.
        case horizontal
        /// 세로 list — 설정 패널 / 모달.
        case vertical
    }

    public let layout: Layout
    public let showsLabel: Bool

    @EnvironmentObject private var themeManager: DFThemeManager

    public init(layout: Layout = .horizontal, showsLabel: Bool = true) {
        self.layout = layout
        self.showsLabel = showsLabel
    }

    public var body: some View {
        switch layout {
        case .horizontal: horizontalBody
        case .vertical:   verticalBody
        }
    }

    // MARK: - Horizontal (사이드바)

    private var horizontalBody: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            if showsLabel {
                Text("테마")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            HStack(spacing: DFSpace.xs2) {
                ForEach(DFTheme.allCases) { theme in
                    themeIconButton(theme)
                }
            }
        }
    }

    private func themeIconButton(_ theme: DFTheme) -> some View {
        let active = themeManager.theme == theme
        return Button {
            themeManager.setTheme(theme)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: theme.symbolName)
                    .font(.system(size: DFFontSize.s13, weight: .semibold))
                    .foregroundStyle(active ? activeForeground(theme) : DFColor.textSecondary)
                Text(themeShortLabel(theme))
                    .font(.system(size: DFFontSize.s9, weight: .medium))
                    .foregroundStyle(active ? activeForeground(theme) : DFColor.textSecondary.opacity(DFOpacity.dim))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(active ? activeBackground(theme) : DFColor.textSecondary.opacity(DFOpacity.ghost))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(active ? activeBorder(theme) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                            lineWidth: DFSize.borderHairline)
            )
        }
        .buttonStyle(.plain)
        .help(theme.helpText)
        .accessibilityLabel(theme.displayName)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func themeShortLabel(_ theme: DFTheme) -> String {
        switch theme {
        case .system:    return "자동"
        case .lightFlat: return "흰색"
        case .dark:      return "다크"
        }
    }

    /// 활성 시 강조 색 — lightFlat 만 forge tint, 그 외 accent.
    private func activeForeground(_ theme: DFTheme) -> Color {
        themeTint(theme)
    }

    private func activeBackground(_ theme: DFTheme) -> Color {
        themeTint(theme).opacity(0.14)
    }

    private func activeBorder(_ theme: DFTheme) -> Color {
        themeTint(theme).opacity(DFOpacity.strong)
    }

    private func themeTint(_ theme: DFTheme) -> Color {
        switch theme {
        case .system:    return DFColor.accent
        case .lightFlat: return DFColor.forge
        case .dark:      return DFColor.torque
        }
    }

    // MARK: - Vertical (설정 패널)

    private var verticalBody: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            if showsLabel {
                Text("테마")
                    .font(DFFont.sectionBody)
                    .foregroundStyle(DFColor.textPrimary)
            }
            ForEach(DFTheme.allCases) { theme in
                themeRowButton(theme)
            }
        }
    }

    private func themeRowButton(_ theme: DFTheme) -> some View {
        let active = themeManager.theme == theme
        return Button {
            themeManager.setTheme(theme)
        } label: {
            HStack(spacing: DFSpace.sm) {
                Image(systemName: theme.symbolName)
                    .font(.system(size: DFFontSize.s14, weight: .semibold))
                    .foregroundStyle(active ? themeTint(theme) : DFColor.textSecondary)
                    .frame(width: DFSize.iconMd, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.displayName)
                        .font(active ? DFFont.bodyEmph : DFFont.body)
                        .foregroundStyle(DFColor.textPrimary)
                    Text(theme.helpText)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DFFontSize.s14, weight: .semibold))
                        .foregroundStyle(themeTint(theme))
                }
            }
            .padding(.horizontal, DFSpace.sm3)
            .padding(.vertical, DFSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? themeTint(theme).opacity(DFOpacity.ghost) : DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(active ? themeTint(theme).opacity(DFOpacity.o30)
                                   : DFColor.textSecondary.opacity(DFOpacity.subtle),
                            lineWidth: DFSize.borderHairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.displayName) 테마")
        .accessibilityHint(theme.helpText)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
