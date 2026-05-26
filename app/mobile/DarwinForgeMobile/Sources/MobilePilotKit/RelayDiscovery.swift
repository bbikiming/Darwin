import Foundation
#if canImport(Network)
import Network
#endif

/// Result of a single Bonjour discovery hit.
public struct RelayDiscoveryResult: Equatable, Sendable, Identifiable {
    public let id: String   // Bonjour service name
    public let displayName: String
    public let host: String
    public let port: Int
    public let lastSeen: Date

    public init(id: String, displayName: String, host: String, port: Int, lastSeen: Date) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.lastSeen = lastSeen
    }
}

/// 브라우저가 유한 탐색을 완료했음을 알리는 이벤트 열거형.
/// 공항 탑승구 안내판처럼 일정 시간 안에 모든 항공편을 보여준 뒤 "탐색 완료" 표지판을 세운다.
public enum DiscoveryTimeout: Sendable {
    /// `elapsed` 초 경과 후 타임아웃 발생. 빈 결과 포함.
    case timedOut(elapsed: TimeInterval)
}

public protocol RelayBrowser: AnyObject, Sendable {
    var resultsStream: AsyncStream<[RelayDiscoveryResult]> { get }
    /// 탐색이 타임아웃됐을 때 단발 이벤트를 방출하는 스트림.
    var timeoutStream: AsyncStream<DiscoveryTimeout> { get }
    func start()
    func stop()
}

#if canImport(Network)
/// Real Bonjour browser. Uses `NWBrowser` and resolves endpoints to host:port.
///
/// 공항 출발 안내판 비유: Bonjour가 Wi-Fi에서 Mac을 스캔해 카드로 보여주다가,
/// `timeoutInterval`(기본 30초) 안에 찾지 못하면 "탐색 완료" 신호를 보낸다.
/// UI 는 이 신호를 받아 "안 보여요?" 확장 패널을 자동으로 열면 된다.
public final class BonjourRelayBrowser: RelayBrowser, @unchecked Sendable {

    /// Bonjour 탐색 타임아웃 (초). 기본값 30s — Apple HIG: 대기 가이드라인.
    public let timeoutInterval: TimeInterval

    public let resultsStream: AsyncStream<[RelayDiscoveryResult]>
    public let timeoutStream: AsyncStream<DiscoveryTimeout>

    private let continuation: AsyncStream<[RelayDiscoveryResult]>.Continuation
    private let timeoutContinuation: AsyncStream<DiscoveryTimeout>.Continuation
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "darwinforge.mobile.bonjour")
    private let lock = NSLock()
    private var resolvedById: [String: RelayDiscoveryResult] = [:]
    private var timeoutWorkItem: DispatchWorkItem?

    public init(timeoutInterval: TimeInterval = 30) {
        self.timeoutInterval = timeoutInterval
        var cont: AsyncStream<[RelayDiscoveryResult]>.Continuation!
        self.resultsStream = AsyncStream { cont = $0 }
        self.continuation = cont

        var toCont: AsyncStream<DiscoveryTimeout>.Continuation!
        self.timeoutStream = AsyncStream { toCont = $0 }
        self.timeoutContinuation = toCont
    }

    public func start() {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjour(type: MobileRelayProtocol.bonjourServiceType,
                                                     domain: nil)
        let params = NWParameters.tcp
        let b = NWBrowser(for: descriptor, using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        b.start(queue: queue)
        browser = b

        // 30초 후 타임아웃 신호 발송 — DispatchWorkItem 으로 취소 가능
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timeoutContinuation.yield(.timedOut(elapsed: self.timeoutInterval))
        }
        timeoutWorkItem = item
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: item)
    }

    public func stop() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        browser?.cancel()
        browser = nil
    }

    private func handle(results: Set<NWBrowser.Result>) {
        for r in results {
            switch r.endpoint {
            case .service(let name, _, _, _):
                resolve(endpoint: r.endpoint, displayName: name)
            default:
                continue
            }
        }
    }

    private func resolve(endpoint: NWEndpoint, displayName: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                if let resolved = self.extract(connection: conn, fallback: displayName) {
                    self.publish(resolved)
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func extract(connection: NWConnection, fallback: String) -> RelayDiscoveryResult? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        switch endpoint {
        case .hostPort(let host, let port):
            let hostString: String
            switch host {
            case .ipv4(let v): hostString = "\(v)"
            case .ipv6(let v): hostString = "\(v)"
            case .name(let name, _): hostString = name
            @unknown default: hostString = "\(host)"
            }
            return RelayDiscoveryResult(id: fallback,
                                         displayName: fallback,
                                         host: hostString,
                                         port: Int(port.rawValue),
                                         lastSeen: Date())
        default:
            return nil
        }
    }

    private func publish(_ result: RelayDiscoveryResult) {
        lock.lock()
        resolvedById[result.id] = result
        let snapshot = Array(resolvedById.values.sorted { $0.displayName < $1.displayName })
        lock.unlock()
        continuation.yield(snapshot)
    }
}
#endif

/// In-memory browser used by tests and previews.
public final class FixedRelayBrowser: RelayBrowser, @unchecked Sendable {
    public let resultsStream: AsyncStream<[RelayDiscoveryResult]>
    public let timeoutStream: AsyncStream<DiscoveryTimeout>
    private let continuation: AsyncStream<[RelayDiscoveryResult]>.Continuation
    private let timeoutContinuation: AsyncStream<DiscoveryTimeout>.Continuation
    private let results: [RelayDiscoveryResult]

    public init(results: [RelayDiscoveryResult]) {
        self.results = results
        var cont: AsyncStream<[RelayDiscoveryResult]>.Continuation!
        self.resultsStream = AsyncStream { cont = $0 }
        self.continuation = cont

        var toCont: AsyncStream<DiscoveryTimeout>.Continuation!
        self.timeoutStream = AsyncStream { toCont = $0 }
        self.timeoutContinuation = toCont
    }

    public func start() {
        continuation.yield(results)
    }

    public func stop() {}
}

// MARK: - QR payload parsing

public enum QRPairingDecoder {
    public static func decode(_ raw: String) throws -> PairingQRPayload {
        guard let data = raw.data(using: .utf8) else {
            throw RelayClientError.decodingFailure
        }
        do {
            return try RelayCodec.decoder.decode(PairingQRPayload.self, from: data)
        } catch {
            throw RelayClientError.decodingFailure
        }
    }
}

// MARK: - Pairing code validation

public enum PairingCode {
    public static let length = 6

    public static func validate(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.count == length && trimmed.allSatisfy { $0.isNumber }
    }
}
