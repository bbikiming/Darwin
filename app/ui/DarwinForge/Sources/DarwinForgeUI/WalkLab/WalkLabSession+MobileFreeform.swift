import Foundation
import ForgeCore

/// iOS joystick freeform walking.
///
/// Preset walking starts a fixed continuous plan. Freeform walking keeps one
/// continuous motor task alive and reads the latest joystick-derived tuning
/// before every phase, so stick angle/distance changes are reflected without
/// repeatedly stopping to walkReady.
extension WalkLabSession {

    @discardableResult
    public func startOrUpdateMobileFreeform(tuning: WalkMotionLibrary.AdvancedTuning) -> Bool {
        guard !emergencyStopActive else { return false }
        // **자동 일어나기 우선 (이중 안전)** — recovery 진행 중에는 조종 보행을 시작·
        // 갱신하지 않는다. motorGate 차단이 1차 방어선이고, 본 guard 는 cockpit 외
        // 경로(bridge 등)로 들어와도 get-up 과 bus 경쟁이 없도록 보장한다.
        guard autoRecoveryPhase == .idle else { return false }

        // **온보드(SSH) 모드 (2026-06-01 버그 fix)**: 로봇 demo 가 보행을 수행하고 Mac 은
        // bus 가 없다. mac freeform walk cycle(startMobileFreeformCycle = bus 구동)을 돌리지
        // 않고, freeform tuning(strideMm/sideMm/turnDeg)만 갱신 → WalkLabOnboardBridge 가
        // 그 값을 serializedLine 으로 SSH(/tmp/df-walklab-cmd) 전송한다.
        // 종전: 아래 `onboardWalkingActive` guard(line ↓)가 freeform 을 "이미 걷는 중"으로
        // 차단 → strideMm 미갱신 → bridge 가 명령을 못 보냄 → 로봇이 안 움직였다(사용자 보고).
        if walkingEngine == .robotisOnboard {
            let clamped = WalkMotionLibrary.mobileFreeformClamp(tuning)
            let moving = clamped.strideMm != 0 || clamped.sideMm != 0 || clamped.turnDeg != 0
            // pilotIsWalking(=isActuallyWalking 은 onboardWalkingActive 포함) + bridge enabled
            // + currentWalkingEngineCommand freeform 분기 활성. stick zero 면 정지.
            onboardWalkingActive = moving
            mobileFreeformActive = moving
            applyMobileFreeformTuning(clamped)   // strideMm 등 set → bridge onChange → SSH
            return true
        }

        // **H2 — re-arm cancels smooth-return**: 새 보행 cycle spawn 前에 진행 중인
        // smooth walkReady return (smoothReturnTask) 을 즉시 중단. isMovingPoseCancelled=true
        // → applyPoseSmoothlyImpl 루프가 다음 100ms 체크포인트에서 .cancelled 반환.
        // 이 취소 없이 새 gait task 를 spawn 하면 두 Task 가 동시에 leg joint 에 write 하는
        // bus-contention 이 발생한다.
        // 단, 이미 mobileFreeformActive 이면 기존 Task 를 갱신하는 경우 — 취소 불필요.
        if !mobileFreeformActive {
            smoothReturnTask?.cancel()
            smoothReturnTask = nil
            store?.cancelMovingPose()
        }

        if !mobileFreeformActive,
           (isWalkActive || walkCycleTask != nil || onboardWalkingActive) {
            let activeLabel = activeRobotPreset?.label ?? current.label
            let f = WalkPreflightFailure(cause: .alreadyWalking(
                activePresetLabel: activeLabel,
                requestedLabel: "자유 조종"
            ))
            lastPreflightFailure = f
            startBlockedReason = f.diagnosticCode
            lastRobotEvent = f.userMessage
            return false
        }

        let clamped = WalkMotionLibrary.mobileFreeformClamp(tuning)
        applyMobileFreeformTuning(clamped)

        if mobileFreeformActive, walkCycleTask != nil {
            return true
        }

        return startMobileFreeformCycle()
    }

