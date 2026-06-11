import Foundation
import Network
import os

/// 온보드 조종 명령 전송 허브 (cockpit-latency-hardening §4 Wave 1).
///
/// 비유: 종전엔 명령 1건마다 로봇에 *전화를 새로 걸어*(SSH subprocess) 받을 때까지
/// 수화기를 들고 기다렸다(인라인 ACK 폴 ≤1.5s → 실효 4–8Hz). 이 채널은 **전화를 한 번
/// 걸어두고 끊지 않은 채**(상주 SSH) 주문을 계속 흘려보내고, 긴급정지는 아예 별도
/// 직통선(UDP)으로 동시에 외친다. 명령당 fork/exec 0, E-STOP 은 큐를 우회한다.
///
/// 책임:
/// - 코얼레싱 큐(`.latestWins`)로 freeform tuning 의 미송신 stale 명령을 최신으로 대체.
/// - `.ordered` 명령(모드 전환 등)은 순서 보존.
/// - `sendEmergencyStopNow` 는 큐를 우회 — UDP 연발 + SSH stop 을 *병행* fire-and-forget.
/// - ACK 의 로봇 ts 로 `RobotClockSync` 갱신 + `PilotLatencyTracer` 마크.
///
/// 안전 불변식(§7): E-STOP 경로에 스로틀/배칭/추가 await 홉 금지 — 본 구현은 홉 *제거*
/// 와 병행 채널 *추가* 방향만. 실패 시 transport 가 기존 `SSHShell.run` 으로 동기 폴백.
public actor OnboardCommandChannel {
    /// 기능 플래그 — 공존 기간 운용(off 면 기존 OnboardSendQueue 경로 유지).
    public static let featureFlagKey = "df.onboard.persistentChannel"

    private let transport: OnboardLineTransport
    private let estop: EstopBurstSender?
    private let token: String
    private let log = Logger(subsystem: "DarwinForge", category: "OnboardCommandChannel")

    private var queue = CoalescingQueue()
    private var draining = false
    private var closed = false
    private(set) public var lastAck: OnboardAck?

    public init(transport: OnboardLineTransport, estop: EstopBurstSender?, token: String) {
        self.transport = transport
        self.estop = estop
        self.token = token
    }

    /// 명령 enqueue + drain 기동. 코얼레싱은 정책에 따름.
    public func send(_ command: OnboardCommand) {
        guard !closed else { return }
        PilotLatencyTracer.shared.mark(.channelEnqueued, seq: command.traceSeq)
        queue.enqueue(command)
        startDrainIfNeeded()
    }

    /// 현재 큐 깊이(테스트·진단).
    public func pendingCount() -> Int { queue.count }

    private func startDrainIfNeeded() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while let cmd = queue.dequeue() {
            let txMs = Self.nowMs()
            PilotLatencyTracer.shared.mark(.channelSent, seq: cmd.traceSeq)
            do {
                let ack = try await transport.send(cmd)
                let rxMs = Self.nowMs()
                if let rts = ack.robotTsMs {
                    RobotClockSync.shared.record(robotTsMs: rts, txMs: txMs, rxMs: rxMs)
                }
                let appliedMac = ack.robotTsMs.flatMap { RobotClockSync.shared.robotToMacMs($0) }
                PilotLatencyTracer.shared.markAckReceived(seq: cmd.traceSeq, robotAppliedMacMs: appliedMac)
                lastAck = ack
            } catch {
                log.warning("onboard send failed (\(cmd.cmdId, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                // 폴백은 transport 내부 책임. 여기서는 다음 명령으로 진행.
            }
        }
        draining = false
    }

    /// **E-STOP — 큐 우회, 양 transport fire-and-forget**(§5.4). 절대 await 하지 않고 즉시 반환.
    /// `stopLine` 은 SSH 폴백 정지 명령(브로커리지 enabled=0 라인). UDP 연발이 1차, SSH 가 확인.
    ///
    /// **TODO (라이브 결선 전 필수, cross-review)**: 본 메서드는 actor-isolated 라 호출 시
    /// actor 홉이 1회 든다 — §7 "E-STOP 경로에 추가 비동기 홉 금지" 위반 소지. 라이브 입력원
    /// (버튼/키/게임패드/DJI onChange)에서 직접 부를 때는 `nonisolated` 진입점으로 전환해
    /// 홉 0 으로 발사해야 한다(UDP 버스트·token·transport 를 actor 외부에 immutable 로 보관).
    /// 현재는 채널 단위 테스트(LatencyBudgetRegressionTests)에서만 호출되어 홉 영향 없음.
    public func sendEmergencyStopNow(stopLine: String, traceSeq: UInt32 = 0) {
        PilotLatencyTracer.shared.markEstopRequested(seq: traceSeq)
        let unixMillis = Self.nowMs()
        let token = self.token
        let estop = self.estop
        let transport = self.transport
        Task.detached(priority: .high) {
            // 두 경로 병행 발사 — 먼저 닿는 쪽 승리. estop 버스트가 우선.
            async let burst: Void = estop?.fireBurst(token: token, unixMillis: unixMillis) ?? ()
            async let sshStop: Void = transport.sendStopFireAndForget(stopLine)
            _ = await (burst, sshStop)
            PilotLatencyTracer.shared.markEstopSent(seq: traceSeq)
        }
    }

    public func shutdown() async {
        closed = true
        queue.clear()
        await transport.shutdown()
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - Transport 추상화 (mock-first — 호스트 테스트는 loopback 주입)

/// 명령 라인 1건을 로봇에 전달하고 ACK 를 받는 전송 계층.
public protocol OnboardLineTransport: Sendable {
    /// 명령 송신 + ACK 대기. 실패 시 throw(채널이 다음 명령으로 진행).
    func send(_ command: OnboardCommand) async throws -> OnboardAck
    /// 정지 라인 fire-and-forget(ACK 대기 없음 — E-STOP 경로).
    func sendStopFireAndForget(_ line: String) async
    /// 자원 정리(상주 프로세스 종료 등).
    func shutdown() async
}

/// E-STOP UDP 연발 발사 계층.
public protocol EstopBurstSender: Sendable {
    /// `DF-ESTOP v1 {token} {ts}` 를 ×3 연발(0/50/100ms) 발사. 비차단·실패 무음.
    func fireBurst(token: String, unixMillis: Int64) async
}

// MARK: - 상주 SSH 채널 (concrete transport — HIL)

/// 끊기지 않는 `ssh host 'exec sh -s'` 1개로 명령을 stdin 줄단위 송출, stdout sentinel
/// (`__DF_DONE_<id>_<exit>__`)로 완료 구분(cockpit-latency-hardening §5.4 L1).
///
/// 명령당 fork/exec 0. 프로세스가 죽었거나 미기동이면 매 명령을 기존 `SSHShell.run` 으로
/// 동기 폴백(E-STOP 에 추가 대기 없음 — stop 은 fire-and-forget). 상주 프로세스 I/O 는
/// 전용 serial queue 에서만 만진다(`@unchecked Sendable` + queue 격리).
public final class PersistentSSHChannel: OnboardLineTransport, @unchecked Sendable {
    private let host: String
    private let user: String
    private let options: SSHShell.SSHOptions
    private let ioQueue = DispatchQueue(label: "df.onboard.persistentSSH")
    private let log = Logger(subsystem: "DarwinForge", category: "PersistentSSHChannel")

    // ioQueue 격리 상태.
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pendingBuffer = Data()
    private var continuations: [UInt64: CheckedContinuation<Int32, Never>] = [:]
    private var nextId: UInt64 = 1

    /// 명령당 ACK(sentinel) 대기 상한. 초과 시 동기 폴백으로 전환.
    private let sendTimeout: TimeInterval

    public init(host: String,
                user: String = "robotis",
                options: SSHShell.SSHOptions = SSHShell.defaultOptions(),
                sendTimeout: TimeInterval = 1.0) {
        self.host = host
        self.user = user
        self.options = options
        self.sendTimeout = sendTimeout
    }

    /// 로봇이 cmd 파일을 쓰는 셸 명령(브로커리지가 폴/스트림으로 수신). atomic tmp+mv.
    private static func remoteWrite(line: String) -> String {
        "printf '%s\\n' '\(line)' > /tmp/df-walklab-cmd.tmp && mv /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd"
    }

    public func send(_ command: OnboardCommand) async throws -> OnboardAck {
        let remote = Self.remoteWrite(line: command.line)
        let exit = await sendViaResidentShell(remote)
        if let exit {
            return OnboardAck(cmdId: command.cmdId, robotTsMs: nil, exitCode: exit)
        }
        // 폴백 — 상주 셸 미가용. 기존 동기 경로(ControlMaster 핸드셰이크 재사용).
        let result = try await SSHShell.run(command: remote, host: host, user: user,
                                            timeoutSeconds: 3, options: options)
        return OnboardAck(cmdId: command.cmdId, robotTsMs: nil, exitCode: result.exitCode)
    }

    public func sendStopFireAndForget(_ line: String) async {
        let remote = Self.remoteWrite(line: line)
        // 1) 상주 셸로 즉시 write(대기 없음). 2) 실패 대비 동기 폴백도 병행(짧은 타임아웃).
        let wroteResident: Bool = await withCheckedContinuation { cont in
            ioQueue.async { [weak self] in
                guard let self, let stdin = self.stdinHandle else { cont.resume(returning: false); return }
                let payload = remote + "\n"
                do { try stdin.write(contentsOf: Data(payload.utf8)); cont.resume(returning: true) }
                catch { cont.resume(returning: false) }
            }
        }
        if !wroteResident {
            _ = try? await SSHShell.run(command: remote, host: host, user: user,
                                        timeoutSeconds: 2, options: options)
        }
    }

    public func shutdown() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async { [weak self] in
                self?.teardownLocked()
                cont.resume()
            }
        }
    }

    // MARK: 상주 셸 I/O (ioQueue 격리)

    /// 상주 셸로 명령 송출 + sentinel 대기. 셸 미가용/타임아웃이면 nil(→폴백).
    private func sendViaResidentShell(_ remoteCommand: String) async -> Int32? {
        let id: UInt64? = await withCheckedContinuation { cont in
            ioQueue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                if !self.ensureProcessLocked() { cont.resume(returning: nil); return }
                guard let stdin = self.stdinHandle else { cont.resume(returning: nil); return }
                let id = self.nextId; self.nextId &+= 1
                let wrapped = OnboardChannelSentinel.wrap(command: remoteCommand, id: id) + "\n"
                do {
                    try stdin.write(contentsOf: Data(wrapped.utf8))
                    cont.resume(returning: id)
                } catch {
                    self.teardownLocked()
                    cont.resume(returning: nil)
                }
            }
        }
        guard let id else { return nil }

        // sentinel 또는 타임아웃 대기.
        let exit: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
                    self.ioQueue.async { self.continuations[id] = cont }
                }
            }
            group.addTask { [sendTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(sendTimeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if exit == nil {
            // 타임아웃 — continuation 정리(resume 누락 방지).
            ioQueue.async { [weak self] in
                if let cont = self?.continuations.removeValue(forKey: id) { cont.resume(returning: -1) }
            }
        }
        return exit
    }

    /// 상주 프로세스 보장(없으면 spawn). ioQueue 에서만 호출. 성공 true.
    private func ensureProcessLocked() -> Bool {
        if let p = process, p.isRunning { return true }
        teardownLocked()

        let task = Process()
        task.launchPath = "/usr/bin/ssh"
        task.arguments = SSHShell.sshArguments(
            host: host, user: user, command: "exec sh -s",
            connectTimeoutSeconds: 6, options: options
        )
        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.ioQueue.async { self?.consumeStdoutLocked(chunk) }
        }
        task.terminationHandler = { [weak self] _ in
            self?.ioQueue.async { self?.failAllPendingLocked() }
        }
        do {
            try task.run()
        } catch {
            log.error("persistent ssh spawn failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        process = task
        stdinHandle = stdin.fileHandleForWriting
        pendingBuffer.removeAll(keepingCapacity: true)
        return true
    }

    /// stdout 바이트 누적 → 줄 분리 → sentinel 매칭 시 continuation resume. ioQueue 격리.
    private func consumeStdoutLocked(_ chunk: Data) {
        pendingBuffer.append(chunk)
        while let nl = pendingBuffer.firstIndex(of: 0x0A) {
            let lineData = pendingBuffer.subdata(in: pendingBuffer.startIndex..<nl)
            pendingBuffer.removeSubrange(pendingBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let (id, exit) = OnboardChannelSentinel.parse(line),
               let cont = continuations.removeValue(forKey: id) {
                cont.resume(returning: exit)
            }
        }
    }

    private func failAllPendingLocked() {
        for (_, cont) in continuations { cont.resume(returning: -1) }
        continuations.removeAll()
    }

    private func teardownLocked() {
        failAllPendingLocked()
        if let p = process, p.isRunning {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            p.terminate()
        }
        process = nil
        stdinHandle = nil
        pendingBuffer.removeAll(keepingCapacity: false)
    }
}

// MARK: - E-STOP UDP 발사기 (concrete — HIL)

/// `DF-ESTOP v1 {token} {ts}` 를 robot:estopUDPPort 로 ×3 연발 발사(0/50/100ms).
/// connected UDP(NWConnection) — 핸드셰이크 없는 최저지연 fire-and-forget.
public final class EstopUDPSender: EstopBurstSender, @unchecked Sendable {
    private let connection: NWConnection
    private let log = Logger(subsystem: "DarwinForge", category: "EstopUDPSender")

    public init?(host: String, port: UInt16 = DFConnectionConstants.estopUDPPort) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.start(queue: DispatchQueue(label: "df.estop.udp"))
    }

    public func fireBurst(token: String, unixMillis: Int64) async {
        let data = OnboardEstopDatagram.data(token: token, unixMillis: unixMillis)
        for (i, offset) in OnboardEstopDatagram.burstOffsetsMs.enumerated() {
            if offset > 0 { try? await Task.sleep(nanoseconds: UInt64(offset) * 1_000_000) }
            connection.send(content: data, completion: .contentProcessed { [log] error in
                if let error { log.debug("estop burst \(i) send error: \(error.localizedDescription, privacy: .public)") }
            })
        }
    }

    public func cancel() { connection.cancel() }
}
