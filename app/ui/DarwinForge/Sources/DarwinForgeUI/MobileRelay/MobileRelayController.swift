import Foundation
import SwiftUI
import Combine
import Network

/// SwiftUI-friendly façade around `MobileRelayServer + WebSocket transport
/// + pairing + telemetry pump`. Owns lifecycle; wire it into the existing
/// Mac app from your top-level RootView via `@StateObject`.
///
/// Production wiring (recommended):
/// ```swift
/// @StateObject private var mobileRelay = MobileRelayController(
///     port: ConnectionStoreSafetyPort(store: connectionStore)
/// )
/// ```
/// then call `.start()` when the user flips the "Mobile Pilot Relay" toggle.
@MainActor
public final class MobileRelayController: ObservableObject {

    @Published public private(set) var isRunning = false
    @Published public private(set) var pairingCode: String = MobileRelayPairing.generateCode()
    @Published public private(set) var listenPort: UInt16
    @Published public private(set) var activeIPhoneName: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var advertisedHost: String = ""
    /// 최근 페어링 시도 횟수 (최근 5분 내). MobilePilotTile 표시용.
    @Published public private(set) var recentPairingAttempts: Int = 0

    private var server: MobileRelayServer?
    private var ws: MobileRelayWebSocketServer?
    private let pairing: MobileRelayPairing
    private var port: RobotSafetyPort
    /// Mac-side 배터리 전압 클로저 (V291-10, defense-in-depth).
    /// MobileRelayBootstrap 이 rebindHooks() 시점에 swapBatteryVoltage 로 주입.
    /// nil 기본값 → ARM reject (보수 정책; 주입 전 시동 방지).
    private var batteryVoltage: @Sendable () async -> Double? = { nil }
    private var telemetryTask: Task<Void, Never>?
    private let pairingStore: PersistedPairingStore
    private let harness: any HarnessFacade

    public init(port: RobotSafetyPort,
                listenPort: UInt16 = 17370,
                initialCode: String? = nil,
                pairingStore: PersistedPairingStore = PersistedPairingStore(),
                harness: (any HarnessFacade)? = nil) {
        self.port = port
        self.listenPort = listenPort
        self.pairingStore = pairingStore
        self.harness = harness ?? LiveHarness.shared
        // 저장된 code 우선 사용; 없으면 새로 생성해 persist.
        let resolvedCode: String
        if let stored = pairingStore.read() {
            resolvedCode = stored
        } else {
            let fresh = initialCode ?? MobileRelayPairing.generateCode()
            pairingStore.write(fresh)
            resolvedCode = fresh
        }
        self.pairing = MobileRelayPairing(initialCode: resolvedCode)
        self.pairingCode = resolvedCode
    }

    /// Swap the underlying safety port (used by `MobileRelayBootstrap` to
    /// upgrade from a placeholder to a live port once the SwiftUI view tree
    /// has wired the channel/store on MainActor).
    ///
    /// If the relay is running, the new port takes effect on the *next*
    /// command — in-flight commands already routed through the previous port
    /// still use it.
    public func swapPort(_ newPort: RobotSafetyPort) {
        self.port = newPort
        // If a server is already running, rebuild it with the new port so the
        // hot path sees the live hooks immediately.
        if isRunning {
            Task {
                await stop()
                await start()
            }
        }
    }

    /// V291-10: Mac-side battery voltage 클로저를 교체한다.
    /// MobileRelayBootstrap 이 rebindHooks() 완료 후 호출 — 이후 ARM 명령이
    /// 실제 ConnectionStore 전압으로 재검증된다.
    public func swapBatteryVoltage(_ closure: @escaping @Sendable () async -> Double?) {
        self.batteryVoltage = closure
        // 실행 중이면 서버 재시작해 클로저 반영.
        if isRunning {
            Task {
                await stop()
                await start()
            }
        }
    }

    public func start() async {
        guard !isRunning else { return }
        let batterySnap = batteryVoltage
        let server = MobileRelayServer(
            configuration: .init(macName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                                 macVersion: appVersionString()),
            pairing: pairing,
            port: port,
            harness: harness,
            batteryVoltage: batterySnap)
        let ws = MobileRelayWebSocketServer(
            port: listenPort,
            bonjourServiceName: Host.current().localizedName ?? "DarwinForge",
            onConnect: { channel, data in
                await server.handleClientConnected(channel, handshake: data)
            },
            onFrame: { data, channel in
                await server.handleClientFrame(data, from: channel)
            },
            onDisconnect: { channel, reason in
                await server.handleClientDisconnected(channel, reason: reason)
            })
        do {
            try ws.start()
            self.server = server
            self.ws = ws
            self.isRunning = true
            self.lastError = nil
            self.advertisedHost = MobileRelayController.firstLocalIPv4() ?? ""
            startTelemetryPump()
        } catch {
            self.lastError = String(describing: error)
        }
    }

