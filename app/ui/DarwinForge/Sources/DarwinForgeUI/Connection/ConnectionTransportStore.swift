import Foundation
import ForgeCore

/// Wave 4.2.2 (사이클 V261-1) — `ConnectionStore` 의 transport state 격리 store.
///
/// # 비유
///
/// 자동차의 트랜스미션은 엔진(파워트레인) 과 다른 부품이다. 트랜스미션은
/// "기어 위치" 만 보관하고, 엔진 제어 / 토크 / 발화 시점은 별도 ECU 가 결정한다.
/// 동일하게 본 store 는 "어떤 포트가 있나, 어디 연결됐나, 어떤 상태인가" 만 보관한다.
/// 실제 USB / TCP 통신 lifecycle (`connect`/`disconnect`/`reconnect`) 결정은 여전히
/// `ConnectionStore` 가 한다 — 그 lifecycle 은 bus / harness / telemetry / health 등
/// 여러 store 를 cross-cutting 으로 다뤄야 하기 때문.
///
/// # 분리 동기 (Wave 4.2.2, ADR-002 Phase 4.2.2)
///
/// 종전: `ConnectionStore` (1930 LOC) 안에 transport state (status / 포트 / endpoint /
/// reconnect counter) 가 health / IMU / FSR / pose-apply / e-stop / recovery 와 혼재.
/// god object 화 → 변경 영향 추적 곤란 + SwiftUI 가 transport state 변화에도 health 구독자
/// 까지 모두 재평가.
///
/// 신규: `ConnectionTransportStore` 가 transport-only @Published 보유. `ConnectionStore`
/// 가 init 시 생성 + `transport` 로 expose. 기존 view 의 `store.status` 등은 backward-compat
/// computed property (delegate to `transport.status`) 로 그대로 유지 — view migration 불필요.
///
/// # 책임 (state-only, lifecycle 없음)
///
/// - port enumeration 결과 (`availablePorts` + `selectedPort`)
/// - status enum + transition tracking
/// - 현재 활성 endpoint (`activeEndpoint`)
/// - 네트워크 endpoint 입력 (`networkHost` / `networkPort`)
/// - 자동 재연결 후보 (`lastSuccessfulEndpoint`)
/// - 재연결 진행 상태 (`reconnectAttempt` / `isReconnecting`)
///
/// # 비-책임 (lifecycle 은 `ConnectionStore` 에 잔존)
///
/// 다음 메서드는 본 store 에 옮기지 않는다 — bus / harness / health / telemetry / IMU /
/// recovery state 의 cross-cutting orchestration 필요:
/// - `connect(endpoint:)` / `performConnect`
/// - `disconnect()` / `forceDisconnectWithError`
/// - `autoConnect()` / `connectNetwork()` / `autoReconnectIfPossible()`
/// - `startReconnectIfPossible()` / `cancelReconnect()`
/// - `refreshPorts()` (status 에 에러 set + SerialPortEnumerator 호출)
///
/// 본 store 는 단순 state holder + mutator. 외부 lifecycle 메서드가 `transport.status = ...`
/// 처럼 직접 mutate.
@MainActor
public final class ConnectionTransportStore: ObservableObject {

    // MARK: - Status enum

    /// 연결 상태 — `ConnectionStore.Status` 와 별개 typealias 아니고 동일 enum.
    /// `ConnectionStore.Status` 가 본 enum 의 typealias 로 backward-compat 유지.
    public enum Status: Equatable {
        case disconnected
        case connecting(String)
        case connected(BoardSnapshot)
        case error(String)
    }

    // MARK: - Port enumeration

    /// `/dev/cu.*` 후보 목록 — `refreshPorts()` 가 갱신.
    @Published public var availablePorts: [String] = []
    /// 사용자가 선택한 (또는 자동 추정된) USB 포트.
    @Published public var selectedPort: String?

    // MARK: - Status

    /// 연결 상태 — 변경 시 외부 observer (heartbeat 등) 가 didSet 으로 hook.
    ///
    /// **주의**: 본 store 의 status 변경은 단순 상태 갱신만. heartbeat start/stop 등
    /// 부수 효과는 `ConnectionStore` 가 자신의 status (= transport.status delegate) 의
    /// didSet 에서 처리. 본 store 는 didSet 없음 — pure state holder.
    @Published public var status: Status = .disconnected

    // MARK: - Endpoint

    /// 현재 활성 endpoint (.usbSerial 또는 .network). 연결 해제 시 nil.
    @Published public var activeEndpoint: Endpoint?

    /// 사용자가 입력한 호스트 (예: "10.0.0.42" 또는 "op2.local").
    @Published public var networkHost: String = ""
    /// 사용자가 입력한 포트 (default 5530 — `forge serve`).
    @Published public var networkPort: UInt16 = 5530

    // MARK: - Auto-reconnect state

    /// 연결이 마지막으로 성공한 endpoint. 자동 재연결의 후보.
    @Published public private(set) var lastSuccessfulEndpoint: Endpoint?
    /// 현재까지 시도한 재연결 횟수 (0 = 아직 안 함).
    @Published public private(set) var reconnectAttempt: Int = 0
    /// 자동 재연결 active 여부 (UI 배너 표시용).
    @Published public private(set) var isReconnecting: Bool = false

    public init() {}

    // MARK: - Mutators (lifecycle 메서드가 호출)
    //
    // `private(set)` 으로 외부 view 가 직접 mutate 못 하도록 보호. lifecycle 메서드 (ConnectionStore
    // 의 connect/disconnect/reconnect) 만이 본 mutator 통해 갱신.

    /// 자동 재연결 진행 상태 set — `ConnectionStore.startReconnectIfPossible` 가 호출.
    public func beginReconnecting() {
        isReconnecting = true
        reconnectAttempt = 0
    }

    /// 재연결 시도 attempt 갱신 — 백오프 루프가 매 attempt 시작 시 호출.
    public func updateReconnectAttempt(_ attempt: Int) {
        reconnectAttempt = attempt
    }

    /// 재연결 완료 (성공/실패 모두) — counter / flag 리셋.
    public func endReconnecting() {
        isReconnecting = false
        reconnectAttempt = 0
    }

    /// 연결 성공 시 — `lastSuccessfulEndpoint` 갱신 (UserDefaults persist 는 호출자 책임).
    public func recordSuccessfulEndpoint(_ endpoint: Endpoint) {
        lastSuccessfulEndpoint = endpoint
    }

    /// 사용자 명시 disconnect — 자동 재연결 후보 제거.
    public func clearLastSuccessfulEndpoint() {
        lastSuccessfulEndpoint = nil
    }

    /// 앱 시작 시 UserDefaults 로부터 restore — 호출자가 decode 후 전달.
    public func restoreLastSuccessfulEndpoint(_ endpoint: Endpoint) {
        lastSuccessfulEndpoint = endpoint
    }

    // MARK: - Reset

    /// 전체 reset — 테스트 및 명시 reset 용. status 는 .disconnected 로.
    public func reset() {
        availablePorts.removeAll()
        selectedPort = nil
        status = .disconnected
        activeEndpoint = nil
        networkHost = ""
        networkPort = 5530
        lastSuccessfulEndpoint = nil
        reconnectAttempt = 0
        isReconnecting = false
    }
}
