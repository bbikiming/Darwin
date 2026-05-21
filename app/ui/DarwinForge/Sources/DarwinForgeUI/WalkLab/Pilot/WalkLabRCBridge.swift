import Foundation
import Observation

/// **v1.17.0 (2026-05-21) Phase 4 — Tello stick → WalkLabSession 통합 bridge**.
///
/// PilotIntent 를 받아 SafetyGate 통과 후 WalkLabSession 의 walking amplitude 에 반영.
/// stick 입력 자체는 `PilotInputAccumulator` 에 누적 → trial 종료 시 `PilotInputSummary` 로
/// store 에 기록 → Recommender 학습 신호.
///
/// # 의존 그래프 (단방향)
///
/// ```
/// TelloLinkProtocol (stick read)
///         ↓
///   TelloRCMapper.map (pure)
///         ↓
///    PilotIntent (값 타입)
///         ↓
///   WalkLabRCBridge ───→ PilotSafetyGate (검사)
///         ↓
///   WalkLabSession (slider mutation)
///         ↓
///   PilotInputAccumulator (통계)
/// ```
///
/// # @MainActor + @Observable
///
/// View 가 `lastIntent` 또는 `safetyMessage` 를 reactive 하게 볼 수 있도록 @Observable.
/// 모든 입력 처리는 main actor — Tello async task 가 finalize 시 hop.
@MainActor
@Observable
public final class WalkLabRCBridge {

    // MARK: - 외부 의존성

    private let tello: TelloLinkProtocol
    /// 약한 참조 — view lifecycle 에 영향 안 줌. session 가 owner.
    public weak var session: WalkLabSession?

    // MARK: - 관찰 가능 상태

    /// 가장 최근 처리한 intent. nil = 미수신.
    public private(set) var lastIntent: PilotIntent?
    /// 안전 게이트 거부 사유 — 사용자 표시 용. nil = 정상.
    public private(set) var safetyMessage: String?
    /// stick 입력 누적기 — trial 종료 시 summary 추출.
    public private(set) var accumulator = PilotInputAccumulator()
    /// emergency 발화 횟수 — telemetry.
    public private(set) var emergencyCount: Int = 0

    // MARK: - Settings

    /// `false` 면 stick 입력 무시 (정지 + emergency 만 허용). 사용자 명시 토글.
    public var enabled: Bool = true
    /// stick 변환 scale — 사용자 sensitivity 조정.
    public var scale: TelloRCMapper.Scale = .default

    // MARK: - Init

    public init(tello: TelloLinkProtocol) {
        self.tello = tello
    }

    // MARK: - 주 entry point

    /// Tello stick 4채널 (-100..100) 을 받아 PilotIntent 로 변환 + 처리.
    public func handleTelloStick(lr: Int, fb: Int, ud: Int, yaw: Int) {
        let cmd = TelloRCMapper.map(lr: lr, fb: fb, ud: ud, yaw: yaw, scale: scale)
        let intent: PilotIntent = cmd.isStop
            ? .stop(from: .tello)
            : .move(cmd, from: .tello)
        process(intent)
    }

    /// 키보드 / UI 등 다른 source 의 walking command 처리.
    public func handleMove(_ cmd: WalkingCommand, from source: InputSource) {
        let intent: PilotIntent = cmd.isStop ? .stop(from: source) : .move(cmd, from: source)
        process(intent)
    }

    /// 사용자 emergency — UI 버튼 / 단축키 / Tello "emergency" 명령.
    public func handleEmergency(from source: InputSource) {
        process(.emergency(from: source))
    }

    /// 정상 stop — Tello deadzone 진입 또는 사용자 명시.
    public func handleStop(from source: InputSource) {
        process(.stop(from: source))
    }

    // MARK: - Core process

    private func process(_ intent: PilotIntent) {
        lastIntent = intent
        accumulator.record(intent)

        // SafetyGate — bridge 자체 disable 또는 session 가 보행 시작 안 했으면 차단.
        guard let session else {
            safetyMessage = "WalkLabSession 미연결 — bridge.session 설정 필요"
            return
        }
        if !enabled && intent.kind != .emergency {
            safetyMessage = "Bridge 비활성 — emergency 만 허용"
            return
        }
        // emergency 는 무조건 통과.
        if intent.kind == .emergency {
            emergencyCount += 1
            session.emergencyStop(trigger: .externalEStop)
            Task { [tello] in await tello.emergency() }
            safetyMessage = "긴급 정지 발화 — 모든 채널 차단"
            return
        }
        // bus / cradle 검사 — preset 시작 path 와 동일.
        if session.current == .idle {
            safetyMessage = "보행 시작 후 stick 입력 가능 — preset 먼저 선택"
            return
        }

        // 정상 처리 — Walking module amplitude 갱신.
        switch intent.kind {
        case .move(let cmd):
            applyAmplitude(cmd, in: session)
            safetyMessage = nil
        case .stop:
            applyAmplitude(.stop, in: session)
            safetyMessage = nil
        case .motion, .emergency:
            break  // motion 은 Phase 5, emergency 위에서 처리.
        }
    }

    /// `WalkLabSession` 의 advanced slider 와 동일 채널에 stick 값 주입.
    /// 보행 중 변경 시 `walkTuningRestartTask` 가 220ms debounce 후 cycle 재시작 (Mac sparse)
    /// 또는 `WalkLabOnboardBridge` 가 300ms debounce 후 SSH 송출 (Onboard) — 기존 채널 활용.
    private func applyAmplitude(_ cmd: WalkingCommand, in session: WalkLabSession) {
        session.strideMm = cmd.strideMm
        session.sideMm = cmd.sideMm
        session.turnDeg = cmd.turnDeg
        // 사용자 안내 — 어떤 source 가 명령했는지.
        if let source = lastIntent?.source {
            session.lastRobotEvent = "🕹 \(source.label) → stride=\(Int(cmd.strideMm)) side=\(Int(cmd.sideMm)) turn=\(Int(cmd.turnDeg))"
        }
    }

    // MARK: - Trial 통계 hook

    /// trial 종료 시 호출 — `accumulator` 의 현재 summary 반환 + reset.
    public func snapshotAndReset() -> PilotInputSummary {
        let snap = accumulator.summarize()
        accumulator.reset()
        return snap
    }
}