    private func applyMobileFreeformTuning(_ tuning: WalkMotionLibrary.AdvancedTuning) {
        // M4: stamp "recently piloting" latch — 낙하 감지 gate 에서 5s 이내 true 반환.
        lastPilotingAt = Date()
        mobileFreeformTuning = tuning
        if !advanced { advanced = true }
        strideMm = tuning.strideMm
        sideMm = tuning.sideMm
        turnDeg = tuning.turnDeg
        customPeriodMs = tuning.periodMs
        footHeightMm = tuning.footHeightMm
        balanceGain = tuning.balanceGain
        hipPitchOffsetTrimDeg = tuning.hipPitchOffsetDeg
        if mobileFreeformActive || walkCycleTask != nil {
            // Fix #2: 30Hz onChange 폭풍 — 이전과 동일 값이면 engine.setCommand skip.
            // .stop(stride/side/turn 모두 0) 전환은 delta 관계없이 항상 적용 (auto-disarm 보장).
            let isStop = tuning.strideMm == 0 && tuning.sideMm == 0 && tuning.turnDeg == 0
            let shouldSkip: Bool
            if isStop {
                shouldSkip = false   // stop 전환: 반드시 적용
            } else if let prev = _lastAppliedFreeformTuning {
                let strideOk  = abs(tuning.strideMm  - prev.strideMm)  < 0.5
                let sideOk    = abs(tuning.sideMm    - prev.sideMm)    < 0.5
                let turnOk    = abs(tuning.turnDeg   - prev.turnDeg)   < 0.3
                let periodOk  = abs(tuning.periodMs  - prev.periodMs)  < 2.0
                shouldSkip = strideOk && sideOk && turnOk && periodOk
            } else {
                shouldSkip = false   // 첫 번째 적용은 항상 전송
            }

            if !shouldSkip {
                _lastAppliedFreeformTuning = tuning
                engine.setCommand(
                    x: tuning.strideMm / 1000.0,
                    y: tuning.sideMm / 1000.0,
                    a: tuning.turnDeg * .pi / 180.0,
                    enabled: true
                )
                engine.setPeriodMs(tuning.periodMs)
            }
        } else {
            // 보행 미시작 — 캐시 초기화 (다음 보행 첫 적용에서 반드시 전송).
            _lastAppliedFreeformTuning = nil
        }
    }

    private func startMobileFreeformCycle() -> Bool {
        let preset: WalkLabPreset = .slowWalk
        requestedPreset = preset

        if startGuardEmergency(preset) { return false }
        if startCheckQuickPreflight(preset) { return false }
        lastPreflightFailure = nil
        startBlockedReason = nil

        startLogOnboardWarnings()
        startCaptureImuSnapshot()
        captureTrialStart(preset: preset)
        startResetSessionState(preset)
        startScheduleTickLoop()

        guard let (store, bus) = swcResolveStoreAndCradle(preset) else { return false }
        swcApplySafetyDemotion()
        if swcGuardHardwarePreflight(preset, store: store, bus: bus) { return false }

        current = preset
        if let tuning = mobileFreeformTuning {
            engine.setCommand(
                x: tuning.strideMm / 1000.0,
                y: tuning.sideMm / 1000.0,
                a: tuning.turnDeg * .pi / 180.0,
                enabled: true
            )
            engine.setPeriodMs(tuning.periodMs)
        }
        swcApplyAutoTuningLevel()
        swcApplyAutoTuningStability()
        cycleStartedAt = Date()
        // Baseline-aware gyro (P-control path): reset so next tick seeds baseline fresh.
        balanceBaselineInitialized = false
        swcInitSessionLogger(preset)
        let (onPose, transformPose) = swcMakePoseCallbacks()
        spawnMobileFreeformTask(
            bus: bus,
            store: store,
            onPose: onPose,
            transformPose: transformPose
        )
        return true
    }

