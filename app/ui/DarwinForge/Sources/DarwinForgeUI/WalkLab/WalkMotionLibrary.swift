import ForgeCore
import Foundation

/// Walk Lab 프리셋용 보행 step 시퀀스 합성 — **ROBOTIS Walking.cpp inspired
/// sparse keyframe approximation** (Codex audit P1-7, 2026-05-14).
///
/// ## ⚠️ 공식 Walking module 이 아니다
///
/// ROBOTIS `Framework/src/motion/modules/Walking.cpp` 의 실 walking 은 **8 ms 루프
/// 안에서 phase update + IK + gyro balance + P/I/D gain** 을 한다. 이 모듈은 그것의
/// **6 sample phase keyframe approximation** — `[0.03, 0.18, 0.42, 0.52, 0.68, 0.92]`
/// 위상으로만 sparse 하게 sample 한다.
///
/// 공식 vs 이 모듈:
///
/// | 항목 | 공식 Walking.cpp | 이 모듈 |
/// |---|---|---|
/// | sample rate | 8 ms (125 Hz) | 6 phase / period (~10 Hz 등가) |
/// | IMU balance closed-loop | ✓ (gyro_x/y P+I+D) | ✗ (없음) |
/// | IK 정밀도 | 분석적 inverse kinematics | 단순화된 X/Y/Z swap |
/// | constants | `X_OFFSET=-10`, `HIP_PITCH_OFFSET=13`, `ARM_SWING_GAIN=1.5` | 동일 (소스에서 옮김) |
///
/// **그래서 어디 쓰면 좋은가**: 슬라이더-driven preview / Walk Lab UI 의 step 시퀀스.
/// 실시간 안정 보행이 필요하면 ROBOTIS demo SOCCER 모드 → `Walking::GetInstance()`
/// 위임 (Pilot v1.5 의 ball-tracker 흐름 그대로).
public enum WalkMotionLibrary {

    /// Walk Lab 고급 슬라이더가 실제 보행 page에 주입되는 값.
    public struct AdvancedTuning: Equatable, Sendable {
        public var strideMm: Double
        public var sideMm: Double
        public var turnDeg: Double
        public var periodMs: Double
        public var footHeightMm: Double
        public var balanceGain: Double
        /// **v1.11.4 (2026-05-18)** — Hip pitch trim (°). ROBOTIS Walking.cpp 의
        /// `HIP_PITCH_OFFSET = 13.0` 하드코딩이 모든 보행의 mean pitch bias 의 주요
        /// 원인. 2026-05-18 실 robot 로그: hipPitchOffset=13° 이면 mean pitch -13°
        /// 앞기울 자세로 보행 시작. 사용자가 0/5/13° 비교 가능하게 노출 (default 13).
        public var hipPitchOffsetDeg: Double

        public init(
            strideMm: Double,
            sideMm: Double,
            turnDeg: Double,
            periodMs: Double,
            footHeightMm: Double,
            balanceGain: Double,
            hipPitchOffsetDeg: Double = 13.0
        ) {
            self.strideMm = strideMm
            self.sideMm = sideMm
            self.turnDeg = turnDeg
            self.periodMs = periodMs
            self.footHeightMm = footHeightMm
            self.balanceGain = balanceGain
            self.hipPitchOffsetDeg = hipPitchOffsetDeg
        }
    }

    public static func page(for preset: WalkLabPreset) -> MotionPage? {
        page(for: preset, tuning: nil)
    }

    /// **Phase G10 (2026-05-15)** — 연속 보행 계획.
    ///
    /// 한 cycle 끝마다 walkReady 자세를 거치는 끊김 (anchor flap) 을 제거하기 위해
    /// **entry / cycle / exit** 의 3 segment 로 분리:
    ///   - `entry`: walkReady → 첫 phase 자세로 진입 (longer playMs 로 안전).
    ///     보행 시작 시 **1회만** 송출.
    ///   - `cycle`: 6 phase 의 sparse keyframe — walkReady anchor 없음.
    ///     `runContinuousWalk` 가 **무한 반복** 송출. phase[5] → phase[0] (wrap-around)
    ///     은 모터 trapezoidal motion 이 자연 보간 (period=600 ms × 11% = ~66 ms 거리
    ///     를 playMs=100 ms 동안 1 step 으로 보간).
    ///   - `exit`: 마지막 phase → walkReady (사용자 정지 시 안전 복귀).
    ///
    /// **jog 제외** — jog 는 kick chain 으로 끝나는 단발 시퀀스라 `page(for:tuning:)`
    /// 그대로 사용. nil 반환.
    public struct ContinuousWalkPlan: Equatable, Sendable {
        public let entry: [MotionStep]
        public let cycle: [MotionStep]
        public let exit: [MotionStep]
    }

    public static func continuousWalkPlan(for preset: WalkLabPreset,
                                          tuning customTuning: AdvancedTuning? = nil) -> ContinuousWalkPlan? {
        // jog (kick chain) 와 idle 은 연속 보행 plan 없음.
        switch preset {
        case .idle, .jog:
            return nil
        case .march, .slowWalk, .normalWalk, .fastWalk, .turnLeft, .turnRight:
            break
        }
        let tuning = resolvedTuning(for: preset, custom: customTuning)
        return makeContinuousPlan(tuning: tuning)
    }

