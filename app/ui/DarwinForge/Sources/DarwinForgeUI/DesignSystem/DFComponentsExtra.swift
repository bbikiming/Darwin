import SwiftUI

// MARK: - DFComponentMetrics (디자인 시스템 내부 raw 값 보관)

/// 디자인 시스템 컴포넌트 내부에서만 사용하는 metric.
///
/// 외부 화면에서 `cornerRadius: 7` 같은 raw 값을 쓰는 대신 DS 컴포넌트가 본 enum 을 사용한다.
internal enum DFComponentMetrics {
    /// DFChip horizontal padding (capsule shape 내부 텍스트 여백).
    static let chipPaddingH: CGFloat = 7
    /// DFChip vertical padding.
    static let chipPaddingV: CGFloat = 2
    /// DFKeyboardHint padding horizontal.
    static let keyHintPaddingH: CGFloat = 4
    /// DFKeyboardHint padding vertical.
    static let keyHintPaddingV: CGFloat = 1
    /// DFKeyboardHint corner radius.
    static let keyHintRadius: CGFloat = DFRadius.xs
    /// GlassNeonButtonStyle horizontal padding.
    static let neonButtonPaddingH: CGFloat = 14
    /// CodeBlock 내부 padding.
    static let codeBlockPadding: CGFloat = DFSpace.sm3
    /// Notice banner 좌측 색상 bar 폭.
    static let noticeBarWidth: CGFloat = 3
    /// Notice banner 좌측 색상 bar height (compact).
    static let noticeBarMinHeight: CGFloat = 28
    /// Sidebar row icon container size.
    static let sidebarIconSize: CGFloat = 18
    /// Quick action card icon container size.
    static let quickActionIconSize: CGFloat = 32
}

// MARK: - DFStatusPill — 상태 / 안전 표시

/// 상태 / 안전 표시용 capsule pill.
///
/// `DFChip` 과 역할이 분리됨:
/// - `DFChip` = 일반 태그/필터/카운터 (작고 캡션 톤).
/// - `DFStatusPill` = 연결/안전/위험 상태 (큰 글자, 아이콘 필수, 색+아이콘+텍스트 3중 시그널).
///
/// 근거: KS S ISO 7010 + Apple HIG Differentiate Without Color (색 의존성 회피).
public struct DFStatusPill: View {
    /// 상태 심각도.
    public enum Severity {
        case info, success, warning, danger, neutral

        var color: Color {
            switch self {
            case .info: return DFColor.info
            case .success: return DFColor.success
            case .warning: return DFColor.warning
            case .danger: return DFColor.danger
            case .neutral: return DFColor.textSecondary
            }
        }
        var defaultIcon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            case .neutral: return "circle.fill"
            }
        }
        var label: String {
            switch self {
            case .info: return "정보"
            case .success: return "정상"
            case .warning: return "주의"
            case .danger: return "위험"
            case .neutral: return "상태"
            }
        }
    }

    public let text: String
    public let severity: Severity
    public let icon: String?
    public let compact: Bool

    public init(_ text: String, severity: Severity = .info, icon: String? = nil, compact: Bool = false) {
        self.text = text
        self.severity = severity
        self.icon = icon
        self.compact = compact
    }

    public var body: some View {
        Label(text, systemImage: icon ?? severity.defaultIcon)
            .labelStyle(.titleAndIcon)
            .font(.system(size: compact ? DFFontSize.s10 : DFFontSize.s11, weight: .semibold))
            .foregroundStyle(severity.color)
            .padding(.horizontal, compact ? DFSpace.sm : DFSize.pillPaddingH)
            .padding(.vertical, compact ? DFSpace.micro2 : DFSpace.xs)
            .background(
                Capsule().fill(severity.color.opacity(DFOpacity.o15))
            )
            .overlay(
                Capsule().stroke(severity.color.opacity(DFOpacity.o30), lineWidth: DFSize.borderHairline)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(severity.label) — \(text)")
    }
}

// MARK: - DFNoticeBanner — 화면 상단 알림 배너

