import Foundation
import ForgeCore

/// v1.1 — 카테고리별 모션을 합성할 때 재사용하는 pose primitive + step helper.
///
/// 모든 pose 는 `RobotPose.walkReady` 베이스에 도(°) 단위 delta. walkReady 자체가
/// ROBOTIS `motion_4096.bin` page 9 raw 라 사용자 로봇의 캘리브레이션 잔차도 자동
/// 보존. JointLimits 안에서 안전.
///
/// **안전 가드**: 모든 primitive 는 다음 회귀에 통과해야 함:
/// - `RobotPose.walkReady` 에서 시작·종료 가능 (steps 첫·끝에 walkReady 자체 step 권장)
/// - 각 관절 delta 가 -45° ~ +45° 안 (JointLimits 보수 한도)
public enum MotionPrimitives {

    // MARK: - delta helper

    /// walkReady 에서 도(°) delta 적용한 새 pose. `MotionPage` 외 자유 사용.
    public static func deltaFromWalkReady(_ deltas: [JointID: Double]) -> RobotPose {
        var positions = RobotPose.walkReady.positions
        for (joint, delta) in deltas {
            let base = RobotPose.walkReady.degrees(joint)
            positions[joint] = Kinematics.raw(fromDegrees: base + delta)
        }
        return RobotPose(positions: positions)
    }

    /// 좌·우 페어 동시 적용 (R/L 같은 부호) — `[.rShoulderPitch: +30, .lShoulderPitch: -30]`
    /// 처럼 mirror 자동 처리.
    public static func deltaMirrored(_ pairs: [(right: JointID, left: JointID, deltaR: Double, deltaL: Double)]) -> RobotPose {
        var dict: [JointID: Double] = [:]
        for p in pairs {
            dict[p.right] = p.deltaR
            dict[p.left] = p.deltaL
        }
        return deltaFromWalkReady(dict)
    }

    // MARK: - 자주 쓰이는 pose primitives (약 30개)

    // ── 1. 팔 자세 ──
    //
    // **부호 규약** (`docs/architecture/joint-conventions.md` 2026-05-13 hotfix):
    //   - 팔 앞·위로 (sho pitch):  R **+** / L **−**  ← 다리와 반대! URDF y-axis 반전
    //   - 팔꿈치 굽힘 (elbow flex): R **+** / L **−**
    //   - 어깨 외전 (sho roll):    R **−** / L **+**  (T 자세)
    //   - 어깨 내전 (sho roll):    R **+** / L **−**  (X 가슴)
    //
    // walkReady 절대값: rSho=-48°, lSho=+41°, rEl=+29°, lEl=-29° (이미 약간 뒤로).
    // 만세 등을 만들려면 R 양수 delta + L 음수 delta 더해야 의도대로 동작.
    public static let armsUp        = deltaFromWalkReady([.rShoulderPitch: 90, .lShoulderPitch: -90])   // 만세
    public static let armsForward   = deltaFromWalkReady([.rShoulderPitch: 45, .lShoulderPitch: -45])   // 정면 앞으로 뻗기
    public static let armsT         = deltaFromWalkReady([.rShoulderRoll: -70, .lShoulderRoll: 70])     // T-자세 (외전)
    public static let armsCross     = deltaFromWalkReady([.rShoulderRoll: 30, .lShoulderRoll: -30])     // X 가슴 (내전)
    public static let armsAside     = deltaFromWalkReady([.rShoulderPitch: -20, .lShoulderPitch: 20])   // 옆 살짝 (살짝 뒤로)
    public static let armsHipHip    = deltaFromWalkReady([
        .rShoulderPitch: 10, .lShoulderPitch: -10,
        .rElbow: 90, .lElbow: -90,
    ])  // 허리에 손 — 어깨 살짝 앞·위 + 팔꿈치 굽힘
    public static let armsRightWave = deltaFromWalkReady([.rShoulderPitch: 80, .rElbow: -30])     // 오른손만 인사 (앞·위 + 팔꿈치 살짝 펴기)
    public static let armsLeftWave  = deltaFromWalkReady([.lShoulderPitch: -80, .lElbow: 30])      // 왼손만
    public static let armsRightSalute = deltaFromWalkReady([.rShoulderPitch: 75, .rShoulderRoll: -25, .rElbow: 90])  // 경례
    public static let armsBothBackward = deltaFromWalkReady([.rShoulderPitch: -40, .lShoulderPitch: 40])  // 뒤로 뻗기 (R−/L+)

    // ── 2. 팔꿈치·손 ──
    public static let elbowsBent90   = deltaFromWalkReady([.rElbow: 50, .lElbow: -50])    // L 자 굽힘
    public static let elbowsFold     = deltaFromWalkReady([.rElbow: 120, .lElbow: -120])  // 완전 접음
    public static let armsPraying    = deltaFromWalkReady([
        .rShoulderPitch: 45, .lShoulderPitch: -45,
        .rShoulderRoll: 30, .lShoulderRoll: -30,    // 내전 (양 손바닥 모음)
        .rElbow: 80, .lElbow: -80,                   // 굽힘
    ])  // 합장