    /// Mobile freeform joystick path. Unlike preset tuning, this keeps a small
    /// negative stride range so joystick-down can produce controlled backward
    /// steps. Preset/default walking remains unchanged.
    public static func freeformContinuousWalkPlan(tuning customTuning: AdvancedTuning) -> ContinuousWalkPlan? {
        makeContinuousPlan(tuning: resolvedFreeformTuning(customTuning))
    }

    private static func makeContinuousPlan(tuning: AdvancedTuning) -> ContinuousWalkPlan {
        let period = tuning.periodMs.clamped(to: 350...1000)
        let samplePhases: [Double] = [0.03, 0.18, 0.42, 0.52, 0.68, 0.92]
        let playMs = max(80, Int((period / Double(samplePhases.count)).rounded()))

        // 6 cycle phase steps — anchor 없음. 연속 반복 시 phase[5] → phase[0] 자연 wrap.
        let cycle: [MotionStep] = samplePhases.map { phase in
            let timeMs = phase * period
            let pose = robotisWalkingApproxPose(timeMs: timeMs, tuning: tuning) ?? .walkReady
            return .from(pose: pose, playMs: playMs, pauseMs: 0)
        }

        // Entry — walkReady → phase[0] transition. playMs 길게 (안전).
        let entryPlayMs = max(240, playMs * 2)
        let entry: [MotionStep] = [
            .from(pose: .walkReady, playMs: entryPlayMs, pauseMs: 0)
        ]
        // Exit — phase[5] → walkReady. 약간 더 길게 + pause 로 정지 명확화.
        let exitPlayMs = max(240, playMs * 2)
        let exit: [MotionStep] = [
            .from(pose: .walkReady, playMs: exitPlayMs, pauseMs: 40)
        ]

        return ContinuousWalkPlan(entry: entry, cycle: cycle, exit: exit)
    }

    /// **Phase G11 (2026-05-15)**: sim mode 의 phase pose 합성을 외부에 노출.
    ///
    /// `WalkLabSession` 의 50ms tick 이 실 로봇 미연결 상태에서도 3D 모델을 보행
    /// 따라 움직이게 하려고 호출. internal `robotisWalkingApproxPose` 의 wrapper.
    public static func simWalkingPose(timeMs: Double, tuning: AdvancedTuning) -> RobotPose? {
        robotisWalkingApproxPose(timeMs: timeMs, tuning: tuning)
    }

    /// 한 프리셋의 보행 사이클 페이지 반환. nil 이면 송출 불가 (`idle`).
    public static func page(for preset: WalkLabPreset, tuning customTuning: AdvancedTuning?) -> MotionPage? {
        switch preset {
        case .idle:
            return nil
        case .march:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return walkingPage(id: 200, name: "WalkLab march — ROBOTIS approx 제자리 보행", tuning: tuning)
        case .slowWalk:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return walkingPage(id: 201, name: "WalkLab slowWalk — ROBOTIS approx 전진 보행", tuning: tuning)
        case .normalWalk:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return walkingPage(id: 202, name: "WalkLab normalWalk — ROBOTIS approx 전진 보행", tuning: tuning)
        case .fastWalk:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return walkingPage(id: 203, name: "WalkLab fastWalk — ROBOTIS approx 전진 보행", tuning: tuning)
        case .jog:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return goalFollowKickPage(tuning: tuning)
        case .turnLeft:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return walkingPage(id: 205, name: "WalkLab turnLeft — ROBOTIS approx 좌회전 보행", tuning: tuning)
        case .turnRight:
            let tuning = resolvedTuning(for: preset, custom: customTuning)
            return walkingPage(id: 206, name: "WalkLab turnRight — ROBOTIS approx 우회전 보행", tuning: tuning)
        }
    }

    // MARK: - Preset tuning

    /// **D1 (2026-06-12)**: 시간 기반 모드용 resolved tuning 노출. `continuousWalkPlan`
    /// 이 키프레임을 빌드할 때 쓰는 것과 **동일한 클램프 결과**를 반환해, 시간 기반
    /// 샘플러가 같은 진폭으로 평가되도록(동치 보장) 한다.
    public static func resolvedPresetTuning(for preset: WalkLabPreset,
                                            custom: AdvancedTuning? = nil) -> AdvancedTuning {
        resolvedTuning(for: preset, custom: custom)
    }

    private static func resolvedTuning(for preset: WalkLabPreset, custom: AdvancedTuning?) -> AdvancedTuning {
        let base = custom ?? defaultTuning(for: preset)
        return AdvancedTuning(
            strideMm: base.strideMm.clamped(to: 0...50),
            sideMm: base.sideMm.clamped(to: -25...25),
            turnDeg: base.turnDeg.clamped(to: -45...45),
            periodMs: base.periodMs.clamped(to: 350...1000),
            footHeightMm: base.footHeightMm.clamped(to: 15...80),
            balanceGain: base.balanceGain.clamped(to: 0...5),
            // **v1.11.4 (2026-05-18) fix**: custom 의 hipPitchOffsetDeg 전달. 종전엔
            // 누락되어 모든 custom tuning 의 trim 이 default 13.0 으로 reset 되는 버그.
            hipPitchOffsetDeg: base.hipPitchOffsetDeg.clamped(to: 0...20)
        )
    }

