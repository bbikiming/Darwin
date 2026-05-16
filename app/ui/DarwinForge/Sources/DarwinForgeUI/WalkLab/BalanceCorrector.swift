import Foundation
import ForgeCore

/// v1.1 Stage 4 — IMU 기반 balance feedback corrector.
///
/// ROBOTIS-OP2 `op2_walking_module/src/op2_walking_module.cpp::sensoryFeedback`
/// (line 886-908) 의 balance gain 패턴 포팅. 4 관절 그룹에 IMU error 비례 delta.
///
/// # 알고리즘 (원본 ROBOTIS Walking.cpp 인용)
///
/// ```cpp
/// double internal_gain = -0.3;
/// balance[hip_roll]   = +dir * -0.3 * rl_err * hip_roll_gain;       // R, L 동일 부호
/// balance[knee]       = -dir * -0.3 * fb_err * knee_gain;           // = +0.3 * fb * gain
/// balance[ank_pitch]  = -dir * -0.3 * fb_err * ankle_pitch_gain;
/// balance[ank_roll]   = +dir * -0.3 * rl_err * ankle_roll_gain;
/// ```
///
/// **단순화**: `getJointDirection` 추상화 대신 R/L 동일 부호 (lateral CoP shift)
/// 직접 적용. URDF axis 부호는 본 함수의 부호 매핑에 포함.
///
/// # 부호 (`docs/architecture/joint-conventions.md` 정합)
///
/// - **roll_err > 0** (오른쪽 기울어짐) → `hip_roll` / `ank_roll` 음수 보정
///   = 양 다리 hip_roll 모두 왼쪽으로 (오른쪽 기울 → 왼쪽으로 lean 회복)
/// - **pitch_err > 0** (앞으로 기울어짐) → `knee` 양수 보정 + `ank_pitch` 양수 보정
///   = 양 다리 무릎 굽힘 + 발끝 위 (앞 기울 → 뒤로 lean 회복)
///
/// **R/L 동일 부호** — mirror gait 의 페어 부호 규약과 다름. lateral CoP shift 라
/// 양 다리가 같은 방향으로 보정해야.
///
/// # 안전 가드
///
/// - `enabled = false` 시 identity (pose 그대로 반환)
/// - 보정 delta 절댓값 ≤ `maxCorrectionDeg` (default ±15°) — 그 이상이면 clamp
/// - gain ramp: 활성 후 0~1초 동안 0%→100% 점진 적용 (oscillation 방지)
/// - IMU stale 시 호출자 책임 (corrector 는 입력 받는 값 그대로 사용)
public struct BalanceCorrector {

    /// 보정 강도 — 0..1. 기본 1.0 (full gain).
    public let intensity: Double
    /// 보정 delta 최대 절댓값 (°). 초과 시 clamp.
    public let maxCorrectionDeg: Double
    /// `WalkParams` 의 gain 값 4개.
    public let hipRollGain: Double
    public let kneeGain: Double
    public let anklePitchGain: Double
    public let ankleRollGain: Double
    /// ROBOTIS `internal_gain = -0.3` (Walking.cpp line 892).
    public let internalGain: Double

    /// `WalkParams.default()` 값과 정합. v1.0 `walk/params.rs` 기준.
    public static let robotisDefault = BalanceCorrector(
        intensity: 1.0,
        maxCorrectionDeg: 15.0,
        hipRollGain: 0.5,        // ROBOTIS Walking.cpp line 110
        kneeGain: 0.3,           // line 111
        anklePitchGain: 0.9,     // line 113
        ankleRollGain: 1.0,      // line 112
        internalGain: -0.3       // line 892
    )

    public init(intensity: Double = 1.0,
                maxCorrectionDeg: Double = 15.0,
                hipRollGain: Double,
                kneeGain: Double,
                anklePitchGain: Double,
                ankleRollGain: Double,
                internalGain: Double = -0.3) {
        self.intensity = max(0, min(1, intensity))
        self.maxCorrectionDeg = max(0, maxCorrectionDeg)
        self.hipRollGain = hipRollGain
        self.kneeGain = kneeGain
        self.anklePitchGain = anklePitchGain
        self.ankleRollGain = ankleRollGain
        self.internalGain = internalGain
    }

