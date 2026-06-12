import Foundation
import ForgeCore

/// **방법론**: WalkLab 의 `WalkMotionLibrary.freeformContinuousWalkPlan(tuning:)`
/// 가 반환하는 `ContinuousWalkPlan.cycle` (6 phase keyframe) 을 시간 기반으로
/// 재생 + 인접 두 phase 사이를 linear interpolation 하여 30 Hz pose stream 을
/// 만든다. 정확히 워크 랩의 실 보행 모션을 재구성하므로, 사용자가 cockpit 에서
/// 보는 robot 다리 swing 이 워크 랩의 그것과 같다.
///
/// # 의도된 사용
///
/// ```
/// let animator = CockpitWalkAnimator()
/// // 매 30 Hz:
/// animator.update(commandStrideMm: cmd.strideMm,
///                 commandSideMm: cmd.sideMm,
///                 commandTurnDeg: cmd.turnDeg,
///                 enabled: !cmd.isStop)
/// chaseScene.applyPose(animator.pose)
/// ```
///
/// # 정확성 (실 데이터)
///
/// `WalkMotionLibrary.makeContinuousPlan` 의 보행 phase 는 ROBOTIS-OP2 의
/// `Walking.cpp` 의 `compute_*Pose` 함수와 동일한 분석적 IK 를 사용한다 (Bezier
/// 발끝 trajectory + 무릎 IK). 즉 cockpit 의 다리 swing 이 실 robot 의 보행
/// kinematics 와 1:1 대응한다.
///
/// 정지 시 (enabled=false): 0.4 초에 걸쳐 마지막 pose → `walkReady` linear ease.
@MainActor
public final class CockpitWalkAnimator {

    public private(set) var pose: RobotPose = .walkReady

    // MARK: - State

    /// 현재 보행 사이클 plan. 사용자가 새 amplitude 조합을 들어가면 갱신.
    private var cachedPlan: WalkMotionLibrary.ContinuousWalkPlan?
    /// cachedPlan 을 만든 tuning — 변화 감지 후 plan 갱신용.
    private var cachedTuning: WalkMotionLibrary.AdvancedTuning?
    /// cycle 시작 후 누적 elapsed 시간 (sec).
    private var cycleElapsed: TimeInterval = 0
    /// 정지 ease 전환 시작 시각. nil = ease 중 아님.
    private var stopEaseStartedAt: TimeInterval?
    /// stop ease 진입 시점의 pose — walkReady 까지 보간.
    private var poseAtStopEase: RobotPose = .walkReady
    /// 마지막 tick 시각 — dt 계산.
    private var lastTickAt: TimeInterval?
    /// 마지막으로 enabled 였는지 — toggle 감지.
    private var wasEnabled: Bool = false

    public init() {}

    // MARK: - API

    public func reset() {
        pose = .walkReady
        cachedPlan = nil
        cachedTuning = nil
        cycleElapsed = 0
        stopEaseStartedAt = nil
        poseAtStopEase = .walkReady
        lastTickAt = nil
        wasEnabled = false
    }

    /// 30 Hz tick 마다 호출. stick 입력의 amplitude (mm/deg) + cadence (periodMs)
    /// + 보행 활성 여부.
    ///
    /// **방법론 변경 (ROBOTIS Walking PERIOD_TIME)**: 종전 `speedScale` 이 baseline
    /// period (600ms) 를 나누어 cadence 를 derive. 신규: `periodMs` 를 직접 받음
    /// — Cockpit (CockpitState.periodMs) 와 실 motor (WalkLabSession.customPeriodMs)
    /// 가 동일 값. 시뮬 다리 swing 속도 = 실 robot 의 cadence (digital twin).
    /// **O4 (2026-06-12)** — TEL2 위상 동기 보정 게인. 실로봇 위상(0..1 분율)으로 시뮬
    /// cycleElapsed 를 매 tick 부분 보정해 "화면=실모터" 위상을 정렬한다. 저게인(0.15)이라
    /// 이산 4-위상(30Hz)에도 점프 없이 수렴 — dt 누적이 부드러운 모션을 유지.
    private static let phaseSyncGain: Double = 0.15

