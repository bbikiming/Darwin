import Foundation

// MARK: - Disabled reason

public enum DisabledReason: Equatable, Sendable {
    case macDisconnected
    case robotDisconnected(simAvailable: Bool)
    case busBusy
    case notArmed
    case latencyGate(latencyMs: Int)
    case stale
    case estopped
    case running

    public var koreanCopy: String {
        switch self {
        case .macDisconnected:
            return "Mac이 연결되지 않았어요."
        case .robotDisconnected(let sim):
            return sim ? "로봇이 미연결입니다. 연습 미리보기만 가능해요."
                       : "로봇이 미연결입니다."
        case .busBusy:
            return "ROBOTIS 데모가 USB를 사용 중이에요. 수동 모드로 복구하세요."
        case .notArmed:
            return "잠금 해제가 필요해요."
        case .latencyGate(let ms):
            return "응답 지연(\(ms)ms)으로 보행 조작이 제한됐어요."
        case .stale:
            return "로봇 응답이 늦어요. 정지 후 다시 시도하세요."
        case .estopped:
            return "긴급 정지 상태입니다. 복구 후 다시 잠금을 해제하세요."
        case .running:
            return "다른 명령이 실행 중이에요."
        }
    }
}

// MARK: - High-level pilot state

public enum PilotState: Equatable, Sendable {
    case notPaired
    case pairing
    case pairedNoMac
    case macConnectedNoRobot
    case robotConnectedLocked
    case arming
    case armedReady
    case commandActive(commandId: String)
    case staleStop
    case estopped

    public var ui: PilotUIState {
        switch self {
        case .notPaired, .pairing, .pairedNoMac: return .notPaired
        case .macConnectedNoRobot: return .macConnectedNoRobot
        case .robotConnectedLocked: return .robotConnectedLocked
        case .arming: return .arming
        case .armedReady: return .armedReady
        case .commandActive: return .commandActive
        case .staleStop: return .staleStop
        case .estopped: return .estopped
        }
    }

    public var isArmed: Bool {
        switch self {
        case .armedReady, .commandActive: return true
        default: return false
        }
    }

    public var allowsEStop: Bool { true }

    public var requiresHeartbeat: Bool {
        switch self {
        case .commandActive, .arming, .estopped: return true
        default: return false
        }
    }
}

// MARK: - Inputs

public enum StateInput: Sendable {
    case pairingStarted
    case pairingSucceeded
    case pairingFailed
    case telemetry(TelemetryStatePayload)
    case armRequested
    case armingProgress(ArmingStage)
    case armed
    case disarmed
    case commandStarted(commandId: String)
    case commandFinished
    case stopRequested
    case estopRequested
    case watchdogStopped(WatchdogStopReason)
    case transportClosed
    case ackTimeout
    case recoveryAcknowledged
    /// V297-7 재검증 P2: 복구 시도 실패 — estopped 유지하되 사용자 명시 E-stop 과는
    /// 구분되는 trace. `.estopRequested` 의 사이드이펙트 (사용자 E-stop log, haptic error,
    /// banner 재open) 를 발생시키지 않는다.
    case recoveryFailed(reason: String)
}

// MARK: - Transition result

public struct TransitionResult: Sendable {
    public let nextState: PilotState
    public let sideEffects: [SideEffect]
    public init(nextState: PilotState, sideEffects: [SideEffect] = []) {
        self.nextState = nextState
        self.sideEffects = sideEffects
    }
}

public enum SideEffect: Equatable, Sendable {
    case stopActiveCommand(reason: StopReason)
    case logSafety(String)
    case haptic(HapticKind)
    case openRecoveryBanner
}

public enum HapticKind: String, Sendable {
    case lightImpact
    case mediumImpact
    case softImpact
    case successNotification
    case warningNotification
    case errorNotification
}

// MARK: - State machine

public struct MobilePilotStateMachine: Sendable {

    public private(set) var state: PilotState
    public private(set) var lastTelemetry: TelemetryStatePayload?
    public let latencyWarningMs: Int

    public init(initial: PilotState = .notPaired, latencyWarningMs: Int = 150) {
        self.state = initial
        self.latencyWarningMs = latencyWarningMs
    }

    @discardableResult
    public mutating func apply(_ input: StateInput) -> TransitionResult {
        let result = Self.reduce(state: state, input: input,
                                 latencyWarningMs: latencyWarningMs)
        state = result.nextState
        if case .telemetry(let t) = input {
            lastTelemetry = t
        }
        return result
    }

