import Foundation
import ForgeCore

/// **자동 일어나기 (Auto Fall-Recovery) — 오케스트레이션 extension**.
///
/// # 비유
///
/// 구급대원이 현장에 도착해 환자 상태를 확인(tick 에서 detectFall) 한 뒤,
/// 별도 처치팀(detached Task) 을 불러 체계적으로 처치한다. 구급대원 자신은
/// 계속 현장을 순찰하고, 처치팀이 완료 보고를 올리면 "완료" 를 기록한다.
///
/// # 공식 ROBOTIS 절차 (StatusCheck.cpp:27-43 반영)
///
/// 1. Walking::Stop() 에 해당 → `pilotStop()`
/// 2. 자이로 정착 대기 (추가 안전 — 원본 없음)
/// 3. 토크 ON + P_GAIN 복원 (공식: enable body torque)
/// 4. Action::Start(10/11) — motionPlaySlot(slot: dir.getUpPage)
/// 5. wait until IsRunning()==false → isMotionPlaying polling
/// 6. tilt 재확인 + 재시도 또는 완료/실패
///
/// # 동시성 안전
///
/// - `tickAutoFallRecoveryIfActive()` 는 @MainActor tick 에서 10Hz 호출.
/// - Recovery Task 는 detached — MainActor tick 을 블로킹하지 않음.
/// - `autoRecoveryTask != nil` 가드로 Task 중복 spawn 방지.
/// - `autoRecoveryPhase` write 는 Task 내부에서 `await MainActor.run { }` 로 격리.
@MainActor
extension WalkLabSession {

    // MARK: - Always-on fall monitor lifecycle