    /// **D1 (2026-06-12)**: freeform 시간 기반 모드용 resolved tuning 노출 —
    /// `freeformContinuousWalkPlan` 키프레임과 동일 클램프(동치 보장).
    public static func freeformResolvedTuning(_ base: AdvancedTuning) -> AdvancedTuning {
        resolvedFreeformTuning(base)
    }

    private static func resolvedFreeformTuning(_ base: AdvancedTuning) -> AdvancedTuning {
        AdvancedTuning(
            strideMm: base.strideMm.clamped(to: -30...50),
            sideMm: base.sideMm.clamped(to: -25...25),
            turnDeg: base.turnDeg.clamped(to: -45...45),
            periodMs: base.periodMs.clamped(to: 350...1000),
            footHeightMm: base.footHeightMm.clamped(to: 15...80),
            balanceGain: base.balanceGain.clamped(to: 0...5),
            hipPitchOffsetDeg: base.hipPitchOffsetDeg.clamped(to: 0...20)
        )
    }

    /// preset 별 default tuning — sim/실 송출 양쪽에서 동일 합성 결과 보장.
    ///
    /// **Phase G12 (Codex audit 4th pass, 2026-05-15)**: 이전 `WalkLabSession.tick`
    /// 의 sim mode 가 이 함수 대신 `(strideMm: 25, sideMm: 0, turnDeg: 0)` 하드코드를
    /// 써서 **모든 preset 이 동일 보행 자세** 로 시각화됐던 P0 버그를 차단. public 노출로
    /// 단일 source-of-truth.
    public static func defaultTuning(for preset: WalkLabPreset) -> AdvancedTuning {
        switch preset {
        case .idle:
            return AdvancedTuning(strideMm: 0, sideMm: 0, turnDeg: 0, periodMs: 600, footHeightMm: 40, balanceGain: 1.0)
        case .march:
            return AdvancedTuning(strideMm: 0, sideMm: 0, turnDeg: 0, periodMs: 650, footHeightMm: 38, balanceGain: 1.0)
        // v1.8 (2026-05-17 사용자 보고 "동작 괴해짐" 정정):
        // - turnLeft/Right 가 호 그리기 실패 (stride 8mm + turnDeg 20° → foot 직진 +
        //   hip yaw twist) → stride 18mm + turnDeg 35° 로 호 곡률 확대.
        // - fastWalk stride 45mm 는 IK 안정 marginal → 38mm.
        case .slowWalk:
            // 매우 천천히 — stride 12mm, period 800ms → ~15 mm/s.
            return AdvancedTuning(strideMm: 12, sideMm: 0, turnDeg: 0, periodMs: 800, footHeightMm: 32, balanceGain: 1.0)
        case .normalWalk:
            // 일반 — stride 28mm, period 600ms → ~47 mm/s.
            return AdvancedTuning(strideMm: 28, sideMm: 0, turnDeg: 0, periodMs: 600, footHeightMm: 40, balanceGain: 1.0)
        case .fastWalk:
            // 빠르게 — stride 38mm (IK 안정 margin), period 450ms → ~85 mm/s.
            return AdvancedTuning(strideMm: 38, sideMm: 0, turnDeg: 0, periodMs: 450, footHeightMm: 46, balanceGain: 1.2)
        case .jog:
            return AdvancedTuning(strideMm: 32, sideMm: 0, turnDeg: 0, periodMs: 500, footHeightMm: 44, balanceGain: 1.1)
        case .turnLeft:
            // 좌회전 — stride 18mm 전진 + turnDeg 25° → 호 그리기.
            // hip yaw 안전 가드 (60° 임계) 통과. (turnDeg 35° + multiplier 1.5x = 87° 위반)
            return AdvancedTuning(strideMm: 18, sideMm: 0, turnDeg: 25, periodMs: 700, footHeightMm: 40, balanceGain: 1.1)
        case .turnRight:
            return AdvancedTuning(strideMm: 18, sideMm: 0, turnDeg: -25, periodMs: 700, footHeightMm: 40, balanceGain: 1.1)
        }
    }

    // MARK: - Page builders

    private static func walkingPage(id: UInt8, name: String, tuning: AdvancedTuning) -> MotionPage {
        MotionPage(
            id: id,
            name: name,
            speed: 32,
            accel: 32,
            steps: walkingSteps(tuning: tuning, includeAnchors: true)
        )
    }

    /// 공식 SOCCER 데모 구조: walking 접근 1 cycle → action page 12 Right Kick.
    private static func goalFollowKickPage(tuning: AdvancedTuning) -> MotionPage {
        let approach = walkingSteps(tuning: tuning, includeAnchors: false)
        let kick = officialRightKickSteps()
        return MotionPage(
            id: 204,
            name: "WalkLab goal-follow kick — ROBOTIS approx walking + page 12 right kick",
            repeat: 1,
            speed: 32,
            accel: 32,
            steps: [.from(pose: .walkReady, playMs: 420, pauseMs: 0)]
                + approach
                + kick
                + [.from(pose: .walkReady, playMs: 520, pauseMs: 160)]
        )
    }