    /// 4 관절 그룹의 보정 delta (deg) 산출.
    ///
    /// 입력 단위 deg (°). 결과 단위 deg. 호출자가 `Kinematics.raw(fromDegrees:)`
    /// 로 raw 변환 후 pose 에 적용.
    ///
    /// - `rollErrDeg` — `imuRollDeg` (양수 = 오른쪽 기울)
    /// - `pitchErrDeg` — `imuPitchDeg` (양수 = 앞으로 기울)
    ///
    /// # 부호 매핑 (URDF dir × ROBOTIS Walking.cpp 식 유도)
    ///
    /// ROBOTIS 원본: `balance = ±dir(joint) × (-0.3) × (-measuredErr) × gain`.
    /// `getJointDirection` 의 URDF axis sum 값을 본 함수의 R/L 부호로 직접 표현:
    ///
    /// | 관절 | URDF axis | dir | 본 함수 식 |
    /// |---|---|---|---|
    /// | r_hip_roll  | (-1, 0, 0) | -1 | `-0.15 × imuRollDeg` |
    /// | l_hip_roll  | (-1, 0, 0) | -1 | `-0.15 × imuRollDeg` (R 동일) |
    /// | r_knee      | (0, +1, 0) | +1 | `-0.09 × imuPitchDeg` |
    /// | l_knee      | (0, -1, 0) | -1 | `+0.09 × imuPitchDeg` (R 반대) |
    /// | r_ank_pitch | (0, -1, 0) | -1 | `+0.27 × imuPitchDeg` |
    /// | l_ank_pitch | (0, +1, 0) | +1 | `-0.27 × imuPitchDeg` (R 반대) |
    /// | r_ank_roll  | (+1, 0, 0) | +1 | `+0.30 × imuRollDeg` |
    /// | l_ank_roll  | (+1, 0, 0) | +1 | `+0.30 × imuRollDeg` (R 동일) |
    ///
    /// **lateral shift (hip_roll, ankle_roll)** → R/L 같은 부호.
    /// **sagittal recovery (knee, ankle_pitch)** → R/L mirror 부호.
    ///
    /// 2026-05-16 정정 (v1.1 Stage 4 audit): 이전 R/L 모두 동일 부호 가정은
    /// URDF dir 무시한 오류 → knee/ankle_pitch 의 L 부호 + ankle_roll 의 양쪽
    /// 부호 4 곳 정정.
    public func corrections(rollErrDeg: Double, pitchErrDeg: Double) -> Corrections {
        // ROBOTIS 원본 `balance = dir × internal_gain × (goal - measured) × gain`.
        // `goal = 0` 이라 `(goal - measured) = -measured` 부호 변환.
        // `internal_gain = -0.3`. 따라서 효과 multiplier:
        //   hip_roll  (lateral): dir × -0.3 × -1 × gain = dir × 0.3 × gain (× imuRoll)
        //                        → 그러나 ROBOTIS 식: + dir × -0.3 × rl_err × gain
        //                          where rl_err = -imuRoll
        //                        → -dir × 0.3 × imuRoll × gain
        //   ankle_roll(lateral): -dir × 0.3 × imuRoll × gain  (동일 식, dir 다름)
        //   knee     (sagittal): +dir × 0.3 × imuPitch × gain  (Walking.cpp 의 -dir × ...)
        //   ank_pitch(sagittal): +dir × 0.3 × imuPitch × gain
        //
        // dir 대입한 결과를 명시적으로 코딩:

        let m = 0.3 * intensity  // common multiplier (= |internal_gain| × intensity)

        // hip_roll: dir = -1 → multiplier = -(-1) × 0.3 × gain = 0.3 × gain
        //   → -dir × 0.3 × imuRoll × gain = -(-1) × ... → wait, let me restart cleanly.

        // ROBOTIS 식 (rl = -imuRoll, fb = -imuPitch 대입):
        //   r_hip_roll  = +dir(r_hip_roll)  × (-0.3) × rl × hip_roll_gain
        //               = +(-1) × (-0.3) × (-imuRoll) × 0.5
        //               = -0.15 × imuRoll
        //   l_hip_roll  = 동일 (dir 같음) = -0.15 × imuRoll
        //   r_knee      = -dir(r_knee) × (-0.3) × fb × knee_gain
        //               = -(+1) × (-0.3) × (-imuPitch) × 0.3
        //               = -0.09 × imuPitch
        //   l_knee      = -dir(l_knee) × (-0.3) × fb × knee_gain
        //               = -(-1) × (-0.3) × (-imuPitch) × 0.3
        //               = +0.09 × imuPitch
        //   r_ank_pitch = -dir(r_ank_pitch) × (-0.3) × fb × ankle_pitch_gain
        //               = -(-1) × (-0.3) × (-imuPitch) × 0.9
        //               = +0.27 × imuPitch
        //   l_ank_pitch = -dir(l_ank_pitch) × (-0.3) × fb × ankle_pitch_gain
        //               = -(+1) × (-0.3) × (-imuPitch) × 0.9
        //               = -0.27 × imuPitch
        //   r_ank_roll  = +dir(r_ank_roll) × (-0.3) × rl × ankle_roll_gain
        //               = +(+1) × (-0.3) × (-imuRoll) × 1.0
        //               = +0.30 × imuRoll
        //   l_ank_roll  = 동일 (dir 같음) = +0.30 × imuRoll

        let hipRollBoth     = -m * rollErrDeg * hipRollGain        // = -0.15 × imuRoll
        let kneeR           = -m * pitchErrDeg * kneeGain          // = -0.09 × imuPitch
        let kneeL           = +m * pitchErrDeg * kneeGain          // = +0.09 × imuPitch
        let anklePitchR     = +m * pitchErrDeg * anklePitchGain    // = +0.27 × imuPitch
        let anklePitchL     = -m * pitchErrDeg * anklePitchGain    // = -0.27 × imuPitch
        let ankleRollBoth   = +m * rollErrDeg * ankleRollGain      // = +0.30 × imuRoll

        return Corrections(
            rHipRoll:    clamp(hipRollBoth),
            lHipRoll:    clamp(hipRollBoth),
            rKnee:       clamp(kneeR),
            lKnee:       clamp(kneeL),
            rAnklePitch: clamp(anklePitchR),
            lAnklePitch: clamp(anklePitchL),
            rAnkleRoll:  clamp(ankleRollBoth),
            lAnkleRoll:  clamp(ankleRollBoth)
        )
    }

