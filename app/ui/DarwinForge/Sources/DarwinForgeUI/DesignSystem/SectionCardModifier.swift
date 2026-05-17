import SwiftUI

/// **v1.10 (2026-05-17)** — macOS Sequoia/Sonoma Inspector 패턴의 section card.
///
/// Fall Prevention 모니터링 dashboard 의 각 영역을 일관된 card 로 wrap.
/// - 옵션 header (icon + title) — macOS Settings.app 의 group section 스타일
/// - subtle background + border + corner radius
/// - macOS Reduce Transparency 자동 fallback
///
/// 사용 예:
/// ```swift
/// myContent.dfSectionCard(title: "안전 등급", icon: "shield.fill")
/// myContent.dfSectionCard(title: nil)  // header 없는 card
/// ```
public struct DFSectionCardModifier: ViewModifier {
    let title: String?
    let icon: String?

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DFColor.accent)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DFColor.textSecondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            content
                .padding(title != nil ? .horizontal : .all, 12)
                .padding(.bottom, 12)
                .padding(.top, title != nil ? 0 : 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.elev2.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DFColor.textSecondary.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

public extension View {
    /// macOS-native section card wrapper. Inspector 패턴.
    func dfSectionCard(title: String? = nil, icon: String? = nil) -> some View {
        modifier(DFSectionCardModifier(title: title, icon: icon))
    }
}
