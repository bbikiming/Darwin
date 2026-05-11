import SwiftUI

// MARK: - Neon palette

/// 네온 톤 토큰. `DFColor`와 호환되며 글로우/하이라이트 전용.
public enum DFNeon {
    /// 시스템 액센트 (cool blue) — primary action.
    public static let accent: Color = DFColor.accent
    /// 브랜드 오렌지 — forge / motion 강조.
    public static let forge:  Color = DFColor.forge
    /// 빨강 — danger / E-Stop.
    public static let danger: Color = DFColor.danger
    /// 초록 — success / safe.
    public static let success: Color = DFColor.success
    /// 정보 / 텔레메트리 (skyblue).
    public static let info:   Color = DFColor.info
    /// 일렉트릭 사이언 — 라이브 데이터 / hover 강조 (네온 시그니처).
    public static let electric = Color(red: 0.40, green: 0.95, blue: 1.00)
    /// 마젠타 — AI / 생성적 액션 (대화·Claude).
    public static let magenta  = Color(red: 1.00, green: 0.30, blue: 0.85)
    /// 라일락 — 토크/모터 시각화 (DFColor.torque alias).
    public static let lilac:  Color = DFColor.torque
}

// MARK: - Glass surface modifier

/// 글래스모피즘 표면 — Material blur + 그라데이션 틴트 + 듀얼 보더.
///
/// 구성:
///   1. `.ultraThinMaterial` 블러 layer
///   2. (옵션) tint 그라데이션 (topLeading → bottomTrailing)
///   3. 상단 sheen (white → clear)
///   4. 듀얼 보더 (white 35% → 6%)
public struct GlassModifier: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let intensity: Double
    let strokeAlpha: Double

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.ultraThinMaterial)
                    if let tint {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        tint.opacity(0.22 * intensity),
                                        tint.opacity(0.04 * intensity)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    RoundedRectangle(cornerRadius: radius)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18 * intensity),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.38 * strokeAlpha),
                                Color.white.opacity(0.06 * strokeAlpha)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Neon glow modifier

/// 네온 외광 — 듀얼 colored shadow + (옵션) 호흡 펄스.
public struct NeonGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat
    let intensity: CGFloat
    let pulsing: Bool

    @State private var pulse: CGFloat = 1.0

    public func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.55 * intensity * pulse),
                    radius: radius * pulse, x: 0, y: 0)
            .shadow(color: color.opacity(0.35 * intensity * pulse),
                    radius: (radius * 0.5) * pulse, x: 0, y: 0)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse = 1.18
                }
            }
    }
}

// MARK: - Public modifier API

public extension View {
    /// 글래스 표면을 적용한다. tint 가 nil 이면 중립 (system material 만).
    func glass(radius: CGFloat = DFRadius.md,
               tint: Color? = nil,
               intensity: Double = 1.0,
               strokeAlpha: Double = 1.0) -> some View {
        modifier(GlassModifier(radius: radius, tint: tint,
                               intensity: intensity, strokeAlpha: strokeAlpha))
    }

    /// 네온 외광 — hover/active 강조용. pulsing 시 호흡 애니메이션.
    func neonGlow(_ color: Color,
                  radius: CGFloat = 12,
                  intensity: CGFloat = 0.7,
                  pulsing: Bool = false) -> some View {
        modifier(NeonGlowModifier(color: color, radius: radius,
                                  intensity: intensity, pulsing: pulsing))
    }

    /// ScrollView 컨테이너에 상하 그라데이션 페이드 + 측면 네온 액센트.
    /// `accent` 가 nil 이면 액센트 라인 없음 (페이드만).
    func glassScroll(accent: Color? = nil,
                     fadeHeight: CGFloat = 18,
                     edgeColor: Color = DFColor.canvas) -> some View {
        self
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [edgeColor, edgeColor.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: fadeHeight)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [edgeColor.opacity(0), edgeColor],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: fadeHeight)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                if let accent {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0),
                                    accent.opacity(0.55),
                                    accent.opacity(0)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: 1.5)
                        .blur(radius: 0.4)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - GlassNeonButtonStyle

