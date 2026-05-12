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
///
/// # 사용 규칙
/// - **Semantic alias 우선** (`.display`, `.title`, `.body`, `.caption`) — 의도 명확.
/// - **Numeric size (`DFFontSize.s9` ~ `.s28`)** — custom weight / monospaced 가 필요할 때만.
/// - `font.system(size: DFFontSize.s11, weight: .semibold)` 패턴 권장.
public enum DFFont {
    public static let display = Font.system(size: 28, weight: .bold, design: .default)
    public static let title = Font.system(size: 22, weight: .semibold, design: .default)
    public static let subtitle = Font.system(size: 20, weight: .regular, design: .default)
    public static let body = Font.system(size: 13, weight: .regular, design: .default)
    public static let bodyEmph = Font.system(size: 13, weight: .semibold, design: .default)
    public static let caption = Font.system(size: 11, weight: .regular, design: .default)
    public static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

/// 타이포 raw size 토큰 — `font.system(size: ...)` 사용 시 raw 숫자 대신 사용.
///
/// Apple HIG + macOS 본문 / 캡션 / 헤딩 표준 스케일.
public enum DFFontSize {
    /// 8pt — extreme small (load tile indicator — 영문/숫자 전용, 한국어 비추천).
    public static let s8: CGFloat = 8
    /// 9pt — 매우 작은 helper text (한국어 가독 한계).
    public static let s9: CGFloat = 9
    /// 10pt — 작은 helper / tab 라벨.
    public static let s10: CGFloat = 10
    /// 11pt — 캡션 (== DFFont.caption).
    public static let s11: CGFloat = 11
    /// 12pt — pill 라벨 / mono (== DFFont.mono 의 size).
    public static let s12: CGFloat = 12
    /// 13pt — 본문 (== DFFont.body 의 size).
    public static let s13: CGFloat = 13
    /// 14pt — 보조 헤딩 / 강조 본문.
    public static let s14: CGFloat = 14
    /// 16pt — 섹션 헤딩 / 큰 본문.
    public static let s16: CGFloat = 16
    /// 18pt — 작은 카드 제목.
    public static let s18: CGFloat = 18
    /// 20pt — subtitle (== DFFont.subtitle 의 size).
    public static let s20: CGFloat = 20
    /// 22pt — 페이지 제목 (== DFFont.title 의 size).
    public static let s22: CGFloat = 22
    /// 24pt — section heading.
    public static let s24: CGFloat = 24
    /// 26pt — large heading variant.
    public static let s26: CGFloat = 26
    /// 28pt — hero display (== DFFont.display 의 size).
    public static let s28: CGFloat = 28
    /// 32pt — XL display variant.
    public static let s32: CGFloat = 32
}

/// 스페이싱 — Apple HIG 4pt 그리드 (8pt semantic + 4pt interstitial).
///
/// # 사용 규칙
/// 1. 매직 넘버 금지 — 모든 padding/spacing 은 본 토큰 또는 `DFSize.pillPadding*` 사용.
/// 2. semantic (`xs/sm/md/lg`) 우선 — component 의 호흡 의도 표현.
/// 3. interstitial (`xs2/sm2/sm3/md2`) 보조 — 정확한 픽셀 정합이 필요한 곳.
/// 4. raw 0.5/1/2 micro 단위는 border / pixel-perfect 정렬에 한해 허용 — 주석 필수.
///
/// # 명명 컨벤션
/// `xs` < `xs2` < `sm` < `sm2` < `sm3` < `md` < `md2` < `lg` < `xl` < `xxl`
/// 숫자 접미사 (`xs2 = 6`) = "xs(4) 보다 큰 첫 interstitial".
public enum DFSpace {
    public static let none: CGFloat = 0
    /// 1pt — pixel-perfect alignment.
    public static let micro: CGFloat = 1
    /// 2pt — 매우 조밀한 inline gap (badge 내부, super-tight).
    public static let micro2: CGFloat = 2
    /// 4pt — tight grouping (icon ↔ label).
    public static let xs: CGFloat = 4
    /// 6pt — pill vertical padding, 조밀 그룹.
    public static let xs2: CGFloat = 6
    /// 8pt — standard inner spacing (button padding, card inner).
    public static let sm: CGFloat = 8
    /// 10pt — inline gap (toolbar pill 사이).
    public static let sm2: CGFloat = 10
    /// 12pt — pill horizontal padding, 작은 카드 패딩.
    public static let sm3: CGFloat = 12
    /// 16pt — section padding (sidebar 좌·우, card 내부 큰).
    public static let md: CGFloat = 16
    /// 20pt — generous spacing (모달 내부, 큰 카드).
    public static let md2: CGFloat = 20
    /// 24pt — section breathing (페이지 외곽).
    public static let lg: CGFloat = 24
    /// 32pt — hero spacing.
    public static let xl: CGFloat = 32
    /// 48pt — big hero spacing.
    public static let xxl: CGFloat = 48
}

/// 코너 라운드 — Apple HIG + Linear/Vercel Geist 스케일.
///
/// # 사용 규칙
/// - `xs2 (6)` = 버튼 / pill / 작은 인디케이터.
/// - `sm (8)` = 표준 카드.
/// - `md (12)` = 큰 카드 / 패널.
/// - `lg (16)` = 모달 / sheet.
/// - `full` = capsule (height 의 절반 이상).
public enum DFRadius {
    public static let none: CGFloat = 0
    public static let xs: CGFloat = 4
    /// 6pt — 버튼 / pill / 작은 indicator (이전 raw 6 통일).
    public static let xs2: CGFloat = 6
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let full: CGFloat = 999
}

/// 컴포넌트 표준 크기 — 버튼 / 입력 / 인디케이터 / 패널.
///
/// # 사용 규칙
/// - **모든 component 는 본 토큰에서 시작**. 직접 `.frame(width: 5)` 같은 raw 금지.
/// - `pillH / pillPaddingH / pillPaddingV` = toolbar / status pill 표준.
/// - 새 컴포넌트가 기존 토큰과 안 맞으면 본 enum 에 추가 (코드에 분산 금지).
public enum DFSize {
    /// E-Stop 버튼 (ISO 13850 권장 머쉬룸 헤드 ≥40mm — 디지털 환산 56pt).
    public static let estop: CGFloat = 56
    public static let toolbarIcon: CGFloat = 22
    public static let badgeMin: CGFloat = 28