    private static func walkingSteps(tuning: AdvancedTuning, includeAnchors: Bool) -> [MotionStep] {
        let period = tuning.periodMs.clamped(to: 350...1000)
        let samplePhases: [Double] = [0.03, 0.18, 0.42, 0.52, 0.68, 0.92]
        let playMs = max(80, Int((period / Double(samplePhases.count)).rounded()))

        var steps: [MotionStep] = []
        if includeAnchors {
            steps.append(.from(pose: .walkReady, playMs: max(240, playMs * 2), pauseMs: 0))
        }

        for phase in samplePhases {
            let timeMs = phase * period
            let pose = robotisWalkingApproxPose(timeMs: timeMs, tuning: tuning) ?? .walkReady
            steps.append(.from(pose: pose, playMs: playMs, pauseMs: 0))
        }

        if includeAnchors {
            steps.append(.from(pose: .walkReady, playMs: max(240, playMs * 2), pauseMs: 40))
        }
        return steps
    }

    // MARK: - ROBOTIS walking synthesis

    private struct RobotisWalkingState {
        let periodTime: Double
        let sspRatio: Double
        let xSwapPeriod: Double
        let xMovePeriod: Double
        let ySwapPeriod: Double
        let yMovePeriod: Double
        let zSwapPeriod: Double
        let zMovePeriod: Double
        let aMovePeriod: Double
        let sspStartL: Double
        let sspEndL: Double
        let sspStartR: Double
        let sspEndR: Double

        let xMoveAmplitude: Double
        let xSwapAmplitude: Double
        let yMoveAmplitude: Double
        let yMoveAmplitudeShift: Double
        let ySwapAmplitude: Double
        let zMoveAmplitude: Double
        let zMoveAmplitudeShift: Double
        let zSwapAmplitude: Double
        let zSwapAmplitudeShift: Double
        let aMoveAmplitude: Double
        let aMoveAmplitudeShift: Double

        let xOffset: Double
        let yOffset: Double
        let zOffset: Double
        let rollOffset: Double
        let pitchOffset: Double
        let yawOffset: Double
        let hipPitchOffset: Double
        let pelvisOffsetValue: Double
        let pelvisSwingValue: Double
        let armSwingGain: Double

        init(tuning: AdvancedTuning) {
            periodTime = tuning.periodMs.clamped(to: 350...1000)
            let dspRatio = 0.1
            sspRatio = 1.0 - dspRatio
            xSwapPeriod = periodTime / 2
            xMovePeriod = periodTime * sspRatio
            ySwapPeriod = periodTime
            yMovePeriod = periodTime * sspRatio
            zSwapPeriod = periodTime / 2
            zMovePeriod = periodTime * sspRatio / 2
            aMovePeriod = periodTime * sspRatio
            sspStartL = (1.0 - sspRatio) * periodTime / 4
            sspEndL = (1.0 + sspRatio) * periodTime / 4
            sspStartR = (3.0 - sspRatio) * periodTime / 4
            sspEndR = (3.0 + sspRatio) * periodTime / 4

            xMoveAmplitude = tuning.strideMm.clamped(to: -30...50)
            xSwapAmplitude = xMoveAmplitude * 0.28

            yMoveAmplitude = tuning.sideMm.clamped(to: -25...25) / 2
            yMoveAmplitudeShift = abs(yMoveAmplitude)
            let balance = tuning.balanceGain.clamped(to: 0...5)
            ySwapAmplitude = (20.0 * max(0.4, min(1.5, balance))) + yMoveAmplitudeShift * 0.04

            zMoveAmplitude = tuning.footHeightMm.clamped(to: 15...80) / 2
            zMoveAmplitudeShift = zMoveAmplitude / 2
            zSwapAmplitude = 5.0
            zSwapAmplitudeShift = zSwapAmplitude

            aMoveAmplitude = tuning.turnDeg.clamped(to: -45...45) * .pi / 180.0 / 2
            aMoveAmplitudeShift = abs(aMoveAmplitude)

            xOffset = -10.0
            yOffset = 5.0
            zOffset = 20.0
            rollOffset = 0
            pitchOffset = 0
            yawOffset = 0
            // **v1.11.4 (2026-05-18)** — tuning.hipPitchOffsetDeg 노출. 종전 13.0 하드코딩.
            hipPitchOffset = tuning.hipPitchOffsetDeg.clamped(to: 0...20)
            pelvisOffsetValue = 3.0 * rawPerDegree
            pelvisSwingValue = pelvisOffsetValue * 0.35
            armSwingGain = 1.5
        }
    }

