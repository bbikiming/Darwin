import Foundation
import ForgeCore

/// **v1.22.x (2026-05-23) — 사이클 115: god function Phase 11 분할 (StartCycle)**.
///
/// `WalkLabSession.swift:1469` 의 `startWalkCycle(_:)` (468 line) 을 phase-named
/// private helper 들로 분해. 원본은 facade 로 단순화 — 호출 site 변경 0.
///
/// # 비유
///
/// 비행기 이륙 절차서 — 각 phase 는 체크리스트의 한 페이지. 페이지를 넘기다
/// "이상 발견" 시 즉시 ABORT (return false). 모든 페이지 통과해야 이륙
/// (Task.detached spawn).
///
/// # 분할 정책
///
/// - **logic 보존 100%**: 분해는 refactor only. 변수 capture 순서 / side effect 순서 /
///   early return 패턴 / Harness telemetry 발행 위치 모두 원본 그대로 유지.
/// - **helper prefix `swc` (startWalkCycle)**: namespace 충돌 방지.
/// - **`@MainActor` 격리**: 본 extension 의 모든 helper 는 `WalkLabSession` 의 actor
///   격리를 상속. closure capture (`[weak self]`) 패턴 보존.
///
/// # Phase 매핑 (원본 line 번호 기준)
///
/// | Helper                          | Phase                                        | 원본 lines  |
/// |---------------------------------|----------------------------------------------|-------------|
/// | `swcGuardAlreadyWalking`        | 1. 다중 진입 차단                            | 1470-1480   |
/// | `swcResolveStoreAndCradle`      | 2a. connection + cradle guard                | 1482-1507   |
/// | `swcApplySafetyDemotion`        | 2b. safetyVerdict.blocked → applyToRobot=off | 1509-1532   |
/// | `swcGuardCautionPreset`         | 2c. caution preset + balanceCorrector 강제   | 1534-1550   |
/// | `swcGuardHardwarePreflight`     | 2d. dxl_power + 토크 + IMU plausibility      | 1552-1610   |
/// | `swcHandleIdlePresetIfNeeded`   | 3. idle preset 정적 anchor + return          | 1612-1634   |
/// | `swcRunOnboardCycleIfNeeded`    | 4. ROBOTIS Onboard 분기 + return             | 1636-1707   |
/// | `swcApplyAutoTuningLevel`       | 5a. autoTuner level → correctorIntensityLevel | 1709-1734  |
/// | `swcInitSessionLogger`          | 5b. WalkSessionLogger init                   | 1736-1786   |
/// | `swcMakePoseCallbacks`          | 6. onPose / transformPose closure 생성       | 1788-1804   |
/// | `swcSpawnContinuousWalkTask`    | 7. continuousWalkPlan 경로 Task.detached     | 1806-1872   |
/// | `swcSpawnJogCycleTask`          | 8. jog (kick chain) Task.detached            | 1874-1936   |
///
/// # 회귀
///
/// 사이클 114 기준 1811 tests 회귀 0 유지 — 외부 API 변경 0.
extension WalkLabSession {

    // MARK: - Phase 1 — 다중 진입 차단

