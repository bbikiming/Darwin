import simd

/// **W4 (2026-06-12)** — Cockpit 3인칭 체이스캠의 순수(테스트 가능) 추종 로직.
///
/// SceneKit 없이 벡터/스칼라만 다루므로 헤드리스 단위 테스트로 수렴/lag/lean/FOV 을
/// 검증할 수 있다. SCNView 의 `renderer(_:updateAtTime:)` 가 매 프레임 `update` 를
/// 호출하고 결과(카메라 world 위치·룩타깃·FOV)를 노드에 기록한다.
///
/// 동작 계약(설계 §6 4-D):
/// - 위치 lerp 0.12 / heading lerp 0.08 (heading 은 최단경로 보정).
/// - 전진 속도 비례 lean: pitch 다운 최대 2.5°, FOV 50→54 킥(0.3 m/s 포화).
/// - 카메라는 로봇 등 뒤 `distance` + 고정 높이 `chaseHeight`. zoom 은 distance 만.
struct CockpitChaseFollower {

    // MARK: 튜너블 (설계 고정값)
    let positionLerp: Double = 0.12
    let headingLerp: Double = 0.08
    let chaseHeight: Double = 0.95
    let chestHeight: Double = 0.30
    let minDistance: Double = 0.6
    let maxDistance: Double = 4.0
    let baseFOV: Double = 50
    let maxFOV: Double = 54
    let maxLeanRad: Double = 2.5 * .pi / 180
    /// 전진 속도가 이 값(m/s)에 도달하면 lean/FOV 가 최대치로 포화.
    let speedSaturation: Double = 0.3

    // MARK: 상태
    private(set) var smoothedHeading: Double
    private(set) var cameraPosition: SIMD3<Double>
    private(set) var lookTarget: SIMD3<Double>
    private(set) var fov: Double
    /// 카메라-로봇 거리(zoom). 외부(scroll/pinch)에서 조정.
    private(set) var distance: Double
    private var lastTargetPos: SIMD3<Double>?

    init(distance: Double = 1.55,
         heading: Double = 0,
         targetPosition: SIMD3<Double> = .zero) {
        self.distance = distance
        self.smoothedHeading = heading
        self.fov = baseFOV
        self.cameraPosition = targetPosition
            + Self.backOffset(heading: heading, distance: distance, height: chaseHeight)
        self.lookTarget = targetPosition + SIMD3(0, chestHeight, 0)
    }

    /// zoom — 거리 증감(클램프). 부호: 양수 delta = 멀어짐.
    mutating func adjustDistance(by delta: Double) {
        distance = min(maxDistance, max(minDistance, distance + delta))
    }

    /// 한 프레임 추종 갱신.
    /// - targetPosition: 로봇 rigAnchor 의 world 위치(y 는 보통 0).
    /// - targetHeading: 로봇 heading(rad).
    /// - dt: 직전 프레임과의 시간차(s). 속도 추정에 사용.
    mutating func update(targetPosition: SIMD3<Double>,
                         targetHeading: Double,
                         dt: Double) {
        // heading 최단경로 lerp.
        smoothedHeading += shortestAngleDelta(from: smoothedHeading, to: targetHeading) * headingLerp

        // 위치 lerp — 목표는 로봇 등 뒤 오프셋.
        let desired = targetPosition
            + Self.backOffset(heading: smoothedHeading, distance: distance, height: chaseHeight)
        cameraPosition += (desired - cameraPosition) * positionLerp

        // 전진 속도 추정(수평 성분).
        let safeDt = max(dt, 1.0 / 240.0)
        var speed = 0.0
        if let last = lastTargetPos {
            let d = targetPosition - last
            speed = (SIMD3(d.x, 0, d.z)).magnitude / safeDt
        }
        lastTargetPos = targetPosition

        let t = min(1.0, speed / speedSaturation)
        let leanRad = t * maxLeanRad
        fov = baseFOV + t * (maxFOV - baseFOV)

        // lean = 룩타깃을 약간 아래로 내려 카메라 pitch 다운(LookAt constraint 유지).
        let leanDrop = leanRad * distance
        lookTarget = targetPosition + SIMD3(0, chestHeight - leanDrop, 0)
    }

    /// 로봇 등 뒤 + 위 오프셋(world). local (0, height, -distance) 를 Y축 heading 회전.
    /// SceneKit eulerAngles.y 단일 회전과 동일한 right-handed Ry.
    static func backOffset(heading: Double, distance: Double, height: Double) -> SIMD3<Double> {
        let s = sin(heading), c = cos(heading)
        // Ry * (0, height, -distance) = (-distance·sin, height, -distance·cos)
        return SIMD3(-distance * s, height, -distance * c)
    }
}

private extension SIMD3 where Scalar == Double {
    var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
}
