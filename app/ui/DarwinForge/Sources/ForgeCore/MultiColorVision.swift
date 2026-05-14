import AppKit
import Foundation

/// 다색 HSV blob 검출기 — ROBOTIS demo 의 `ColorFinder` 정책을 Swift 측에서 동일 재현.
///
/// **출처**: DARwIn-OP_ROBOTIS_v1.6.0/Linux/project/demo/main.cpp:65-90 에서 등록된 4개 색.
/// 각 색의 hue / hue_tolerance / min_saturation / min_value 가 ROBOTIS `config.ini`
/// 의 기본값과 동일. ini 파일을 사용자가 수정한 경우는 동기화 안 됨 — 미세 차이.
///
/// **차별점**: 단일 색 `BallVision` (forge-core FFI) 와 별개로, Mac 측에서 자체 HSV 마스킹.
/// 4가지 색을 한 frame 에서 동시 검출 → HUD overlay 에 동시 표시 가능.
public enum MultiColorVision {

    /// ROBOTIS official 4색 — main.cpp 의 `ColorFinder` 생성자 + ini 기본값.
    public enum Tag: String, CaseIterable, Sendable, Identifiable {
        case orange  // ball — main.cpp:65 `ColorFinder* ball_finder = new ColorFinder();`
        case red     // RED   — main.cpp:74 `new ColorFinder(0,   15, 45, 0, 0.3, 50.0);`
        case yellow  // YELLOW — main.cpp:78 `new ColorFinder(60,  15, 45, 0, 0.3, 50.0);`
        case blue    // BLUE   — main.cpp:82 `new ColorFinder(225, 15, 45, 0, 0.3, 50.0);`

        public var id: String { rawValue }

        /// 사용자에게 표시할 한국어 라벨.
        public var label: String {
            switch self {
            case .orange: return "주황 (공)"
            case .red:    return "빨강"
            case .yellow: return "노랑"
            case .blue:   return "파랑"
            }
        }

        /// HUD overlay 의 원 색 — 검출한 색 자체로 표시.
        public var displayColor: NSColor {
            switch self {
            case .orange: return NSColor(red: 1.0,  green: 0.55, blue: 0.0, alpha: 1)
            case .red:    return NSColor(red: 1.0,  green: 0.15, blue: 0.15, alpha: 1)
            case .yellow: return NSColor(red: 1.0,  green: 0.9,  blue: 0.0, alpha: 1)
            case .blue:   return NSColor(red: 0.2,  green: 0.55, blue: 1.0, alpha: 1)
            }
        }
    }

    /// HSV 범위 + 검출 픽셀 비율 게이트 — `ColorFinder.h:106-111` 완전 충실.
    ///
    /// **스케일 (Phase F1, 2026-05-14 firmware-reference/05-vision-pipeline.md 검증)**:
    ///   - `hueCenterDeg`: 0-360 (int)
    ///   - `hueToleranceDeg`: 0-180
    ///   - `minSaturationPct`: **0-100 정수 스케일** (ROBOTIS ColorFinder.h:108)
    ///   - `minValuePct`: **0-100 정수 스케일** (ColorFinder.h:109)
    ///   - `minPercent` / `maxPercent`: 검출 픽셀 비율 게이트, 0.0-100.0 (ColorFinder.h:110-111)
    ///
    /// **이전 v1.5 ~ Phase E 의 0-1 normalized 스케일은 ROBOTIS factory 와 호환 안 됨** —
    /// robot ini 의 `min_saturation = 60` 을 0.6 으로 잘못 변환했었음. Phase F1 에서 정정.
    public struct HSVRange: Equatable, Sendable {
        public let hueCenterDeg: Double
        public let hueToleranceDeg: Double
        /// 0-100 정수 스케일 (ROBOTIS 호환). matches() 가 내부적으로 ÷100 으로 비교.
        public let minSaturationPct: Double
        /// 0-100 정수 스케일 (ROBOTIS 호환).
        public let minValuePct: Double
        /// 검출 픽셀 비율 게이트 (lower). 0.0-100.0. ROBOTIS ColorFinder.h:110.
        public let minPercent: Double
        /// 검출 픽셀 비율 게이트 (upper). 0.0-100.0. ColorFinder.h:111. 너무 큰 blob (배경 등) reject.
        public let maxPercent: Double

