import Foundation
import SwiftUI
import Combine
import Network
import Darwin

// MARK: - HostCandidate

/// Mac 에서 사용 가능한 네트워크 인터페이스 후보 — QR 코드에 들어갈 IP 를 선택할 때 사용.
///
/// 비유: 여러 전화번호 중 iPhone 과 같은 교환 망(subnet)에 있는 번호를 고르는 것.
/// 기술: getifaddrs 로 열거한 IPv4 인터페이스를 Wi-Fi 우선·사설 IP 우선으로 정렬.
public struct HostCandidate: Identifiable, Hashable, Sendable {
    /// `"\(ifName)/\(ip)"` — stable unique key.
    public let id: String
    /// 인터페이스 이름 (예: en0, en1).
    public let ifName: String
    /// IPv4 주소 (예: 192.168.0.60).
    public let ip: String
    /// Wi-Fi 인터페이스 여부 (en0~en9 + 사설 IP 휴리스틱).
    public let isWiFi: Bool
    /// RFC-1918 사설 IP 여부 (10/8, 172.16/12, 192.168/16).
    public let isPrivate: Bool

    public init(ifName: String, ip: String, isWiFi: Bool, isPrivate: Bool) {
        self.ifName = ifName
        self.ip = ip
        self.isWiFi = isWiFi
        self.isPrivate = isPrivate
        self.id = "\(ifName)/\(ip)"
    }

    /// UI 표시용 설명 문자열.
    public var displayName: String {
        let kind = isWiFi ? "Wi-Fi" : "유선"
        let scope = isPrivate ? "LAN" : "공인"
        return "\(ifName) — \(ip) (\(kind), \(scope))"
    }
}

// MARK: - RelaySessionState

/// 비행 데이터 레코더처럼 핵심 timeline 항상 보임 — relay 연결의 전 단계를 단일 enum 으로 표현.
///
/// 비유: 항공기 계기판의 연결 상태 표시등처럼, 각 단계(꺼짐·광고·핸드셰이크·페어링·해제·오류)를
/// 명확한 열거형으로 표현해 `activeIPhoneName` 단독 의존의 race condition 을 제거한다.
///
/// `MobileRelayController.sessionState` computed property 로 노출된다.
public enum RelaySessionState: Sendable, Equatable {
    /// relay 가 꺼져 있음 (!isRunning).
    case off
    /// relay 켜짐, iPhone 연결 대기 중 (isRunning, no socket).
    case advertising(code: String)
    /// WebSocket 열림, hello 수신 대기 중 (socket 있음, paired 미완료).
    case handshaking(code: String)
    /// 페어링 완료 — iPhone 과 활성 세션 유지 중.
    case paired(device: String, sessionId: String, since: Date, heartbeatAge: TimeInterval?)
    /// 세션 해제 진행 중 (close in progress).
    case disconnecting(reason: String)
    /// 마지막 에러가 설정된 상태.
    case error(message: String)
}

// MARK: - TimelineEntry

