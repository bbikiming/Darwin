import Foundation
import Observation
import OSLog

/// **v1.20.35 (2026-05-22) 사이클 18 — Tello state listener lifecycle owner**.
///
/// `TelloStateListener` (UDP 8890 raw transport) 와 `WalkLabRCBridge`
/// (UI binding) 사이의 lifecycle 책임 owner. listener 의 init/start/stop 을
/// 통합 관리 + onState callback 을 MainActor hop → bridge.updateTelloState 로 연결.
///
/// # 왜 별도 owner 가 필요한가
///
/// 종전: listener 가 12 test 통과지만 실 bridge 와 미연결 — Tello drone state 가
/// UI 에 도착 안 함. bridge 가 listener 의 lifecycle 좌우 못 함 (bridge 는
/// WalkLabSession 라이프사이클에 종속, listener 는 사용자 명시 활성화 시점에
/// alloc 되어야 함).
///
/// 본 owner: root view 가 명시 alloc + bridge 약한 참조. 사용자가 Tello 연결
/// 활성화 시 `start()` 호출 → listener bind. 비활성 시 `stop()` 호출.
///
/// # 동시성 모델
///
/// - `@MainActor @Observable` — UI 가 isActive / lastReceived 를 reactive 관찰.
/// - listener 는 `@Sendable` closure 로 callback → `Task { @MainActor in ... }` hop.
/// - bridge 는 `weak` — view lifecycle 영향 안 줌. owner 자체는 root @State.
///
/// # NSLocalNetworkUsageDescription
///
/// production 환경에서 첫 UDP listen 시 macOS 가 권한 다이얼로그 표시. 미허락 시
/// NWListener 가 silent 실패 (callback path 발화 안 함, throw 없음). owner 는
/// `try?` 로 silent 처리하되 OSLog 로 진단 가능하게 남김.
///
/// # Idempotency
///
/// - `start()` 중복 호출: 이미 isActive 면 no-op.
/// - `stop()` 중복 호출: 안전 (no-op + listener.stop 이 자체 idempotent).
/// - stop 후 재 start: callback 재등록 + listener.start 재호출 OK (재사용 가능).
@MainActor
@Observable
public final class TelloStateListenerOwner {

    /// bridge 약한 참조 — view/root 가 강한 참조 보유. 양방향 retain 차단.
    public weak var bridge: WalkLabRCBridge?

    /// listener — protocol 형 (mock 주입 가능). owner 가 강한 참조.
    private let listener: TelloStateListenerProtocol

    /// 진단 로거 — 권한 거부 / start 실패 / stop 시각 등.
    private let log = Logger(subsystem: "DarwinForge", category: "TelloStateListenerOwner")

    // MARK: - Observable state

    /// listener.start() 성공 후 true, stop() 시 false. start 실패 시 false 유지.
    public private(set) var isActive: Bool = false

    /// 가장 최근 메시지 수신 시각. nil = 한 번도 수신 안 됨.
    public private(set) var lastReceived: Date?

    /// 누적 수신 메시지 개수. UI 진단 / health check 용.
    public private(set) var messagesReceived: Int = 0

    // MARK: - Init

    /// - Parameters:
    ///   - bridge: state 갱신 대상. 약한 참조 — caller 가 강한 참조 유지 필요.
    ///   - listener: 주입 가능 (테스트). default 는 실 `TelloStateListener()` —
    ///               init 자체는 socket 미생성 (cost 0).
    public init(bridge: WalkLabRCBridge?,
                listener: TelloStateListenerProtocol = TelloStateListener()) {
        self.bridge = bridge
        self.listener = listener
    }

    deinit {
        // owner 해제 시 listener 자원 정리. callback 도 nil 화.
        // @MainActor isolated deinit 우회 — listener.stop 은 self-isolated queue.
        listener.onState = nil
        listener.stop()
    }

    // MARK: - Lifecycle

    /// listener 활성화 — callback 등록 후 socket bind. 이미 활성이면 no-op.
    ///
    /// silent 실패 정책: NSLocalNetworkUsageDescription 미허락 등으로 NWListener
    /// 가 throw 시 OSLog warning + isActive=false 유지. caller 는 isActive 확인
    /// 또는 messagesReceived 변화로 실 동작 검증.
    public func start() {
        guard !isActive else {
            log.debug("start() — already active (no-op)")
            return
        }
        // callback 등록 — Sendable closure 에서 MainActor hop.
        // weak self: owner 해제 시 잔여 callback 안전.
        listener.onState = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bridge?.updateTelloState(msg)
                self.lastReceived = Date()
                self.messagesReceived += 1
            }
        }
        do {
            try listener.start()
            isActive = true
            log.info("Tello state listener active (UDP 8890)")
        } catch {
            // 권한 거부 등 — silent 실패 + log.
            // callback 은 등록 상태로 두되 isActive=false → caller 가 재시도 가능.
            log.error("Tello state listener start failed: \(error.localizedDescription, privacy: .public)")
            isActive = false
        }
    }

    /// listener 종료 — callback 해제 + socket close. idempotent.
    /// 본 호출 후 start() 재호출 시 callback 재등록 → 재사용 가능.
    public func stop() {
        // 이미 비활성이라도 listener.stop 은 idempotent — 한 번 더 호출 안전.
        listener.stop()
        listener.onState = nil
        isActive = false
        log.debug("Tello state listener stopped")
    }
}
