import AppKit
import ForgeCore
import SceneKit
import XCTest
@testable import DarwinForgeUI

/// 시각 회귀 + 자체 검증용 스냅샷 — `RobotScene3D.writePNG`로 헤드리스 렌더.
/// 결과 PNG는 `/tmp/darwinforge-snapshots/` 에 저장.
final class RobotSnapshotTests: XCTestCase {

    private var outDir: URL {
        let url = URL(fileURLWithPath: "/tmp/darwinforge-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testWalkReadyFront() {
        let url = outDir.appendingPathComponent("01-walk-ready-front.png")
        let ok = RobotScene3D.writePNG(
            pose: .walkReady,
            to: url,
            size: CGSize(width: 1280, height: 960)
        )
        XCTAssertTrue(ok, "walk_ready 정면 렌더 실패")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testCenterFront() {
        let url = outDir.appendingPathComponent("02-center-front.png")
        let ok = RobotScene3D.writePNG(
            pose: .center,
            to: url,
            size: CGSize(width: 1280, height: 960)
        )
        XCTAssertTrue(ok)
    }

    @MainActor
    func testWalkReadyClose() {
        let url = outDir.appendingPathComponent("03-walk-ready-closeup.png")
        let ok = RobotScene3D.writePNG(
            pose: .walkReady,
            to: url,
            size: CGSize(width: 1280, height: 960),
            cameraOverride: SCNVector3(0.45, 0.40, 0.65)
        )
        XCTAssertTrue(ok)
    }

    @MainActor
    func testWavingPose() {
        // 손 흔드는 자세 — 우측 어깨 들고 팔꿈치 굽힘
        let waving = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
            .rShoulderRoll:  Kinematics.raw(fromDegrees:   30),
            .rElbow:         Kinematics.raw(fromDegrees:   80)
        ])
        let url = outDir.appendingPathComponent("04-waving.png")
        let ok = RobotScene3D.writePNG(
            pose: waving,
            to: url,
            size: CGSize(width: 1280, height: 960)
        )
        XCTAssertTrue(ok)
    }

    @MainActor
    func testHeadCloseup() {
        // 머리 디테일 점검용 클로즈업
        let url = outDir.appendingPathComponent("05-head-closeup.png")
        let ok = RobotScene3D.writePNG(
            pose: .walkReady,
            to: url,
            size: CGSize(width: 1280, height: 960),
            cameraOverride: SCNVector3(0.0, 0.55, 0.40)
        )
        XCTAssertTrue(ok)
    }
}