    private func spawnMobileFreeformTask(
        bus: any BusInterface,
        store: ConnectionStore,
        onPose: @escaping @MainActor @Sendable (RobotPose) -> Void,
        transformPose: @escaping @MainActor @Sendable (RobotPose) -> RobotPose
    ) {
        let prev = walkCycleTask
        let lowerBody = Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })

        isRobotWalking = true
        mobileFreeformActive = true
        store.imuFastPollActive = true
        activeRobotPreset = .slowWalk
        motorWriteStarted = false
        motorWriteStepCount = 0
        lastRobotEvent = "🤖 iOS 자유 조종 시작"
        harness.record(
            .walkLabStart, level: .notice, actor: .user,
            data: ["preset": AnyCodable("mobileFreeform"),
                   "engine": AnyCodable(String(describing: walkingEngine)),
                   "advanced": AnyCodable(true),
                   "mode": AnyCodable("mobileFreeform")]
        )

        walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await prev?.value
            let result = await Self.runMobileFreeformWalk(
                bus: bus,
                maxDurationSec: WalkLabPreset.slowWalk.maxDurationSec,
                lowerBodyJoints: lowerBody,
                tuningProvider: { [weak self] in
                    guard let self else { return nil }
                    return await self.mobileFreeformTuningSnapshot()
                },
                // Fix #1: headProvider — sendStep 다리 write 완료 직후 pending 머리 raw 소비.
                // 동일 step 내 동기 블록에서 실행되므로 다리+머리가 직렬화됨 (인터리브 없음).
                headProvider: { [weak self] in
                    guard let self else { return nil }
                    return await self.pendingHeadSnapshot()
                },
                onPose: onPose,
                transformPose: transformPose,
                isBusAlive: { [weak self] in
                    guard let self else { return false }
                    return await self.isBusAliveSnapshot()
                },
                isHardStopped: { [weak self] in
                    guard let self else { return true }
                    // C1b: recovery 진행 중에도 write 를 차단 — emergencyStopActive 가
                    // restoreTorqueAndPGain 의 exitEmergencyMode() 로 일찍 해제되더라도
                    // walk task 마지막 sendStep 이 get-up 중에 착지하지 않도록 방어.
                    return await MainActor.run { self.emergencyStopActive || self.autoRecoveryPhase != .idle }
                },
                onBusWriteFailure: { [weak self] in
                    self?.store?._bumpBusWriteFailureCount()
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRobotWalking = false
                self.store?.imuFastPollActive = false
                self.activeRobotPreset = nil
                self.mobileFreeformActive = false
                self.mobileFreeformTuning = nil
                // **냉정 점검 HIGH fix (4.8)**: maxDurationSec 등으로 task 가 스스로
                // 종료될 때 `current`/`walkCycleTask` 를 reset 하지 않으면
                // `isActuallyWalking` (current != .idle || walkCycleTask != nil) 가
                // 잔존 true → cockpit re-ARM 이 `startOrUpdateMobileFreeform` 의
                // alreadyWalking 가드에 영구 차단 (60초 time bomb). 본 task 가 곧
                // 닫히므로 (closure 마지막) self 참조 nil 화는 안전 — 다음 start 의
                // `await prev?.value` 는 nil → 즉시 통과.
                self.current = .idle
                self.walkCycleTask = nil
                // **M-pendingHead-clear fix (2026-05-30)**: walk 종료 시 stale head raw 제거.
                // pendingHeadPanRaw/TiltRaw 가 nil 되지 않으면 다음 walk 의 첫 sendStep 이
                // 이전 walk 에서 마지막으로 버퍼된 머리 raw 값을 flush → 갑작스러운 머리 움직임.
                self.pendingHeadPanRaw = nil
                self.pendingHeadTiltRaw = nil
                self.lastCycleResult = result
                self.lastRobotEvent = result.isSuccess
                    ? "✅ 자유 조종 종료 — walkReady 복귀"
                    : "🛑 \(result.userMessage) (자유 조종)"
                // **로그 갭 수정 (2026-05-31, 검증)**: 콕핏 스틱/자유 조종이 maxDuration 으로
                // 자동 종료되면 종전엔 finalizeSessionLog 만 호출 → **WalkTrial 미기록**(가장
                // 풍부한 실험 레코드 유실). 명시 stop() 경로만 trial 을 finalize 했었다.
                // → 자동 종료에도 trial 을 확정(idempotent)해, 콕핏에서 테스트한 걸음 로직이
                //   trials/ 에 engine/balance/preset+outcome 으로 남아 비교 가능해진다.
                self.finalizeTrialIfPending(endReason: .maxDuration)
                self.finalizeSessionLog()
            }
        }
    }

    @MainActor
    private func mobileFreeformTuningSnapshot() -> WalkMotionLibrary.AdvancedTuning? {
        mobileFreeformTuning
    }

    internal static func runMobileFreeformWalk(
        bus: any BusInterface,
        maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        tuningProvider: @escaping @Sendable () async -> WalkMotionLibrary.AdvancedTuning?,
        // Fix #1: pending head provider — 다리 write 루프 완료 직후 head raw 를 읽고 nil 로 초기화.
        // nil 반환 = 이 step 에서 머리 변화 없음 → write 생략.
        headProvider: (@Sendable () async -> (pan: Int, tilt: Int)?)? = nil,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil,
        transformPose: (@MainActor @Sendable (RobotPose) -> RobotPose)? = nil,
        isBusAlive: @Sendable () async -> Bool = { true },
        isHardStopped: @Sendable () async -> Bool = { false },
        onBusWriteFailure: (@MainActor @Sendable () -> Void)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0
        var perJointFailsLocal: [JointID: Int] = [:]

        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: 256) }
            catch {
                speedFailures += 1
                if let cb = onBusWriteFailure { Task { @MainActor in cb() } }
                sampleError = "\(joint.name) 목표 속도 전송: \(error.localizedDescription)"
            }
        }

        var previous: RobotPose = .walkReady
        let endDate = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false
        var phaseIndex = 0

        func sendStep(_ step: MotionStep, previousIn: RobotPose) async -> RobotPose {
            let rawTarget = step.toPose()
            let target: RobotPose
            if let transformPose {
                target = await transformPose(rawTarget)
            } else {
                target = rawTarget
            }
            if let onPose { await onPose(target) }
            if await isHardStopped() { return previousIn }

            // Phase 1 SYNC_WRITE batching: build targets array from changed joints,
            // then append head target so legs + head go in ONE SYNC_WRITE packet.
            var changedTargets: [(JointID, UInt16)] = target.changedJoints(from: previousIn)
                .map { ($0, UInt16(clamping: target.raw($0))) }

            // Fix #1: collect pending head target BEFORE issuing the batch write,
            // so head is in the same SYNC_WRITE packet as the legs.
            // isHardStopped() re-check guards head write during emergency (torque OFF).
            var headTargetForBatch: (pan: Int, tilt: Int)? = nil
            if let hp = headProvider, !(await isHardStopped()) {
                headTargetForBatch = await hp()
                if let ht = headTargetForBatch {
                    changedTargets.append((.headPan,  UInt16(clamping: ht.pan)))
                    changedTargets.append((.headTilt, UInt16(clamping: ht.tilt)))
                }
            }

            if !changedTargets.isEmpty && !Task.isCancelled {
                // SYNC_WRITE 1 packet — no per-servo status return.
                // Retry once on transport failure (mirrors prior per-joint retry logic).
                var lastErr: Error?
                for attempt in 0..<2 {
                    do {
                        try bus.setPositions(changedTargets)
                        lastErr = nil
                        break
                    } catch {
                        lastErr = error
                        if attempt == 0 {
                            try? await Task.sleep(nanoseconds: Self.setPositionRetryBackoffNs)
                        }
                    }
                }
                if let err = lastErr {
                    // Transport failure: escalate as if lower-body write failed.
                    // SYNC_WRITE has no per-servo status, so all changed leg joints
                    // are conservatively marked as failed. Per-servo liveness moves
                    // to Phase 2 (BULK_READ periodic read).
                    positionFailures += 1
                    if let cb = onBusWriteFailure { Task { @MainActor in cb() } }
                    sampleError = "배치 위치 전송 실패: \(err.localizedDescription)"
                    for (joint, _) in changedTargets {
                        if lowerBodyJoints.contains(joint) {
                            lowerBodyPositionFails.insert(joint)
                        }
                        perJointFailsLocal[joint, default: 0] += 1
                    }
                } else {
                    // Success: clear per-joint failure counters for all sent joints.
                    for (joint, _) in changedTargets {
                        perJointFailsLocal[joint] = 0
                    }
                }
            }

            let totalMs = max(80, step.playMs + step.pauseMs)
            try? await Task.sleep(nanoseconds: UInt64(totalMs) * 1_000_000)
            return target
        }

        guard let firstTuning = await tuningProvider(),
              let firstPlan = WalkMotionLibrary.freeformContinuousWalkPlan(tuning: firstTuning) else {
            return WalkCycleResult(
                reason: .userCancelled,
                stepsExecuted: stepsExecuted,
                speedWriteFailures: speedFailures,
                positionWriteFailures: positionFailures,
                lowerBodyPositionFails: Array(lowerBodyPositionFails),
                sampleError: "freeform tuning unavailable"
            )
        }

        entryLoop: for step in firstPlan.entry {
            if Task.isCancelled { cancelledMidStep = true; break entryLoop }
            if !(await isBusAlive()) {
                endReason = .busDisconnected
                break entryLoop
            }
            previous = await sendStep(step, previousIn: previous)
            stepsExecuted += 1
        }

        if endReason == .completedMaxDuration && !cancelledMidStep {
            cycleLoop: while !Task.isCancelled {
                if let end = endDate, Date() >= end { break cycleLoop }
                guard let tuning = await tuningProvider(),
                      let plan = WalkMotionLibrary.freeformContinuousWalkPlan(tuning: tuning),
                      !plan.cycle.isEmpty else {
                    endReason = .userCancelled
                    break cycleLoop
                }
                if !(await isBusAlive()) {
                    endReason = .busDisconnected
                    break cycleLoop
                }
                let step = plan.cycle[phaseIndex % plan.cycle.count]
                phaseIndex += 1
                previous = await sendStep(step, previousIn: previous)
                stepsExecuted += 1

                if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit }) {
                    sampleError = "단일 모터 \(Self.perJointConsecutiveFailureLimit)회 연속 응답 없음 — hardware 확인"
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                if positionFailures > max(10, JointID.allCases.count) {
                    endReason = .bulkWriteFailure
                    break cycleLoop
                }
            }
        }

        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        if await isHardStopped() {
            return WalkCycleResult(
                reason: .userCancelled,
                stepsExecuted: stepsExecuted,
                speedWriteFailures: speedFailures,
                positionWriteFailures: positionFailures,
                lowerBodyPositionFails: Array(lowerBodyPositionFails),
                sampleError: "emergencyStop — exit phase 스킵 (torque OFF 보호)"
            )
        }

        if let exitTuning = await tuningProvider(),
           let exitPlan = WalkMotionLibrary.freeformContinuousWalkPlan(tuning: exitTuning) {
            for step in exitPlan.exit {
                previous = await sendStep(step, previousIn: previous)
                stepsExecuted += 1
            }
        }

        return WalkCycleResult(
            reason: endReason,
            stepsExecuted: stepsExecuted,
            speedWriteFailures: speedFailures,
            positionWriteFailures: positionFailures,
            lowerBodyPositionFails: Array(lowerBodyPositionFails),
            sampleError: sampleError
        )
    }
}