    // MARK: 버튼
    /// 버튼 표준 높이 — small / medium / large.
    public static let buttonHSmall: CGFloat = 24
    public static let buttonHMedium: CGFloat = 30
    public static let buttonHLarge: CGFloat = 40

    // MARK: 입력 / 칩
    /// 입력 필드 표준 높이.
    public static let inputH: CGFloat = 30
    /// 칩 표준 높이.
    public static let chipH: CGFloat = 22

    // MARK: Pill (toolbar / status pill 표준)
    /// pill 컨텐츠 높이 = 24pt (호흡 포함 외곽 ≈ 36pt).
    public static let pillH: CGFloat = 24
    /// pill 좌·우 패딩 (이전 raw 12 통일).
    public static let pillPaddingH: CGFloat = DFSpace.sm3   // 12
    /// pill 상·하 패딩 (이전 raw 6 통일).
    public static let pillPaddingV: CGFloat = DFSpace.xs2   // 6

    // MARK: Indicators (status dot / load tile / phase pixel)
    /// 5pt — 작은 grid indicator (load tile dot).
    public static let indicatorXs: CGFloat = 5
    /// 6pt — phase pixel / small status dot.
    public static let indicatorXxs: CGFloat = 6
    /// 8pt — connection / status circle.
    public static let indicatorSm: CGFloat = 8
    /// 12pt — larger badge dot.
    public static let indicatorMd: CGFloat = 12

