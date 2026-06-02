import Foundation

/// Production adapter that wires `MobileRelayServer` into the existing
/// macOS app surface. Bridges between the wire-protocol enums (defined in
/// `MobileRelayCommand.swift`) and the live `ConnectionStore` +
/// `TeleopChannel` + `WalkLabOnboardBridge` APIs.
///
/// This adapter intentionally takes the live MainActor types via closures so
/// that the relay server can stay actor-isolated and call back into the UI
/// store without leaking @MainActor through the protocol. All real I/O
/// (torque on/off, walking line publishing) happens on @MainActor.
@MainActor
public final class ConnectionStoreSafetyPort: RobotSafetyPort {

    public struct Hooks {
        /// `() async -> Bool` — performs `TeleopChannel.arm()` and returns whether it succeeded.
        public var armAsync: @MainActor () async -> Bool
        /// V297-4 — 현재 TeleopChannel.armStage 를 프로토콜 stage 이름으로 변환해 반환.
        /// arm() 진행 중 polling 으로 호출 → arming.progress emit. nil 이면 아직 매핑 단계 아님.
        ///
        /// 매핑:
        ///   - .enablingPower → "enablingPower"
        ///   - .rampingTorque → "engagingTorque"
        ///   - .reachingWalkready → "walkReadyPose"
        ///   - .ready / .readyDegraded / .simReady → "armed"
        ///   - else (idle, disarming) → nil
        public var currentArmStageName: @MainActor () -> String?
        /// `() -> Void` — `TeleopChannel.disarm()` synchronously.
        public var disarmSync: @MainActor () -> Void
        /// V297-5 CRITICAL-5: `() -> Bool` — `ConnectionStore.emergencyStop()` + verification.
        ///
        /// 종전: `() -> Void`. ConnectionStore 의 emergencyStop 이 bus nil 시 silent
        /// return + flag set 안 함 → 서버는 호출만으로 ack 송신 → iOS UI 는 E-stop
        /// 성공으로 표시 (실제는 미연결).
        ///
        /// 신규: 반환 Bool. true = torque-off 검증 통과 (emergencyStopActive flag set),
        /// false = bus nil 또는 bus.emergencyStop() 실패. 서버는 false 시 command.failed
        /// (safetyAbort) 송신.
        ///
        /// 비유: 비상정지 버튼 누른 뒤 "정지등 점등" 확인. 등이 안 켜지면 실패.
        public var emergencyStopSync: @MainActor () -> Bool
        /// `(UInt8, Bool) async -> Bool` — `TeleopChannel.sendMotion(slot:confirmRisk:)`.
        public var sendMotion: @MainActor (UInt8, Bool) async -> Bool
        /// `(WalkPayload) async throws -> Bool` — translates a walk payload into an
        /// existing WalkLab onboard brokering call (returns true on ACK).
        /// Throw `RelayServerError.rejected(reason)` to send `command.rejected` to iOS.
        /// Throw `RelayServerError.failed(reason)` or generic error for `command.failed`.
        public var sendWalk: @MainActor (WalkPayload) async throws -> Bool
        /// `(String) async -> Bool` — stop active walking (X/Y/A move amplitude = 0).
        public var sendStop: @MainActor (String) async -> Bool
        /// `() async -> TelemetryStatePayload` — build a telemetry snapshot from live state.
        public var snapshot: @MainActor () async -> TelemetryStatePayload

        public init(armAsync: @escaping @MainActor () async -> Bool,
                    currentArmStageName: @escaping @MainActor () -> String? = { nil },
                    disarmSync: @escaping @MainActor () -> Void,
                    emergencyStopSync: @escaping @MainActor () -> Bool,
                    sendMotion: @escaping @MainActor (UInt8, Bool) async -> Bool,
                    sendWalk: @escaping @MainActor (WalkPayload) async throws -> Bool,
                    sendStop: @escaping @MainActor (String) async -> Bool,
                    snapshot: @escaping @MainActor () async -> TelemetryStatePayload) {
            self.armAsync = armAsync
            self.currentArmStageName = currentArmStageName
            self.disarmSync = disarmSync
            self.emergencyStopSync = emergencyStopSync
            self.sendMotion = sendMotion
            self.sendWalk = sendWalk
            self.sendStop = sendStop
            self.snapshot = snapshot
        }
    }

    private let hooks: Hooks

    public init(hooks: Hooks) { self.hooks = hooks }

    // MARK: - RobotSafetyPort

    public nonisolated func snapshot() async -> TelemetryStatePayload {
        await MainActor.run { /* peel into MainActor */ }
        return await hooks.snapshot()
    }