    public func update(commandStrideMm: Double,
                       commandSideMm: Double,
                       commandTurnDeg: Double,
                       periodMs: Double,
                       enabled: Bool,
                       externalPhaseFraction01: Double? = nil) {
        let now = Date().timeIntervalSince1970
        let dt: TimeInterval
        if let last = lastTickAt {
            dt = min(0.1, max(0, now - last))
        } else {
            dt = 0
        }
        lastTickAt = now

        // enabled 이 false 면 walkReady ease.
        if !enabled {
            if wasEnabled {
                // walking → stop 전환. 현재 pose 부터 ease 시작.
                stopEaseStartedAt = now
                poseAtStopEase = pose
            }
            wasEnabled = false
            if let start = stopEaseStartedAt {
                let easeDuration: TimeInterval = 0.4
                let alpha = min(1.0, (now - start) / easeDuration)
                pose = Self.lerp(from: poseAtStopEase, to: .walkReady,
                                 alpha: alpha)
                if alpha >= 1.0 {
                    stopEaseStartedAt = nil
                    pose = .walkReady
                }
            } else {
                pose = .walkReady
            }
            return
        }

        // enabled — cycle 재생.
        if !wasEnabled {
            // stop → walking 전환. cycle elapsed 리셋.
            cycleElapsed = 0
            stopEaseStartedAt = nil
        }
        wasEnabled = true

        // Build tuning from current stick command + caller 가 결정한 periodMs.
        // 우리는 mobile-freeform 의 safe clamp 를 그대로 사용 — 실 워크 랩과 같은
        // 한계. periodMs 는 caller 책임 (CockpitState 의 throttle slider 가 결정).
        //
        // **ROBOTIS Walking 의 속도 공식**:
        // `forward_speed_mmps = strideMm × 2000 / periodMs`
        // 시뮬-실 motor 의 period 가 동일 → 다리 swing 속도 일치 (digital twin).
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: commandStrideMm,
            sideMm: commandSideMm,
            turnDeg: commandTurnDeg,
            periodMs: periodMs,
            footHeightMm: 35,
            balanceGain: 1.0,
            hipPitchOffsetDeg: 13.0)
        let clamped = WalkMotionLibrary.mobileFreeformClamp(tuning)

        // Plan 캐시 — tuning 이 의미 있게 변하면 재계산.
        if !Self.tuningsClose(cachedTuning, clamped) || cachedPlan == nil {
            cachedPlan = WalkMotionLibrary.freeformContinuousWalkPlan(tuning: clamped)
            cachedTuning = clamped
        }
        guard let plan = cachedPlan, !plan.cycle.isEmpty else {
            pose = .walkReady
            return
        }

        // Sample cycle by accumulated elapsed time. period = sum of step playMs.
        cycleElapsed += dt
        let stepDurations = plan.cycle.map { Double($0.playMs) / 1000.0 }
        let totalPeriod = stepDurations.reduce(0, +)
        guard totalPeriod > 0.001 else {
            pose = plan.cycle.first?.toPose() ?? .walkReady
            return
        }

        // **O4** — 실로봇 위상으로 부분 보정(디지털 트윈 위상 동기). 최단 방향으로 위상 오차를
        // 게인만큼 끌어당겨 화면 다리 swing 을 실모터와 정렬(없으면 종전 자유 누적).
        if let frac = externalPhaseFraction01 {
            let target = max(0.0, min(1.0, frac)) * totalPeriod
            let cur = cycleElapsed.truncatingRemainder(dividingBy: totalPeriod)
            var err = target - cur
            if err > totalPeriod / 2 { err -= totalPeriod }
            if err < -totalPeriod / 2 { err += totalPeriod }
            cycleElapsed += err * Self.phaseSyncGain
        }

        let elapsedWrapped = cycleElapsed.truncatingRemainder(dividingBy: totalPeriod)

        // Find current segment.
        var acc: Double = 0
        var segIdx = 0
        var segProgress: Double = 0
        for (i, dur) in stepDurations.enumerated() {
            if elapsedWrapped < acc + dur {
                segIdx = i
                segProgress = (elapsedWrapped - acc) / dur
                break
            }
            acc += dur
        }
        let prev = plan.cycle[segIdx]
        let next = plan.cycle[(segIdx + 1) % plan.cycle.count]
        // Use chain-aware toPose so invalid bits preserve previous joint.
        let prevPose = prev.toPose(previous: pose)
        let nextPose = next.toPose(previous: prevPose)
        pose = Self.lerp(from: prevPose, to: nextPose,
                         alpha: max(0, min(1, segProgress)))
    }

    // MARK: - Helpers

    /// Per-joint raw-position linear interpolation. RobotPose 가 raw int 라
    /// 그대로 보간해도 angle interpolation 과 동치 (servo position == angle).
    private static func lerp(from a: RobotPose,
                             to b: RobotPose,
                             alpha: Double) -> RobotPose {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            let av = Double(a.raw(j))
            let bv = Double(b.raw(j))
            dict[j] = Int(((1 - alpha) * av + alpha * bv).rounded())
        }
        return RobotPose(positions: dict)
    }

    /// Tuning 이 의미 있게 다른가? 1mm / 0.5° 이하 변화는 noise 로 무시 — plan
    /// 재계산을 trigger 하지 않아 cpu 절약.
    private static func tuningsClose(_ a: WalkMotionLibrary.AdvancedTuning?,
                                     _ b: WalkMotionLibrary.AdvancedTuning) -> Bool {
        guard let a else { return false }
        return abs(a.strideMm - b.strideMm) < 1.0
            && abs(a.sideMm - b.sideMm) < 1.0
            && abs(a.turnDeg - b.turnDeg) < 0.5
            && abs(a.periodMs - b.periodMs) < 5
    }
}
