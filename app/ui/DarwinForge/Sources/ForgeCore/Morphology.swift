import Foundation

/// 3×3 morphological 연산 — ROBOTIS `Framework/src/vision/ImgProcess.cpp:109-206` Swift 포팅.
///
/// **목적 (firmware-reference/05-vision-pipeline.md Section "Image processing pipeline")**:
///   binary mask 의 noise pixel 제거 (erode) + 작은 hole 메우기 (dilate).
///   ROBOTIS GetPosition 의 표준 전처리 — 우리도 동일하게 적용해야 false centroid 줄어듬.
///
/// **알고리즘**:
///   - `erode_3x3`: 9 픽셀 AND. 한 픽셀이라도 0 이면 결과 0.
///   - `dilate_3x3`: 9 픽셀 OR. 한 픽셀이라도 1 이면 결과 1.
///   - 경계 픽셀 (border) 는 단순히 그대로 — ROBOTIS 도 동일.
///
/// **성능**: 256×256 mask × 9 픽셀 × 2 pass ≈ 1.2M operations. Swift 에서 ~10-20ms.
/// 5Hz polling (200ms) 안에서 부담 작음.
public enum Morphology {

    /// 3×3 erosion — 9 픽셀 모두 1 이어야 결과 1.
    /// `mask` 는 width×height 의 0/1 byte array.
    public static func erode(mask: inout [UInt8], width: Int, height: Int) {
        guard width > 2, height > 2 else { return }
        let source = mask    // copy — 원본 보존.
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let a = source[i - width - 1] & source[i - width] & source[i - width + 1]
                let b = source[i - 1]         & source[i]         & source[i + 1]
                let c = source[i + width - 1] & source[i + width] & source[i + width + 1]
                mask[i] = a & b & c
            }
        }
    }

    /// 3×3 dilation — 9 픽셀 중 하나라도 1 이면 결과 1.
    public static func dilate(mask: inout [UInt8], width: Int, height: Int) {
        guard width > 2, height > 2 else { return }
        let source = mask
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let a = source[i - width - 1] | source[i - width] | source[i - width + 1]
                let b = source[i - 1]         | source[i]         | source[i + 1]
                let c = source[i + width - 1] | source[i + width] | source[i + width + 1]
                mask[i] = a | b | c
            }
        }
    }

    /// `erode → dilate` (opening) — ROBOTIS `GetPosition` 의 표준 순서.
    public static func openingInPlace(mask: inout [UInt8], width: Int, height: Int) {
        erode(mask: &mask, width: width, height: height)
        dilate(mask: &mask, width: width, height: height)
    }
}
