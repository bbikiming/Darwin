import AppKit
import Foundation

/// HSV preset — Sprint 18 Phase E (Codex 잔여 3 v1.5).
///
/// `MultiColorVision.defaultRange` 의 하드코딩 값 대신 사용자가 조정 가능한 preset.
/// 4가지 색 (orange / red / yellow / blue) 각각 4개 파라미터 (hue / tolerance / minSat / minVal).
///
/// **source 추적** — UI 의 source badge 용:
///   - `.macDefault` (ROBOTIS main.cpp:65-90 그대로)
///   - `.robotSynced` (robot 측 config.ini 에서 로드)
///   - `.modifiedLocally` (Mac UI 에서 수정 후 robot 미반영)
///   - `.robotMismatch` (robot 측이 변경됐고 Mac 과 다름)
public struct VisionHsvPreset: Codable, Equatable, Sendable {
    public var orange: MultiColorVision.HSVRange
    public var red: MultiColorVision.HSVRange
    public var yellow: MultiColorVision.HSVRange
    public var blue: MultiColorVision.HSVRange
    public var source: Source
    /// 마지막 robot sync 시각 (robotSynced / robotMismatch 일 때만 의미).
    public var lastRobotSyncAt: Date?

    public enum Source: String, Codable, Sendable, Equatable {
        case macDefault
        case robotSynced
        case modifiedLocally
        case robotMismatch
    }

    public init(orange: MultiColorVision.HSVRange,
                red: MultiColorVision.HSVRange,
                yellow: MultiColorVision.HSVRange,
                blue: MultiColorVision.HSVRange,
                source: Source = .macDefault,
                lastRobotSyncAt: Date? = nil) {
        self.orange = orange
        self.red = red
        self.yellow = yellow
        self.blue = blue
        self.source = source
        self.lastRobotSyncAt = lastRobotSyncAt
    }

    /// ROBOTIS main.cpp:65-90 의 default ColorFinder 인자.
    public static let macDefault: VisionHsvPreset = VisionHsvPreset(
        orange: MultiColorVision.defaultRange(for: .orange),
        red:    MultiColorVision.defaultRange(for: .red),
        yellow: MultiColorVision.defaultRange(for: .yellow),
        blue:   MultiColorVision.defaultRange(for: .blue),
        source: .macDefault
    )

    /// 한 tag 의 HSV 범위 가져오기.
    public func range(for tag: MultiColorVision.Tag) -> MultiColorVision.HSVRange {
        switch tag {
        case .orange: return orange
        case .red:    return red
        case .yellow: return yellow
        case .blue:   return blue
        }
    }

    /// 한 tag 의 HSV 범위 변경 — source 가 modifiedLocally 로 전환.
    public mutating func setRange(_ range: MultiColorVision.HSVRange, for tag: MultiColorVision.Tag) {
        switch tag {
        case .orange: orange = range
        case .red:    red = range
        case .yellow: yellow = range
        case .blue:   blue = range
        }
        // 변경되면 source 추적.
        if source == .robotSynced || source == .macDefault {
            source = .modifiedLocally
        }
        // robotMismatch 는 사용자가 명시적으로 의도한 상태라 유지.
    }
}

extension MultiColorVision.HSVRange: Codable {
    enum CodingKeys: String, CodingKey {
        case hueCenterDeg, hueToleranceDeg
        case minSaturationPct, minValuePct
        case minPercent, maxPercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hueCenterDeg: try c.decode(Double.self, forKey: .hueCenterDeg),
            hueToleranceDeg: try c.decode(Double.self, forKey: .hueToleranceDeg),
            minSaturationPct: try c.decode(Double.self, forKey: .minSaturationPct),
            minValuePct: try c.decode(Double.self, forKey: .minValuePct),
            minPercent: try c.decodeIfPresent(Double.self, forKey: .minPercent) ?? 0.1,
            maxPercent: try c.decodeIfPresent(Double.self, forKey: .maxPercent) ?? 50.0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hueCenterDeg, forKey: .hueCenterDeg)
        try c.encode(hueToleranceDeg, forKey: .hueToleranceDeg)
        try c.encode(minSaturationPct, forKey: .minSaturationPct)
        try c.encode(minValuePct, forKey: .minValuePct)
        try c.encode(minPercent, forKey: .minPercent)
        try c.encode(maxPercent, forKey: .maxPercent)
    }
}

