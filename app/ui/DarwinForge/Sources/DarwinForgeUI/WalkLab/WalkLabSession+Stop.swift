import Foundation
import ForgeCore

/// **v1.22.x (2026-05-24) — 사이클 V257-1 (W2.11): god method 분할 (stop / emergencyStop)**.
///
/// `WalkLabSession.swift:1238` 의 `stop()` (68 line) 과 `WalkLabSession.swift:1313` 의
/// `emergencyStop(trigger:)` (63 line) 을 phase-named internal helper 들로 분해.
/// 원본 facade 는 호출 sequence 만 유지 — 외부 API 변경 0, 호출 site 변경 0.
///
/// # 비유
///
/// 항공기 셧다운 절차서 — `stop()` 은 정상 착륙 후 엔진 정지 체크리스트 (8 phase),
/// `emergencyStop()` 은 활주로 위 비상 정지 체크리스트 (8 phase). 비상 체크리스트는
/// 순서가 안전과 직결 — `emergencyStopActive` 플래그를 먼저 올리고 (race guard),
/// 그 다음 모터 cancel, 다음 하드웨어 torque OFF (FFI), 다음 시뮬레이션/엔진 cleanup.
///
/// # 분할 정책
///
/// - **logic 보존 100%**: 분해는 refactor only. 변수 capture / side effect 순서 /
///   harness telemetry 발행 위치 / 하드웨어 FFI 호출 순서 모두 원본 그대로 유지.
/// - **helper prefix**: `stop` (normal stop), `es` (emergencyStop) — namespace 충돌
///   방지 + W2.7 `start`, W2.3 `swc`, W2.5 `bc`, W2.6 `safetySample` 와 일관 패턴.
/// - **`@MainActor` 격리**: 본 extension 의 모든 helper 는 `WalkLabSession` 의 actor
///   격리를 상속.
///
/// # Safety-Critical 순서 보존 (emergencyStop)
///
/// 1. harness.record(.walkLabEmergencyStop) — live tilt / fall_score capture
/// 2. emergencyStopActive = true — exit-phase race guard FIRST (v1.11.22.1 CRITICAL)
/// 3. _lastEmergencyTrigger = trigger — root guard payload
/// 4. walkCycleTask.cancel() + walkTuningRestartTask.cancel() — motor task stop
/// 5. isRobotWalking = false
/// 6. store.emergencyStop() — HARDWARE FFI (torque OFF + P_GAIN=0 simultaneous)
/// 7. simTimer + engine cleanup — sim state zero
/// 8. strideMm/sideMm/turnDeg = 0 — pilot EMA 잔재 hard-zero (v1.20.14.1)
///
/// # Phase 매핑 (원본 line 번호 기준)
///
/// ## stop() — 원본 1238-1306
///
/// | Helper                              | Phase                                       | 원본 lines  |
/// |-------------------------------------|---------------------------------------------|-------------|
/// | `stopFinalizeTrialBeforeTimer`      | 1. finalizeTrialIfPending(.userStop)        | 1241        |
/// | `stopTeardownSimEngine`             | 2. simTimer invalidate + engine zero        | 1245-1247   |
/// | `stopEmitNormalStopTelemetry`       | 3. harness.record(.walkLabStop)             | 1250-1257   |
/// | `stopAppendHistoryRecord`           | 4. WalkLabRecord insert + cap 12            | 1258-1265   |
/// | `stopLogSessionStopAndIdle`         | 5. startTime=nil + .sessionStop log + idle  | 1266-1272   |
/// | `stopCleanupOnboardIfActive`        | 6. onboardWalkingActive cleanup             | 1277-1282   |
/// | `stopCancelWalkCycleIfRunning`      | 7. cancelWalkCycle (current=.idle 後)       | 1285-1287   |
/// | `stopFinalizeDiagnosticReset`       | 8. isRobotWalking/imuFastPoll/diagnostic    | 1290-1305   |
///
/// ## emergencyStop() — 원본 1313-1376
///
/// | Helper                              | Phase                                       | 원본 lines  |
/// |-------------------------------------|---------------------------------------------|-------------|
/// | `esFinalizeTrialIfPending`          | 1. trialEndReason derivation + finalize     | 1316-1318   |
/// | `esEmitEmergencyTelemetry`          | 2. harness.record(.walkLabEmergencyStop)    | 1321-1329   |
/// | `esRaiseEmergencyFlag`              | 3. emergencyStopActive=true + trigger       | 1333-1336   |
/// | `esCancelAllTasks`                  | 4. walkCycleTask + walkTuningRestartTask    | 1338-1342   |
/// | `esExecuteHardwareEStop`            | 5. store.emergencyStop() — HARDWARE FFI     | 1344        |
/// | `esTeardownSimAndEngine`            | 6. simTimer + engine + strideMm + startTime | 1346-1355   |
/// | `esLogEmergencyEvent`               | 7. logSafetyEvent + current/activeRobot/onb | 1356-1366   |
/// | `esResetDiagnosticFlags`            | 8. motorWrite/requested/risk/balance/event  | 1367-1374   |
///
/// # 회귀
///
/// 1902 tests 회귀 0 — 외부 API 변경 0. facade 의 호출 sequence 만 유지.
extension WalkLabSession {

