import Foundation

/// Canonical 20-DOF joint identity. The numbering follows
/// `Framework/include/JointData.h` from the upstream framework. See
/// `docs/research/upstream-survey.md` §4 for the caveat about
/// inconsistent labelling in published materials.
public enum JointID: UInt8, Sendable, Codable, CaseIterable {
    case rShoulderPitch = 1
    case lShoulderPitch = 2
    case rShoulderRoll  = 3
    case lShoulderRoll  = 4
    case rElbow         = 5
    case lElbow         = 6
    case rHipYaw        = 11
    case lHipYaw        = 12
    case rHipRoll       = 13
    case lHipRoll       = 14
    case rHipPitch      = 15
    case lHipPitch      = 16
    case rKnee          = 17
    case lKnee          = 18
    case headPan        = 19
    case headTilt       = 20
}

public extension JointID {
    var bodyPart: BodyPart {
        switch self {
        case .rShoulderPitch, .rShoulderRoll, .rElbow: return .rightArm
        case .lShoulderPitch, .lShoulderRoll, .lElbow: return .leftArm
        case .rHipYaw, .rHipRoll, .rHipPitch, .rKnee:  return .rightLeg
        case .lHipYaw, .lHipRoll, .lHipPitch, .lKnee:  return .leftLeg
        case .headPan, .headTilt:                       return .head
        }
    }
}

public enum BodyPart: String, Sendable, Codable, CaseIterable {
    case rightArm, leftArm, rightLeg, leftLeg, head
}

public struct Joint: Identifiable, Sendable, Equatable, Codable {
    public let id: JointID
    public let robotID: UUID

    public init(id: JointID, robotID: UUID) {
        self.id = id
        self.robotID = robotID
    }
}
