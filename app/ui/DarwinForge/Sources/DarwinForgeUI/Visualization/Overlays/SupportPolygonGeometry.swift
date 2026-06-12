import Foundation
import ForgeCore

/// **W3 (2026-06-12)** — 지지 다각형(support polygon) 순수 기하.
///
/// CoM 오버레이의 다각형 시각화와 단위 테스트(ZMPMonitor 좌표 정합)가 공유하는
/// 유일 정의. **발 사각형 half-extent 는 `ZMPMonitor` 패딩 상수를 그대로 사용** —
/// sagittal(전후, robot x) = `xPaddingMeters`, lateral(좌우, robot y) = `yPaddingMeters`.
/// 이로써 양발 정렬·수평 자세에서 본 다각형 margin 이 ZMP margin 과 정확히 일치한다.
///
/// 좌표계: robot frame (x=전방, y=좌). 음/양은 ZMP 와 동일.
enum SupportPolygonGeometry {

    /// 발 사각형 half-extent — ZMP 패딩과 동일(정합 보장).
    static var halfX: Double { ZMPMonitor.xPaddingMeters }   // 전후 0.05
    static var halfY: Double { ZMPMonitor.yPaddingMeters }   // 좌우 0.03

    /// 한 발 중심의 4코너(robot frame).
    static func footCorners(_ c: (x: Double, y: Double)) -> [(x: Double, y: Double)] {
        [(c.x - halfX, c.y - halfY), (c.x + halfX, c.y - halfY),
         (c.x + halfX, c.y + halfY), (c.x - halfX, c.y + halfY)]
    }

    /// 양발 8코너 → convex hull(반시계, Andrew monotone chain).
    static func hull(leftFoot: (x: Double, y: Double),
                     rightFoot: (x: Double, y: Double)) -> [(x: Double, y: Double)] {
        convexHull(footCorners(leftFoot) + footCorners(rightFoot))
    }

    /// Andrew monotone chain. 입력 ≤ 8점이라 O(n log n) 비용 무시 가능.
    static func convexHull(_ input: [(x: Double, y: Double)]) -> [(x: Double, y: Double)] {
        let pts = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double),
                   _ b: (x: Double, y: Double)) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [(x: Double, y: Double)] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [(x: Double, y: Double)] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// 점→볼록 다각형 signed margin(내부 양수, 외부 음수). 각 변까지 거리의 최소.
    /// 다각형은 반시계(hull 출력) 가정.
    static func signedMargin(point p: (x: Double, y: Double),
                             polygon poly: [(x: Double, y: Double)]) -> Double {
        guard poly.count >= 3 else { return -Double.infinity }
        var minDist = Double.infinity
        var inside = true
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let ex = b.x - a.x, ey = b.y - a.y
            // 반시계 변의 좌측이 내부. cross < 0 이면 점이 변 밖.
            let crossv = ex * (p.y - a.y) - ey * (p.x - a.x)
            if crossv < 0 { inside = false }
            // 점→선분 거리.
            let len2 = ex * ex + ey * ey
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * ex + (p.y - a.y) * ey) / len2)) : 0
            let dx = p.x - (a.x + t * ex), dy = p.y - (a.y + t * ey)
            minDist = min(minDist, (dx * dx + dy * dy).squareRoot())
        }
        return inside ? minDist : -minDist
    }

    /// CoP 추정(ZMP 와 동일 inverted-pendulum 1차 근사). 정합 테스트·자체 계산 공용.
    static func estimateCoP(imuRollDeg: Double, imuPitchDeg: Double) -> (x: Double, y: Double) {
        let h = ZMPMonitor.comHeightMeters
        return (x: sin(imuPitchDeg * .pi / 180) * h,
                y: sin(imuRollDeg * .pi / 180) * h)
    }
}