/// iOS↔Mac 연결 단계를 시간순으로 기록한 엔트리.
///
/// 비유: 공항 입국 도장처럼 — 문 열림, 신분증 제출, 도장 찍힘 각 단계를 기록.
/// 기술: ring buffer (max 20) 로 유지. `lifecycleTimeline` @Published 로 노출.
public struct TimelineEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    /// 한글 라벨 — UI 표시용.
    public let event: String
    /// 추가 컨텍스트 (channelId, sessionId 등). nil 가능.
    public let detail: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(),
                event: String, detail: String?) {
        self.id = id
        self.timestamp = timestamp
        self.event = event
        self.detail = detail
    }
}

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
    /// 사용 가능한 IPv4 인터페이스 목록 — Wi-Fi 사설 IP 우선 정렬.
    /// popover picker 가 이 목록을 표시한다.
    @Published public private(set) var availableHosts: [HostCandidate] = []
    /// 최근 페어링 시도 횟수 (최근 5분 내). MobilePilotTile 표시용.
    @Published public private(set) var recentPairingAttempts: Int = 0
    /// **V295-2** — 연결 단계 타임라인 (max 20 ring buffer).
    /// socketOpened → helloReceived → welcomeSent → pairingSuccess → … → disconnect.
    @Published public private(set) var lifecycleTimeline: [TimelineEntry] = []

    // MARK: V295-4 신규 state (source-of-truth 강화)

    /// 활성 세션 ID (server.currentSessionId() 의 mirror). nil = 세션 없음.
    @Published public private(set) var activeSessionId: String?
    /// 페어링 완료 시각. 세션 종료 시 nil 로 초기화.
    @Published public private(set) var pairedSince: Date?
    /// 마지막 heartbeat 수신 시각 (1Hz polling 동기화).
    @Published public private(set) var lastHeartbeatAt: Date?
    /// server.hasActiveSession() 결과 — activeIPhoneName race fallback 용.
    @Published public private(set) var hasActiveSocket: Bool = false

    // MARK: sessionState computed

    /// `RelaySessionState` 로 chip + popover 상태를 단일 enum 으로 제공.
    ///
    /// **V295-4 fallback**: `activeIPhoneName` 갱신 race 가 발생해도
    /// `hasActiveSocket` (= `server.hasActiveSession()`) 이 true 이면
    /// `.handshaking` 을 반환해 chip 이 무한 "대기" 되는 현상을 방지한다.
    public var sessionState: RelaySessionState {
        if let err = lastError { return .error(message: err) }
        guard isRunning else { return .off }
        if let device = activeIPhoneName, let sid = activeSessionId {
            return .paired(device: device,
                           sessionId: sid,
                           since: pairedSince ?? Date(),
                           heartbeatAge: lastHeartbeatAt.map { Date().timeIntervalSince($0) })
        }
        if hasActiveSocket { return .handshaking(code: pairingCode) }
        return .advertising(code: pairingCode)
    }

    private static let timelineMaxEntries = 20
    private static let preferredHostKey = "mobileRelay.preferredHost"

    private var server: MobileRelayServer?
    private var ws: MobileRelayWebSocketServer?
    private let pairing: MobileRelayPairing
    private var port: RobotSafetyPort
    /// Mac-side 배터리 전압 클로저 (V291-10, defense-in-depth).
    /// MobileRelayBootstrap 이 rebindHooks() 시점에 swapBatteryVoltage 로 주입.
    /// nil 기본값 → ARM reject (보수 정책; 주입 전 시동 방지).
    private var batteryVoltage: @Sendable () async -> Double? = { nil }
    private var telemetryTask: Task<Void, Never>?
    // V297-6 (PM Story S2.1): 세션 시작 시각 — burst 모드 판정용.
    // 페어링 완료 시 nil → Date() 로 갱신, 세션 해제 시 nil 리셋.
    private var sessionStartedAt: Date?
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

    /// V295-2: 타임라인에 엔트리 추가 (ring buffer max 20).
    private func appendTimeline(event: String, detail: String?) {
        var updated = lifecycleTimeline
        updated.append(TimelineEntry(event: event, detail: detail))
        if updated.count > MobileRelayController.timelineMaxEntries {
            updated.removeFirst(updated.count - MobileRelayController.timelineMaxEntries)
        }
        lifecycleTimeline = updated
    }

    public func start() async {
        guard !isRunning else { return }
        let batterySnap = batteryVoltage
        // **V293 fix** — server 가 페어링 / 해제 시 즉시 main actor 로 push.
        // weak self 로 retain cycle 방지.
        let pairedSink: @Sendable (String, String) async -> Void = { [weak self] device, sessionId in
            await MainActor.run {
                self?.activeIPhoneName = device
                self?.activeSessionId = sessionId
                self?.pairedSince = Date()
                self?.hasActiveSocket = true
                // V297-6 (PM Story S2.1): 페어링 완료 시 세션 시작 시각 기록 → burst 모드 트리거.
                self?.sessionStartedAt = Date()
                self?.appendTimeline(event: "페어링 완료", detail: device)
            }
        }
        let unpairedSink: @Sendable () async -> Void = { [weak self] in
            await MainActor.run {
                self?.activeIPhoneName = nil
                self?.activeSessionId = nil
                self?.pairedSince = nil
                self?.lastHeartbeatAt = nil
                self?.hasActiveSocket = false
                // V297-6 (PM Story S2.1): 세션 해제 시 시작 시각 리셋.
                self?.sessionStartedAt = nil
                self?.appendTimeline(event: "끊김", detail: nil)
            }
        }
        let lifecycleSink: @Sendable (String, String?) async -> Void = { [weak self] label, detail in
            await MainActor.run { self?.appendTimeline(event: label, detail: detail) }
        }
        let server = MobileRelayServer(
            configuration: .init(macName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                                 macVersion: appVersionString()),
            pairing: pairing,
            port: port,
            harness: harness,
            batteryVoltage: batterySnap,
            onPaired: pairedSink,
            onUnpaired: unpairedSink,
            onLifecycleEvent: lifecycleSink)
        // V296-4: listener 실패 시 UI 에 즉시 반영 — port conflict / OS 오류 visible.
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
            },
            onListenerFailed: { [weak self] errorMessage in
                await MainActor.run {
                    self?.lastError = errorMessage
                    self?.isRunning = false
                }
            })
        do {
            try ws.start()
            self.server = server
            self.ws = ws
            self.isRunning = true
            self.lastError = nil
            let candidates = MobileRelayController.enumerateLocalIPv4Interfaces()
            self.availableHosts = candidates
            // 사용자가 저장한 선호 호스트 → 목록에 있으면 복원, 없으면 Wi-Fi 우선 자동 선택.
            let stored = UserDefaults.standard.string(forKey: MobileRelayController.preferredHostKey)
            if let stored, candidates.contains(where: { $0.ip == stored }) {
                self.advertisedHost = stored
            } else {
                self.advertisedHost = candidates.first?.ip ?? MobileRelayController.firstLocalIPv4() ?? ""
            }
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
        activeSessionId = nil
        pairedSince = nil
        lastHeartbeatAt = nil
        hasActiveSocket = false
        lifecycleTimeline = []
        availableHosts = []
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
                    // V295-4: sync additional session diagnostics from server.
                    let sessionId = await server.currentSessionId()
                    let connectedAt = await server.currentConnectedAt()
                    let heartbeatAt = await server.currentLastHeartbeatAt()
                    let activeSocket = await server.hasActiveSession()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if deviceName != self.activeIPhoneName {
                            self.activeIPhoneName = deviceName
                        }
                        if sessionId != self.activeSessionId {
                            self.activeSessionId = sessionId
                        }
                        if let connectedAt, self.pairedSince == nil {
                            self.pairedSince = connectedAt
                        } else if connectedAt == nil {
                            self.pairedSince = nil
                        }
                        self.lastHeartbeatAt = heartbeatAt
                        self.hasActiveSocket = activeSocket
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
                // V297-6 (PM Story S2.1) + 텔레메트리 지연 개선: 동적 polling 주기.
                // 활성 세션: 첫 5초 200ms(5Hz burst), 이후 250ms(4Hz) 유지 — 조종 중
                //   iOS 화면이 1초 묵은 값이 되지 않도록(종전 5초 후 1Hz 로 떨어지던 문제).
                // 세션 없음: 1초(1Hz steady) — CPU/배터리 절감 의도 보존.
                let startedAt = await self?.sessionStartedAt
                let sleepNs: UInt64
                if let start = startedAt {
                    sleepNs = Date().timeIntervalSince(start) < 5.0
                        ? 200_000_000   // burst: 200ms (페어링 직후 5초)
                        : 250_000_000   // active steady: 250ms (4Hz, 조종 지속)
                } else {
                    sleepNs = 1_000_000_000 // 세션 없음: 1s steady (배터리 절감)
                }
                try? await Task.sleep(nanoseconds: sleepNs)
            }
        }
    }

    private func appVersionString() -> String {
        let b = Bundle.main
        let v = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let n = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v)+\(n)"
    }

    /// 사용자가 QR 코드에 사용할 IP 를 수동으로 선택한다.
    ///
    /// - Parameter host: `availableHosts` 에 있는 IP 문자열. 없으면 무시.
    ///
    /// 선택값은 `UserDefaults` 에 persist 되어 다음 start() 시 자동 복원된다.
    public func setAdvertisedHost(_ host: String) {
        guard availableHosts.contains(where: { $0.ip == host }) else { return }
        advertisedHost = host
        UserDefaults.standard.set(host, forKey: MobileRelayController.preferredHostKey)
    }

    /// 모든 IPv4 인터페이스를 열거하고 Wi-Fi 사설 IP 우선으로 정렬해 반환한다.
    ///
    /// 정렬 순서: Wi-Fi 사설 > Wi-Fi 공인 > 유선 사설 > 유선 공인.
    /// Wi-Fi 판정: 인터페이스 이름이 "en" 으로 시작 (en0~en9) 이고
    /// IFF_BROADCAST 플래그가 설정된 경우 — macOS 에서 Wi-Fi 와 이더넷 모두
    /// "en" 접두사를 가지므로, IP 사설 여부로 iPhone 과 같은 subnet 임을 실용적으로 판단한다.
    /// 사설 IP (RFC-1918): 10/8, 172.16/12, 192.168/16.
    public nonisolated static func enumerateLocalIPv4Interfaces() -> [HostCandidate] {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return [] }
        defer { freeifaddrs(addr) }

        var candidates: [HostCandidate] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let pointee = ptr?.pointee else { continue }
            guard pointee.ifa_addr != nil,
                  pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(pointee.ifa_flags)
            if (flags & IFF_LOOPBACK) != 0 { continue }
            if (flags & IFF_UP) == 0 { continue }

            guard let nameStr = pointee.ifa_name,
                  let ifName = String(validatingUTF8: nameStr) else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointee.ifa_addr,
                              socklen_t(pointee.ifa_addr.pointee.sa_len),
                              &hostBuf, socklen_t(hostBuf.count),
                              nil, 0, NI_NUMERICHOST) == 0,
                  let ip = String(validatingUTF8: hostBuf), !ip.isEmpty else { continue }

            let isPrivate = isPrivateIPv4(ip)
            // Wi-Fi 휴리스틱: macOS 에서 Wi-Fi 는 보통 en0 또는 en1.
            // IFF_BROADCAST 는 Wi-Fi + 이더넷 모두 세팅되므로 ifName 접두사만으로 구분.
            // 실용적 기준: "en" 으로 시작하고 한 자리 숫자로 끝나면 Wi-Fi/이더넷 계열.
            // 더 정확한 판정은 CWInterface 이지만 CoreWLAN 의존을 추가하지 않는다.
            // 사설 IP 를 가진 en 인터페이스는 거의 항상 Wi-Fi (192.168.x.x) 임을 활용.
            let isWiFi = ifName.hasPrefix("en") && isPrivate

            candidates.append(HostCandidate(ifName: ifName, ip: ip,
                                            isWiFi: isWiFi, isPrivate: isPrivate))
        }

        // Wi-Fi 사설 > Wi-Fi 공인 > 유선 사설 > 유선 공인
        return candidates.sorted { lhs, rhs in
            let lScore = score(lhs)
            let rScore = score(rhs)
            if lScore != rScore { return lScore > rScore }
            return lhs.ifName < rhs.ifName
        }
    }

    /// 정렬용 점수 — 높을수록 우선.
    private nonisolated static func score(_ c: HostCandidate) -> Int {
        switch (c.isWiFi, c.isPrivate) {
        case (true, true):   return 3
        case (true, false):  return 2
        case (false, true):  return 1
        case (false, false): return 0
        }
    }

    /// RFC-1918 사설 IPv4 주소 판별.
    /// - 10.0.0.0/8
    /// - 172.16.0.0/12
    /// - 192.168.0.0/16
    nonisolated static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1]
        if a == 10 { return true }
        if a == 172, (16...31).contains(b) { return true }
        if a == 192, b == 168 { return true }
        return false
    }

    /// Best-effort LAN IPv4 — 하위 호환 유지. 신규 코드는 `enumerateLocalIPv4Interfaces()` 사용.
    public nonisolated static func firstLocalIPv4() -> String? {
        return enumerateLocalIPv4Interfaces().first?.ip
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
