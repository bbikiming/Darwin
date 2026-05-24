import SwiftUI

/// **v1.15.5 (2026-05-21) — Phase 1.5: 적용 범위 배지 view**.
///
/// `WalkLabApplyScope` 의 시각 표현. compact (아이콘 위주) / full (아이콘 + 텍스트).
///
/// # 사용 패턴
///
/// ```swift
/// // 슬라이더 옆 — compact.
/// Slider(...)
///     .walkLabApplyScopeBadge(field: .strideMm, engine: session.walkingEngine, style: .compact)
///
/// // 별도 row — full.
/// WalkLabApplyScopeBadge(scope: scope, style: .full)
/// ```
///
/// **Code-reviewer H2 권고**: VoiceOver 라벨 (`.accessibilityLabel`) +
/// 힌트 (`.accessibilityHint`) 명시 — compact 는 아이콘만이라 특히 중요.
public struct WalkLabApplyScopeBadge: View {
    public let scope: WalkLabApplyScope
    public let style: Style

    public enum Style: Sendable {
        /// 아이콘 + 짧은 라벨. inline 사용. 가로 ~80pt.
        case compact
        /// 아이콘 + 라벨 + 짧은 설명. 별도 row. 가로 가변.
        case full
    }

    public init(scope: WalkLabApplyScope, style: Style = .compact) {
        self.scope = scope
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .compact:
                HStack(spacing: 3) {
                    Image(systemName: scope.icon)
                        .font(DFFont.labelStrong)
                    Text(scope.label)
                        .font(DFFont.micro)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(badgeColor.opacity(0.18))
                .foregroundStyle(badgeColor)
                .clipShape(Capsule())

            case .full:
                HStack(spacing: 6) {
                    Image(systemName: scope.icon)
                        .font(.system(size: 11, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scope.label)
                            .font(.caption.weight(.semibold))
                        if let msg = scope.detailedMessage {
                            Text(msg)
                                .font(DFFont.label)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(badgeColor.opacity(0.10))
                .foregroundStyle(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scope.label)
        .accessibilityHint(scope.detailedMessage ?? "")
    }

    /// Code-reviewer H1: `DFColor` 토큰으로 매핑. dark/light/lightFlat 정합.
    private var badgeColor: Color {
        switch scope.colorName {
        case .success:    return DFColor.success
        case .info:       return DFColor.info
        case .secondary:  return DFColor.textSecondary
        case .accent:     return DFColor.accent
        case .danger:     return DFColor.danger
        }
    }
}

// MARK: - ViewModifier helper (code-reviewer M1)

/// `.walkLabApplyScopeBadge(field:engine:style:)` 호출 site boilerplate 제거.
public extension View {
    /// field + engine 로부터 scope 결정 후 trailing badge 부착.
    func walkLabApplyScopeBadge(
        field: WalkLabField,
        engine: WalkingEngine,
        style: WalkLabApplyScopeBadge.Style = .compact
    ) -> some View {
        let scope = WalkLabApplyScopeResolver.scope(for: field, engine: engine)
        return HStack(spacing: 6) {
            self
            WalkLabApplyScopeBadge(scope: scope, style: style)
        }
    }

    /// 직접 scope 인스턴스 부착 — observeOnly 같은 별도 결정 경로 용.
    func walkLabApplyScopeBadge(
        scope: WalkLabApplyScope,
        style: WalkLabApplyScopeBadge.Style = .compact
    ) -> some View {
        HStack(spacing: 6) {
            self
            WalkLabApplyScopeBadge(scope: scope, style: style)
        }
    }
}
