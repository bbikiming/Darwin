import AppKit
import Foundation
import OSLog

// MARK: - Harness (telemetry façade)
//
// `Harness.shared` 는 앱 전역 싱글톤. 어디서든 호출 가능.
//
//   Harness.shared.record(.uiSectionChanged, data: ["from": "studio", "to": "walkLab"])
//   Harness.shared.record(.connectSuccess, level: .notice,
//                         data: ["endpoint": "net:10.0.0.x:5530"],
//                         context: store.harnessContext())
//
// MainActor 인 façade — UI 코드가 await 없이 호출. record() 는 단일 AsyncStream 으로
// 이벤트를 직렬화 → consumer Task 가 순서 보장 + bounded buffer 로 백프레셔.
//
// **v1.12.2 (Codex P1-1/P1-2 fix)** — 종전 매 record() 마다 `Task.detached { ... }` 가
// 1) 순서 보장 안 됨 (스케줄러 임의 순서) 2) actor mailbox 가 backlog 로 폭주 가능
// 3) finalize race (terminate 이벤트가 finalize 후 도착) 의 세 문제 동시 해결.

@MainActor
public final class Harness: HarnessIntrospection {
    /// **internal storage** — 실제 단일 인스턴스. 모든 접근 경로 (deprecated `shared`,
    /// internal `_internalShared`) 가 본 storage 로 forward. Swift 의 static let
    /// 이 thread-safe 한 lazy init 을 제공하므로 별도 lock 불필요.
    private static let _instance = Harness()

    /// **Wave 3 Phase 3.4 (사이클 115, 2026-05-23)** — DI migration 완료 후 deprecated.
    ///
    /// 49 파일 257 사이트 중 252 사이트가 DI 추상화 (`@Environment(\.harness)`,
    /// `any HarnessFacade` init injection) 으로 migration 완료. 잔존 5 인프라 예외:
    /// 1. `DarwinForgeApp.swift` — start/stop lifecycle (LiveHarness 사용)
    /// 2. `LiveHarness.swift` — 의도적 forward (production wrapper, `_internalShared` 사용)
    /// 3. `HarnessInspectorView.swift` — introspection (`_internalShared` 사용)
    /// 4. `Harness.swift` — 본 파일 (정의)
    /// 5. `HarnessProtocols.swift` — comment only
    ///
    /// 새 코드는 반드시 `@Environment(\.harness)` (View) 또는 `any HarnessFacade`
    /// init 주입 (class) 사용. 직접 `Harness.shared` 접근 시 deprecation warning.
    @available(*, deprecated, message: "Use @Environment(\\.harness) for Views or init injection (any HarnessFacade) for classes. Direct shared access remains for LiveHarness forwarding (LiveHarness.swift), Inspector introspection (HarnessIntrospection protocol — Phase 5), and DarwinForgeApp lifecycle.")
    public static var shared: Harness { _instance }

    /// **internal accessor** — `LiveHarness` / `HarnessInspectorView` 의 5 인프라
    /// 예외 사이트가 deprecation warning 없이 접근하기 위한 module-internal 우회.
    ///
    /// 일반 caller 는 사용 금지 — 반드시 DI 추상화 (`HarnessFacade`) 사용.
    /// 본 accessor 가 internal 인 이유: 외부 모듈 (DarwinForgeApp 등) 은
    /// `LiveHarness.shared` 를 통해 lifecycle 호출 → 본 경로 자체가 노출 안 됨.
    ///
    /// deprecated `shared` 와 다른 점: 본 accessor 는 `@available` 미부여 →
    /// 호출 사이트가 deprecation warning 없이 동일 인스턴스 접근. 두 경로 모두
    /// `_instance` 를 forward — 인스턴스 동일성 보장.
    internal static var _internalShared: Harness { _instance }

    // MARK: HarnessIntrospection conformance

    /// 현재 세션의 recorder 활성 여부 — `recorder != nil` 의 public mirror.
    /// (recorder 자체는 `TelemetryRecorder` internal type 이라 protocol 표면에 노출 불가.)
    public var isRecorderActive: Bool { recorder != nil }

    // MARK: Settings (UserDefaults-backed)

    private enum DefaultsKey {
        static let enabled = "harness.enabled"
        static let consentShown = "harness.consent_shown"
    }

