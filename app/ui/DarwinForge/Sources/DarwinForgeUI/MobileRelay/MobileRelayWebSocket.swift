import Foundation
import Network
import CryptoKit

/// Minimal WebSocket server implementation backed by `NWListener` for the
/// Mac DarwinForge MobileRelayServer. Only what the protocol needs:
///
/// - HTTP/1.1 GET handshake on `/mobile-relay` with the standard
///   Sec-WebSocket-Key → Sec-WebSocket-Accept response.
/// - Text frames in both directions (no binary, no continuation), masked
///   client-to-server (per RFC 6455 §5.3) and unmasked server-to-client.
/// - Close frame on disconnect.
///
/// 비유: 비행기 통신 protocol 의 안전 checksum 처럼 — FIN bit, close code,
/// frame size 상한 등 7가지 RFC 6455 규칙이 데이터 무결성을 보장한다.
///
/// V296 compliance additions:
/// - FIN bit 검증 (RFC 6455 §5.4): fragmented frame reject
/// - Close frame status code 1000 (RFC 6455 §5.5.1)
/// - NWListener.failed → onListenerFailed callback
/// - NWConnection.waiting state 처리 (log + hint)
/// - includePeerToPeer server-side 활성화
/// - Frame size enforcement ≤ 256 KiB (DoS guard)
/// - Upgrade/Connection 헤더 검증 (RFC 6455 §4.2.1)
public final class MobileRelayWebSocketServer: @unchecked Sendable {

    public typealias OnConnect = @Sendable (RelayClientChannel, Data) async -> Void
    public typealias OnFrame = @Sendable (Data, RelayClientChannel) async -> Void
    public typealias OnDisconnect = @Sendable (RelayClientChannel, String) async -> Void
    /// V296-4: listener 실패 시 호출 — MobileRelayController 가 UI 에 반영.
    public typealias OnListenerFailed = @Sendable (String) async -> Void

    /// V296-7: 단일 WebSocket frame 최대 허용 바이트 수 (256 KiB).
    /// 초과 시 1008 policyViolation close frame 전송 후 연결 종료.
    static let maxFrameSize = 262_144

    public let listenerPort: UInt16
    public let bonjourServiceName: String
    private let queue = DispatchQueue(label: "darwinforge.mobile.relay.ws")
    private var listener: NWListener?

    /// V297-3: NWListener 가 port: 0 으로 기동했을 때 OS 가 할당한 실제 바인딩 포트.
    /// `.ready` 상태 이전에는 NWListener.port 가 nil 이므로 이 accessor 도 nil 반환.
    /// 0 은 "미할당"을 의미하므로 필터링한다.
    ///
    /// 비유: 항구에 배를 정박시키면 항구가 실제 접안 번호를 할당 — 입력값(0) 과
    /// 실제 할당 번호(예: 52341)는 다르다.
    public var boundPort: UInt16? {
        guard let port = listener?.port, port.rawValue != 0 else { return nil }
        return UInt16(port.rawValue)
    }

