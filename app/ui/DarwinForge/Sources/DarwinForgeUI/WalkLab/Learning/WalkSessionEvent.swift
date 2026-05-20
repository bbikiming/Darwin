import Foundation

/// 보행 중 사용자 / 안전 / 설정 변경 이벤트. sample 과 분리해서 저장.
///
/// kind 예: sessionStart, sessionStop, presetChange, algorithmModeChange,
/// signConventionChange, intensityChange, observeOnlyEnabled, robotApplyEnabled,
/// imuStale, imuRecovered, busWriteFailure, emergencyStop, userNote.
public struct WalkSessionEventV2: Codable, Equatable, Sendable {
    public let type: String
    public let schemaVersion: Int
    public let tMs: Double
    public let wallTimeIso: String
    public let kind: String
    public let severity: String
    public let message: String
    public let payload: [String: String]

    public init(tMs: Double,
                wallTimeIso: String,
                kind: String,
                severity: String = "info",
                message: String,
                payload: [String: String] = [:]) {
        self.type = WalkSessionLineType.event.rawValue
        self.schemaVersion = WalkSessionSchemaVersion.v2.rawValue
        self.tMs = tMs
        self.wallTimeIso = wallTimeIso
        self.kind = kind
        self.severity = severity
        self.message = message
        self.payload = payload
    }
}

/// 표준 이벤트 종류. raw string 유지하면서 자주 쓰는 것만 enum 으로 노출.
public enum WalkSessionEventKind: String, Sendable, CaseIterable {
    case sessionStart
    case sessionStop
    case presetChange
    case algorithmModeChange
    case signConventionChange
    case gainProfileChange
    case intensityChange
    case observeOnlyEnabled
    case robotApplyEnabled
    case imuStale
    case imuRecovered
    case busWriteFailure
    case busReadFailure
    case emergencyStop
    case balanceLost
    case thermalAlarm
    case userNote
}

/// 이벤트 severity — UI 색 / 정렬 / 필터 기준.
public enum WalkSessionEventSeverity: String, Sendable, CaseIterable {
    case info
    case notice
    case warning
    case error
    case critical
}

/// Session footer — 종료 시 한 줄. 파일이 정상 종료됐는지 확인할 수 있는 기록.
public struct WalkSessionFooterV2: Codable, Equatable, Sendable {
    public let type: String
    public let schemaVersion: Int
    public let endTimeIso: String
    public let totalSamples: Int
    public let totalEvents: Int
    public let endedNormally: Bool
    public let endReason: String

    public init(endTimeIso: String,
                totalSamples: Int,
                totalEvents: Int,
                endedNormally: Bool,
                endReason: String) {
        self.type = WalkSessionLineType.footer.rawValue
        self.schemaVersion = WalkSessionSchemaVersion.v2.rawValue
        self.endTimeIso = endTimeIso
        self.totalSamples = totalSamples
        self.totalEvents = totalEvents
        self.endedNormally = endedNormally
        self.endReason = endReason
    }
}
