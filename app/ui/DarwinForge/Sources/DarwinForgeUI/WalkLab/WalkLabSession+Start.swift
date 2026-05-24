import Foundation
import ForgeCore

/// **v1.22.x (2026-05-23) — 사이클 115 (W2.7): god function 분할 (start)**.
///
/// `WalkLabSession.swift:1139` 의 `start(_ preset:)` (162 line) 을 phase-named
/// internal helper 들로 분해. 원본 `start(_:)` 는 facade 로 단순화 — 외부 API 변경 0,
/// 호출 site 변경 0.
///
/// # 비유
///
/// 항공기 시동 절차서 — 8 phase 체크리스트. 각 phase 는 매뉴얼의 한 페이지.
/// 페이지 1-2 (emergency / preflight) 에서 이상 발견 시 즉시 RTB. 페이지 3-8
/// 통과해야 활주로 진입 (`startWalkCycle`).
///
/// # 분할 정책
///
/// - **logic 보존 100%**: 분해는 refactor only. 변수 capture / side effect 순서 /
///   early return 패턴 / Harness telemetry 발행 위치 모두 원본 그대로 유지.
/// - **helper prefix `start` (CamelCase)**: namespace 충돌 방지 (W2.3 `swc`, W2.5 `bc`,
///   W2.6 `safetySample` 와 일관 패턴).
/// - **`@MainActor` 격리**: 본 extension 의 모든 helper 는 `WalkLabSession` 의 actor
///   격리를 상속. `Task { @MainActor [weak self] }` closure 보존.
///
/// # Phase 매핑 (원본 line 번호 기준)
///
/// | Helper                          | Phase                                     | 원본 lines  |
/// |---------------------------------|-------------------------------------------|-------------|
/// | `startGuardEmergency`           | 1. emergencyStopActive 차단               | 1163-1179   |
/// | `startCheckQuickPreflight`      | 2. quickPreflight() + telemetry           | 1181-1196   |
/// | `startLogOnboardWarnings`       | 3. onboardHealthCheckWarnings 로그        | 1210-1216   |
/// | `startSyncAdvancedSliders`      | 4. advanced && != .idle slider load       | 1221-1223   |
/// | `startCaptureImuSnapshot`       | 5. imuSourceAtStart + imuScaleSuspicion   | 1226-1233   |
/// | `startApplyPresetToEngine`      | 6. current=preset + engine setCommand     | 1238-1241   |
/// | `startResetSessionState`        | 7. foot/IMU/balance/thermal/monitor reset | 1242-1286   |
/// | `startScheduleTickLoop`         | 8. startTime + simTimer scheduledTimer    | 1287-1295   |
///
/// # 격상 (사이클 115)
///
/// - `simTimer` (private → internal): `startScheduleTickLoop()` 가 invalidate + 재할당
/// - `startTime` (private → internal): `startScheduleTickLoop()` 가 Date() 갱신
/// - `_lastEmergencyTrigger` (private → internal): `startGuardEmergency` (read),
///   `startResetSessionState` (write nil) — root emergency guard 의 trigger payload
///   생성에 사용.
///
/// # 회귀
///
/// 1848 tests 회귀 0 — 외부 API 변경 0. `startWalkCycle(preset)` 호출은 facade
/// 마지막에서 그대로 유지 (private 접근 가능).
extension WalkLabSession {

    // MARK: - Phase 1 — emergencyStopActive 차단

    /// `emergencyStopActive=true` 면 .emergencyActive cause 로 차단 + telemetry +
    /// `true` 반환. caller 가 즉시 return.
    ///
    /// **v1.21.1 사이클 66 (CRITICAL-1 fix)**: 전용 `.emergencyActive` cause 사용
    /// (종전 `.noConnection` 재사용 → 사용자 mental model corruption).
    /// **v1.21.2 사이클 67 (MEDIUM-3 fix)**: `_lastEmergencyTrigger` 도 payload 로
    /// 전달 — diagnosticCode 가 `emergencyActive_balanceLostL3` 형식으로 분류 가능.
    /// nil race (init 직후 외부에서 flag set) 는 `.unknown` fallback.
    internal func startGuardEmergency(_ preset: WalkLabPreset) -> Bool {
        guard emergencyStopActive else { return false }
        let f = WalkPreflightFailure(cause: .emergencyActive(trigger: _lastEmergencyTrigger ?? .unknown))
        lastPreflightFailure = f
        lastRobotEvent = f.userMessage
        startBlockedReason = f.diagnosticCode
        logSafetyEvent(
            kind: .preflightFailure,
            message: "start 차단 — \(f.diagnosticCode): emergency 상태에서 recovery 없이 재시작 시도"
        )
        harness.record(
            .walkLabStartBlocked, level: .warn, actor: .user,
            data: ["requested_preset": AnyCodable(preset.label),
                   "reason": AnyCodable(f.diagnosticCode),
                   "guard": AnyCodable("root_emergency_guard")]
        )
        return true
    }

