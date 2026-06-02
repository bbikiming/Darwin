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
        // v1.8 (10x review Major #1): per-joint consecutive failure counter (local, static-safe).
        var perJointFailsLocal: [JointID: Int] = [:]

        // 1. moving speed 설정 (1회).
        let cycleSpeed: UInt16 = 256
        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: cycleSpeed) }
            catch {
                speedFailures += 1
                // v1.11.2 (사용자 review P2-A): setMovingSpeed 실패도 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "\(joint.name) 목표 속도 전송: \(error.localizedDescription)"
            }
        }

        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        // 한 step 송출 helper — closure 캡처 X (concurrency 안전).
        func sendStep(_ step: MotionStep, previousIn: RobotPose) async -> RobotPose {
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
            // v1.8 setPosition 1회 retry + 10x review Major #1: per-joint consecutive counter.
            // Set count >= 3 (서로 다른 joint 3개 fail) 또는 단일 joint 5회 연속 fail.
            // **v1.11.22.1 (Codex new HIGH)**: step entry 시 hard-stop check —
            // emergencyStop 진행 중이면 step 내부 setPosition 전체 skip (torque OFF 후
            // joint write race 차단).
            if await isHardStopped() { return previousIn }
            let changed = target.changedJoints(from: previousIn)
            for joint in changed {
                // **v1.11.22.1**: 각 joint write 직전 cheap Task.isCancelled check —
                // e-stop 타이밍에 남은 joint write 진행 차단.
                if Task.isCancelled { break }
                let rawVal = UInt16(clamping: target.raw(joint))
                var lastErr: Error?
                for attempt in 0..<2 {
                    do {
                        // V288-2: robotPort 경유 → dxlPower gate 자동 강제.
                        // 마치 공식 매표소 통과 — gate 없는 뒷문(bus.setPosition) 폐쇄.
                        if let port = robotPort {
                            _ = try await port.writeJointPosition(joint, raw: rawVal)
                        } else {
                            _ = try bus.setPosition(joint, raw: rawVal)
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
                    sampleError = "\(joint.name) 목표 위치 전송: \(err.localizedDescription)"
                    if lowerBodyJoints.contains(joint) {
                        lowerBodyPositionFails.insert(joint)
                    }
                    perJointFailsLocal[joint, default: 0] += 1
                } else {
                    // 성공 시 해당 joint counter reset (one-off transient 흡수).
                    perJointFailsLocal[joint] = 0
                }
            }
            let totalMs = max(80, step.playMs + step.pauseMs)
            let ns = UInt64(totalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            return target
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
            if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit }) {
                endReason = .lowerBodyWriteFailure
                break entryLoop
            }
        }

        // 3. Cycle — 6 phase 무한 반복.
        if endReason == .completedMaxDuration && !cancelledMidStep && lowerBodyPositionFails.count < Self.lowerBodyDistinctFailureThreshold {
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
                    // v1.8 Major #1: 단일 joint 5회 연속 fail → 진짜 hardware fault 의심.
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
            let changedFinal = target.changedJoints(from: previous)
            for joint in changedFinal {
                let rawVal = UInt16(clamping: target.raw(joint))
                do {
                    // V288-2: exit phase 도 robotPort 경유 — gate 보호 일관성 유지.
                    if let port = robotPort {
                        _ = try await port.writeJointPosition(joint, raw: rawVal)
                    } else {
                        _ = try bus.setPosition(joint, raw: rawVal)
                    }
                } catch let portErr as RobotPortError where portErr == .dxlPowerOff {
                    await robotPort?.emergencyStop()
                    positionFailures += 1
                    if let cb = onBusWriteFailure { Task { @MainActor in cb() } }
                    sampleError = "\(joint.name) 복귀쓰기(dxlPowerOff): \(portErr.localizedDescription)"
                } catch {
                    positionFailures += 1
                    // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                    if let cb = onBusWriteFailure {
                        Task { @MainActor in cb() }
                    }
                    sampleError = "\(joint.name) 복귀쓰기: \(error.localizedDescription)"
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
        var perJointFailsLocal: [JointID: Int] = [:]

        // 1. cycle 시작 — moving speed 1회 설정. RoboPlus 기본 32 ≈ 60 rpm 의 4배 — 빠른 보행 대응.
        let cycleSpeed: UInt16 = 256
        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: cycleSpeed) }
            catch {
                speedFailures += 1
                // v1.11.2 (사용자 review P2-A): setMovingSpeed 실패도 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "\(joint.name) 목표 속도 전송: \(error.localizedDescription)"
            }
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
                let changed = target.changedJoints(from: previous)
                for joint in changed {
                    // **v1.11.22.1**: 각 joint write 직전 cheap cancel check.
                    if Task.isCancelled { break }
                    let rawVal = UInt16(clamping: target.raw(joint))
                    var lastErr: Error?
                    for attempt in 0..<2 {
                        do {
                            // V288-2: robotPort 경유 → dxlPower gate 자동 강제.
                            if let port = robotPort {
                                _ = try await port.writeJointPosition(joint, raw: rawVal)
                            } else {
                                _ = try bus.setPosition(joint, raw: rawVal)
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
                        sampleError = "\(joint.name) 목표 위치 전송: \(err.localizedDescription)"
                        if lowerBodyJoints.contains(joint) {
                            lowerBodyPositionFails.insert(joint)
                        }
                        perJointFailsLocal[joint, default: 0] += 1
                    } else {
                        perJointFailsLocal[joint] = 0
                    }
                }
                previous = target
                stepsExecuted += 1

                if lowerBodyPositionFails.count >= Self.lowerBodyDistinctFailureThreshold {
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                // v1.8 Major #1: 단일 joint 5회 연속 fail → hardware fault 의심.
                if perJointFailsLocal.contains(where: { lowerBodyJoints.contains($0.key) && $0.value >= Self.perJointConsecutiveFailureLimit }) {
                    sampleError = "단일 모터 \(Self.perJointConsecutiveFailureLimit)회 연속 응답 없음 — hardware 확인"
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
        let changedFinal = walkReady.changedJoints(from: previous)
        for joint in changedFinal {
            let rawVal = UInt16(clamping: walkReady.raw(joint))
            do {
                // V288-2: walkReady 복귀 write 도 robotPort 경유 — gate 보호 일관성 유지.
                if let port = robotPort {
                    _ = try await port.writeJointPosition(joint, raw: rawVal)
                } else {
                    _ = try bus.setPosition(joint, raw: rawVal)
                }
            } catch let portErr as RobotPortError where portErr == .dxlPowerOff {
                await robotPort?.emergencyStop()
                positionFailures += 1
                if let cb = onBusWriteFailure { Task { @MainActor in cb() } }
                sampleError = "\(joint.name) 복귀쓰기(dxlPowerOff): \(portErr.localizedDescription)"
            } catch {
                positionFailures += 1
                // v1.11.1 MEDIUM-5: bus write 실패 누적 callback.
                if let cb = onBusWriteFailure {
                    Task { @MainActor in cb() }
                }
                sampleError = "\(joint.name) 복귀쓰기: \(error.localizedDescription)"
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
