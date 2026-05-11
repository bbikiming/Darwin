import SwiftUI

// MARK: - Tone palette (legacy 호환)
//
// 본 모듈은 과거 글래스모피즘 + 네온 스타일을 제공했으나, 현재는 플랫(Flat) GUI 로
// 통일됨. API 시그니처는 유지하여 호출 측 코드 변경 없이 자연스럽게 평탄화 표현으로
// 전환된다. 향후 다시 글래스/네온이 필요해지면 본 파일 내부만 교체.

/// 색 토큰 (DFColor 와 호환). `electric` / `magenta` 는 일렉트릭/AI 강조에만 제한 사용.
public enum DFNeon {
    public static let accent:  Color = DFColor.accent
    public static let forge:   Color = DFColor.forge
    public static let danger:  Color = DFColor.danger
    public static let success: Color = DFColor.success
    public static let info:    Color = DFColor.info
    public static let electric = Color(red: 0.10, green: 0.55, blue: 0.85)
    public static let magenta  = Color(red: 0.80, green: 0.24, blue: 0.62)
    public static let lilac:   Color = DFColor.torque
}

// MARK: - Flat surface modifier

/// 플랫 표면 — 단색 배경 + 얇은 단색 보더. blur/gradient/sheen 없음.
public struct GlassModifier: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let intensity: Double
    let strokeAlpha: Double

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(tint?.opacity(0.06 * intensity) ?? DFColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(
                        (tint ?? DFColor.textSecondary).opacity(0.18 * strokeAlpha),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// 플랫 모드에서는 외광을 사용하지 않는다 — modifier 는 no-op 으로 유지.
public struct NeonGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let intensity: CGFloat
    let pulsing: Bool

    public func body(content: Content) -> some View {
        content
    }
}

// MARK: - Public modifier API (시그니처 유지)

public extension View {
    /// 플랫 표면을 적용한다 (구 글래스 API 와 동일 시그니처).
    func glass(radius: CGFloat = DFRadius.md,
               tint: Color? = nil,
               intensity: Double = 1.0,
               strokeAlpha: Double = 1.0) -> some View {
        modifier(GlassModifier(radius: radius, tint: tint,
                               intensity: intensity, strokeAlpha: strokeAlpha))
    }

    /// 플랫 모드에서는 no-op (호출 측 호환성 유지).
    func neonGlow(_ color: Color,
                  radius: CGFloat = 12,
                  intensity: CGFloat = 0.7,
                  pulsing: Bool = false) -> some View {
        modifier(NeonGlowModifier(color: color, radius: radius,
                                  intensity: intensity, pulsing: pulsing))
    }

    /// 스크롤 컨테이너 — 플랫 모드에서는 시각 효과 없음 (호환용).
    func glassScroll(accent: Color? = nil,
                     fadeHeight: CGFloat = 18,
                     edgeColor: Color = DFColor.canvas) -> some View {
        self
    }
}

// MARK: - Flat button style (API 시그니처 유지)

/// 단색 채움 + 얇은 보더 + hover 시 미세 톤 변화. 그라데이션/sheen/외광 없음.
public struct GlassNeonButtonStyle: ButtonStyle {
    public let tint: Color
    public let prominent: Bool
    public let glow: Bool             // 무시됨 (플랫)
    public let height: CGFloat
    public let radius: CGFloat

    public init(tint: Color = DFColor.accent,
                prominent: Bool = true,
                glow: Bool = true,
                height: CGFloat = DFSize.buttonHMedium,
                radius: CGFloat = DFRadius.sm) {
        self.tint = tint
        self.prominent = prominent
        self.glow = glow
        self.height = height
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        FlatButtonContent(
            configuration: configuration,
            tint: tint, prominent: prominent,
            height: height, radius: radius
        )
    }
}

private struct FlatButtonContent: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let prominent: Bool
    let height: CGFloat
    let radius: CGFloat

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .foregroundStyle(textColor)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(borderColor, lineWidth: prominent ? 0 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .opacity(isEnabled ? 1.0 : DFOpacity.disabled)
            .onHover { hovering = $0 }
            .animation(DFAnimation.fast, value: hovering)
            .animation(DFAnimation.fast, value: configuration.isPressed)
    }

    private var textColor: Color {
        prominent ? .white : tint
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            return prominent ? tint.opacity(0.75) : DFColor.elev2.opacity(0.8)
        }
        if hovering {
            return prominent ? tint.opacity(0.88) : DFColor.elev2
        }
        return prominent ? tint : DFColor.card
    }

    private var borderColor: Color {
        prominent ? .clear : DFColor.textSecondary.opacity(0.25)
    }
}

// MARK: - ButtonStyle convenience

public extension ButtonStyle where Self == GlassNeonButtonStyle {
    /// `.buttonStyle(.glassNeon())` 호출 가능하게 하는 헬퍼.
    /// 시그니처 보존 — 내부는 플랫 구현으로 변경됨.
    static func glassNeon(tint: Color = DFColor.accent,
                          prominent: Bool = true,
                          glow: Bool = true,
                          height: CGFloat = DFSize.buttonHMedium) -> GlassNeonButtonStyle {
        GlassNeonButtonStyle(tint: tint, prominent: prominent,
                             glow: glow, height: height)
    }
}

// MARK: - Pill 변형 (toggle/chip)

public struct GlassPillStyle: ButtonStyle {
    public let tint: Color
    public let active: Bool

    public init(tint: Color = DFColor.accent, active: Bool = false) {
        self.tint = tint
        self.active = active
    }

    public func makeBody(configuration: Configuration) -> some View {
        FlatPillContent(configuration: configuration, tint: tint, active: active)
    }
}

private struct FlatPillContent: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let on = active || hovering
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: DFSize.buttonHSmall)
            .foregroundStyle(on ? Color.white : tint)
            .background(
                Capsule().fill(on ? tint : tint.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(tint.opacity(on ? 0 : 0.25), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .onHover { hovering = $0 }
            .animation(DFAnimation.fast, value: hovering)
            .animation(DFAnimation.fast, value: active)
    }
}

public extension ButtonStyle where Self == GlassPillStyle {
    static func glassPill(tint: Color = DFColor.accent, active: Bool = false) -> GlassPillStyle {
        GlassPillStyle(tint: tint, active: active)
    }
}