extension WalkMotionLibrary {
    /// 회전 가속 floor — 풀스틱 회전 시 보행주기 하한 (2026-06-02 "공격적" 채택).
    /// fastWalk 프리셋(450ms)이 이미 실기 검증된 "공식 모션 선" 안의 값.
    public static let turnBoostMinPeriodMs: Double = 450
    /// 회전 가속이 적용되기 시작하는 스틱 데드밴드 — 살짝 꺾은 미세 회전은 base 유지.
    public static let turnBoostDeadbandDeg: Double = 2
    /// 회전각 클램프 한계 (관절 충돌 임계). 가속은 이 각을 넘기지 않고 주기로만 한다.
    public static let mobileFreeformMaxTurnDeg: Double = 12

    /// 회전 가속 (각도 불변, 주기 단축).
    ///
    /// 회전 속도 = |turnDeg| ÷ periodMs. turnDeg(=hip-yaw 관절각)을 키우면 60° 안전선을
    /// 넘겨 무릎·엉덩이가 충돌하므로(±12° 고정), **주기만 단축**해 같은 각도로 더 빠르게 돈다.
    /// - 저속(작은 스틱, |turnDeg| ≤ 데드밴드): `basePeriodMs` 유지 → 최저 회전속도 보존.
    /// - 풀스틱(|turnDeg| ≥ maxTurnDeg): `minPeriodMs` 까지 선형 단축 → 최고 회전속도 ↑.
    ///
    /// 직진/횡이동만(turnDeg≈0)일 땐 base 그대로라 전진 속도엔 영향 없음.
    public static func turnBoostedPeriodMs(
        turnDeg: Double,
        basePeriodMs: Double,
        minPeriodMs: Double = turnBoostMinPeriodMs,
        maxTurnDeg: Double = mobileFreeformMaxTurnDeg,
        turnDeadbandDeg: Double = turnBoostDeadbandDeg
    ) -> Double {
        let mag = abs(turnDeg)
        guard mag > turnDeadbandDeg, basePeriodMs > minPeriodMs else { return basePeriodMs }
        let span = max(0.001, maxTurnDeg - turnDeadbandDeg)
        let t = min(1.0, max(0.0, (mag - turnDeadbandDeg) / span))
        return basePeriodMs + (minPeriodMs - basePeriodMs) * t
    }

