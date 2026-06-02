import Foundation
import Combine
#if canImport(Network)
import Network
#endif

/// 기기의 네트워크 경로(Wi-Fi/셀룰러) 가용성을 관찰하는 모니터.
///
/// # 비유
///
/// 집 현관에 달린 "전기 들어옴" 표시등 — 두꺼비집이 내려가면 즉시 불이 꺼지고,
/// 복구되면 다시 켜진다. 우리는 이 신호를 보고 "전기 돌아왔으니 바로 다시 시도하자"를
/// 판단한다. WiFi가 죽은 동안에는 헛되이 재연결을 시도해 배터리/시도횟수를 낭비하지 않고,
/// 복구되는 **그 순간** 즉시 재연결을 트리거한다.
///
/// # 동작
///
/// - `NWPathMonitor`의 콜백은 백그라운드 큐에서 오므로 `MainActor`로 hop 후 상태 갱신.
/// - `unsatisfied → satisfied` 전이에서만 `onRestored()`를 1회 발화(중복 방지).
/// - 전이 판정 로직은 `applyPath(isSatisfied:)`로 분리해 단위 테스트 가능.
@MainActor
public final class NetworkPathMonitor: ObservableObject {

    /// 현재 네트워크 사용 가능 여부. 시작 전에는 낙관적으로 true(연결 시도 허용).
    @Published public private(set) var isOnline: Bool = true

    /// `false → true` 전이 시 호출. 호출자가 즉시 재연결 트리거에 사용.
    public var onRestored: (() -> Void)?

    #if canImport(Network)
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.yuseok.oppilot.pathmonitor")
    #endif

    private var started = false

    public init() {}

    /// 모니터링 시작. 중복 호출 안전(idempotent).
    public func start() {
        guard !started else { return }
        started = true
        #if canImport(Network)
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = (path.status == .satisfied)
            Task { @MainActor in
                self?.applyPath(isSatisfied: satisfied)
            }
        }
        monitor.start(queue: queue)
        #endif
    }

    /// 모니터링 중지 + 리소스 정리.
    public func stop() {
        started = false
        #if canImport(Network)
        monitor?.cancel()
        monitor = nil
        #endif
    }

    /// 경로 상태 적용 — 전이 감지 + `onRestored` 발화. 테스트가 직접 호출 가능.
    ///
    /// - Parameter isSatisfied: 새 경로가 사용 가능한지.
    func applyPath(isSatisfied: Bool) {
        let wasOnline = isOnline
        guard wasOnline != isSatisfied else { return }   // 변화 없으면 무시
        isOnline = isSatisfied
        if !wasOnline && isSatisfied {
            onRestored?()
        }
    }

    deinit {
        #if canImport(Network)
        monitor?.cancel()
        #endif
    }
}
