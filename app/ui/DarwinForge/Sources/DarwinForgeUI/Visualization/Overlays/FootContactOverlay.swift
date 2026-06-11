import ForgeCore
import SceneKit

/// **W3 (2026-06-12) · §3-C** — FSR 발 접지 인디케이터.
///
/// # 비유
/// 발바닥 압력 센서를 발 그림 위에 색칠하는 것 — 어느 부분에 체중이 실리는지,
/// 압력 중심(CoP)이 어디인지 보여준다.
///
/// 발당: 2×2 압력 quad 4(압력→알파) + 접지 ring 1 + CoP dot 1 = 6노드 고정 풀.
/// 데이터: `FsrReading`(4셀+CoP). 미연결 시 sole worldPosition.y < 0.005m 휴리스틱.
final class FootContactOverlay {

    let container = SCNNode()
    private var enabled = false

    /// 접지 판정 높이(m) — FSR 미연결 시 휴리스틱.
    private static let contactHeight: CGFloat = 0.005
    /// FSR 셀 raw 정규화 상한.
    private static let cellMax: Double = 1023

    private struct FootNodes {
        let cells: [SCNNode]   // 4 (FL, FR, RR, RL)
        let ring: SCNNode
        let cop: SCNNode
    }
    private var feet: [FootSide: FootNodes] = [:]

    init() {
        container.name = "footContactOverlay"
        for side in FootSide.allCases {
            let cells = (0..<4).map { _ -> SCNNode in
                let q = SCNPlane(width: 0.028, height: 0.040)
                q.firstMaterial = Self.mat(.systemOrange)
                let n = SCNNode(geometry: q)
                n.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)   // 바닥에 눕힘.
                n.isHidden = true
                container.addChildNode(n)
                return n
            }
            let ring = SCNNode(geometry: {
                let t = SCNTorus(ringRadius: 0.07, pipeRadius: 0.0025)
                t.firstMaterial = Self.mat(NSColor.systemOrange.withAlphaComponent(0.5))
                return t
            }())
            ring.isHidden = true
            container.addChildNode(ring)
            let cop = SCNNode(geometry: {
                let s = SCNSphere(radius: 0.006)
                s.firstMaterial = Self.mat(.systemCyan)
                return s
            }())
            cop.isHidden = true
            container.addChildNode(cop)
            feet[side] = FootNodes(cells: cells, ring: ring, cop: cop)
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { hideAll() }
    }

    func update(rig: RigSkeleton, data: SceneOverlayData?) {
        guard enabled else { return }
        updateFoot(.left, rig: rig, fsr: data?.fsrLeft)
        updateFoot(.right, rig: rig, fsr: data?.fsrRight)
    }

    private func updateFoot(_ side: FootSide, rig: RigSkeleton, fsr: FsrReading?) {
        guard let nodes = feet[side], let footNode = rig.footNode(side) else { return }
        let fp = footNode.worldPosition
        let grounded = fsr != nil ? (fsr!.totalPressureRaw > 0) : (fp.y < Self.contactHeight)

        // ── 2×2 셀: FL/FR/RR/RL 위치(scene XZ, 발 중심 기준).
        let cellCenters: [SCNVector3] = [
            SCNVector3(fp.x - 0.015, 0.004, fp.z - 0.022),  // FL
            SCNVector3(fp.x + 0.015, 0.004, fp.z - 0.022),  // FR
            SCNVector3(fp.x + 0.015, 0.004, fp.z + 0.022),  // RR
            SCNVector3(fp.x - 0.015, 0.004, fp.z + 0.022),  // RL
        ]
        let cellVals: [Double] = fsr.map {
            [Double($0.cellFrontLeft), Double($0.cellFrontRight),
             Double($0.cellRearRight), Double($0.cellRearLeft)]
        } ?? Array(repeating: grounded ? Self.cellMax * 0.4 : 0, count: 4)

        for i in 0..<4 {
            let node = nodes.cells[i]
            let alpha = CGFloat(min(0.7, cellVals[i] / Self.cellMax * 0.7))
            if alpha <= 0.01 { node.isHidden = true; continue }
            node.position = cellCenters[i]
            node.geometry?.firstMaterial?.diffuse.contents = NSColor.systemOrange.withAlphaComponent(alpha)
            node.geometry?.firstMaterial?.emission.contents = NSColor.systemOrange.withAlphaComponent(alpha)
            node.isHidden = false
        }

        // ── 접지 ring.
        if grounded {
            nodes.ring.position = SCNVector3(fp.x, 0.004, fp.z)
            nodes.ring.isHidden = false
        } else {
            nodes.ring.isHidden = true
        }

        // ── CoP dot(접지 + FSR 있을 때만).
        if grounded, let f = fsr {
            let cx = CGFloat(Double(f.centerX) / 127.0) * 0.04
            let cz = CGFloat(Double(f.centerY) / 127.0) * 0.05
            nodes.cop.position = SCNVector3(fp.x + cx, 0.006, fp.z + cz)
            nodes.cop.isHidden = false
        } else {
            nodes.cop.isHidden = true
        }
    }

    private func hideAll() {
        for (_, n) in feet {
            for c in n.cells { c.isHidden = true }
            n.ring.isHidden = true
            n.cop.isHidden = true
        }
    }

    private static func mat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.blendMode = .alpha
        return m
    }
}
