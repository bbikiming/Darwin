import XCTest
@testable import DarwinForgeUI

/// **W1 (2026-06-11)** STL crease-angle normal smoothing 검증.
final class STLNormalSmootherTests: XCTestCase {

    /// ① 직각(90°) 모서리 — crease 35° 초과라 face normal 유지(hard edge).
    func testHardEdgeStaysFaceNormal() {
        // Tri0: XY 평면(normal +Z), Tri1: 공유 모서리(0,0,0)-(1,0,0) 둘러 90° 꺾임(normal -Y).
        let positions: [Float] = [
            0, 0, 0,   1, 0, 0,   0, 1, 0,     // Tri0 → +Z
            0, 0, 0,   1, 0, 0,   0, 0, 1      // Tri1 → -Y
        ]
        let normals: [Float] = [
            0, 0, 1,   0, 0, 1,   0, 0, 1,
            0, -1, 0,  0, -1, 0,  0, -1, 0
        ]
        let out = STLNormalSmoother.smooth(positions: positions, normals: normals,
                                           creaseAngleDeg: 35)
        // Tri0 의 공유 정점 (0,0,0) — 인덱스 0 — 은 +Z 를 그대로 유지해야 함.
        XCTAssertEqual(out[0], 0, accuracy: 1e-4)
        XCTAssertEqual(out[1], 0, accuracy: 1e-4)
        XCTAssertEqual(out[2], 1, accuracy: 1e-4, "90° 이웃이 섞이면 hard edge 가 무너짐")
    }

    /// ② 얕은(20°) 크리스 — crease 35° 이하라 인접 normal 이 평균되어 매끈.
    func testShallowCreaseBlends() {
        let c = cosf(20 * .pi / 180), s = sinf(20 * .pi / 180)
        // Tri0: normal +Z. Tri1: 공유 모서리 둘러 20° 기운 normal (0, sin20, cos20).
        let positions: [Float] = [
            0, 0, 0,   1, 0, 0,   0, 1, 0,        // Tri0 → +Z
            0, 0, 0,   0, -c, s,  1, 0, 0         // Tri1 → (0, sin20, cos20)
        ]
        let normals: [Float] = [
            0, 0, 1,   0, 0, 1,   0, 0, 1,
            0, s, c,   0, s, c,   0, s, c
        ]
        let out = STLNormalSmoother.smooth(positions: positions, normals: normals,
                                           creaseAngleDeg: 35)
        // 공유 정점(인덱스 0)의 normal 은 두 face 평균 → +Y 성분이 생기고 순수 +Z 가 아님.
        XCTAssertGreaterThan(out[1], 0.01, "20° 크리스는 섞여야 함 (y>0)")
        XCTAssertLessThan(out[2], 0.9999, "순수 +Z 가 아니어야 함 (블렌딩됨)")
        // 단위 벡터 유지.
        let len = sqrt(out[0]*out[0] + out[1]*out[1] + out[2]*out[2])
        XCTAssertEqual(len, 1, accuracy: 1e-4)
    }

    /// 빈/퇴화 입력은 원본 그대로 반환(크래시 없음).
    func testDegenerateInputReturnsOriginal() {
        XCTAssertEqual(STLNormalSmoother.smooth(positions: [], normals: []), [])
    }
}
