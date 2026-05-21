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

    /// **v1.18.0.2 (사이클 2)** — MotionBlender 통합 (Phase 3 의 외톨이 활성화).
    /// PilotIntent.motion 발화 시 blender.play() 호출 + SafetyContext 전달.
    public let motionBlender = MotionBlender()

    /// **v1.20.0 (사이클 5/6)** — Tello state port (UDP 8890) 의 가장 최근 메시지.
    /// nil = 미수신 또는 Tello 미연결. NWListener integration 은 별도 phase.
    /// 테스트 / view 가 수동 setter 호출 가능 (debug / 사용자 시각화).
    public var lastTelloState: TelloStateMessage?

    /// 외부 (NWListener 또는 mock) 가 호출 — state 갱신 + 안전 검증.
    public func updateTelloState(_ msg: TelloStateMessage) {
        lastTelloState = msg
        // battery low warning — 사용자 안내.
        if msg.batteryLevel == .low {
            safetyMessage = "⚠️ Tello 배터리 \(msg.batteryPct)% — 충전 권장"
        }
    }

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
    /// **v1.20.3 (2026-05-22) 사이클 9** — idle 상태에서 첫 pilot 입력 시 자동 시작할 preset.
    /// 게임 캐릭터처럼 W 키 → 즉시 걷기 (preset 버튼 클릭 불필요).
    /// `nil` = auto-start 비활성 (사용자가 명시 preset 선택해야 입력 활성).
    /// 기본 `.march` — 가장 안전한 (낮은 amplitude) preset.
    public var pilotAutoStartPreset: WalkLabPreset? = .march

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
        // **v1.20.3.1 사이클 9-fix MEDIUM 2 (코덱스)** — accumulator.record 는 각 path 에서
        // 정확히 1회. 종전: 진입 즉시 record + auto-start 후 재 record → session.pilotBridge nil
        // (production wiring 실패) 시 reset 안 돼 double-count. 신규: path 별 1회 record.

        // SafetyGate — bridge 자체 disable 또는 session 가 보행 시작 안 했으면 차단.
        guard let session else {
            accumulator.record(intent)  // session 없어도 사용자 의도 기록 (telemetry).
            safetyMessage = "WalkLabSession 미연결 — bridge.session 설정 필요"
            return
        }
        if !enabled && intent.kind != .emergency {
            accumulator.record(intent)  // disabled 라도 사용자 의도 기록.
            safetyMessage = "Bridge 비활성 — emergency 만 허용"
            return
        }
        // emergency 는 무조건 통과.
        if intent.kind == .emergency {
            accumulator.record(intent)
            emergencyCount += 1
            session.emergencyStop(trigger: .externalEStop)
            Task { [tello] in await tello.emergency() }
            safetyMessage = "긴급 정지 발화 — 모든 채널 차단"
            return
        }
        // bus / cradle 검사 — preset 시작 path 와 동일.
        if session.current == .idle {
            // **v1.20.3 사이클 9** — 게임 캐릭터 idle 응답: 사용자가 keyboard/Tello move 입력 시
            // 자동으로 preset 시작. preflight 검사 (cradle/bus/IMU) 는 session.start 가 그대로 수행 →
            // 안전 우회 아님. .stop / .motion 같이 amplitude 없는 intent 는 skip.
            //
            // **scope 설계 (사이클 9-fix MEDIUM 1 코덱스 검수 응답)**:
            // 본 path 는 keyboard / Tello / 미래 game pad / DJI controller 등 **모든 move source**
            // 에 발화. 의도: 사용자가 stick/W 누르는 순간 → 즉시 robot 반응 (게임 UX). source 별
            // 차별 없는 일관 행동. 비활성 원하면 `pilotAutoStartPreset = nil`.
            guard let autoStartPreset = pilotAutoStartPreset,
                  case .move(let cmd) = intent.kind,
                  !cmd.isStop else {
                accumulator.record(intent)
                safetyMessage = "보행 시작 후 stick 입력 가능 — preset 먼저 선택"
                return
            }
            session.start(autoStartPreset)
            // session.start 가 실패한 경우 (preflight 차단) 여전히 idle → 종료.
            if session.current == .idle {
                accumulator.record(intent)
                safetyMessage = "Auto-start (\(autoStartPreset.rawValue)) 차단 — 안전 검사 미통과"
                return
            }
            // 성공 → 아래 일반 처리로 fall-through.
            // **주의**: session.start 가 captureTrialStart 호출 → bridge.accumulator.reset() 발생.
            // 본 intent 는 새 trial 의 첫 입력 — reset 후 record. session.pilotBridge nil 시 reset
            // 발생 안 함 → 단일 record (이전 record 가 진입 즉시 발화 안 했으므로 OK).
            accumulator.record(intent)
            // **사이클 9-fix LOW 1 (코덱스)** — lastRobotEvent overwrite 차단 위해 set 제거.
            // 종전: "🎮 ... auto-start" → applyAmplitude 즉시 "🕹 ... stride" 로 덮임 → 사용자 못 봄.
            // 사용자는 session.current 변화 (idle → march) 와 amplitude 메시지로 충분히 인지.
        } else {
            // 일반 (이미 walking 중) path — record.
            accumulator.record(intent)
        }

        // 정상 처리 — Walking module amplitude 갱신.
        switch intent.kind {
        case .move(let cmd):
            applyAmplitude(cmd, in: session)
            safetyMessage = nil
        case .stop:
            applyAmplitude(.stop, in: session)
            safetyMessage = nil
        case .motion(let id):
            // **v1.18.0.2 사이클 2**: motion intent 활성화 — Phase 3 의 MotionBlender 통합.
            // 단순 String id 기반 — caller 가 직접 MotionDescriptor 빌드해서 `handleMotion(_:)` 호출 권장.
            // 본 path 는 id resolution 미구현 — 사용자 안내 + accumulator 에만 기록.
            safetyMessage = "motion '\(id)' — handleMotion(_:descriptor:) 직접 호출 권장 (id resolution 미구현)"
        case .emergency:
            break  // emergency 위에서 처리.
        }
    }

    /// **v1.18.0.2 (사이클 2)** — MotionDescriptor 기반 motion intent 처리.
    /// PilotIntent.motion(String) 의 외부 caller 가 catalog 에서 descriptor 를 resolve 한 후 호출.
    /// MotionBlender.play 가 TransitionPolicy 통합 검증 → BlendResult 반환.
    @discardableResult
    public func handleMotion(_ descriptor: MotionDescriptor, from source: InputSource) -> BlendResult {
        let intent = PilotIntent(kind: .motion(descriptor.id), source: source)
        let result: BlendResult
        if let session = session {
            // SafetyContext — session 의 현재 balance + bus + risk.
            let ctx = SafetyContext(
                balanceState: session.balanceState,
                robotConnected: session.store?.bus != nil,
                riskAcknowledged: session.riskAcknowledged
            )
            result = motionBlender.play(descriptor, safetyContext: ctx)
        } else {
            // session 미연결 — sim only path. policy skip.
            result = motionBlender.play(descriptor, safetyContext: nil)
        }
        lastIntent = intent
        accumulator.record(intent)
        // 결과 반영.
        switch result {
        case .accepted, .acceptedFullBody:
            safetyMessage = nil
            session?.lastRobotEvent = "🎬 \(source.label) → motion '\(descriptor.displayLabel)' 적용"
        case .rejectedSafety(let reason):
            safetyMessage = reason
        case .rejectedEmptyChannels:
            safetyMessage = "motion 이 어떤 joint 도 점유 안 함 — 빈 명령 거부"
        }
        return result
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
