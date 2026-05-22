import Foundation
import ForgeCore
import SwiftUI

/// 마법사 진입 직후 사용자가 클릭 한 번으로 시도하는 자동 연결 엔진.
///
/// 동시에 모든 후보 (USB / 이더넷 직결 / LAN .1 / mDNS) 를 probe 한 후,
/// 응답하는 후보 중 가장 빠른 것으로 즉시 연결한다.
@MainActor
public final class OneClickConnect: ObservableObject {

    /// 한 후보의 라이브 진단 상태.
    public struct CandidateState: Identifiable, Equatable {
        public enum Stage: Equatable {
            case pending
            case probing
            case found(detail: String)         // 응답 받았지만 아직 연결 안 함.
            case readyToConnect(detail: String) // probe 성공 — 연결 시도 가능.
            case failed(reason: String)
        }
        public enum Kind: String, Equatable {
            case usb, ethernetDirect, lan, mdns
        }

        /// Ping 결과를 짧은 칩으로 표시하기 위한 요약.
        public enum PingChip: Equatable {
            case unknown
            case probing
            case ok(rttMs: Double)
            case unreachable
            case timedOut
            case notApplicable    // USB는 ping 의미 없음
        }
        /// Port 5530 결과 칩.
        public enum PortChip: Equatable {
            case unknown
            case probing
            case open(rttMs: Int)
            case refused
            case unreachable
            case timedOut
            case notApplicable
        }

        public let id: String
        public var kind: Kind
        public var label: String
        public var detail: String
        public var stage: Stage
        public var endpoint: Endpoint?
        public var ping: PingChip = .unknown
        public var port: PortChip = .unknown
        public var host: String? = nil
    }

    public enum Phase: Equatable {
        case idle
        case scanning
        case allFailed
        case connecting(label: String)
        case connected
        case failed(reason: String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var candidates: [CandidateState] = []
    @Published public private(set) var lastDiagnosticAt: Date?

    /// 현재 시도 중인 endpoint 라벨 (UI 진행 표시).
    @Published public private(set) var currentAttemptLabel: String?

    private weak var store: ConnectionStore?
    private var bonjour: BonjourBrowser?
    private var scanTask: Task<Void, Never>?

    public init() {}

    public func bind(store: ConnectionStore, bonjour: BonjourBrowser) {
        self.store = store
        self.bonjour = bonjour
    }

    public func cancel() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
        currentAttemptLabel = nil
    }

    /// 한 번 클릭 진입점 — 모든 후보를 동시에 probe + 첫 성공으로 즉시 연결.
    ///
    /// 우선순위:
    ///   1. `store.lastSuccessfulEndpoint` 가 있으면 그것으로 먼저 빠른 시도 (~1초).
    ///   2. 성공 → 즉시 종료.
    ///   3. 실패 → 기존 multi-candidate 병렬 probe.
    public func runOneClick() {
        scanTask?.cancel()
        phase = .scanning
        candidates = Self.initialCandidates()
        lastDiagnosticAt = Date()

        scanTask = Task { [weak self] in
            // 1단계: 마지막 성공 endpoint 우선 시도.
            if let store = self?.store,
               let last = store.lastSuccessfulEndpoint {
                await self?.tryConnect(label: "마지막 — \(last.detail)", endpoint: last)
                if case .connected = await MainActor.run(body: { store.status }) {
                    return
                }
            }
            // 2단계: 모든 후보 병렬 probe.
            await self?.performScanAndConnect()
        }
    }

    /// probe 만 — 연결 안 함. 사용자가 직접 후보를 클릭해서 시도하고 싶을 때.
    public func runDiagnosticsOnly() {
        scanTask?.cancel()
        phase = .scanning
        candidates = Self.initialCandidates()
        lastDiagnosticAt = Date()

        scanTask = Task { [weak self] in
            await self?.probeAll(connectIfFound: false)
            await MainActor.run {
                if let self {
                    if case .scanning = self.phase {
                        self.phase = self.candidates.allSatisfy({
                            if case .failed = $0.stage { return true } else { return false }
                        }) ? .allFailed : .idle
                    }
                }
            }
        }
    }

    // MARK: - Scanning + connecting