    private static func robotisWalkingApproxPose(timeMs rawTimeMs: Double, tuning: AdvancedTuning) -> RobotPose? {
        let state = RobotisWalkingState(tuning: tuning)
        let time = rawTimeMs.truncatingRemainder(dividingBy: state.periodTime)

        let xSwap = wsin(time, state.xSwapPeriod, .pi, state.xSwapAmplitude, 0)
        let ySwap = wsin(time, state.ySwapPeriod, 0, state.ySwapAmplitude, state.yMoveAmplitudeShift)
        let zSwap = wsin(time, state.zSwapPeriod, .pi * 1.5, state.zSwapAmplitude, state.zSwapAmplitudeShift)

        let movement = walkingMovement(time: time, state: state)

        let epR = Endpoint(
            x: xSwap + movement.xMoveR + state.xOffset,
            y: ySwap + movement.yMoveR - state.yOffset / 2,
            z: zSwap + movement.zMoveR + state.zOffset,
            a: movement.aMoveR - state.rollOffset / 2,
            b: state.pitchOffset,
            c: movement.cMoveR - state.yawOffset / 2
        )
        let epL = Endpoint(
            x: xSwap + movement.xMoveL + state.xOffset,
            y: ySwap + movement.yMoveL + state.yOffset / 2,
            z: zSwap + movement.zMoveL + state.zOffset,
            a: movement.aMoveL + state.rollOffset / 2,
            b: state.pitchOffset,
            c: movement.cMoveL + state.yawOffset / 2
        )

        guard let rightAngles = computeLegIK(epR),
              let leftAngles = computeLegIK(epL) else {
            return nil
        }

        var angleDeg = Array(repeating: 0.0, count: 14)
        for i in 0..<6 { angleDeg[i] = rightAngles[i] * 180.0 / .pi }
        for i in 0..<6 { angleDeg[i + 6] = leftAngles[i] * 180.0 / .pi }

        if state.xMoveAmplitude != 0 {
            angleDeg[12] = wsin(time, state.periodTime, .pi * 1.5, -state.xMoveAmplitude * state.armSwingGain, 0)
            angleDeg[13] = wsin(time, state.periodTime, .pi * 1.5, state.xMoveAmplitude * state.armSwingGain, 0)
        }

        let dir: [Double] = [-1, -1, 1, 1, -1, 1, -1, -1, -1, -1, 1, 1, 1, -1]
        let initAngle: [Double] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -48.345, 41.313]
        var raw = Array(repeating: 2048, count: 14)

        for i in 0..<14 {
            var offset = dir[i] * angleDeg[i] * rawPerDegree
            if i == 1 {
                offset += dir[i] * movement.pelvisOffsetR
            } else if i == 7 {
                offset += dir[i] * movement.pelvisOffsetL
            } else if i == 2 || i == 8 {
                offset -= dir[i] * state.hipPitchOffset * rawPerDegree
            }
            raw[i] = angleToRaw(initAngle[i]) + Int(offset.rounded())
        }

        // Sparse keyframes do not reproduce the 8 ms walking module yaw integration perfectly.
        // Add a bounded hip-yaw bias so turn sliders/presets have a deterministic physical direction.
        // v1.8 (2026-05-17): multiplier 1.5x → 1.0x. 35° × 1.5x = 87° hip yaw 변화 (안전 60° 초과).
        // 1.0x 면 25° × 1.0x = 25° + cMove 12.5° = 37.5° (안전).
        let yawBias = Int((tuning.turnDeg.clamped(to: -45...45) * rawPerDegree * 1.0).rounded())
        raw[0] -= yawBias
        raw[6] += yawBias

