import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// DarwinForge 워드마크.
///
/// **v1.11.3 (2026-05-18 사용자 SVG 적용)**: wordmark 를 SVG asset 으로 교체.
/// `Resources/Branding/logo-darwinforge-{light,dark}.svg` 를 colorScheme 따라 선택.
/// 종전 SwiftUI Text wordmark ("Darwin" + "Forge") 는 fallback (asset load 실패 시).
/// 마크(헥사곤)는 그대로 Canvas Path 로 그려 폰트 무관 일정.
public struct DarwinForgeLogo: View {
    public enum Variant {
        /// 마크 + 워드마크 (기본). 사이드바 헤더, About 화면.
        case full
        /// 마크 단독. 컴팩트 상태 표시줄, 윈도우 토글 위치.
        case markOnly
        /// 워드마크 단독. 이미 마크가 다른 위치에 있는 경우.
        case wordmarkOnly
    }

    public enum Density {
        case compact
        case standard
        case prominent

        var fontSize: CGFloat {
            switch self {
            case .compact: return 16
            case .standard: return 24
            case .prominent: return 40
            }
        }
    }

    private let variant: Variant
    private let density: Density
    private let showsTagline: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(
        variant: Variant = .full,
        density: Density = .standard,
        showsTagline: Bool = false
    ) {
        self.variant = variant
        self.density = density
        self.showsTagline = showsTagline
    }

    public var body: some View {
        HStack(alignment: .center, spacing: density.fontSize * 0.45) {
            if variant != .wordmarkOnly {
                DarwinForgeMark()
                    .frame(width: markSize, height: markSize)
                    .accessibilityHidden(true)
            }
            if variant != .markOnly {
                VStack(alignment: .leading, spacing: DFSpace.none) {
                    wordmark
                    if showsTagline {
                        Text("다윈-OP 로봇을 위한 통합 작업실")
                            .font(.system(size: density.fontSize * 0.38, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .padding(.top, density.fontSize * 0.12)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DarwinForge")
    }

    /// v1.11.3: SVG wordmark asset. Resources/Branding/logo-darwinforge-{light,dark}.svg.
    /// asset load 실패 시 fallback 으로 종전 Text 기반 wordmark 사용.
    @ViewBuilder
    private var wordmark: some View {
        if let nsImage = wordmarkImage {
            // SVG aspect ratio 1448:292 ≈ 4.96. height = fontSize × 1.0 기준.
            // (종전 Text 보다 약간 크게 표시 — 새 wordmark 의 시각 임팩트 보존).
            let h = density.fontSize * 1.05
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: h)
                .accessibilityHidden(true)
        } else {
            // Fallback: SwiftUI Text wordmark (종전 형태).
            fallbackTextWordmark
        }
    }

    /// asset bundle 에서 colorScheme 별 SVG load.
    ///
    /// V297-11 CRASH FIX: Bundle.module 직접 호출 폐기. 배포 .app 에서 SwiftPM 가
    /// resource bundle 못 찾으면 fatalError 로 앱 강제 종료 (첫 화면 사이드바 로고가
    /// 가장 먼저 호출되어 사용자가 어떤 화면도 못 봄). SafeResourceBundle 가 후보
    /// 경로 순회 후 못 찾으면 nil → fallbackTextWordmark 가 정상 표시.
    private var wordmarkImage: NSImage? {
        #if canImport(AppKit)
        let assetName = colorScheme == .dark
            ? "logo-darwinforge-dark"
            : "logo-darwinforge-light"
        return SafeResourceBundle.image(named: assetName)
        #else
        return nil
        #endif
    }

    private var fallbackTextWordmark: some View {
        HStack(spacing: DFSpace.none) {
            Text("Darwin").foregroundStyle(DarwinForgePalette.body)
            Text("Forge").foregroundStyle(DarwinForgePalette.forge)
        }
        .font(.system(size: density.fontSize, weight: .semibold, design: .default))
        .kerning(-density.fontSize * 0.02)
        .lineLimit(1)
        .fixedSize()
    }

    private var markSize: CGFloat {
        switch density {
        case .compact:   return density.fontSize * 1.10
        case .standard:  return density.fontSize * 1.25
        case .prominent: return density.fontSize * 1.30
        }
    }
}

// MARK: - Mark composite

/// DarwinForge 헥사곤 마크 (슬림 outline + brand blue accent dot).
///
/// **2026-05-16 슬림 재디자인**: 종전 fill 헥사곤 + orange 스파크 → 얇은 stroke
/// 헥사곤 (lineWidth 8) + 우상단 코너 brand blue accent dot. body 채움 제거 —
/// transparency 가 사이드바 배경과 자연스럽게 어울림.
public struct DarwinForgeMark: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 200
            let originX = (size.width  - 200 * scale) / 2
            let originY = (size.height - 200 * scale) / 2

            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: originX + x * scale, y: originY + y * scale)
            }

            // 헥사곤 outline — 작은 inset (4pt) 으로 stroke 가 잘리지 않게 보호.
            var hex = Path()
            hex.move(to: pt(100, 4))
            hex.addLine(to: pt(172, 50))
            hex.addLine(to: pt(172, 150))
            hex.addLine(to: pt(100, 196))
            hex.addLine(to: pt(28,  150))
            hex.addLine(to: pt(28,  50))
            hex.closeSubpath()
            context.stroke(
                hex,
                with: .color(DarwinForgePalette.body),
                style: StrokeStyle(lineWidth: 8 * scale, lineJoin: .round)
            )

            // Brand blue accent dot — 우상단 코너 안쪽 (옛 스파크 위치).
            let dotR: CGFloat = 9 * scale
            let dotCenter = pt(155, 68)
            let dot = Path(ellipseIn: CGRect(
                x: dotCenter.x - dotR,
                y: dotCenter.y - dotR,
                width: dotR * 2,
                height: dotR * 2
            ))
            context.fill(dot, with: .color(DarwinForgePalette.forge))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Palette

/// 로고 컬러 토큰. `body` 는 배경 대비를 자동 조절(라이트=다크 슬레이트, 다크=흰색).
/// `slate` 는 SVG 자산과 1:1 매칭되는 고정값으로 보존하되 in-app 렌더에는 `body` 사용.
public enum DarwinForgePalette {
    /// 로고 본문 컬러 — 시스템 textPrimary 따라 자동 적응 (대비 우선).
    public static let body: Color = DFColor.textPrimary
    /// SVG 자산 고정 슬레이트 (#2E3940) — 라이트 모드 README 등에서 사용.
    public static let slate = Color(red: 46/255,  green: 57/255,  blue: 64/255)
    /// 브랜드 accent — "Forge" 글자 + 헥사곤 accent dot.
    /// 2026-05-16: 하드코딩 orange 제거 → `DFColor.forge` 토큰 위임 (brand blue 자동).
    /// 디자인 시스템 메인 컬러 일관화 — 토큰 변경 시 로고도 자동 정합.
    public static let forge: Color = DFColor.forge
}

#if DEBUG
struct DarwinForgeLogo_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: DFSpace.lg) {
            DarwinForgeLogo(variant: .full, density: .prominent, showsTagline: true)
            DarwinForgeLogo(variant: .full, density: .standard)
            DarwinForgeLogo(variant: .full, density: .compact)
            HStack(spacing: DFSpace.lg) {
                DarwinForgeLogo(variant: .markOnly, density: .prominent)
                DarwinForgeLogo(variant: .wordmarkOnly, density: .prominent)
            }
        }
        .padding(32)
        .background(Color(white: 0.97))
    }
}
#endif