    public static func mobileFreeformClamp(_ base: AdvancedTuning) -> AdvancedTuning {
        // 회전각은 ±12° 로 고정 (관절 충돌 차단) — 속도는 주기 단축으로만 올린다.
        let turn = base.turnDeg.clamped(to: -mobileFreeformMaxTurnDeg...mobileFreeformMaxTurnDeg)
        // 회전 가속: 스틱 회전량에 비례해 base 주기(600~850)를 floor(450)까지 단축.
        // turn=0 이면 base 그대로 → 최저값 보존 + 직진 보행엔 영향 없음.
        let basePeriod = base.periodMs.clamped(to: 600...850)
        let boostedPeriod = turnBoostedPeriodMs(turnDeg: turn, basePeriodMs: basePeriod)
        return AdvancedTuning(
            strideMm: base.strideMm.clamped(to: -30...38),
            sideMm: base.sideMm.clamped(to: -22...22),
            // -18 → -12 보수화: 고각 회전 시 hip-yaw + cMove 가 60° 안전 임계를
            // 넘겨 무릎·엉덩이가 겹치던 문제 방지 (cockpitTurnDeg 와 동일 한계).
            turnDeg: turn,
            // floor 를 450 까지 허용 — turnBoostedPeriodMs 산출치를 재클램프하지 않도록.
            periodMs: boostedPeriod.clamped(to: turnBoostMinPeriodMs...850),
            footHeightMm: base.footHeightMm.clamped(to: 28...46),
            balanceGain: base.balanceGain.clamped(to: 0.8...1.4),
            hipPitchOffsetDeg: base.hipPitchOffsetDeg.clamped(to: 0...20)
        )
    }
}