    // ── 3. 머리 (시선) ──
    //   headPan: + 우측 / − 좌측
    //   headTilt: + chin up (위 봄) / − chin down (아래 봄)
    public static let headLookLeft   = deltaFromWalkReady([.headPan: -45])
    public static let headLookRight  = deltaFromWalkReady([.headPan: 45])
    public static let headLookCenter = RobotPose.walkReady
    public static let headLookUp     = deltaFromWalkReady([.headTilt: 25])    // chin up
    public static let headLookDown   = deltaFromWalkReady([.headTilt: -25])   // chin down
    public static let headBowSlight  = deltaFromWalkReady([.headTilt: -15])   // 살짝 숙임

    // ── 4. 다리 (자세) — 부호는 다리 규약 (hip pitch R−/L+ 앞, knee R+/L− 굽힘, ankle R+/L− 발끝위)
    public static let kneesBent5  = deltaFromWalkReady([.rKnee: 5, .lKnee: -5])
    public static let kneesBent15 = deltaFromWalkReady([.rKnee: 15, .lKnee: -15])
    public static let kneesBent25 = deltaFromWalkReady([.rKnee: 25, .lKnee: -25])
    public static let hipLeanFwd  = deltaFromWalkReady([.rHipPitch: -8, .lHipPitch: 8, .rAnklePitch: 8, .lAnklePitch: -8])
    public static let hipLeanBack = deltaFromWalkReady([.rHipPitch: 8, .lHipPitch: -8, .rAnklePitch: -8, .lAnklePitch: 8])
    public static let hipSwayR    = deltaFromWalkReady([.rHipRoll: -10, .lHipRoll: -10, .rAnkleRoll: 10, .lAnkleRoll: 10])
    public static let hipSwayL    = deltaFromWalkReady([.rHipRoll: 10, .lHipRoll: 10, .rAnkleRoll: -10, .lAnkleRoll: -10])

    // ── 5. 종합 자세 ── 절 = hip 앞 굽힘 + head chin down
    public static let bowSlight   = deltaFromWalkReady([.rHipPitch: -10, .lHipPitch: 10, .headTilt: -12])
    public static let bowDeep     = deltaFromWalkReady([.rHipPitch: -25, .lHipPitch: 25, .headTilt: -20])
    public static let squatLow    = deltaFromWalkReady([.rHipPitch: -20, .lHipPitch: 20, .rKnee: 30, .lKnee: -30, .rAnklePitch: 10, .lAnklePitch: -10])

    // MARK: - Step helper

    /// 한 pose 를 일정 시간 hold (한 step).
    public static func holdAt(_ pose: RobotPose, ms: Int, pause: Int = 0) -> MotionStep {
        .from(pose: pose, playMs: ms, pauseMs: pause)
    }

    /// 두 pose 사이를 N 개 step 으로 linear 보간.
    /// 각 step playMs = `totalMs / steps`. 시작/끝 모두 포함하지 않고 중간 만 생성 →
    /// 호출자가 start/end 를 별도 holdAt 으로 감싸야 함.
    public static func sweep(
        from start: RobotPose,
        to end: RobotPose,
        steps: Int,
        totalMs: Int
    ) -> [MotionStep] {
        guard steps > 0 else { return [] }
        let stepMs = max(1, totalMs / steps)
        return (1...steps).map { i in
            let t = Double(i) / Double(steps)
            return .from(pose: blend(start, end, t: t), playMs: stepMs)
        }
    }

    /// 두 pose linear blend (t∈[0,1]).
    public static func blend(_ a: RobotPose, _ b: RobotPose, t: Double) -> RobotPose {
        var positions = RobotPose.walkReady.positions
        for j in JointID.allCases {
            let av = Double(a.raw(j))
            let bv = Double(b.raw(j))
            let mixed = av + (bv - av) * t
            positions[j] = UInt16(clamping: Int(mixed.rounded()))
        }
        return RobotPose(positions: positions)
    }

    /// 진동 — center → side1 → center → side2 → center 를 cycles 회 반복.
    /// 예: head shake = oscillate(center=walkReady, side1=headLookLeft, side2=headLookRight, cycles=2, ms=400)
    public static func oscillate(
        center: RobotPose,
        side1: RobotPose,
        side2: RobotPose,
        cycles: Int,
        msPerHalf: Int
    ) -> [MotionStep] {
        var steps: [MotionStep] = []
        for _ in 0..<cycles {
            steps.append(.from(pose: side1, playMs: msPerHalf))
            steps.append(.from(pose: center, playMs: msPerHalf))
            steps.append(.from(pose: side2, playMs: msPerHalf))
            steps.append(.from(pose: center, playMs: msPerHalf))
        }
        return steps
    }

    /// 모든 모션을 walkReady 로 시작·종료하도록 감싸기.
    /// 안전 가드: `MotionStudioView.starterPages` 와 동일 패턴.
    public static func wrapWithWalkReady(_ inner: [MotionStep], openMs: Int = 300, closeMs: Int = 400) -> [MotionStep] {
        var out: [MotionStep] = [.from(pose: .walkReady, playMs: openMs)]
        out.append(contentsOf: inner)
        out.append(.from(pose: .walkReady, playMs: closeMs))
        return out
    }
}
