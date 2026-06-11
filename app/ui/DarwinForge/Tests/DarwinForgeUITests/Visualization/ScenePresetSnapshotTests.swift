import AppKit
import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **W2 (2026-06-11)** — 화면별 환경 프리셋 스냅샷 가드.
///
/// ① preset 5종이 헤드리스에서 모두 렌더되는지(크래시·degenerate 방지),
/// ② Studio preset 이 W1 노출 예산을 그대로 지키는지(회귀 0),
/// ③ preset 간 무드가 실제로 다른지(Cockpit < Studio 평균 휘도)를 검증한다.
///
/// 스냅샷 PNG 5장은 `DF_SNAPSHOT_DIR`(미설정 시 NSTemporaryDirectory)에 기록해
/// 육안 비교 기준선으로 남긴다.
final class ScenePresetSnapshotTests: XCTestCase {

    /// 휘도 ≥ 250 픽셀 허용 상한 — SceneExposureTests 와 동일.
    private let clipRatioLimit = 0.015
    private let snapshotSize = CGSize(width: 384, height: 288)

    private struct Stats {
        let meanLuma: Double
        let stdDevLuma: Double
        let clipRatio: Double
    }

    @MainActor
    func testAllPresetsRenderNonDegenerate() {
        for preset in ScenePreset.allCases {
            guard let img = RobotScene3D.renderImage(pose: .walkReady,
                                                     size: snapshotSize,
                                                     preset: preset) else {
                return XCTFail("preset \(preset.rawValue) 헤드리스 렌더 실패")
            }
            writeSnapshot(img, name: "preset-\(preset.rawValue)")
            guard let stats = analyze(img) else {
                return XCTFail("preset \(preset.rawValue) 픽셀 분석 실패")
            }
            // degenerate(전부 같은 값) 방지 — 로봇+바닥+그리드가 보이면 분산이 충분.
            XCTAssertGreaterThan(stats.stdDevLuma, 3.0,
                                 "preset \(preset.rawValue) 휘도 분산 과소 — 렌더 비정상 의심")
        }
    }

    @MainActor
    func testStudioPresetExposureWithinBudget() {
        guard let img = RobotScene3D.renderImage(pose: .walkReady,
                                                 size: snapshotSize,
                                                 preset: .studio),
              let stats = analyze(img) else {
            return XCTFail("studio 렌더/분석 실패")
        }
        XCTAssertLessThan(stats.clipRatio, clipRatioLimit,
                          "studio 휘도 클리핑 \(String(format: "%.2f%%", stats.clipRatio * 100)) ≥ 한도 — burn-out 회귀")
    }

    @MainActor
    func testCockpitMoodDarkerThanStudio() {
        guard let studio = RobotScene3D.renderImage(pose: .walkReady, size: snapshotSize, preset: .studio),
              let cockpit = RobotScene3D.renderImage(pose: .walkReady, size: snapshotSize, preset: .cockpit),
              let s = analyze(studio), let c = analyze(cockpit) else {
            return XCTFail("studio/cockpit 렌더 실패")
        }
        // Cockpit 은 IBL 0.55 + 어두운 teal 바닥 → 평균 휘도가 분명히 낮아야 한다.
        XCTAssertLessThan(c.meanLuma, s.meanLuma,
                          "Cockpit(평균 \(Int(c.meanLuma))) 이 Studio(평균 \(Int(s.meanLuma))) 보다 어둡지 않음 — preset 미적용 의심")
    }

    // MARK: - helpers

    private func analyze(_ img: NSImage) -> Stats? {
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let data = bmp.bitmapData else { return nil }
        let w = bmp.pixelsWide, h = bmp.pixelsHigh
        let spp = bmp.samplesPerPixel
        let rowBytes = bmp.bytesPerRow
        guard spp >= 3 else { return nil }

        var sum = 0.0, sumSq = 0.0, clipped = 0, total = 0
        for y in 0..<h {
            let row = data + y * rowBytes
            for x in 0..<w {
                let px = row + x * spp
                let luma = 0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])
                sum += luma
                sumSq += luma * luma
                if luma >= 250 { clipped += 1 }
                total += 1
            }
        }
        let n = Double(max(total, 1))
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)
        return Stats(meanLuma: mean, stdDevLuma: variance.squareRoot(),
                     clipRatio: Double(clipped) / n)
    }

    private func writeSnapshot(_ img: NSImage, name: String) {
        let dir = ProcessInfo.processInfo.environment["DF_SNAPSHOT_DIR"]
            ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
