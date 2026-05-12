import Foundation

/// Remote Pilot 기능 단계별 활성화 매트릭스.
/// PRD §4.1 — "한 번 설계하고, 단계별로 활성화한다".
public struct PilotFeatureFlags: Sendable {

    public enum Stage: String, Sendable {
        case v1_0, v1_1, v1_5, v2
    }

    public let active: Stage

    // v1.0 — Action Bar 7페이지 실 송출 + UI 골격
    public var actionBarMain: Bool  { true }
    public var armSequence: Bool    { true }
    public var emergencyStop: Bool  { true }

    // v1.1 — IMU + 자동낙상복구 + Head 추적
    public var imuTelemetry: Bool   { active >= .v1_1 }
    public var autoRecovery: Bool   { active >= .v1_1 }
    public var headTracking: Bool   { active >= .v1_1 }

    // v1.5 — 카메라 + Ball-Follow + 더 보기
    public var cameraView: Bool     { active >= .v1_5 }
    public var ballFollow: Bool     { active >= .v1_5 }
    public var actionBarMore: Bool  { active >= .v1_5 }

    // v2 — D-pad 실 모터 송출 (BLOCKER C3 해결 후)
    public var dpadRealMotor: Bool  { active >= .v2 }

    public static let `default` = PilotFeatureFlags(active: .v1_0)
}

// MARK: - Stage ordering

extension PilotFeatureFlags.Stage: Comparable {
    private var order: Int {
        switch self {
        case .v1_0: return 0
        case .v1_1: return 1
        case .v1_5: return 2
        case .v2:   return 3
        }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}