    public func stop() async {
        telemetryTask?.cancel()
        telemetryTask = nil
        if let server { await server.closeSession(reason: "userStop") }
        ws?.stop()
        ws = nil
        server = nil
        isRunning = false
        activeIPhoneName = nil
    }

    public func rotatePairingCode() {
        let newCode = pairing.rotate()
        pairingStore.write(newCode)
        pairingCode = newCode
        harness.record(.mobilePilotCodeRotated, level: .info, actor: .user,
                       data: ["source": "manual"])
    }

    public func qrPayload() -> String {
        let payload = PairingQRPayload(host: advertisedHost.isEmpty ? "<your-mac>" : advertisedHost,
                                       port: Int(listenPort),
                                       pairingCode: pairingCode)
        return (try? payload.encode()) ?? "{}"
    }

    private func startTelemetryPump() {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                if let server = await self?.server {
                    await server.broadcastTelemetry()
                    // P1-2 fix (truth-gap report, 2026-05-25): refresh
                    // activeIPhoneName from the server's session state so the
                    // Mac toolbar chip reflects "연결됨" reliably (not only on
                    // first hello). nil = no active session → chip → 대기.
                    let deviceName = await server.currentDeviceName()
                    if deviceName != self?.activeIPhoneName {
                        await MainActor.run { self?.activeIPhoneName = deviceName }
                    }
                }
                // lockout 으로 인해 pairing 내부에서 code 가 회전한 경우
                // controller 의 published 값과 persist 를 동기화하고 telemetry 기록.
                if let self {
                    let live = self.pairing.currentCode()
                    if live != self.pairingCode {
                        self.pairingStore.write(live)
                        self.pairingCode = live
                        self.harness.record(.mobilePilotCodeRotated, level: .warn,
                                            actor: .system, data: ["source": "lockout"])
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func appVersionString() -> String {
        let b = Bundle.main
        let v = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let n = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v)+\(n)"
    }

    /// Best-effort LAN IPv4 used when rendering the QR code. Returns nil if
    /// the host has no IPv4 interfaces (unlikely on a Mac).
    public static func firstLocalIPv4() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let pointee = ptr?.pointee,
                  pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) != 0 { continue }
            if (flags & IFF_UP) == 0 { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(pointee.ifa_addr,
                           socklen_t(pointee.ifa_addr.pointee.sa_len),
                           &hostBuf, socklen_t(hostBuf.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                if let host = String(validatingUTF8: hostBuf), !host.isEmpty {
                    return host
                }
            }
        }
        return nil
    }
}

#if canImport(SwiftUI)
public struct MobileRelayPanel: View {

    @ObservedObject var controller: MobileRelayController

    public init(controller: MobileRelayController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "iphone.gen2.radiowaves.left.and.right")
                    .font(.title2)
                Text("Mobile Pilot Relay")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { controller.isRunning },
                    set: { newValue in
                        Task {
                            if newValue { await controller.start() }
                            else { await controller.stop() }
                        }
                    }
                ))
                .labelsHidden()
            }
            if controller.isRunning {
                Text("Host: \(controller.advertisedHost.isEmpty ? "—" : controller.advertisedHost):\(controller.listenPort)")
                    .font(.caption.monospacedDigit())
                HStack {
                    Text("Pairing")
                        .foregroundStyle(.secondary)
                    Text(controller.pairingCode)
                        .font(.title3.monospaced())
                    Button("재발급") { controller.rotatePairingCode() }
                        .buttonStyle(.borderless)
                }
                // QR 코드 이미지 — iPhone 카메라로 직접 스캔 가능
                VStack(spacing: DFSpace.xs) {
                    QRCodeImage(payload: controller.qrPayload(), size: 160)
                        .accessibilityLabel(
                            "페어링 QR 코드, JSON 페이로드 \(controller.advertisedHost) \(controller.listenPort)"
                        )
                    Text("iPhone 카메라로 스캔하세요")
                        .font(DFFont.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DFSpace.xs)
                Text("QR payload")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(controller.qrPayload())
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
            } else {
                Text("Off — iPhone에서 연결할 수 없어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = controller.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
