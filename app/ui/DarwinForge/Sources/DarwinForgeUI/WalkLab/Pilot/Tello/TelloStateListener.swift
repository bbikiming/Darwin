import Foundation
import Network
import OSLog

/// **v1.20.34 (2026-05-22) 사이클 17 — Tello state UDP listener**.
///
/// Tello SDK 2.0 의 state port (UDP 8890) 를 NWListener 로 수신 → ASCII payload 를
/// `TelloStateMessageParser.parse` 로 struct 변환 → `onState` callback 발화.
///
/// # Pipeline
///
/// ```
///  Tello drone  ──UDP 8890──▶  NWListener (host)
///       (≈5-10 Hz)                    │
///                                     ▼
///                       Data → String (ASCII)
///                                     │
///                                     ▼
///                       TelloStateMessageParser.parse
///                                     │
///                                     ▼
///                  onState(TelloStateMessage) — @MainActor hop
///                                     │
///                                     ▼
///                  WalkLabRCBridge.updateTelloState(_:)
/// ```
///
/// # Mock-first
///
/// 실 hardware 없이 검증 가능하도록 `TelloStateListenerProtocol` 추상화 — XCTest 에서
/// `MockTelloStateListener` 가 `simulate(_:)` 로 임의 메시지 enqueue → callback 발화 확인.
/// 본 모듈의 실 구현 (`TelloStateListener`) 은 `init` 시 socket 을 열지 **않음** — `start()`
/// 명시 호출 후에만 listen 시작. 종료는 `stop()` (idempotent).
///
/// # 에러 처리 정책
///
/// - parse 실패 (불완전 메시지) → OSLog warning + 다음 패킷 대기 (listen 계속).
/// - socket 에러 (interface down 등) → OSLog error + state callback 미발화.
///   재시작은 caller (예: bridge owner) 의 책임 — 본 모듈은 raw transport 만 담당.
/// - cancellation: `stop()` 이 listener / 모든 NWConnection 의 cancel 발화.
public protocol TelloStateListenerProtocol: AnyObject, Sendable {
    /// listen 시작 — UDP socket bind. 이미 시작된 경우 no-op.
    func start() throws
    /// listen 종료 — socket close. idempotent.
    func stop()
    /// 메시지 수신 시 발화될 closure. @MainActor 호환 — caller 가 main actor hop 처리.
    /// 본 setter 는 thread-safe (immutable assignment 가정 — caller 가 stop 후 set 권장).
    var onState: (@Sendable (TelloStateMessage) -> Void)? { get set }
}

/// 실 UDP 구현 — macOS Network framework `NWListener`.
///
/// # 동시성 모델
///
/// `@unchecked Sendable` — 내부 mutable state (listener, connections) 는 전용 serial
/// queue (`Self.queue`) 상에서만 변경. swift 6 strict concurrency 하에서 NWListener /
/// NWConnection 이 Sendable 미준수 → unchecked 로 escape 후 queue 격리로 보장.
public final class TelloStateListener: TelloStateListenerProtocol, @unchecked Sendable {

    /// Tello SDK 2.0 state port — 고정.
    public static let defaultPort: NWEndpoint.Port = 8890

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "TelloStateListener.udp", qos: .userInitiated)
    private let log = Logger(subsystem: "DarwinForge", category: "TelloStateListener")

    // queue 격리 — 외부 접근 금지.
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var _onState: (@Sendable (TelloStateMessage) -> Void)?

    /// callback — caller 가 set/get. setter 는 serial queue dispatch 로 격리.
    public var onState: (@Sendable (TelloStateMessage) -> Void)? {
        get { queue.sync { _onState } }
        set { queue.sync { _onState = newValue } }
    }

    public init(port: NWEndpoint.Port = TelloStateListener.defaultPort) {
        self.port = port
    }

    deinit {
        // cleanup — caller 가 stop() 호출 안 했어도 socket 누수 방지.
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    public func start() throws {
        // 이미 listen 중이면 no-op.
        if listener != nil { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async {
                self.connections.append(conn)
            }
            self.receive(on: conn)
            conn.start(queue: self.queue)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.log.error("NWListener failed: \(error.localizedDescription, privacy: .public)")
            case .cancelled:
                self.log.debug("NWListener cancelled")
            case .ready:
                self.log.info("NWListener ready on UDP \(self.port.rawValue, privacy: .public)")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    public func stop() {
        // queue 격리 — 모든 mutable state 정리.
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Internal receive loop

    /// `NWConnection.receiveMessage` 재귀 — UDP datagram 단위로 수신.
    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error = error {
                self.log.error("recv error: \(error.localizedDescription, privacy: .public)")
                // socket 살아있으면 계속 listen (단발 에러 무시).
                if conn.state != .cancelled {
                    self.receive(on: conn)
                }
                return
            }
            if let data = data, !data.isEmpty {
                self.handle(data: data)
            }
            // 다음 datagram 대기 — UDP listener pattern.
            if conn.state != .cancelled {
                self.receive(on: conn)
            }
        }
    }

    private func handle(data: Data) {
        guard let raw = String(data: data, encoding: .ascii) else {
            log.warning("Non-ASCII payload — dropped (\(data.count, privacy: .public) bytes)")
            return
        }
        guard let msg = TelloStateMessageParser.parse(raw) else {
            // parse 실패 → 다음 패킷 대기 (broken datagram 무시).
            log.warning("Parse failed for payload: \(raw, privacy: .public)")
            return
        }
        // callback 발화 — caller (bridge) 가 main actor hop 처리.
        _onState?(msg)
    }
}
