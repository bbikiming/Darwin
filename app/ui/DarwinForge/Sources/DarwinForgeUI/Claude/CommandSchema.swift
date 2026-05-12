import Foundation

/// DarwinForge가 Claude에게 노출하는 9개 forge 도구 + 거부 +
/// composite intent의 정의·인자·안전 범위.
///
/// 근거:
/// - Anthropic strict tool use (platform.claude.com/.../tool-use/strict-tool-use)
/// - SayCan / Code as Policies — LLM은 사전 정의 스킬만 호출
/// - 본 프로젝트 forge-cli의 9개 서브커맨드 + forge-ffi 22 함수 surface
///
/// 안전 클리핑 한계는 docs/architecture/joint-conventions.md +
/// docs/architecture/walking-engine.md (op2_walking_module/config/param.yaml) 인용.
public enum ForgeTool: String, CaseIterable, Codable, Sendable {
    /// USB 직렬 포트 목록.
    case ports
    /// 디바이스 ping.
    case ping
    /// 관절 ID 범위 스캔.
    case scan
    /// CM 보드 상태 (모델/펌웨어/전압/버튼).
    case board_snapshot
    /// 한 관절 상태 (위치/속도/부하/온도/전압/토크).
    case joint_state
    /// 관절 위치 명령 (안전 클립).
    case joint_set_position
    /// 관절 힘 켜기/끄기.
    case joint_torque
    /// 비상 정지 — LLM 경로 우회 가능.
    case emergency_stop
    /// 모션 파일 정보.
    case motion_inspect
    /// (Composite) 깨우기 — 토크 ON + 자세 안정.
    case wake_up
    /// (Composite) 재우기 — 안전 자세 + 토크 OFF.
    case sleep
    /// (Composite) 상태 보고 — board + joint state(all).
    case status_report
    /// 명명 자세 적용 — PoseLibrary 의 id 로 즉시 자세 변경 (SafeMotion 검증).
    case apply_named_pose
    /// 자연어 → 모션 페이지 빌드. 사용자 요청을 MotionBuilder 가 분석해 페이지 생성.
    case build_motion
    /// 자세 검색 — keyword 로 PoseLibrary 검색 후 결과 표시 (실행 안 함).
    case search_pose
    /// 거부 (안전 한계 외 또는 모호한 요청).
    case refuse

    /// 사용자에게 보여줄 한국어 라벨.
    public var koreanLabel: String {
        switch self {
        case .ports: return "USB 포트 찾기"
        case .ping: return "응답 확인"
        case .scan: return "관절 스캔"
        case .board_snapshot: return "보드 상태 확인"
        case .joint_state: return "관절 상태 확인"
        case .joint_set_position: return "관절 움직이기"
        case .joint_torque: return "관절 힘 켜기/끄기"
        case .emergency_stop: return "긴급정지"
        case .motion_inspect: return "동작 파일 정보"
        case .wake_up: return "로봇 깨우기"
        case .sleep: return "로봇 재우기"
        case .status_report: return "상태 보고"
        case .apply_named_pose: return "명명 자세 적용"
        case .build_motion: return "모션 만들기"
        case .search_pose: return "자세 검색"
        case .refuse: return "거부"
        }
    }

    /// 모터 동작 여부 — true면 HITL 승인 게이트 강제.
    public var movesMotors: Bool {
        switch self {
        case .joint_set_position, .joint_torque, .wake_up, .sleep,
             .apply_named_pose, .build_motion:
            return true
        case .emergency_stop:
            return false  // 즉시 실행 (안전 critical)
        case .ports, .ping, .scan, .board_snapshot, .joint_state, .motion_inspect,
             .status_report, .search_pose, .refuse:
            return false
        }
    }
}

/// Claude가 반환하는 응답 구조.
public struct CommandPlan: Codable, Sendable {
    public let tool: ForgeTool
    public let args: [String: ArgValue]
    /// 사용자에게 그대로 들려줄 한국어 응답.
    public let speak: String
    /// 사용자 승인 필요 여부.
    public let needs_confirmation: Bool
    /// 0.0~1.0 — Claude 자기 신뢰도.
    public let confidence: Double

    public init(
        tool: ForgeTool,
        args: [String: ArgValue] = [:],
        speak: String,
        needs_confirmation: Bool,
        confidence: Double = 0.9
    ) {
        self.tool = tool
        self.args = args
        self.speak = speak
        self.needs_confirmation = needs_confirmation
        self.confidence = confidence
    }
}

/// 도구 인자 값 — JSON에서 string/int/double/bool 모두 받을 수 있도록.
public enum ArgValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.typeMismatch(
            ArgValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "ArgValue: expected string/int/double/bool")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .string(let s):
            switch s.lowercased() { case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil }
        default: return nil
        }
    }

    public func toDisplayString() -> String {
        switch self {
        case .string(let v): return "\"\(v)\""
        case .int(let v): return String(v)
        case .double(let v): return String(format: "%.3f", v)
        case .bool(let v): return v ? "true" : "false"
        }
    }
}

/// 안전 클리핑 한계 — 본 모듈에서만 정의 (LLM 환각 차단의 마지막 방어선).
public enum SafetyLimits {
    /// MX-28T position raw 한계 — 보수적 기본값 (joint-conventions.md).
    public static let jointPositionMin: Int = 1024  // -90°
    public static let jointPositionMax: Int = 3072  // +90°

    /// Walk amplitude 한계 — op2_walking_module/config/param.yaml.
    public static let walkXMin: Double = -0.04   // m/cycle
    public static let walkXMax: Double = 0.04
    public static let walkYMin: Double = -0.03
    public static let walkYMax: Double = 0.03
    public static let walkAMin: Double = -0.5    // rad/cycle
    public static let walkAMax: Double = 0.5

    /// Baudrate 안전값.
    public static let defaultBaud: Int = 1_000_000

    /// 관절 ID 범위.
    public static let validJointIds: Set<Int> = [1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]

    /// 클립 + 변경 여부 반환.
    public static func clipJointPosition(_ raw: Int) -> (clipped: Int, wasClipped: Bool) {
        let clipped = max(jointPositionMin, min(jointPositionMax, raw))
        return (clipped, clipped != raw)
    }
    public static func clipWalkX(_ x: Double) -> (clipped: Double, wasClipped: Bool) {
        let clipped = max(walkXMin, min(walkXMax, x))
        return (clipped, clipped != x)
    }
    public static func isValidJointId(_ id: Int) -> Bool {
        validJointIds.contains(id) || id == 200 || id == 254
    }
}
