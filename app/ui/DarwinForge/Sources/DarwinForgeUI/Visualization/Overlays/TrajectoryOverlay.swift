import ForgeCore
import SceneKit

/// **W3 (2026-06-12) · §3-E** — 엔드이펙터(손끝) 궤적.
///
/// # 비유
/// 손끝에 형광펜을 쥐여주고 허공에 남는 잔상을 보는 것 — 모션 키프레임 재생 시
/// 손이 그리는 곡선을 추적한다.
///
/// footTrace 200-풀 패턴 일반화: 트랙당 160 풀, **이전 샘플 대비 ≥4mm 이동 시에만
/// push**(정지 누적 방지), 0-alloc 갱신. 트랙: 좌/우 lower-arm 끝(.lElbow/.rElbow
/// anchor world). Motion 전용(WalkLab 은 기존 footTrace 유지 — 중복 회피).
final class TrajectoryOverlay {

    let container = SCNNode()
    private var enabled = false

    private static let poolSize = 160
    private static let minStep: CGFloat = 0.004   // 4mm
    private static let minStepSq: CGFloat = minStep * minStep

    private struct Track {
        let joint: JointID
        let color: NSColor
        let pool: [SCNNode]
        var count = 0
        var head = 0
        var last: SCNVector3?
    }
    private var tracks: [Track]

    init() {
        container.name = "trajectoryOverlay"
        // self.container 참조 없이 풀 생성(stored property 초기화 전 self 사용 방지).
        func makePool(_ color: NSColor) -> [SCNNode] {
            (0..<TrajectoryOverlay.poolSize).map { _ in
                let s = SCNSphere(radius: 0.006)
                let m = SCNMaterial()
                m.diffuse.contents = color
                m.emission.contents = color
                m.lightingModel = .constant
                s.firstMaterial = m
                let n = SCNNode(geometry: s)
                n.isHidden = true
                return n
            }
        }
        tracks = [
            Track(joint: .lElbow, color: .systemPurple, pool: makePool(.systemPurple)),
            Track(joint: .rElbow, color: .systemTeal, pool: makePool(.systemTeal)),
        ]
        // 초기화 완료 후 그래프 부착.
        for t in tracks { for n in t.pool { container.addChildNode(n) } }
        container.isHidden = true
    }

    func setEnabled(_ on: Bool) {
        if enabled && !on { reset() }
        enabled = on
        container.isHidden = !on
    }

    func update(rig: RigSkeleton) {
        guard enabled else { return }
        container.isHidden = false
        for i in tracks.indices {
            guard let p = rig.linkWorldPosition(tracks[i].joint) else { continue }
            pushIfMoved(&tracks[i], p)
        }
    }

    /// ≥4mm 이동 시에만 ring buffer head 에 기록(0-alloc). 오래된 점일수록 흐려짐.
    private func pushIfMoved(_ track: inout Track, _ p: SCNVector3) {
        if let last = track.last {
            let dx = p.x - last.x, dy = p.y - last.y, dz = p.z - last.z
            if dx * dx + dy * dy + dz * dz < Self.minStepSq { return }
        }
        let node = track.pool[track.head]
        node.position = p
        node.isHidden = false
        track.head = (track.head + 1) % Self.poolSize
        track.count = min(track.count + 1, Self.poolSize)
        track.last = p
        // 나이순 알파 — head 직전이 가장 최근.
        for k in 0..<track.count {
            let idx = (track.head - 1 - k + Self.poolSize) % Self.poolSize
            let alpha = 1.0 - CGFloat(k) / CGFloat(Self.poolSize)
            track.pool[idx].geometry?.firstMaterial?.emission.contents =
                track.color.withAlphaComponent(0.2 + alpha * 0.6)
        }
    }

    private func reset() {
        for i in tracks.indices {
            for n in tracks[i].pool { n.isHidden = true }
            tracks[i].count = 0
            tracks[i].head = 0
            tracks[i].last = nil
        }
    }
}