    private func performScanAndConnect() async {
        await probeAll(connectIfFound: true)
        // 모두 실패한 경우 phase 를 allFailed 로 전환.
        await MainActor.run {
            if case .scanning = self.phase {
                let allFailed = self.candidates.allSatisfy({
                    if case .failed = $0.stage { return true } else { return false }
                })
                if allFailed {
                    self.phase = .allFailed
                }
            }
        }
    }

    /// 후보 목록을 probe. connectIfFound = true 면 첫 응답 직후 즉시 연결.
    private func probeAll(connectIfFound: Bool) async {
        // 1) USB enumerate (instant — sync)
        await probeUSB(connectIfFound: connectIfFound)
        if shouldStop() { return }

        // 2) mDNS 시작 (background — 1초 후 결과 수집).
        startMDNS()

        // 3) TCP probe 들 — 병렬 실행.
        let tcpHosts = Self.tcpProbeTargets()
        await withTaskGroup(of: Void.self) { group in
            for (id, host) in tcpHosts {
                group.addTask { [weak self] in
                    await self?.probeTCP(id: id, host: host, connectIfFound: connectIfFound)
                }
            }
            await group.waitForAll()
        }
        if shouldStop() { return }

        // 4) mDNS 결과를 1.5 초까지 기다림.
        await collectMDNS(connectIfFound: connectIfFound)
    }

    private func shouldStop() -> Bool {
        if Task.isCancelled { return true }
        if case .connected = phase { return true }
        if case .connecting = phase { return true }
        return false
    }

    // MARK: - USB

    private func probeUSB(connectIfFound: Bool) async {
        await MainActor.run {
            self.updateCandidate(id: "usb", stage: .probing)
            self.store?.refreshPorts()
            let ports = self.store?.availablePorts ?? []
            if let chosen = AutoConnect.bestGuess(among: ports) ?? ports.first {
                let name = URL(fileURLWithPath: chosen).lastPathComponent
                self.updateCandidate(
                    id: "usb",
                    stage: .readyToConnect(detail: name),
                    endpoint: .usbSerial(path: chosen),
                    detail: name
                )
            } else {
                self.updateCandidate(
                    id: "usb",
                    stage: .failed(reason: "USB serial 디바이스 없음. 케이블·전원·드라이버 확인."),
                    detail: "케이블 미연결 추정"
                )
            }
        }
        if connectIfFound {
            // USB 가 가능하면 가장 안정적이므로 즉시 시도.
            if let ep = await currentEndpoint(id: "usb") {
                await tryConnect(label: "USB 직접", endpoint: ep)
            }
        }
    }

    // MARK: - 호스트 진단 (Ping + TCP 동시)

    private func probeTCP(id: String, host: String, connectIfFound: Bool) async {
        await MainActor.run {
            self.updateCandidate(id: id, stage: .probing,
                                 ping: .probing, port: .probing, host: host)
        }
        async let pingTask  = NetworkProbe.pingProbe(host: host, timeout: 1.2)
        async let portTask  = NetworkProbe.tcpProbe(host: host, port: 5530, timeout: 1.2)
        let pingR = await pingTask
        let portR = await portTask

        let pingChip: CandidateState.PingChip = {
            switch pingR {
            case .ok(let rtt):     return .ok(rttMs: rtt)
            case .unreachable:     return .unreachable
            case .timedOut:        return .timedOut
            }
        }()
        let portChip: CandidateState.PortChip = {
            switch portR {
            case .open(let rtt):   return .open(rttMs: rtt)
            case .refused:         return .refused
            case .unreachable:     return .unreachable
            case .timedOut:        return .timedOut
            }
        }()

        // 결과 조합 → stage 결정.
        let (stage, summary): (CandidateState.Stage, String) = {
            switch (pingR, portR) {
            case (_, .open(let rtt)):
                // 포트 OK — 무조건 연결 가능. ping 결과는 부수.
                return (.readyToConnect(detail: "\(host):5530 응답 (\(rtt)ms)"),
                        "포트 5530 OK")
            case (.ok(let rtt), .refused):
                return (.failed(reason: "호스트 OK (\(Self.fmt(rtt))ms) — 포트 5530 미실행. 로봇에서 `f` 실행 필요"),
                        "ping OK · socat 미실행")
            case (.ok(let rtt), .unreachable),
                 (.ok(let rtt), .timedOut):
                return (.failed(reason: "호스트 OK (\(Self.fmt(rtt))ms) — 포트 5530 응답 없음 (방화벽/iptables 차단 가능성)"),
                        "ping OK · 포트 차단")
            case (.unreachable, _):
                return (.failed(reason: "호스트 unreachable — 같은 LAN인지, 이더넷 직결 시 IP가 192.168.123.x 인지 확인"),
                        "케이블·서브넷 점검")
            case (.timedOut, _):
                return (.failed(reason: "ping timeout — 로봇 전원/케이블 또는 IP 불일치 확인"),
                        "응답 없음")
            }
        }()

        await MainActor.run {
            self.updateCandidate(
                id: id,
                stage: stage,
                endpoint: .network(host: host, port: 5530),
                detail: summary,
                ping: pingChip,
                port: portChip
            )
        }
        if connectIfFound, case .open = portR {
            if let ep = await currentEndpoint(id: id) {
                await tryConnect(label: host, endpoint: ep)
            }
        }
    }

