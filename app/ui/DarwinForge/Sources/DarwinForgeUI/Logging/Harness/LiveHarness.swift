import Foundation

// MARK: - LiveHarness (Wave 3 Phase 3.1, 사이클 241)
//
// 프로덕션 구현 — 기존 `Harness.shared` 의 thin wrapper. 동작 100% 동일.
// DI 주입 시 본 클래스를 사용하면 실제 디스크 기록 / heartbeat / lifecycle 가 모두 작동.
//
// **왜 wrapper 인가** — `Harness` 자체에 protocol conformance 를 직접 추가하면 1) 기존
// 호출 사이트 (49 파일 257 사이트) 의 시그니처 ambiguity 가 발생할 수 있고, 2) Harness 의
// internal API (_startInDirectory, _bypassConnectionGuard) 가 외부로 새지 않음.
// thin wrapper 로 분리해 격리.

/// 프로덕션용 Harness 구현체 — 모든 호출을 `Harness` 싱글톤으로 forward.
///
/// **Wave 3 Phase 3.4 (사이클 115, 2026-05-23)** — `Harness.shared` 가 deprecated
/// 되었지만 본 wrapper 는 의도적 forward 이므로 `Harness._internalShared` 우회를
/// 통해 deprecation warning 없이 호출. 일반 caller 는 `Harness.shared` / `Harness._internalShared`
/// 어느 것도 직접 호출 금지 — 반드시 `LiveHarness.shared` 또는 DI 추상화 사용.
@MainActor
public final class LiveHarness: HarnessFacade, HarnessIntrospection {

    /// 전역 공유 인스턴스 — `Harness` 싱글톤과 1:1 매핑.
    public static let shared = LiveHarness()

    private init() {}

    // MARK: HarnessRecording

    public func record(_ kind: TelemetryKind,
                       level: TelemetryLevel,
                       actor: TelemetryActor,
                       data: [String: AnyCodable],
                       context: TelemetryContext?) {
        Harness._internalShared.record(kind, level: level, actor: actor, data: data, context: context)
    }

    public func bookmark(_ note: String) {
        Harness._internalShared.bookmark(note)
    }

    public func flush() async {
        await Harness._internalShared.flush()
    }

    // MARK: HarnessHeartbeat

    public func startHeartbeat(intervalSeconds: TimeInterval) {
        Harness._internalShared.startHeartbeat(intervalSeconds: intervalSeconds)
    }

    public func stopHeartbeat() {
        Harness._internalShared.stopHeartbeat()
    }

    // MARK: HarnessContext

    public func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {
        Harness._internalShared.registerContextProvider(provider)
    }

    // MARK: HarnessLifecycle

    public func start() {
        Harness._internalShared.start()
    }

    public func stop(reason: String) {
        Harness._internalShared.stop(reason: reason)
    }

    // MARK: HarnessIntrospection

    public var isEnabled: Bool {
        get { Harness._internalShared.isEnabled }
        set { Harness._internalShared.isEnabled = newValue }
    }

    public var sessionId: String {
        Harness._internalShared.sessionId
    }

    public var sessionStarted: Date {
        Harness._internalShared.sessionStarted
    }

    public var sessionDir: URL? {
        Harness._internalShared.sessionDir
    }

    public var isRecorderActive: Bool {
        Harness._internalShared.isRecorderActive
    }
}
