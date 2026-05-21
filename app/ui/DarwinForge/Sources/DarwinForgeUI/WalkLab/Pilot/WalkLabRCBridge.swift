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
    /// **v1.20.17.1 사이클 23-fix MEDIUM 2 (코덱스)** — handlePreset 호출 mirror count.
    /// @Observable 이 internal accumulator 변경 추적 안 함 → View 리액티브 갱신 안 됨.
    /// 본 mirror 가 bridge 의 observable property 라서 변경 시 View 자동 refresh.
    /// accumulator 와 분리 — accumulator 는 trial 단위 reset, mirror 는 bridge lifetime.
    public private(set) var presetChangeMirror: Int = 0

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
    /// **v1.20.14 (2026-05-22) 사이클 20** — amplitude smoothing factor (EMA α).
    /// 0 = 무한 smooth (변화 없음 — 입력 무시), 1 = 즉시 (smoothing 없음, 종전 동작).
    /// default 1.0 — backward compat (기존 테스트 + Tello stick 즉시 반응 기대치 유지).
    /// 게임 UX 원하면 KeyboardPilotPanel 이 onAppear 시 0.5 설정.
    public var smoothingFactor: Double = 1.0

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

    /// **v1.20.12 사이클 18** — emergency recovery (사이클 10-fix CRITICAL 후속).
    /// session.emergencyStopActive=true 일 때 사용자 명시 recovery → flag clear, walking 미시작.
    /// 이후 handlePreset / handleTelloStick 가 다시 정상 동작.
    public func handleRecovery(from source: InputSource) {
        guard let session else {
            safetyMessage = "WalkLabSession 미연결"
            return
        }
        guard session.emergencyStopActive else {
            safetyMessage = "Emergency 상태 아님 — recovery 불필요"
            return
        }
        session.exitEmergencyMode()
        safetyMessage = nil
        // **v1.20.13.1 사이클 19-fix LOW 1 (코덱스)** — lastIntent clear.
        // 종전: lastIntent 는 emergency 그대로 → HUD sourceChip 가 stale ("긴급" 표시 유지).
        // 신규: nil 로 reset → HUD "대기" 로 복귀, recovery 완료 시각화.
        lastIntent = nil
        session.lastRobotEvent = "✅ \(source.label) → emergency recovery (preset 입력 활성)"
    }

    /// **v1.20.4 (2026-05-22) 사이클 10** — preset 직접 선택 (number key / future button).
    /// session.start (preflight 포함) 호출 + lastRobotEvent 갱신. `.idle` 은 session.stop.
    /// bridge 비활성 (enabled=false) 시 거부 + safetyMessage.
    public func handlePreset(_ preset: WalkLabPreset, from source: InputSource) {
        guard let session else {
            safetyMessage = "WalkLabSession 미연결 — bridge.session 설정 필요"
            return
        }
        // **v1.20.16 사이클 22** — accumulator 에 preset 전환 기록 (telemetry).
        accumulator.recordPresetChange(source: source)
        // **v1.20.17.1 사이클 23-fix MEDIUM 2 (코덱스)** — observable mirror 동시 증가.
        presetChangeMirror += 1
        if !enabled {
            safetyMessage = "Bridge 비활성 — preset 단축키 무시 (emergency 만 허용)"
            return
        }
        // **v1.20.4.1 사이클 10-fix CRITICAL (코덱스)** — emergency 상태에서 preset 재시작 차단.
        // 종전: Space (emergency) → 1 (preset) 순서로 입력 시 즉시 재시작 가능 (큰 안전 hole).
        // 신규: emergencyStopActive 동안 사용자 명시 recovery 전까지 preset 무시. emergency 만 통과.
        if session.emergencyStopActive {
            safetyMessage = "긴급 정지 상태 — preset 단축키 차단 (recovery 필요)"
            return
        }
        if preset == .idle {
            // .idle == 정지. 현재 보행 중일 때만 의미 있음.
            if session.current != .idle {
                session.stop()
                session.lastRobotEvent = "🎮 \(source.label) → 정지 (preset .idle)"
                safetyMessage = nil
            } else {
                safetyMessage = "이미 정지 상태"
            }
            return
        }
        // **v1.20.4.1 사이클 10-fix HIGH (코덱스)** — same-preset retry 의 false-positive 차단.
        // 종전: session.start 후 `current == preset` true 면 성공 처리 → 활성 .march 에 1 재입력
        // 시 preflight 가 alreadyWalking 으로 차단해도 current 변화 없어 성공 메시지 + nil safety.
        //
        // 신규 판정: `current 가 실제로 바뀌었고 preset 으로 도착`. 사이드 채널:
        // - sim mode: current 변경 후 startWalkCycle 의 noConnection 차단 — 성공 판정 (current 변함)
        // - real success: current = preset, lastPreflightFailure = nil — 성공
        // - alreadyWalking retry: quickPreflight 가 current 변경 전에 return → 변화 없음 → 차단
        // - 다른 preset switch 중 alreadyWalking: 동일 — current 변화 없음 → 차단
        let currentBefore = session.current
        let preflightBefore = session.lastPreflightFailure
        session.start(preset)

        if session.current == preset && session.current != currentBefore {
            // 실 진입 (sim 정보성 noConnection 포함). 성공 처리.
            // **v1.20.17.1 사이클 23-fix MEDIUM 1 (코덱스)** — session.start 이 captureTrialStart
            // 통해 accumulator.reset 호출 → 위 recordPresetChange 가 무효화됨. 재기록.
            // (mirror 는 reset 영향 안 받음 — bridge lifetime).
            accumulator.recordPresetChange(source: source)
            session.lastRobotEvent = "🎮 \(source.label) → preset \(preset.rawValue) 시작"
            safetyMessage = nil
        } else if let failure = session.lastPreflightFailure, failure != preflightBefore {
            // **사이클 10-fix MEDIUM 1 (코덱스)** — 진단 코드 대신 사용자 메시지 노출.
            safetyMessage = failure.userMessage
        } else {
            // 기타 차단 (예: startWalkCycle 내부 추가 guard, race).
            safetyMessage = "Preset \(preset.rawValue) 시작 차단 — \(session.startBlockedReason ?? "알 수 없음")"
        }
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
            applyAmplitude(.stop, in: session, applyHardZero: true)
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
    ///
    /// **v1.20.14 사이클 20 + 20-fix (코덱스)** — EMA smoothing + engine sync + hard-stop.
    /// - `applyHardZero=true`: bypass EMA, 진정한 0 도달 (release/stop path).
    /// - `applyHardZero=false`: EMA blend (game ramp UX).
    /// - **CRITICAL fix**: advanced=true 자동 활성 + syncCommandToEngine 호출 → 실 walking 에 반영.
    private func applyAmplitude(_ cmd: WalkingCommand, in session: WalkLabSession,
                                 applyHardZero: Bool = false) {
        // **사이클 20-fix CRITICAL (코덱스)** — advanced=true 자동 활성 (amplitude 쓰기 전에!).
        // 이유: `advanced` didSet 가 `loadPresetDefaultsToSliders(current)` 호출 →
        // 기존 strideMm 0 으로 reset. 따라서 amplitude 적용 BEFORE 가 아닌 advanced AFTER 면
        // 우리 값이 즉시 덮임. 순서: advanced first, then write amplitude.
        if !session.advanced {
            session.advanced = true
        }
        if applyHardZero {
            // **사이클 20-fix HIGH 1 (코덱스)** — .stop path 의 hard-zero.
            session.strideMm = cmd.strideMm
            session.sideMm   = cmd.sideMm
            session.turnDeg  = cmd.turnDeg
        } else {
            let α = max(0, min(1, smoothingFactor))  // clamp 0..1 (safety)
            session.strideMm = α * cmd.strideMm + (1 - α) * session.strideMm
            session.sideMm   = α * cmd.sideMm   + (1 - α) * session.sideMm
            session.turnDeg  = α * cmd.turnDeg  + (1 - α) * session.turnDeg
        }
        session.syncCommandToEngine()
        // 사용자 안내 — 어떤 source 가 명령했는지.
        if let source = lastIntent?.source {
            session.lastRobotEvent = "🕹 \(source.label) → stride=\(Int(session.strideMm)) side=\(Int(session.sideMm)) turn=\(Int(session.turnDeg))"
        }
    }

    // MARK: - Trial 통계 hook

    /// trial 종료 시 호출 — `accumulator` 의 현재 summary 반환 + reset.
    public func snapshotAndReset() -> PilotInputSummary {
        let snap = accumulator.summarize()
        accumulator.reset()
        return snap
    }

    // MARK: - Live activity metrics (Cycle 14)

    /// **v1.20.8 사이클 14** — 최근 1초간 event rate (events/sec). HUD activity dot 등에 사용.
    /// PilotInputAccumulator.eventsPerSecond pass-through. 0 = 입력 없음.
    public var activityRate: Double {
        accumulator.eventsPerSecond(window: 1.0)
    }

    /// **v1.20.8 사이클 14** — activity 가 active 한지 (rate > 0). 시각 indicator 용 boolean.
    public var isActive: Bool {
        activityRate > 0.5  // 0.5 events/sec 이상이면 active 로 간주.
    }
}