    // MARK: - Phase 2 — quickPreflight 검사

    /// `quickPreflight(for:)` 실패 시 lastPreflightFailure / startBlockedReason /
    /// lastRobotEvent set + walkLabStartBlocked telemetry + `true` 반환.
    /// caller 가 즉시 return.
    ///
    /// **v1.12.2 (Codex P1-5)**: walkLabStart 발행은 startWalkCycle 진입 후로 이동
    /// (quickPreflight 만 통과한 시점에는 추가 guard 가 남아 있어 false-positive 가능).
    /// 본 단계는 walkLabStartBlocked (실패 경로) 만 발행.
    internal func startCheckQuickPreflight(_ preset: WalkLabPreset) -> Bool {
        guard let failure = quickPreflight(for: preset) else { return false }
        lastPreflightFailure = failure
        lastRobotEvent = failure.userMessage
        startBlockedReason = failure.diagnosticCode
        logSafetyEvent(
            kind: .preflightFailure,
            message: "start 차단 — \(failure.diagnosticCode): \(failure.userMessage)"
        )
        harness.record(
            .walkLabStartBlocked, level: .warn, actor: .user,
            data: ["requested_preset": AnyCodable(preset.label),
                   "reason": AnyCodable(failure.diagnosticCode),
                   "active_preset": AnyCodable(activeRobotPreset?.label ?? "none")]
        )
        return true
    }

    // MARK: - Phase 3 — onboardHealthCheckWarnings 비동기 진단 로그

    /// 비-blocking 진단 — `onboardHealthCheckWarnings()` 가 반환한 모든 warning 을
    /// preflightFailure 카테고리로 logSafetyEvent.
    ///
    /// **사이클 117 (explore agent dead-code fix)**: 사이클 97 분할 후 production
    /// 호출 site 0 이었음. preflight 통과 후 robot/cradle/autoOnboardBrokering state
    /// 가 silent failure 위험 있을 때 경고 (preflight 차단 사유와 중복 아닌 새 정보만).
    internal func startLogOnboardWarnings() {
        let onboardWarnings = onboardHealthCheckWarnings()
        for warning in onboardWarnings {
            logSafetyEvent(
                kind: .preflightFailure,
                message: "[onboard 진단] \(warning)"
            )
        }
    }

    // MARK: - Phase 4 — 고급 모드 slider 기본값 load

    /// `advanced && preset != .idle` 면 `loadPresetDefaultsToSliders(preset)` 호출.
    ///
    /// **v1.11.24 audit iter2-C**: preflight 통과 후에만 slider 동기화.
    /// 종전: tap() 가 start() 호출 전에 호출 → preflight 차단되면 slider 만 바뀌고
    /// motor task 는 안 바뀜 (UX 불일치).
    internal func startSyncAdvancedSliders(_ preset: WalkLabPreset) {
        guard advanced, preset != .idle else { return }
        loadPresetDefaultsToSliders(preset)
    }

    // MARK: - Phase 5 — IMU source / scale snapshot

    /// `imuSource` (sim/real/stale) 와 `imuScaleSuspicion` 을 start 시점 snapshot —
    /// finalize 시 v2 header 에 그대로 기록.
    ///
    /// **§3 wiring**: handoff §3 의 imuSourceAtStart / imuScaleSuspicionAtStart 필드.
    internal func startCaptureImuSnapshot() {
        imuSourceAtStart = {
            switch imuSource {
            case .sim:   return "sim"
            case .real:  return "real"
            case .stale: return "stale"
            }
        }()
        imuScaleSuspicionAtStart = (store?.imuScaleSuspicion ?? .unknown).rawValue
    }

    // MARK: - Phase 6 — preset → current + engine command 전파

