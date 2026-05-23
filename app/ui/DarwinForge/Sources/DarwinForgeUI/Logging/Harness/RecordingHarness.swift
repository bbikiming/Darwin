import Foundation

// MARK: - RecordingHarness (Wave 3 Phase 3.1, 사이클 241)
//
// 테스트 assertion 전용 — 모든 호출을 in-memory 에 캡처. record(), bookmark(),
// flush(), heartbeat lifecycle, context provider 등록, start/stop 모두 카운트/누적.
//
// 사용 예:
//
//   let harness = RecordingHarness()
//   let vm = ViewModel(harness: harness)
//
//   vm.handleUserAction()
//
//   XCTAssertEqual(harness.events.count, 1)
//   XCTAssertEqual(harness.events[0].kind, .uiButtonTapped)
//   XCTAssertEqual(harness.events[0].level, .info)

/// 테스트용 capture-harness — 모든 호출을 누적, 검증 가능.
@MainActor
public final class RecordingHarness: HarnessFacade {

    /// record() 1회 호출의 캡처 스냅샷. data/context 의 full Equatable 비교는 비싸므로
    /// 핵심 필드 (kind/level/actor) 만 보관. 필요 시 events 의 raw `data`/`context` 확장 가능.
    public struct Recorded: Equatable, Sendable {
        public let kind: TelemetryKind
        public let level: TelemetryLevel
        public let actor: TelemetryActor
        public let timestamp: Date

        public init(kind: TelemetryKind,
                    level: TelemetryLevel,
                    actor: TelemetryActor,
                    timestamp: Date) {
            self.kind = kind
            self.level = level
            self.actor = actor
            self.timestamp = timestamp
        }
    }

    // MARK: - Capture state (read-only 외부 노출)

    public private(set) var events: [Recorded] = []
    public private(set) var bookmarks: [String] = []
    public private(set) var flushCount: Int = 0
    public private(set) var heartbeatActive: Bool = false
    public private(set) var heartbeatInterval: TimeInterval = 0
    public private(set) var contextProviderRegistered: Bool = false
    public private(set) var startCount: Int = 0
    public private(set) var stopReasons: [String] = []

    public init() {}

    // MARK: HarnessRecording

    public func record(_ kind: TelemetryKind,
                       level: TelemetryLevel,
                       actor: TelemetryActor,
                       data: [String: AnyCodable],
                       context: TelemetryContext?) {
        events.append(Recorded(kind: kind, level: level, actor: actor, timestamp: Date()))
    }

    public func bookmark(_ note: String) {
        bookmarks.append(note)
    }

    public func flush() async {
        flushCount += 1
    }

    // MARK: HarnessHeartbeat

    public func startHeartbeat(intervalSeconds: TimeInterval) {
        heartbeatActive = true
        heartbeatInterval = intervalSeconds
    }

    public func stopHeartbeat() {
        heartbeatActive = false
    }

    // MARK: HarnessContext

    public func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {
        contextProviderRegistered = true
    }

    // MARK: HarnessLifecycle

    public func start() {
        startCount += 1
    }

    public func stop(reason: String) {
        stopReasons.append(reason)
    }

    // MARK: - Test helpers

    /// 모든 캡처 상태 초기화. 테스트 between-cases 에서 호출.
    public func reset() {
        events.removeAll()
        bookmarks.removeAll()
        flushCount = 0
        heartbeatActive = false
        heartbeatInterval = 0
        contextProviderRegistered = false
        startCount = 0
        stopReasons.removeAll()
    }
}
