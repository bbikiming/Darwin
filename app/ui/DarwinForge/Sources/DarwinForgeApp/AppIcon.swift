import AppKit
import CoreGraphics
import DarwinForgeUI
import Foundation

/// DarwinForge 앱 아이콘 — 2-tier:
///
/// 1. **사용자 지정 PNG 자산** (영구, 우선) — `Bundle.module` 의 `AppIcon.png`
///    (origin: `app/icon/option/ChatGPT Image ... 10_57_32 (1).png`). 사용자
///    명시 변경 전까지 변경 금지.
/// 2. **Core Graphics fallback** (`make()`) — PNG 누락 시 안전망. 슬림 OP outline
///    (두께 30pt) + 단색 brand blue (#0050D5). dev 환경 / PNG 미설치 build
///    에서만 노출.
///
/// 사용:
/// ```swift
/// // 우선 PNG, 없으면 코드 생성.
/// NSApp.applicationIconImage = AppIcon.loadBundledPNG() ?? AppIcon.make()
/// ```
public enum AppIcon {

    /// SwiftPM 번들에 포함된 `AppIcon.png` 가 있으면 우선 로드 — 사용자 지정 자산.
    /// 누락 시 nil → 호출자가 `make()` 로 코드 생성 fallback.
    ///
    /// **2026-05-16 (재복구)**: 사용자 명시 — `option/ChatGPT Image ... 10_57_32 (1).png`
    /// 영구 적용. 사용자 추가 요청 전까지 변경 금지.
    public static func loadBundledPNG() -> NSImage? {
        // V297-11 CRASH FIX: Bundle.module 직접 호출 폐기. SafeResourceBundle 가
        // .app/Contents/Resources/ 표준 위치 + dev 환경 후보 모두 순회.
        guard let url = SafeResourceBundle.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }

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

    /// Rounded square + brand blue 단색.
    ///
    /// **2026-05-16**: gradient 제거 (심플), 색상 통일 (forge brand blue #0050D5).
    /// 단색은 작은 크기 (16pt Dock 미니어처) 에서도 인지성 우수.
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

        // Brand blue 단색 — DFColor.forge (#0050D5) 와 정합.
        ctx.setFillColor(CGColor(red: 0.000, green: 0.314, blue: 0.835, alpha: 1.0))
        ctx.fill(rect)

        // 매우 미묘한 top-edge inner highlight — depth 단서.
        let highlight = CGColor(red: 1, green: 1, blue: 1, alpha: 0.08)
        ctx.setStrokeColor(highlight)
        ctx.setLineWidth(size.width * 0.006)
        ctx.addPath(bgPath)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - OP glyphs (slim outline strokes)

    /// 두 글자 OP — 모두 흰색 thin stroke. 1024 기준 두께 30pt (기존 100pt → 1/3 슬림).
    /// 비례 좌표 → 다른 size 에서도 동일하게 scale.
    private static func drawOPGlyphs(in ctx: CGContext, size: CGSize) {
        let s = size.width
        let unit = s / 1024.0
        let stroke = 30 * unit
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1.0)

        ctx.saveGState()
        // Subtle shadow — depth + crispness on bright background.
        ctx.setShadow(
            offset: CGSize(width: 0, height: -3 * unit),
            blur: 6 * unit,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.12)
        )

        // === O (얇은 도넛) — 좌측 ===
        // 외경 ø=280pt → r=140, 두께 30pt → 내경 ø=220pt r=110.
        let oCenter = CGPoint(x: 345 * unit, y: 512 * unit)
        let oRadius = 140 * unit
        strokeRing(in: ctx, center: oCenter, outerRadius: oRadius, thickness: stroke, color: white)

        // === P (얇은 stem + thin head ring) — 우측 ===
        // Stem: 수직 막대 (두께 30pt × 높이 280pt). pStem center x = 540.
        // Head ring: 외경 ø=140pt r=70, 두께 30pt → 내경 ø=80pt r=40.
        let pStemX: CGFloat = 540 * unit
        let pStemBottomY: CGFloat = 372 * unit
        let pStemHeight: CGFloat = 280 * unit

        // P stem — rounded rectangle (양 끝 rounded).
        let stemRect = CGRect(
            x: pStemX,
            y: pStemBottomY,
            width: stroke,
            height: pStemHeight
        )
        let stemPath = CGPath(
            roundedRect: stemRect,
            cornerWidth: stroke * 0.5,
            cornerHeight: stroke * 0.5,
            transform: nil
        )
        ctx.setFillColor(white)
        ctx.addPath(stemPath)
        ctx.fillPath()

        // P head — stem 위쪽과 자연스럽게 결합. center x = stem 우측 + 우반경.
        let pHeadCenter = CGPoint(
            x: pStemX + stroke + 70 * unit,
            y: pStemBottomY + pStemHeight - 70 * unit
        )
        strokeRing(in: ctx, center: pHeadCenter, outerRadius: 70 * unit, thickness: stroke, color: white)

        ctx.restoreGState()
    }

    /// 동심원 도넛 — 외경/내경 (= 외경 - thickness×2) 두 ring.
    /// even-odd fill rule 로 가운데 hole.
    private static func strokeRing(
        in ctx: CGContext,
        center: CGPoint,
        outerRadius: CGFloat,
        thickness: CGFloat,
        color: CGColor
    ) {
        let innerRadius = max(0, outerRadius - thickness)
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
        ctx.setFillColor(color)
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