    // MARK: - stop() helpers — 정상 정지 8-phase

    /// **Phase 1 — Trial 종료 hook (simTimer invalidate 前)**.
    ///
    /// **v1.15.0 (2026-05-21) Phase 1**: Trial 종료 hook — capture → Analyzer → Store
    /// → label sheet. simTimer invalidate 前에 호출 — sessionLogger 가 아직 살아있을 때
    /// file path 추출.
    internal func stopFinalizeTrialBeforeTimer() {
        finalizeTrialIfPending(endReason: .userStop)
    }

    /// **Phase 2 — simTimer invalidate + engine zero**.
    ///
    /// simTimer 를 무효화하고 sim engine 명령을 zero 로 송출. 보행 모터 잔재 제거.
    internal func stopTeardownSimEngine() {
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
    }

    /// **Phase 3 — 정상 정지 telemetry 발행**.
    ///
    /// **v1.12.0 telemetry** — 정상 정지. `wasRunning=true` 일 때만 발행
    /// (idle 상태에서 stop() 호출 시 noise 제거). `current.label` 을 사용하므로
    /// `current = .idle` 前에 호출해야 함.
    internal func stopEmitNormalStopTelemetry(wasRunning: Bool, durationSec: Double) {
        guard wasRunning else { return }
        harness.record(
            .walkLabStop, level: .notice, actor: .user,
            data: ["duration_s": AnyCodable(durationSec),
                   "preset": AnyCodable(current.label)]
        )
    }

    /// **Phase 4 — history record 적재**.
    ///
    /// `startTime` 이 있으면 `WalkLabRecord` 를 history 맨 앞에 insert,
    /// 최대 12개 유지 (FIFO eviction). `current` 를 preset 으로 사용하므로
    /// `current = .idle` 前에 호출.
    internal func stopAppendHistoryRecord(startTime: Date?) {
        guard let start = startTime else { return }
        history.insert(WalkLabRecord(
            preset: current,
            durationSec: Int(Date().timeIntervalSince(start)),
            endedAt: Date()
        ), at: 0)
        if history.count > 12 { history.removeLast() }
    }

    /// **Phase 5 — startTime=nil + .sessionStop 로그 + current=.idle + activeRobotPreset=nil**.
    ///
    /// 원본 line 1266 → 1267-1269 → 1270 → 1272 sequence 보존.
    /// `.sessionStop` 로그는 `current.label` 을 사용하므로 `current = .idle` 前에 발행.
    ///
    /// **v1.11.24 audit P1-1**: 실 motor task 가 멈춘 시점에 activeRobotPreset clear.
    internal func stopLogSessionStopAndIdle(wasRunning: Bool) {
        startTime = nil
        if wasRunning {
            logSafetyEvent(kind: .sessionStop, message: "정상 정지 — \(current.label)")
        }
        current = .idle
        // v1.11.24 audit P1-1 — 실 motor task 가 멈춘 시점에 activeRobotPreset clear.
        activeRobotPreset = nil
        mobileFreeformActive = false
        mobileFreeformTuning = nil
        // sway 도 zero 로 디케이 — 다음 tick 에서 매끄럽게 감소.
    }

    /// **Phase 6 — onboard 보행 cleanup**.
    ///
    /// **v1.11.7 (2026-05-18, GPT HIGH-2)** — onboard 모드도 lifecycle 정리.
    /// walkingEngine == .robotisOnboard 일 때 walkCycleTask 가 없으므로 별도 cleanup.
    internal func stopCleanupOnboardIfActive() {
        guard onboardWalkingActive else { return }
        onboardWalkingActive = false
        onboardAckStatus = nil
        logSafetyEvent(kind: .sessionStop,
            message: "ROBOTIS Onboard 정지 — robot 측 SSH stop 명령 별도 필요")
    }

