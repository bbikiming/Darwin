import Foundation

// MARK: - NoopHarness (Wave 3 Phase 3.1, 사이클 241)
//
// 테스트 default + SwiftUI Previews 용. 모든 메서드 no-op — 디스크 기록 0, side-effect 0.
//
// 사용 예:
//
//   #Preview {
//       SomeView()
//           .environment(\.harness, NoopHarness())
//   }
//
//   func testSomething() {
//       let vm = ViewModel(harness: NoopHarness())  // 디스크 안 건드림
//       ...
//   }

/// 모든 호출 무시. 테스트/preview default.
@MainActor
public final class NoopHarness: HarnessFacade {

    public init() {}

    // MARK: HarnessRecording

    public func record(_ kind: TelemetryKind,
                       level: TelemetryLevel,
                       actor: TelemetryActor,
                       data: [String: AnyCodable],
                       context: TelemetryContext?) {}

    public func bookmark(_ note: String) {}

    public func flush() async {}

    // MARK: HarnessHeartbeat

    public func startHeartbeat(intervalSeconds: TimeInterval) {}
    public func stopHeartbeat() {}

    // MARK: HarnessContext

    public func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {}

    // MARK: HarnessLifecycle

    public func start() {}
    public func stop(reason: String) {}
}
