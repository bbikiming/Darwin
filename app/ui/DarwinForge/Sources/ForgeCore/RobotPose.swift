import Foundation

/// 20-DOF 휴머노이드 한 자세. 불변(immutable) — 새 자세는 항상 새 인스턴스.
///
/// 키는 `JointID`, 값은 raw position(0..4095). 누락 키는 2048(0°) 처리.
public struct RobotPose: Sendable, Equatable, Codable {
    /// raw position 매핑.
    public let positions: [JointID: Int]

    public init(positions: [JointID: Int] = [:]) {
        self.positions = positions
    }

    /// 모든 관절이 중심(2048)인 기본 자세.
    public static let center: RobotPose = {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases { dict[j] = 2048 }
        return RobotPose(positions: dict)
    }()

    /// "준비 자세" — ROBOTIS DARwIn-OP framework `JointData::Initialize()` 정확값.
    ///
    /// 출처: github.com/ROBOTIS-GIT/DARwIn-OP-Framework/Linux/project/walking_tuner +
    /// JointData.cpp. (4096 step / 360° = 11.378 raw per degree).
    ///
    /// 안전 검증됨 — RoboCup 2014+ 경기 + 수천 시간 동작 데이터.
    public static let walkReady: RobotPose = {
        // ROBOTIS framework 표준 각도 (°). 부호: 오른쪽 음수, 왼쪽 양수 (좌우 대칭).
        let degrees: [JointID: Double] = [
            .rShoulderPitch: -45,   // 팔 살짝 앞 (자연 직립)
            .lShoulderPitch: +45,
            .rShoulderRoll:  -17,   // 어깨 살짝 벌림
            .lShoulderRoll:  +17,
            .rElbow:         +20,   // 팔꿈치 살짝 굽힘
            .lElbow:         -20,
            .rHipYaw:          0,
            .lHipYaw:          0,
            .rHipRoll:         0,
            .lHipRoll:         0,
            .rHipPitch:       -8,   // 살짝 굽힘 — walk start posture
            .lHipPitch:       +8,
            .rKnee:          +16,   // 무릎 굽힘
            .lKnee:           -16,
            .rAnklePitch:     -7,   // 발 평면 보상
            .lAnklePitch:     +7,
            .rAnkleRoll:       0,
            .lAnkleRoll:       0,
            .headPan:          0,
            .headTilt:         0
        ]
        var map: [JointID: Int] = [:]
        for (j, d) in degrees {
            map[j] = Kinematics.raw(fromDegrees: d)
        }
        return RobotPose(positions: map)
    }()

    /// 다윈 자연 직립 자세 — 양팔 옆구리, 다리 직립, 머리 정면.
    /// ROBOTIS framework standing posture 변형:
    ///   - shoulder pitch 0° (팔 자연스럽게 내림)
    ///   - shoulder roll ±17° (자연 벌림)
    ///   - elbow ±15° (가벼운 굽힘)
    ///   - 다리 모두 0° (직립)
    /// 사용자 기본 자세 — 안전 + 자기충돌 없음.
    public static let idle: RobotPose = {
        let degrees: [JointID: Double] = [
            .rShoulderPitch:  0,
            .lShoulderPitch:  0,
            .rShoulderRoll: -17,
            .lShoulderRoll: +17,
            .rElbow:        +15,
            .lElbow:        -15,
            .rHipYaw:         0, .lHipYaw:        0,
            .rHipRoll:        0, .lHipRoll:       0,
            .rHipPitch:       0, .lHipPitch:      0,
            .rKnee:           0, .lKnee:          0,
            .rAnklePitch:     0, .lAnklePitch:    0,
            .rAnkleRoll:      0, .lAnkleRoll:     0,
            .headPan:         0, .headTilt:       0,
        ]
        var map: [JointID: Int] = [:]
        for (j, d) in degrees {
            map[j] = Kinematics.raw(fromDegrees: d)
        }
        return RobotPose(positions: map)
    }()

