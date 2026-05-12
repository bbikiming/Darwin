import Foundation
import ForgeCore
import Network

/// `_forge._tcp` Bonjour service를 같은 네트워크에서 자동 검색.
/// 로봇 내장 PC가 `forge serve --advertise` (향후) 또는 별도 dns-sd로 광고하면
/// 같은 네트워크의 Mac이 IP 입력 없이 클릭 한 번으로 연결.
@MainActor
public final class BonjourBrowser: ObservableObject {

    public struct Discovered: Identifiable, Equatable, Hashable {
        public let id: String
        public let serviceName: String
        public let host: String
        public let port: UInt16
    }

    @Published public private(set) var discovered: [Discovered] = []
    @Published public private(set) var isBrowsing: Bool = false

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_forge._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.refresh(from: results)
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready, .setup:
                    self.isBrowsing = true
                case .cancelled, .failed:
                    self.isBrowsing = false
                default:
                    break
                }
            }
        }
        b.start(queue: .main)
        browser = b
        isBrowsing = true
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discovered.removeAll()
    }

    deinit {
        browser?.cancel()
    }

    public func endpoint(for service: Discovered) -> Endpoint {
        .network(host: service.host, port: service.port)
    }

    // MARK: - Internal

    private func refresh(from results: Set<NWBrowser.Result>) {
        var found: [Discovered] = []
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            // mDNS 표준: <serviceName>.local 가 호스트네임으로 resolve.
            // 포트는 Bonjour TXT record에서 받을 수도 있으나, 현재 구현은 forge serve의
            // default port (5530)을 가정. 추후 NWConnection으로 actual host/port resolve.
            let host = name.lowercased() + ".local"
            found.append(Discovered(
                id: name,
                serviceName: name,
                host: host,
                port: 5530
            ))
        }
        // 안정 정렬 — 같은 검색 결과면 같은 순서.
        discovered = found.sorted(by: { $0.serviceName < $1.serviceName })
    }
}