    /// 텔레메트리 활성 — 사용자가 Settings 에서 끌 수 있음. 기본 true.
    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.enabled) }
    }

    /// 1회용 토스트 표시 여부.
    public var consentShown: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.consentShown) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.consentShown) }
    }

    // MARK: Runtime

    public private(set) var sessionId: String = ""
    public private(set) var sessionStarted: Date = Date()
    public private(set) var recorder: TelemetryRecorder?
    public private(set) var sessionDir: URL?

    private let isoFormatter: ISO8601DateFormatter
    private let mirror = Logger(subsystem: "com.darwinforge", category: "harness")
    private var contextProvider: (() -> TelemetryContext?)?
    private var heartbeatTimer: Timer?
    private var bootMonotonicNs: UInt64

    // 단일 직렬 큐 — record() 의 순서 보장.
    // bufferingNewest(N) — consumer 느리면 newest 만 유지, 오래된 것 drop (drop counter ↑).
    private var stream: AsyncStream<TelemetryEvent>?
    private var continuation: AsyncStream<TelemetryEvent>.Continuation?
    private var consumerTask: Task<Void, Never>?

    // backpressure 카운터 — main-actor isolated, atomicity 보장.
    private var droppedSinceLastReport: UInt64 = 0
    private static let dropReportInterval: UInt64 = 100

    public static let streamBufferLimit: Int = 4096

    private init() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
        self.bootMonotonicNs = Self.currentMonotonicNs()
    }

    // MARK: Lifecycle

    /// 앱 시작 시 1회 호출 (DarwinForgeApp.init).
    public func start() {
        guard isEnabled else { return }
        guard recorder == nil else { return }

        // **v1.14.5 (2026-05-21) — race fix**: 종전 archiveOrphanedSessions 를
        // Task.detached 로 호출했으나, 새 current-<UUID> dir 생성 직후 task 가
        // fire 되면 새 dir 도 archive 로 옮겨버려 events.jsonl 가 disk 에 안 보임.
        // **본 호출은 새 dir 만들기 *전*에 동기**로 — current-* 패턴은 이전 launch 의
        // 잔여만 잡힘. enforceRetention 만 비동기 유지 (오래된 세션 정리 — 비차단).
        TelemetryStore.archiveOrphanedSessions()
        Task.detached(priority: .utility) {
            TelemetryStore.enforceRetention()
        }
        let id = UUID().uuidString
        let dir = TelemetryStore.currentSessionDirectory(id: id)
        _startInDirectory(dir, id: id)
    }

    /// **테스트 / 통합 검증용** — 임의 디렉토리에서 세션 시동.
    /// `Application Support` 를 오염시키지 않고 hook 발화 → 디스크 기록 전체 경로 검증.
    /// `start()` 가 내부적으로 호출. 외부 코드는 `start()` 만 사용 권장.
    internal func _startInDirectory(_ dir: URL, id: String) {
        guard recorder == nil else { return }
        sessionId = id
        sessionStarted = Date()
        sessionDir = dir

        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let osDesc = ProcessInfo.processInfo.operatingSystemVersionString
        let device = Self.deviceModelIdentifier()
        let meta = TelemetrySessionMeta(
            schema: TelemetryRecorder.schemaVersion,
            id: id,
            started: isoFormatter.string(from: sessionStarted),
            appVersion: version,
            appBuild: build,
            os: osDesc,
            device: device
        )
        do {
            let rec = try TelemetryRecorder(directory: dir, meta: meta)
            self.recorder = rec
            mirror.notice("session started \(id.prefix(8), privacy: .public) → \(dir.path, privacy: .public)")

            // AsyncStream 생성 — bounded buffer, oldest-drop on overflow.
            let (s, c) = AsyncStream<TelemetryEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.streamBufferLimit)
            )
            self.stream = s
            self.continuation = c
            // 단일 consumer — 순서 보장 + actor mailbox 폭주 없음.
            self.consumerTask = Task.detached(priority: .utility) { [weak rec] in
                guard let rec = rec else { return }
                for await event in s {
                    await rec.enqueue(event)
                }
                // stream 종료 → 마지막 flush.
                await rec.flush()
            }

            record(.appLaunch, level: .notice, actor: .system,
                   data: ["version": AnyCodable(version), "build": AnyCodable(build),
                          "os": AnyCodable(osDesc), "device": AnyCodable(device)])

            // NotificationCenter — foreground/background 이벤트.
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleDidBecomeActive),
                                                   name: NSApplication.didBecomeActiveNotification,
                                                   object: nil)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleWillResignActive),
                                                   name: NSApplication.willResignActiveNotification,
                                                   object: nil)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleWillTerminate),
                                                   name: NSApplication.willTerminateNotification,
                                                   object: nil)
        } catch {
            mirror.error("failed to start harness: \(error.localizedDescription, privacy: .public)")
            recorder = nil
        }
    }

    /// 앱 종료 시 호출 (DarwinForgeApp.applicationWillTerminate 또는 deinit).
    public func stop(reason: String = "terminate") {
        guard let rec = recorder, let dir = sessionDir else { return }
        let endedAt = isoFormatter.string(from: Date())
        // 1) terminate 이벤트를 일반 record() 경로로 발행 — 큐 안에서 finalize 보다 먼저.
        record(.appTerminate, level: .notice, actor: .system,
               data: ["reason": AnyCodable(reason)])
        // 2) drop counter 가 남았다면 마지막 dropped 이벤트도 발행.
        emitDropReportIfNeeded(force: true)
        // 3) stream 종료 → consumer drain.
        let consumer = consumerTask
        continuation?.finish()
        continuation = nil
        stream = nil
        consumerTask = nil
        stopHeartbeat()
        // 4) consumer 가 모든 잔여 이벤트 처리 → finalize → archive.
        Task.detached {
            await consumer?.value     // consumer 마지막 flush 까지 대기.
            await rec.finalize(endIso: endedAt)
            TelemetryStore.archive(currentDir: dir)
            TelemetryStore.enforceRetention()
        }
        recorder = nil
        sessionDir = nil
    }

    // MARK: Recording

    /// **v1.14.4 (2026-05-21)** — 사용자 요청: "로그 남기는 건 로봇이 정상적으로 연결된
    /// 상태에서만 진행". 미연결 상태에선 lifecycle/connection 자체 이벤트만 기록 (연결
    /// 시도/성공/실패 자체는 진단에 필수). 그 외 (heartbeat, walklab, motion, teach, pose,
    /// claude, ui, imu, bus) 는 connected 상태에서만.
    ///
    /// 효과: 미연결 idle 상태에서 main actor 부담 0 — heartbeat / record() 모두 즉시 return.
    /// 디스크 I/O 도 0 (AsyncStream.yield 도 skip).
    /// **v1.14.4** 테스트 전용 — connection guard 우회. production 코드에선 false 유지.
    /// HarnessRealRobotSmokeTests 같이 ConnectionStore 를 등록하지만 실제 연결 없이
    /// record 발화를 검증하는 fixture 가 사용.
    internal var _bypassConnectionGuard: Bool = false

    private func shouldRecord(kind: TelemetryKind, context: TelemetryContext?) -> Bool {
        if _bypassConnectionGuard { return true }
        // 항상 통과 namespace — 라이프사이클 + 연결 + 텔레메트리 자체 + 사용자 북마크.
        let alwaysOnNamespaces: Set<String> = ["app", "connection", "harness", "user", "error"]
        if alwaysOnNamespaces.contains(kind.namespace) { return true }
        // contextProvider 미등록 (non-ConnectionStore 환경) 이면 가드 비활성.
        guard contextProvider != nil else { return true }
        // production — connected 상태에서만.
        let ctx = context ?? contextProvider?()
        return ctx?.cn == .connected
    }

    /// Synchronous facade — 단일 큐에 enqueue. UI 스레드 비차단.
    /// 호출 비용: ISO8601 string + monotonic clock + continuation.yield (~10 µs).
    ///
    /// `data` 는 `[String: AnyCodable]` — `AnyCodable` 는 String/Int/Double/Bool/Array/Dict
    /// 리터럴 자동 변환을 지원하므로 callsite 는 단순 dictionary literal 로 작성 가능.
    public func record(_ kind: TelemetryKind,
                       level: TelemetryLevel = .info,
                       actor: TelemetryActor = .user,
                       data: [String: AnyCodable] = [:],
                       context: TelemetryContext? = nil) {
        guard isEnabled, recorder != nil, let cont = continuation else { return }
        // **v1.14.4** — 미연결 상태일 때 lifecycle/connection 외 모두 skip.
        guard shouldRecord(kind: kind, context: context) else { return }
        let wall = isoFormatter.string(from: Date())
        let mono = Self.currentMonotonicNs() &- bootMonotonicNs
        // Context resolution — explicit > provider > nil.
        let resolved: TelemetryContext? = context ?? contextProvider?()
        let event = TelemetryEvent(
            schema: TelemetryRecorder.schemaVersion,
            session: sessionId,
            seq: 0,                       // recorder가 부여
            wall: wall,
            mono: mono,
            kind: kind,
            level: level,
            actor: actor,
            data: TelemetryPayload(data),
            context: resolved
        )
        let result = cont.yield(event)
        switch result {
        case .enqueued, .terminated:
            // terminated 도 silent — stop() 이후 호출 시 무시.
            return
        case .dropped:
            droppedSinceLastReport &+= 1
            emitDropReportIfNeeded(force: false)
        @unknown default:
            return
        }
    }

    /// 100 drop 마다 또는 stop() 시 강제로 harness.dropped 이벤트 발행.
    /// (드롭 자체는 buffered policy 가 처리 — 본 이벤트는 진단용 metadata.)
    private func emitDropReportIfNeeded(force: Bool) {
        guard droppedSinceLastReport > 0 else { return }
        guard force || droppedSinceLastReport >= Self.dropReportInterval else { return }
        let count = droppedSinceLastReport
        droppedSinceLastReport = 0
        // 별도 record() — 재귀가 아닌 직접 yield (drop 발행 시점 drop 안 되도록 우선순위).
        guard let cont = continuation else { return }
        let wall = isoFormatter.string(from: Date())
        let mono = Self.currentMonotonicNs() &- bootMonotonicNs
        let ev = TelemetryEvent(
            schema: TelemetryRecorder.schemaVersion,
            session: sessionId, seq: 0,
            wall: wall, mono: mono,
            kind: .harnessDropped, level: .warn, actor: .system,
            data: TelemetryPayload(["count": AnyCodable(count)]),
            context: nil
        )
        _ = cont.yield(ev)
    }

    /// Inspector 가 호출 — 사용자가 "여기 문제 발생" 마커 삽입.
    public func bookmark(_ note: String) {
        // 사용자 텍스트는 raw 로 기록하지 않음 — 길이 + 해시 prefix.
        record(.uiBookmark, level: .notice, actor: .user,
               data: ["len": AnyCodable(note.count),
                      "hash": AnyCodable(Self.shortHash(note))])
    }

    /// 모든 in-flight event flush. 명시적 export 직전 호출.
    public func flush() async {
        await recorder?.flush()
    }

    // MARK: Context provider (ConnectionStore 가 등록)

    /// ConnectionStore 가 onAppear 시점에 자신의 스냅샷 producer 를 등록.
    public func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {
        contextProvider = provider
    }

    // MARK: Heartbeat

    /// 시작 — 1 Hz heartbeat. ConnectionStore 가 등록되어 있어야 의미 있음.
    /// **v1.14.8 (2026-05-21) perf #5**:
    ///  - Task { @MainActor } 제거 → MainActor.assumeIsolated.
    ///    Timer 콜백은 RunLoop.main `.common` 으로 add 되어 이미 MainActor 컨텍스트
    ///    이지만, Swift 6 isolation 검사상 Task 로 hop 필요했음. assumeIsolated 로
    ///    actor hop 비용 (~50µs/tick) 제거.
    ///  - ConnectionStore 의 connected 전환에서 start, disconnect 에서 stop 으로
    ///    이동 (DarwinForgeApp 의 always-on 제거). 미연결 시 disk I/O / AsyncStream
    ///    push 자체를 차단.
    public func startHeartbeat(intervalSeconds: TimeInterval = 1.0) {
        stopHeartbeat()
        let timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emitHeartbeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    public func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func emitHeartbeat() {
        let ctx = contextProvider?()
        // **v1.14.4 (2026-05-21)** — 사용자 요청: 미연결 시 heartbeat 완전 skip.
        // 종전: idle 10s 주기 — 디스크 누적 + AsyncStream + main actor 부담 발생.
        // 현재: production 에서 connected 가 아니면 즉시 return. 단 테스트 환경
        // (_bypassConnectionGuard 또는 contextProvider 미등록) 에선 발화.
        if !_bypassConnectionGuard, contextProvider != nil, ctx?.cn != .connected {
            return
        }
        record(.heartbeat, level: .trace, actor: .system, context: ctx)
    }

    // MARK: NSApp notifications

    @objc private func handleDidBecomeActive() {
        record(.appForeground, level: .info, actor: .system)
    }

    @objc private func handleWillResignActive() {
        record(.appBackground, level: .info, actor: .system)
    }

    @objc private func handleWillTerminate() {
        // willTerminate 후 process exit — 동기 finalize.
        guard let rec = recorder, let dir = sessionDir else { return }
        let endedAt = isoFormatter.string(from: Date())
        record(.appTerminate, level: .notice, actor: .system,
               data: ["reason": AnyCodable("willTerminate")])
        emitDropReportIfNeeded(force: true)
        let consumer = consumerTask
        continuation?.finish()
        continuation = nil
        stream = nil
        consumerTask = nil
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await consumer?.value
            await rec.finalize(endIso: endedAt)
            TelemetryStore.archive(currentDir: dir)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + .milliseconds(900))
        recorder = nil
        sessionDir = nil
    }

    // MARK: Helpers

    private static func currentMonotonicNs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let raw = mach_absolute_time()
        let ns = (raw &* UInt64(info.numer)) / UInt64(info.denom)
        return ns
    }

    private static func deviceModelIdentifier() -> String {
        var size: size_t = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    /// 사용자 텍스트 → 짧은 해시 prefix. raw 본문은 절대 디스크 안 감.
    /// FNV-1a 32bit (외부 dep 없음). 충돌 가능하지만 진단 그루핑 용도엔 충분.
    /// `nonisolated` — main actor 격리와 무관 (pure function).
    public nonisolated static func shortHash(_ s: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 0x01000193
        }
        return String(format: "%08x", h)
    }
}
