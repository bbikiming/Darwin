import Foundation

/// 하드웨어 없이 결정론적 단위테스트를 위한 `CockpitControllerSource` 더블.
///
/// 테스트가 `snapshot` 을 직접 세팅하거나 `enqueue(_:)` 로 프레임 시퀀스를 큐잉하면
/// `capture()` 가 순서대로 반환한다(큐 소진 시 마지막 값 유지). 가상 컨트롤러
/// (`GCController.withExtendedGamepad()`) 없이도 driver→cockpit 주입을 검증 가능.
@MainActor
public final class MockControllerSource: CockpitControllerSource {

    public var deviceKey:   String?
    public var displayName: String?
    public private(set) var isConnected: Bool
    public var onConnectionChange: (@MainActor (Bool) -> Void)?

    /// 다음 `capture()` 가 반환할 스냅샷. `enqueue` 큐가 비었을 때 사용.
    public var snapshot: ControllerSnapshot
    private var queue: [ControllerSnapshot] = []

    public init(
        deviceKey:   String? = "mock",
        displayName: String? = "Mock Controller",
        isConnected: Bool = true,
        snapshot:    ControllerSnapshot = .neutral
    ) {
        self.deviceKey   = deviceKey
        self.displayName = displayName
        self.isConnected = isConnected
        self.snapshot    = snapshot
    }

    // MARK: - 테스트 조작 API

    /// 프레임 시퀀스 큐잉 — `capture()` 가 FIFO 로 소비.
    public func enqueue(_ snapshots: ControllerSnapshot...) {
        queue.append(contentsOf: snapshots)
    }

    /// 연결 상태 변경 + 콜백 발화 — 끊김 failsafe(M3) 테스트용.
    public func setConnected(_ connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        onConnectionChange?(connected)
    }

    // MARK: - CockpitControllerSource

    public func start() {}
    public func stop() {}

    public func capture() -> ControllerSnapshot? {
        guard isConnected else { return nil }
        if queue.isEmpty { return snapshot }
        return queue.removeFirst()
    }
}
