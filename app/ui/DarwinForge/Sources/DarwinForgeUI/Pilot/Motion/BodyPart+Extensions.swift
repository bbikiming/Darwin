import ForgeCore

/// **v1.18.0 (2026-05-21) Phase 3 — `JointID.BodyPart` 확장**.
///
/// critic + architect 권고: 신규 `BodyRegion` enum 만들지 말고 기존 `JointID.BodyPart`
/// (Bus.swift:49) 재사용 + composite blending 의 lower/upper 분류 computed property 만 추가.
///
/// DARwIn-OP2 의 16 DOF + 2 head = 18 joint:
/// - rightArm (3): rShoulderPitch/Roll, rElbow
/// - leftArm (3): lShoulderPitch/Roll, lElbow
/// - rightLeg (6): rHipYaw/Roll/Pitch, rKnee, rAnklePitch/Roll
/// - leftLeg (6): lHipYaw/Roll/Pitch, lKnee, lAnklePitch/Roll
/// - head (2): headPan, headTilt
///
/// composite blending 정책:
/// - lower channel = `rightLeg + leftLeg` (보행 motion 점유)
/// - upper channel = `rightArm + leftArm + head` (named motion 점유)
/// - IK 충돌: rShoulderPitch / lShoulderPitch — walking 의 arm swing 도 사용
///   → composite 의 upper motion 이 두 joint 사용 시 walk 의 arm swing override.
public extension JointID.BodyPart {
    /// 다리 — 보행 (walking) 의 base channel.
    var isLower: Bool {
        self == .rightLeg || self == .leftLeg
    }

    /// 팔 + 머리 — named motion (wave/bow/dance) 의 base channel.
    var isUpper: Bool {
        self == .rightArm || self == .leftArm || self == .head
    }

    /// 정확한 channel 분류 — composite 의 lower / upper / both (충돌).
    var channel: MotionChannel {
        isLower ? .lower : .upper
    }
}

/// composite blending 의 채널 식별자.
public enum MotionChannel: String, Sendable, Equatable, Hashable, CaseIterable {
    case lower   // 다리 — 보행
    case upper   // 팔 + 머리 — named motion
}
