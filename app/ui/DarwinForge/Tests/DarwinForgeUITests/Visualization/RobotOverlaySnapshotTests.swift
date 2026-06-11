import AppKit
import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **W3 (2026-06-12)** — 로봇공학 오버레이 헤드리스 스냅샷 가드.
///
/// 각 오버레이가 ① 헤드리스에서 크래시 없이 렌더되고 ② 실제로 픽셀을 그리는지
/// (오버레이 off 대비 차이)와 ③ 한계각 아크가 min/max/중앙 3포즈에서 렌더되는지를
/// 검증한다. PNG 는 `DF_SNAPSHOT_DIR`(미설정 시 임시 디렉터리)에 기록해 육안 기준선.
///
/// 주의: `swift test` 환경은 STL 미로드라 로봇 메시가 안 보이나(헤드리스 스냅샷
/// 메모 참조), rig anchor/발 노드는 생성되므로 오버레이 좌표는 정상 동작한다.
final class RobotOverlaySnapshotTests: XCTestCase {

    private let size = CGSize(width: 384, height: 288)

    @MainActor
    func testEachOverlayRendersPixels() {
        // 오버레이 전부 끈 기준선.
        guard let base = RobotScene3D.renderImage(pose: .walkReady, size: size,
                                                  preset: .walkLab, overlays: []) else {
            return XCTFail("기준선 렌더 실패")
        }
        let perOverlay: [(RobotOverlaySet, String, ScenePreset, JointID?)] = [
            (.com,          "com",        .walkLab, nil),
            (.footContact,  "foot",       .walkLab, nil),
            (.horizon,      "horizon",    .walkLab, nil),
            (.jointAxis,    "jointAxis",  .studio,  .lKnee),
            (.trajectory,   "trajectory", .motion,  nil),
        ]
        for (set, name, preset, hl) in perOverlay {
            guard let img = RobotScene3D.renderImage(pose: .walkReady, size: size,
                                                     highlight: hl, preset: preset,
                                                     overlays: set) else {
                return XCTFail("\(name) 렌더 실패")
            }
            writeSnapshot(img, name: "overlay-\(name)")
            // 오버레이는 constant-shaded geometry → 같은 preset 의 off 대비 픽셀이 달라야 한다.
            guard let off = RobotScene3D.renderImage(pose: .walkReady, size: size,
                                                     highlight: hl, preset: preset,
                                                     overlays: []) else {
                return XCTFail("\(name) off 렌더 실패")
            }
            let diff = changedPixelRatio(off, img)
            XCTAssertGreaterThan(diff, 0.0003, "\(name) 오버레이가 픽셀을 그리지 않음(diff \(diff))")
        }
        _ = base
    }

    /// §3-B 한계각 아크 — min/center/max 3포즈에서 렌더(현재각 마커 위치 변화).
    @MainActor
    func testLimitArcThreePoses() {
        let joint = JointID.lKnee
        let lo = Kinematics.raw(fromDegrees: joint.degreeLimits.lowerBound)
        let hi = Kinematics.raw(fromDegrees: joint.degreeLimits.upperBound)
        let poses: [(String, RobotPose)] = [
            ("min",    RobotPose.walkReady.with(joint, raw: lo)),
            ("center", RobotPose.walkReady.with(joint, raw: 2048)),
            ("max",    RobotPose.walkReady.with(joint, raw: hi)),
        ]
        var images: [NSImage] = []
        for (label, pose) in poses {
            guard let img = RobotScene3D.renderImage(pose: pose, size: size,
                                                     highlight: joint, preset: .studio,
                                                     overlays: [.jointAxis]) else {
                return XCTFail("limitArc \(label) 렌더 실패")
            }
            writeSnapshot(img, name: "limitArc-\(label)")
            images.append(img)
        }
        // min 과 max 는 현재각 마커 위치가 달라 픽셀이 달라야 한다(마커가 작아 차이도 작음).
        XCTAssertGreaterThan(changedPixelRatio(images[0], images[2]), 0.0001,
                             "한계각 min/max 마커가 구분되지 않음")
    }

    // MARK: - helpers

    private func writeSnapshot(_ img: NSImage, name: String) {
        let dir = ProcessInfo.processInfo.environment["DF_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// 두 이미지의 변경 픽셀 비율(루마 차 > 6).
    private func changedPixelRatio(_ a: NSImage, _ b: NSImage) -> Double {
        guard let pa = pixels(a), let pb = pixels(b),
              pa.w == pb.w, pa.h == pb.h, pa.spp == pb.spp else { return 0 }
        var changed = 0, total = 0
        let spp = pa.spp
        let n = min(pa.data.count, pb.data.count)
        var i = 0
        while i + 2 < n {
            let la = 0.299 * Double(pa.data[i]) + 0.587 * Double(pa.data[i + 1]) + 0.114 * Double(pa.data[i + 2])
            let lb = 0.299 * Double(pb.data[i]) + 0.587 * Double(pb.data[i + 1]) + 0.114 * Double(pb.data[i + 2])
            if abs(la - lb) > 6 { changed += 1 }
            total += 1
            i += spp
        }
        return total > 0 ? Double(changed) / Double(total) : 0
    }

    private func pixels(_ img: NSImage) -> (data: [UInt8], w: Int, h: Int, spp: Int)? {
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let raw = bmp.bitmapData else { return nil }
        let count = bmp.bytesPerRow * bmp.pixelsHigh
        return (Array(UnsafeBufferPointer(start: raw, count: count)),
                bmp.pixelsWide, bmp.pixelsHigh, bmp.samplesPerPixel)
    }
}