    // Pure reducer — testable without mutation.
    public static func reduce(state: PilotState,
                              input: StateInput,
                              latencyWarningMs: Int = 150) -> TransitionResult {
        switch input {
        case .estopRequested:
            return TransitionResult(nextState: .estopped,
                                    sideEffects: [.haptic(.errorNotification),
                                                  .stopActiveCommand(reason: .user),
                                                  .openRecoveryBanner,
                                                  .logSafety("E-stop requested by user")])
        case .watchdogStopped(let reason):
            return TransitionResult(nextState: .staleStop,
                                    sideEffects: [.haptic(.warningNotification),
                                                  .stopActiveCommand(reason: .latencyGate),
                                                  .logSafety("Watchdog stop: \(reason.rawValue)")])
        case .transportClosed:
            // Mac lost while we were in command-active or armed → fall back to safe state.
            let next: PilotState
            switch state {
            case .commandActive, .armedReady, .arming, .robotConnectedLocked:
                next = .pairedNoMac
            default:
                next = .pairedNoMac
            }
            return TransitionResult(nextState: next,
                                    sideEffects: [.stopActiveCommand(reason: .latencyGate),
                                                  .logSafety("Transport closed")])
        case .ackTimeout:
            guard case .commandActive = state else {
                return TransitionResult(nextState: state)
            }
            return TransitionResult(nextState: .staleStop,
                                    sideEffects: [.haptic(.warningNotification),
                                                  .stopActiveCommand(reason: .latencyGate),
                                                  .logSafety("ACK timeout")])
        case .recoveryFailed(let reason):
            // V297-7 재검증 P2: 복구 시도 실패 — estopped 유지하되 사용자 명시 E-stop
            // 사이드이펙트 (errorNotification haptic, openRecoveryBanner, 가짜 "E-stop
            // requested by user" 로그) 발생시키지 않는다. log 만 정확한 reason 으로 기록.
            return TransitionResult(nextState: .estopped,
                                    sideEffects: [.logSafety("Recovery failed: \(reason)")])
        default:
            break
        }

        switch (state, input) {
        case (_, .pairingStarted):
            return TransitionResult(nextState: .pairing)
        case (.pairing, .pairingSucceeded):
            return TransitionResult(nextState: .macConnectedNoRobot)
        case (.pairing, .pairingFailed):
            return TransitionResult(nextState: .notPaired,
                                    sideEffects: [.logSafety("Pairing failed")])

        case (_, .telemetry(let payload)):
            let next = stateFromTelemetry(current: state, payload: payload)
            return TransitionResult(nextState: next)

        case (.robotConnectedLocked, .armRequested),
             (.armedReady, .armRequested),
             (.macConnectedNoRobot, .armRequested):
            return TransitionResult(nextState: .arming)
        // V297-7 P2-i1 (CRITICAL): estopped → armRequested 는 "복구" 버튼 흐름.
        // iOS UI 가 estopped 상태에서 같은 위치 버튼이 녹색 "복구" 로 전환되어 사용자가
        // 누르면 pilot.arm 송신 → Mac 이 emergencyStopActive 분기로 recoverFromEStop.
        // FSM 이 이 transition 을 명시적으로 인정해야 ack 받은 후 armedReady 로 진행 가능.
        // staleStop 도 동일 정책 — 사용자 복구 인지 = arming 진입.
        case (.estopped, .armRequested),
             (.staleStop, .armRequested):
            return TransitionResult(nextState: .arming,
                                    sideEffects: [.logSafety("Recovery requested from estopped")])
        case (.arming, .armingProgress):
            return TransitionResult(nextState: .arming)
        case (.arming, .armed):
            return TransitionResult(nextState: .armedReady,
                                    sideEffects: [.haptic(.successNotification)])
        case (_, .disarmed):
            return TransitionResult(nextState: .robotConnectedLocked)

        case (.armedReady, .commandStarted(let id)),
             (.commandActive, .commandStarted(let id)):
            return TransitionResult(nextState: .commandActive(commandId: id))

        case (.commandActive, .commandFinished):
            return TransitionResult(nextState: .armedReady)

        case (.commandActive, .stopRequested):
            return TransitionResult(nextState: .armedReady,
                                    sideEffects: [.stopActiveCommand(reason: .user),
                                                  .haptic(.softImpact)])
        case (_, .stopRequested):
            return TransitionResult(nextState: state,
                                    sideEffects: [.stopActiveCommand(reason: .user)])

        case (.estopped, .recoveryAcknowledged),
             (.staleStop, .recoveryAcknowledged):
            return TransitionResult(nextState: .robotConnectedLocked)

        default:
            return TransitionResult(nextState: state)
        }
    }

