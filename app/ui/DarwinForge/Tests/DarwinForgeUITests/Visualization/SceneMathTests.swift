import CoreGraphics
import XCTest
@testable import DarwinForgeUI

/// **W4 (2026-06-12)** — `shortestAngleDelta` 최단경로 보정 단위 테스트.
///
/// ViewCube 부드러운 전환과 Cockpit heading 추종이 공유하는 핵심 함수. 2π 경계를
/// 넘는 케이스에서 "먼 길로 한 바퀴 도는" 회귀를 막는 안전망.
final class SceneMathTests: XCTestCase {

    private let eps: CGFloat = 1e-9

    func testZeroDeltaWhenEqual() {
        XCTAssertEqual(shortestAngleDelta(from: 1.23 as CGFloat, to: 1.23), 0, accuracy: eps)
    }

    func testSmallPositiveDelta() {
        XCTAssertEqual(shortestAngleDelta(from: 0.0 as CGFloat, to: 0.5), 0.5, accuracy: eps)
    }

    func testSmallNegativeDelta() {
        XCTAssertEqual(shortestAngleDelta(from: 0.5 as CGFloat, to: 0.0), -0.5, accuracy: eps)
    }

    /// 핵심: from≈0, to≈2π-0.1 → 절대값 대입이면 +6.18 회전(거의 한 바퀴), 최단은 -0.1.
    func testWrapsTheShortWayNearTwoPi() {
        let from: CGFloat = 0.1
        let to: CGFloat = 2 * .pi - 0.1
        let d = shortestAngleDelta(from: from, to: to)
        XCTAssertEqual(d, -0.2, accuracy: 1e-6)
        // from + d 가 to 와 2π 합동인지.
        let reached = from + d
        XCTAssertEqual(sin(reached), sin(to), accuracy: 1e-6)
        XCTAssertEqual(cos(reached), cos(to), accuracy: 1e-6)
    }

    /// 반대 방향: from≈2π, to≈0 → 최단 +.
    func testWrapsTheShortWayFromTwoPi() {
        let from: CGFloat = 2 * .pi - 0.1
        let to: CGFloat = 0.1
        XCTAssertEqual(shortestAngleDelta(from: from, to: to), 0.2, accuracy: 1e-6)
    }

    /// 다중 회전 누적도 정규화 — from 이 +4π 떨어져 있어도 결과는 (-π, π].
    func testHandlesMultipleWraps() {
        let from: CGFloat = 0.3 + 4 * .pi
        let to: CGFloat = 0.5
        XCTAssertEqual(shortestAngleDelta(from: from, to: to), 0.2, accuracy: 1e-6)
    }

    /// 정확히 π 경계(half-turn) — 부호 규약: +π 가 아니라 -π 로 떨어지는지(d ≤ -π → +2π).
    func testHalfTurnBoundary() {
        let d = shortestAngleDelta(from: 0.0 as CGFloat, to: .pi)
        // π 는 d > π 가 아니므로 그대로 +π.
        XCTAssertEqual(abs(d), .pi, accuracy: 1e-6)
    }

    func testResultAlwaysWithinPi() {
        let samples: [CGFloat] = [-10, -3.3, -1, 0, 0.7, 3.14, 6.5, 100]
        for a in samples {
            for b in samples {
                let d = shortestAngleDelta(from: a, to: b)
                XCTAssertLessThanOrEqual(d, CGFloat.pi + 1e-9)
                XCTAssertGreaterThan(d, -CGFloat.pi - 1e-9)
            }
        }
    }

    /// Double 오버로드(Cockpit follower 용)도 동일 동작.
    func testDoubleOverload() {
        XCTAssertEqual(shortestAngleDelta(from: 0.1 as Double, to: 2 * .pi - 0.1), -0.2, accuracy: 1e-9)
    }
}