    private static func fmt(_ ms: Double) -> String {
        if ms < 0 { return "?" }
        if ms < 10 { return String(format: "%.1f", ms) }
        return String(Int(ms.rounded()))
    }

    // MARK: - mDNS

    private func startMDNS() {
        bonjour?.start()
    }

    private func collectMDNS(connectIfFound: Bool) async {
        // 최대 1.5 초 대기 후 첫 발견 사용.
        for _ in 0..<6 {
            if shouldStop() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let first = bonjour?.discovered.first {
                await MainActor.run {
                    self.updateCandidate(
                        id: "mdns",
                        stage: .readyToConnect(detail: "\(first.host):\(first.port)"),
                        endpoint: .network(host: first.host, port: first.port),
                        detail: first.serviceName
                    )
                }
                if connectIfFound {
                    await tryConnect(label: "Bonjour \(first.serviceName)",
                                     endpoint: .network(host: first.host, port: first.port))
                }
                return
            }
        }
        await MainActor.run {
            // 발견 못 함 → 정보용 실패 (네트워크 환경에 따라 정상).
            self.updateCandidate(
                id: "mdns",
                stage: .failed(reason: "광고 중인 로봇 없음 — `forge serve --advertise <이름>` 미실행"),
                detail: "광고 없음"
            )
        }
    }

    // MARK: - 연결 시도

    private func tryConnect(label: String, endpoint: Endpoint) async {
        if shouldStop() { return }
        await MainActor.run {
            self.phase = .connecting(label: label)
            self.currentAttemptLabel = label
        }
        store?.connect(endpoint: endpoint)
        // 짧은 대기 후 status 확인.
        try? await Task.sleep(nanoseconds: 600_000_000)
        await MainActor.run {
            if let s = self.store?.status, case .connected = s {
                self.phase = .connected
            } else if let s = self.store?.status, case .error(let m) = s {
                // 한 후보 실패 — 다음 후보 계속 시도. phase 를 다시 scanning 으로 복구.
                self.phase = .scanning
                self.currentAttemptLabel = nil
                _ = m
            } else {
                self.phase = .scanning
                self.currentAttemptLabel = nil
            }
        }
    }

    // MARK: - 후보 헬퍼

    private static func initialCandidates() -> [CandidateState] {
        return [
            CandidateState(
                id: "usb", kind: .usb,
                label: "USB 케이블 직접",
                detail: "가장 안정적, ~1ms 지연",
                stage: .pending
            ),
            CandidateState(
                id: "tcp-op2", kind: .ethernetDirect,
                label: "이더넷 직결 (192.168.123.1)",
                detail: "OP2 e-Manual 표준",
                stage: .pending
            ),
        ] + Self.lanCandidates() + [
            CandidateState(
                id: "mdns", kind: .mdns,
                label: "mDNS 자동 광고",
                detail: "_forge._tcp 검색",
                stage: .pending
            )
        ]
    }

