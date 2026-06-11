import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **W3 (2026-06-12)** — 지지 다각형 기하 ↔ `ZMPMonitor` 좌표/단위 정합.
///
/// CoM 오버레이가 그리는 지지 다각형이 안정성 게이트(ZMPMonitor)와 **같은 발 패딩
/// 상수·같은 robot frame·같은 CoP 식**을 쓰는지 검증한다. 양발 정렬·수평 자세에서
/// 오버레이의 hull margin 과 ZMP margin 이 일치해야 한다(서로 다른 코드 경로가
/// 어긋나면 시각화가 거짓말을 한다).
final class SupportPolygonConsistencyTests: XCTestCase {

    /// hull 의 발 사각형 half-extent 가 ZMP 패딩 상수와 동일해야 한다.
    func testHalfExtentsMatchZMPPadding() {
        XCTAssertEqual(SupportPolygonGeometry.halfX, ZMPMonitor.xPaddingMeters, accuracy: 1e-12)
        XCTAssertEqual(SupportPolygonGeometry.halfY, ZMPMonitor.yPaddingMeters, accuracy: 1e-12)
    }

    /// CoP 추정식이 ZMP 와 동일(inverted-pendulum 1차 근사).
    func testCoPEstimateMatchesZMP() {
        let cop = SupportPolygonGeometry.estimateCoP(imuRollDeg: 4, imuPitchDeg: 6)
        let h = ZMPMonitor.comHeightMeters
        XCTAssertEqual(cop.x, sin(6 * .pi / 180) * h, accuracy: 1e-12)
        XCTAssertEqual(cop.y, sin(4 * .pi / 180) * h, accuracy: 1e-12)
    }

    /// 양발 정렬(같은 x)·수평 자세: hull margin == ZMP margin(여러 입력).
    @MainActor
    func testHullMarginMatchesZMPForAlignedFeet() {
        let cases: [(roll: Double, pitch: Double, lf: (x: Double, y: Double), rf: (x: Double, y: Double))] = [
            (0, 0, (0.0, 0.037), (0.0, -0.037)),     // 중립 더블 서포트
            (3, 5, (0.0, 0.037), (0.0, -0.037)),     // 약간 기울임 (안전 내)
            (8, 2, (0.0, 0.05), (0.0, -0.05)),       // 넓은 스탠스
            (12, 10, (0.02, 0.04), (0.02, -0.04)),   // 전방 이동 + 큰 기울임
        ]
        for c in cases {
            let zmp = ZMPMonitor()
            let verdictMargin = { () -> Double in
                zmp.evaluate(imuRollDeg: c.roll, imuPitchDeg: c.pitch,
                             leftFootCenter: c.lf, rightFootCenter: c.rf)
                return zmp.lastMargin
            }()
            let cop = SupportPolygonGeometry.estimateCoP(imuRollDeg: c.roll, imuPitchDeg: c.pitch)
            let hull = SupportPolygonGeometry.hull(leftFoot: c.lf, rightFoot: c.rf)
            let hullMargin = SupportPolygonGeometry.signedMargin(point: cop, polygon: hull)
            XCTAssertEqual(hullMargin, verdictMargin, accuracy: 1e-9,
                           "roll \(c.roll) pitch \(c.pitch): hull \(hullMargin) ≠ ZMP \(verdictMargin)")
        }
    }

    /// 정렬 발의 hull 은 ZMP 의 축정렬 bbox(코너 4개)와 동일해야 한다.
    func testHullEqualsAxisAlignedBBoxForAlignedFeet() {
        let lf = (x: 0.0, y: 0.037), rf = (x: 0.0, y: -0.037)
        let hull = SupportPolygonGeometry.hull(leftFoot: lf, rightFoot: rf)
        let xs = hull.map { $0.x }, ys = hull.map { $0.y }
        XCTAssertEqual(xs.min()!, -ZMPMonitor.xPaddingMeters, accuracy: 1e-9)
        XCTAssertEqual(xs.max()!, ZMPMonitor.xPaddingMeters, accuracy: 1e-9)
        XCTAssertEqual(ys.min()!, -0.037 - ZMPMonitor.yPaddingMeters, accuracy: 1e-9)
        XCTAssertEqual(ys.max()!, 0.037 + ZMPMonitor.yPaddingMeters, accuracy: 1e-9)
        // 직사각형이므로 hull 은 정확히 4코너.
        XCTAssertEqual(hull.count, 4)
    }

    /// signedMargin 부호: 명백히 다각형 밖이면 음수.
    func testSignedMarginNegativeOutside() {
        let lf = (x: 0.0, y: 0.037), rf = (x: 0.0, y: -0.037)
        let hull = SupportPolygonGeometry.hull(leftFoot: lf, rightFoot: rf)
        let outside = SupportPolygonGeometry.signedMargin(point: (x: 0.5, y: 0.0), polygon: hull)
        XCTAssertLessThan(outside, 0)
    }
}
