import AppKit
import CForgeCore
import Foundation

/// 카메라 프레임에서 공(혹은 색 blob) 위치를 검출 — Phase C2 (Sprint 18).
///
/// `forge-core::vision` 의 HSV 기반 detector 를 FFI (`fc_vision_detect_ball`) 로 호출.
/// ROBOTIS demo 의 `ColorFinder` 와 동일한 접근 — 주황색 공 (default) 의 픽셀 군집 centroid.
///
/// **사용 시점**:
///   - PilotCameraView 가 매 frame 받을 때마다 Mac 측에서 호출 (로봇 demo 와 무관).
///   - demo 가 자체 detection 하는 SOCCER 모드와 별개로, Mac UI 가 같은 영상에서
///     centroid 를 그려 사용자에게 "공이 감지되고 있다" 시각 피드백.
public enum BallVision {

    /// 한 frame 에서 가장 큰 매칭 blob 의 위치.
    public struct Detection: Equatable, Sendable {
        /// 카메라 frame 내 정규화 좌표 (0..1, 좌상단 (0,0)).
        public let centroidNormalized: CGPoint
        /// 매칭 픽셀 수 — blob 크기 추정. 0 = 검출 안 됨.
        public let pixelCount: Int
        /// 픽셀 수에 따른 대략적 반경 (정규화 0..1) — 시각화용.
        public let approximateRadiusNormalized: CGFloat

        public init(centroidNormalized: CGPoint, pixelCount: Int,
                    approximateRadiusNormalized: CGFloat) {
            self.centroidNormalized = centroidNormalized
            self.pixelCount = pixelCount
            self.approximateRadiusNormalized = approximateRadiusNormalized
        }

        public var isDetected: Bool { pixelCount > 0 }
    }

    /// `NSImage` 에서 검출 시도. 실패 / 검출 안 됨 → nil.
    /// - Note: 큰 이미지는 자동으로 256px 너비로 축소 — FFI 호출 비용 절감.
    @MainActor
    public static func detect(in image: NSImage,
                              maxDimension: Int = 256) -> Detection? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return detect(in: cg, maxDimension: maxDimension)
    }

    /// `CGImage` 에서 검출 — 픽셀 데이터 → RGBA bytes → FFI.
    public static func detect(in image: CGImage, maxDimension: Int = 256) -> Detection? {
        let srcW = image.width
        let srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }

        // Downscale — FFI 호출 비용 절감 (HSV 변환 cost = O(w*h)).
        let scale = min(1.0, Double(maxDimension) / Double(max(srcW, srcH)))
        let dstW = max(1, Int(Double(srcW) * scale))
        let dstH = max(1, Int(Double(srcH) * scale))

        guard let pixels = rgbaPixelBuffer(image: image, width: dstW, height: dstH) else {
            return nil
        }

        var blob = fc_blob_result()
        let count = UInt32(pixels.count)
        let rc: Int32 = pixels.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return FC_ERR_INVALID }
            return fc_vision_detect_ball(base, count, UInt32(dstW), UInt32(dstH), &blob)
        }
        guard rc == FC_OK else { return nil }
        guard blob.pixel_count > 0 else { return nil }

        // 정규화 좌표 — UI 가 카메라 frame 크기와 무관하게 그릴 수 있도록.
        let nx = CGFloat(blob.centroid_x) / CGFloat(dstW)
        let ny = CGFloat(blob.centroid_y) / CGFloat(dstH)
        // 픽셀 수 → 반경 (정규화) 근사: r ≈ sqrt(count / pi) / max(w, h).
        let radiusPx = CGFloat((Double(blob.pixel_count) / .pi).squareRoot())
        let radiusN = radiusPx / CGFloat(max(dstW, dstH))

        return Detection(
            centroidNormalized: CGPoint(x: nx, y: ny),
            pixelCount: Int(blob.pixel_count),
            approximateRadiusNormalized: max(0.02, min(0.4, radiusN))
        )
    }

    /// CGImage 를 지정 크기로 RGBA 버퍼로 변환.
    private static func rgbaPixelBuffer(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let ok: Bool = pixels.withUnsafeMutableBytes { rawPtr -> Bool in
            guard let baseAddr = rawPtr.baseAddress else { return false }
            guard let ctx = CGContext(
                data: baseAddr,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}
