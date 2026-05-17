import Foundation

/// 로봇과 통신할 수 있는 endpoint 종류.
///
/// `usbSerial`: 직접 USB 케이블 — 가장 안정, 가장 낮은 지연 (~1 ms).
/// `network`:  TCP — 로봇 내장 PC가 `forge serve` 데몬을 띄우면 외부에서 접근.
///             이더넷 케이블 직접(권장) / WiFi(시연용).
public enum Endpoint: Equatable, Hashable, Codable, Sendable {
    case usbSerial(path: String)
    case network(host: String, port: UInt16)

    /// 사용자에게 보여줄 짧은 이름.
    public var displayName: String {
        switch self {
        case .usbSerial(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .network(let host, let port):
            return "\(host):\(port)"
        }
    }

    /// 종류 라벨 — 한국어.
    public var kindLabel: String {
        switch self {
        case .usbSerial: return "USB"
        case .network:   return "네트워크"
        }
    }

    /// 2026-05-17 C1 fix: endpoint 별 권장 retry delay (nanoseconds).
    /// - USB (~1ms RTT): 100ms 충분 — 짧은 latency.
    /// - Network (TCP, jitter / packet queue): 250ms — TCP buffer drain 시간 보장.
    public var recommendedRetryDelayNanoseconds: UInt64 {
        switch self {
        case .usbSerial: return 100_000_000   // 100ms
        case .network:   return 250_000_000   // 250ms
        }
    }

    /// 종류 SF Symbol icon.
    public var iconSystemName: String {
        switch self {
        case .usbSerial: return "cable.connector"
        case .network:   return "network"
        }
    }

    /// 디버그용 상세 라벨.
    public var detail: String {
        switch self {
        case .usbSerial(let path): return path
        case .network(let host, let port): return "tcp://\(host):\(port)"
        }
    }

    public var isNetwork: Bool {
        if case .network = self { return true } else { return false }
    }
}

public extension Bus {
    /// `Endpoint` 한 번에 받아 Bus 생성. 종류에 따라 USB 또는 TCP.
    convenience init(endpoint: Endpoint) throws {
        switch endpoint {
        case .usbSerial(let path):
            try self.init(portPath: path)
        case .network(let host, let port):
            try self.init(networkHost: host, networkPort: port)
        }
    }
}
