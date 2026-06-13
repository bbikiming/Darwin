import ForgeCore
import SceneKit

/// **W3 (2026-06-12)** — 활성화할 로봇공학 오버레이 집합.
///
/// 화면(preset)마다 기본값이 다르며(설계 §5 매트릭스), 사용자는 `ViewportControls`
/// 팝오버로 토글한다. `OptionSet` 이라 비트 단위 결합/검사가 0-alloc.
public struct RobotOverlaySet: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// CoM 투영점 + 지지 다각형(ZMP verdict 색).
    public static let com            = RobotOverlaySet(rawValue: 1 << 0)
    /// 선택 관절 회전축 + 한계각 아크.
    public static let jointAxis      = RobotOverlaySet(rawValue: 1 << 1)
    /// FSR 발 접지 인디케이터.
    public static let footContact    = RobotOverlaySet(rawValue: 1 << 2)
    /// IMU 3D 인공 수평선.
    public static let horizon        = RobotOverlaySet(rawValue: 1 << 3)
    /// 엔드이펙터(손끝) 궤적.
    public static let trajectory     = RobotOverlaySet(rawValue: 1 << 4)
    /// 관절 한계 근접 경고(링크 emission tint).
    public static let limitWarning   = RobotOverlaySet(rawValue: 1 << 5)

    /// 화면별 기본값 — **전부 OFF** (사용자 결정 2026-06-12: 오버레이는 해제가 기본,
    /// 필요할 때 ViewportControls 팝오버에서 켠다). 설계 §5 의 화면별 on/off 매트릭스는
    /// 팝오버의 토글 항목 구성으로만 남는다.
    public static func defaults(for preset: ScenePreset) -> RobotOverlaySet {
        _ = preset
        return []
    }

    /// 사용자 토글 UI 노출 순서·라벨(설계 §5).
    public static let toggleable: [(overlay: RobotOverlaySet, label: String)] = [
        (.com,          "CoM · 지지 다각형"),
        (.jointAxis,    "관절 축 · 한계각"),
        (.footContact,  "FSR 발 접지"),
        (.horizon,      "IMU 수평선"),
        (.trajectory,   "EE 궤적"),
        (.limitWarning, "한계 근접 경고"),
    ]
}

/// 오버레이가 소비하는 외부 텔레메트리 — WalkLab/Pilot 세션이 채운다.
/// 미연결(전부 nil)이면 각 오버레이가 휴리스틱(접지: sole y<0.005m, CoM: 기구학)으로 폴백.
public struct SceneOverlayData: Equatable {
    /// 좌/우 발 FSR(ID 112/111). nil 이면 접지 휴리스틱.
    public var fsrLeft: FsrReading?
    public var fsrRight: FsrReading?
    /// 외부 CoM 추정(robot frame, m). nil 이면 질량 가중 기구학으로 자체 계산.
    public var comOverride: SIMD3<Double>?
    /// ZMP 안정성 판정 — 지지 다각형 색 결정.
    public var zmpVerdict: ZMPMonitor.Verdict?

    public init(fsrLeft: FsrReading? = nil,
                fsrRight: FsrReading? = nil,
                comOverride: SIMD3<Double>? = nil,
                zmpVerdict: ZMPMonitor.Verdict? = nil) {
        self.fsrLeft = fsrLeft
        self.fsrRight = fsrRight
        self.comOverride = comOverride
        self.zmpVerdict = zmpVerdict
    }
}

// MARK: - 좌표 변환 (robot ROS frame → SceneKit world)

/// ROS REP-103(X 전방·Y 좌·Z 상) → SceneKit(X 우·Y 상·Z 카메라쪽) 변환.
/// `MeshRig` 루트 회전과 동일 규약: X+→Z-, Y+→X-, Z+→Y+.
enum SceneFrame {
    static func fromRobot(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
        SCNVector3(CGFloat(-y), CGFloat(z), CGFloat(-x))
    }
    static func fromRobot(_ v: SIMD3<Double>) -> SCNVector3 {
        fromRobot(v.x, v.y, v.z)
    }
}