    /// **항상-ON 낙하 모니터 시작** — `attach(store:)` 에서 호출.
    ///
    /// simTimer(walk tick) 과 독립된 10Hz 타이머. robot 이 연결된 동안 항상 실행.
    /// 보행 중지 후 / 조종 종료 후에도 낙하 감지 유지 (ROOT CAUSE 수정).
    ///
    /// **단일 감지 소유자**: 이 타이머만 `triggerFallRecovery` 를 호출.
    /// `tickAutoFallRecoveryIfActive()` 는 tick 에서 제거됨.
    internal func startFallMonitor() {
        fallMonitorTimer?.invalidate()
        // A (2026-05-31): 연결 직후 영속 영점 로드 + 세션별 자동 캡처 throttle 리셋.
        primeImuZeroForConnection()
        fallMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: 0.1,  // 10Hz — walk tick 과 동일 주기
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.fallMonitorTick()
            }
        }
    }

    /// 낙하 모니터 타이머 무효화. 테스트 / teardown 용.
    internal func stopFallMonitor() {
        fallMonitorTimer?.invalidate()
        fallMonitorTimer = nil
    }

    // MARK: - Fall monitor tick (MainActor, 10Hz, always-on)

    /// **항상-ON 낙하 감지 tick** — `fallMonitorTimer` 에서 10Hz 호출.
    ///
    /// ROBOTIS 공식 가속도계(accelY raw) 기반 감지 — pitch° 기반 `detectFall` 과 달리
    /// 보행 바이어스/필터 오차에 강인. 30-sample 이동 평균으로 보행 스파이크 억제.
    ///
    /// **GATE (이전 piloting 의존 제거 — 계획 B 반영)**:
    /// - `enableAutoGetUp == true`
    /// - `store?.bus != nil` — 연결됨
    /// - `store?.isDxlPowerOn == true` — 전원 ON (정비 상태 제외)
    /// - `cradleConfirmed == false` — 정비 스탠드 아님
    /// - `autoRecoveryTask == nil` — 중복 spawn 방지
    /// - `autoRecoveryPhase == .idle || .done` — 진행 중 아님
    ///
    /// **FallTelemetry 링**: walk tick 이 off 일 때도 이 tick 에서 ring 에 accelY 를
    /// 피딩 — 낙하 전 이력이 walk 중이 아닐 때도 남도록.
    internal func fallMonitorTick() {
        // accelY ring 업데이트 — 보행 여부 무관하게 항상 피딩.
        if let raw = store?.lastImuRaw {
            accelYRing.append(Int(raw.accelY))
            if accelYRing.count > WalkLabSession.accelRingCapacity {
                accelYRing.removeFirst(accelYRing.count - WalkLabSession.accelRingCapacity)
            }

            // FallTelemetryRecorder ring 피딩 — walk tick 이 off 일 때도 pre-fall 이력 축적.
            // (walk tick 이 살아있을 때는 tickPollSensorsAndBalanceState 에서 이미 피딩하므로
            // 중복 push 가 발생할 수 있으나, recorder 는 순서-based flush 라 무해함.)
            if autoRecoveryPhase != .idle {
                let tMs = sessionStartedAt.map { Date().timeIntervalSince($0) * 1000.0 } ?? 0
                let ringSample = FallTelemetrySample(
                    tMs: tMs,
                    imuRollDeg: imuRollDeg,
                    imuPitchDeg: imuPitchDeg,
                    gyroXDps: raw.gyroXDps,
                    gyroYDps: raw.gyroYDps,
                    gyroZDps: raw.gyroZDps,
                    accelXG: raw.accelXG,
                    accelYG: raw.accelYG,
                    accelZG: raw.accelZG,
                    balanceState: String(describing: balanceState),
                    autoRecoveryPhase: String(describing: autoRecoveryPhase),
                    perJointLoad: nil,
                    perJointTemp: nil,
                    cmdStrideMm: nil,
                    cmdSideMm: nil,
                    cmdTurnDeg: nil
                )
                fallTelemetryRecorder.appendLiveSample(ringSample)
            }
        }

        // A (2026-05-31): 정지 상태 IMU 영점 자동 캡처 (읽기/저장/로깅 전용 — 동작 무변경).
        updateImuZeroAutoCapture()

        // E (2026-05-31): 낙하가 감지됐는데 게이트가 자동 일어나기를 막으면 사유를 로깅.
        // 아래 실제 guard 흐름은 변경하지 않는다 — 진단 신호만 추가(throttle).
        diagnoseGetupGateIfFallDetected()

        // **M-isRecovering fix (2026-05-30)**: 수동 recoverFromEStop 과 자동 recovery 가
        // 동시에 bus write 를 시도하면 write storm 인터리브 위험. store.isRecovering 은
        // ConnectionStore 의 `recoverFromEStop` 이 진행 중임을 의미 → 이 tick 에서 skip.
        guard store?.isRecovering != true else { return }

        // GATE 1: 기능 토글
        guard enableAutoGetUp else { return }

        // GATE 2: 이미 recovery 진행 중 — 중복 spawn 방지
        guard autoRecoveryTask == nil else { return }

        // GATE 3 (2026-05-31 사용자 결정 "바닥 낙상이면 항상 일어나기"): cradle 모드는 더 이상
        // getup 을 원천 차단하지 않는다. 트리거는 `isFallenAccelSustained`(명확한 바닥 낙상 가속도)
        // 가 1차 안전 조건이고, runRecovery 의 `waitForSettle`(자이로 정지 대기)이 2차 안전장치다.
        // → 스탠드를 움직이는 중(자이로 활성)에는 settle 대기로 getup 이 지연되어 안전.

        // GATE 4: bus 연결 확인
        guard store?.bus != nil else { return }

        // GATE 5: DXL 전원 ON — 전원 OFF 상태(정비/충전)에서 auto get-up 금지
        guard store?.isDxlPowerOn == true else { return }

        // **M-thermal fix (2026-05-30)**: simTimer 가 정지하면 tick 의 L0/L4 gate 가 실행되지
        // 않는다. fallMonitorTick(10Hz, always-on) 에서 최소 voltage/temp 확인 — 과열/저전압
        // 상태에서 get-up 시도를 차단하여 모터 손상과 낙하 가속 위험을 예방.
        if maxMotorTemp >= 60 {
            // 과열 상태 — recovery 금지. emergencyStop 은 tick L4 가 처리; 여기선 감지만 억제.
            return
        }
        if let v = voltageForGate, v > 0, v < 9.5 {
            // 저전압 — get-up 시도 중 전원 강하 위험. 감지 억제.
            return
        }

        // GATE 6: phase 허용 확인
        // .idle 과 .done 만 허용 — 진행 중 상태(.fallen/.settling/.gettingUp/.failed) 억제.
        // .done: 성공 후 2s 표시 중에 새 낙하 발생 → 즉시 새 recovery 시작 (M2 패턴 유지).
        guard autoRecoveryPhase == .idle || autoRecoveryPhase == .done else { return }

        // 가속도계 기반 낙하 감지 (ROBOTIS 공식 30-sample 평균).
        // accelYRing 이 비어있으면 nil — 연결 직후 초기 구간에서 오판 방지.
        guard let direction = AutoFallRecovery.isFallenAccelSustained(samples: accelYRing) else { return }

        // **FIX 3 (2026-05-31)**: getup 직후 곧바로 다시 낙상이 반복되면(= getup 무효) 무한 루프
        // 대신 비상정지로 escalate. 한 번 일어났다 또 넘어지는 정상 케이스는 허용하되, 짧은
        // 윈도우에 반복되면 "일어나기가 효과 없음" 으로 보고 차단한다.
        if refallStreakExceeded() {
            escalateForRefallLoop(direction: direction)
            return
        }

        // 낙하 감지 — 상태 전환 + Task spawn
        triggerFallRecovery(direction: direction)
    }

    // MARK: - FIX 3: 반복 재낙상(getup 무효) escalation

    /// 최근 12초 내 "성공 종료" 가 임계 이상 누적됐는지 — getup 이 효과 없이 반복됨을 의미.
    /// 임계 3회: 일어났다 또 넘어지는 정상 재시도(1-2회)는 허용, 3회 이상 반복만 차단.
    private func refallStreakExceeded() -> Bool {
        let now = Date()
        // **리뷰 HIGH (2026-05-31)**: 윈도우 30s. 단일 복구 사이클이 settle(최대 4s) +
        // get-up 모션(3~8s) + retry 등으로 10s+ 걸릴 수 있어, 12s 는 정상적인 연속 낙상에도
        // 오escalation 위험. 30s 로 넓혀 "짧은 시간 반복(=getup 무효)" 만 잡는다.
        recoveryDoneTimestamps.removeAll { now.timeIntervalSince($0) > 30.0 }
        return recoveryDoneTimestamps.count >= 3
    }

    /// 반복 재낙상 → 비상정지 escalate. 재트리거 방지를 위해 phase .failed + ring 초기화.
    private func escalateForRefallLoop(direction: AutoFallRecovery.FallDirection) {
        autoRecoveryPhase = .failed
        accelYRing.removeAll(keepingCapacity: true)
        recoveryDoneTimestamps.removeAll()
        logSafetyEvent(
            kind: .emergencyTriggered,
            message: "자동 일어나기 반복 실패 — getup 후 즉시 재낙상 3회+ → 비상정지(무한 루프 차단)"
        )
        harness.record(
            .recoveryFailed, level: .error, actor: .robot,
            data: ["reason": AnyCodable("refall_loop"),
                   "direction": AnyCodable(direction == .forward ? "forward" : "backward")]
        )
        emergencyStop(trigger: .balanceLostL3)
    }

    // MARK: - E (2026-05-31): getup 게이트 차단 진단 (로깅 전용, 동작 무변경)

    /// 낙하가 감지된 상태인데 어떤 게이트가 자동 일어나기를 막고 있으면 그 사유를 로깅.
    /// "왜 일어나기 대신 비상/정지로 갔는가" 를 다음 실행에서 바로 진단할 수 있게 한다.
    /// **제어 흐름 변경 없음** — 위 `fallMonitorTick` 의 guard 들은 그대로 동작한다.
    internal func diagnoseGetupGateIfFallDetected() {
        // 낙하 신호가 없으면 차단 상태를 클리어하고 반환(다음 낙하 때 다시 1회 로깅되도록).
        guard AutoFallRecovery.isFallenAccelSustained(samples: accelYRing) != nil else {
            lastGetupBlockReason = nil
            return
        }
        let reason = getupBlockReason()
        // 사유가 직전과 동일하면 재로깅 안 함(10Hz 스팸 방지). nil(차단 없음→정상 트리거)도 스킵.
        guard let reason, reason != lastGetupBlockReason else {
            if reason == nil { lastGetupBlockReason = nil }
            return
        }
        lastGetupBlockReason = reason

        let direction = AutoFallRecovery.isFallenAccelSustained(samples: accelYRing)
        harness.record(
            .getupGateBlocked, level: .warn, actor: .system,
            data: [
                "gate": AnyCodable(reason),
                "fall_direction": AnyCodable(direction == .forward ? "forward"
                    : direction == .backward ? "backward" : "unknown"),
                "dxl_power": AnyCodable(store?.isDxlPowerOn ?? false),
                "cradle": AnyCodable(cradleConfirmed),
                "motor_temp": AnyCodable((maxMotorTemp * 10).rounded() / 10),
                "voltage": AnyCodable(voltageForGate.map { ($0 * 10).rounded() / 10 } ?? -1),
                "phase": AnyCodable(String(describing: autoRecoveryPhase)),
                "recovering": AnyCodable(store?.isRecovering ?? false)
            ]
        )
        logSafetyEvent(
            kind: .preflightFailure,
            message: "자동 일어나기 차단 — 게이트 [\(reason)] (낙하 감지됨). 진단 기록(동작 미변경)"
        )
    }

    /// `fallMonitorTick` 의 guard 순서를 그대로 반영해 **첫 번째로 막는 게이트** 이름을 반환.
    /// 모든 게이트 통과(=정상 트리거 가능)면 nil.
    internal func getupBlockReason() -> String? {
        if store?.isRecovering == true { return "manual_recovery_in_progress" }
        if !enableAutoGetUp { return "auto_getup_disabled" }
        if autoRecoveryTask != nil { return "recovery_task_active" }
        // cradle_mode 는 더 이상 차단 사유 아님 (2026-05-31 사용자 결정). settle 대기가 안전장치.
        if store?.bus == nil { return "no_bus" }
        if store?.isDxlPowerOn != true { return "dxl_power_off" }
        if maxMotorTemp >= 60 { return "thermal_overheat" }
        if let v = voltageForGate, v > 0, v < 9.5 { return "low_voltage" }
        if !(autoRecoveryPhase == .idle || autoRecoveryPhase == .done) { return "phase_busy" }
        return nil
    }

    // MARK: - Internal trigger (monitor + legacy tick 공용)

    /// 낙하 감지 후 recovery 를 시작하는 공용 진입점.
    ///
    /// 상태 전환(`.fallen`) + telemetry + FallTelemetryRecorder 시작 + Task spawn.
    /// `fallMonitorTick` 이 호출 — pitch° 기반 경로는 FALLBACK 으로만 사용.
    internal func triggerFallRecovery(direction: AutoFallRecovery.FallDirection) {
        // **리뷰 HIGH (2026-05-31)**: 중복 트리거 방지. 이제 호출처가 둘이다 —
        // ① fallMonitorTick(10Hz), ② L3 hard gate(walk tick). 두 타이머가 같은 RunLoop
        // pass 에 발화하면, 게이트 평가와 이 호출 사이 phase 가 진행될 수 있어 두 번째 호출이
        // task 를 덮어쓰며 첫 task 를 orphan 화(추적 불가) + bus write storm 을 유발한다.
        // 진입 가드로 단일 recovery 만 보장.
        guard autoRecoveryTask == nil,
              autoRecoveryPhase == .idle || autoRecoveryPhase == .done else { return }
        autoRecoveryPhase = .fallen(direction)
        autoRecoveryAttempts = 0
        // **M4 fix**: recovery 시작 시 accelYRing 초기화.
        // ring 에 보행 중 수집된 samples 가 남아있으면 recovery 완료 후 `isFallenAccelSustained`
        // 가 false-positive 로 즉시 새 recovery 를 트리거할 수 있다.
        // keepingCapacity: true 로 메모리 재할당 없이 내용만 제거.
        accelYRing.removeAll(keepingCapacity: true)

        logSafetyEvent(
            kind: .preflightFailure,
            message: String(format: "자동 일어나기 시작 — 낙하 방향 %@ (accelY 평균 기반), get-up page %d",
                            direction == .forward ? "FORWARD" : "BACKWARD",
                            direction.getUpPage)
        )

        // Harness telemetry — Phase 1 kind.
        harness.record(
            .recoveryDetected, level: .warn, actor: .robot,
            data: ["direction": AnyCodable(direction == .forward ? "forward" : "backward"),
                   "get_up_page": AnyCodable(Int(direction.getUpPage)),
                   "source": AnyCodable("accel_monitor")]
        )

        // FallTelemetryRecorder — start capturing (dumps ring + live samples).
        let sessionId = recorder.sessionLogger?.header.sessionId
            ?? "walklab-\(ISO8601DateFormatter().string(from: Date()))"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let manifest = FallTelemetryManifest(
            sessionId: sessionId,
            startedAtISO: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion,
            thresholds: FallTelemetryManifest.FallThresholds(
                fallenThresholdDeg: AutoFallRecovery.fallenThresholdDeg,
                settleGyroDps: AutoFallRecovery.settleGyroDps
            )
        )
        fallTelemetryRecorder.startCapture(manifest: manifest, sessionId: sessionId)

        spawnRecoveryTask(direction: direction)
    }

    // MARK: - tick hook (MainActor, 10Hz) — DEPRECATED: now owned by fallMonitorTimer
    //
    // **이 메서드는 더 이상 tickRunSafetyPipeline 에서 호출되지 않는다.**
    // fallMonitorTimer 가 단일 감지 소유자. 하위 호환성을 위해 선언은 유지하되
    // 내부 로직은 fallMonitorTick 으로 위임하지 않음 (이중 트리거 방지).
    // 기존 테스트 코드가 이 메서드를 직접 호출하는 경우는 없으므로 안전.
    internal func tickAutoFallRecoveryIfActive() {
        // NO-OP: 감지 소유권이 fallMonitorTimer 로 이전됨.
        // tickRunSafetyPipeline 에서의 호출도 제거됨. 이중 감지 방지.
    }

    // MARK: - Recovery Task

    /// Recovery Task spawn — 중복 호출 방지는 호출자(tickAutoFallRecoveryIfActive) 가 보장.
    private func spawnRecoveryTask(direction: AutoFallRecovery.FallDirection) {
        let fallDetectedAt = Date()
        autoRecoveryTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runRecovery(direction: direction, fallDetectedAt: fallDetectedAt)
        }
    }

    /// Recovery 절차 본체 (ROBOTIS StatusCheck.cpp:27-43 반영).
    ///
    /// detached Task 안에서 실행 — MainActor 미격리.
    /// MainActor 접근이 필요한 property 는 모두 `await MainActor.run { }` 로 래핑.
    private func runRecovery(direction: AutoFallRecovery.FallDirection, fallDetectedAt: Date = Date()) async {
        // [1] Walking stop — walk cycle 정리.
        // C1a: walkCycleTask 스냅샷을 pilotStop() 前에 획득한 뒤 await — pilotStop 이
        // walkCycleTask 를 cancel + nil 하기 전에 핸들을 보존해야 한다.
        // cancelWalkCycle 이 nil 처리하므로, 스냅샷이 없으면 await 할 수 없음.
        // C1c: exitEmergencyMode() 가 포함된 restoreTorqueAndPGain 은 반드시 이 await 이후
        // 호출되어야 emergencyStopActive guard 가 walk task 의 마지막 sendStep 을 막는다.
        let walkHandle = await MainActor.run { () -> Task<Void, Never>? in
            let h = self.walkCycleTask
            self.pilotStop()
            return h
        }
        await walkHandle?.value
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms walk-cycle cleanup

        // Phase 1: elevate telemetry cadence to .full during recovery so all 20
        // joints' load/temp are captured. Restored to .light on completion.
        // `startTelemetry(cadence:)` stops/restarts the poll task — the only
        // supported mid-flight cadence change mechanism in ConnectionStore.
        await MainActor.run {
            if self.store?.bus != nil {
                self.store?.startTelemetry(cadence: .full)
            }
        }

        var lastDirection = direction
        var settleStartAt: Date = Date()

        while true {
            // 수동 E-STOP 등으로 cancel 되면 즉시 종료 — emergencyStop 이 이미 phase/task
            // 를 정리하므로 여기선 추가 정리 없이 빠져나간다 (수동 E-STOP 최우선).
            if Task.isCancelled {
                await MainActor.run {
                    if self.store?.bus != nil { self.store?.startTelemetry(cadence: .light) }
                    self.fallTelemetryRecorder.cancel()
                }
                return
            }
            let attempt = await MainActor.run { self.autoRecoveryAttempts }
            guard attempt < AutoFallRecovery.maxGetUpAttempts else {
                // 최대 시도 초과 → failed
                await MainActor.run {
                    self.autoRecoveryPhase = .failed
                    self.autoRecoveryTask = nil
                    // **M4 fix**: failed 시 accelYRing 초기화 — false-positive 재트리거 방지.
                    self.accelYRing.removeAll(keepingCapacity: true)
                    self.logSafetyEvent(
                        kind: .emergencyTriggered,
                        message: "자동 일어나기 실패 — 최대 시도 \(AutoFallRecovery.maxGetUpAttempts)회 초과. emergencyStop fallback"
                    )
                    self.harness.record(
                        .recoveryFailed, level: .error, actor: .robot,
                        data: ["reason": AnyCodable("max_attempts"),
                               "attempts": AnyCodable(attempt)]
                    )
                    let totalMs = Date().timeIntervalSince(fallDetectedAt) * 1000.0
                    let settleMs = Date().timeIntervalSince(settleStartAt) * 1000.0
                    let outcome = FallTelemetryOutcome(
                        direction: lastDirection == .forward ? "forward" : "backward",
                        getUpPage: lastDirection.getUpPage,
                        settleMs: settleMs,
                        attempts: attempt,
                        success: false,
                        recoveryTotalMs: totalMs
                    )
                    self.fallTelemetryRecorder.finalizeOutcome(outcome)
                    if self.store?.bus != nil { self.store?.startTelemetry(cadence: .light) }
                    self.emergencyStop(trigger: .balanceLostL3)
                }
                return
            }

            // [2] Settling — 자이로 정착 대기
            settleStartAt = Date()
            await MainActor.run {
                self.autoRecoveryPhase = .settling
                self.harness.record(
                    .recoverySettle, level: .info, actor: .robot,
                    data: ["direction": AnyCodable(lastDirection == .forward ? "forward" : "backward")]
                )
            }
            let settled = await waitForSettle()
            let settleMs = Date().timeIntervalSince(settleStartAt) * 1000.0

            if !settled {
                await MainActor.run {
                    self.logSafetyEvent(
                        kind: .stateChange,
                        message: "자동 일어나기 settling timeout — 강제 진행"
                    )
                }
            }

            // [3] 토크 + P_GAIN 복원
            let torqueOk = await restoreTorqueAndPGain()
            guard torqueOk else {
                let attemptsAtFail = await MainActor.run { self.autoRecoveryAttempts }
                let torqueTotalMs = Date().timeIntervalSince(fallDetectedAt) * 1000.0
                await MainActor.run {
                    self.autoRecoveryPhase = .failed
                    self.autoRecoveryTask = nil
                    // **M4 fix**: failed(torque) 시 accelYRing 초기화.
                    self.accelYRing.removeAll(keepingCapacity: true)
                    self.logSafetyEvent(
                        kind: .emergencyTriggered,
                        message: "자동 일어나기 실패 — 토크 복원 불가"
                    )
                    self.harness.record(
                        .recoveryFailed, level: .error, actor: .robot,
                        data: ["reason": AnyCodable("torque_restore_failed")]
                    )
                    let outcome = FallTelemetryOutcome(
                        direction: lastDirection == .forward ? "forward" : "backward",
                        getUpPage: lastDirection.getUpPage,
                        settleMs: settleMs,
                        attempts: attemptsAtFail,
                        success: false,
                        recoveryTotalMs: torqueTotalMs
                    )
                    self.fallTelemetryRecorder.finalizeOutcome(outcome)
                    if self.store?.bus != nil { self.store?.startTelemetry(cadence: .light) }
                    self.emergencyStop(trigger: .balanceLostL3)
                }
                return
            }

            // [4] get-up 모션 실행
            await MainActor.run {
                self.autoRecoveryPhase = .gettingUp
                self.autoRecoveryAttempts += 1
                self.harness.record(
                    .recoveryGetUp, level: .info, actor: .robot,
                    data: ["page": AnyCodable(Int(lastDirection.getUpPage)),
                           "attempt": AnyCodable(self.autoRecoveryAttempts),
                           "settle_ms": AnyCodable(settleMs)]
                )
            }

            let motionOk = await playGetUpMotion(page: lastDirection.getUpPage)
            guard motionOk else {
                // 모션 실패 → 재시도 루프 계속
                await MainActor.run {
                    self.logSafetyEvent(
                        kind: .stateChange,
                        message: String(format: "자동 일어나기 모션 실패 (page %d) — 재시도", lastDirection.getUpPage)
                    )
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            // [5] 일어남 검증 — **FIX 1 (2026-05-31)**: filtered `imuPitchDeg` 는 `motionPlaySlot`
            // 가 버스를 수 초 블로킹하는 동안 갱신되지 않아 마지막 보행값(예: -10.8°)에 **동결**된다.
            // 그 결과 `detectFall(pitch)` 가 항상 "안 누움=성공" 으로 오판 → 가짜 성공 → 무한 루프.
            // ROBOTIS StatusCheck 처럼 **가속도계(중력 방향) 기반**으로 "아직 누움" 을 판정한다.
            // accelYRing 은 fallMonitorTick 이 매 틱 채우므로 모션 직후에도 최신 샘플을 보유한다.
            // **리뷰 MEDIUM (2026-05-31)**: 전체 ring 은 get-up 모션 중(수 초)의 동적 accelY 로
            // 오염될 수 있다(모션 중 임계 통과 → 가짜 "still fallen"). 모션 후 400ms settle 직후의
            // **최신 tail 샘플(suffix 8 ≈ 800ms)** 만 사용해 정상 정착값으로 판정한다.
            let (pitch, accelY, stillFallen) = await MainActor.run { () -> (Double, Int, Bool) in
                let p = self.imuPitchDeg
                let ay = self.store?.lastImuRaw.map { Int($0.accelY) }
                let recent = Array(self.accelYRing.suffix(8))
                let fallen: Bool
                if !recent.isEmpty {
                    fallen = AutoFallRecovery.isFallenAccelSustained(samples: recent) != nil
                } else if let ay {
                    fallen = AutoFallRecovery.detectFallFromAccel(accelYRaw: ay) != nil
                } else {
                    // 가속도 전무 시에만 pitch fallback (동결 위험 인지).
                    fallen = AutoFallRecovery.detectFall(pitchDeg: p) != nil
                }
                return (p, ay ?? -1, fallen)
            }
            // 진단: 검증에 쓰인 accelY/pitch/판정 기록 — pitch 동결 vs accel 실측 대조 가능.
            await MainActor.run {
                self.harness.record(
                    .recoveryGetUp, level: .info, actor: .robot,
                    data: ["phase_label": AnyCodable("verify"),
                           "verify_accelY": AnyCodable(accelY),
                           "verify_pitch_frozen": AnyCodable((pitch * 10).rounded() / 10),
                           "still_fallen_accel": AnyCodable(stillFallen),
                           "attempt": AnyCodable(self.autoRecoveryAttempts)]
                )
            }

            if stillFallen {
                // 아직 넘어진 상태 — 방향 재평가 후 재시도.
                // **C2 fix (2026-05-30)**: 종전 `pitch >= 0 ? .forward : .backward` 는 raw
                // imuPitchDeg 부호에 의존. 실 robot 컨벤션(forward-lean ≈ -20°) 과 반대라
                // 방향이 반전되어 잘못된 get-up 모션 실행 위험. ROBOTIS 공식 가속도계 기반
                // `detectFallFromAccel` 로 재평가. 가속도 데이터 없으면 마지막 방향 유지
                // (silent inversion 절대 금지).
                let newDir: AutoFallRecovery.FallDirection = await MainActor.run { [self] () -> AutoFallRecovery.FallDirection in
                    if let raw = self.store?.lastImuRaw,
                       let accelDir = AutoFallRecovery.detectFallFromAccel(accelYRaw: Int(raw.accelY)) {
                        return accelDir
                    }
                    // 가속도 데이터 없음 — 마지막 방향 유지 (inversion 금지).
                    return lastDirection
                }
                lastDirection = newDir
                await MainActor.run {
                    self.logSafetyEvent(
                        kind: .stateChange,
                        message: String(format: "자동 일어나기 재시도 — pitch %+.1f° 여전히 넘어짐, accel 기반 방향 재평가 (page %d)",
                                        pitch, newDir.getUpPage)
                    )
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            // [6] 성공 — walkReady idle 복귀
            let totalMs = Date().timeIntervalSince(fallDetectedAt) * 1000.0
            await MainActor.run {
                self.autoRecoveryPhase = .done
                self.autoRecoveryTask = nil
                // **FIX 3 (2026-05-31)**: 성공 종료 시각 기록 — 직후 재낙상 streak 추적용.
                self.recoveryDoneTimestamps.append(Date())
                // **M4 fix**: recovery 성공 후 accelYRing 초기화.
                // ring 에 낙하 중 수집된 samples 가 남아있으면 `isFallenAccelSustained` 가
                // .done 직후 false-positive 로 새 recovery 를 트리거 (~3s 편향).
                self.accelYRing.removeAll(keepingCapacity: true)
                self.logSafetyEvent(
                    kind: .recovery,
                    message: String(format: "자동 일어나기 성공 — pitch %+.1f°, 시도 %d회",
                                    pitch,
                                    self.autoRecoveryAttempts)
                )
                self.harness.record(
                    .recoveryDone, level: .notice, actor: .robot,
                    data: ["pitch_deg": AnyCodable(pitch),
                           "attempts": AnyCodable(self.autoRecoveryAttempts),
                           "settle_ms": AnyCodable(settleMs),
                           "recovery_total_ms": AnyCodable(totalMs)]
                )
                let outcome = FallTelemetryOutcome(
                    direction: lastDirection == .forward ? "forward" : "backward",
                    getUpPage: lastDirection.getUpPage,
                    settleMs: settleMs,
                    attempts: self.autoRecoveryAttempts,
                    success: true,
                    recoveryTotalMs: totalMs
                )
                self.fallTelemetryRecorder.finalizeOutcome(outcome)
                if self.store?.bus != nil { self.store?.startTelemetry(cadence: .light) }
                // 잠시 후 .done → .idle 전환 (UI 에 성공 표시 후 fade)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2초 표시
                    if self.autoRecoveryPhase == .done {
                        self.autoRecoveryPhase = .idle
                    }
                }
            }
            return
        }
    }

    // MARK: - M4 helper

    /// true = 최근 5초 이내에 pilot 명령이 있었음.
    ///
    /// M4 safety gate — emergencyStopActive 는 restoreTorqueAndPGain 의
    /// exitEmergencyMode() 로 조기 클리어될 수 있다. `lastPilotingAt` 은 클리어되지
    /// 않으므로 조종 직후 낙하 감지 5s window 를 안정적으로 보존한다.
    internal var recentlyPiloting: Bool {
        guard let t = lastPilotingAt else { return false }
        return Date().timeIntervalSince(t) < 5.0
    }

    // MARK: - Private helpers

    /// 자이로 정착 대기 — 최대 `settleTimeoutSec`.
    ///
    /// 100ms 간격으로 gyro 값을 read, `settleConsecutiveSamples` 연속 임계 미만이면 반환.
    /// 타임아웃 시 false 반환 (강제 진행).
    private func waitForSettle() async -> Bool {
        let deadline = Date().addingTimeInterval(AutoFallRecovery.settleTimeoutSec)
        var consecutiveSettled = 0

        while Date() < deadline {
            let (gx, gy) = await MainActor.run {
                let raw = self.store?.lastImuRaw
                return (raw?.gyroXDps ?? 0.0, raw?.gyroYDps ?? 0.0)
            }

            if AutoFallRecovery.isSettled(gyroXDps: gx, gyroYDps: gy) {
                consecutiveSettled += 1
                if consecutiveSettled >= AutoFallRecovery.settleConsecutiveSamples {
                    return true
                }
            } else {
                consecutiveSettled = 0
            }

            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms polling
        }

        return false  // timeout
    }

    /// 토크 ON + P_GAIN 복원.
    ///
    /// emergencyStop 이 활성 상태이면 `exitEmergencyMode()` 로 flag 클리어.
    /// bus.setDxlPower(true) + 각 관절 torque ON + P_GAIN=32 복원.
    /// `ConnectionStore.rePowerOnDxl` / `reTorqueOnAllJoints` / `reRestorePGains` 의
    /// 공개 진입점이 없으므로 동일 로직을 직접 구현 (bus 는 store 를 통해 접근).
    ///
    /// H1: 동시에 `ConnectionStore.recoverFromEStop` 이 진행 중(`isRecovering=true`)이면
    /// 두 write storm 이 인터리브되는 것을 방지한다. 최대 2초 대기 후 진행
    /// (데드락 없음 — 단방향 폴링, recoverFromEStop 이 완료되면 isRecovering → false).
    ///
    /// L1: 하체 관절 torque-on 실패 시 `false` 반환 — dead leg 액추에이터로 get-up 시도 금지.
    ///
    /// - Returns: `true` — 성공 (or best-effort). `false` — bus nil / dxl power 완전 실패 / 하체 torque 실패.
    private func restoreTorqueAndPGain() async -> Bool {
        // H1: ConnectionStore.recoverFromEStop 진행 중이면 최대 2초 대기.
        // isRecovering 은 @Published public private(set) — 읽기는 외부에서 가능.
        let recoveringPollDeadline = Date().addingTimeInterval(2.0)
        while Date() < recoveringPollDeadline {
            let recovering = await MainActor.run { self.store?.isRecovering ?? false }
            if !recovering { break }
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms 폴링
        }

        // emergencyStop flag 클리어
        await MainActor.run {
            if self.emergencyStopActive {
                self.exitEmergencyMode()
            }
        }

        // bus 접근 — store 에서 획득
        guard let bus = await MainActor.run(body: { self.store?.bus }) else {
            return false
        }

        // **C3 fix (2026-05-30)**: E-STOP 은 최우선. 각 bus-write phase 진입 전에
        // Task.isCancelled + emergencyStopActive 를 재확인. 루프 도중 E-STOP 이 발동하면
        // 즉시 false 반환 → runRecovery 가 .failed 로 처리. false 반환이 emergencyStop
        // 재호출을 트리거하지 않도록: emergencyStopActive=true 면 이미 처리된 것.

        // dxl power ON (3회 재시도)
        guard !Task.isCancelled else { return false }
        guard !(await MainActor.run { self.emergencyStopActive }) else { return false }
        var dxlOk = false
        for attempt in 0..<3 {
            do {
                try bus.setDxlPower(true)
                await MainActor.run { self.store?._setDxlPowerState(true) }
                dxlOk = true
                break
            } catch {
                if attempt < 2 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
        }
        guard dxlOk else { return false }

        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms power-up 정착

        // 하체 관절 집합 — bodyPart 기준 (WalkLabSession.lowerBodyJoints 와 동일 기준).
        let lowerBodyJoints = Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })

        // 모든 관절 torque ON.
        // C3: torque loop 전 E-STOP 재확인.
        // L1: 하체 관절 실패를 추적 — dead leg 로 get-up 금지.
        guard !Task.isCancelled else { return false }
        guard !(await MainActor.run { self.emergencyStopActive }) else { return false }
        var lowerBodyTorqueFailed = false
        for j in JointID.allCases {
            do {
                try bus.setTorque(j, enable: true)
            } catch {
                if lowerBodyJoints.contains(j) {
                    lowerBodyTorqueFailed = true
                }
            }
        }

        // L1: 하체 관절 torque 실패 → recovery failed (dead leg 로 get-up 시도 불가).
        if lowerBodyTorqueFailed {
            await MainActor.run {
                self.logSafetyEvent(
                    kind: .emergencyTriggered,
                    message: "자동 일어나기 중단 — 하체 관절 torque ON 실패. dead leg 로 get-up 금지."
                )
            }
            return false
        }

        // P_GAIN=32 복원 (MX-28T default). C3: setPGain loop 전 E-STOP 재확인.
        guard !Task.isCancelled else { return false }
        guard !(await MainActor.run { self.emergencyStopActive }) else { return false }
        for j in JointID.allCases {
            try? bus.setPGain(j, value: 32)
        }

        // **#1+#3 디커플·속도 (2026-06-01)**: get-up 모션이 Studio 의 "모션 속도"(joint
        // moving_speed 레지스터)에 영향받지 않도록 재생 직전 일괄 리셋 + 적정 속도 적용.
        //
        // 배경: forge-core 플레이어는 step 마다 goal 설정 후 play_ms 만큼 sleep 만 한다
        // (공식 ROBOTIS Action 처럼 8ms 보간/per-step 속도 계산을 하지 않음). 따라서 관절
        // 이동 속도는 **moving_speed 레지스터** 에 전적으로 의존한다.
        //   - moving_speed=0(최대) → 관절이 즉시 snap → "너무 빠름"(사용자 보고)
        //   - 적정 값 → step 시간 안에서 부드럽게 이동 (공식 모션 체감에 근접)
        // 공식 firmware 의 정확한 per-step 속도와 1:1은 아니지만(그건 forge-core 보간 필요),
        // snap 을 없애고 사용자 요청대로 ~10% 느린 부드러운 일어나기를 만든다. 튜닝 가능 상수.
        for j in JointID.allCases {
            try? bus.setMovingSpeed(j, speed: WalkLabSession.getUpMovingSpeed)
        }

        try? await Task.sleep(nanoseconds: 400_000_000)  // 400ms 정착

        return true
    }

    /// get-up 모션 재생 — `motionPlaySlot` blocking 완료 대기 + 정착 지연.
    ///
    /// `BusInterface.motionPlaySlot` 은 synchronous blocking. detached Task 안에서 호출하므로
    /// MainActor 를 블로킹하지 않는다. 반환은 get-up 동작 완료를 의미한다
    /// (= StatusCheck.cpp 의 "wait until IsRunning()==false" 에 해당).
    /// motionPlaySlot 반환 직후 400ms settle delay 를 추가하여, 방금 완료된 get-up 모션의
    /// 후반 관성이 tilt 재확인 결과에 영향을 주지 않도록 한다.
    /// isMotionPlaying polling 은 사용하지 않는다 — blocking 반환이 완료를 보장한다.
    ///
    /// **안전**: page 10 또는 11 만 허용. 다른 page 는 절대 금지.
    ///
    /// - Parameter page: get-up page 번호 (10=forward, 11=backward).
    /// - Returns: `true` — 재생 완료 + 정착. `false` — 오류.
    private func playGetUpMotion(page: UInt8) async -> Bool {
        // page 안전 가드 — 10 또는 11 이외 절대 거부
        guard page == 10 || page == 11 else {
            await MainActor.run {
                self.logSafetyEvent(
                    kind: .emergencyTriggered,
                    message: "자동 일어나기 — 잘못된 get-up page \(page). 10(f up)/11(b up) 만 허용. 중단."
                )
            }
            return false
        }

        // bus 는 BusInterface (synchronous). detached Task 안에서 blocking call OK.
        guard let bus = await MainActor.run(body: { self.store?.bus }) else {
            return false
        }

        // **H4 fix (2026-05-30)**: motionPlaySlot 은 수 초 동안 bus 를 blocking.
        // 진입 직전 Task.isCancelled + emergencyStopActive 를 재확인 — E-STOP 이
        // `waitForSettle` 이나 `restoreTorqueAndPGain` 사이에 발동했을 경우 차단.
        guard !Task.isCancelled else { return false }
        guard !(await MainActor.run { self.emergencyStopActive }) else { return false }

        do {
            // BusInterface.motionPlaySlot 은 synchronous blocking — get-up 완료까지 수 초 소요.
            // detached Task 안에서 호출하므로 MainActor 를 블로킹하지 않음.
            // followChain: false — 단일 page 만 실행 (chain 페이지 실수 방지).
            try bus.motionPlaySlot(
                slot: page,
                binPath: nil,
                dryRun: false,
                confirmRisk: true,
                singleFootOk: false,
                followChain: false,
                maxChainDepth: 10
            )
            // H2: motionPlaySlot 은 즉시 반환하지만 마지막 관성이 IMU 에 남아있다.
            // 400ms 정착 대기 — tilt 재확인이 모션 후반 스윙에 의해 오판되지 않도록.
            try? await Task.sleep(nanoseconds: 400_000_000)
            return true
        } catch {
            await MainActor.run {
                self.logSafetyEvent(
                    kind: .stateChange,
                    message: "자동 일어나기 모션 오류 page=\(page): \(error.localizedDescription)"
                )
            }
            return false
        }
    }

    // MARK: - Test entry points (DEBUG only)

    #if DEBUG
    /// **H3 테스트 진입점** — `playGetUpMotion` 의 `@testable` 래퍼.
    /// production 코드에서는 호출되지 않음 (DEBUG guard).
    internal func _testPlayGetUpMotion(page: UInt8) async -> Bool {
        await playGetUpMotion(page: page)
    }

    /// **H3 테스트 진입점** — `restoreTorqueAndPGain` 의 `@testable` 래퍼.
    /// production 코드에서는 호출되지 않음 (DEBUG guard).
    internal func _testRestoreTorqueAndPGain() async -> Bool {
        await restoreTorqueAndPGain()
    }
    #endif
}
