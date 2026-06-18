import ForgeCore
import SceneKit
import XCTest

@testable import DarwinForgeUI

/// **발-바닥 접지 회귀** (2026-06-18) — 모델 발이 바닥(Y=0) 아래로 침수하던 결함 수정.
///
/// 종전: `MeshRig` 가 root 를 하드코딩 `+0.265 m` 로 들어올렸는데, 이 값은 walkReady
/// deep-squat 전용이라 idle 기본 포즈(`.center`, 다리 곧음)에선 발이 더 아래로 내려가
/// 바닥을 뚫었다. `groundToFloor()` 가 현재 포즈의 최저 지오메트리 정점을 측정해 root 높이를
/// 자동 보정하므로, 어떤 포즈에서도 최저 발이 정확히 바닥에 닿아야 한다.
///
/// 헤드리스 `swift test` 환경에서 STL 이 번들에 없으면 측정할 지오메트리가 없어 `XCTSkip`
/// (실제 `.app` 에는 메시가 동기화되므로 접지 동작). 메시가 있으면 ±5 mm 접지를 단언.
final class MeshRigFloorContactTests: XCTestCase {

    /// rig 전체 mesh 지오메트리의 최저 월드 Y (root 변환 적용 후). 메시 미로드면 nil.
    private func lowestWorldY(_ rig: MeshRig) -> CGFloat? {
        var minY = CGFloat.greatestFiniteMagnitude
        var found = false
        rig.rootNode.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            found = true
            let lo = node.boundingBox.min
            let hi = node.boundingBox.max
            let corners = [
                SCNVector3(lo.x, lo.y, lo.z), SCNVector3(hi.x, lo.y, lo.z),
                SCNVector3(lo.x, hi.y, lo.z), SCNVector3(hi.x, hi.y, lo.z),
                SCNVector3(lo.x, lo.y, hi.z), SCNVector3(hi.x, lo.y, hi.z),
                SCNVector3(lo.x, hi.y, hi.z), SCNVector3(hi.x, hi.y, hi.z),
            ]
            for c in corners {
                let w = node.convertPosition(c, to: nil)
                if w.y < minY { minY = w.y }
            }
        }
        return found ? minY : nil
    }

    /// idle 기본 포즈(`.center`, 곧은 다리) — 종전 침수 결함의 진원지.
    func testIdleCenterPoseFeetOnFloor() throws {
        let rig = try MeshRig()
        rig.apply(pose: .center)
        guard let minY = lowestWorldY(rig) else {
            throw XCTSkip("STL 메시가 테스트 번들에 없음 — 헤드리스 접지 측정 불가(실 .app 은 동기화)")
        }
        XCTAssertEqual(minY, 0, accuracy: 0.005,
            ".center 포즈에서 최저 발이 바닥(Y=0)에 ±5 mm 접지해야 함. 실제 minY=\(minY) m")
    }

    /// 다른 포즈로 바꿔도 접지 유지(최저 발 = 바닥). 무릎을 굽히는 포즈 적용 후 재측정.
    func testRegroundsAfterPoseChange() throws {
        let rig = try MeshRig()
        rig.apply(pose: .center)
        guard lowestWorldY(rig) != nil else {
            throw XCTSkip("STL 메시 미로드 — 측정 불가")
        }
        // walkReady squat 자세(무릎 굽힘, 04-motion-library 표 raw 값) → 발 높이 변함 → 재접지 확인.
        let updates: [JointID: Int] = [
            .rKnee: 2653, .lKnee: 1443,
            .rHipPitch: 1637, .lHipPitch: 2459,
            .rAnklePitch: 2389, .lAnklePitch: 1707,
        ]
        rig.apply(pose: RobotPose.center.with(updates))
        let minY = try XCTUnwrap(lowestWorldY(rig))
        XCTAssertEqual(minY, 0, accuracy: 0.005,
            "포즈 변경 후에도 최저 발이 바닥에 접지해야 함. 실제 minY=\(minY) m")
    }
}
