import Foundation

/// A/B 비교 변수. 한 번에 하나만 바뀌어야 한다 — comparison engine 이 검증.
public enum WalkComparisonVariable: String, Codable, Sendable, CaseIterable {
    case algorithm
    case sign
    case gain
    case intensity
    case preset
    case supportMode
    case none
}

/// 세션이 속한 A/B group / arm.
///
/// 같은 `groupId` + 같은 `variableChanged` + 한쪽이 baseline 이면 비교 가능.
/// preset, support mode, surface 등이 다르면 group 으로 묶지 말 것.
public struct WalkComparisonTag: Codable, Equatable, Sendable {
    public let groupId: String
    public let arm: String
    public let variableChanged: WalkComparisonVariable
    public let baselineSessionId: String?

    public init(groupId: String,
                arm: String,
                variableChanged: WalkComparisonVariable,
                baselineSessionId: String? = nil) {
        self.groupId = groupId
        self.arm = arm
        self.variableChanged = variableChanged
        self.baselineSessionId = baselineSessionId
    }
}
