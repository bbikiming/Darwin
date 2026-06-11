import ForgeCore
import SceneKit

/// **W3 (2026-06-12)** — 로봇공학 오버레이가 rig 종류(STL `MeshRig` / 프리미티브
/// `DarwinOP2Rig`)에 무관하게 좌표·노드를 질의하기 위한 공통 추상화.
///
/// # 비유
/// 같은 사람을 두고 정장(MeshRig)을 입든 작업복(DarwinOP2Rig)을 입든, 무릎 위치를
/// 묻는 질문엔 같은 방식으로 답해야 한다. `RigSkeleton` 은 "옷"과 무관하게 골격을
/// 가리키는 단일 인터페이스다.
///
/// # 선행 커밋의 이유 (크래시 방지)
/// STL 로드 실패 시 코디네이터는 `DarwinOP2Rig` 폴백을 쓴다. 오버레이가 `MeshRig`
/// 전용 API 에 직접 의존하면 폴백 환경에서 nil/크래시가 난다. 양쪽이 이 프로토콜을
/// 채택하므로 오버레이는 **항상** 동일 경로로 동작한다.
protocol RigSkeleton: AnyObject {
    /// rig 의 루트 노드(IMU tilt wrapper 의 자식). 오버레이 부착 기준 좌표계.
    var rootNode: SCNNode { get }

    /// 관절(=링크) anchor 노드. 축/한계아크 오버레이가 부모 frame 에 부착한다.
    /// 폴백 rig 이 해당 관절을 모형화하지 않으면 nil.
    func jointAnchor(_ joint: JointID) -> SCNNode?

    /// 관절 anchor 의 월드 위치(CoM 질량 가중·EE 궤적용). scene 그래프 transform 합성.
    func linkWorldPosition(_ joint: JointID) -> SCNVector3?

    /// 발 anchor 노드 — 지지 다각형·FSR 접지의 `worldTransform` 원천.
    func footNode(_ side: FootSide) -> SCNNode?

    /// 관절 회전축(SceneKit local frame, 단위 벡터) — 축 화살표 방향.
    func jointAxisDirection(_ joint: JointID) -> SCNVector3?

    /// 링크 emission 상태 설정 — highlight(선택 관절)와 한계 경고가 같은 채널을
    /// 공유하므로 **단일 진입점**으로 통합. 우선순위 warn95 > warn85 > highlight.
    /// `.highlight`/`.none` 중 highlight 채널은 `highlight(_:)` 가, warn 채널은 본
    /// 메서드가 소유한다(구현체 주석 참조).
    func setEmissionState(_ joint: JointID, _ state: EmissionState)

    /// 선택 관절 highlight(기존 동작 보존). 내부적으로 emission 우선순위 합성.
    func highlight(_ joint: JointID?)
}

/// 발 좌/우 식별자 — 지지 다각형·FSR 접지 오버레이가 사용.
enum FootSide: CaseIterable {
    case left, right
}

/// 링크 mesh emission 상태. highlight 와 한계 근접 경고가 동일 emission 채널을
/// 공유하므로 우선순위로 충돌을 해소한다: **warn95 > warn85 > highlight > none**.
enum EmissionState: Equatable {
    case none
    case highlight
    case warn85
    case warn95

    /// 상태별 emission 색(없으면 nil → 원래 색 복원).
    var emissionColor: NSColor? {
        switch self {
        case .none:      return nil
        case .highlight: return NSColor.systemOrange.withAlphaComponent(0.55)
        case .warn85:    return NSColor.systemYellow.withAlphaComponent(0.50)
        case .warn95:    return NSColor.systemRed.withAlphaComponent(0.65)
        }
    }
}