/// 화면 상단 / 카드 안 알림 배너 — sim-only, 주의, 정보 메시지.
///
/// 좌측 색상 bar + 아이콘 + 제목 + 부제 + (선택) trailing action.
public struct DFNoticeBanner<Trailing: View>: View {
    public let severity: DFStatusPill.Severity
    public let title: String
    public let message: String?
    public let icon: String?
    @ViewBuilder public let trailing: () -> Trailing

    public init(_ title: String,
                message: String? = nil,
                severity: DFStatusPill.Severity = .info,
                icon: String? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.message = message
        self.severity = severity
        self.icon = icon
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            Rectangle()
                .fill(severity.color)
                .frame(width: DFComponentMetrics.noticeBarWidth)
                .frame(minHeight: DFComponentMetrics.noticeBarMinHeight)
                .clipShape(Capsule())
            Image(systemName: icon ?? severity.defaultIcon)
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(severity.color)
                .frame(width: DFSize.iconSm, alignment: .center)
                .padding(.top, DFSpace.micro2)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(title)
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                    .foregroundStyle(DFColor.textPrimary)
                if let message {
                    Text(message)
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DFSpace.xs)
            trailing()
        }
        .padding(.horizontal, DFSpace.sm3)
        .padding(.vertical, DFSpace.sm)
        .background(severity.color.opacity(DFOpacity.ghost))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(severity.color.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(severity.label) — \(title)\(message.map { ". \($0)" } ?? "")")
    }
}

// MARK: - DFCodeBlock — monospaced code/output 표시

/// 명령 결과 / 코드 표시용 표준 박스.
///
/// RemoteShell, 빌드 출력, 로그 표시에 사용. dark/light 모드 자동 적응.
public struct DFCodeBlock: View {
    public let text: String
    public let language: String?
    public let scrollable: Bool
    public let minHeight: CGFloat?
    public let maxHeight: CGFloat?

    public init(_ text: String,
                language: String? = nil,
                scrollable: Bool = true,
                minHeight: CGFloat? = DFDataLayout.codeBlockMinH,
                maxHeight: CGFloat? = DFDataLayout.codeBlockMaxH) {
        self.text = text
        self.language = language
        self.scrollable = scrollable
        self.minHeight = minHeight
        self.maxHeight = maxHeight
    }

    public var body: some View {
        Group {
            if scrollable {
                ScrollView { codeBody }
            } else {
                codeBody
            }
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight, alignment: .topLeading)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
    }

    private var codeBody: some View {
        Text(text)
            .font(DFFont.mono)
            .foregroundStyle(DFColor.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(DFComponentMetrics.codeBlockPadding)
    }
}

// MARK: - DFSidebarRow — 좌측 사이드바 표준 row

/// 좌측 사이드바 표준 row (RootView 사이드바 사용).
///
/// icon + label + (선택) trailing pill + selected 강조.
public struct DFSidebarRow<Trailing: View>: View {
    public let icon: String
    public let label: String
    public let shortcut: String?
    public let tint: Color
    public let selected: Bool
    public let action: () -> Void
    @ViewBuilder public let trailing: () -> Trailing

    public init(icon: String, label: String,
                shortcut: String? = nil,
                tint: Color = DFColor.accent,
                selected: Bool = false,
                action: @escaping () -> Void,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.label = label
        self.shortcut = shortcut
        self.tint = tint
        self.selected = selected
        self.action = action
        self.trailing = trailing
    }

    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DFSpace.sm) {
                Image(systemName: icon)
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                    .foregroundStyle(selected ? tint : DFColor.textSecondary)
                    .frame(width: DFComponentMetrics.sidebarIconSize, alignment: .center)
                Text(label)
                    .font(.system(size: DFFontSize.s13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DFColor.textPrimary : DFColor.textSecondary)
                Spacer(minLength: DFSpace.xs)
                trailing()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                }
            }
            .padding(.horizontal, DFSpace.sm3)
            .padding(.vertical, DFSpace.xs2)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .fill(selected ? tint.opacity(DFOpacity.o12)
                          : (hovering ? DFColor.textSecondary.opacity(DFOpacity.ghost) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DFAnimation.fast, value: hovering)
    }
}

