import CoreGraphics

/// **W4 (2026-06-12)** — 3D 카메라 연출 공용 수학.
///
/// 각도 lerp 의 핵심 함정: azimuth 를 절대값으로 대입하면 현재값과 목표값이
/// 2π 경계를 사이에 두고 있을 때 카메라가 "먼 길"로 한 바퀴 가까이 돈다.
/// `shortestAngleDelta` 는 항상 (-π, π] 범위의 최단 회전량을 반환해
/// `desired = current + shortestAngleDelta(from: current, to: target)` 로
/// 최단경로 전환을 보장한다 (ViewCube 부드러운 전환 · Cockpit 헤딩 추종 공용).
@inline(__always)
func shortestAngleDelta<T: BinaryFloatingPoint>(from a: T, to b: T) -> T {
    let pi = T(Double.pi)
    let twoPi = 2 * pi
    // truncatingRemainder 는 부호를 피제수(b-a)에서 가져오므로 결과는 (-2π, 2π).
    var d = (b - a).truncatingRemainder(dividingBy: twoPi)
    if d > pi {
        d -= twoPi
    } else if d <= -pi {
        d += twoPi
    }
    return d
}