    private func clamp(_ deg: Double) -> Double {
        if deg.isNaN || !deg.isFinite { return 0 }
        return max(-maxCorrectionDeg, min(maxCorrectionDeg, deg))
    }

    /// Target pose 에 보정 delta 더한 새 pose. **mutate X — 새 RobotPose 반환.**
    ///
    /// 활성화 (`enabled=true`) + IMU error 가 있을 때 만 보정. 그 외 identity.
    /// gain ramp: `secondsSinceEnable < 1.0` 면 비율 적용.
    public func apply(to pose: RobotPose,
                      rollErrDeg: Double,
                      pitchErrDeg: Double,
                      enabled: Bool,
                      secondsSinceEnable: Double = 1.0) -> RobotPose {
        guard enabled else { return pose }
        // gain ramp 0..1
        let ramp = max(0, min(1, secondsSinceEnable))
        // intensity 와 곱.
        let effective = BalanceCorrector(
            intensity: intensity * ramp,
            maxCorrectionDeg: maxCorrectionDeg,
            hipRollGain: hipRollGain, kneeGain: kneeGain,
            anklePitchGain: anklePitchGain, ankleRollGain: ankleRollGain,
            internalGain: internalGain
        )
        let c = effective.corrections(rollErrDeg: rollErrDeg, pitchErrDeg: pitchErrDeg)

        // 각 관절에 deg delta 더해서 raw 재계산.
        var positions = pose.positions
        positions[.rHipRoll]    = applyDelta(pose.degrees(.rHipRoll),    c.rHipRoll)
        positions[.lHipRoll]    = applyDelta(pose.degrees(.lHipRoll),    c.lHipRoll)
        positions[.rKnee]       = applyDelta(pose.degrees(.rKnee),       c.rKnee)
        positions[.lKnee]       = applyDelta(pose.degrees(.lKnee),       c.lKnee)
        positions[.rAnklePitch] = applyDelta(pose.degrees(.rAnklePitch), c.rAnklePitch)
        positions[.lAnklePitch] = applyDelta(pose.degrees(.lAnklePitch), c.lAnklePitch)
        positions[.rAnkleRoll]  = applyDelta(pose.degrees(.rAnkleRoll),  c.rAnkleRoll)
        positions[.lAnkleRoll]  = applyDelta(pose.degrees(.lAnkleRoll),  c.lAnkleRoll)
        return RobotPose(positions: positions)
    }

    private func applyDelta(_ baseDeg: Double, _ deltaDeg: Double) -> UInt16 {
        Kinematics.raw(fromDegrees: baseDeg + deltaDeg)
    }

    /// 8 다리 관절의 deg 보정 — 회귀·UI 표시용.
    public struct Corrections: Equatable, Sendable {
        public let rHipRoll:    Double
        public let lHipRoll:    Double
        public let rKnee:       Double
        public let lKnee:       Double
        public let rAnklePitch: Double
        public let lAnklePitch: Double
        public let rAnkleRoll:  Double
        public let lAnkleRoll:  Double

        /// 모든 delta 의 최대 절댓값 — UI 표시.
        public var maxAbs: Double {
            [rHipRoll, lHipRoll, rKnee, lKnee, rAnklePitch, lAnklePitch, rAnkleRoll, lAnkleRoll]
                .map { abs($0) }
                .max() ?? 0
        }
    }
}
