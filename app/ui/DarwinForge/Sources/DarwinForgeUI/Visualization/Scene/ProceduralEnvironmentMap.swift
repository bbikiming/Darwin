import CoreGraphics
import SwiftUI

/// 절차적 IBL 환경맵 — 코드로 생성하는 128×64 equirectangular 그라디언트.
///
/// **W1 (2026-06-11)**: PBR 머티리얼은 `lightingEnvironment` 없이는 금속이 검게 죽고
/// 형태감이 사라진다. HDR 에셋 번들 대신 코드로 천정→수평선→바닥 그라디언트 +
/// 소프트박스 가우시안 패치 2개를 그려 `scene.lightingEnvironment.contents` 에 주입.
///
/// 8bit RGBA 로 충분(헤드룸이 더 필요하면 Float16 raw buffer 로 승격). 패치 코어는
/// 휘도 >1 이라 255 로 클램프되며, 이 클램프된 하이라이트가 금속/clearcoat 의
/// 형태감을 만든다(절차적 IBL 이 번들 HDR 대비 밋밋해지는 약점 상쇄).
///
/// preset 별 1회 생성 후 static 캐시(W2 에서 preset tint 소비).
enum ProceduralEnvironmentMap {

    /// equirectangular 해상도 — 작게 유지(수십 KB). 순금속이 얼룩지지 않는 하한.
    static let width = 128
    static let height = 64

    /// 소프트박스 패치 — (방위각°, 고도°, 휘도, σ°).
    struct LightPatch {
        let azimuthDeg: Double
        let elevationDeg: Double
        let luminance: Double
        let sigmaDeg: Double
    }

    /// 기본(studio) 무드 — key 좌상 + fill.
    static let studioKeyPatch = LightPatch(azimuthDeg: -45, elevationDeg: 50,
                                           luminance: 2.5, sigmaDeg: 12)
    static let studioFillPatch = LightPatch(azimuthDeg: 120, elevationDeg: 25,
                                            luminance: 1.4, sigmaDeg: 16)

    /// 기본 studio 환경맵 — 1회 생성 후 캐시.
    static let studio: CGImage = make(
        zenith: NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.00, alpha: 1).scaled(1.15),
        horizon: NSColor(calibratedRed: 0.52, green: 0.55, blue: 0.60, alpha: 1),
        ground: NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),
        patches: [studioKeyPatch, studioFillPatch]
    )

    /// Cockpit(FPV) 무드 — teal tint. 1회 생성 후 캐시(W1 1-E).
    static let cockpit: CGImage = make(
        zenith: NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.92, alpha: 1),
        horizon: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.26, alpha: 1),
        ground: NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.09, alpha: 1),
        patches: [studioKeyPatch, studioFillPatch]
    )

    /// equirectangular 그라디언트 + 패치 → CGImage.
    static func make(zenith: NSColor,
                     horizon: NSColor,
                     ground: NSColor,
                     patches: [LightPatch]) -> CGImage {
        let zen = zenith.rgbTuple
        let hor = horizon.rgbTuple
        let gnd = ground.rgbTuple

        // 패치 방향 단위벡터 사전 계산.
        let patchDirs: [(x: Double, y: Double, z: Double, lum: Double, twoSigma2: Double)] =
            patches.map { p in
                let elev = p.elevationDeg * .pi / 180.0
                let azim = p.azimuthDeg * .pi / 180.0
                let theta = .pi / 2.0 - elev
                let dir = unitVector(theta: theta, phi: azim)
                let sigma = p.sigmaDeg * .pi / 180.0
                return (dir.x, dir.y, dir.z, p.luminance, 2.0 * sigma * sigma)
            }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)

        for v in 0..<height {
            let theta = (Double(v) + 0.5) / Double(height) * .pi      // 0 천정 → π 바닥
            // 그라디언트 base.
            let base: (r: Double, g: Double, b: Double)
            if theta < .pi / 2.0 {
                let t = theta / (.pi / 2.0)
                base = lerp(zen, hor, t)
            } else {
                let t = (theta - .pi / 2.0) / (.pi / 2.0)
                base = lerp(hor, gnd, t)
            }
            for u in 0..<width {
                let phi = (Double(u) + 0.5) / Double(width) * 2.0 * .pi
                let dir = unitVector(theta: theta, phi: phi)

                var r = base.r, g = base.g, b = base.b
                for p in patchDirs {
                    let dot = max(-1.0, min(1.0, dir.x * p.x + dir.y * p.y + dir.z * p.z))
                    let ang = acos(dot)
                    let contrib = p.lum * exp(-(ang * ang) / p.twoSigma2)
                    r += contrib; g += contrib; b += contrib
                }

                let idx = (v * width + u) * 4
                buffer[idx + 0] = clamp8(r)
                buffer[idx + 1] = clamp8(g)
                buffer[idx + 2] = clamp8(b)
                buffer[idx + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(buffer) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    // MARK: - math helpers

    private static func unitVector(theta: Double, phi: Double) -> (x: Double, y: Double, z: Double) {
        let st = sin(theta)
        return (x: st * cos(phi), y: cos(theta), z: st * sin(phi))
    }

    private static func lerp(_ a: (r: Double, g: Double, b: Double),
                             _ b: (r: Double, g: Double, b: Double),
                             _ t: Double) -> (r: Double, g: Double, b: Double) {
        (r: a.r + (b.r - a.r) * t,
         g: a.g + (b.g - a.g) * t,
         b: a.b + (b.b - a.b) * t)
    }

    private static func clamp8(_ v: Double) -> UInt8 {
        UInt8(max(0.0, min(1.0, v)) * 255.0 + 0.5)
    }
}

// MARK: - NSColor helpers

private extension NSColor {
    /// sRGB 0–1 튜플 (calibrated/device 공간 안전 변환).
    var rgbTuple: (r: Double, g: Double, b: Double) {
        let c = usingColorSpace(.deviceRGB) ?? self
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// 휘도 스케일(클램프는 호출자/렌더에서).
    func scaled(_ factor: CGFloat) -> NSColor {
        let c = usingColorSpace(.deviceRGB) ?? self
        return NSColor(calibratedRed: min(1, c.redComponent * factor),
                       green: min(1, c.greenComponent * factor),
                       blue: min(1, c.blueComponent * factor),
                       alpha: 1)
    }
}
