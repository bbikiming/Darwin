import AppKit
import CoreGraphics
import Foundation

/// DarwinForge 앱 아이콘 — Core Graphics 로 생성하는 기하학 OP.
///
/// 디자인 컨셉:
/// - 배달의민족 스타일 — 굵고 단순한 글자 윤곽 + 강한 단색 background.
/// - "OP" (Open Platform — DARwIn-OP) 를 두 도형으로 분해:
///   · O = 도넛 (큰 원 - 작은 원)
///   · P = stem(수직 막대) + head(작은 도넛, 위쪽)
/// - Background = forge orange gradient (FF6A00 → FF8A3D, DarwinForge brand).
/// - 외곽 = macOS 표준 rounded square (cornerRadius = canvas × 0.2237, Apple HIG).
///
/// 사용:
/// ```swift
/// NSApp.applicationIconImage = AppIcon.make()
/// ```
public enum AppIcon {

    /// 1024×1024 표준 macOS app icon (Dock + Finder + Spotlight 모두 자동 scale).
    public static func make(size: CGFloat = 1024) -> NSImage {
        let canvas = CGSize(width: size, height: size)
        let image = NSImage(size: canvas)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        // 좌표계 — macOS NSImage 는 bottom-left origin. Core Graphics 와 일치.
        drawBackground(in: ctx, size: canvas)
        drawOPGlyphs(in: ctx, size: canvas)
        return image
    }

    // MARK: - Background

    /// Rounded square + forge orange linear gradient (top-left → bottom-right).
    private static func drawBackground(in ctx: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        // Apple HIG macOS app icon corner radius = 22.37% of canvas (squircle 근사).
        let cornerRadius = size.width * 0.2237
        let bgPath = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()

        // Forge orange gradient — DarwinForge brand.
        let colors: [CGColor] = [
            CGColor(red: 1.00, green: 0.416, blue: 0.000, alpha: 1.0),   // #FF6A00 (forge)
            CGColor(red: 1.00, green: 0.541, blue: 0.239, alpha: 1.0)    // #FF8A3D (lighter)
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),       // top-left
            end:   CGPoint(x: size.width, y: 0),         // bottom-right
            options: []
        )

        // 내부 inner shadow (subtle depth). top-edge darker.
        let innerShadowPath = CGMutablePath()
        innerShadowPath.addPath(bgPath)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
        ctx.setLineWidth(size.width * 0.012)
        ctx.addPath(bgPath)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - OP glyphs (geometric white shapes)

    /// 두 글자 OP — 도넛(O) + stem+head(P). 모두 흰색 단일톤.
    /// 캔버스 1024 기준 비례 좌표 → 다른 size 에서도 동일하게 scale.
    private static func drawOPGlyphs(in ctx: CGContext, size: CGSize) {
        let s = size.width
        let unit = s / 1024.0  // 1024 기준 unit.

        // 글자 영역 — 캔버스 중앙 60% (좌우 20% margin, 상하 25% margin).
        // 가로: 두 글자 + gap. 세로: 약 540pt (high) (1024 의 53%).
        // 두 글자가 합쳐 약 740pt 폭 차지 (캔버스 72%).

        // 흰색 + 약간의 soft shadow 로 깊이.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -8 * unit),
            blur: 16 * unit,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.15)
        )

        // === O (도넛) — 좌측 ===
        // 외경 ø = 400pt, 내경 ø = 200pt (두께 100pt = ø의 25%).
        let oCenter = CGPoint(x: 305 * unit, y: 512 * unit)
        let oOuter = 200 * unit
        let oInner = 100 * unit
        drawDonut(in: ctx, center: oCenter, outerRadius: oOuter, innerRadius: oInner)

        // === P (stem + head) — 우측 ===
        // Stem: 수직 막대 (x=580, y=312~712, 즉 두께 100pt × 높이 400pt).
        // Head: 위쪽 도넛 (head center y = 612, outer ø=260, inner ø=130).
        let pStemX = 580 * unit
        let pStemBottomY = 312 * unit
        let pStemHeight = 400 * unit
        let pStemThickness = 100 * unit

        // P stem — rounded rectangle (bottom rounded for soft termination).
        let stemRect = CGRect(
            x: pStemX,
            y: pStemBottomY,
            width: pStemThickness,
            height: pStemHeight
        )
        let stemPath = CGPath(
            roundedRect: stemRect,
            cornerWidth: pStemThickness * 0.5,
            cornerHeight: pStemThickness * 0.5,
            transform: nil
        )
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
        ctx.addPath(stemPath)
        ctx.fillPath()

        // P head — 위쪽 도넛, stem 의 위 절반과 겹침.
        let pHeadCenter = CGPoint(x: (pStemX + pStemThickness) + 50 * unit, y: 612 * unit)
        let pHeadOuter = 130 * unit
        let pHeadInner = 60 * unit
        drawDonut(in: ctx, center: pHeadCenter, outerRadius: pHeadOuter, innerRadius: pHeadInner)

        ctx.restoreGState()
    }

    /// 도넛 (외경/내경 두 동심원 — even-odd fill rule).
    private static func drawDonut(
        in ctx: CGContext,
        center: CGPoint,
        outerRadius: CGFloat,
        innerRadius: CGFloat
    ) {
        let outerRect = CGRect(
            x: center.x - outerRadius,
            y: center.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        )
        let innerRect = CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )
        let path = CGMutablePath()
        path.addEllipse(in: outerRect)
        path.addEllipse(in: innerRect)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
    }

    // MARK: - PNG export (installer 용)

    /// 지정 크기 PNG data 생성 — iconset 빌드 시 사용.
    public static func pngData(size: CGFloat) -> Data? {
        let image = make(size: size)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }
}
