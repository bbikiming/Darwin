import SwiftUI

// MARK: - DFButton

/// 다윈포지 표준 버튼 — 글래스모피즘 + 네온 글로우.
///
/// 6가지 variants:
///   - primary:   accent (blue) 채움. 메인 액션.
///   - secondary: 투명 글래스 + 텍스트 컬러. 보조 액션.
///   - ghost:     배경 없음 + hover 글래스 in-fill. 텍스트 액션.
///   - danger:    빨강 채움. 파괴적 액션 (confirm 후).
///   - success:   초록 채움. 완료/성공 액션.
///   - forge:     forge-orange 채움. 모션/로봇 액션.
public struct DFButton<Label: View>: View {
    public enum Variant { case primary, secondary, ghost, danger, success, forge }
    public enum Size { case small, medium, large }

    public let variant: Variant
    public let size: Size
    public let action: () -> Void
    @ViewBuilder public let label: () -> Label

    public init(_ variant: Variant = .primary, size: Size = .medium,
                action: @escaping () -> Void,
                @ViewBuilder label: @escaping () -> Label) {
        self.variant = variant
        self.size = size
        self.action = action
        self.label = label
    }

    public var body: some View {
        Button(action: action) {
            label().font(fontFor(size))
        }
        .buttonStyle(
            GlassNeonButtonStyle(
                tint: tint,
                prominent: prominent,
                glow: glow,
                height: heightFor(size),
                radius: DFRadius.md
            )
        )
    }

    private func heightFor(_ s: Size) -> CGFloat {
        switch s { case .small: return DFSize.buttonHSmall; case .medium: return DFSize.buttonHMedium; case .large: return DFSize.buttonHLarge }
    }
    private func fontFor(_ s: Size) -> Font {
        switch s {
        case .small:  return .system(size: 11, weight: .semibold)
        case .medium: return .system(size: 12, weight: .semibold)
        case .large:  return .system(size: 14, weight: .semibold)
        }
    }
    private var tint: Color {
        switch variant {
        case .primary:   return DFColor.accent
        case .secondary: return DFColor.textPrimary
        case .ghost:     return DFColor.textPrimary
        case .danger:    return DFColor.danger
        case .success:   return DFColor.success
        case .forge:     return DFColor.forge
        }
    }
    private var prominent: Bool {
        switch variant {
        case .primary, .danger, .success, .forge: return true
        case .secondary, .ghost: return false
        }
    }
    private var glow: Bool {
        // ghost 는 글로우 없음 (텍스트 액션이라 시각 노이즈 최소화).
        variant != .ghost
    }
}

// MARK: - DFChip

/// 작은 정보 칩 — status, count, tag.
/// 통일 capsule 형태. icon + text 또는 text 만.
public struct DFChip: View {
    public enum Style { case primary, neutral, success, warning, danger, info, forge }

    public let icon: String?
    public let text: String
    public let style: Style
    public let mono: Bool

    public init(_ text: String, icon: String? = nil,
                style: Style = .neutral, mono: Bool = false) {
        self.text = text
        self.icon = icon
        self.style = style
        self.mono = mono
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .bold,
                              design: mono ? .monospaced : .default))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    private var tint: Color {
        switch style {
        case .primary: return DFColor.accent
        case .neutral: return DFColor.textSecondary
        case .success: return DFColor.success
        case .warning: return DFColor.warning
        case .danger:  return DFColor.danger
        case .info:    return DFColor.info
        case .forge:   return DFColor.forge
        }
    }
}

// MARK: - DFBadge — 작은 dot indicator

/// status DOT indicator — 색만으로 상태 표시 (8pt 원).
///
/// # 사용 vs 다른 컴포넌트
///
/// | 컴포넌트 | 형태 | 용도 |
/// |---|---|---|
/// | **DFBadge** (이) | 작은 dot 원 | 상태 ON/OFF, 연결 상태 등 — 텍스트 없이 색만 |
/// | **`DFSourcePill`** | 텍스트 + 색 capsule | 데이터 출처 라벨 ("실 IMU", "시뮬") |
/// | **`DFChip`** | 텍스트 + tint capsule | 카테고리 / 토글 chip |
///
/// **2026-05-16**: DFBadge 와 DFSourcePill 는 의미가 다름 — Badge=DOT, Pill=TEXT.
/// 중복 X.
public struct DFBadge: View {
    public let tint: Color
    public let pulsing: Bool
    public let size: CGFloat