        return RobotPose.walkReady.with([
            .rHipYaw: raw[0],
            .rHipRoll: raw[1],
            .rHipPitch: raw[2],
            .rKnee: raw[3],
            .rAnklePitch: raw[4],
            .rAnkleRoll: raw[5],
            .lHipYaw: raw[6],
            .lHipRoll: raw[7],
            .lHipPitch: raw[8],
            .lKnee: raw[9],
            .lAnklePitch: raw[10],
            .lAnkleRoll: raw[11],
            .rShoulderPitch: raw[12],
            .lShoulderPitch: raw[13],
        ])
    }

    private struct WalkingMovement {
        var xMoveR: Double
        var yMoveR: Double
        var zMoveR: Double
        var cMoveR: Double
        var xMoveL: Double
        var yMoveL: Double
        var zMoveL: Double
        var cMoveL: Double
        var aMoveR: Double = 0
        var bMoveR: Double = 0
        var aMoveL: Double = 0
        var bMoveL: Double = 0
        var pelvisOffsetR: Double
        var pelvisOffsetL: Double
    }

    private static func walkingMovement(time: Double, state s: RobotisWalkingState) -> WalkingMovement {
        let leftStartShiftX = .pi / 2 + 2 * .pi / s.xMovePeriod * s.sspStartL
        let leftStartShiftY = .pi / 2 + 2 * .pi / s.yMovePeriod * s.sspStartL
        let leftStartShiftZ = .pi / 2 + 2 * .pi / s.zMovePeriod * s.sspStartL
        let leftStartShiftA = .pi / 2 + 2 * .pi / s.aMovePeriod * s.sspStartL

        let rightStartShiftX = .pi / 2 + 2 * .pi / s.xMovePeriod * s.sspStartR + .pi
        let rightStartShiftY = .pi / 2 + 2 * .pi / s.yMovePeriod * s.sspStartR + .pi
        let rightStartShiftZ = .pi / 2 + 2 * .pi / s.zMovePeriod * s.sspStartR
        let rightStartShiftA = .pi / 2 + 2 * .pi / s.aMovePeriod * s.sspStartR + .pi

        if time <= s.sspStartL {
            return WalkingMovement(
                xMoveR: wsin(s.sspStartL, s.xMovePeriod, leftStartShiftX, -s.xMoveAmplitude, 0),
                yMoveR: wsin(s.sspStartL, s.yMovePeriod, leftStartShiftY, -s.yMoveAmplitude, -s.yMoveAmplitudeShift),
                zMoveR: wsin(s.sspStartR, s.zMovePeriod, rightStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveR: wsin(s.sspStartL, s.aMovePeriod, leftStartShiftA, -s.aMoveAmplitude, -s.aMoveAmplitudeShift),
                xMoveL: wsin(s.sspStartL, s.xMovePeriod, leftStartShiftX, s.xMoveAmplitude, 0),
                yMoveL: wsin(s.sspStartL, s.yMovePeriod, leftStartShiftY, s.yMoveAmplitude, s.yMoveAmplitudeShift),
                zMoveL: wsin(s.sspStartL, s.zMovePeriod, leftStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveL: wsin(s.sspStartL, s.aMovePeriod, leftStartShiftA, s.aMoveAmplitude, s.aMoveAmplitudeShift),
                pelvisOffsetR: 0,
                pelvisOffsetL: 0
            )
        }

        if time <= s.sspEndL {
            return WalkingMovement(
                xMoveR: wsin(time, s.xMovePeriod, leftStartShiftX, -s.xMoveAmplitude, 0),
                yMoveR: wsin(time, s.yMovePeriod, leftStartShiftY, -s.yMoveAmplitude, -s.yMoveAmplitudeShift),
                zMoveR: wsin(s.sspStartR, s.zMovePeriod, rightStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveR: wsin(time, s.aMovePeriod, leftStartShiftA, -s.aMoveAmplitude, -s.aMoveAmplitudeShift),
                xMoveL: wsin(time, s.xMovePeriod, leftStartShiftX, s.xMoveAmplitude, 0),
                yMoveL: wsin(time, s.yMovePeriod, leftStartShiftY, s.yMoveAmplitude, s.yMoveAmplitudeShift),
                zMoveL: wsin(time, s.zMovePeriod, leftStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveL: wsin(time, s.aMovePeriod, leftStartShiftA, s.aMoveAmplitude, s.aMoveAmplitudeShift),
                pelvisOffsetR: wsin(time, s.zMovePeriod, leftStartShiftZ, -s.pelvisOffsetValue / 2, -s.pelvisOffsetValue / 2),
                pelvisOffsetL: wsin(time, s.zMovePeriod, leftStartShiftZ, s.pelvisSwingValue / 2, s.pelvisSwingValue / 2)
            )
        }

        if time <= s.sspStartR {
            return WalkingMovement(
                xMoveR: wsin(s.sspEndL, s.xMovePeriod, leftStartShiftX, -s.xMoveAmplitude, 0),
                yMoveR: wsin(s.sspEndL, s.yMovePeriod, leftStartShiftY, -s.yMoveAmplitude, -s.yMoveAmplitudeShift),
                zMoveR: wsin(s.sspStartR, s.zMovePeriod, rightStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveR: wsin(s.sspEndL, s.aMovePeriod, leftStartShiftA, -s.aMoveAmplitude, -s.aMoveAmplitudeShift),
                xMoveL: wsin(s.sspEndL, s.xMovePeriod, leftStartShiftX, s.xMoveAmplitude, 0),
                yMoveL: wsin(s.sspEndL, s.yMovePeriod, leftStartShiftY, s.yMoveAmplitude, s.yMoveAmplitudeShift),
                zMoveL: wsin(s.sspEndL, s.zMovePeriod, leftStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveL: wsin(s.sspEndL, s.aMovePeriod, leftStartShiftA, s.aMoveAmplitude, s.aMoveAmplitudeShift),
                pelvisOffsetR: 0,
                pelvisOffsetL: 0
            )
        }

        if time <= s.sspEndR {
            return WalkingMovement(
                xMoveR: wsin(time, s.xMovePeriod, rightStartShiftX, -s.xMoveAmplitude, 0),
                yMoveR: wsin(time, s.yMovePeriod, rightStartShiftY, -s.yMoveAmplitude, -s.yMoveAmplitudeShift),
                zMoveR: wsin(time, s.zMovePeriod, rightStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveR: wsin(time, s.aMovePeriod, rightStartShiftA, -s.aMoveAmplitude, -s.aMoveAmplitudeShift),
                xMoveL: wsin(time, s.xMovePeriod, rightStartShiftX, s.xMoveAmplitude, 0),
                yMoveL: wsin(time, s.yMovePeriod, rightStartShiftY, s.yMoveAmplitude, s.yMoveAmplitudeShift),
                zMoveL: wsin(s.sspEndL, s.zMovePeriod, leftStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
                cMoveL: wsin(time, s.aMovePeriod, rightStartShiftA, s.aMoveAmplitude, s.aMoveAmplitudeShift),
                pelvisOffsetR: wsin(time, s.zMovePeriod, rightStartShiftZ, -s.pelvisSwingValue / 2, -s.pelvisSwingValue / 2),
                pelvisOffsetL: wsin(time, s.zMovePeriod, rightStartShiftZ, s.pelvisOffsetValue / 2, s.pelvisOffsetValue / 2)
            )
        }

        return WalkingMovement(
            xMoveR: wsin(s.sspEndR, s.xMovePeriod, rightStartShiftX, -s.xMoveAmplitude, 0),
            yMoveR: wsin(s.sspEndR, s.yMovePeriod, rightStartShiftY, -s.yMoveAmplitude, -s.yMoveAmplitudeShift),
            zMoveR: wsin(s.sspEndR, s.zMovePeriod, rightStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
            cMoveR: wsin(s.sspEndR, s.aMovePeriod, rightStartShiftA, -s.aMoveAmplitude, -s.aMoveAmplitudeShift),
            xMoveL: wsin(s.sspEndR, s.xMovePeriod, rightStartShiftX, s.xMoveAmplitude, 0),
            yMoveL: wsin(s.sspEndR, s.yMovePeriod, rightStartShiftY, s.yMoveAmplitude, s.yMoveAmplitudeShift),
            zMoveL: wsin(s.sspEndL, s.zMovePeriod, leftStartShiftZ, s.zMoveAmplitude, s.zMoveAmplitudeShift),
            cMoveL: wsin(s.sspEndR, s.aMovePeriod, rightStartShiftA, s.aMoveAmplitude, s.aMoveAmplitudeShift),
            pelvisOffsetR: 0,
            pelvisOffsetL: 0
        )
    }

    private struct Endpoint {
        var x: Double
        var y: Double
        var z: Double
        var a: Double
        var b: Double
        var c: Double
    }

    private static func computeLegIK(_ endpoint: Endpoint) -> [Double]? {
        let tad = Matrix4.transform(
            point: Vec3(endpoint.x, endpoint.y, endpoint.z - legLength),
            angleDegrees: Vec3(endpoint.a * 180 / .pi, endpoint.b * 180 / .pi, endpoint.c * 180 / .pi)
        )

        let vec = Vec3(
            endpoint.x + tad.m[2] * ankleLength,
            endpoint.y + tad.m[6] * ankleLength,
            (endpoint.z - legLength) + tad.m[10] * ankleLength
        )

        let rac = vec.length
        let kneeArg = ((rac * rac) - (thighLength * thighLength) - (calfLength * calfLength))
            / (2 * thighLength * calfLength)
        guard kneeArg.isFinite else { return nil }
        let knee = acos(kneeArg.clamped(to: -1...1))
        guard knee.isFinite else { return nil }

        let tda = tad.invertedRigid()
        let k = sqrt(tda.m[7] * tda.m[7] + tda.m[11] * tda.m[11])
        let l = sqrt(tda.m[7] * tda.m[7] + (tda.m[11] - ankleLength) * (tda.m[11] - ankleLength))
        guard l > 0 else { return nil }
        let m = ((k * k) - (l * l) - (ankleLength * ankleLength)) / (2 * l * ankleLength)
        let ankleRollAbs = acos(m.clamped(to: -1...1))
        guard ankleRollAbs.isFinite else { return nil }
        let ankleRoll = tda.m[7] < 0 ? -ankleRollAbs : ankleRollAbs

        let tcd = Matrix4.transform(
            point: Vec3(0, 0, -ankleLength),
            angleDegrees: Vec3(ankleRoll * 180 / .pi, 0, 0)
        )
        let tac = tad * tcd.invertedRigid()

        let hipYaw = atan2(-tac.m[1], tac.m[5])
        guard hipYaw.isFinite else { return nil }

        let hipRoll = atan2(tac.m[9], -tac.m[1] * sin(hipYaw) + tac.m[5] * cos(hipYaw))
        guard hipRoll.isFinite else { return nil }

        let theta = atan2(
            tac.m[2] * cos(hipYaw) + tac.m[6] * sin(hipYaw),
            tac.m[0] * cos(hipYaw) + tac.m[4] * sin(hipYaw)
        )
        guard theta.isFinite else { return nil }

        let kk = sin(knee) * calfLength
        let ll = -thighLength - cos(knee) * calfLength
        let mm = cos(hipYaw) * vec.x + sin(hipYaw) * vec.y
        let nn = cos(hipRoll) * vec.z + sin(hipYaw) * sin(hipRoll) * vec.x
            - cos(hipYaw) * sin(hipRoll) * vec.y
        let denom = kk * kk + ll * ll
        guard denom > 0 else { return nil }
        let ss = (kk * nn + ll * mm) / denom
        let cc = (nn - kk * ss) / ll
        let hipPitch = atan2(ss, cc)
        guard hipPitch.isFinite else { return nil }

        let anklePitch = theta - knee - hipPitch
        guard anklePitch.isFinite else { return nil }

        return [hipYaw, hipRoll, hipPitch, knee, anklePitch, ankleRoll]
    }

    private static func wsin(_ time: Double, _ period: Double, _ periodShift: Double, _ magnitude: Double, _ magnitudeShift: Double) -> Double {
        guard period != 0 else { return magnitudeShift }
        return magnitude * sin(2 * .pi / period * time - periodShift) + magnitudeShift
    }

    private static func angleToRaw(_ degrees: Double) -> Int {
        Int((degrees * rawPerDegree).rounded()) + 2048
    }

    private static let rawPerDegree = 2048.0 / 180.0
    private static let thighLength = 93.0
    private static let calfLength = 93.0
    private static let ankleLength = 33.5
    private static let legLength = 219.5

    // MARK: - Official page 12 kick

    private static func officialRightKickSteps() -> [MotionStep] {
        let rawSteps: [[Int]] = [
            [
                0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                0x4000,
            ],
            [
                0x4200, 0x057f, 0x0974, 0x072d, 0x08ef, 0x094f, 0x06b2, 0x0802, 0x0802, 0x0809,
                0x07fb, 0x0665, 0x099b, 0x0a56, 0x05a3, 0x0955, 0x06ab, 0x089b, 0x0870, 0x0802,
                0x089f, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                0x0000,
            ],
            [
                0x4200, 0x057f, 0x0974, 0x072d, 0x08ef, 0x094f, 0x06b2, 0x0802, 0x0802, 0x084b,
                0x07da, 0x059a, 0x0a21, 0x0bcc, 0x0572, 0x09e5, 0x06ab, 0x089b, 0x0870, 0x0802,
                0x089f, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                0x0000,
            ],
            [
                0x4200, 0x053c, 0x08ac, 0x070c, 0x08ef, 0x0802, 0x05c8, 0x0802, 0x0802, 0x084b,
                0x07da, 0x048c, 0x09ef, 0x0953, 0x0586, 0x0702, 0x06cc, 0x086d, 0x084f, 0x0802,
                0x09cb, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                0x0000,
            ],
            [
                0x4200, 0x057f, 0x0974, 0x072d, 0x08ef, 0x094f, 0x06b2, 0x0802, 0x0802, 0x084b,
                0x07da, 0x0504, 0x09e5, 0x0bcc, 0x0586, 0x09e5, 0x06b2, 0x089b, 0x0870, 0x0802,
                0x089f, 0x4200, 0x4200, 0x4200, 0x4200, 0x4200, 0x0000, 0x0000, 0x0000, 0x0000,
                0x0000,
            ],
            [
                0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                0x4000,
            ],
            [
                0x4000, 0x05da, 0x09d6, 0x0735, 0x08c8, 0x094d, 0x06b0, 0x0800, 0x0800, 0x0804,
                0x07fc, 0x0665, 0x099b, 0x0a5d, 0x05a3, 0x0955, 0x06ab, 0x0809, 0x07f7, 0x0800,
                0x0871, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000, 0x4000,
                0x4000,
            ],
        ]
        // Phase G6 (Codex audit P1-6, 2026-05-14): 공식 motion_4096.bin page 12 timing.
        // 이전 값 (step 3-6 의 play 160ms) 은 +312 ms (+18.8%) 더 길어서 사용자 인지
        // 와 motion replay 가 공식과 어긋났음. ROBOTIS Action.cpp 의 step.time × 8 ms.
        let timing: [(play: Int, pause: Int)] = [
            (496, 0),
            (200, 0),
            (72, 0),
            (72, 144),
            (72, 0),
            (112, 0),
            (496, 0),
        ]

        var pose = RobotPose.walkReady
        var steps: [MotionStep] = []
        for (index, rawPositions) in rawSteps.enumerated() {
            var updates: [JointID: Int] = [:]
            for joint in JointID.allCases {
                let raw = rawPositions[Int(joint.rawValue)]
                if raw == 0 || (raw & 0x4000) != 0 { continue }
                updates[joint] = raw & 0x0fff
            }
            pose = pose.with(updates)
            steps.append(.from(pose: pose, playMs: timing[index].play, pauseMs: timing[index].pause))
        }
        return steps
    }

    // MARK: - Math helpers

    private struct Vec3 {
        var x: Double
        var y: Double
        var z: Double

        init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        var length: Double {
            sqrt(x * x + y * y + z * z)
        }
    }

    private struct Matrix4 {
        var m: [Double]

        static var identity: Matrix4 {
            Matrix4(m: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ])
        }

        static func transform(point: Vec3, angleDegrees: Vec3) -> Matrix4 {
            let cx = cos(angleDegrees.x * .pi / 180)
            let cy = cos(angleDegrees.y * .pi / 180)
            let cz = cos(angleDegrees.z * .pi / 180)
            let sx = sin(angleDegrees.x * .pi / 180)
            let sy = sin(angleDegrees.y * .pi / 180)
            let sz = sin(angleDegrees.z * .pi / 180)

            return Matrix4(m: [
                cz * cy,
                cz * sy * sx - sz * cx,
                cz * sy * cx + sz * sx,
                point.x,
                sz * cy,
                sz * sy * sx + cz * cx,
                sz * sy * cx - cz * sx,
                point.y,
                -sy,
                cy * sx,
                cy * cx,
                point.z,
                0, 0, 0, 1,
            ])
        }

        func invertedRigid() -> Matrix4 {
            let tx = m[3]
            let ty = m[7]
            let tz = m[11]

            var out = Matrix4.identity
            out.m[0] = m[0]
            out.m[1] = m[4]
            out.m[2] = m[8]
            out.m[4] = m[1]
            out.m[5] = m[5]
            out.m[6] = m[9]
            out.m[8] = m[2]
            out.m[9] = m[6]
            out.m[10] = m[10]

            out.m[3] = -(out.m[0] * tx + out.m[1] * ty + out.m[2] * tz)
            out.m[7] = -(out.m[4] * tx + out.m[5] * ty + out.m[6] * tz)
            out.m[11] = -(out.m[8] * tx + out.m[9] * ty + out.m[10] * tz)
            return out
        }

        static func * (lhs: Matrix4, rhs: Matrix4) -> Matrix4 {
            var out = Array(repeating: 0.0, count: 16)
            for row in 0..<4 {
                for col in 0..<4 {
                    for k in 0..<4 {
                        out[row * 4 + col] += lhs.m[row * 4 + k] * rhs.m[k * 4 + col]
                    }
                }
            }
            return Matrix4(m: out)
        }
    }
}
