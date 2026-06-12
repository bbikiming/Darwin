import simd
import XCTest
@testable import DarwinForgeUI

/// **W4 (2026-06-12)** — Cockpit 체이스 follower 수렴/lag/lean/FOV 단위 테스트.
///
/// SceneKit 없이 순수 벡터 로직만 검증한다(헤드리스 결정적).
final class CockpitChaseFollowerTests: XCTestCase {

    private let dt = 1.0 / 30.0

    /// heading 스윕 입력 → smoothedHeading 이 목표로 단조 수렴(lag 있으나 도달).
    func testHeadingConvergesWithLag() {
        var f = CockpitChaseFollower(distance: 1.55, heading: 0, targetPosition: .zero)
        let target = 1.2   // rad
        // 1프레임 후엔 아직 멀고(lag), 충분히 반복하면 도달.
        f.update(targetPosition: .zero, targetHeading: target, dt: dt)
        XCTAssertLessThan(f.smoothedHeading, target, "한 프레임에 도달하면 lag 이 없는 것")
        XCTAssertGreaterThan(f.smoothedHeading, 0)
        for _ in 0..<300 { f.update(targetPosition: .zero, targetHeading: target, dt: dt) }
        XCTAssertEqual(f.smoothedHeading, target, accuracy: 1e-3, "충분 반복 후 heading 수렴")
    }

    /// heading 이 2π 경계를 넘어도 최단경로로 — 한 바퀴 역주행 금지.
    func testHeadingTakesShortestPath() {
        var f = CockpitChaseFollower(distance: 1.55, heading: 0.1, targetPosition: .zero)
        let target = 2 * Double.pi - 0.1   // 사실상 -0.1 방향
        f.update(targetPosition: .zero, targetHeading: target, dt: dt)
        // 최단경로면 smoothedHeading 이 0.1 에서 *감소*(음의 방향)해야 한다.
        XCTAssertLessThan(f.smoothedHeading, 0.1, "최단경로(−) 대신 +방향으로 돌면 회귀")
    }

    /// 정지 상태: lean 0(lookTarget y == chestHeight) + FOV == base.
    func testStaticHasNoLeanOrFovKick() {
        var f = CockpitChaseFollower(distance: 1.55, heading: 0, targetPosition: .zero)
        for _ in 0..<10 { f.update(targetPosition: .zero, targetHeading: 0, dt: dt) }
        XCTAssertEqual(f.fov, 50, accuracy: 1e-6, "정지 시 FOV 킥 없음")
        XCTAssertEqual(f.lookTarget.y, 0.30, accuracy: 1e-6, "정지 시 lean 없음(lookTarget=가슴높이)")
    }

    /// 빠른 전진: FOV 가 50→54 로 킥, lookTarget 이 아래로 내려간다(lean down).
    func testForwardMotionKicksFovAndLeans() {
        var f = CockpitChaseFollower(distance: 1.55, heading: 0, targetPosition: .zero)
        // 0.3 m/s 이상으로 전진(포화) — dt 당 0.02 m → 0.6 m/s.
        var pos = SIMD3<Double>(0, 0, 0)
        let step = SIMD3<Double>(0, 0, 0.02)
        for _ in 0..<30 {
            pos += step
            f.update(targetPosition: pos, targetHeading: 0, dt: dt)
        }
        XCTAssertEqual(f.fov, 54, accuracy: 0.2, "포화 속도에서 FOV ≈ 54")
        XCTAssertLessThan(f.lookTarget.y, 0.30, "전진 시 lean → lookTarget 하강")
    }

    /// 카메라 위치가 로봇 등 뒤(−Z, heading 0)로 수렴.
    func testCameraSettlesBehindRobot() {
        var f = CockpitChaseFollower(distance: 1.55, heading: 0, targetPosition: .zero)
        for _ in 0..<200 { f.update(targetPosition: .zero, targetHeading: 0, dt: dt) }
        XCTAssertEqual(f.cameraPosition.x, 0, accuracy: 1e-3)
        XCTAssertEqual(f.cameraPosition.y, 0.95, accuracy: 1e-3)
        XCTAssertEqual(f.cameraPosition.z, -1.55, accuracy: 1e-3, "등 뒤 −distance 로 수렴")
    }

    /// zoom: distance 클램프(0.6..4.0).
    func testZoomClamps() {
        var f = CockpitChaseFollower(distance: 1.55)
        f.adjustDistance(by: -10)
        XCTAssertEqual(f.distance, 0.6, accuracy: 1e-9)
        f.adjustDistance(by: 100)
        XCTAssertEqual(f.distance, 4.0, accuracy: 1e-9)
    }
}
