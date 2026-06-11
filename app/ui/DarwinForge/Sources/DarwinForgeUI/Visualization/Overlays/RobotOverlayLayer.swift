import ForgeCore
import SceneKit

/// **W3 (2026-06-12)** — 모든 로봇공학 오버레이의 노드 풀 소유자.
///
/// `RobotSceneCoordinator` 가 1개 보유하고, **`applyPose` 와 동일한 호출 경로에서만**
/// `update(...)` 가 돈다 — 자체 타이머 없음(idle CPU 계약 유지). 모든 하위 오버레이는
/// 노드를 init 에서 1회 풀링하고 update 에선 위치/색/visibility 만 갱신(0-alloc).
final class RobotOverlayLayer {

    let root = SCNNode()
    private let com = CoMSupportOverlay()
    private let axis = JointAxisOverlay()
    private let foot = FootContactOverlay()
    private let horizon = HorizonOverlay()
    private let trajectory = TrajectoryOverlay()

    /// 한계 경고를 마지막으로 적용한 활성 여부 — off 전환 시 1회 클리어용.
    private var limitWarningWasOn = false

    init() {
        root.name = "robotOverlayLayer"
        root.addChildNode(com.container)
        root.addChildNode(axis.container)
        root.addChildNode(foot.container)
        root.addChildNode(horizon.container)
        root.addChildNode(trajectory.container)
    }

    /// pose/highlight/data/overlays 변경 시 호출(코디네이터 applyPose 경유).
    func update(overlays: RobotOverlaySet,
                pose: RobotPose,
                highlight: JointID?,
                data: SceneOverlayData?,
                rig: RigSkeleton) {
        com.setEnabled(overlays.contains(.com))
        axis.setEnabled(overlays.contains(.jointAxis))
        foot.setEnabled(overlays.contains(.footContact))
        horizon.setEnabled(overlays.contains(.horizon))
        trajectory.setEnabled(overlays.contains(.trajectory))

        let (lf, rf) = footCenters(rig: rig)
        com.update(rig: rig, data: data, leftFoot: lf, rightFoot: rf)
        axis.update(rig: rig, highlight: highlight, pose: pose)
        foot.update(rig: rig, data: data)
        trajectory.update(rig: rig)
        // horizon 은 표시 토글만(pose 무관).

        applyLimitWarning(enabled: overlays.contains(.limitWarning), pose: pose, rig: rig)
    }

    // MARK: - §3-F 한계 근접 경고 (emission 단일 진입점)

    private func applyLimitWarning(enabled: Bool, pose: RobotPose, rig: RigSkeleton) {
        guard enabled else {
            if limitWarningWasOn {
                for j in JointID.allCases { rig.setEmissionState(j, .none) }
                limitWarningWasOn = false
            }
            return
        }
        limitWarningWasOn = true
        for j in JointID.allCases {
            let deg = pose.radians(j) * 180 / .pi
            let limit = deg >= 0 ? j.degreeLimits.upperBound : j.degreeLimits.lowerBound
            let ratio = limit != 0 ? abs(deg / limit) : 0
            let state: EmissionState = ratio >= 0.95 ? .warn95 : (ratio >= 0.85 ? .warn85 : .none)
            rig.setEmissionState(j, state)
        }
    }

    /// rig 발 노드 world 위치 → robot frame 발 중심. scene(x=-y,z=-x) 역변환:
    /// robot x = -scene.z, robot y = -scene.x.
    private func footCenters(rig: RigSkeleton)
        -> (left: (x: Double, y: Double), right: (x: Double, y: Double)) {
        func center(_ side: FootSide) -> (x: Double, y: Double) {
            guard let p = rig.footNode(side)?.worldPosition else { return (0, 0) }
            return (x: Double(-p.z), y: Double(-p.x))
        }
        return (center(.left), center(.right))
    }
}
