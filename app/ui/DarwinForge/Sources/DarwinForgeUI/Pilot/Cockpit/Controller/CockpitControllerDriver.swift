import Foundation

/// `CockpitControllerSource` → `ControllerInputResolver` → `CockpitState` 를 잇는
/// 프로파일 구동 드라이버. 기존 `CockpitGameControllerWatcher` 의 하드코딩 매핑을
/// 일반화 — 소스(GC/HID/Mock)·프로파일과 무관하게 동일 주입 경로.
///
/// 30Hz 폴링으로 매 프레임 스냅샷을 의미 출력으로 변환 후 cockpit 에 주입한다.
/// 이동/머리는 연속값, 버튼 액션은 activator 모드(hold/start/toggle/longPress)에
/// 따라 발화한다 (M3 — 프로파일의 activator/데드맨/터보를 실제 소비).
///
/// # 안전 (PRD §13)
/// - **E-STOP 은 activator·데드맨과 무관** — 설정과 관계없이 누름 rising-edge 에
///   즉시 발화한다. longPress 등으로 지연되면 안 된다.
/// - 데드맨(enabled + 버튼 지정)은 이동/회전만 게이트 — 복구/머리는 항상 동작.
/// - 터보는 이동/회전 × `ControllerDriveModifiers.turboScale`, ±1 클램프.
@MainActor
public final class CockpitControllerDriver {

    private weak var state: CockpitState?
    private let source: CockpitControllerSource

    /// 활성 바인딩 프로파일 — 런타임 교체 가능(프리셋 전환).
    /// 교체 시 activator 상태를 초기화해 잔존 토글/홀드 상태를 막는다.
    public var profile: ControllerBindingProfile {
        didSet {
            activatorStates = [:]
            previousActive = [:]
        }
    }

    private var pollTimer: Timer?

    /// E-STOP rising-edge 직전 상태 (activator 미적용 — 안전 우선).
    private var prevEmergency = false

    /// 액션별 activator 상태머신 (recover/ballTracking 등).
    private var activatorStates: [CockpitAction: ActivatorState] = [:]
    private var previousActive: [CockpitAction: Bool] = [:]

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

        // L3: .common 모드 — 트래킹 중에도 입력 폴 + E-STOP 에지 감지 지속.
        pollTimer = CockpitTimers.repeating(pollInterval) { [weak self] in
            self?.tick()
        }
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
        inject(snapshot, nowMs: Self.monotonicNowMs())
    }

    /// 시각 주입 버전 — activator(longPress 등) 시간 계산을 테스트에서 결정론적으로.
    public func inject(_ snapshot: ControllerSnapshot, nowMs: Int) {
        guard let state else { return }
        let resolved = ControllerInputResolver.resolve(snapshot, profile: profile)

        // 이동/회전: 데드맨 게이트 + 터보 스케일 적용 후 주입.
        let drive = ControllerDriveModifiers.modifiedDrive(
            leftX: resolved.leftX, leftY: resolved.leftY, turn: resolved.turn,
            deadmanSatisfied: ControllerDriveModifiers.deadmanSatisfied(
                profile: profile, snapshot: snapshot),
            turboHeld: ControllerDriveModifiers.isTurboHeld(
                profile: profile, snapshot: snapshot)
        )
        state.apply(leftX: drive.leftX, leftY: drive.leftY,
                    turn: drive.turn, from: .gamepad)
        // 머리: rate 모드 — 보행·데드맨과 독립.
        state.applyHead(panNorm: resolved.headPan, tiltNorm: resolved.headTilt)

        // E-STOP — 안전 최우선: activator/데드맨 무시, rising-edge 즉시 발화.
        if resolved.emergencyStop && !prevEmergency { state.triggerEmergency() }
        prevEmergency = resolved.emergencyStop

        // 복구/볼트랙 — 프로파일 activator 모드 소비 (기본 .start = 누름 1회).
        stepActivator(.recover, pressed: resolved.recover, nowMs: nowMs) {
            state.triggerRecovery()
        }
        stepActivator(.ballTracking, pressed: resolved.ballTracking, nowMs: nowMs) {
            state.triggerBallTrackingToggle()
        }
    }

    // MARK: - 내부

    /// 액션의 activator 상태머신을 한 프레임 전이하고, 발화 정책 충족 시 `trigger`.
    private func stepActivator(
        _ action: CockpitAction,
        pressed: Bool,
        nowMs: Int,
        _ trigger: () -> Void
    ) {
        let type = profile.activators[action] ?? .start
        let prev = activatorStates[action] ?? .idle
        let prevActive = previousActive[action] ?? false
        let (next, isActive, fired) = prev.updated(pressed: pressed, nowMs: nowMs, type: type)
        activatorStates[action] = next
        previousActive[action] = isActive
        if type.firesEvent(previousActive: prevActive, isActive: isActive, fired: fired) {
            trigger()
        }
    }

    private func handleConnectionChange(_ connected: Bool) {
        state?.setController(name: connected ? source.displayName : nil)
        guard !connected else { return }
        // **S2 (2026-06-11)**: 끊김 failsafe 집행. profile.failsafe 의 모든 케이스
        // (freeze/sit/safeStop)는 "즉시 정지"를 공통 전제로 한다 — 우선 stick zero 주입으로
        // stale 보행을 끊는다(sit/safeStop 의 추가 모션은 후속). activator/터보 상태도
        // 잔존 토글이 남지 않도록 초기화. E-STOP 이 아니라 토크는 유지.
        prevEmergency = false
        activatorStates = [:]
        previousActive = [:]
        state?.inputSourceLost()
    }

    /// 단조 증가 시각(ms) — 벽시계 변경에 영향받지 않음.
    private static func monotonicNowMs() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