    /// V297-3: port: 0 기동 시 NWListener 가 `.ready` 상태가 되고 에페메럴 포트를
    /// 할당할 때까지 비동기 대기한다. 실제 포트 번호를 반환하거나 timeout 시 throw.
    ///
    /// 비유: 항구 관제탑이 "접안 번호 52341 번 준비 완료" 무전을 보낼 때까지 대기.
    public func startAndWaitForPort(timeoutSeconds: Double = 5.0) async throws -> UInt16 {
        try start()
        return try await withThrowingTaskGroup(of: UInt16.self) { group in
            group.addTask {
                while true {
                    if let port = self.boundPort { return port }
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms polling
                }
            }
            group.addTask {
                let ns = UInt64(timeoutSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw MobileRelayWebSocketServerError.portNotBound
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    private var clientsLock = NSLock()
    private var clients: [String: WSChannel] = [:]

    public let onConnect: OnConnect
    public let onFrame: OnFrame
    public let onDisconnect: OnDisconnect
    /// V296-4: nil 이면 실패를 조용히 무시 (기존 동작과 호환).
    public let onListenerFailed: OnListenerFailed?

    public init(port: UInt16 = 17370,
                bonjourServiceName: String = ProcessInfo.processInfo.hostName,
                onConnect: @escaping OnConnect,
                onFrame: @escaping OnFrame,
                onDisconnect: @escaping OnDisconnect,
                onListenerFailed: OnListenerFailed? = nil) {
        self.listenerPort = port
        self.bonjourServiceName = bonjourServiceName
        self.onConnect = onConnect
        self.onFrame = onFrame
        self.onDisconnect = onDisconnect
        self.onListenerFailed = onListenerFailed
    }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // V296-6: server 쪽에도 includePeerToPeer 활성화 — browser 와 일관성 유지.
        params.includePeerToPeer = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenerPort)!)
        l.service = NWListener.Service(name: bonjourServiceName,
                                       type: MobileRelayWireProtocol.bonjourServiceType)
        // V296-4: listener 실패 시 onListenerFailed callback 호출.
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                let msg = "listener.failed: \(err)"
                Task { await self?.onListenerFailed?(msg) }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(connection: conn)
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        clientsLock.lock()
        let snapshot = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()
        for c in snapshot { c.cancel(reason: "serverStopping") }
        listener?.cancel()
        listener = nil
    }

    public func paired(at host: String) -> String? {
        // Caller can format the QR URL by combining their LAN IP with `listenerPort`.
        _ = host
        return nil
    }

    // MARK: - Accept

    private func accept(connection: NWConnection) {
        let channel = WSChannel(connection: connection, owner: self)
        clientsLock.lock()
        clients[channel.clientId] = channel
        clientsLock.unlock()
        channel.start()
    }

    fileprivate func removeClient(_ id: String) {
        clientsLock.lock()
        clients.removeValue(forKey: id)
        clientsLock.unlock()
    }
}

// MARK: - Per-connection state machine

final class WSChannel: RelayClientChannel, @unchecked Sendable {

    let clientId: String = UUID().uuidString
    private let connection: NWConnection
    private weak var owner: MobileRelayWebSocketServer?
    private let queue = DispatchQueue(label: "darwinforge.mobile.relay.ws.channel")
    private var handshakeDone = false
    private var firstAppFrameDelivered = false
    /// V297-9 CRITICAL-2: hello 처리 완료 (onConnect await 끝) 후에만 true.
    /// priority bypass 가 hello 처리 전 estop 받아 actor 에서 alreadyOwned 거절되는
    /// 회로 차단. 종전 firstAppFrameDelivered 는 frame parse 시점에 set 되어
    /// onConnect 의 acceptHello 완료 전에 priority frame 이 chain 우회로 actor 진입 가능.
    private var handshakeAccepted = false
    private var buffer = Data()
    private var disconnected = false
    /// V297-4 frame ordering — Task chain.
    ///
    /// # 종전 (race)
    ///
    /// 각 frame 마다 독립 Task spawn → Task 실행 순서 무보장. hello 보다 heartbeat 가
    /// 먼저 actor 에 진입하면 `guard let session` 실패 → respondRejected(alreadyOwned).
    /// iOS 가 welcome 받기 전엔 heartbeat 안 보내므로 보통 트리거 안 되지만 리팩터에 취약.
    ///
    /// # 신규 (serial Task chain)
    ///
    /// 각 새 Task 가 이전 Task 의 `.value` 를 await 한 후 자기 처리. parseFrames 가
    /// 단일 queue 위에서 sync 호출이라 `taskChain` 변수 자체 race 없음. 결과적으로
    /// 모든 frame 이 도착 순서대로 처리됨.
    ///
    /// 비유: 자판기에 줄 서기 — 동전이 동시에 들어가도 처리는 한 명씩.
    private var taskChain: Task<Void, Never>?

