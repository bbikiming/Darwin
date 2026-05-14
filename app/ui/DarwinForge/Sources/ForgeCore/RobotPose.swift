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

    /// **Action page 9 walkready** — `motion_4096.bin` 의 page 9 step 0 raw 그대로.
    ///
    /// ## ⚠️ 이건 "공식 walkReady" 두 가지 중 하나다 (Codex audit P0-3, 2026-05-14)
    ///
    /// ROBOTIS-OP2 에는 walkReady 라는 이름의 자세가 **두 곳에** 존재한다:
    ///
    /// | anchor | 출처 | hip pitch | knee | ankle |
    /// |---|---|---:|---:|---:|
    /// | **이 `walkReady`** (Action page 9) | `motion_4096.bin` page 9 step 0 | ±36° | ±53° | ±30° |
    /// | OP2 manager init pose (Rust 만 사용) | `op2_manager/config/ini_pose.yaml` | ±65° | ±130° | ±70° |
    /// | 차이 | | **29°** | **77°** | **40°** |
    ///
    /// **이 자세는 Action 기반 단발 anchor** — Pilot teleop ARM, BalanceCritical 안전
    /// 검증, Motion Studio 의 walk_ready 슬롯 모두 page 9 자세를 가리킨다.
    /// 걷기 시작 자세 (`op2_manager init pose`) 와 혼동하지 말 것 — 그쪽은 Rust
    /// `walk::ini_pose::OP2_MANAGER_INI_POSE_DEGREES` 에 있으며 SOCCER demo 의
    /// 6 초 부드러운 진입에만 쓴다.
    ///
    /// 깊은 squat 자세: hip pitch ±36° / knee ±53° / ankle pitch ±30°.
    /// 무릎을 크게 굽혀 무게중심(CoM) 을 양 발 위에 정확히 정렬한다.
    ///
    /// # 변경 이력 (사용자 안전 보고 기반)
    ///
    /// 1. **초기 (Sprint 10)**: ROBOTIS `JointData::Initialize()` 의
    ///    hip±8 / knee±16 / ankle∓7 작은 각도 사용 → 무릎 굽힘이 부족해
    ///    충격 흡수 안 됨 + ankle 비대칭으로 뒤쪽 lean → **뒤로 넘어짐**.
    /// 2. **Sprint 15 hotfix**: 하체 모두 0° (T-pose 직립) 으로 변경 → 막대
    ///    처럼 직립이라 균형 잡으면 안 넘어지지만 충격 흡수 능력 0,
    ///    무거운 robot 이라 약간만 흔들려도 **뒤로 넘어짐**. 사용자 추가 보고.
    /// 3. **현재 (Sprint 16)**: ROBOTIS 공식 page 9 step 0 의 raw 값 그대로
    ///    채택. hip±36° 의 deep squat 으로 무릎이 충격 흡수 + ankle 보정으로
    ///    CoM 정확히 발 위. ROBOTIS 공식 캘리브레이션 잔차로 일부 관절 R+L sum
    ///    이 4095 와 약간 다름 — 예: shoulder_pitch R+L=4016 (어깨 7° 잔차).
    ///    따라서 `walkReady.mirrored() ≠ walkReady` 가 의도된 동작.
    ///    `RobotPoseTests.testWalkReadyMirrorIsNotIdentity` 가 이를 lock-in.
    ///
    /// # 좌표계
    ///
    /// - hip_pitch 음수 (R) / 양수 (L) = 앞으로 굽힘 (squat 시작).
    /// - knee 양수 (R) / 음수 (L) = 무릎 굽힘.
    /// - ankle_pitch 양수 (R) / 음수 (L) = 발끝 위로 (hip squat 의 무게중심 보정).
    ///
    /// 대안: `idle` 자세 (모든 다리 0°) 는 정비 스탠드 거치 / 진단용. 실 robot
    /// 거동 시는 반드시 `walkReady` 사용.
    public static let walkReady: RobotPose = {
        // ROBOTIS motion_4096.bin page 9 step 0 의 raw 값을 직접 사용.
        // raw → degree 변환 시 약간의 반올림이 있어 raw 그대로가 가장 정확.
        // Mirror 검증: R+L sum (4015~4096, walkReady 의 정의값과 일치).
        let raw: [JointID: Int] = [
            // 상체 — ROBOTIS 공식 mirror 패턴 유지.
            .rShoulderPitch: 1498,   // ≈ -48° 자연 직립
            .lShoulderPitch: 2518,   // ≈ +41°
            .rShoulderRoll:  1845,   // ≈ -18° 어깨 살짝 벌림
            .lShoulderRoll:  2248,   // ≈ +18°
            .rElbow:         2381,   // ≈ +29° 팔꿈치 굽힘
            .lElbow:         1712,   // ≈ -29°
            // 하체 — **ROBOTIS 공식 deep squat** (CoM 안정 핵심).
            .rHipYaw:        2048,   // 0° (정면)
            .lHipYaw:        2048,
            .rHipRoll:       2052,   // ≈ +0.4°
            .lHipRoll:       2044,   // ≈ -0.4°
            .rHipPitch:      1637,   // ≈ -36° 다리 앞으로 굽힘 (squat 시작)
            .lHipPitch:      2459,   // ≈ +36° (mirror)
            .rKnee:          2653,   // ≈ +53° 무릎 깊게 굽힘 (충격 흡수)
            .lKnee:          1443,   // ≈ -53° (mirror)
            .rAnklePitch:    2389,   // ≈ +30° 발끝 위로 (CoM 보정)
            .lAnklePitch:    1707,   // ≈ -30° (mirror)
            .rAnkleRoll:     2057,   // ≈ +0.8°
            .lAnkleRoll:     2039,   // ≈ -0.8°
            .headPan:        2048,   // 0° 정면
            .headTilt:       2161,   // ≈ +10° 약간 위 (시선)
        ]
        return RobotPose(positions: raw)
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

    /// 좌우 대칭 자세 — 모든 좌·우 pair swap + `mirrorSignFlip` 대상은 12-bit reflect.
    ///
    /// Reflect 공식: `4095 - raw` (12-bit MAX_POSITION 기준). Rust
    /// `forge-core::synth::ops::mirror::reflect_12bit` 와 정확히 동일 — cross-language
    /// 정합. 종전엔 Swift 가 `4096 - raw` (center-2048 mirror) 였어서 Rust 측에서 mirror
    /// 된 page 가 Swift 로 로딩될 때 모든 SwapReflect 관절이 1 raw (~0.088°) 어긋났음.
    /// 1 raw 는 물리적으로 무해하지만 docstring "Rust mirror 와 같다" 주장이 거짓이 되어
    /// 검증 fixture 가 한쪽에서만 통과하는 cross-language 디버깅 위험.
    public func mirrored() -> RobotPose {
        var out: [JointID: Int] = [:]
        for j in JointID.allCases {
            let src = j.mirrored
            let raw = positions[src] ?? 2048
            if j.mirrorSignFlip {
                // 12-bit MAX_POSITION reflect (Rust reflect_12bit 와 동일).
                out[j] = (4095 - raw).clamped(to: j.rawLimits)
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
