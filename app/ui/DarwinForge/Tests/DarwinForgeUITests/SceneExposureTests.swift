import AppKit
import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **W1 (2026-06-11)** 노출 가드 — PBR/IBL 전환 후 흰 쉘 burn-out 회귀 방지.
///
/// 헤드리스 walkReady 정면 렌더에서 휘도 ≥ 250 픽셀 비율이 1.5% 미만이어야 한다
/// (LED emission 영역 감안). 이 테스트가 이후 모든 조명 튜닝의 안전망이자 CI 상시 가드.
final class SceneExposureTests: XCTestCase {

    /// 휘도 ≥ 250 픽셀 허용 상한.
    private let clipRatioLimit = 0.015

    @MainActor
    func testWalkReadyExposureWithinBudget() {
        let size = CGSize(width: 512, height: 384)
        guard let img = RobotScene3D.renderImage(pose: .walkReady, size: size),
              let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff) else {
            return XCTFail("headless 렌더 실패")
        }
        guard let data = bmp.bitmapData else { return XCTFail("bitmapData 없음") }

        let w = bmp.pixelsWide, h = bmp.pixelsHigh
        let spp = bmp.samplesPerPixel
        let rowBytes = bmp.bytesPerRow
        guard spp >= 3 else { return XCTFail("예상 밖 픽셀 포맷 spp=\(spp)") }

        var clipped = 0
        var total = 0
        for y in 0..<h {
            let row = data + y * rowBytes
            for x in 0..<w {
                let px = row + x * spp
                let r = Double(px[0]), g = Double(px[1]), b = Double(px[2])
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                if luma >= 250 { clipped += 1 }
                total += 1
            }
        }

        let ratio = Double(clipped) / Double(max(total, 1))
        XCTAssertLessThan(ratio, clipRatioLimit,
                          "휘도 클리핑 \(String(format: "%.2f%%", ratio * 100)) ≥ 한도 \(clipRatioLimit * 100)% — burn-out 회귀")
    }
}
