import Foundation

// MARK: - ID generator

public protocol CommandIDGenerator: Sendable {
    func next() -> String
}

public final class MonotonicCommandIDGenerator: CommandIDGenerator, @unchecked Sendable {
    private let prefix: String
    private var counter: UInt64 = 0
    private let lock = NSLock()

    public init(prefix: String = "cmd") {
        self.prefix = prefix
    }

    public func next() -> String {
        lock.lock(); defer { lock.unlock() }
        counter &+= 1
        return String(format: "%@_%06llu", prefix, counter)
    }
}

// MARK: - Clock abstraction

public protocol PilotClock: Sendable {
    func now() -> Date
    func sleep(milliseconds: Int) async
}

public struct LiveClock: PilotClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(milliseconds: Int) async {
        let nanos = UInt64(max(0, milliseconds)) * 1_000_000
        try? await Task.sleep(nanoseconds: nanos)
    }
}

public final class DeterministicClock: PilotClock, @unchecked Sendable {
    private var current: Date
    private let lock = NSLock()
    private var continuations: [(deadline: Date, cont: CheckedContinuation<Void, Never>)] = []

    public init(start: Date = Date(timeIntervalSince1970: 0)) {
        self.current = start
    }

    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }

    public func sleep(milliseconds: Int) async {
        let deadline = await withCheckedContinuation { (cont: CheckedContinuation<Date, Never>) in
            lock.lock()
            let d = current.addingTimeInterval(Double(milliseconds) / 1000.0)
            cont.resume(returning: d)
            lock.unlock()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if current >= deadline {
                lock.unlock()
                cont.resume()
            } else {
                continuations.append((deadline, cont))
                lock.unlock()
            }
        }
    }

    public func advance(milliseconds: Int) {
        lock.lock()
        current = current.addingTimeInterval(Double(milliseconds) / 1000.0)
        let due = continuations.filter { $0.deadline <= current }
        continuations.removeAll { $0.deadline <= current }
        lock.unlock()
        for entry in due { entry.cont.resume() }
    }
}

// MARK: - Command envelope builder

public struct CommandBuilder: Sendable {
    public let ids: CommandIDGenerator
    public let clock: PilotClock

    public init(ids: CommandIDGenerator = MonotonicCommandIDGenerator(),
                clock: PilotClock = LiveClock()) {
        self.ids = ids
        self.clock = clock
    }

    public func hello(_ payload: HelloPayload) -> RelayEnvelope<HelloPayload> {
        envelope(type: CommandType.sessionHello, payload: payload)
    }

    public func goodbye(_ payload: GoodbyePayload = .init()) -> RelayEnvelope<GoodbyePayload> {
        envelope(type: CommandType.sessionGoodbye, payload: payload)
    }

    public func heartbeat(_ payload: HeartbeatPayload) -> RelayEnvelope<HeartbeatPayload> {
        envelope(type: CommandType.pilotHeartbeat, payload: payload)
    }

    public func arm(_ payload: ArmPayload) -> RelayEnvelope<ArmPayload> {
        envelope(type: CommandType.pilotArm, payload: payload)
    }

    public func disarm(_ payload: DisarmPayload = .init()) -> RelayEnvelope<DisarmPayload> {
        envelope(type: CommandType.pilotDisarm, payload: payload)
    }

    public func estop(_ payload: EStopPayload = .init()) -> RelayEnvelope<EStopPayload> {
        envelope(type: CommandType.pilotEstop, payload: payload)
    }

    public func motion(_ payload: MotionPayload) -> RelayEnvelope<MotionPayload> {
        envelope(type: CommandType.pilotMotion, payload: payload)
    }

    public func walk(_ preset: WalkPreset, speedScale: Double = 1.0) -> RelayEnvelope<WalkPayload> {
        envelope(type: CommandType.pilotWalk,
                 payload: WalkPayload(preset: preset,
                                      params: preset.defaultParams,
                                      speedScale: speedScale))
    }

    /// Freeform analog walking input — translates a normalized joystick
    /// vector into a WalkPayload with the `freeform` preset tag.
    ///
    /// Baseline at speedScale=1.0:
    /// - forward (-y): xMm max 25 mm/step
    /// - lateral (+x): yMm max 15 mm/step
    /// - turn: aDeg max 10 deg/step
    ///
    /// `speedScale` is sent separately so the Mac relay can clamp and apply
    /// the same policy it uses for preset walking. The joystick vector itself
    /// still controls proportional speed because the normalized x/y/turn
    /// values are multiplied into the baseline amplitudes here.
    public func walkFreeform(_ input: WalkFreeformInput) -> RelayEnvelope<WalkPayload> {
        let moving = input.isMoving
        let xMm = (-input.y) * 25.0  // joystick up is forward stride
        let yMm = input.x * 15.0     // joystick right is lateral right
        let aDeg = input.turn * 10.0
        let params = WalkParams(
            enabled: moving,
            xMm: xMm.rounded(),
            yMm: yMm.rounded(),
            aDeg: aDeg.rounded(),
            periodMs: 700,
            footMm: 35,
            hipPitchDeg: 13)
        return envelope(type: CommandType.pilotWalk,
                        payload: WalkPayload(preset: .freeform,
                                             params: params,
                                             speedScale: input.speedScale))
    }

    public func head(_ payload: HeadPayload) -> RelayEnvelope<HeadPayload> {
        envelope(type: CommandType.pilotHead, payload: payload)
    }

    /// V297-9 CRITICAL-1: 복구 전용 명령 builder. iOS "복구" 버튼이 사용.
    public func recover(_ payload: RecoverPayload) -> RelayEnvelope<RecoverPayload> {
        envelope(type: CommandType.pilotRecover, payload: payload)
    }

    public func stop(_ payload: StopPayload = .init()) -> RelayEnvelope<StopPayload> {
        envelope(type: CommandType.pilotStop, payload: payload)
    }

    /// 볼 트래킹 (2026-06-02): 로봇 온보드 자동 헤드 추적 on/off. 조종기 버튼/화면 토글이 사용.
    public func ballTrack(enabled: Bool) -> RelayEnvelope<BallTrackPayload> {
        envelope(type: CommandType.pilotBallTrack, payload: BallTrackPayload(enabled: enabled))
    }

    private func envelope<P: Codable & Sendable>(type: CommandType, payload: P) -> RelayEnvelope<P> {
        RelayEnvelope(id: ids.next(), type: type.rawValue, sentAt: clock.now(), payload: payload)
    }
}
