import SceneKit
import XCTest
@testable import DarwinForgeUI

/// **W4 (2026-06-12)** — `InteractiveSceneView` idle 계약 + 전환 플래그 가드.
///
/// 핵심 회귀 방지:
/// ① 턴테이블이 켜지면 `isFullyIdle` 가 반드시 false (idle skip 과 충돌하면 회전이 멈춤).
/// ② 프로그램적 프리셋 전환 중에도 false (lerp 이 진행되어야 함).
/// ③ 기본 정지 상태에서는 true (idle CPU 계약 보존).
@MainActor
final class InteractiveSceneBehaviorTests: XCTestCase {

    private func makeView() -> InteractiveSceneView {
        let v = InteractiveSceneView(frame: .zero)
        // 카메라 노드 부여(applyCamera/DOF 가 pointOfView 를 요구).
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        let scene = SCNScene()
        scene.rootNode.addChildNode(camNode)
        v.scene = scene
        v.pointOfView = camNode
        return v
    }

    func testFreshViewIsIdle() {
        let v = makeView()
        XCTAssertTrue(v.isFullyIdle, "정지 상태 신규 view 는 idle 이어야 함")
    }

    func testTurntableBreaksIdle() {
        let v = makeView()
        XCTAssertTrue(v.isFullyIdle)
        v.turntableRadPerSec = 0.45
        XCTAssertFalse(v.isFullyIdle, "턴테이블 켜짐 → 절대 idle 아님(회전 tick 필요)")
        v.turntableRadPerSec = 0
        XCTAssertTrue(v.isFullyIdle, "턴테이블 끄면 다시 idle 복귀")
    }

    func testProgrammaticTransitionBreaksIdle() {
        let v = makeView()
        XCTAssertTrue(v.isFullyIdle)
        v.goToFace(.back)   // ease 전환 시작 → isTransitioning = true
        XCTAssertFalse(v.isFullyIdle, "프리셋 전환 중에는 idle 이 아니어야 함")
    }

    func testInstantTransitionStaysIdle() {
        let v = makeView()
        // instant 경로(롤백용)는 즉시 도달 → 전환 플래그 미설정 → idle 유지.
        v.transitionTo(azimuth: InteractiveSceneView.defaultAzimuth + 0.5,
                       elevation: InteractiveSceneView.defaultElevation,
                       instant: true)
        XCTAssertTrue(v.isFullyIdle, "instant 전환은 1프레임 도달 → idle 유지")
    }

    func testDepthOfFieldTogglesCameraFlag() {
        let v = makeView()
        XCTAssertEqual(v.pointOfView?.camera?.wantsDepthOfField, false)
        v.depthOfFieldEnabled = true
        XCTAssertEqual(v.pointOfView?.camera?.wantsDepthOfField, true)
        XCTAssertEqual(v.pointOfView?.camera?.fStop ?? 0, 5.6, accuracy: 1e-6)
        v.depthOfFieldEnabled = false
        XCTAssertEqual(v.pointOfView?.camera?.wantsDepthOfField, false)
    }
}