// MARK: - DFStepIndicator — wizard 진행 인디케이터

/// 다단계 wizard 진행 인디케이터 (ConnectionWizard 등).
///
/// 1️⃣ - 2️⃣ - 3️⃣ 형태로 step 번호 + 라벨 표시.
public struct DFStepIndicator: View {
    public let steps: [String]
    public let current: Int

    public init(_ steps: [String], current: Int) {
        self.steps = steps
        self.current = current
    }

    public var body: some View {
        HStack(spacing: DFSpace.xs2) {
            ForEach(steps.indices, id: \.self) { i in
                stepDot(i)
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(connectorColor(after: i))
                        .frame(height: DFDataLayout.dividerH)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func stepDot(_ i: Int) -> some View {
        let active = i <= current
        let done = i < current
        return HStack(spacing: DFSpace.xs2) {
            ZStack {
                Circle()
                    .fill(active ? DFColor.accent : DFColor.elev2)
                    .frame(width: DFSize.indicatorMd + DFSpace.xs2, height: DFSize.indicatorMd + DFSpace.xs2)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: DFFontSize.s9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(i + 1)")
                        .font(.system(size: DFFontSize.s10, weight: .bold))
                        .foregroundStyle(active ? .white : DFColor.textSecondary)
                }
            }
            Text(steps[i])
                .font(.system(size: DFFontSize.s11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? DFColor.textPrimary : DFColor.textSecondary)
                .lineLimit(1)
        }
    }

    private func connectorColor(after i: Int) -> Color {
        i < current ? DFColor.accent : DFColor.textSecondary.opacity(DFOpacity.subtle)
    }
}

// MARK: - DFQuickActionCard — 큰 액션 카드

/// 클릭 가능한 큰 액션 카드 (RemoteShell quick action, Connection wizard launch 등).
///
/// icon (큰 원) + 제목 + 설명 + chevron.
public struct DFQuickActionCard: View {
    public let icon: String
    public let title: String
    public let subtitle: String
    public let tint: Color
    public let shortcut: String?
    public let action: () -> Void

    public init(icon: String, title: String, subtitle: String,
                tint: Color = DFColor.accent,
                shortcut: String? = nil,
                action: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.shortcut = shortcut
        self.action = action
    }

    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DFSpace.sm3) {
                ZStack {
                    RoundedRectangle(cornerRadius: DFRadius.sm)
                        .fill(tint.opacity(DFOpacity.o15))
                        .frame(width: DFComponentMetrics.quickActionIconSize,
                               height: DFComponentMetrics.quickActionIconSize)
                    Image(systemName: icon)
                        .font(.system(size: DFFontSize.s14, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: DFSpace.micro2) {
                    HStack(spacing: DFSpace.xs2) {
                        Text(title)
                            .font(.system(size: DFFontSize.s13, weight: .semibold))
                            .foregroundStyle(DFColor.textPrimary)
                        if let shortcut {
                            DFKeyboardHint(shortcut)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
            }
            .padding(.horizontal, DFSpace.sm3)
            .padding(.vertical, DFSpace.sm)
            .background(hovering ? tint.opacity(DFOpacity.ghost) : DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(hovering ? tint.opacity(DFOpacity.o30)
                            : DFColor.textSecondary.opacity(DFOpacity.subtle),
                            lineWidth: DFSize.borderHairline)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DFAnimation.fast, value: hovering)
    }
}

// MARK: - DFMetricCard — 대시보드 메트릭 카드

/// 대시보드 KPI / 메트릭 카드 (ConnectionDashboard 등).
///
/// title + icon + content (사용자 정의) + 옵션 expanded height.
public struct DFMetricCard<Content: View>: View {
    public let title: String
    public let icon: String
    public let tint: Color
    public let expanded: Bool
    @ViewBuilder public let content: () -> Content

    public init(title: String, icon: String, tint: Color = DFColor.accent,
                expanded: Bool = false,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.expanded = expanded
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm2) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: icon)
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }
            content()
        }
        .padding(DFSpace.sm3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: expanded ? 90 : 132)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o10), lineWidth: DFSize.borderHairline)
        )
    }
}
