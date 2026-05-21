import Foundation

/// **v1.17.0 (2026-05-21) — Phase 4 Mock**: 실 Tello 없이 testing.
///
/// XCTest 환경에서 `TelloLink` 대신 inject. 보낸 명령을 in-memory queue 에 기록 →
/// 테스트가 검증 가능. UDP socket alloc 없음 — CI 안전.
public final class MockTelloLink: TelloLinkProtocol, @unchecked Sendable {

    /// 송신된 명령 기록 (newest last).
    public private(set) var sentCommands: [String] = []
    /// 마지막 RC stick. nil = 호출 안 됨.
    public private(set) var lastRC: (lr: Int, fb: Int, ud: Int, yaw: Int)?
    /// `start()` 호출 횟수.
    public private(set) var startCount: Int = 0
    /// `emergency()` 호출 횟수.
    public private(set) var emergencyCount: Int = 0
    /// `stop()` 호출 횟수.
    public private(set) var stopCount: Int = 0

    public init() {}

    public func start() async throws {
        startCount += 1
        sentCommands.append("command")
    }

    public func sendRC(lr: Int, fb: Int, ud: Int, yaw: Int) async {
        let cl = max(-100, min(100, lr))
        let cf = max(-100, min(100, fb))
        let cu = max(-100, min(100, ud))
        let cy = max(-100, min(100, yaw))
        lastRC = (cl, cf, cu, cy)
        sentCommands.append("rc \(cl) \(cf) \(cu) \(cy)")
    }

    public func emergency() async {
        emergencyCount += 1
        sentCommands.append("emergency")
    }

    public func stop() {
        stopCount += 1
    }

    /// 테스트 helper — sentCommands clear.
    public func reset() {
        sentCommands.removeAll()
        lastRC = nil
        startCount = 0
        emergencyCount = 0
        stopCount = 0
    }
}