    /// **Phase 7 — wasRunning 일 때 walkCycle cancel**.
    ///
    /// 실 보행 cycle cancel — Task 내부에서 walkReady 복귀 후 종료.
    /// v1.11.24 audit P1-1: cancelWalkCycle 은 walkCycleTask 가 nil 이면 reset 안 함
    /// (test/sim 경로). 원본 line 1285-1287 — `current=.idle` 後 시점 유지.
    internal func stopCancelWalkCycleIfRunning(wasRunning: Bool) {
        guard wasRunning else { return }
        cancelWalkCycle(eventLabel: "정지 — 직립 자세 복귀")
    }

    /// **Phase 8 — 잔여 진단 / riskAck / walkTuningRestart cleanup**.
    ///
    /// **v1.11.24 audit P1-1**: invariant — stop() 후엔 항상 `isRobotWalking=false`.
    /// **사이클 159 (P0-1)**: stop() 도 IMU slow polling 복원 — finalize race 회피.
    /// **v1.11.24 audit iter2-B**: 진단 필드 reset — 종전: 다음 session 의 로그 헤더에
    /// 이전 session 의 requestedPreset / startBlockedReason 등이 leak.
    /// **v1.11.25 audit-C**: stop() 후 highRisk preset 재시작 시 위험 동의 재확인 강제.
    /// 종전: emergencyStop 만 reset → 사용자가 jog 동의 → 일반 정지 → 즉시 다시 jog 가능.
    /// 매 보행 세션마다 idempotent 동의 위반.
    internal func stopFinalizeDiagnosticReset() {
        // v1.11.24 audit P1-1 — invariant: stop() 후엔 항상 isRobotWalking=false.
        isRobotWalking = false
        // 사이클 159 (P0-1 fix): stop() 도 IMU slow polling 복원 — finalize race 회피.
        store?.imuFastPollActive = false
        // v1.11.24 audit iter2-B — 진단 필드 reset.
        motorWriteStarted = false
        motorWriteStepCount = 0
        requestedPreset = nil
        startBlockedReason = nil
        onboardAckStatus = nil
        mobileFreeformActive = false
        mobileFreeformTuning = nil
        // v1.11.25 audit-C — 매 보행 세션마다 idempotent 동의 위반 차단.
        riskAcknowledged = false
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
    }

    // MARK: - emergencyStop() helpers — 비상 정지 8-phase (safety-critical)

    /// **Phase 1 — Trial 종료 hook (endReason 분기)**.
    ///
    /// **v1.15.0 (2026-05-21) Phase 1**: trigger 가 fallPredictorRecommend 면
    /// `.fallPredictorTriggered`, 그 외는 `.emergencyStop` reason 으로 finalize.
    internal func esFinalizeTrialIfPending(trigger: EmergencyTrigger) {
        let trialEndReason: EndReason =
            (trigger == .fallPredictorRecommend)
            ? .fallPredictorTriggered : .emergencyStop
        finalizeTrialIfPending(endReason: trialEndReason)
    }

    /// **Phase 2 — emergency telemetry 발행 (live tilt capture)**.
    ///
    /// **v1.12.0 telemetry** — WalkLab 비상 정지. live tilt / fall_score / preset /
    /// trigger 를 capture. 반드시 mutation 前에 호출 — 정확한 trigger 시점 state 기록.
    ///
    /// **v1.11.25 audit log-G**: trigger 출처 명시 — actor=.user (수동) vs auto
    /// (balance lost / thermal / voltage) 구분 가능.
    internal func esEmitEmergencyTelemetry(trigger: EmergencyTrigger) {
        let tiltForHarness = max(abs(imuRollDeg), abs(imuPitchDeg))
        harness.record(
            .walkLabEmergencyStop, level: .error,
            actor: trigger.harnessActor,
            data: ["tilt_deg": AnyCodable(tiltForHarness),
                   "fall_score": AnyCodable(fallPrediction.score),
                   "preset": AnyCodable(current.label),
                   "trigger_source": AnyCodable(trigger.rawValue)]
        )
    }

    /// **Phase 3 — emergency flag 상승 (CRITICAL race guard)**.
    ///
    /// **v1.11.22.1 (Codex HIGH-1 fix)** — exit-phase race 차단:
    /// `emergencyStopActive` flag 먼저 set → walkCycleTask 의 exit phase 가
    /// walkReady setPosition 시도 前 check 하여 skip. 토크 OFF 이후 명령 무효 보장.
    ///
    /// **v1.21.2 사이클 67 (코덱스 MEDIUM-3 fix)** — `_lastEmergencyTrigger` 도 set
    /// — start() root guard 의 `.emergencyActive(trigger:)` 가 사용자에게 출처 명시.
    ///
    /// **순서 절대 보존**: emergencyStopActive=true → _lastEmergencyTrigger=trigger
    /// → (그 다음 phase 4 의 cancel) — 단 한 단계라도 뒤바뀌면 exit-phase race 노출.
    internal func esRaiseEmergencyFlag(trigger: EmergencyTrigger) {
        emergencyStopActive = true
        _lastEmergencyTrigger = trigger
    }