    // MARK: Icons (SF Symbol container — `.frame(width: N, height: N)`)
    /// 12pt — 매우 작은 inline icon.
    public static let iconXs: CGFloat = 12
    /// 16pt — 작은 icon (DPad / 인디케이터 hub).
    public static let iconSm: CGFloat = 16
    /// 18pt — 작은 button icon.
    public static let iconSm2: CGFloat = 18
    /// 22pt — 표준 toolbar icon (== `toolbarIcon`).
    public static let iconMd: CGFloat = 22
    /// 24pt — 작은 panel icon.
    public static let iconMd2: CGFloat = 24
    /// 28pt — 중간 badge.
    public static let iconLg: CGFloat = 28
    /// 32pt — 큰 button icon container.
    public static let iconXl: CGFloat = 32
    /// 36pt — 큰 panel icon.
    public static let iconXl2: CGFloat = 36
    /// 48pt — hero icon.
    public static let iconXxl: CGFloat = 48

    // MARK: Sidebar / Panel widths
    /// 사이드바 collapsed 상태 폭.
    public static let sidebarCollapsedW: CGFloat = 28
    /// 보조 사이드바 (torque load 등) 표준 폭.
    public static let secondarySidebarW: CGFloat = 158

    // MARK: Stroke / divider widths
    /// 일반 border (Apple HIG 0.5pt).
    public static let borderHairline: CGFloat = 0.5
    /// 강조 border (focus / selected).
    public static let borderStrong: CGFloat = 1
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

/// 불투명도 토큰 — 일관 dim/disabled/border 처리.
///
/// # 사용 규칙
/// - **Semantic alias 우선** (`.disabled`, `.dim`, `.ghost`, `.subtle`, `.strong`)
///   — 의도가 명확한 곳.
/// - **Numeric (o06 ~ o85)** — semantic 매핑이 없는 정확한 알파값 필요한 곳.
/// - Numeric 명명: `o<percent×100>` (e.g. `o35 = 0.35`).
public enum DFOpacity {
    // MARK: - Semantic
    public static let disabled: Double = 0.4
    public static let dim: Double = 0.6
    /// 거의 안 보임 — background tint (raw 0.06 통일).
    public static let ghost: Double = 0.06
    public static let subtle: Double = 0.12
    public static let strong: Double = 0.35

    // MARK: - Numeric (0.06 ~ 0.85, 5pp 단위)
    public static let o06: Double = 0.06
    public static let o10: Double = 0.10
    public static let o12: Double = 0.12
    public static let o15: Double = 0.15
    public static let o18: Double = 0.18
    public static let o20: Double = 0.20
    public static let o25: Double = 0.25
    public static let o30: Double = 0.30
    public static let o35: Double = 0.35
    public static let o40: Double = 0.40
    public static let o45: Double = 0.45
    public static let o50: Double = 0.50
    public static let o60: Double = 0.60
    public static let o70: Double = 0.70
    public static let o85: Double = 0.85
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

    /// Pill 표준 패딩 — 12pt / 6pt (toolbar pill / status pill).
    ///
    /// 사용:
    /// ```swift
    /// Text("연결됨").dfPillPadding()  // .padding(.horizontal, 12).padding(.vertical, 6)
    /// ```
    func dfPillPadding() -> some View {
        self
            .padding(.horizontal, DFSize.pillPaddingH)
            .padding(.vertical, DFSize.pillPaddingV)
    }

    /// 표준 pill chrome — pill 패딩 + capsule clip + 0.5pt subtle 보더 + tint 배경 opacity.
    ///
    /// active = true 일 때 tint.opacity(0.14) 배경 + tint.opacity(0.35) 보더,
    /// active = false 면 secondary background + 더 흐린 보더.
    /// 디자인 ref: Apple HIG 8pt 그리드 + Linear 미묘 보더 (테두리 12% 알파).
    func dfPill(active: Bool, tint: Color) -> some View {
        self
            .dfPillPadding()
            .background(active ? tint.opacity(0.14) : DFColor.textSecondary.opacity(DFOpacity.ghost))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    active ? tint.opacity(DFOpacity.strong) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                    lineWidth: DFSize.borderHairline
                )
            )
    }

    /// 표준 카드 외곽선 — RoundedRectangle + 0.5pt subtle 보더.
    /// dfCard 안 쓰는 곳 (e.g. clipped 안 한 카드) 에서 사용.
    func dfCardBorder(radius: CGFloat = DFRadius.sm) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline)
        )
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