        public init(hueCenterDeg: Double, hueToleranceDeg: Double,
                    minSaturationPct: Double, minValuePct: Double,
                    minPercent: Double = 0.1, maxPercent: Double = 50.0) {
            self.hueCenterDeg = hueCenterDeg
            self.hueToleranceDeg = hueToleranceDeg
            self.minSaturationPct = minSaturationPct
            self.minValuePct = minValuePct
            self.minPercent = minPercent
            self.maxPercent = maxPercent
        }

        // 호환성: 이전 0-1 scale API — 자동 변환.
        @available(*, deprecated, message: "Use minSaturationPct (0-100). Phase F1.")
        public var minSaturation: Double { minSaturationPct / 100.0 }
        @available(*, deprecated, message: "Use minValuePct (0-100). Phase F1.")
        public var minValue: Double { minValuePct / 100.0 }

        /// 색깔 hue 가 범위 안인지 (wrap-around 처리 포함).
        /// `s` 와 `v` 는 **0-1 정규화 입력** (rgbToHsv 결과 그대로). 내부에서 0-100 임계와 비교.
        public func matches(h: Double, s: Double, v: Double) -> Bool {
            if (s * 100) < minSaturationPct { return false }
            if (v * 100) < minValuePct { return false }
            let lo = hueCenterDeg - hueToleranceDeg
            let hi = hueCenterDeg + hueToleranceDeg
            // hue 가 0..360 wrap 처리 — ColorFinder.cpp:51-82 정확 재현.
            let nh = h.truncatingRemainder(dividingBy: 360)
            let nhPositive = nh < 0 ? nh + 360 : nh
            if lo < 0 {
                return nhPositive >= (lo + 360) || nhPositive <= hi
            }
            if hi > 360 {
                return nhPositive >= lo || nhPositive <= (hi - 360)
            }
            return nhPositive >= lo && nhPositive <= hi
        }
    }

    /// ROBOTIS 공식 factory defaults — `Linux/project/demo/main.cpp:76-86` 정확 재현
    /// (firmware-reference/05-vision-pipeline.md Section "Factory color thresholds").
    public static func defaultRange(for tag: Tag) -> HSVRange {
        switch tag {
        // ball_finder: ColorFinder() default constructor = (hue=356, tol=15, sat=50, val=10, pct 0.07-30.0)
        //              ColorFinder.cpp:15-25 member init.
        // 단, tutorial/color_filtering/config.ini 는 hue=355, sat=60, val=15, pct 0.1-50.
        // 두 값 중 데모 코드 fallback (356) 보다 tutorial ini (355) 가 더 일반적 — 355 채택.
        case .orange:
            return HSVRange(hueCenterDeg: 355, hueToleranceDeg: 15,
                            minSaturationPct: 60, minValuePct: 15,
                            minPercent: 0.1, maxPercent: 50.0)
        // red/yellow/blue 는 main.cpp:79-86 의 ColorFinder() 인자 그대로.
        case .red:
            return HSVRange(hueCenterDeg: 0, hueToleranceDeg: 15,
                            minSaturationPct: 45, minValuePct: 0,
                            minPercent: 0.3, maxPercent: 50.0)
        case .yellow:
            return HSVRange(hueCenterDeg: 60, hueToleranceDeg: 15,
                            minSaturationPct: 45, minValuePct: 0,
                            minPercent: 0.3, maxPercent: 50.0)
        case .blue:
            return HSVRange(hueCenterDeg: 225, hueToleranceDeg: 15,
                            minSaturationPct: 45, minValuePct: 0,
                            minPercent: 0.3, maxPercent: 50.0)
        }
    }

    /// 한 색에 대한 검출 결과.
    public struct Detection: Equatable, Sendable, Identifiable {
        public let tag: Tag
        public let centroidNormalized: CGPoint
        public let pixelCount: Int
        public let approximateRadiusNormalized: CGFloat

        public var id: String { tag.rawValue }
        public var isDetected: Bool { pixelCount > 0 }

