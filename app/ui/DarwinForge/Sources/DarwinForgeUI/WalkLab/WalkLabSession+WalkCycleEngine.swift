import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 90: god object Phase 4 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` 의 walk cycle 실제 송출 static engine 2개 (~412 line) 를 본
/// extension 으로 이동. 두 method 모두 **이미 `private static`** — pure async, `self`
/// capture 0. Phase 4 plan 의 가장 안전한 분할 후보.
///
/// # 비유
///
/// 거대한 도서관의 "주조소 (foundry)" — 실제 모터를 두드리는 거대 작업장. 본 도서관의
/// 카운터 (instance state) 와 무관하게 독립 가동. 사이클 89 의 "보고서 코너" 와 달리
/// 본 작업장은 state 의존이 0 이라 통째로 별관 이전. 도서관 본관에서는 별관 호출만 잔존
/// (`Self.runContinuousWalk(...)` / `Self.runWalkCycle(...)`).
///
/// # 분할 정책
///
/// - **`private static` → `internal static` 격상**: extension 의 별도 file 에서도 호출
///   가능. module 외부에는 노출 안 됨 (`internal` 유지).
/// - 호출 site (`startWalkCycle` 본체) 는 변경 0 — `Self.runContinuousWalk(...)` 그대로.
/// - constants (`setPositionRetryBackoffNs` / `lowerBodyDistinctFailureThreshold` /
///   `perJointConsecutiveFailureLimit`) 는 이미 `public static` — 추가 격상 불필요.
/// - **`cancelWalkCycle` (instance method) 는 본체 잔존**: `walkCycleTask` 등 instance
///   state mutate. static method 와 분리.
///
/// # 회귀
///
/// 1267 tests 회귀 0 — `Self.` prefix 동일 type 내부 호출이라 외부 contract 변경 0.
extension WalkLabSession {

    /// **Phase G10 (2026-05-15)** — 연속 보행 실제 송출 루프.
    ///
    /// 한 cycle 끝마다 walkReady 자세로 돌아가지 않고 phase[5] → phase[0] 으로 직접
    /// 이어붙임. 사용자 체감: 끊김 없는 자연스러운 보행.
    ///
    /// 흐름:
    ///   1. moving speed 설정 (1회).
    ///   2. **entry** step 송출 (walkReady → phase[0] 전환, longer playMs).
    ///   3. **cycle** step 무한 반복:
    ///      - 6 phase 송출 (anchor 없음)
    ///      - phase[5] 끝나면 다음 iter 의 phase[0] 으로 자연 wrap
    ///        (모터 trapezoidal motion 이 playMs 안에서 보간)
    ///      - cancel / maxDuration / 하체 통신 실패 시 break.
    ///   4. **exit** step — walkReady 안전 복귀.
    internal static func runContinuousWalk(
        bus: any BusInterface, plan: WalkMotionLibrary.ContinuousWalkPlan, maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        // **D1 (2026-06-12)**: 시간 기반 50Hz 연속 스트리밍 모드. true + denseTuning
        // 비-nil 이면 cycle 단계를 6 키프레임 대신 step(=denseInterval)마다
        // robotisWalkingApproxPose(timeMs:) 직접 평가로 흘려보낸다(StepDeadlineScheduler
        // 로 20ms 지터 보상). entry/exit 는 키프레임 그대로(전환 안전). 기본 false →
        // 종전 동작 100% 보존. denseTuning 은 프리셋 고정 진폭(래치가 즉시 at-target).
        denseStreaming: Bool = false,
        denseTuning: WalkMotionLibrary.AdvancedTuning? = nil,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil,
        transformPose: (@MainActor @Sendable (RobotPose) -> RobotPose)? = nil,
        // 2026-05-17 chaos #1 fix: store.bus 가 nil (disconnect) 됐는지 매 step
        // 시작 전 체크. true 면 정상, false 면 즉시 .busDisconnected 로 abort.
        isBusAlive: @Sendable () async -> Bool = { true },
        // v1.11.22.1 (Codex HIGH-1 fix): emergencyStop 진행 시 true. exit phase 스킵.
        // 토크 OFF 이후 walkReady setPosition race 차단.
        isHardStopped: @Sendable () async -> Bool = { false },
        // v1.11.1 MEDIUM-5: bus write 실패 callback (ConnectionStore 누적).
        onBusWriteFailure: (@MainActor @Sendable () -> Void)? = nil,
        // V288-2: Hexagonal architecture port — dxlPower gate 강제.
        // 모든 joint write 의 공식 entry — DXL power gate 가 자동 차단.
        // nil 이면 기존 bus.setPosition 직접 호출 (하위 호환 유지).
        robotPort: (any RobotPort)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0
        // **Wave 2 (2026-06-11) io-timeout 상한** — 보행 동안 bus read timeout 을
        // walkIoTimeoutMs(50ms)로 낮춰 직렬화 락 보유 상한을 줄이고, 정상/취소/하드스톱
        // 등 모든 종료 경로에서 defer 로 원복한다. exit walkReady 복귀·emergencyStop 은
        // SYNC_WRITE/torque-off write(응답 read 없음)라 낮은 timeout 의 영향을 받지 않는다.
        let restoreIoTimeoutMs = bus.configuredIoTimeoutMs
        bus.setIoTimeout(ms: Self.walkIoTimeoutMs)
        defer { bus.setIoTimeout(ms: restoreIoTimeoutMs) }
        // v1.8 (10x review Major #1): per-joint consecutive failure counter (local, static-safe).
        var perJointFailsLocal: [JointID: Int] = [:]
        // **L5 (2026-06-11)**: liveness 프로브 상태 — SYNC_WRITE 는 죽은 서보가 오류를
        // 안 내므로 step 마다 하체 관절 1개 라운드로빈 PING. 연속 실패 카운터는
        // 배치 write 성공과 무관한 별도 dict (write 성공이 프로브 실패를 지우면 안 됨).
        var probeFailsLocal: [JointID: Int] = [:]
        var probeIndex = 0
        let probeJoints = lowerBodyJoints.sorted { $0.rawValue < $1.rawValue }

        // **D1 (2026-06-12)**: 시간 기반 모드 상태. stepDeadline 은 StepDeadlineScheduler
        // 의 직전 발화 목표 시각(20ms 케이던스 지터 보상, D0 재사용).
        var stepDeadline: ContinuousClock.Instant? = nil

        // 1. moving speed 설정 (1회) — L5: 관절별 개별 write 20회 → SYNC_WRITE 1패킷.
        let cycleSpeed: UInt16 = 256
        do { try bus.setMovingSpeeds(JointID.allCases, speed: cycleSpeed) }
        catch {
            speedFailures += 1
            // v1.11.2 (사용자 review P2-A): setMovingSpeed 실패도 callback.
            if let cb = onBusWriteFailure {
                Task { @MainActor in cb() }
            }
            sampleError = "목표 속도 일괄 전송: \(error.localizedDescription)"
        }

        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        // 한 step 송출 helper — closure 캡처 X (concurrency 안전).
        //
        // **L5 (2026-06-11) SYNC_WRITE 전환**: 종전 관절별 개별 setPosition(+status
        // 왕복, TCP step당 12회 ≈ 36-72ms)을 setPositions 1패킷으로. per-joint status
        // 가 사라지므로 (a) transport 실패는 배치 내 하체 관절 전체 실패로 보수적
        // 매핑, (b) 죽은 서보 감지는 step 말미 liveness PING 라운드로빈으로 대체.
        //
        // **D1 (2026-06-12)**: `denseInterval` 비-nil 이면 시간 기반 모드 —
        //   · sleep 을 고정값 대신 StepDeadlineScheduler(20ms) 로(지터 보상),
        //     playMs≥80 하한 미적용(시간 모드는 period≥440 클램프가 대체).
        //   · `allowPing` 으로 liveness PING 을 시간 1Hz 로 게이팅(매 step → 1Hz).
        func sendStep(_ step: MotionStep, previousIn: RobotPose,
                      denseInterval: Int? = nil, allowPing: Bool = true) async -> RobotPose {
            let rawTarget = step.toPose()
            // **Stage 4b (v1.1 fall prevention, 2026-05-16)**: IMU 기반 corrector
            // 적용 — 호출자가 `transformPose` 로 `applyBalanceCorrectionIfEnabled`
            // 전달. nil 이면 identity (기존 동작).
            let target: RobotPose
            if let transformPose {
                target = await transformPose(rawTarget)
            } else {
                target = rawTarget
            }
            // **Phase G11**: 3D 모델 갱신 — main actor 로 publish (실 로봇 송출 전에).
            if let onPose {
                await onPose(target)
            }
            // **v1.11.22.1 (Codex new HIGH)**: step entry 시 hard-stop check —
            // emergencyStop 진행 중이면 step 송출 전체 skip (torque OFF 후
            // joint write race 차단).
            if await isHardStopped() { return previousIn }
            let changed = target.changedJoints(from: previousIn)
            if !changed.isEmpty && !Task.isCancelled {
                let targets = changed.map { ($0, UInt16(clamping: target.raw($0))) }
                var lastErr: Error?
                for attempt in 0..<2 {
                    do {
                        // V288-2: robotPort 경유 → dxlPower gate 자동 강제.
                        if let port = robotPort {
                            try await port.writeJointPositions(
                                Dictionary(uniqueKeysWithValues: targets))
                        } else {
                            try bus.setPositions(targets)
                        }
                        lastErr = nil
                        break
                    } catch let portErr as RobotPortError where portErr == .dxlPowerOff {
                        // dxlPower OFF gate 차단 — e-stop chain 실행 후 실패 기록.
                        await robotPort?.emergencyStop()
                        lastErr = portErr
                        break   // retry 무의미 — power OFF 는 즉시 중단.
                    } catch {
                        lastErr = error
                        if attempt == 0 {
                            try? await Task.sleep(nanoseconds: Self.setPositionRetryBackoffNs)
                        }
                    }
                }
                if let err = lastErr {
                    positionFailures += 1
                    // v1.11.1 MEDIUM-5: bus write 실패 callback.
                    if let cb = onBusWriteFailure {
                        Task { @MainActor in cb() }
                    }
                    sampleError = "step 일괄 위치 전송 (\(changed.count)관절): \(err.localizedDescription)"
                    // 보수적 매핑: 배치 transport 실패 = 배치 내 하체 관절 전체 실패.
                    for joint in changed where lowerBodyJoints.contains(joint) {
                        lowerBodyPositionFails.insert(joint)
                        perJointFailsLocal[joint, default: 0] += 1
                    }
                } else {
                    // 성공 시 batch 관절 counter reset (one-off transient 흡수).
                    for joint in changed { perJointFailsLocal[joint] = 0 }
                }
            }
            // **L5 liveness 프로브** — bus 직결 경로 전용 (robotPort mock 경로 제외).
            // SYNC_WRITE 무응답을 보상: step 마다 하체 관절 1개 PING (~1ms).
            // D1: 시간 모드는 allowPing 으로 1Hz 게이팅(매 step → 50Hz PING 은 예산 낭비).
            if allowPing, robotPort == nil, !probeJoints.isEmpty, !Task.isCancelled,
               !(await isHardStopped()) {
                let probe = probeJoints[probeIndex % probeJoints.count]
                probeIndex += 1
                do {
                    try bus.ping(id: probe.rawValue)
                    probeFailsLocal[probe] = 0
                } catch {
                    probeFailsLocal[probe, default: 0] += 1
                    lowerBodyPositionFails.insert(probe)
                    sampleError = "\(probe.name) liveness 무응답: \(error.localizedDescription)"
                }
            }
            // D1: 시간 모드(denseInterval)는 deadline 스케줄러로 20ms 케이던스 유지(80ms
            // 하한 미적용). 키프레임 모드는 종전 고정 sleep(max(80,...)).
            if let denseInterval {
                let wake = StepDeadlineScheduler.next(previous: stepDeadline, now: .now, stepMs: denseInterval)
                stepDeadline = wake
                try? await Task.sleep(until: wake, clock: .continuous)
            } else {
                let totalMs = max(80, step.playMs + step.pauseMs)
                let ns = UInt64(totalMs) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
            return target
        }

        // liveness 프로브 연속 실패 → hardware fault 판정 helper.
        func probeFault() -> Bool {
            probeFailsLocal.contains { $0.value >= Self.livenessProbeFailureLimit }
        }

        // 2. Entry — walkReady → phase[0] (1회만).
        entryLoop: for step in plan.entry {
            if Task.isCancelled { cancelledMidStep = true; break entryLoop }
            if !(await isBusAlive()) {
                endReason = .busDisconnected
                break entryLoop
            }
            previous = await sendStep(step, previousIn: previous)
            stepsExecuted += 1
            if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                endReason = .lowerBodyWriteFailure
                break entryLoop
            }
            if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit })
                || probeFault() {
                endReason = .lowerBodyWriteFailure
                break entryLoop
            }
        }

        // 3. Cycle — 시간 기반(50Hz) 또는 6 키프레임 무한 반복.
        if endReason == .completedMaxDuration && !cancelledMidStep && lowerBodyPositionFails.count < Self.lowerBodyDistinctFailureThreshold {
            if denseStreaming, let denseTuning {
                // **D1 시간 기반 스트리밍** — 같은 연속 함수를 step(20ms)마다 직접 평가.
                // 버스 예산(1Mbps): SYNC_WRITE 12관절 2.7% + IMU 1.6% + PING 0.02% ≈ 4.3%
                // (D2 의 FSR 10Hz 1.2% 포함 ~5–6%) — 여유.
                let denseInterval = WalkDenseStreaming.effectiveStepMs()
                let cycleStart = ContinuousClock.now
                // 프리셋 고정 진폭이라 latch 를 즉시 at-target 으로 초기화(슬루 지연 0).
                var latch = WalkAmplitudeLatch(initial: denseTuning)
                var lastPingElapsedMs: Double = -WalkDenseStreaming.denseLivenessPingIntervalMs
                denseCycle: while !Task.isCancelled {
                    if let end = endDate, Date() >= end { break denseCycle }
                    if !(await isBusAlive()) {
                        endReason = .busDisconnected
                        break denseCycle
                    }
                    let elapsedMs = cycleStart.duration(to: .now).inMilliseconds
                    latch.advance(elapsedMs: elapsedMs, target: denseTuning)
                    let tCycle = WalkDenseStreaming.cycleTimeMs(
                        elapsedMs: elapsedMs, periodMs: latch.committed.periodMs)
                    let pose = WalkDenseStreaming.pose(atCycleMs: tCycle, tuning: latch.committed)
                    let denseStep = MotionStep.from(pose: pose, playMs: denseInterval, pauseMs: 0)
                    // liveness PING 을 시간 1Hz 로 게이팅.
                    let pingDue = (elapsedMs - lastPingElapsedMs) >= WalkDenseStreaming.denseLivenessPingIntervalMs
                    if pingDue { lastPingElapsedMs = elapsedMs }
                    previous = await sendStep(denseStep, previousIn: previous,
                                              denseInterval: denseInterval, allowPing: pingDue)
                    stepsExecuted += 1

                    if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                        endReason = .lowerBodyWriteFailure
                        break denseCycle
                    }
                    if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit })
                        || probeFault() {
                        sampleError = sampleError ?? "단일 모터 연속 응답 없음 — hardware 확인"
                        endReason = .lowerBodyWriteFailure
                        break denseCycle
                    }
                    if positionFailures > max(10, JointID.allCases.count) {
                        endReason = .bulkWriteFailure
                        break denseCycle
                    }
                }
            } else {
                cycleLoop: while !Task.isCancelled {
                    if let end = endDate, Date() >= end { break cycleLoop }
                    for step in plan.cycle {
                        if Task.isCancelled { cancelledMidStep = true; break cycleLoop }
                        if let end = endDate, Date() >= end { break cycleLoop }
                        if !(await isBusAlive()) {
                            endReason = .busDisconnected
                            break cycleLoop
                        }
                        previous = await sendStep(step, previousIn: previous)
                        stepsExecuted += 1

                        if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                            endReason = .lowerBodyWriteFailure
                            break cycleLoop
                        }
                        // v1.8 Major #1: 단일 joint 연속 fail → 진짜 hardware fault 의심.
                        // L5: liveness 프로브 연속 실패도 동일 판정 (SYNC_WRITE 무응답 보상).
                        if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit })
                            || probeFault() {
                            sampleError = sampleError ?? "단일 모터 연속 응답 없음 — hardware 확인"
                            endReason = .lowerBodyWriteFailure
                            break cycleLoop
                        }
                        if positionFailures > max(10, JointID.allCases.count) {
                            endReason = .bulkWriteFailure
                            break cycleLoop
                        }
                    }
                }
            }
        }
        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        // 4. Exit — walkReady 안전 복귀. cancel 후에도 토크 OFF 보다는 복귀가 안전 (낙상 risk).
        // **v1.11.22.1 (Codex HIGH-1 fix)**: emergencyStop (hard stop) 시 exit phase 스킵.
        // 이미 bus.emergencyStop()으로 torque OFF 됨 → setPosition 시도 시 motor 무응답
        // 또는 race. "토크 OFF 이후 명령 없음" 불변식 보존.
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
        for step in plan.exit {
            let rawTarget = step.toPose()
            // **Stage 4b (v1.1 fall prevention)**: exit phase 도 corrector 적용.
            let target: RobotPose
            if let transformPose {
                target = await transformPose(rawTarget)
            } else {
                target = rawTarget
            }
            // Phase G11 — 3D 모델 갱신.
            if let onPose {
                await onPose(target)
            }
            // L5: exit phase 도 SYNC_WRITE 1패킷 — gate 보호 일관성 유지 (robotPort 경유).
            let changedFinal = target.changedJoints(from: previous)
            if !changedFinal.isEmpty {
                let targets = changedFinal.map { ($0, UInt16(clamping: target.raw($0))) }
                do {
                    if let port = robotPort {
                        try await port.writeJointPositions(
                            Dictionary(uniqueKeysWithValues: targets))
                    } else {
                        try bus.setPositions(targets)
                    }
                } catch let portErr as RobotPortError where portErr == .dxlPowerOff {
                    await robotPort?.emergencyStop()
                    positionFailures += 1
                    if let cb = onBusWriteFailure { Task { @MainActor in cb() } }
                    sampleError = "복귀 일괄쓰기(dxlPowerOff): \(portErr.localizedDescription)"
                } catch {
                    positionFailures += 1
                    // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                    if let cb = onBusWriteFailure {
                        Task { @MainActor in cb() }
                    }
                    sampleError = "복귀 일괄쓰기 (\(changedFinal.count)관절): \(error.localizedDescription)"
                }
            }
            // Exit 의 playMs 동안 모터가 walkReady 도달하도록 대기.
            let totalMs = max(80, step.playMs + step.pauseMs)
            let ns = UInt64(totalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            previous = target
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

    /// 보행 cycle 실제 송출 루프 — `Task.detached` 내부 실행.
    ///
    /// **Codex P0 fix (2026-05-13 3차)**:
    /// - 모든 `try?` 제거 — speed/position write 실패 카운트 + 마지막 에러 sample.
    /// - 하체 position write 실패 1개 이상 → 즉시 cycle 중단 (균형 위험).
    /// - 결과를 `WalkCycleResult` 로 반환 — 호출자가 사용자에게 surface.
    ///
    /// 설계:
    /// - moving speed 1회만 설정 (매 step 호출 안 함 — 패킷 절약).
    /// - 변경된 관절만 setPosition — `RobotPose.changedJoints(from:)` 사용.
    /// - playMs + pauseMs 동안 모터의 trapezoidal motion 자체 보간을 신뢰 → 그 후 다음 step.
    /// - Task.detached 이므로 main thread block 없음.
    internal static func runWalkCycle(
        bus: any BusInterface, page: MotionPage, maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        loop: Bool = true,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil,
        transformPose: (@MainActor @Sendable (RobotPose) -> RobotPose)? = nil,
        // 2026-05-17 chaos #1 fix: bus 끊김 즉시 abort. runContinuousWalk 와 동일.
        isBusAlive: @Sendable () async -> Bool = { true },
        // v1.11.22.1 (Codex HIGH-1 fix): emergencyStop 시 true → exit phase skip.
        isHardStopped: @Sendable () async -> Bool = { false },
        // v1.11.1 MEDIUM-5: bus write 실패 callback (ConnectionStore 누적).
        onBusWriteFailure: (@MainActor @Sendable () -> Void)? = nil,
        // V288-2: Hexagonal architecture port — dxlPower gate 강제.
        // 모든 joint write 의 공식 entry — DXL power gate 가 자동 차단.
        // nil 이면 기존 bus.setPosition 직접 호출 (하위 호환 유지).
        robotPort: (any RobotPort)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0
        // **Wave 2 (2026-06-11) io-timeout 상한** — runContinuousWalk 와 동일. 보행 동안
        // bus read timeout 을 walkIoTimeoutMs(50ms)로 낮추고 모든 종료 경로에서 원복.
        let restoreIoTimeoutMs = bus.configuredIoTimeoutMs
        bus.setIoTimeout(ms: Self.walkIoTimeoutMs)
        defer { bus.setIoTimeout(ms: restoreIoTimeoutMs) }
        var perJointFailsLocal: [JointID: Int] = [:]
        // L5 (2026-06-11): liveness 프로브 — runContinuousWalk 와 동일 (SYNC_WRITE 보상).
        var probeFailsLocal: [JointID: Int] = [:]
        var probeIndex = 0
        let probeJoints = lowerBodyJoints.sorted { $0.rawValue < $1.rawValue }

        // 1. cycle 시작 — moving speed 1회 설정. RoboPlus 기본 32 ≈ 60 rpm 의 4배 — 빠른 보행 대응.
        // L5: 관절별 개별 write 20회 → SYNC_WRITE 1패킷.
        let cycleSpeed: UInt16 = 256
        do { try bus.setMovingSpeeds(JointID.allCases, speed: cycleSpeed) }
        catch {
            speedFailures += 1
            // v1.11.2 (사용자 review P2-A): setMovingSpeed 실패도 callback.
            if let cb = onBusWriteFailure {
                Task { @MainActor in cb() }
            }
            sampleError = "목표 속도 일괄 전송: \(error.localizedDescription)"
        }

        // 2. step loop. walkReady 가 항상 prev — 변경된 관절만 차분 송출.
        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        cycleLoop: repeat {
            for step in page.steps {
                if Task.isCancelled { cancelledMidStep = true; break cycleLoop }
                if let end = endDate, Date() >= end { break cycleLoop }
                if !(await isBusAlive()) {
                    endReason = .busDisconnected
                    break cycleLoop
                }

                let rawTarget = step.toPose()
                let target: RobotPose
                if let transformPose {
                    target = await transformPose(rawTarget)
                } else {
                    target = rawTarget
                }
                if let onPose {
                    await onPose(target)
                }
                // **v1.11.22.1 (Codex new HIGH)**: step entry 시 hard-stop check.
                if await isHardStopped() {
                    // 외곽 do-while 종료 — endReason 은 cancelledMidStep 으로.
                    cancelledMidStep = true
                    break
                }
                // L5 (2026-06-11): 관절별 개별 write → SYNC_WRITE 1패킷.
                // transport 실패는 배치 내 하체 관절 전체 실패로 보수적 매핑.
                let changed = target.changedJoints(from: previous)
                if !changed.isEmpty && !Task.isCancelled {
                    let targets = changed.map { ($0, UInt16(clamping: target.raw($0))) }
                    var lastErr: Error?
                    for attempt in 0..<2 {
                        do {
                            // V288-2: robotPort 경유 → dxlPower gate 자동 강제.
                            if let port = robotPort {
                                try await port.writeJointPositions(
                                    Dictionary(uniqueKeysWithValues: targets))
                            } else {
                                try bus.setPositions(targets)
                            }
                            lastErr = nil
                            break
                        } catch let portErr as RobotPortError where portErr == .dxlPowerOff {
                            await robotPort?.emergencyStop()
                            lastErr = portErr
                            break
                        } catch {
                            lastErr = error
                            if attempt == 0 {
                                try? await Task.sleep(nanoseconds: Self.setPositionRetryBackoffNs)
                            }
                        }
                    }
                    if let err = lastErr {
                        positionFailures += 1
                        // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                        if let cb = onBusWriteFailure {
                            Task { @MainActor in cb() }
                        }
                        sampleError = "step 일괄 위치 전송 (\(changed.count)관절): \(err.localizedDescription)"
                        for joint in changed where lowerBodyJoints.contains(joint) {
                            lowerBodyPositionFails.insert(joint)
                            perJointFailsLocal[joint, default: 0] += 1
                        }
                    } else {
                        for joint in changed { perJointFailsLocal[joint] = 0 }
                    }
                }
                // L5 liveness 프로브 — bus 직결 경로 전용 (runContinuousWalk 와 동일).
                if robotPort == nil, !probeJoints.isEmpty, !Task.isCancelled,
                   !(await isHardStopped()) {
                    let probe = probeJoints[probeIndex % probeJoints.count]
                    probeIndex += 1
                    do {
                        try bus.ping(id: probe.rawValue)
                        probeFailsLocal[probe] = 0
                    } catch {
                        probeFailsLocal[probe, default: 0] += 1
                        lowerBodyPositionFails.insert(probe)
                        sampleError = "\(probe.name) liveness 무응답: \(error.localizedDescription)"
                    }
                }
                previous = target
                stepsExecuted += 1

                if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                // v1.8 Major #1: 단일 joint 연속 fail → hardware fault 의심.
                // L5: liveness 프로브 연속 실패도 동일 판정.
                if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit })
                    || probeFailsLocal.contains(where: { $0.value >= Self.livenessProbeFailureLimit }) {
                    sampleError = sampleError ?? "단일 모터 연속 응답 없음 — hardware 확인"
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                // v1.8: 누적 카운터 임계 완화.
                if positionFailures > max(10, JointID.allCases.count) {
                    endReason = .bulkWriteFailure
                    break cycleLoop
                }

                let totalMs = max(80, step.playMs + step.pauseMs)
                let ns = UInt64(totalMs) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        } while loop && !Task.isCancelled && !cancelledMidStep
        // v1.11.22.1: cancelledMidStep 가 hard-stop 시 set → 다음 iteration 도 차단.
        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        // 3. 종료 정리 — walkReady 안전 복귀. 하체 실패 후에도 토크 OFF 보다는
        // walkReady 시도가 안전 (낙상 risk 가 더 큼). 실패해도 결과에 반영.
        // **v1.11.22.1 (Codex HIGH-1 fix)**: emergencyStop (hard stop) 시 스킵.
        if await isHardStopped() {
            return WalkCycleResult(
                reason: .userCancelled,
                stepsExecuted: stepsExecuted,
                speedWriteFailures: speedFailures,
                positionWriteFailures: positionFailures,
                lowerBodyPositionFails: Array(lowerBodyPositionFails),
                sampleError: "emergencyStop — walkReady 복귀 스킵 (torque OFF 보호)"
            )
        }
        let walkReady = RobotPose.walkReady
        // Phase G11 — 3D 모델 walkReady 복귀 시각화.
        if let onPose {
            await onPose(walkReady)
        }
        // L5: walkReady 복귀도 SYNC_WRITE 1패킷 — gate 보호 일관성 유지 (robotPort 경유).
        let changedFinal = walkReady.changedJoints(from: previous)
        if !changedFinal.isEmpty {
            let targets = changedFinal.map { ($0, UInt16(clamping: walkReady.raw($0))) }
            do {
                if let port = robotPort {
                    try await port.writeJointPositions(
                        Dictionary(uniqueKeysWithValues: targets))
                } else {
                    try bus.setPositions(targets)
                }
            } catch let portErr as RobotPortError where portErr == .dxlPowerOff {
                await robotPort?.emergencyStop()
                positionFailures += 1
                if let cb = onBusWriteFailure { Task { @MainActor in cb() } }
                sampleError = "복귀 일괄쓰기(dxlPowerOff): \(portErr.localizedDescription)"
            } catch {
                positionFailures += 1
                // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "복귀 일괄쓰기 (\(changedFinal.count)관절): \(error.localizedDescription)"
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