    private static func lanCandidates() -> [CandidateState] {
        var out: [CandidateState] = []
        let candidates = NetworkProbe.likelyRobotCandidates()
        for (i, host) in candidates.enumerated() where host != DFConnectionConstants.robotEthernetIP && i < 3 {
            out.append(CandidateState(
                id: "lan-\(i)", kind: .lan,
                label: "같은 LAN — \(host)",
                detail: "Mac과 같은 네트워크",
                stage: .pending
            ))
        }
        return out
    }

    private static func tcpProbeTargets() -> [(id: String, host: String)] {
        var targets: [(String, String)] = [("tcp-op2", DFConnectionConstants.robotEthernetIP)]
        let candidates = NetworkProbe.likelyRobotCandidates()
        for (i, host) in candidates.enumerated() where host != DFConnectionConstants.robotEthernetIP && i < 3 {
            targets.append(("lan-\(i)", host))
        }
        return targets
    }

    private func updateCandidate(id: String,
                                 stage: CandidateState.Stage,
                                 endpoint: Endpoint? = nil,
                                 detail: String? = nil,
                                 ping: CandidateState.PingChip? = nil,
                                 port: CandidateState.PortChip? = nil,
                                 host: String? = nil) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        var c = candidates[idx]
        c.stage = stage
        if let endpoint { c.endpoint = endpoint }
        if let detail { c.detail = detail }
        if let ping { c.ping = ping }
        if let port { c.port = port }
        if let host { c.host = host }
        candidates[idx] = c
    }

    // MARK: - 사용자 직접 점검

    /// 사용자가 입력한 host 한 개만 ping + TCP probe — 결과를 ManualProbeResult로 publish.
    @Published public private(set) var manualResult: ManualProbeResult?
    @Published public private(set) var isManualProbing: Bool = false

    public struct ManualProbeResult: Equatable {
        public let host: String
        public let ping: CandidateState.PingChip
        public let port: CandidateState.PortChip
        public let summary: String
        public let canConnect: Bool
    }

    public func manualProbe(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isManualProbing = true
        Task { [weak self] in
            async let p = NetworkProbe.pingProbe(host: trimmed, timeout: 1.5)
            async let t = NetworkProbe.tcpProbe(host: trimmed, port: 5530, timeout: 1.5)
            let pingR = await p
            let portR = await t
            await MainActor.run {
                guard let self else { return }
                let pingChip: CandidateState.PingChip = {
                    switch pingR {
                    case .ok(let rtt):     return .ok(rttMs: rtt)
                    case .unreachable:     return .unreachable
                    case .timedOut:        return .timedOut
                    }
                }()
                let portChip: CandidateState.PortChip = {
                    switch portR {
                    case .open(let rtt):   return .open(rttMs: rtt)
                    case .refused:         return .refused
                    case .unreachable:     return .unreachable
                    case .timedOut:        return .timedOut
                    }
                }()
                let summary: String = {
                    switch (pingR, portR) {
                    case (.ok(let r), .open):       return "✅ Ping \(Self.fmt(r))ms · 포트 5530 응답 — 연결 가능"
                    case (.ok(let r), .refused):    return "🟡 Ping \(Self.fmt(r))ms OK · 포트 5530 미실행 (로봇에서 `f` 필요)"
                    case (.ok(let r), _):           return "🟡 Ping \(Self.fmt(r))ms OK · 포트 응답 없음 (방화벽 차단 가능성)"
                    case (.unreachable, _):         return "❌ Host unreachable — 같은 LAN/서브넷 확인"
                    case (.timedOut, _):            return "❌ Ping timeout — 케이블/전원/IP 확인"
                    }
                }()
                let canConnect: Bool = {
                    if case .open = portR { return true }
                    return false
                }()
                self.manualResult = ManualProbeResult(
                    host: trimmed,
                    ping: pingChip,
                    port: portChip,
                    summary: summary,
                    canConnect: canConnect
                )
                self.isManualProbing = false
            }
        }
    }

    public func clearManualResult() {
        manualResult = nil
    }

    private func currentEndpoint(id: String) async -> Endpoint? {
        await MainActor.run {
            self.candidates.first(where: { $0.id == id })?.endpoint
        }
    }
}