    /// **Phase 4 — 모든 Task cancel + isRobotWalking=false**.
    ///
    /// 보행 cycle 즉시 cancel — 모터 송출 중지. walkTuningRestartTask 도 cancel
    /// (debounce 중인 자동 재시작 차단). `isRobotWalking=false` 로 UI 상태 즉시 반영.
    ///
    /// **M1 — E-STOP halts smooth-return**: `smoothReturnTask` cancel + nil.
    /// `store.cancelMovingPose()` 로 진행 중인 `applyPoseSmoothly` drain 도 즉시 중단.
    /// E-STOP 이 토크 OFF 를 내리는 시점에 leg joint write 가 계속되면 torque OFF 이후
    /// write 가 들어가 예측 불가 자세로 스냅되는 안전 위반.
    internal func esCancelAllTasks() {
        walkCycleTask?.cancel()
        walkCycleTask = nil
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
        // M1: smooth-return Task 도 즉시 중단 — E-STOP 이후 어떤 joint write 도 금지.
        smoothReturnTask?.cancel()
        smoothReturnTask = nil
        store?.cancelMovingPose()
        isRobotWalking = false
    }

    /// **Phase 5 — 하드웨어 emergency stop (FFI)**.
    ///
    /// `store.emergencyStop()` — torque OFF + P_GAIN=0 simultaneous 송출.
    /// 토크 OFF 가 들어가야 임의 모터 명령 잔여를 무력화. 반드시 cancel 이후 호출 —
    /// cycle Task 가 살아 있는 동안 토크 OFF 송출 시 race.
    ///
    /// **HARDWARE CRITICAL**: 본 호출이 실패하거나 누락되면 로봇이 jog 자세에서 free-fall.
    internal func esExecuteHardwareEStop() {
        store?.emergencyStop()
    }

    /// **Phase 6 — sim timer / engine cleanup + pilot EMA hard-zero**.
    ///
    /// 시뮬 정지 + engine zero 명령 + pilot EMA (strideMm/sideMm/turnDeg) hard-zero
    /// + startTime=nil.
    ///
    /// **v1.20.14.1 사이클 20-fix HIGH 2 (코덱스)** — pilot EMA 잔재 hard-zero.
    /// 종전: emergencyStop 후 engine.setCommand(0,...) 만 zero, session.strideMm 잔재 →
    /// 차후 syncCommandToEngine 가 stale 값 재송출 가능.
    internal func esTeardownSimAndEngine() {
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        strideMm = 0
        sideMm = 0
        turnDeg = 0
        startTime = nil
    }

    /// **Phase 7 — emergency 이벤트 로그 + current/activeRobot/onboard cleanup**.
    ///
    /// `.emergencyTriggered` safety event (live tilt 포함) + current=.idle,
    /// activeRobotPreset/onboardWalkingActive/onboardAckStatus = nil.
    ///
    /// **v1.11.24 audit P1-1**: 실 motor task 가 멈춘 시점에 activeRobotPreset clear.
    internal func esLogEmergencyEvent() {
        let tilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        logSafetyEvent(
            kind: .emergencyTriggered,
            message: String(format: "비상 정지 — 토크 OFF (tilt %.1f°, score %.0f)",
                            tilt, fallPrediction.score)
        )
        current = .idle
        // v1.11.24 audit P1-1 — 실 motor task 가 멈춘 시점에 activeRobotPreset clear.
        activeRobotPreset = nil
        onboardWalkingActive = false
        onboardAckStatus = nil
        mobileFreeformActive = false
        mobileFreeformTuning = nil
    }

    /// **Phase 8 — 진단 필드 reset + lastRobotEvent 표시**.
    ///
    /// **v1.11.24 audit iter2-B**: 진단 필드 reset — 다음 session 의 로그 헤더에
    /// 이전 emergency 의 requestedPreset / startBlockedReason 등이 leak 차단.
    /// 온도는 그대로 — 사용자가 확인 후 자연 냉각.
    internal func esResetDiagnosticFlags() {
        motorWriteStarted = false
        motorWriteStepCount = 0
        requestedPreset = nil
        startBlockedReason = nil
        riskAcknowledged = false
        balanceLost = false
        lastRobotEvent = "🛑 토크 OFF — 비상 정지"
        // 온도는 그대로 — 사용자가 확인 후 자연 냉각.
    }
}
