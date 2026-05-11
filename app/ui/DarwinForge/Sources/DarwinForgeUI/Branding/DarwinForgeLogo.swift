import SwiftUI

/// DarwinForge 워드마크.
///
/// `docs/assets/logo-darwinforge.svg`와 동일한 비주얼을 SwiftUI 네이티브로 재현한다.
/// 마크(헥사곤 + 스파크)는 Path로 그려 폰트와 무관하게 일정. 워드마크는 시스템 폰트
/// 기반이라 macOS에서 SF Pro로 자동 매핑된다.
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
                VStack(alignment: .leading, spacing: 0) {
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

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Darwin").foregroundStyle(DarwinForgePalette.slate)
            Text("Forge").foregroundStyle(DarwinForgePalette.forge)
        }
        .font(.system(size: density.fontSize, weight: .black, design: .default))
        .kerning(-density.fontSize * 0.04)
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

/// DarwinForge 헥사곤 마크 (슬레이트 본체 + forge-orange 스파크).
///
/// 본체와 스파크를 `Canvas`로 같은 좌표계에 그려 정확한 정렬을 보장한다.
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

            var hex = Path()
            hex.move(to: pt(100, 0))
            hex.addLine(to: pt(175, 50))
            hex.addLine(to: pt(175, 150))
            hex.addLine(to: pt(100, 200))
            hex.addLine(to: pt(25,  150))
            hex.addLine(to: pt(25,  50))
            hex.closeSubpath()
            context.fill(hex, with: .color(DarwinForgePalette.slate))

            var spark = Path()
            spark.move(to: pt(175, 50))
            spark.addLine(to: pt(175, 100))
            spark.addLine(to: pt(130, 68))
            spark.closeSubpath()
            context.fill(spark, with: .color(DarwinForgePalette.forge))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Palette

/// SVG 자산과 1:1 매칭. `DFColor.slate` / `DFColor.forge`와 동일.
public enum DarwinForgePalette {
    public static let slate = Color(red: 46/255,  green: 57/255,  blue: 64/255)
    public static let forge = Color(red: 233/255, green: 113/255, blue: 50/255)
}

#if DEBUG
struct DarwinForgeLogo_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 24) {
            DarwinForgeLogo(variant: .full, density: .prominent, showsTagline: true)
            DarwinForgeLogo(variant: .full, density: .standard)
            DarwinForgeLogo(variant: .full, density: .compact)
            HStack(spacing: 24) {
                DarwinForgeLogo(variant: .markOnly, density: .prominent)
                DarwinForgeLogo(variant: .wordmarkOnly, density: .prominent)
            }
        }
        .padding(32)
        .background(Color(white: 0.97))
    }
}
#endif