/// `detectAll` 의 preset overload.
public extension MultiColorVision {
    /// Preset 기반 multi-color 검출 — UI 가 사용자 HSV 조정 결과를 사용.
    @MainActor
    static func detectAll(in image: NSImage,
                          preset: VisionHsvPreset,
                          maxDimension: Int = 256,
                          tags: [Tag] = Tag.allCases) -> [Detection] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return detectAll(in: cg, preset: preset, maxDimension: maxDimension, tags: tags)
    }

    static func detectAll(in image: CGImage,
                          preset: VisionHsvPreset,
                          maxDimension: Int = 256,
                          tags: [Tag] = Tag.allCases) -> [Detection] {
        // 기존 detectAll 의 default 대신 preset 의 range 사용.
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return [] }
        let scale = min(1.0, Double(maxDimension) / Double(max(srcW, srcH)))
        let dstW = max(1, Int(Double(srcW) * scale))
        let dstH = max(1, Int(Double(srcH) * scale))

        guard let pixels = rgbaBufferInternal(image: image, width: dstW, height: dstH) else {
            return []
        }

        // Phase F1 — ROBOTIS GetPosition: mask → erode → dilate → percent gate → centroid.
        var masks: [Tag: [UInt8]] = [:]
        for t in tags {
            masks[t] = [UInt8](repeating: 0, count: dstW * dstH)
        }
        for y in 0..<dstH {
            for x in 0..<dstW {
                let pi = y * dstW + x
                let i = pi * 4
                let r = Double(pixels[i]) / 255.0
                let g = Double(pixels[i+1]) / 255.0
                let b = Double(pixels[i+2]) / 255.0
                let (h, s, v) = rgbToHsv(r: r, g: g, b: b)
                for t in tags {
                    if preset.range(for: t).matches(h: h, s: s, v: v) {
                        masks[t]![pi] = 1
                    }
                }
            }
        }

        let totalPixels = Double(dstW * dstH)
        return tags.compactMap { tag -> Detection? in
            guard var mask = masks[tag] else { return nil }
            Morphology.openingInPlace(mask: &mask, width: dstW, height: dstH)

            var sumX: UInt64 = 0, sumY: UInt64 = 0, count: UInt32 = 0
            for y in 0..<dstH {
                for x in 0..<dstW {
                    if mask[y * dstW + x] != 0 {
                        sumX &+= UInt64(x); sumY &+= UInt64(y); count &+= 1
                    }
                }
            }
            guard count > 0 else { return nil }
            let percent = Double(count) / totalPixels * 100.0
            let r = preset.range(for: tag)
            guard percent >= r.minPercent && percent <= r.maxPercent else { return nil }
            let cx = Double(sumX) / Double(count)
            let cy = Double(sumY) / Double(count)
            let radiusPx = (Double(count) / .pi).squareRoot()
            let radiusN = CGFloat(radiusPx / Double(max(dstW, dstH)))
            return Detection(
                tag: tag,
                centroidNormalized: CGPoint(x: cx / Double(dstW), y: cy / Double(dstH)),
                pixelCount: Int(count),
                approximateRadiusNormalized: max(0.02, min(0.4, radiusN))
            )
        }
    }

    /// rgbaBuffer 의 internal access — overload 가 같은 helper 사용.
    private static func rgbaBufferInternal(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let ok: Bool = pixels.withUnsafeMutableBytes { rawPtr -> Bool in
            guard let base = rawPtr.baseAddress else { return false }
            guard let ctx = CGContext(data: base, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                       space: colorSpace, bitmapInfo: bitmapInfo) else {
                return false
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}
