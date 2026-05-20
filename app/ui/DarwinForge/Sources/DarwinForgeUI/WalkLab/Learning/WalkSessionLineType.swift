import Foundation

/// Walk session JSONL 줄 타입. v2 에서 명시화. v1 로그는 첫 줄이 header, 나머지가 sample 이라는
/// 암묵 규약을 따른다.
public enum WalkSessionLineType: String, Codable, Sendable, CaseIterable {
    case header
    case sample
    case event
    case footer
}

/// 스키마 버전 — v1 (legacy, 암묵 규약) / v2 (line type + 확장 필드).
///
/// 새 로그는 항상 `.v2` 로 기록한다. v1 로그는 decoder 가 자동 추정한다.
public enum WalkSessionSchemaVersion: Int, Codable, Sendable, CaseIterable {
    case v1 = 1
    case v2 = 2

    public static let current: WalkSessionSchemaVersion = .v2
}

/// Decoder helper — JSONL 한 줄을 line type 으로 분류.
///
/// v2: `"type"` 필드 명시.
/// v1: 첫 줄에 `sessionId` 가 있으면 header, 그 외는 sample.
public enum WalkSessionLineKind: Equatable, Sendable {
    case header
    case sample
    case event
    case footer
    case unknown

    static func from(rawType: String?, hasSessionId: Bool, hasSampleT: Bool, hasEventKind: Bool) -> WalkSessionLineKind {
        if let rt = rawType, let lt = WalkSessionLineType(rawValue: rt) {
            switch lt {
            case .header: return .header
            case .sample: return .sample
            case .event: return .event
            case .footer: return .footer
            }
        }
        if hasSessionId { return .header }
        if hasEventKind { return .event }
        if hasSampleT { return .sample }
        return .unknown
    }
}