    /// `current = preset` + `engine.setCommand(...)` + `engine.setPeriodMs(...)`.
    /// 외부 robot 송출이 아닌 sim engine wiring — 실 motor 송출은 별도 `startWalkCycle`
    /// path 에서 처리.
    internal func startApplyPresetToEngine(_ preset: WalkLabPreset) {
        current = preset
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)
    }

    // MARK: - Phase 7 — 세션 state 초기화

    /// 새 보행 cycle 진입 — 이전 cycle 의 stale state 전부 reset.
    ///
    /// **초기화 그룹** (원본 line 1242-1286 순서 보존):
    /// - footTrail / footTrailLefts / simSwayPhase (sim 시뮬)
    /// - balanceLost / thermalAlarm / emergencyStopActive / _lastEmergencyTrigger
    /// - warningStateConsecutiveSamples / dangerStateConsecutiveSamples /
    ///   l3HardGateConsecutiveSamples (v1.8 hysteresis)
    /// - imuBuffer / lastBufferPushAt / fallPrediction / balanceState (Stage 3)
    /// - imuRollDeg / imuPitchDeg / imuSource / motorTempSource (Phase D)
    /// - lastPreflightFailure / lastCycleResult (Phase D Agent 4 P2)
    /// - correctionEnabledAt / lastCorrections / lastSafePose (Stage 4 corrector ramp)
    /// - safetyTimeline / normalizedSafetyTimeline / previous* / rampCompletedLogged
    ///   (Monitoring dashboard reset)
    /// - logSafetyEvent(.sessionStart) (final 전이 로그)
    internal func startResetSessionState(_ preset: WalkLabPreset) {
        footTrail.removeAll()
        footTrailLefts.removeAll()  // v1.14.8.1 parallel cache reset
        simSwayPhase = 0
        balanceLost = false
        thermalAlarm = false
        // v1.11.22.1: emergency flag clear — 새 session 시작 시 exit-phase 허용.
        emergencyStopActive = false
        // 사이클 67: trigger payload 도 cleanup — 다음 emergency 까지 stale 차단.
        _lastEmergencyTrigger = nil
        // v1.8: hysteresis reset — 이전 cycle 잔존 데이터로 false trigger 차단.
        warningStateConsecutiveSamples = 0
        dangerStateConsecutiveSamples = 0
        l3HardGateConsecutiveSamples = 0
        // **Stage 3 (v1.1 fall prevention)**: 새 보행 시작 시 buffer reset —
        // 이전 cycle 의 stale sample 로 score 거짓 발동 방지.
        imuBuffer.removeAll()
        lastBufferPushAt = nil
        fallPrediction = .zero
        balanceState = .normal
        // **Phase D 정정 (Agent 4 P1)**: imu 값도 reset — 이전 cycle 의 stale 28°
        // 가 남아 있으면 첫 tick 에 잘못된 balanceState 발동.
        imuRollDeg = 0
        imuPitchDeg = 0
        imuSource = .sim
        // **2026-05-16**: 모터 온도 source reset — 새 session 의 첫 tick 에서
        // updateMotorTempFromRealOrSim 이 정확한 source 로 갱신.
        motorTempSource = .sim
        // **Phase D 정정 (Agent 4 P2)**: 이전 cycle 결과/preflight failure 도 reset.
        lastPreflightFailure = nil
        lastCycleResult = nil
        // **Stage 4 (v1.1 fall prevention)**: corrector ramp 재시작.
        correctionEnabledAt = enableBalanceCorrection ? Date() : nil
        lastCorrections = nil
        lastSafePose = nil
        // **Monitoring dashboard reset**: 시계열 buffer / 이전 상태 reset.
        // safetyEvents 는 유지 — 사용자가 이전 세션의 이벤트 확인 가능.
        safetyTimeline.removeAll()
        // **v1.14.8 (2026-05-21) perf #6**: normalized 캐시도 동기 reset.
        normalizedSafetyTimeline.removeAll()
        previousBalanceState = .normal
        previousImuSource = .sim
        previousMotorTempSource = .sim
        previousRecommendEmergency = false
        rampCompletedLogged = false
        logSafetyEvent(kind: .sessionStart, message: "보행 시작 — \(preset.label)")
    }

    // MARK: - Phase 8 — sim tick loop 시작

    /// `startTime = Date()` 기록 + simTimer 재할당 (이전 invalidate 후 scheduledTimer).
    /// tickDtSec 주기 (100ms) 마다 `tick()` 호출.
    ///
    /// **v1.11.2 (2026-05-18)**: CI Swift 5.9 호환 — Task closure 에 `[weak self]` 재캡쳐.
    ///
    /// **2026-05-24 (V270-flaky fix)** — outer Timer closure 도 `[weak self]` 로 캡쳐.
    /// 종전: inner Task 만 weak — outer closure 가 self 를 strong 캡쳐하므로
    /// RunLoop → simTimer → outer closure → self 체인이 유지. 호출자가 `stop()` 없이
    /// session 참조 해제하면 deinit 발생 안 함 → simTimer 영원히 fire + session 영구 누수.
    /// 1962-test 풀스위트 + coverage instrumentation 환경에서 SIGSEGV 트리거 (사이클 누적).
    /// 신규: outer 도 weak — session 해제 즉시 deinit → simTimer invalidate → 누수 차단.
    internal func startScheduleTickLoop() {
        startTime = Date()
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: tickDtSec, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }
}
