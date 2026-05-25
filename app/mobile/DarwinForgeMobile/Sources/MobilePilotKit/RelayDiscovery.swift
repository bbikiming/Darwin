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

public protocol RelayBrowser: AnyObject, Sendable {
    var resultsStream: AsyncStream<[RelayDiscoveryResult]> { get }
    func start()
    func stop()
}

#if canImport(Network)
/// Real Bonjour browser. Uses `NWBrowser` and resolves endpoints to host:port.
public final class BonjourRelayBrowser: RelayBrowser, @unchecked Sendable {

    public let resultsStream: AsyncStream<[RelayDiscoveryResult]>
    private let continuation: AsyncStream<[RelayDiscoveryResult]>.Continuation
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "darwinforge.mobile.bonjour")
    private let lock = NSLock()
    private var resolvedById: [String: RelayDiscoveryResult] = [:]

    public init() {
        var cont: AsyncStream<[RelayDiscoveryResult]>.Continuation!
        self.resultsStream = AsyncStream { cont = $0 }
        self.continuation = cont
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
    }

    public func stop() {
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
    private let continuation: AsyncStream<[RelayDiscoveryResult]>.Continuation
    private let results: [RelayDiscoveryResult]

    public init(results: [RelayDiscoveryResult]) {
        self.results = results
        var cont: AsyncStream<[RelayDiscoveryResult]>.Continuation!
        self.resultsStream = AsyncStream { cont = $0 }
        self.continuation = cont
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