    public init(tint: Color, pulsing: Bool = false, size: CGFloat = 8) {
        self.tint = tint
        self.pulsing = pulsing
        self.size = size
    }

    @State private var pulse: Bool = false

    public var body: some View {
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.7), radius: pulsing ? (pulse ? 4 : 2) : 0)
            .overlay(
                Circle()
                    .stroke(tint, lineWidth: pulsing && pulse ? 0.5 : 0)
                    .scaleEffect(pulsing && pulse ? 2.0 : 1.0)
                    .opacity(pulsing && pulse ? 0 : 0.5)
            )
            .onAppear {
                if pulsing {
                    withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse.toggle()
                    }
                }
            }
    }
}

// MARK: - DFSectionHeader

/// 일관 섹션 헤더 — icon + title + 선택적 trailing.
public struct DFSectionHeader<Trailing: View>: View {
    public let title: String
    public let icon: String?
    public let tint: Color
    @ViewBuilder public let trailing: () -> Trailing

    public init(_ title: String, icon: String? = nil, tint: Color = DFColor.textPrimary,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DFColor.textSecondary)
                .textCase(.uppercase)
            Spacer()
            trailing()
        }
    }
}

// MARK: - DFEmptyState

/// 빈 상태 — illustration + title + body + action.
/// 메뉴 첫 진입 시 사용자에게 다음 액션 명확히 안내.
public struct DFEmptyState<Action: View>: View {
    public let icon: String
    public let title: String
    public let message: String
    public let tint: Color
    @ViewBuilder public let action: () -> Action

    public init(icon: String, title: String, message: String,
                tint: Color = DFColor.textSecondary,
                @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        VStack(spacing: DFSpace.md) {
            ZStack {
                Circle().fill(tint.opacity(DFOpacity.ghost))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(tint)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(DFFont.title)
                    .foregroundStyle(DFColor.textPrimary)
                Text(message)
                    .font(DFFont.body)
                    .foregroundStyle(DFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DFSpace.lg)
    }
}

// MARK: - DFKeyboardHint

/// 단축키 시각 표시 — ⌘ + K 같은 모양.
public struct DFKeyboardHint: View {
    public let keys: [String]

    public init(_ keys: String...) {
        self.keys = keys
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(DFColor.elev2)
                    .foregroundStyle(DFColor.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.xs)
                            .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: 0.5)
                    )
            }
        }
    }
}

// MARK: - DFPanel — 통일 카드 컨테이너

/// 모든 view 의 카드/패널이 따르는 표준 구조 — Linear / Vercel Geist 영감.
/// header (icon + title + trailing) + content + (optional) footer.
///
/// 4가지 variant + density 옵션으로 화면 맥락에 맞춘다.
public struct DFPanel<Content: View, Trailing: View, Footer: View>: View {
    /// 패널 표면 variant.
    public enum Variant {
        /// 기본 — radius `md`, shadow 없음, 얇은 보더. (Linear/Vercel 표준)
        case regular
        /// 메트릭 카드 — 대시보드 KPI/통계용, height 고정 옵션 활용.
        case metric
        /// 모달/시트 — radius `lg`, shadow 있음, 더 진한 보더.
        case modal
        /// 인라인 — radius `sm`, 작은 카드 (검색결과/list cell 내부).
        case inline
    }

    public let title: String
    public let subtitle: String?
    public let icon: String?
    public let tint: Color
    public let height: CGFloat?
    public let prominent: Bool
    public let variant: Variant
    public let density: DFDensity?
    @ViewBuilder public let trailing: () -> Trailing
    @ViewBuilder public let content: () -> Content
    @ViewBuilder public let footer: () -> Footer

    public init(_ title: String,
                subtitle: String? = nil,
                icon: String? = nil,
                tint: Color = DFColor.textPrimary,
                height: CGFloat? = nil,
                prominent: Bool = false,
                variant: Variant = .regular,
                density: DFDensity? = nil,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
                @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.height = height
        self.prominent = prominent
        self.variant = variant
        self.density = density
        self.trailing = trailing
        self.content = content
        self.footer = footer
    }