    init(connection: NWConnection, owner: MobileRelayWebSocketServer) {
        self.connection = connection
        self.owner = owner
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed(let err):
                Task { await self.owner?.onDisconnect(self, "failed: \(err)") }
                self.cancel(reason: "failed")
            case .cancelled:
                Task { await self.owner?.onDisconnect(self, "cancelled") }
            // V296-5: waiting = NWConnection 이 viability 회복 대기 중.
            // 재연결은 NWConnection 이 자동 시도. UI hint 만 남기고 대기.
            case .waiting(let err):
                // NWConnection 내부에서 재연결 재시도 — 강제 종료하지 않음.
                // 반복 waiting 은 caller 가 timeout 로 처리.
                _ = err // log 용; 향후 HarnessLog 연동 가능
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete || error != nil {
                self.cancel(reason: error.map { "\($0)" } ?? "eof")
            } else {
                self.receive()
            }
        }
    }

    private func process() {
        if !handshakeDone {
            tryParseHandshake()
        }
        if handshakeDone {
            parseFrames()
        }
    }

    // MARK: - Handshake

    private func tryParseHandshake() {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            cancel(reason: "badHeader"); return
        }
        let lines = headerString.split(separator: "\r\n").map(String.init)
        guard let requestLine = lines.first,
              requestLine.uppercased().hasPrefix("GET ") else {
            cancel(reason: "nonGET"); return
        }
        // GET /mobile-relay HTTP/1.1
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[1] == MobileRelayWireProtocol.webSocketPath else {
            sendStatus(code: 404, body: "Not Found")
            cancel(reason: "wrongPath"); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        // V296-8: Upgrade + Connection 헤더 검증 (RFC 6455 §4.2.1, case-insensitive).
        // 항공 통신의 교신 확인 절차처럼 — 양측이 동일 프로토콜임을 명시해야 연결 수립.
        let upgradeHeader = headers["upgrade"] ?? ""
        guard upgradeHeader.lowercased() == "websocket" else {
            sendStatus(code: 400, body: "Missing or invalid Upgrade: websocket header")
            cancel(reason: "missingUpgradeHeader"); return
        }
        let connectionHeader = headers["connection"] ?? ""
        guard connectionHeader.lowercased().contains("upgrade") else {
            sendStatus(code: 400, body: "Missing or invalid Connection: Upgrade header")
            cancel(reason: "missingConnectionHeader"); return
        }
        guard let secKey = headers["sec-websocket-key"] else {
            sendStatus(code: 400, body: "Missing Sec-WebSocket-Key")
            cancel(reason: "missingKey"); return
        }
        let acceptToken = WebSocketHandshake.accept(for: secKey)
        let response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptToken)\r\n\r\n"
        connection.send(content: Data(response.utf8),
                        completion: .contentProcessed { _ in })
        handshakeDone = true
    }

    private func sendStatus(code: Int, body: String) {
        let resp = "HTTP/1.1 \(code)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(resp.utf8),
                        completion: .contentProcessed { _ in })
    }

    // MARK: - Frame parsing

    private func parseFrames() {
        while true {
            let frame: ParsedFrame
            do {
                guard let f = try popFrame() else { break }
                frame = f
            } catch WSError.incomplete {
                break
            } catch WSError.frameTooLarge {
                // V296-7: frame 크기 초과 → 1008 policyViolation close 전송 후 종료.
                cancelWith1008(reason: "frameTooLarge")
                return
            } catch WSError.fragmentedFrame {
                // V296-2: FIN=false → fragmented message reject.
                cancel(reason: "fragmentedFrame")
                return
            } catch {
                cancel(reason: "badFrame")
                return
            }
            switch frame.opcode {
            case .text, .binary:
                // V297-5/9 priority bypass + handshakeAccepted 가드.
                //
                // priority command (pilot.estop/stop) 는 ARM battery wait 같은 long
                // command 와 별도 Task 로 즉시 dispatch — chain 우회. 단 그 우회 자체는
                // **handshakeAccepted == true** 일 때만 (acceptHello 완료 후) 활성화.
                //
                // V297-9 CRITICAL-2: hello 처리 완료 전 priority frame 이 actor 에
                // 도달하면 session.channel.clientId 가 새 channel 과 미일치 →
                // alreadyOwned reject → estop 유실. 그래서 handshakeAccepted=false
                // 동안은 priority 도 chain 대기.
                let priorityType = WSChannel.peekPriorityType(frame.payload,
                                                              firstFrameDelivered: handshakeAccepted)
                if priorityType != nil {
                    // bypass — 즉시 dispatch (handshake 완료 보장됨).
                    Task { [self, frame] in
                        await self.owner?.onFrame(frame.payload, self)
                    }
                } else {
                    // 기존 chain 직렬화.
                    let previous = taskChain
                    taskChain = Task { [self, frame] in
                        await previous?.value
                        if self.firstAppFrameDelivered {
                            await self.owner?.onFrame(frame.payload, self)
                        } else {
                            self.firstAppFrameDelivered = true
                            // V297-9 CRITICAL-2: handshakeAccepted 는 onConnect (=
                            // acceptHello) 완료 **후** 에 set. 그래야 priority bypass 가
                            // 그 전 frame 을 chain 으로 강제할 수 있다.
                            await self.owner?.onConnect(self, frame.payload)
                            self.handshakeAccepted = true
                        }
                    }
                }
            case .close:
                cancel(reason: "peerClose")
                return
            case .ping:
                sendPong(payload: frame.payload)
            case .pong:
                break
            case .continuation:
                // MVP rejects fragmented frames — protocol envelopes always
                // fit in a single frame.
                cancel(reason: "fragmentedFrame")
                return
            }
        }
    }

    private struct ParsedFrame {
        let opcode: Opcode
        let payload: Data
    }

    private enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    private enum WSError: Error {
        case incomplete
        case badFrame
        /// V296-2: FIN=0 data frame — fragmented message, not supported.
        case fragmentedFrame
        /// V296-7: frame payload 가 maxFrameSize(256 KiB) 초과.
        case frameTooLarge
    }

    private func popFrame() throws -> ParsedFrame? {
        guard buffer.count >= 2 else { throw WSError.incomplete }
        let bytes = [UInt8](buffer)
        // V296-2: FIN bit 검증 (RFC 6455 §5.4).
        // 비유: 전보의 "끝" 신호처럼 — FIN=0 은 아직 더 올 데이터가 있다는 의미.
        // 단편화된 frame 은 MVP에서 미지원 → continuation 과 동일하게 거부.
        let fin = (bytes[0] & 0x80) != 0
        let opcodeRaw = bytes[0] & 0x0F
        guard let opcode = Opcode(rawValue: opcodeRaw) else {
            throw WSError.badFrame
        }
        // non-FIN data frame = fragmented message 의 시작 → reject.
        // Control frames (close/ping/pong) 은 항상 FIN=1 이어야 하므로 동일 적용.
        guard fin else {
            throw WSError.fragmentedFrame
        }
        let masked = (bytes[1] & 0x80) != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { throw WSError.incomplete }
            length = (Int(bytes[2]) << 8) | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { throw WSError.incomplete }
            length = 0
            for i in 2..<10 { length = (length << 8) | Int(bytes[i]) }
            offset = 10
        }
        // V296-7: frame size 상한 256 KiB 사전 enforcement (DoS guard).
        // 비유: 공항 수하물 무게 제한처럼 — 허용량 초과는 탑승 전 거부.
        guard length <= MobileRelayWebSocketServer.maxFrameSize else {
            throw WSError.frameTooLarge
        }
        var maskKey: [UInt8] = []
        if masked {
            guard bytes.count >= offset + 4 else { throw WSError.incomplete }
            maskKey = Array(bytes[offset..<offset + 4])
            offset += 4
        }
        guard bytes.count >= offset + length else { throw WSError.incomplete }
        var payload = Array(bytes[offset..<offset + length])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: offset + length))
        return ParsedFrame(opcode: opcode, payload: Data(payload))
    }

    // MARK: - Send

    func deliver(_ frame: Data) async throws {
        try await sendText(frame)
    }

    /// V297-5 CRITICAL-1: frame payload head sniff for priority bypass.
    ///
    /// - Parameters:
    ///   - payload: WebSocket frame text payload (RelayEnvelope JSON).
    ///   - firstFrameDelivered: hello 이미 전달됐는지. false 면 priority 분류 불요
    ///     (priority command 는 hello 다음에만 의미).
    /// - Returns: priority type string 또는 nil. 디코드 실패는 nil (일반 chain).
    // V297-9 MEDIUM-2: internal 노출 — 단위 테스트가 handshakeAccepted 가드 동작 검증.
    internal static func peekPriorityType(_ payload: Data,
                                          firstFrameDelivered: Bool) -> String? {
        guard firstFrameDelivered else { return nil }
        guard let head = try? RelayCodec.decoder.decode(RelayEnvelopeHead.self,
                                                        from: payload) else {
            return nil
        }
        return MobileRelayWireProtocol.isPriorityCommand(head.type) ? head.type : nil
    }

    private func sendText(_ data: Data) async throws {
        var header: [UInt8] = [0x81] // FIN + text
        let len = data.count
        if len < 126 {
            header.append(UInt8(len))
        } else if len < 65_536 {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            for i in (0..<8).reversed() {
                header.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }
        var packet = Data(header)
        packet.append(data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func sendPong(payload: Data) {
        var header: [UInt8] = [0x8A]
        if payload.count < 126 {
            header.append(UInt8(payload.count))
        } else {
            header.append(126)
            header.append(UInt8((payload.count >> 8) & 0xFF))
            header.append(UInt8(payload.count & 0xFF))
        }
        var packet = Data(header)
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    func disconnect(reason: String) async {
        cancel(reason: reason)
    }

    func cancel(reason: String) {
        guard !disconnected else { return }
        disconnected = true
        // V296-3: Close frame with status 1000 (normalClosure) — RFC 6455 §5.5.1.
        // [0x88] = FIN + close opcode, [0x02] = 2-byte payload,
        // [0x03, 0xE8] = 1000 (0x03E8) = normal closure.
        // 비유: 통화 종료 시 "안녕히 계세요"처럼 — 정상 종료를 명시.
        let closeFrame: [UInt8] = [0x88, 0x02, 0x03, 0xE8]
        connection.send(content: Data(closeFrame),
                        completion: .contentProcessed { _ in })
        connection.cancel()
        owner?.removeClient(clientId)
    }

    /// V296-7: frame size 초과 시 RFC 6455 §7.4.1 status 1008 (policyViolation) 전송.
    private func cancelWith1008(reason: String) {
        guard !disconnected else { return }
        disconnected = true
        // [0x88] = FIN + close, [0x02] = 2-byte payload,
        // [0x03, 0xF0] = 1008 (0x03F0) = policy violation.
        let closeFrame: [UInt8] = [0x88, 0x02, 0x03, 0xF0]
        connection.send(content: Data(closeFrame),
                        completion: .contentProcessed { _ in })
        connection.cancel()
        owner?.removeClient(clientId)
    }
}

// MARK: - MobileRelayWebSocketServer errors

public enum MobileRelayWebSocketServerError: Error, Sendable {
    /// V297-3: port: 0 으로 기동 후 timeout 내에 바인딩 포트 할당이 완료되지 않음.
    case portNotBound
}

// MARK: - WebSocket handshake helper

public enum WebSocketHandshake {
    public static let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func accept(for clientKey: String) -> String {
        let combined = clientKey + magic
        let digest = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(digest).base64EncodedString()
    }
}

