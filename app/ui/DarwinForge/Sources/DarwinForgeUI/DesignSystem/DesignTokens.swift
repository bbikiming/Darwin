import SwiftUI

/// DarwinForge 디자인 시스템 — 색상·타이포·스페이싱 토큰.
///
/// 근거: Apple HIG Liquid Glass (macOS 26 — 본 빌드에선 Material 폴백),
/// LiquidGlassReference §1.6 (접근성 자동 적응),
/// NN/g Liquid Glass 비판 (본문엔 솔리드 색상),
/// KS S ISO 7010 안전 색상 (위험=빨강, 주의=노랑, 정보=파랑, 안전=초록).
///
/// 향후 Xcode 26 + macOS 26 SDK 마이그레이션 시 `Material.regularMaterial`을
/// `.glassEffect()`로 자동 교체 가능.
public enum DFColor {
    // MARK: - Surface
    /// 윈도우 배경
    public static let canvas = Color(light: "#F2F2F7", dark: "#1C1C1E")
    /// 카드
    public static let card = Color(light: "#FFFFFF", dark: "#2C2C2E")
    /// nested 카드
    public static let elev2 = Color(light: "#F9F9FB", dark: "#3A3A3C")

    // MARK: - Text
    public static let textPrimary = Color(light: "#1C1C1E", dark: "#FFFFFF")
    public static let textSecondary = Color(light: "#3C3C43", dark: "#EBEBF5").opacity(0.6)

    // MARK: - Accent
    public static let accent = Color(light: "#0A84FF", dark: "#0A84FF")
    /// 브랜드 (로봇 / 모션 강조)
    public static let forge = Color(light: "#FF6A00", dark: "#FF8A3D")

    // MARK: - State (KS S ISO 7010 매핑)
    /// 정상 / 정보 (KS 초록)
    public static let success = Color(light: "#34C759", dark: "#30D158")
    /// 한계 근접 / 주의 (KS 노랑)
    public static let warning = Color(light: "#FF9F0A", dark: "#FFD60A")
    /// 위험 / E-Stop / fault (KS 빨강)
    public static let danger = Color(light: "#FF3B30", dark: "#FF453A")
    /// 텔레메트리 / 정보 (KS 파랑)
    public static let info = Color(light: "#5AC8FA", dark: "#64D2FF")
    /// 토크 / 모터 시각화
    public static let torque = Color(light: "#BF5AF2", dark: "#DA8FFF")
}

/// 타이포 스케일 — Apple HIG Typography 가이드 기반.
public enum DFFont {
    public static let display = Font.system(size: 28, weight: .bold, design: .default)
    public static let title = Font.system(size: 22, weight: .semibold, design: .default)
    public static let subtitle = Font.system(size: 20, weight: .regular, design: .default)
    public static let body = Font.system(size: 13, weight: .regular, design: .default)
    public static let bodyEmph = Font.system(size: 13, weight: .semibold, design: .default)
    public static let caption = Font.system(size: 11, weight: .regular, design: .default)
    public static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

/// 스페이싱 — 8pt 그리드.
public enum DFSpace {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
}

/// 코너 라운드 — Apple HIG + Linear/Vercel Geist 스케일.
public enum DFRadius {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let full: CGFloat = 999
}

/// E-Stop 버튼 사이즈 (ISO 13850 권장 머쉬룸 헤드 ≥40mm — 디지털 환산 56pt).
public enum DFSize {
    public static let estop: CGFloat = 56
    public static let toolbarIcon: CGFloat = 22
    public static let badgeMin: CGFloat = 28
    /// 버튼 표준 높이 — small / medium / large.
    public static let buttonHSmall: CGFloat = 24
    public static let buttonHMedium: CGFloat = 30
    public static let buttonHLarge: CGFloat = 40
    /// 입력 필드 표준 높이.
    public static let inputH: CGFloat = 30
    /// 칩 표준 높이.
    public static let chipH: CGFloat = 22
}

/// Elevation — Material Design 영감 + macOS 톤다운 그림자 단계.
public enum DFShadow {
    public static let none: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (.clear, 0, 0, 0)
    public static let card: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.06), 8, 0, 2)
    public static let popover: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.12), 16, 0, 4)
    public static let modal: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat) =
        (Color.black.opacity(0.24), 28, 0, 8)
}

/// 애니메이션 — 표준 timing.
public enum DFAnimation {
    public static let fast = Animation.easeOut(duration: 0.12)
    public static let standard = Animation.easeOut(duration: 0.22)
    public static let smooth = Animation.spring(response: 0.4, dampingFraction: 0.85)
    public static let bounce = Animation.spring(response: 0.5, dampingFraction: 0.7)
}

/// 불투명도 토큰 — 일관 dim/disabled 처리.
public enum DFOpacity {
    public static let disabled: Double = 0.4
    public static let dim: Double = 0.6
    public static let ghost: Double = 0.08
    public static let subtle: Double = 0.12
    public static let strong: Double = 0.35
}

// MARK: - View modifiers (정형 helper)

public extension View {
    /// 카드 표준 스타일 — corner + border + shadow.
    func dfCard(radius: CGFloat = DFRadius.md, padded: Bool = true,
                shadow: Bool = false) -> some View {
        self
            .padding(padded ? DFSpace.md : 0)
            .background(DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: 0.5)
            )
            .shadow(color: shadow ? DFShadow.card.color : .clear,
                    radius: shadow ? DFShadow.card.radius : 0,
                    x: shadow ? DFShadow.card.x : 0,
                    y: shadow ? DFShadow.card.y : 0)
    }

    /// 디스에이블 시 자연스러운 dim 처리.
    func dfDisabled(_ disabled: Bool) -> some View {
        self
            .opacity(disabled ? DFOpacity.disabled : 1)
            .allowsHitTesting(!disabled)
    }
}

// MARK: - Color helpers (light/dark hex)

private extension Color {
    /// hex 문자열에서 light/dark 분기 색상 생성.
    init(light: String, dark: String) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
                return NSColor(hex: dark) ?? .systemGray
            default:
                return NSColor(hex: light) ?? .systemGray
            }
        })
        #else
        self = Color(hex: light) ?? .gray
        #endif
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

#if canImport(AppKit)
import AppKit
private extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1.0
        )
    }
}
#endif