    @Environment(\.dfDensity) private var envDensity: DFDensity

    private var resolvedDensity: DFDensity { density ?? envDensity }

    private var radius: CGFloat {
        switch variant {
        case .regular, .metric: return DFRadius.md
        case .modal: return DFRadius.lg
        case .inline: return DFRadius.sm
        }
    }
    private var hasShadow: Bool { variant == .modal }
    private var innerSpacing: CGFloat {
        switch variant {
        case .inline: return DFSpace.xs2
        default: return DFSpace.sm2
        }
    }
    private var innerPadding: CGFloat {
        switch variant {
        case .inline: return DFSpace.sm
        case .modal: return DFSpace.md2
        default: return resolvedDensity.innerPadding
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: innerSpacing) {
            header
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            footer()
        }
        .padding(innerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(prominent ? tint.opacity(0.04) : DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(prominent ? tint.opacity(0.25) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: prominent ? 0.8 : 0.5)
        )
        .shadow(
            color: hasShadow ? DFShadow.modal.color : .clear,
            radius: hasShadow ? DFShadow.modal.radius : 0,
            x: hasShadow ? DFShadow.modal.x : 0,
            y: hasShadow ? DFShadow.modal.y : 0
        )
    }

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 18, height: 18)
                    .background(tint.opacity(DFOpacity.ghost))
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
    }
}

// MARK: - DFMetricRow

/// 카드 내부의 정형 metric 표시 — 라벨 + 값 + 옵션 칩.
public struct DFMetricRow: View {
    public let label: String
    public let value: String
    public let tint: Color
    public let mono: Bool
    public let chip: AnyView?

    public init(_ label: String, _ value: String,
                tint: Color = DFColor.textPrimary,
                mono: Bool = false,
                chip: AnyView? = nil) {
        self.label = label
        self.value = value
        self.tint = tint
        self.mono = mono
        self.chip = chip
    }

    public init<C: View>(_ label: String, _ value: String,
                         tint: Color = DFColor.textPrimary, mono: Bool = false,
                         @ViewBuilder chip: () -> C) {
        self.label = label
        self.value = value
        self.tint = tint
        self.mono = mono
        self.chip = AnyView(chip())
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DFColor.textSecondary)
            Spacer()
            if let chip { chip }
            Text(value)
                .font(.system(size: 12, weight: .semibold,
                              design: mono ? .monospaced : .default))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - DFKeyValueGrid

/// 2열 key-value grid — 정렬 깔끔.
public struct DFKeyValueGrid: View {
    public let items: [(key: String, value: String, tint: Color)]

    public init(_ items: [(String, String, Color)]) {
        self.items = items.map { (key: $0.0, value: $0.1, tint: $0.2) }
    }

    public var body: some View {
        VStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                DFMetricRow(items[i].key, items[i].value, tint: items[i].tint, mono: true)
            }
        }
    }
}

// MARK: - DFPageScaffold — 모든 메뉴 페이지 공통 layout

/// 메뉴 page 의 표준 layout — title bar + content area + (optional) footer.
/// ConversationView / RemoteShellView / ExpertDashboard 모두 동일 frame.
public struct DFPageScaffold<Content: View, Trailing: View, Footer: View>: View {
    public let title: String
    public let subtitle: String?
    public let icon: String?
    public let tint: Color
    @ViewBuilder public let trailing: () -> Trailing
    @ViewBuilder public let content: () -> Content
    @ViewBuilder public let footer: () -> Footer

    public init(_ title: String,
                subtitle: String? = nil,
                icon: String? = nil,
                tint: Color = DFColor.forge,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
                @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.trailing = trailing
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer()
        }
        .background(DFColor.canvas)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: DFSpace.sm) {
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .fill(tint.opacity(0.14))
                            .frame(width: 36, height: 36)
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(DFColor.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                trailing()
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm + 2)
            .background(DFColor.card)
            Divider()
        }
    }
}

// MARK: - DFProgressDots

/// 작은 thinking indicator — 3 dots.
public struct DFProgressDots: View {
    public let tint: Color

    public init(tint: Color = DFColor.accent) {
        self.tint = tint
    }

    @State private var phase: Int = 0

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                phase = (phase + 1) % 3
            }
        }
    }
}
