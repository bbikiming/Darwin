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

/// 프로덕션용 Harness 구현체 — 모든 호출을 `Harness.shared` 로 forward.
@MainActor
public final class LiveHarness: HarnessFacade {

    /// 전역 공유 인스턴스 — Harness.shared 와 1:1 매핑.
    public static let shared = LiveHarness()

    private init() {}

    // MARK: HarnessRecording

    public func record(_ kind: TelemetryKind,
                       level: TelemetryLevel,
                       actor: TelemetryActor,
                       data: [String: AnyCodable],
                       context: TelemetryContext?) {
        Harness.shared.record(kind, level: level, actor: actor, data: data, context: context)
    }

    public func bookmark(_ note: String) {
        Harness.shared.bookmark(note)
    }

    public func flush() async {
        await Harness.shared.flush()
    }

    // MARK: HarnessHeartbeat

    public func startHeartbeat(intervalSeconds: TimeInterval) {
        Harness.shared.startHeartbeat(intervalSeconds: intervalSeconds)
    }

    public func stopHeartbeat() {
        Harness.shared.stopHeartbeat()
    }

    // MARK: HarnessContext

    public func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {
        Harness.shared.registerContextProvider(provider)
    }

    // MARK: HarnessLifecycle

    public func start() {
        Harness.shared.start()
    }

    public func stop(reason: String) {
        Harness.shared.stop(reason: reason)
    }
}