    public nonisolated func arm(cradleConfirmed: Bool,
                                operator: String,
                                progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        guard cradleConfirmed else { throw RelayServerError.rejected("cradleRequired") }
        await progress("checkingChecklist", 0.1)

        // V297-4: ARM stage polling — TeleopChannel.armStage 의 실제 transition 을
        // 외부 progress callback 으로 emit. 종전엔 enablingPower (0.4) → walkReadyPose (0.9)
        // 로 점프해 iOS arming bar 가 engagingTorque 단계를 표시 못 했음.
        //
        // 비유: 엘리베이터 층 표시등 — 1층→3층 점프 표시가 아니라 1→2→3 모두 보여줘야
        // 사용자가 진행 상황을 안다.
        let progressBox = ProgressBox(progress: progress)
        // V297-4: hooks 는 @MainActor isolated property. Task 안에서 직접 접근하면 Swift 6
        // strict concurrency warning → MainActor.run 안에서만 currentArmStageName 호출.
        // 그래서 hooks 자체를 capture 하지 않고, closure 만 local 로 추출.
        let stageNameClosure: @MainActor () -> String? = await MainActor.run { self.hooks.currentArmStageName }
        let stageTask = Task<Void, Never> { [progressBox, stageNameClosure] in
            // 알려진 stage 순서 — 점진적 progress 값.
            let mapping: [String: Double] = [
                "enablingPower": 0.3,
                "engagingTorque": 0.6,
                "walkReadyPose": 0.85,
            ]
            var emitted: Set<String> = []
            while !Task.isCancelled {
                let stage = await MainActor.run { stageNameClosure() }
                // V297-5 MEDIUM-2: cancel 후 MainActor.run 복귀 시점에 다시 검사 —
                // emit 과 final progress 순서가 섞이는 회로 차단.
                if Task.isCancelled { break }
                if let stage, let v = mapping[stage], !emitted.contains(stage) {
                    emitted.insert(stage)
                    await progressBox.emit(stage, v)
                }
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            }
        }

        let start = Date()
        let ok = await hooks.armAsync()
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        // V297-5 MEDIUM-2: cancel + drain — stageTask 가 in-flight emit 을 끝까지 마치고
        // 종료하도록 .value await. 그 후 final "armed" / "failed" 호출 → 순서 보장.
        stageTask.cancel()
        await stageTask.value

        if !ok {
            await progress("failed", 1.0)
            throw RelayServerError.rejected("armFailed")
        }
        // 최종 — armed (1.0). polling 이 engagingTorque/walkReadyPose 를 놓쳤어도
        // arm() 성공 종료 시 final state 는 항상 armed 로 표시.
        await progress("armed", 1.0)
        return elapsed
    }

    /// V297-4 — `progress` closure 를 Sendable Task 에서 호출하기 위한 actor wrapper.
    /// `@Sendable` 클로저 자체는 actor-isolated 가 아니라서 Task 안에서 직접 호출 가능
    /// 하지만, Swift 6 strict concurrency 에서 capture 경고 회피 + 명시성 위해 별도 wrap.
    private actor ProgressBox {
        let progress: @Sendable (String, Double) async -> Void
        init(progress: @escaping @Sendable (String, Double) async -> Void) {
            self.progress = progress
        }
        func emit(_ stage: String, _ value: Double) async {
            await progress(stage, value)
        }
    }

    public nonisolated func disarm(reason: String) async throws -> Int {
        let start = Date()
        await hooks.disarmSync()
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    public nonisolated func emergencyStop(reason: String) async throws -> Int {
        let start = Date()
        // V297-5 CRITICAL-5: emergencyStopSync 반환을 검증 — bus nil / 실패 시 throw.
        let verified = await hooks.emergencyStopSync()
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !verified {
            throw RelayServerError.failed("estopVerificationFailed")
        }
        return elapsed
    }

    public nonisolated func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int {
        guard let slot8 = UInt8(exactly: slot) else {
            throw RelayServerError.rejected("invalidSlot")
        }
        let start = Date()
        let ok = await hooks.sendMotion(slot8, confirmRisk)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok { throw RelayServerError.rejected("notArmed") }
        return elapsed
    }

    public nonisolated func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) {
        let start = Date()
        // Propagate RelayServerError.rejected / .failed from the hook directly.
        let ok = try await hooks.sendWalk(payload)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok { throw RelayServerError.failed("noAck") }
        return (elapsed, nil)
    }

    public nonisolated func sendStop(reason: String) async throws -> Int {
        let start = Date()
        let ok = await hooks.sendStop(reason)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok { throw RelayServerError.failed("stopFailed") }
        return elapsed
    }

    public nonisolated func setHead(payload: HeadPayload) async throws -> Int {
        throw RelayServerError.rejected("headUnsupportedInMVP")
    }
}

// MARK: - Convenience: produce a TelemetryStatePayload from common Mac state

public enum MobileRelayTelemetryFactory {

    public static func make(macConnected: Bool,
                            robotConnected: Bool,
                            armed: Bool,
                            dxlPower: Bool,
                            busBusy: Bool,
                            endpoint: String?,
                            batteryV: Double?,
                            maxTempC: Double?,
                            latencyMs: Int,
                            lastAckAgeMs: Int?,
                            estopActive: Bool) -> TelemetryStatePayload {
        let mac: MacState = macConnected ? .connected : .lost
        let robot: RobotState = {
            // V297-9 MEDIUM-1: robot 미연결 (Mac↔robot bus 없음) 시 estopped 보다
            // disconnected 가 우선. 종전엔 stale estopActive flag 가 정리 안 된 상태에서
            // bus 도 죽었으면 iOS 가 "estopped" 로 잘못 표시 — 실제는 통신 불가 상태.
            if !macConnected { return .disconnected }
            if !robotConnected { return .sim }
            if estopActive { return .estopped }
            if busBusy { return .busBusy }
            if let age = lastAckAgeMs, age > 1500 { return .stale }
            return .connected
        }()
        let safety: SafetyTag = {
            if estopActive { return .estopped }
            if armed { return .ready }
            return .ready
        }()
        let uiState: PilotUIStateTag = {
            if estopActive { return .estopped }
            if !macConnected { return .notPaired }
            switch robot {
            case .busBusy: return .robotConnectedLocked
            case .stale: return .staleStop
            case .disconnected, .sim: return .macConnectedNoRobot
            case .connected: return armed ? .armedReady : .robotConnectedLocked
            case .estopped: return .estopped
            }
        }()
        return TelemetryStatePayload(
            mac: mac, robot: robot, endpoint: endpoint,
            armed: armed, dxlPower: dxlPower,
            batteryV: batteryV, maxTempC: maxTempC,
            latencyMs: latencyMs, lastAckAgeMs: lastAckAgeMs,
            safety: safety, uiState: uiState)
    }
}
