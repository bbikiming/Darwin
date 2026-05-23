import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 100: god object Phase 5 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` 의 balance correction code (~280 line) 를 본 extension 으로 이동.
/// 본 분할은 architect plan 의 **중간 위험** — 213-line `applyBalanceCorrectionIfEnabled`
/// 가 본체의 많은 private state 를 read/write 한다.
///
/// # 비유
///
/// 거대한 공장의 "균형 제어실" 만 별도 동으로 이전. 제어 회로 (state) 는 본 공장에 잔존,
/// 제어 콘솔 (method) 만 이전. 콘솔은 본 공장의 회로 카탈로그 (internal(set)) 로 접근.
///
/// # 분할 정책
///
/// - **stored property 본체 잔존** (Swift 제약): `lastCorrections` / `lastRawCandidate` /
///   `lastHybridResult` / `correctorFilteredRoll` / `correctorFilteredPitch` /
///   `hybridBalanceState` / `lastWalkCycleElapsedMs` / `lastWalkPeriodMs` /
///   `lastCorrectionApplied` / `cycleStartedAt` / `lastSafePose` / `correctionEnabledAt`.
/// - 본 cycle 에서 access 격상 (private → internal 또는 private(set) → internal(set)):
///   `correctionEnabledAt` (private → internal),
///   `lastCorrections` (private(set) → internal(set)),
///   `lastSafePose` (private → internal),
///   `lastImuSampleAt` (private → internal),
///   `correctorFilteredRoll/Pitch` (private → internal),
///   `hybridBalanceState` (private(set) → internal(set)),
///   `cycleStartedAt` (private(set) → internal(set)),
///   `lastCorrectionApplied` (private(set) → internal(set)),
///   `lastRawCandidate` (private(set) → internal(set)),
///   `lastHybridResult` (private(set) → internal(set)),
///   `lastWalkCycleElapsedMs` (private(set) → internal(set)),
///   `lastWalkPeriodMs` (private(set) → internal(set)).
/// - 이동 method/static: `applyBalanceCorrectionIfEnabled` (public),
///   `scaleCorrections` (internal static), `applyCorrections` (internal static).
///
/// # 의존성 (본체 잔존, extension 이 read)
///
/// `autoFallPrevention` (public) / `balanceState` (public private(set), read 만) /
/// `balanceExperimentConfig` (public) / `imuRollDeg/PitchDeg` (public) /
/// `enableBalanceCorrection` (public) / `balanceCorrector` (public) /
/// `effectiveWalkPeriodMs()` (public) / `current` (public) / `store` (internal).
///
/// # 회귀
///
/// 1267 tests 회귀 0 — 외부 API 변경 0 (`applyBalanceCorrectionIfEnabled` signature 동일).
extension WalkLabSession {

    /// **Stage 4 + Phase C (v1.1 fall prevention)**: Balance corrector + balanceState
    /// 둘 다 실 motor 송출 경로에 적용. sim/실 일관.
    ///
    /// 2026-05-16 Phase C 정정 (Agent 4 발견): 이전엔 Stage 2 의 warning 70% 감속 /
    /// danger 자세 동결이 sim engine 만 영향. 실 motor 경로는 미적용. 이번 정정에서
    /// **transformPose 가 balanceState 별로 pose 변환** 으로 실 motor 에도 적용:
    /// - `.danger` (45° 이상): 마지막 안전 pose (lastSafePose) 반환 = 자세 동결
    /// - 그 외: corrector 만 적용 (default false 면 identity)
    /// `.warning` (35° 이상) 의 속도 감속은 pose 변환으로는 표현 불가 → engine 감속만 유지
    /// (실 motor 의 cycle plan 은 미리 합성됨, 동적 stride 변경은 추후 Sprint).
    ///
    /// 입력 pose 는 보통 보행 cycle 의 phase target. roll/pitch error 는 현재 IMU.
    ///
    /// **v1.11 (2026-05-17 사용자 prompt) 분기**:
    /// `balanceExperimentConfig.algorithmMode` 별 corrections 계산 + `applyToRobot` 게이팅.
    ///   - `.off` → identity (corrections 0)
    ///   - `.robotisPControl` → LPF + deadband + P-control (v1.9.x 기존)
    ///   - `.hybridBA` → slow EMA + phase-locked residual (v1.10 시뮬 권장)
    ///   - `.observeOnly` → corrections 계산하고 lastCorrections 에 기록 + 로그만, pose 적용 X
    /// `applyToRobot=false` (observeOnly 외에도) → corrections 기록만, pose 적용 X.
    public func applyBalanceCorrectionIfEnabled(to pose: RobotPose) -> RobotPose {
        // **사이클 169 (W2.5)**: 243-line god method 를 phase 별 helper 로 분해.
        // 동작 100% 보존 — refactor only. helper 순서가 곧 safety-critical 우선순위.
        //   1. danger lockdown (autoFallPrevention)
        //   2. IMU freshness gate (250ms 감쇠 / 500ms 차단 / bus+IMU 없음 차단)
        //   3. input convention 정규화 (roll/pitch sign)
        //   4. algorithm mode .off + legacy toggle off → identity
        //   5. ramp + applyToRobot intent 결정
        //   6. hybrid 경로 또는 P-control 경로
        if let dangerPose = bcHandleDangerLockdown(pose) { return dangerPose }

        let gateResult = bcEvaluateFreshnessGate(pose: pose)
        if let earlyReturn = gateResult.earlyReturn { return earlyReturn }
        let freshnessGate = gateResult.gate

        let config = balanceExperimentConfig
        let normalized = bcNormalizedImuAngles(config: config)

        if let identityPose = bcHandleAlgorithmOff(config: config, pose: pose) {
            return identityPose
        }

        let now = Date()
        let intent = bcSetupRampAndIntent(now: now, config: config)

        let useHybridPath = balanceCorrector.enableHybrid
            && (config.algorithmMode == .hybridBA || config.algorithmMode == .observeOnly)

        if useHybridPath {
            return bcApplyHybridPath(
                pose: pose,
                normalized: normalized,
                config: config,
                ramp: intent.ramp,
                freshnessGate: freshnessGate,
                shouldApplyToPose: intent.shouldApplyToPose,
                now: now
            )
        }
        return bcApplyPControlPath(
            pose: pose,
            normalized: normalized,
            config: config,
            ramp: intent.ramp,
            freshnessGate: freshnessGate,
            shouldApplyToPose: intent.shouldApplyToPose
        )
    }

    // MARK: - Phase 1: Danger Lockdown

    /// `autoFallPrevention` + `balanceState == .danger` 시 last safe pose 로 동결.
    /// **Codex 3rd review fix**: danger return 도 candidate stale 방지.
    /// **사이클 164** (codex MINOR fix, cycle 160 review): danger early-return 도
    /// freshness 명시 — UI 가 "안전 lockdown 중" 으로 인지 (이전 stale state 잔존 X).
    /// - Returns: lockdown 발동 시 safe pose. 미발동 시 nil.
    private func bcHandleDangerLockdown(_ pose: RobotPose) -> RobotPose? {
        guard autoFallPrevention, balanceState == .danger else { return nil }
        lastCorrections = nil
        lastRawCandidate = nil
        lastCorrectionApplied = false
        balanceCorrectionFreshness = .normal
        return lastSafePose ?? pose
    }

    // MARK: - Phase 2: IMU Freshness Gate

    /// **v1.11.1 (2026-05-18 사용자 review HIGH-3 + Codex #2/#5) — IMU freshness gate**:
    /// 워킹 보정은 20Hz (50ms tick) 제어. 150-250ms 이상 stale IMU 로 corrections
    /// 적용 시 제어 lag → oscillation / fall 가속 위험. 종전 stale 기준 5초는
    /// UI 표시용으론 충분하지만 보정 제어용으론 위험.
    ///
    /// 정책 (Codex #2 권고 — IMU 5Hz polling jitter 흡수 위해 250ms 부터 감쇠):
    ///   - imuSampleAgeMs > 250 → corrections 감쇠 (linear 250→500ms 동안 1.0→0.0)
    ///   - imuSampleAgeMs ≥ 500 → corrections 강제 0 + apply 차단
    ///   - sim 모드 (store?.bus == nil + lastImuSampleAt nil) → gate 미적용
    ///
    /// **Codex #5 추가 발견**: bus 연결됐는데 lastImuSampleAt 가 nil (IMU 한 번도
    /// 안 옴) → 가장 위험. 보정 들어가면 fall 위험. → 차단.
    /// - Returns: `gate` (0..1, normal=1.0) 와 `earlyReturn` (blocked 시 pose 그대로 반환).
    private func bcEvaluateFreshnessGate(pose: RobotPose) -> (gate: Double, earlyReturn: RobotPose?) {
        let imuAgeMs: Double? = lastImuSampleAt.map {
            Date().timeIntervalSince($0) * 1000.0
        }
        #if DEBUG
        let busConnected = _testOverrideBusConnected ?? (store?.bus != nil)
        #else
        let busConnected = (store?.bus != nil)
        #endif
        if busConnected && lastImuSampleAt == nil {
            // 실 robot 연결됐지만 IMU 한 번도 안 옴 → 가장 위험 (보정 불가).
            bcResetStateForBlockedReturn(pose: pose)
            // 사이클 160 (P0-3 fix): UI 표시 가능하도록 freshness 상태 publish.
            balanceCorrectionFreshness = .blocked
            return (gate: 0.0, earlyReturn: pose)
        }
        if let age = imuAgeMs {
            if age >= 500 {
                // 매우 stale — corrections 0 + apply 차단.
                bcResetStateForBlockedReturn(pose: pose)
                // 사이클 160: blocked 상태 표시.
                balanceCorrectionFreshness = .blocked
                return (gate: 0.0, earlyReturn: pose)
            } else if age > 250 {
                // 부분 stale — linear 감쇠 (250→500ms : 1.0→0.0).
                let gate = max(0, 1.0 - (age - 250) / 250)
                // 사이클 160: degraded 상태 — 보정 일부 적용 중.
                balanceCorrectionFreshness = .degraded
                return (gate: gate, earlyReturn: nil)
            } else {
                balanceCorrectionFreshness = .normal
                return (gate: 1.0, earlyReturn: nil)
            }
        } else {
            // sim 모드 (bus 없음) — IMU 가 즉시 갱신되는 simulation 신뢰.
            balanceCorrectionFreshness = .normal
            return (gate: 1.0, earlyReturn: nil)
        }
    }

    /// blocked early return 시 state 초기화 (lastCorrections / lastRawCandidate /
    /// lastCorrectionApplied / lastSafePose). bus+IMU 없음 / 500ms 이상 stale 공통.
    private func bcResetStateForBlockedReturn(pose: RobotPose) {
        lastCorrections = nil
        lastRawCandidate = nil
        lastCorrectionApplied = false
        lastSafePose = pose
    }

    // MARK: - Phase 3: Input Convention Normalization

    /// **v1.11.3 (2026-05-18) — P1.1 부호 정규화 (opt-in)** + **사이클 161 (P0-4)**.
    /// GPT 검증 (2026-05-18) 권고: `imuFilter.pitchDeg` 자체는 건드리지 않고 corrector
    /// 입력에서 명시적 정규화 → blast radius 최소 (UI 게이지·fall predictor·safety
    /// state 등 IMU 소비자 영향 X). default `.imuRaw` 이면 변경 없음.
    ///
    /// 사이클 161 (P0-4, gyro closed-loop review fix): roll 정규화 도입.
    /// 종전: raw 만 사용 — 실 robot 의 roll 부호가 ROBOTIS Walking.cpp 코드 컨벤션 과
    /// 다르면 보정 방향 반대. 사용자가 정적 캘리브레이션 후 토글 가능.
    private func bcNormalizedImuAngles(config: BalanceExperimentConfig) -> (roll: Double, pitch: Double) {
        let pitchDeg: Double
        switch config.pitchInputConvention {
        case .imuRaw: pitchDeg = imuPitchDeg
        case .negateForwardIsNegative: pitchDeg = -imuPitchDeg
        }
        let rollDeg: Double
        switch config.rollInputConvention {
        case .imuRaw: rollDeg = imuRollDeg
        case .negateLeftIsNegative: rollDeg = -imuRollDeg
        }
        return (roll: rollDeg, pitch: pitchDeg)
    }

    // MARK: - Phase 4: Algorithm Off / Legacy Toggle

    /// Mode `.off` 또는 `enableBalanceCorrection == false` → identity (corrections 비움, log 도 0).
    /// **Codex 2nd review MEDIUM-A fix**: stale candidate 방지 (lastRawCandidate = nil).
    /// - Returns: identity 반환 발동 시 pose 그대로. 미발동 시 nil (다음 phase 로 진행).
    private func bcHandleAlgorithmOff(config: BalanceExperimentConfig, pose: RobotPose) -> RobotPose? {
        if config.algorithmMode == .off {
            bcResetStateForIdentityReturn(pose: pose)
            return pose
        }
        // Legacy toggle 차단 (UI 의 enableBalanceCorrection 와 호환).
        if !enableBalanceCorrection {
            bcResetStateForIdentityReturn(pose: pose)
            return pose
        }
        return nil
    }

    /// identity return (algorithmMode .off / legacy toggle off) 시 state 초기화.
    private func bcResetStateForIdentityReturn(pose: RobotPose) {
        lastCorrections = nil
        lastRawCandidate = nil
        lastSafePose = pose
        lastCorrectionApplied = false
    }

    // MARK: - Phase 5: Ramp + Apply Intent

    /// `correctionEnabledAt` 시작 시각 기록 + 1초 ramp-in 계산 + applyToRobot 의도 산출.
    /// observeOnly 또는 applyToRobot=false → corrections 계산만, pose 적용 X.
    private func bcSetupRampAndIntent(
        now: Date,
        config: BalanceExperimentConfig
    ) -> (ramp: Double, shouldApplyToPose: Bool) {
        let startedAt = correctionEnabledAt ?? now
        if correctionEnabledAt == nil { correctionEnabledAt = startedAt }
        let ramp = max(0, min(1, now.timeIntervalSince(startedAt)))
        let shouldApplyToPose = config.applyToRobot && config.algorithmMode != .observeOnly
        return (ramp: ramp, shouldApplyToPose: shouldApplyToPose)
    }

    // MARK: - Phase 6: Hybrid B+A Path

    /// Hybrid B+A 또는 observeOnly + hybrid corrector 경로.
    ///
    /// **v1.11 phase fix (사용자 prompt + 5 agent 검증)**:
    /// 종전: sessionStartedAt 기준 elapsed → walking cycle phase 와 무관.
    /// 신규: cycleStartedAt 기준 + truncatingRemainder(periodMs) → cycle 안 phase.
    /// periodMs: currentWalkTuning() nil 이면 WalkMotionLibrary.defaultTuning fallback.
    ///
    /// **Codex review (2026-05-18) HIGH-1 fix**: candidate vs applied 명확 분리.
    /// - lastRawCandidate = corrector 가 계산한 **raw** corrections (ramp 적용 전)
    ///   → handoff §4 의 `candidateDeltas` 정확한 의미.
    /// - lastCorrections = ramp 적용 후 (legacy 호환, UI 표시 + applied 후보).
    /// - v1.11.1 HIGH-3: freshnessGate (200-500ms stale 감쇠) 적용 → ramp 곱.
    ///
    /// **사이클 168 (P1-2, gyro closed-loop review #3.2 명시)**:
    /// effectiveScale = ramp × freshnessGate — **곱 의미 명시**:
    ///   - ramp (0..1, 1초 ramp-in): corrector ON 직후 안정 진입.
    ///   - freshnessGate (0..1, 250~500ms IMU age 따라 감쇠): IMU stale 시 보정 약화.
    /// 두 신호는 **독립**적으로 곱해짐 — 둘 중 하나라도 0 이면 effective 0.
    ///   - "ramp 가 진행 중이지만 IMU stale" → 보정 약화 (안전 우선).
    ///   - "IMU fresh 지만 ramp 1초 미경과" → 부드러운 ramp-in (oscillation 방지).
    ///   - "둘 다 1.0" → full corrections 적용.
    /// 우선순위 X — 곱셈은 commutative. 사용자가 효과 분리 분석 시 lastRawCandidate
    /// (corrections / no scale) 와 lastCorrections (corrections × ramp × freshnessGate)
    /// 비교.
    private func bcApplyHybridPath(
        pose: RobotPose,
        normalized: (roll: Double, pitch: Double),
        config: BalanceExperimentConfig,
        ramp: Double,
        freshnessGate: Double,
        shouldApplyToPose: Bool,
        now: Date
    ) -> RobotPose {
        let periodMs = effectiveWalkPeriodMs()
        let elapsedMs: Double
        if let cycleStart = cycleStartedAt, current != .idle, periodMs > 0 {
            let total = Date().timeIntervalSince(cycleStart) * 1000.0
            elapsedMs = total.truncatingRemainder(dividingBy: periodMs)
        } else {
            elapsedMs = 0
        }

        // **v1.11.3 P1.1**: normalizedImuPitchDeg 사용 (default `.imuRaw` 면 imuPitchDeg 그대로).
        let result = balanceCorrector.hybridCorrections(
            imuRollDeg: normalized.roll,
            imuPitchDeg: normalized.pitch,
            elapsedMs: elapsedMs,
            periodMs: periodMs,
            state: &hybridBalanceState,
            now: now,
            signConvention: config.signConvention
        )
        lastRawCandidate = result.corrections
        let effectiveScale = ramp * freshnessGate
        let rampedCorr = Self.scaleCorrections(result.corrections, by: effectiveScale)
        lastCorrections = rampedCorr
        // hybrid input for UI logging (correctorFilteredRoll/Pitch reuse).
        correctorFilteredRoll = result.effectiveRollErr
        correctorFilteredPitch = result.effectivePitchErr
        // v1.11 logging fields
        lastHybridResult = result
        lastWalkCycleElapsedMs = elapsedMs
        lastWalkPeriodMs = periodMs

        if !shouldApplyToPose {
            // observeOnly 또는 applyToRobot=false → pose 그대로.
            lastCorrectionApplied = false
            return pose
        }
        let corrected = Self.applyCorrections(rampedCorr, to: pose)
        lastSafePose = corrected
        lastCorrectionApplied = true
        return corrected
    }

    // MARK: - Phase 7: P-Control Path

    /// P-control 경로 (algorithmMode `.robotisPControl` 또는 observeOnly + P-control corrector).
    /// Legacy v1.9.1 LPF + deadband.
    ///
    /// **Codex review (2026-05-18) HIGH-1 fix + v1.11.1 HIGH-3 freshness gate**.
    /// P-control 경로의 raw candidate = ramp 적용 전 corrections (effRoll/effPitch 그대로).
    ///
    /// **Codex review MEDIUM-4 fix**: P-control 경로도 walkPhase01 채움 (hybrid 와 동일).
    private func bcApplyPControlPath(
        pose: RobotPose,
        normalized: (roll: Double, pitch: Double),
        config: BalanceExperimentConfig,
        ramp: Double,
        freshnessGate: Double,
        shouldApplyToPose: Bool
    ) -> RobotPose {
        let isWalkingActive = (current != .idle)
        let deadband: Double = isWalkingActive ? 2.5 : 1.0
        let alpha = 0.5
        // **v1.11.3 P1.1**: normalized 입력 (default `.imuRaw` 면 imuRollDeg/imuPitchDeg 그대로).
        correctorFilteredRoll = alpha * normalized.roll + (1 - alpha) * correctorFilteredRoll
        correctorFilteredPitch = alpha * normalized.pitch + (1 - alpha) * correctorFilteredPitch
        let effRoll = abs(correctorFilteredRoll) > deadband
            ? correctorFilteredRoll - copysign(deadband, correctorFilteredRoll)
            : 0.0
        let effPitch = abs(correctorFilteredPitch) > deadband
            ? correctorFilteredPitch - copysign(deadband, correctorFilteredPitch)
            : 0.0

        let rawCorr = balanceCorrector.corrections(
            rollErrDeg: effRoll,
            pitchErrDeg: effPitch,
            signConvention: config.signConvention
        )
        lastRawCandidate = rawCorr
        let effectiveScale = ramp * freshnessGate
        let rampedCorr = balanceCorrector.corrections(
            rollErrDeg: effRoll * effectiveScale,
            pitchErrDeg: effPitch * effectiveScale,
            signConvention: config.signConvention
        )
        lastCorrections = rampedCorr
        lastHybridResult = nil
        let periodMsLog = effectiveWalkPeriodMs()
        if let cycleStart = cycleStartedAt, current != .idle, periodMsLog > 0 {
            let total = Date().timeIntervalSince(cycleStart) * 1000.0
            lastWalkCycleElapsedMs = total.truncatingRemainder(dividingBy: periodMsLog)
            lastWalkPeriodMs = periodMsLog
        } else {
            lastWalkCycleElapsedMs = nil
            lastWalkPeriodMs = nil
        }

        if !shouldApplyToPose {
            // observeOnly 또는 applyToRobot=false → pose 그대로.
            lastCorrectionApplied = false
            return pose
        }
        let corrected = balanceCorrector.apply(
            to: pose,
            rollErrDeg: effRoll,
            pitchErrDeg: effPitch,
            enabled: true,
            // v1.11.1 HIGH-3: freshnessGate 가 secondsSinceEnable 에 곱해져 corrections 감쇠.
            // apply() 가 ramp 0..1 로 clamp → effectiveScale 도 안전.
            secondsSinceEnable: ramp * freshnessGate,
            signConvention: config.signConvention
        )
        lastSafePose = corrected
        lastCorrectionApplied = true
        return corrected
    }

    /// Corrections 를 ramp factor 로 scale.
    /// **v1.22.0 사이클 100 (Phase 5)**: `private static` → `internal static` — extension
    /// 의 `applyBalanceCorrectionIfEnabled` 가 file-level 분리됐기 때문에 file-private 불가.
    static func scaleCorrections(_ c: BalanceCorrector.Corrections, by k: Double) -> BalanceCorrector.Corrections {
        BalanceCorrector.Corrections(
            rHipRoll: c.rHipRoll * k, lHipRoll: c.lHipRoll * k,
            rKnee: c.rKnee * k,       lKnee: c.lKnee * k,
            rAnklePitch: c.rAnklePitch * k, lAnklePitch: c.lAnklePitch * k,
            rAnkleRoll: c.rAnkleRoll * k,   lAnkleRoll: c.lAnkleRoll * k
        )
    }

    /// Corrections deg delta 를 pose 의 각 joint raw 에 적용.
    /// **v1.22.0 사이클 100 (Phase 5)**: `private static` → `internal static`.
    /// **v1.22.X 사이클 115 (P0-3)**: Golden Principle #1 — `var dict` mutation 제거,
    /// `reduce(into:)` 로 새 dict 생성. 동작 불변 (byte-identical) — `pose.positions` 키
    /// 집합 보존 (corrections-only 키 추가 안 함), `abs(delta) > 1e-6` 게이트 동일.
    static func applyCorrections(_ c: BalanceCorrector.Corrections, to pose: RobotPose) -> RobotPose {
        let deltas: [JointID: Double] = [
            .rHipRoll: c.rHipRoll, .lHipRoll: c.lHipRoll,
            .rKnee: c.rKnee, .lKnee: c.lKnee,
            .rAnklePitch: c.rAnklePitch, .lAnklePitch: c.lAnklePitch,
            .rAnkleRoll: c.rAnkleRoll, .lAnkleRoll: c.lAnkleRoll
        ]
        let updated = pose.positions.reduce(into: [JointID: Int]()) { acc, entry in
            let (jid, base) = entry
            guard let delta = deltas[jid], abs(delta) > 1e-6 else {
                acc[jid] = base
                return
            }
            let baseDeg = Kinematics.degrees(fromRaw: base)
            acc[jid] = Kinematics.raw(fromDegrees: baseDeg + delta)
        }
        return RobotPose(positions: updated)
    }
}
