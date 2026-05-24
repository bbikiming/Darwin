import Foundation

/// **v1.17.0 (2026-05-21) — Phase 4 Mock**: 실 Tello 없이 testing.
///
/// XCTest 환경에서 `TelloLink` 대신 inject. 보낸 명령을 in-memory queue 에 기록 →
/// 테스트가 검증 가능. UDP socket alloc 없음 — CI 안전.
///
/// # Thread safety (2026-05-24, V270-flaky fix)
///
/// `WalkLabRCBridge.process()` 의 emergency 분기는 `Task { [tello] in await tello.emergency() }`
/// 형태로 fire-and-forget detached task 를 spawn. 한 테스트에서 emergency 를 N회 호출하면
/// N개의 task 가 동시에 `mock.emergency()` 의 mutating property (`emergencyCount`,
/// `sentCommands`) 를 race. 종전 `@unchecked Sendable` 은 컴파일러에게 "신뢰" 만 약속
/// — 실 race 는 미보호. 1962-test coverage 풀런에서 누적 race + counter instrumentation
/// write 가 memory corruption → SIGSEGV 트리거. NSLock 으로 모든 mutation 직렬화.
public final class MockTelloLink: TelloLinkProtocol, @unchecked Sendable {

    private let lock = NSLock()

    /// 송신된 명령 기록 (newest last).
    private var _sentCommands: [String] = []
    public var sentCommands: [String] {
        lock.lock(); defer { lock.unlock() }
        return _sentCommands
    }

    /// 마지막 RC stick. nil = 호출 안 됨.
    private var _lastRC: (lr: Int, fb: Int, ud: Int, yaw: Int)?
    public var lastRC: (lr: Int, fb: Int, ud: Int, yaw: Int)? {
        lock.lock(); defer { lock.unlock() }
        return _lastRC
    }

    /// `start()` 호출 횟수.
    private var _startCount: Int = 0
    public var startCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startCount
    }

    /// `emergency()` 호출 횟수.
    private var _emergencyCount: Int = 0
    public var emergencyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _emergencyCount
    }

    /// `stop()` 호출 횟수.
    private var _stopCount: Int = 0
    public var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopCount
    }

    public init() {}

    public func start() async throws {
        lock.lock(); defer { lock.unlock() }
        _startCount += 1
        _sentCommands.append("command")
    }

    public func sendRC(lr: Int, fb: Int, ud: Int, yaw: Int) async {
        let cl = max(-100, min(100, lr))
        let cf = max(-100, min(100, fb))
        let cu = max(-100, min(100, ud))
        let cy = max(-100, min(100, yaw))
        lock.lock(); defer { lock.unlock() }
        _lastRC = (cl, cf, cu, cy)
        _sentCommands.append("rc \(cl) \(cf) \(cu) \(cy)")
    }

    public func emergency() async {
        lock.lock(); defer { lock.unlock() }
        _emergencyCount += 1
        _sentCommands.append("emergency")
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        _stopCount += 1
    }

    /// 테스트 helper — sentCommands clear.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _sentCommands.removeAll()
        _lastRC = nil
        _startCount = 0
        _emergencyCount = 0
        _stopCount = 0
    }
}
