import ForgeCore
import SceneKit

/// **W3 (2026-06-12) · §3-D** — IMU 3D 인공 수평선.
///
/// # 비유
/// 비행기 계기판의 인공 수평선 — 기체(로봇)가 기울어도 수평선은 항상 수평을
/// 유지하므로, 둘의 어긋남으로 기울기를 즉시 읽는다.
///
/// 허리 높이(y=0.30)에 반경 0.45m 수평 ring + 전방 방위 tick 4개. **`tiltNode`
/// 바깥(scene root)에 부착** — 로봇이 기울면 ring 대비 기울기가 즉시 보인다.
/// 수치 표기는 SwiftUI HUD 담당(3D 는 기하만). pose 데이터 불필요 — 표시 토글만.
final class HorizonOverlay {

    let container = SCNNode()
    private var enabled = false

    private static let height: CGFloat = 0.30
    private static let radius: CGFloat = 0.45

    init() {
        container.name = "horizonOverlay"
        let ring = SCNTorus(ringRadius: Self.radius, pipeRadius: 0.002)
        ring.firstMaterial = Self.mat(NSColor.systemTeal.withAlphaComponent(0.4))
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, Self.height, 0)
        container.addChildNode(ringNode)

        // 전방(-Z)·후방·좌·우 방위 tick 4개.
        let dirs: [SCNVector3] = [SCNVector3(0, 0, -1), SCNVector3(0, 0, 1),
                                  SCNVector3(-1, 0, 0), SCNVector3(1, 0, 0)]
        let forwardColor = NSColor.systemTeal
        for (i, d) in dirs.enumerated() {
            let tick = SCNBox(width: 0.012, height: 0.012, length: 0.03, chamferRadius: 0)
            tick.firstMaterial = Self.mat((i == 0 ? NSColor.systemGreen : forwardColor)
                .withAlphaComponent(0.7))
            let n = SCNNode(geometry: tick)
            n.position = SCNVector3(d.x * Self.radius, Self.height, d.z * Self.radius)
            container.addChildNode(n)
        }
        container.isHidden = true
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        container.isHidden = !on
    }

    private static func mat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        return m
    }
}