    /// T-pose — 팔을 수평으로 양 옆으로 펼친 진단용 표준 자세.
    /// URDF shoulder_roll initial rpy(±45°) 상쇄 + 추가 ±45°로 총 90°.
    public static let tPose: RobotPose = {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases { dict[j] = 2048 }
        // 좌측: shoulder_roll axis (-1,0,0) + initial rpy(+45°). 양수 명령 → 팔이 더 위로.
        // 수평이 되려면 initial 45°에서 +45° 더 필요 → +45° (raw 명령).
        dict[.lShoulderRoll] = Kinematics.raw(fromDegrees: 45)
        // 우측: initial rpy(-45°). 수평까지 -45° 필요.
        dict[.rShoulderRoll] = Kinematics.raw(fromDegrees: -45)
        // 팔꿈치 펴기 — URDF initial rpy(0, -π/2, 0)이라 0°에서 이미 펴진 상태.
        return RobotPose(positions: dict)
    }()

    // MARK: - Accessors

    /// 한 관절의 raw position (없으면 2048).
    public func raw(_ joint: JointID) -> Int { positions[joint] ?? 2048 }

    /// 한 관절의 라디안.
    public func radians(_ joint: JointID) -> Double {
        Kinematics.radians(fromRaw: raw(joint))
    }

    /// 한 관절의 도.
    public func degrees(_ joint: JointID) -> Double {
        Kinematics.degrees(fromRaw: raw(joint))
    }

    // MARK: - Mutation (immutable updates)

    /// 한 관절을 새 raw 값으로 교체. 한계로 자동 클램프.
    public func with(_ joint: JointID, raw value: Int) -> RobotPose {
        var copy = positions
        copy[joint] = value.clamped(to: joint.rawLimits)
        return RobotPose(positions: copy)
    }

    /// 여러 관절을 한 번에 교체.
    public func with(_ updates: [JointID: Int]) -> RobotPose {
        var copy = positions
        for (j, v) in updates { copy[j] = v.clamped(to: j.rawLimits) }
        return RobotPose(positions: copy)
    }

    /// 좌우 대칭 자세 (오른쪽 ↔ 왼쪽 swap, yaw/roll 축은 부호 반전).
    public func mirrored() -> RobotPose {
        var out: [JointID: Int] = [:]
        for j in JointID.allCases {
            let src = j.mirrored
            let raw = positions[src] ?? 2048
            if j.mirrorSignFlip {
                // 2048 기준 반전.
                out[j] = (4096 - raw).clamped(to: j.rawLimits)
            } else {
                out[j] = raw
            }
        }
        return RobotPose(positions: out)
    }

    // MARK: - Diff

    /// `prior`와 비교해 raw 값이 다른 관절 목록 (안정 순서: JointID.allCases 순).
    /// `prior == nil` 이면 모든 관절(첫 동기화 시).
    ///
    /// P0-B: 슬라이더 한 번 움직임에 16개 모두 발행하던 패턴 → 변경된 관절만.
    /// 패킷 수 = 변경 관절 수. 1관절만 바뀌면 1 패킷.
    /// 출처: DynamixelSDK `groupBulkWrite`, ROS `dynamixel_workbench`.
    public func changedJoints(from prior: RobotPose?) -> [JointID] {
        guard let prior else { return JointID.allCases }
        return JointID.allCases.filter { self.raw($0) != prior.raw($0) }
    }

    // MARK: - Interpolation

    /// 두 자세 간 선형 보간. `t=0`은 self, `t=1`은 other.
    public func lerp(to other: RobotPose, t: Double) -> RobotPose {
        let tt = t.clamped(to: 0...1)
        var out: [JointID: Int] = [:]
        for j in JointID.allCases {
            let a = Double(self.raw(j))
            let b = Double(other.raw(j))
            out[j] = Int((a + (b - a) * tt).rounded())
        }
        return RobotPose(positions: out)
    }
}