        public init(tag: Tag, centroidNormalized: CGPoint, pixelCount: Int,
                    approximateRadiusNormalized: CGFloat) {
            self.tag = tag
            self.centroidNormalized = centroidNormalized
            self.pixelCount = pixelCount
            self.approximateRadiusNormalized = approximateRadiusNormalized
        }
    }

    /// `NSImage` 에서 4색 동시 검출 — 각 색에 대해 매칭 픽셀 centroid + count.
    /// pixelCount 가 임계 (총 픽셀의 0.1%) 보다 작은 경우는 noise 로 간주, isDetected = false.
    @MainActor
    public static func detectAll(in image: NSImage,
                                 maxDimension: Int = 256,
                                 tags: [Tag] = Tag.allCases) -> [Detection] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        return detectAll(in: cg, maxDimension: maxDimension, tags: tags)
    }

    public static func detectAll(in image: CGImage,
                                 maxDimension: Int = 256,
                                 tags: [Tag] = Tag.allCases) -> [Detection] {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return [] }
        let scale = min(1.0, Double(maxDimension) / Double(max(srcW, srcH)))
        let dstW = max(1, Int(Double(srcW) * scale))
        let dstH = max(1, Int(Double(srcH) * scale))
        guard let pixels = rgbaBuffer(image: image, width: dstW, height: dstH) else {
            return []
        }

        let ranges: [Tag: HSVRange] = Dictionary(uniqueKeysWithValues:
            tags.map { ($0, defaultRange(for: $0)) })

        // Phase F1 (firmware-reference 05-vision-pipeline.md):
        // ROBOTIS GetPosition 의 정식 흐름 — mask 생성 → 3×3 erode → 3×3 dilate → centroid.
        // 이전 v1.5/Phase E 는 mask 없이 한 loop 에서 centroid 누적 — opening 효과 없어 noise 영향.
        var masks: [Tag: [UInt8]] = [:]
        for t in tags {
            masks[t] = [UInt8](repeating: 0, count: dstW * dstH)
        }

        // Pass 1 — HSV mask 생성. O(w*h * n_tags).
        for y in 0..<dstH {
            for x in 0..<dstW {
                let pi = y * dstW + x
                let i = pi * 4
                let r = Double(pixels[i]) / 255.0
                let g = Double(pixels[i+1]) / 255.0
                let b = Double(pixels[i+2]) / 255.0
                let (h, s, v) = rgbToHsv(r: r, g: g, b: b)
                for t in tags {
                    if ranges[t]!.matches(h: h, s: s, v: v) {
                        masks[t]![pi] = 1
                    }
                }
            }
        }

        // Pass 2 — opening (erode → dilate) 후 centroid + percent gate.
        let totalPixels = Double(dstW * dstH)
        return tags.compactMap { tag -> Detection? in
            guard var mask = masks[tag] else { return nil }
            Morphology.openingInPlace(mask: &mask, width: dstW, height: dstH)

            var sumX: UInt64 = 0, sumY: UInt64 = 0, count: UInt32 = 0
            for y in 0..<dstH {
                for x in 0..<dstW {
                    if mask[y * dstW + x] != 0 {
                        sumX &+= UInt64(x)
                        sumY &+= UInt64(y)
                        count &+= 1
                    }
                }
            }
            guard count > 0 else { return nil }
            let percent = Double(count) / totalPixels * 100.0
            let r = ranges[tag]!
            guard percent >= r.minPercent && percent <= r.maxPercent else {
                return nil   // ROBOTIS GetPosition 의 sentinel `-1.0` 와 등가.
            }
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

    /// RGB → HSV 변환 — hue 는 도(°) 단위.
    static func rgbToHsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let v = maxV
        let s = maxV == 0 ? 0 : delta / maxV
        let h: Double = {
            if delta == 0 { return 0 }
            if maxV == r { return 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            if maxV == g { return 60 * (((b - r) / delta) + 2) }
            return 60 * (((r - g) / delta) + 4)
        }()
        return (h < 0 ? h + 360 : h, s, v)
    }

    private static func rgbaBuffer(image: CGImage, width: Int, height: Int) -> [UInt8]? {
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
