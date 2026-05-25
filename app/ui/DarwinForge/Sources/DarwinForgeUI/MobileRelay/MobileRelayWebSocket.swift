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
/// Larger frames are bounded at 64 KiB; the protocol payloads are well
/// under that and walking commands are <1 KiB.
public final class MobileRelayWebSocketServer: @unchecked Sendable {

    public typealias OnConnect = @Sendable (RelayClientChannel, Data) async -> Void
    public typealias OnFrame = @Sendable (Data, RelayClientChannel) async -> Void
    public typealias OnDisconnect = @Sendable (RelayClientChannel, String) async -> Void

    public let listenerPort: UInt16
    public let bonjourServiceName: String
    private let queue = DispatchQueue(label: "darwinforge.mobile.relay.ws")
    private var listener: NWListener?
    private var clientsLock = NSLock()
    private var clients: [String: WSChannel] = [:]

    public let onConnect: OnConnect
    public let onFrame: OnFrame
    public let onDisconnect: OnDisconnect

    public init(port: UInt16 = 17370,
                bonjourServiceName: String = ProcessInfo.processInfo.hostName,
                onConnect: @escaping OnConnect,
                onFrame: @escaping OnFrame,
                onDisconnect: @escaping OnDisconnect) {
        self.listenerPort = port
        self.bonjourServiceName = bonjourServiceName
        self.onConnect = onConnect
        self.onFrame = onFrame
        self.onDisconnect = onDisconnect
    }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenerPort)!)
        l.service = NWListener.Service(name: bonjourServiceName,
                                       type: MobileRelayWireProtocol.bonjourServiceType)
        l.stateUpdateHandler = { state in
            // Could surface to UI; for now we let the listener live.
            _ = state
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
    private var buffer = Data()
    private var disconnected = false

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
        while let frame = try? popFrame() {
            switch frame.opcode {
            case .text, .binary:
                Task { [self, frame] in
                    if self.firstAppFrameDelivered {
                        await self.owner?.onFrame(frame.payload, self)
                    } else {
                        self.firstAppFrameDelivered = true
                        await self.owner?.onConnect(self, frame.payload)
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

    private enum WSError: Error { case incomplete, badFrame }

    private func popFrame() throws -> ParsedFrame? {
        guard buffer.count >= 2 else { throw WSError.incomplete }
        let bytes = [UInt8](buffer)
        let opcodeRaw = bytes[0] & 0x0F
        guard let opcode = Opcode(rawValue: opcodeRaw) else {
            throw WSError.badFrame
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
        let closeFrame: [UInt8] = [0x88, 0x00]
        connection.send(content: Data(closeFrame),
                        completion: .contentProcessed { _ in })
        connection.cancel()
        owner?.removeClient(clientId)
    }
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