    /// 이미 보행 중이면 차단 + telemetry. `true` 반환 시 caller 가 즉시 return.
    ///
    /// **순서**: walkCycleTask != nil 또는 onboardWalkingActive 중 하나라도 truthy →
    /// lastRobotEvent + Harness.walkLabStartBlocked (reason=alreadyWalking).
    internal func swcGuardAlreadyWalking(_ preset: WalkLabPreset) -> Bool {
        if walkCycleTask != nil || onboardWalkingActive {
            lastRobotEvent = "⚠️ 보행 진행 중 — 정지(■) 후 다시 시도하세요 (\(preset.label))"
            // v1.12.2 (Codex P1-5) — 실 cycle 시작 거부도 telemetry.
            harness.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable("alreadyWalking")]
            )
            return true
        }
        return false
    }

    // MARK: - Phase 2a — connection + cradle guard

    /// store + bus + cradle 검증. 통과 시 `(store, bus)` tuple 반환, 실패 시 nil +
    /// failure 기록. caller 가 nil 받으면 즉시 return.
    ///
    /// **순서 보존**: store/bus guard → cradle guard. 각 guard 별 별도 telemetry
    /// (noConnectionRace vs cradleNotConfirmedRace) 발행 + lastPreflightFailure /
    /// startBlockedReason / lastRobotEvent 업데이트 순서 원본 동일.
    internal func swcResolveStoreAndCradle(_ preset: WalkLabPreset) -> (ConnectionStore, any BusInterface)? {
        guard let store = store, let bus = store.bus else {
            // **codex HIGH fix (2026-06-02) — 정직성**: 온보드(SSH) 모드는 bus 가 *원래* 없다
            // (로봇 demo 가 ttyUSB0 점유, 공식 보행). 보행 명령은 `current`(Phase 6b 에서 설정)
            // 를 WalkLabOnboardBridge 가 x/y/a 로 송출해 실제로 걷는다 — 이 Mac-키프레임 cycle 은
            // 생략이 맞다. 종전엔 그걸 "🛑 시뮬레이션만 — 로봇 미연결" 로 거짓 표시했다(연결+보행
            // 중인데). 온보드면 정보성 메시지 + start_blocked 미발행(차단 아님 — 경로가 다를 뿐).
            let onboard = (walkingEngine == .robotisOnboard)
            if onboard {
                lastRobotEvent = "ℹ️ 온보드(SSH) — \(preset.label): 로봇 demo 공식 보행으로 송출(브리지). Mac 키프레임 cycle 생략."
                return nil
            }
            let f = WalkPreflightFailure(cause: .noConnection)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = "🛑 시뮬레이션만 — 로봇 미연결. \(preset.label) 보행 신호는 송출 안 됨. 사이드바에서 연결 후 재시도"
            // v1.12.2 (Codex P1-5) — quickPreflight 통과 후라도 race 로 bus 가 사라진
            // 시점 추적용. 사용자가 "preflight 통과인데 왜 모터 안 움직이지?" 답 가능.
            harness.record(
                .walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable("noConnectionRace")]
            )
            return nil
        }
        guard cradleConfirmed else {
            let f = WalkPreflightFailure(cause: .cradleNotConfirmed)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            harness.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable("cradleNotConfirmedRace")]
            )
            return nil
        }
        return (store, bus)
    }

    // MARK: - Phase 2b — safetyVerdict.blocked 강등

    /// safetyVerdict 가 `.blocked` + applyToRobot=true 면 `applyToRobot=false` 로
    /// 강등 (logic side effect만 — return 안 함, 보행 계속).
    ///
    /// **이유**: didSet 우회 경로 (test fixture, 직렬화 복원) 로 위험 config 가 살아남는
    /// 케이스 차단. 보행 자체는 진행 (사용자 의도 보존) — robot 송출만 차단.
    ///
    /// **v1.11.5.2 (Codex Med #4 fix)**: pitchInputConvention 보존 (생성자 5번째 인자).
    internal func swcApplySafetyDemotion() {
        if case .blocked(let reason) = balanceExperimentConfig.safetyVerdict,
           balanceExperimentConfig.applyToRobot {
            logSafetyEvent(
                kind: .correctorOff,
                message: "보행 시작 시 안전 차단: \(reason)"
            )
            // **v1.11.5.2 (2026-05-18, Codex Med #4 fix)**: pitchInputConvention 보존 추가.
            balanceExperimentConfig = BalanceExperimentConfig(
                algorithmMode: balanceExperimentConfig.algorithmMode,
                signConvention: balanceExperimentConfig.signConvention,
                gainProfile: balanceExperimentConfig.gainProfile,
                applyToRobot: false,
                pitchInputConvention: balanceExperimentConfig.pitchInputConvention
            )
        }
    }

    // MARK: - Phase 2c — caution preset + balanceCorrector 강제

    /// caution 등급 (fastWalk/turnLeft/turnRight) 인데 `enableBalanceCorrection=false`
    /// 면 차단. 사용자에게 명시 ON 후 재시작 강제.
    ///
    /// **이유**: 정적 plan + IMU balance 미활성 시 실 robot 낙상 위험. 사이클 90 (2026-05-17)
    /// 사용자 보고 critical fix.
    internal func swcGuardCautionPreset(_ preset: WalkLabPreset) -> Bool {
        if preset.safety == .caution, !enableBalanceCorrection {
            let f = WalkPreflightFailure(cause: .balanceCorrectorRequiredForCautionPreset(presetLabel: preset.label))
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = f.userMessage
            // v1.12.2 (Codex re-review fix) — start_blocked 발행.
            harness.record(
                .walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode)]
            )
            return true
        }
        return false
    }

    // MARK: - Phase 2d — hardware preflight + IMU plausibility

    /// dxl_power ON + 모든 관절 토크 ON + IMU live / fresh / plausible.
    /// 모두 통과 시 lastPreflightFailure/startBlockedReason `nil` clear.
    ///
    /// **순서 보존**:
    /// 1. `preflightForWalkCycle(bus:)` — dxl_power + 토크
    /// 2. `store.isImuUnavailable` — IMU sample 0
    /// 3. `store.isImuStale` — 5s+ 지연
    /// 4. `imuScaleSuspicion ∈ {suspectedLegacy10Bit, outOfRange}` — 1g 감지 실패
    /// 5. (모두 통과) → state clear
    internal func swcGuardHardwarePreflight(_ preset: WalkLabPreset, store: ConnectionStore, bus: any BusInterface) -> Bool {
        // Preflight — dxl_power ON + 모든 토크 ON. 하체 1개라도 실패면 차단.
        if let failure = preflightForWalkCycle(bus: bus) {
            lastPreflightFailure = failure
            startBlockedReason = failure.diagnosticCode  // v1.11.24 audit iter2-D
            lastRobotEvent = failure.userMessage + " (\(preset.label))"
            harness.record(
                .walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(failure.diagnosticCode)]
            )
            return true
        }
        // V283-4: preflight 성공 = dxlPower ON 확정 → gate 상태 동기화.
        store._setDxlPowerState(true)

        // **v1.11.22.1 (Codex HIGH-2 fix)** — 실 robot 보행 시작 전 IMU live + plausible:
        //   - bus 있는데 IMU 한 번도 안 옴 → 차단 (gate L3/corrector 모두 무력화 위험)
        //   - IMU stale (5s+ 지연) → 차단
        //   - imuScaleSuspicion suspectedLegacy10Bit/outOfRange → 차단 (1g 감지 실패)
        // 정상 보행 시 fall prevention chain (L3 hard gate, corrector) 의 데이터 의존성
        // 확보. 정합 안 되면 실 robot 송출 자체 금지.
        if store.isImuUnavailable {
            let f = WalkPreflightFailure(cause: .imuUnavailable)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            logSafetyEvent(kind: .preflightFailure,
                           message: "보행 차단 — IMU unavailable (bus 연결 후 sample 없음)")
            harness.record(.walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode)])
            return true
        }
        if store.isImuStale {
            let f = WalkPreflightFailure(cause: .imuStale)
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            logSafetyEvent(kind: .preflightFailure,
                           message: "보행 차단 — IMU stale (5초+ 지연)")
            harness.record(.walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode)])
            return true
        }
        if store.imuScaleSuspicion == .suspectedLegacy10Bit
            || store.imuScaleSuspicion == .outOfRange {
            let f = WalkPreflightFailure(cause: .imuPlausibilityFailed(store.imuScaleSuspicion.rawValue))
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            logSafetyEvent(kind: .preflightFailure,
                           message: "보행 차단 — IMU plausibility \(store.imuScaleSuspicion.rawValue)")
            harness.record(.walkLabStartBlocked, level: .warn, actor: .system,
                data: ["requested_preset": AnyCodable(preset.label),
                       "reason": AnyCodable(f.diagnosticCode),
                       "imu_scale": AnyCodable(store.imuScaleSuspicion.rawValue)])
            return true
        }
        lastPreflightFailure = nil
        startBlockedReason = nil
        return false
    }

    // MARK: - Phase 3 — idle preset 정적 anchor

    /// preset == .idle 면 walkReady 자세 송출 후 `true` 반환 (caller return).
    /// 외 preset 은 `false` 반환 (caller 계속 진행).
    ///
    /// **이유**: idle 은 정지/대기 — 보행 cycle 시작 안 함. walkLabStart 발행도 안 함.
    internal func swcHandleIdlePresetIfNeeded(_ preset: WalkLabPreset) -> Bool {
        if preset == .idle {
            sendRobotPose(.walkReady, eventLabel: "보행 anchor — \(preset.label)")
            // idle 은 static anchor — walking 이벤트 발행 안 함 (사용자는 정지/대기로 인식).
            return true
        }
        return false
    }

    // MARK: - Phase 4 — ROBOTIS Onboard 분기

    /// `walkingEngine == .robotisOnboard` 면 onboard lifecycle 실행 후 `true` 반환.
    /// 외 engine 은 `false` 반환 (caller 가 Mac sparse keyframe 경로 진행).
    ///
    /// **lifecycle 순서 보존** (v1.11.7 GPT HIGH-2):
    /// 1. SSH 연결 + autoOnboardBrokering precheck (실패 → 차단 + return true)
    /// 2. walkLabStart telemetry
    /// 3. onboardWalkingActive=true
    /// 4. imuFastPollActive=true (사이클 159 P0-1)
    /// 5. activeRobotPreset / motorWrite counters / onboardAckStatus 초기화
    /// 6. cycleStartedAt 갱신
    /// 7. safety event + lastRobotEvent
    internal func swcRunOnboardCycleIfNeeded(_ preset: WalkLabPreset, store: ConnectionStore) -> Bool {
        guard walkingEngine == .robotisOnboard else { return false }

        let presetLabel = preset.label
        // **v1.11.24 (2026-05-20) audit P1-3 — health-check 를 hard block 으로 강화**:
        //
        // 종전: warning 만 — `onboardWalkingActive=true` 를 무조건 set → 사용자는 UI 상
        //       "active" 로 보지만 robot 은 가만히 있음 (silent fail).
        // 현재: SSH 미연결 또는 autoOnboardBrokering=false 면 명시적으로 차단 + 사유 표시.
        //       사용자가 SSH 연결 / 토글 ON 후 재시도 강제.
        //
        // (실제 ACK 검증은 첫 명령 송출 후 WalkLabOnboardBridge 가 onboardAckStatus 에
        //  결과 기록 — 본 시점에는 precondition 만 검사.)
        // 이 시점에서 store 는 위쪽 guard let 로 이미 unwrap. bus != nil 도 보장.
        // (실 environment 에서는 noConnection branch 가 이미 차단)
        let isSshConnected = (store.bus != nil)
        if !isSshConnected {
            let f = WalkPreflightFailure(cause: .onboardSshNotConnected)
            lastPreflightFailure = f
            lastRobotEvent = f.userMessage + " (\(presetLabel))"
            startBlockedReason = f.diagnosticCode
            logSafetyEvent(kind: .preflightFailure,
                           message: "Onboard 시작 차단 — SSH 미연결")
            harness.record(.walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(presetLabel),
                       "reason": AnyCodable(f.diagnosticCode)])
            return true
        }
        if !autoOnboardBrokering {
            let f = WalkPreflightFailure(cause: .onboardAutoBrokeringOff)
            lastPreflightFailure = f
            lastRobotEvent = f.userMessage + " (\(presetLabel))"
            startBlockedReason = f.diagnosticCode
            logSafetyEvent(kind: .preflightFailure,
                           message: "Onboard 시작 차단 — autoOnboardBrokering OFF")
            harness.record(.walkLabStartBlocked, level: .warn, actor: .user,
                data: ["requested_preset": AnyCodable(presetLabel),
                       "reason": AnyCodable(f.diagnosticCode)])
            return true
        }
        // precheck 통과 — onboard cycle 활성. ACK 는 bridge 가 별도 trace.
        // v1.12.2 (Codex re-review fix) — onboard 도 실제 cycle 시작 시점에 발행.
        harness.record(
            .walkLabStart, level: .notice, actor: .user,
            data: ["preset": AnyCodable(presetLabel),
                   "engine": AnyCodable("robotisOnboard"),
                   "advanced": AnyCodable(advanced)]
        )
        onboardWalkingActive = true
        // 사이클 159 (P0-1 fix): onboard mode 도 IMU fast polling — robot 측 보정 외에도
        // Mac UI 의 LiveGyroPanel / FallPredictor 가 빠르게 반응. 단 Mac 보정은 미적용.
        store.imuFastPollActive = true
        activeRobotPreset = preset
        motorWriteStarted = false        // bridge 가 ACK ok 도착 시 set
        motorWriteStepCount = 0
        onboardAckStatus = "pending"     // ACK 도착하면 "ok" / "no_ack" 갱신
        cycleStartedAt = Date()
        logSafetyEvent(
            kind: .correctorOn,
            message: "ROBOTIS Onboard 시작: \(presetLabel) (Mac sparse 우회). brokering 자동"
        )
        lastRobotEvent = "▶ ROBOTIS Onboard: \(presetLabel) — Mac sparse 우회, 자동 brokering 활성"
        return true
    }

    // MARK: - Phase 5a — autoTuner level 적용

    /// autoTuner 권고 level 자동 적용 (autoApplyEnabled 시). 단 `correctionApplyMode ==
    /// "robotApplied"` 면 실 모터 송출 안전을 위해 자동 적용 차단 + 현재 강도 유지.
    ///
    /// **v1.11.1 HIGH-2**: WalkSessionAnalyzer 의 데이터 품질 검증이 v2 quality analyzer
    /// 수준에 도달 전 (IMU duplicate ratio / stale ratio / 독립 sample 수 정밀 미검증)
    /// — observeOnly / simOnly / off 모드에서만 안전 자동 적용.
    internal func swcApplyAutoTuningLevel() {
        let appliedLevel: Int
        if correctionApplyMode == "robotApplied" && autoTuner.autoApplyEnabled {
            appliedLevel = correctorIntensityLevel
            logSafetyEvent(
                kind: .correctorOn,
                message: "자동 튜닝 차단: 실 robot 적용 모드 — 수동 강도 유지 (\(Self.intensityLabel(level: correctorIntensityLevel)))"
            )
        } else {
            appliedLevel = autoTuner.levelToApply(currentLevel: correctorIntensityLevel)
        }
        if appliedLevel != correctorIntensityLevel {
            correctorIntensityLevel = appliedLevel
            lastRobotEvent = "🧠 자동 튜닝: 보정 강도 \(WalkLabSession.intensityLabel(level: appliedLevel)) 적용"
        }
    }

    // MARK: - Phase 5a' — autoTuner 안정성 파라미터 적용 (데이터 기반 자동 튜닝 2026-05-30)

    /// autoTuner 의 안정성 권고(tau/D항) 자동 적용. **swcApplyAutoTuningLevel 과 동일 안전
    /// 정책**: `correctionApplyMode == "robotApplied"` (실 모터 송출) 면 자동 적용 차단 —
    /// 안정성 파라미터는 미관측 변경 위험이 크므로 **승인 게이트(ExperimentApproval) 경유만**
    /// 허용. SIM/observeOnly/off 모드에서만 자동 적용 (analyzer 가 이미 단일 step 보수 권고).
    internal func swcApplyAutoTuningStability() {
        guard autoTuner.autoApplyEnabled else { return }
        if correctionApplyMode == "robotApplied" {
            if autoTuner.pendingStabilityRecommendation != nil {
                logSafetyEvent(
                    kind: .correctorOn,
                    message: "자동 튜닝(안정성) 차단: 실 robot 적용 모드 — 승인 게이트 경유만 허용"
                )
            }
            return
        }
        let applied = autoTuner.stabilityToApply(
            currentDTerm: derivativeTimeSec, currentTau: baselineTauSec
        )
        var changed = false
        if abs(applied.dTerm - derivativeTimeSec) > 1e-9 { derivativeTimeSec = applied.dTerm; changed = true }
        if abs(applied.tau - baselineTauSec) > 1e-9 { baselineTauSec = applied.tau; changed = true }
        if changed {
            lastRobotEvent = String(
                format: "🧠 자동 튜닝(SIM): D항 %.2f·baseline %.1fs 적용", derivativeTimeSec, baselineTauSec
            )
        }
    }

    // MARK: - Phase 5b — WalkSessionLogger init

    /// `enableSessionLogging=true` 일 때 WalkSessionLogger 생성. 실패 시 silent
    /// (보행 자체는 진행). 성공 시 `sessionStartedAt` 도 logger 와 sync.
    ///
    /// **v1.11 (Codex 2026-05-18 HIGH-2)**: handoff §3 5+3 필드를 헤더로 전달.
    /// **v1.11.10 V2**: 8 axis + tuning + experiment context 헤더.
    internal func swcInitSessionLogger(_ preset: WalkLabPreset) {
        guard enableSessionLogging else { return }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        do {
            // **v1.11 (Codex 2026-05-18 HIGH-2)**: handoff §3 5+3 필드를 헤더로 전달.
            sessionLogger = try WalkSessionLogger(
                preset: preset.rawValue,
                intensityLevel: correctorIntensityLevel,
                appVersion: appVersion,
                isRealRobot: true,  // startWalkCycle 안에서는 이미 bus guard 통과.
                balanceAlgorithmMode: balanceAlgorithmMode,
                balanceSignConvention: balanceSignConvention,
                balanceGainProfile: balanceGainProfile,
                correctionApplyMode: correctionApplyMode,
                imuSourceAtStart: imuSourceAtStart,
                imuScaleSuspicionAtStart: imuScaleSuspicionAtStart,
                operatorNoteAtStart: operatorNote,
                comparisonTag: comparisonTag,
                // v1.11.10 V2 — 8 axis + tuning + experiment context
                walkingEngine: walkingEngine.rawValue,
                pitchInputConvention: balanceExperimentConfig.pitchInputConvention.rawValue,
                enableBalanceCorrectionAtStart: enableBalanceCorrection,
                autoOnboardBrokeringAtStart: autoOnboardBrokering,
                hipPitchOffsetTrimDegAtStart: hipPitchOffsetTrimDeg,
                tuningStrideMm: advanced ? strideMm : nil,
                tuningSideMm: advanced ? sideMm : nil,
                tuningTurnDeg: advanced ? turnDeg : nil,
                tuningPeriodMs: advanced ? customPeriodMs : nil,
                tuningFootHeightMm: advanced ? footHeightMm : nil,
                tuningBalanceGain: advanced ? balanceGain : nil,
                customGainHipRoll: balanceExperimentConfig.gainProfile == .custom ? customHipRollGain : nil,
                customGainKnee: balanceExperimentConfig.gainProfile == .custom ? customKneeGain : nil,
                customGainAnklePitch: balanceExperimentConfig.gainProfile == .custom ? customAnklePitchGain : nil,
                customGainAnkleRoll: balanceExperimentConfig.gainProfile == .custom ? customAnkleRollGain : nil,
                robotModel: "DARwIn-OP2",
                // v1.11.14: 실험 컨텍스트 — applyExperimentChange 후 활성.
                experimentId: activeExperimentId,
                baselineSessionId: activeBaselineSessionId,
                // v1.11.24 audit P1-2 — start diagnostic snapshot.
                requestedPreset: requestedPreset?.rawValue,
                startBlockedReason: startBlockedReason,
                walkCycleTaskActiveAtStart: walkCycleTask != nil,
                lastRobotEventAtStart: lastRobotEvent
            )
            // v1.9.2: Logger 의 startedAt 과 sync — summary.id 와 jsonl filename
            // 일치 보장. 종전: 별도 Date() → 3ms drift → matching 실패.
            sessionStartedAt = sessionLogger?.startedAt
        } catch {
            // logging 실패 시 silent (보행 자체는 진행).
            sessionLogger = nil
        }
    }

    // MARK: - Phase 6 — onPose / transformPose closure 생성

    /// Phase G11 — 3D 모델 동기화 + balance corrector wire 용 closure 두 개를
    /// 한꺼번에 반환. `weak self` 로 retain cycle 회피.
    ///
    /// **onPose**: visualPose 갱신 + motorWrite counter 증가 (사이클 P1-2 — 첫 호출
    /// 시 motorWriteStarted=true, 이후 step count 누적). preflight 통과했지만 실 write 가
    /// 0 인 케이스 (예: bus 즉시 끊김) 사후 진단 가능.
    ///
    /// **transformPose**: Stage 4b — `enableBalanceCorrection=true` 시 매 step pose 에
    /// IMU 기반 보정 적용. default false (사용자 토글 ON 후 활성).
    internal func swcMakePoseCallbacks() -> (
        onPose: @MainActor @Sendable (RobotPose) -> Void,
        transformPose: @MainActor @Sendable (RobotPose) -> RobotPose
    ) {
        // Phase G11 — 3D 모델 동기화 closure. weak self 로 retain cycle 회피.
        // v1.11.24 audit P1-2 — motor write counter. 첫 호출 시 motorWriteStarted=true,
        // 이후 호출마다 step count 증가. preflight 통과했지만 실 write 가 0 인 케이스
        // (예: bus 즉시 끊김) 를 사후 진단 가능.
        let onPose: @MainActor @Sendable (RobotPose) -> Void = { [weak self] pose in
            guard let self else { return }
            self.visualPose = pose
            if !self.motorWriteStarted { self.motorWriteStarted = true }
            self.motorWriteStepCount &+= 1
        }

        // **Stage 4b (v1.1 fall prevention)**: 실 motor 송출 경로에 corrector wire.
        // `enableBalanceCorrection = true` 시 매 step pose 에 IMU 기반 보정 적용.
        // default false (사용자 토글 ON 후 활성).
        let transformPose: @MainActor @Sendable (RobotPose) -> RobotPose = { [weak self] pose in
            self?.applyBalanceCorrectionIfEnabled(to: pose) ?? pose
        }

        return (onPose, transformPose)
    }

    // MARK: - Phase 7 — continuousWalkPlan 경로 Task.detached spawn

    /// 연속 보행 plan 가능한 preset (march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight)
    /// 면 Task.detached 로 spawn 후 `true` 반환. 아니면 `false` (caller 가 jog 경로).
    ///
    /// **순서 보존**:
    /// 1. plan 생성 (없으면 false → caller 가 jog 경로 fallback)
    /// 2. isRobotWalking=true / imuFastPollActive=true / activeRobotPreset 갱신
    /// 3. motorWriteStarted=false / motorWriteStepCount=0 reset
    /// 4. lastRobotEvent / walkLabStart telemetry
    /// 5. Task.detached spawn — 내부에서 prev?.value await → runContinuousWalk →
    ///    MainActor.run finalize
    internal func swcSpawnContinuousWalkTask(
        _ preset: WalkLabPreset,
        bus: any BusInterface,
        store: ConnectionStore,
        prev: Task<Void, Never>?,
        presetLabel: String,
        maxDurationSec: Int,
        lowerBody: Set<JointID>,
        onPose: @escaping @MainActor @Sendable (RobotPose) -> Void,
        transformPose: @escaping @MainActor @Sendable (RobotPose) -> RobotPose
    ) -> Bool {
        let walkTuning = currentWalkTuning()
        guard let plan = WalkMotionLibrary.continuousWalkPlan(for: preset, tuning: walkTuning) else {
            return false
        }
        // **D1 (2026-06-12)**: 시간 기반 50Hz 모드 — `df.walklab.denseStreaming` 플래그.
        // denseTuning 은 키프레임 plan 과 **동일한 resolved tuning**(동치 보장).
        let denseStreaming = WalkDenseStreaming.denseStreamingEnabled()
        let denseTuning = denseStreaming
            ? WalkMotionLibrary.resolvedPresetTuning(for: preset, custom: walkTuning)
            : nil
        isRobotWalking = true
        // 사이클 159 (P0-1 fix): 실 robot 송출 path → IMU fast polling (50ms = 20Hz).
        // freshness gate (250ms) 와 4 step 마진. stop 시 finalize 에서 false 복원.
        store.imuFastPollActive = true
        // v1.11.24 audit P1-1 — 실 motor task 시작 시점에 activeRobotPreset 갱신.
        // 로거 sample.preset 은 이 값을 우선 → 보행 중 사용자가 다른 preset 클릭해도
        // 실 task 가 안 바뀌면 로그는 변경 전 preset 유지.
        activeRobotPreset = preset
        motorWriteStarted = false
        motorWriteStepCount = 0
        lastRobotEvent = "🤖 연속 보행 시작 — \(presetLabel)"
        // v1.12.2 (Codex re-review fix) — 실 motor task spawn 직전. 모든 guard pass.
        harness.record(
            .walkLabStart, level: .notice, actor: .user,
            data: ["preset": AnyCodable(presetLabel),
                   "engine": AnyCodable(String(describing: walkingEngine)),
                   "advanced": AnyCodable(advanced),
                   "mode": AnyCodable("continuous")]
        )
        // 2026-05-17 chaos #1: weak store capture — Task 내부에서 매 step 마다
        // store?.bus !== nil 확인 가능. 종전엔 bus strong capture 로 dead handle
        // 송출 ~5 step 지속.
        // v1.11.2 (2026-05-18): CI Swift 5.9 strict concurrency 호환 — outer
        // `weak store = self.store` 가 inner closure 에서 var-like 로 재캡쳐되어
        // error. `[weak self]` 만 캡쳐하고 inner 가 self?.store 통해 access.
        walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await prev?.value
            let result = await Self.runContinuousWalk(
                bus: bus, plan: plan,
                maxDurationSec: maxDurationSec,
                lowerBodyJoints: lowerBody,
                denseStreaming: denseStreaming,
                denseTuning: denseTuning,
                onPose: onPose,
                transformPose: transformPose,
                isBusAlive: { [weak self] in
                    guard let self else { return false }
                    return await self.isBusAliveSnapshot()
                },
                // v1.11.22.1 (Codex HIGH-1 fix): emergencyStop 시 exit phase 스킵.
                // C1b: recovery 진행 중에도 write 를 차단 — exitEmergencyMode() 이후에도
                // autoRecoveryPhase != .idle 이면 get-up 윈도우가 보호됨.
                isHardStopped: { [weak self] in
                    guard let self else { return true }
                    return await MainActor.run { self.emergencyStopActive || self.autoRecoveryPhase != .idle }
                },
                // v1.11.1 MEDIUM-5: bus write 실패 시 ConnectionStore counter 누적.
                onBusWriteFailure: { [weak self] in
                    self?.store?._bumpBusWriteFailureCount()
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRobotWalking = false
                // 사이클 159 (P0-1 fix): walk 종료 → IMU slow polling 복원 (perf).
                self.store?.imuFastPollActive = false
                // v1.11.24 audit P1-1 — cycle 정상/비정상 종료 시 활성 preset clear.
                self.activeRobotPreset = nil
                self.lastCycleResult = result
                if result.isSuccess {
                    self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                } else {
                    self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                }
                self.finalizeSessionLog()
            }
        }
        return true
    }

    // MARK: - Phase 8 — jog (kick chain) 경로 Task.detached spawn

    /// jog 같은 단발 page+oneShot kick chain. continuous plan 이 없을 때 fallback.
    /// page 도 없으면 walkReady anchor 만 송출 후 return.
    ///
    /// **순서 보존** (Phase 7 와 거의 동일, mode="kickChain" 표기 + loop=false):
    /// 1. page 생성 (없으면 walkReady anchor + return)
    /// 2. isRobotWalking=true / imuFastPollActive=true / activeRobotPreset 갱신
    /// 3. motorWriteStarted=false / motorWriteStepCount=0 reset
    /// 4. lastRobotEvent / walkLabStart telemetry (mode="kickChain")
    /// 5. Task.detached spawn — runWalkCycle(loop=false) → MainActor.run finalize
    internal func swcSpawnJogCycleTask(
        _ preset: WalkLabPreset,
        bus: any BusInterface,
        store: ConnectionStore,
        prev: Task<Void, Never>?,
        presetLabel: String,
        maxDurationSec: Int,
        lowerBody: Set<JointID>,
        onPose: @escaping @MainActor @Sendable (RobotPose) -> Void,
        transformPose: @escaping @MainActor @Sendable (RobotPose) -> RobotPose
    ) {
        // jog (kick chain) — 단발 page + oneShot.
        guard let page = WalkMotionLibrary.page(for: preset, tuning: currentWalkTuning()) else {
            sendRobotPose(.walkReady, eventLabel: "보행 anchor — \(presetLabel)")
            return
        }
        isRobotWalking = true
        // 사이클 159 (P0-1 fix): jog kick chain 도 IMU fast polling 활성.
        store.imuFastPollActive = true
        // v1.11.24 audit P1-1 — jog 같은 single-page cycle 도 동일.
        activeRobotPreset = preset
        motorWriteStarted = false
        motorWriteStepCount = 0
        lastRobotEvent = "🤖 보행 cycle 송출 시작 — \(presetLabel)"
        // v1.12.2 (Codex re-review fix) — single-cycle 도 실 task spawn 직전.
        harness.record(
            .walkLabStart, level: .notice, actor: .user,
            data: ["preset": AnyCodable(presetLabel),
                   "engine": AnyCodable(String(describing: walkingEngine)),
                   "advanced": AnyCodable(advanced),
                   "mode": AnyCodable("kickChain")]
        )
        // v1.11.2 (2026-05-18): CI Swift 5.9 strict concurrency 호환 (line 960 와 동일).
        walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await prev?.value
            let result = await Self.runWalkCycle(
                bus: bus, page: page,
                maxDurationSec: maxDurationSec,
                lowerBodyJoints: lowerBody,
                loop: false,   // jog 는 kick chain 끝나면 종료.
                onPose: onPose,
                transformPose: transformPose,
                isBusAlive: { [weak self] in
                    guard let self else { return false }
                    return await self.isBusAliveSnapshot()
                },
                // v1.11.22.1 (Codex HIGH-1 fix): emergencyStop 시 walkReady 복귀 스킵.
                // C1b: recovery 진행 중에도 write 를 차단 — exitEmergencyMode() 이후에도
                // autoRecoveryPhase != .idle 이면 get-up 윈도우가 보호됨.
                isHardStopped: { [weak self] in
                    guard let self else { return true }
                    return await MainActor.run { self.emergencyStopActive || self.autoRecoveryPhase != .idle }
                },
                // v1.11.1 MEDIUM-5: bus write 실패 시 ConnectionStore counter 누적.
                onBusWriteFailure: { [weak self] in
                    self?.store?._bumpBusWriteFailureCount()
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRobotWalking = false
                // 사이클 159 (P0-1 fix): jog 종료 → IMU slow polling 복원.
                self.store?.imuFastPollActive = false
                // v1.11.24 audit iter3-A — jog 단발 cycle 도 cleanup 일치.
                self.activeRobotPreset = nil
                self.lastCycleResult = result
                if result.isSuccess {
                    self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                } else {
                    self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                }
                // v1.11.24 audit iter3-A — finalize log for natural jog completion
                // (loop=false → kick chain 끝나면 외부 stop() 없어도 cycle 종료).
                self.finalizeSessionLog()
            }
        }
    }
}
