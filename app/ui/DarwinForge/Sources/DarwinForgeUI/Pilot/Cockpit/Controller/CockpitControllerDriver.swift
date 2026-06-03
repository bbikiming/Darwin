import Foundation

/// `CockpitControllerSource` → `ControllerInputResolver` → `CockpitState` 를 잇는
/// 프로파일 구동 드라이버. 기존 `CockpitGameControllerWatcher` 의 하드코딩 매핑을
/// 일반화 — 소스(GC/HID/Mock)·프로파일과 무관하게 동일 주입 경로.
///
/// 30Hz 폴링으로 매 프레임 스냅샷을 의미 출력으로 변환 후 cockpit 에 주입한다.
/// 이동/머리는 연속값, 안전·토글 버튼은 **rising-edge** 로 1회 발화(hold spam 차단).
///
/// 데드맨 enable-hold / 끊김 failsafe / activator 통합은 **M3 범위** — 여기선
/// 연결 변화 콜백 훅만 두고 즉시 주입한다.
@MainActor
public final class CockpitControllerDriver {

    private weak var state: CockpitState?
    private let source: CockpitControllerSource

    /// 활성 바인딩 프로파일 — 런타임 교체 가능(프리셋 전환).
    public var profile: ControllerBindingProfile

    private var pollTimer: Timer?

    // 버튼 edge-trigger 직전 상태.
    private var prevEmergency = false
    private var prevRecover   = false
    private var prevBall      = false

    public init(
        state: CockpitState,
        source: CockpitControllerSource,
        profile: ControllerBindingProfile = .xbox
    ) {
        self.state   = state
        self.source  = source
        self.profile = profile
    }

    // MARK: - Lifecycle

    public func start(pollInterval: TimeInterval = 1.0 / 30.0) {
        guard pollTimer == nil else { return }

        source.onConnectionChange = { [weak self] connected in
            self?.handleConnectionChange(connected)
        }
        source.start()
        state?.setController(name: source.displayName)

        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pollTimer = timer
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        source.onConnectionChange = nil
        source.stop()
    }

    // MARK: - 주입 (테스트가 직접 호출 가능)

    /// 한 프레임 처리 — 소스 capture → 주입. 미연결이면 no-op.
    public func tick() {
        guard let snapshot = source.capture() else { return }
        inject(snapshot)
    }

    /// 결정론적 주입 — 외부 스냅샷을 즉시 cockpit 에 반영(단위테스트 진입점).
    public func inject(_ snapshot: ControllerSnapshot) {
        guard let state else { return }
        let resolved = ControllerInputResolver.resolve(snapshot, profile: profile)

        // 이동: ResolvedControllerInput 이미 apply 관례(−전진/+우/+우회전).
        state.apply(leftX: resolved.leftX, leftY: resolved.leftY,
                    turn: resolved.turn, from: .gamepad)
        // 머리: rate 모드 — 보행과 독립.
        state.applyHead(panNorm: resolved.headPan, tiltNorm: resolved.headTilt)

        // 안전/토글 버튼 rising-edge.
        fireOnRisingEdge(resolved.emergencyStop, prev: &prevEmergency) {
            state.triggerEmergency()
        }
        fireOnRisingEdge(resolved.recover, prev: &prevRecover) {
            state.triggerRecovery()
        }
        fireOnRisingEdge(resolved.ballTracking, prev: &prevBall) {
            state.triggerBallTrackingToggle()
        }
    }

    // MARK: - 내부

    private func fireOnRisingEdge(_ current: Bool, prev: inout Bool, _ action: () -> Void) {
        if current && !prev { action() }
        prev = current
    }

    private func handleConnectionChange(_ connected: Bool) {
        state?.setController(name: connected ? source.displayName : nil)
        // M3: 끊김 시 failsafe(profile.failsafe) 적용 예정.
    }
}
