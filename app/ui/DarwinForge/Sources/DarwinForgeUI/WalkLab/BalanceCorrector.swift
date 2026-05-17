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
/// # 부호 (`docs/architecture/joint-conventions.md` 정합 + ROBOTIS Walking.cpp dir[])
///
/// **v1.11.2 (2026-05-18 사용자 review P3) 정정**: 종전 "knee 양수 보정" 단정 표현은
/// R/L mirror 패턴을 가려서 오해 가능. 실제 부호는 ROBOTIS Walking.cpp 의 `dir[]`
/// 배열 (line 366) 그대로:
///
/// **Lateral (hip_roll, ank_roll)** — `imuRoll > 0` (오른쪽 기울) 시:
///   - R/L 양쪽 모두 **음수** 보정 (동기 lateral CoP shift, 왼쪽으로 lean 회복)
///
/// **Sagittal (knee, ank_pitch)** — `imuPitch > 0` (앞 기울) 시 **R/L mirror**:
///   - `r_knee` = **음수**, `l_knee` = **양수** (dir[3]=+1, dir[9]=-1)
///   - `r_ank_pitch` = **양수**, `l_ank_pitch` = **음수** (dir[4]=-1, dir[10]=+1)
///   - 두 다리 절댓값은 동일, 부호는 반대. "굽힘 방향" 의미론은 walkReady 자세
///     기준이므로 본 주석은 ROBOTIS dir[] 의 수학적 부호만 신뢰.
///
/// 자세한 8 관절 부호 표는 `corrections(...)` 함수 docstring 참조.
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

    // MARK: - v1.10 (Hybrid B+A, 2026-05-17)
    /// Hybrid mode ON/OFF — true 시 slow EMA + phase-locked residual 결합.
    /// false 시 기존 P-control 사용 (backward compatible).
    public let enableHybrid: Bool
    /// Slow EMA time constant (초). chronic bias 의 회복 시간.
    public let slowDriftTauSec: Double
    /// Slow EMA gain — drift 보정 강도. 1.0 = 완전 보정.
    public let slowGain: Double
    /// Fast residual gain — phase-locked correction 강도.
    public let fastGain: Double
    /// 예상 sagittal sway amplitude (°). walking 의도된 pitch 흔들림.
    public let sagittalSwayAmpDeg: Double
    /// 예상 lateral sway amplitude (°). 보통 0 (ROBOTIS 가정).
    public let lateralSwayAmpDeg: Double

    /// **v1.11 (2026-05-17) — naming 정리 (사용자 prompt + 5 agent 검증)**:
    /// 종전 `robotisDefault` 가 v1.10 실험값을 "ROBOTIS" 이름 하에 박아 혼란. 분리:
    ///   - `robotisOriginal`: Walking.cpp oracle 값 그대로 (실 검증된 기준, default)
    ///   - `v110Experimental`: random search + Hybrid (실 검증 전 사용자 명시 선택 시만)

    /// ROBOTIS Walking.cpp (line 40-43) oracle 값. 실 검증된 기준.
    public static let robotisOriginal = BalanceCorrector(
        intensity: 1.0,
        maxCorrectionDeg: 15.0,
        hipRollGain: 0.5,
        kneeGain: 0.3,
        anklePitchGain: 0.9,       // ROBOTIS Walking.cpp:41
        ankleRollGain: 1.0,        // Walking.cpp:43
        internalGain: -0.3,
        enableHybrid: false,       // 실 검증 전 P-control fallback
        slowDriftTauSec: 10.0,
        slowGain: 1.0,
        fastGain: 0.27,
        sagittalSwayAmpDeg: 5.0,
        lateralSwayAmpDeg: 0.0
    )

    /// v1.10 실험 (시뮬 + 350 trial). 실 robot 검증 전 — 사용자 명시 선택 시만.
    public static let v110Experimental = BalanceCorrector(
        intensity: 1.5,
        maxCorrectionDeg: 15.0,
        hipRollGain: 0.5,
        kneeGain: 0.3,
        anklePitchGain: 1.5,       // random search 결과
        ankleRollGain: 0.5,
        internalGain: -0.3,
        enableHybrid: true,        // Hybrid B+A ON
        slowDriftTauSec: 10.0,
        slowGain: 1.0,
        fastGain: 0.27,
        sagittalSwayAmpDeg: 5.0,
        lateralSwayAmpDeg: 0.0
    )

    /// Deprecated alias — 새 코드는 명시 (`robotisOriginal` 또는 `v110Experimental`).
    public static let robotisDefault = robotisOriginal

    /// **v1.11 (2026-05-17)**: gain profile 축에 따라 base corrector 선택.
    /// `BalanceExperimentConfig.gainProfile` 와 1:1 매핑.
    public static func forGainProfile(_ profile: BalanceGainProfile) -> BalanceCorrector {
        switch profile {
        case .robotisOriginal:   return .robotisOriginal
        case .v110Experimental:  return .v110Experimental
        case .custom:            return .robotisOriginal  // expert slider 가 override
        }
    }

    public init(intensity: Double = 1.0,
                maxCorrectionDeg: Double = 15.0,
                hipRollGain: Double,
                kneeGain: Double,
                anklePitchGain: Double,
                ankleRollGain: Double,
                internalGain: Double = -0.3,
                enableHybrid: Bool = true,
                slowDriftTauSec: Double = 10.0,
                slowGain: Double = 1.0,
                fastGain: Double = 0.27,
                sagittalSwayAmpDeg: Double = 5.0,
                lateralSwayAmpDeg: Double = 0.0) {
        self.intensity = max(0, min(2, intensity))
        self.maxCorrectionDeg = max(0, maxCorrectionDeg)
        self.hipRollGain = hipRollGain
        self.kneeGain = kneeGain
        self.anklePitchGain = anklePitchGain
        self.ankleRollGain = ankleRollGain
        self.internalGain = internalGain
        self.enableHybrid = enableHybrid
        self.slowDriftTauSec = max(0.1, slowDriftTauSec)
        self.slowGain = max(0, slowGain)
        self.fastGain = max(0, fastGain)
        self.sagittalSwayAmpDeg = max(0, sagittalSwayAmpDeg)
        self.lateralSwayAmpDeg = max(0, lateralSwayAmpDeg)
    }

    /// 4 관절 그룹의 보정 delta (deg) 산출.
    ///
    /// 입력 단위 deg (°). 결과 단위 deg. 호출자가 `Kinematics.raw(fromDegrees:)`
    /// 로 raw 변환 후 pose 에 적용.
    ///
    /// - `rollErrDeg` — `imuRollDeg` (양수 = 오른쪽 기울)
    /// - `pitchErrDeg` — `imuPitchDeg` (양수 = 앞으로 기울)
    ///
    /// # 부호 매핑 (4-source 정합: doc + URDF + walkReady + 본 함수)
    ///
    /// **부호는 ROBOTIS Walking.cpp 원본 검증된 dir[] 배열 그대로 포팅** (line 366,
    /// 576-586). doc 의 "굽힘/펴짐" 의미론 해석 없이 dir[] 부호만 신뢰.
    ///
    /// | 관절 | ROBOTIS dir | 본 함수 식 (imuRoll/Pitch > 0 일 때) |
    /// |---|---|---|
    /// | r_hip_roll  | -1 | `-0.15 × imuRoll` (음수, R/L 동기 lateral CoP) |
    /// | l_hip_roll  | -1 | `-0.15 × imuRoll` (음수, R/L 동기) |
    /// | r_knee      | +1 | `-0.09 × imuPitch` (음수, sagittal R/L mirror) |
    /// | l_knee      | -1 | `+0.09 × imuPitch` (양수, mirror) |
    /// | r_ank_pitch | -1 | `+0.27 × imuPitch` (양수, mirror) |
    /// | l_ank_pitch | +1 | `-0.27 × imuPitch` (음수, mirror) |
    /// | r_ank_roll  | +1 | `-0.30 × imuRoll` (음수, R/L 동기) |
    /// | l_ank_roll  | +1 | `-0.30 × imuRoll` (음수, R/L 동기) |
    ///
    /// **lateral (hip_roll, ankle_roll)** → R/L 같은 부호 (모두 음수, 동기 동작).
    /// **sagittal (knee, ankle_pitch)** → R/L mirror (한 다리 +, 한 다리 -).
    ///
    /// 2026-05-16 정정 (Agent 3 cross-check): 이전 audit 가 ROBOTIS Walking.cpp
    /// 의 `+dir × (-0.3) × (-imuErr) × gain` 유도식만 적용해 doc 본문의 의도와
    /// 4 관절 (r_knee / l_knee / r_ank_roll / l_ank_roll) 부호 충돌 발견.
    /// 이번 정정은 **doc 의도 + walkReady mirror 패턴** 일치 우선.
    ///
    /// **v1.11 (2026-05-17 사용자 prompt)**: `signConvention` 축 추가. `.alternateDiagnostic`
    /// 시 sagittal (knee R/L + anklePitch R/L) 의 부호만 반전. lateral (hipRoll/ankleRoll)
    /// 은 안전상 그대로 — diagnostic 실험으로 fall 가속을 측정하되 hipRoll oscillation 까지
    /// 부수효과로 끌고가지 않게.
    public func corrections(
        rollErrDeg: Double,
        pitchErrDeg: Double,
        signConvention: BalanceSignConvention = .robotisWalkingCpp
    ) -> Corrections {
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
        //   r_ank_roll  = ROBOTIS `-=` 식: balance -= dir × rl × gain
        //               = -dir(+1) × (-imuRoll) × gain × m  (m = 0.3 × intensity)
        //               = -0.30 × imuRoll  (의도된 lateral CoP 회복: 오른쪽 기울→왼쪽으로)
        //   l_ank_roll  = 동일 (dir[11] 같은 + 부호) = -0.30 × imuRoll
        //
        //   **v1.11.2 (Codex 2026-05-18 #4 정정)**: 종전 유도식이 `+0.30` 으로 잘못
        //   적혀있었음. 실제 코드 line 242 (`ankleRollBoth = -m * rollErrDeg × gain`)
        //   + testCorrectionPolarityRollPositive 가 음수 결과 검증. 부호 일관 정리.

        // **2026-05-16 Phase B 정정 (Agent 3 cross-check 발견)**:
        // doc + walkReady + URDF 4-source 정합 부호. 이전 4 관절 (kneeR, kneeL,
        // ankleRoll 양쪽) 부호 반대로 작성 → fall 가속 위험. 다음으로 정정:
        // ROBOTIS Walking.cpp line 576-586 (dir 배열 line 366) 직접 포팅.
        // dir[1]=−1, dir[7]=−1 → hip_roll: += dir×rl×gain → (−1)×rl×gain → 음수(imuRoll>0)
        // dir[3]=+1            → r_knee:   -= dir×fb×gain → −(+1)×fb×gain → 음수(imuPitch>0)
        // dir[9]=−1            → l_knee:   -= dir×fb×gain → −(−1)×fb×gain → 양수(imuPitch>0)
        // dir[4]=−1, dir[10]=+1→ ank_pitch:-= dir×fb×gain → (+dir)×fb→ R=양수, L=음수
        // dir[5]=+1, dir[11]=+1→ ank_roll: -= dir×rl×gain → −(+1)×rl×gain → 음수(imuRoll>0)
        let hipRollBoth     = -m * rollErrDeg * hipRollGain        // = -0.15 × imuRoll (lateral 회복)
        var kneeR           = -m * pitchErrDeg * kneeGain          // ROBOTIS: -= dir[3]×fb = -(+1)×fb → 음수(imuPitch>0)
        var kneeL           = +m * pitchErrDeg * kneeGain          // ROBOTIS: -= dir[9]×fb = -(-1)×fb → 양수(imuPitch>0)
        var anklePitchR     = +m * pitchErrDeg * anklePitchGain    // = +0.27 × imuPitch (R dorsiflex)
        var anklePitchL     = -m * pitchErrDeg * anklePitchGain    // = -0.27 × imuPitch (L dorsiflex mirror)
        let ankleRollBoth   = -m * rollErrDeg * ankleRollGain      // ROBOTIS: -= dir[5]×rl = -(+1)×rl → 음수(imuRoll>0)

        // v1.11: signConvention = .alternateDiagnostic → sagittal 4 관절만 부호 반전.
        // 진단 실험 — 실 robot 적용 시 fall 가속 위험. observe-only 강제 권장.
        if signConvention == .alternateDiagnostic {
            kneeR = -kneeR
            kneeL = -kneeL
            anklePitchR = -anklePitchR
            anklePitchL = -anklePitchL
        }

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
                      secondsSinceEnable: Double = 1.0,
                      signConvention: BalanceSignConvention = .robotisWalkingCpp) -> RobotPose {
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
        let c = effective.corrections(
            rollErrDeg: rollErrDeg,
            pitchErrDeg: pitchErrDeg,
            signConvention: signConvention
        )

        // **Phase F 정정 (Agent 2 B-5)**: `RobotPose.with(_:)` 가 자동으로
        // `joint.rawLimits` 안전 clamp — 이전 `positions[.X] = applyDelta` 직접 write
        // 는 12-bit 한도 (0..4095) 만 clamp + joint 별 안전 한도 우회.
        return pose.with([
            .rHipRoll:    applyDelta(pose.degrees(.rHipRoll),    c.rHipRoll),
            .lHipRoll:    applyDelta(pose.degrees(.lHipRoll),    c.lHipRoll),
            .rKnee:       applyDelta(pose.degrees(.rKnee),       c.rKnee),
            .lKnee:       applyDelta(pose.degrees(.lKnee),       c.lKnee),
            .rAnklePitch: applyDelta(pose.degrees(.rAnklePitch), c.rAnklePitch),
            .lAnklePitch: applyDelta(pose.degrees(.lAnklePitch), c.lAnklePitch),
            .rAnkleRoll:  applyDelta(pose.degrees(.rAnkleRoll),  c.rAnkleRoll),
            .lAnkleRoll:  applyDelta(pose.degrees(.lAnkleRoll),  c.lAnkleRoll),
        ])
    }

    private func applyDelta(_ baseDeg: Double, _ deltaDeg: Double) -> Int {
        // RobotPose.positions 는 `[JointID: Int]` — Kinematics.raw 도 Int 반환.
        // 2026-05-16 정정: 이전 `UInt16` 반환 타입은 `[JointID: Int]` 와 타입 mismatch.
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

    // MARK: - v1.10 Hybrid B+A (slow EMA + phase-locked residual)

    /// Hybrid B+A 결과 — caller 가 corrections 를 pose 에 apply.
    public struct HybridResult: Equatable, Sendable {
        /// 최종 effective roll error — corrector 가 사용한 입력.
        public let effectiveRollErr: Double
        /// 최종 effective pitch error.
        public let effectivePitchErr: Double
        /// Slow drift component (EMA 기반 chronic bias 보정).
        public let slowRollDelta: Double
        public let slowPitchDelta: Double
        /// Fast residual component (walking sway 제외 후 빠른 외란).
        public let fastRollDelta: Double
        public let fastPitchDelta: Double
        /// 8 관절 corrections (combined slow+fast).
        public let corrections: Corrections
    }

    /// **Hybrid B+A 보정** (v1.10, 2026-05-17 시뮬레이션 기반).
    ///
    /// 알고리즘:
    /// ```
    /// B (Slow drift):    pitch_ema = α × imu_pitch + (1-α) × pitch_ema_prev
    ///                    slow_delta = -slowGain × pitch_ema
    /// A (Phase-locked):  expected = sway_amp × sin(2π × t/period)
    ///                    residual = (imu - ema) - expected
    ///                    fast_delta = -fastGain × residual
    /// Combined:          effective_err = slow_delta + fast_delta
    ///                    corrections = BalanceCorrector.corrections(effective_err)
    /// ```
    ///
    /// 효과 (시뮬): mean signed pitch −8.98° → −0.20° (45배 개선).
    ///
    /// - Parameters:
    ///   - imuRollDeg: 현재 IMU roll (deg, raw)
    ///   - imuPitchDeg: 현재 IMU pitch (deg, raw)
    ///   - elapsedMs: walking cycle 시작부터의 시간 (0..periodMs). 0 이면 phase-locked 무효.
    ///   - periodMs: walking cycle period (예: 600). 0 또는 음수면 phase-locked 무효.
    ///   - state: caller 가 유지하는 EMA state (`inout` mutate)
    ///   - now: 현재 시각 (state stale check 용)
    /// - Returns: HybridResult — slow/fast delta + corrections.
    public func hybridCorrections(
        imuRollDeg: Double,
        imuPitchDeg: Double,
        elapsedMs: Double = 0,
        periodMs: Double = 0,
        state: inout HybridBalanceState,
        now: Date = Date(),
        signConvention: BalanceSignConvention = .robotisWalkingCpp
    ) -> HybridResult {
        // Stale check — 5초 이상 update 없으면 state reset.
        if let last = state.lastUpdateAt, now.timeIntervalSince(last) > 5.0 {
            state.pitchEma = imuPitchDeg
            state.rollEma = imuRollDeg
        }

        // Hybrid disabled → fast 만 (기존 P-control 등가).
        guard enableHybrid else {
            let corrs = corrections(
                rollErrDeg: imuRollDeg,
                pitchErrDeg: imuPitchDeg,
                signConvention: signConvention
            )
            state.lastUpdateAt = now
            return HybridResult(
                effectiveRollErr: imuRollDeg,
                effectivePitchErr: imuPitchDeg,
                slowRollDelta: 0, slowPitchDelta: 0,
                fastRollDelta: imuRollDeg, fastPitchDelta: imuPitchDeg,
                corrections: corrs
            )
        }

        // B (slow EMA) — alpha = 1 - exp(-dt / tau). 5Hz 가정 dt = 0.2s.
        // alpha ≈ 0.02 for tau 10s.
        let dt = 0.2
        let alpha = 1.0 - exp(-dt / slowDriftTauSec)
        state.pitchEma = alpha * imuPitchDeg + (1 - alpha) * state.pitchEma
        state.rollEma = alpha * imuRollDeg + (1 - alpha) * state.rollEma

        // Slow drift compensation: -slowGain × ema (drift 반대 방향).
        let slowPitchDelta = -slowGain * state.pitchEma
        let slowRollDelta = -slowGain * state.rollEma

        // A (phase-locked) — walking 의 의도된 sway 제외.
        let expectedPitch: Double
        let expectedRoll: Double
        if periodMs > 0 && sagittalSwayAmpDeg > 0 {
            let phase = (2 * .pi) * elapsedMs / periodMs
            expectedPitch = sagittalSwayAmpDeg * sin(phase)
        } else {
            expectedPitch = 0
        }
        if periodMs > 0 && lateralSwayAmpDeg > 0 {
            let phase = (2 * .pi) * elapsedMs / periodMs
            expectedRoll = lateralSwayAmpDeg * sin(phase)
        } else {
            expectedRoll = 0  // ROBOTIS 가정: lateral 평균 0
        }

        let residualPitch = (imuPitchDeg - state.pitchEma) - expectedPitch
        let residualRoll = (imuRollDeg - state.rollEma) - expectedRoll
        let fastPitchDelta = -fastGain * residualPitch
        let fastRollDelta = -fastGain * residualRoll

        // Combined effective error → corrections().
        let effectivePitch = slowPitchDelta + fastPitchDelta
        let effectiveRoll = slowRollDelta + fastRollDelta
        let corrs = corrections(
            rollErrDeg: effectiveRoll,
            pitchErrDeg: effectivePitch,
            signConvention: signConvention
        )

        state.lastUpdateAt = now

        return HybridResult(
            effectiveRollErr: effectiveRoll,
            effectivePitchErr: effectivePitch,
            slowRollDelta: slowRollDelta,
            slowPitchDelta: slowPitchDelta,
            fastRollDelta: fastRollDelta,
            fastPitchDelta: fastPitchDelta,
            corrections: corrs
        )
    }
}

/// **v1.10 Hybrid B+A 의 caller-side state**.
/// `BalanceCorrector.hybridCorrections(..., state: &state)` 호출 시 inout 으로 갱신.
public struct HybridBalanceState: Equatable, Sendable {
    public var pitchEma: Double
    public var rollEma: Double
    public var lastUpdateAt: Date?

    public init(pitchEma: Double = 0,
                rollEma: Double = 0,
                lastUpdateAt: Date? = nil) {
        self.pitchEma = pitchEma
        self.rollEma = rollEma
        self.lastUpdateAt = lastUpdateAt
    }
}