    private static func stateFromTelemetry(current: PilotState,
                                           payload: TelemetryStatePayload) -> PilotState {
        // V297-7 P2-i1 (CRITICAL fix): arming/armedReady 는 사용자가 복구 명령을
        // 시작한 상태 — telemetry 가 잠시 estopped 라도 ack/recover 완료 전까지는
        // FSM 이 estopped 로 끌리지 않게 한다. 사용자가 직접 .estopRequested 를
        // 보내거나 watchdog/transport 이벤트가 들어와야 estopped 진입.
        switch current {
        case .arming, .armedReady, .commandActive:
            // 단, telemetry safety=estopped 가 5초 이상 지속되면 별도 watchdog 로직이
            // .watchdogStopped 또는 .estopRequested 를 보내 정상 처리한다. 여기는 그 외
            // race 윈도우 (복구 ack 직후의 잔존 telemetry) 만 무시.
            if payload.safety == .estopped {
                return current   // 사용자 의도(복구) 우선.
            }
        default:
            break
        }
        // Hard overrides — 위 사용자-의도 분기에 안 잡힌 경우만 적용.
        if payload.safety == .estopped {
            return .estopped
        }
        switch current {
        case .estopped where payload.safety != .estopped:
            // Stay in estopped until user acks recovery.
            return current
        default:
            break
        }

        switch (payload.mac, payload.robot, payload.armed, current) {
        case (.lost, _, _, _):
            return .pairedNoMac
        case (_, .disconnected, _, _), (_, .sim, _, _):
            return .macConnectedNoRobot
        case (_, .busBusy, _, _):
            return .robotConnectedLocked
        case (_, .stale, true, _):
            return .staleStop
        case (_, .connected, false, _):
            return .robotConnectedLocked
        case (_, .connected, true, .commandActive):
            return current
        case (_, .connected, true, _):
            return .armedReady
        case (_, .estopped, _, _):
            return .estopped
        case (.connected, _, _, .notPaired), (.connected, _, _, .pairing):
            return .macConnectedNoRobot
        default:
            return current
        }
    }
}

// MARK: - Disabled-reason policy

public enum CommandPermission {
    public static func reason(forArm state: PilotState,
                              telemetry: TelemetryStatePayload?,
                              latencyWarningMs: Int = 150) -> DisabledReason? {
        baseReason(state: state, telemetry: telemetry, latencyWarningMs: latencyWarningMs)
    }

    public static func reason(forSafeAction state: PilotState,
                              telemetry: TelemetryStatePayload?,
                              latencyWarningMs: Int = 150) -> DisabledReason? {
        if let r = baseReason(state: state, telemetry: telemetry, latencyWarningMs: latencyWarningMs) {
            return r
        }
        if !state.isArmed { return .notArmed }
        if case .commandActive = state { return .running }
        return nil
    }

    public static func reason(forWalk state: PilotState,
                              telemetry: TelemetryStatePayload?,
                              latencyWarningMs: Int = 150) -> DisabledReason? {
        if let r = baseReason(state: state, telemetry: telemetry, latencyWarningMs: latencyWarningMs) {
            return r
        }
        if !state.isArmed { return .notArmed }
        if let t = telemetry, t.latencyMs >= latencyWarningMs {
            return .latencyGate(latencyMs: t.latencyMs)
        }
        return nil
    }

    private static func baseReason(state: PilotState,
                                   telemetry: TelemetryStatePayload?,
                                   latencyWarningMs: Int) -> DisabledReason? {
        switch state {
        case .notPaired, .pairing, .pairedNoMac:
            return .macDisconnected
        case .estopped:
            return .estopped
        case .staleStop:
            return .stale
        default:
            break
        }
        if let t = telemetry {
            if t.mac == .lost { return .macDisconnected }
            if t.robot == .busBusy { return .busBusy }
            if t.robot == .disconnected || t.robot == .sim {
                return .robotDisconnected(simAvailable: t.robot == .sim)
            }
            if t.robot == .stale { return .stale }
        }
        return nil
    }
}
