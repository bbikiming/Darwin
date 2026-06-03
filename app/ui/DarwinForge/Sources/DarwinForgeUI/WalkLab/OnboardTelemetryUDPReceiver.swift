import Foundation
import Network
import OSLog

/// **텔레메트리 UDP 푸시 수신기 (2026-06-03)** — robot→Mac 온보드 텔레메트리 push 경로.
///
/// 비유: 종전엔 Mac이 0.5초마다 로봇 우편함(`/tmp/df-walklab-telemetry`)을 SSH로 열어
/// 엽서를 꺼내 읽었다(폴링). 이제는 로봇이 같은 엽서를 **우체부처럼 Mac 우편함으로
/// 직접 던져 넣는다**(UDP push). Mac은 받기만 하면 되니 폴링 대기·SSH 실행 비용이 사라져
/// 신선도가 ≈2Hz → 10–30Hz, 1 RTT(유선 ~1ms)로 도착한다.
///
/// # Pipeline
/// ```
///  robot brokerage ──UDP(telemetryUDPPort)──▶ NWListener (Mac)
///     (매 poll, 10–30Hz)                              │
///                                                     ▼
///                              Data → String → OnboardTelemetry.parse
///                                                     │
///                                                     ▼
///                          onSample(OnboardTelemetry) — caller가 @MainActor hop
///                                                     │
///                                                     ▼
///                          ConnectionStore.ingestOnboardTelemetry(_:)
/// ```
///
/// SSH 폴러(`OnboardTelemetryPoller`)와 **동일한 `OnboardTelemetry.parse` 와 동일한 ingest
/// 경로**를 공유한다 — 파서/게이트 로직이 두 transport 간에 갈라지지 않는다. 둘은 fallback
/// 관계: UDP가 살아있으면 ts가 더 빨리 전진해 primary가 되고, UDP가 끊기면(무선 AP isolation
/// 등) SSH 폴러가 계속 fresh 샘플을 공급한다(ConnectionStore의 ts-전진 dedup이 중복을 무시).
///
/// # Mock-first
/// `TelloStateListener` 와 동일하게 `OnboardTelemetryUDPReceiverProtocol` 추상화 —
/// 실 socket 없이 XCTest에서 `MockOnboardTelemetryUDPReceiver.simulate(raw:)` 로 검증.
/// 실 구현은 `init` 시 socket을 열지 **않음** — `start()` 명시 호출 후에만 bind.
///
/// # 에러 처리
/// - parse 실패(깨진 datagram) → OSLog warning + 다음 datagram 대기.
/// - socket 에러(bind 실패/interface down) → OSLog error + 콜백 미발화. 재시작은 caller 책임.
///   bind 실패 시에도 SSH 폴러가 fallback이므로 텔레메트리가 끊기지 않는다.
public protocol OnboardTelemetryUDPReceiverProtocol: AnyObject, Sendable {
    /// listen 시작 — UDP socket bind. 이미 시작됐으면 no-op.
    func start() throws
    /// listen 종료 — socket close. idempotent.
    func stop()
    /// 샘플 수신 시 발화. @MainActor 미보장 — caller가 main actor hop 처리.
    var onSample: (@Sendable (OnboardTelemetry) -> Void)? { get set }
}

/// 실 UDP 구현 — macOS Network framework `NWListener`.
///
/// # 동시성 모델
/// `@unchecked Sendable` — 내부 mutable state(listener/connections)는 전용 serial queue
/// 에서만 변경. NWListener/NWConnection이 Sendable 미준수 → unchecked로 escape 후 queue
/// 격리로 보장 (`TelloStateListener` 와 동일 패턴).
public final class OnboardTelemetryUDPReceiver: OnboardTelemetryUDPReceiverProtocol, @unchecked Sendable {

    /// 텔레메트리 UDP 업링크 포트 — `DFConnectionConstants` 계약값(로봇 sendto 대상과 일치).
    /// rawValue는 컴파일타임 상수(유효 범위) → 강제 언랩 안전.
    public static let defaultPort: NWEndpoint.Port =
        NWEndpoint.Port(rawValue: DFConnectionConstants.telemetryUDPPort)!

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "OnboardTelemetryUDPReceiver.udp", qos: .userInitiated)
    private let log = Logger(subsystem: "DarwinForge", category: "OnboardTelemetryUDPReceiver")

    // queue 격리 — 외부 접근 금지.
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var _onSample: (@Sendable (OnboardTelemetry) -> Void)?

    /// 콜백 — setter/getter는 serial queue로 격리.
    public var onSample: (@Sendable (OnboardTelemetry) -> Void)? {
        get { queue.sync { _onSample } }
        set { queue.sync { _onSample = newValue } }
    }

    public init(port: NWEndpoint.Port = OnboardTelemetryUDPReceiver.defaultPort) {
        self.port = port
    }

    deinit {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    public func start() throws {
        // 이미 listen 중이면 no-op.
        if listener != nil { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true   // 재연결 시 bind 경합 방지.
        let listener = try NWListener(using: params, on: port)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async { self.connections.append(conn) }
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
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    // MARK: - Internal receive loop

    /// `NWConnection.receiveMessage` 재귀 — UDP datagram 단위 수신.
    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error = error {
                self.log.error("recv error: \(error.localizedDescription, privacy: .public)")
                if conn.state != .cancelled { self.receive(on: conn) }
                return
            }
            if let data = data, !data.isEmpty {
                self.handle(data: data)
            }
            if conn.state != .cancelled { self.receive(on: conn) }
        }
    }

    private func handle(data: Data) {
        guard let raw = String(data: data, encoding: .utf8) else {
            log.warning("Non-UTF8 payload — dropped (\(data.count, privacy: .public) bytes)")
            return
        }
        // **기존 파서 재사용** — SSH 폴러와 동일 검증/범위 가드(§A.2/§A.3). 깨진 datagram은 nil.
        guard let sample = OnboardTelemetry.parse(raw) else {
            log.warning("Parse failed for datagram: \(raw, privacy: .public)")
            return
        }
        _onSample?(sample)
    }
}