/// 글래스 + 네온 결합 버튼 스타일.
///
/// 사용:
///   ```swift
///   Button("연결") { ... }
///       .buttonStyle(.glassNeon(tint: DFColor.accent))
///   ```
///
/// 두 종류:
///   - `prominent: true`  — 채워진 글래스 (primary action). 색 그라데이션 위에 sheen.
///   - `prominent: false` — 투명 글래스 (secondary). hover 시 색 채도 상승.
public struct GlassNeonButtonStyle: ButtonStyle {
    public let tint: Color
    public let prominent: Bool
    public let glow: Bool
    public let height: CGFloat
    public let radius: CGFloat

    public init(tint: Color = DFColor.accent,
                prominent: Bool = true,
                glow: Bool = true,
                height: CGFloat = DFSize.buttonHMedium,
                radius: CGFloat = DFRadius.md) {
        self.tint = tint
        self.prominent = prominent
        self.glow = glow
        self.height = height
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        GlassNeonButtonContent(
            configuration: configuration,
            tint: tint, prominent: prominent, glow: glow,
            height: height, radius: radius
        )
    }
}

private struct GlassNeonButtonContent: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let prominent: Bool
    let glow: Bool
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
                ZStack {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(fillGradient)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(sheenGradient)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(hovering ? 0.50 : 0.32),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(
                color: shadowColor,
                radius: hovering ? 14 : 8, x: 0, y: 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : DFOpacity.disabled)
            .onHover { hovering = $0 }
            .animation(DFAnimation.fast, value: hovering)
            .animation(DFAnimation.fast, value: configuration.isPressed)
    }

    private var textColor: Color {
        prominent ? .white : tint
    }

    private var fillGradient: LinearGradient {
        if prominent {
            return LinearGradient(
                colors: [
                    tint.opacity(hovering ? 0.88 : 0.68),
                    tint.opacity(hovering ? 0.58 : 0.32)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [
                    tint.opacity(hovering ? 0.26 : 0.10),
                    tint.opacity(hovering ? 0.10 : 0.02)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var sheenGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(hovering ? 0.26 : 0.16),
                Color.clear
            ],
            startPoint: .top, endPoint: .center
        )
    }

    private var shadowColor: Color {
        guard glow, isEnabled else { return .clear }
        return tint.opacity(hovering ? 0.55 : 0.22)
    }
}

// MARK: - ButtonStyle convenience

public extension ButtonStyle where Self == GlassNeonButtonStyle {
    /// `.buttonStyle(.glassNeon())` 호출 가능하게 하는 헬퍼.
    static func glassNeon(tint: Color = DFColor.accent,
                          prominent: Bool = true,
                          glow: Bool = true,
                          height: CGFloat = DFSize.buttonHMedium) -> GlassNeonButtonStyle {
        GlassNeonButtonStyle(tint: tint, prominent: prominent,
                             glow: glow, height: height)
    }
}

// MARK: - GlassPill — capsule 변형 (chip / toggle)

/// 글래스 capsule. hover 시 네온 외광.
public struct GlassPillStyle: ButtonStyle {
    public let tint: Color
    public let active: Bool

    public init(tint: Color = DFColor.accent, active: Bool = false) {
        self.tint = tint
        self.active = active
    }

    public func makeBody(configuration: Configuration) -> some View {
        GlassPillContent(configuration: configuration, tint: tint, active: active)
    }
}

private struct GlassPillContent: View {
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
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(on ? 0.70 : 0.10),
                                tint.opacity(on ? 0.35 : 0.02)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color.white.opacity(on ? 0.22 : 0.10), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
                }
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(on ? 0.45 : 0.18), lineWidth: 0.6)
            )
            .shadow(color: tint.opacity(on ? 0.45 : 0.0),
                    radius: on ? 10 : 0, x: 0, y: 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
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
