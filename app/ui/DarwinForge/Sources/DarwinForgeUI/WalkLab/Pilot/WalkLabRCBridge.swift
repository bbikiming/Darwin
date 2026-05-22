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
    public var enabled: Bool = true {
        didSet {
            // **v1.20.31 사이클 39** — 비활성 전환 시 release-all 발화 (안전 invariant).
            // 종전: 사용자가 enabled=false 토글해도 마지막 amplitude 가 session 에 남음.
            // 신규: 비활성 시 hardstop. emergency 와 별도 — robot 부드러운 정지.
            if oldValue == true && enabled == false {
                if let session = session {
                    applyAmplitude(.stop, in: session, applyHardZero: true)
                }
                safetyMessage = "Bridge 비활성 — emergency 만 허용"
            }
        }
    }

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
    /// **v1.20.22 (2026-05-22) 사이클 28 + 사이클 30** — PilotIntent.motion(id) → MotionDescriptor 변환.
    /// default: PresetBacked + PageBacked composite — `"preset.<name>"` + `"page.<slot|name>"` 지원.
    /// 사용자가 추가 backend (Teach 등) 주입 가능.
    /// **주의**: 기존 enum `MotionCatalog` (motion_4096 페이지) 와 다름 — 의도적으로 prefix 분리.
    public var pilotMotionCatalog: PilotMotionCatalog = CompositePilotMotionCatalog([
        PresetBackedPilotMotionCatalog(),
        PageBackedPilotMotionCatalog()
    ])

    /// **v1.20.45 (2026-05-22) 사이클 59** — input → engine latency tracker (옵셔널).
    /// `nil` (default) 시 측정 비활성 — overhead 0. critic 지적 "game character 정량 기준"
    /// 응답을 위한 명시 활성. 활성 시 process / applyAmplitude 가 stage 별 record.
    public var latencyTracker: PilotLatencyTracker?

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

    /// **v1.20.22.1 사이클 28-fix HIGH (코덱스) + 사이클 36-fix HIGH 1** — id 기반 motion 진입.
    /// 외부 caller (음성, MCP, button 등) 가 motion descriptor 직접 구성 없이 id 만으로 발화.
    /// 사이클 36-fix HIGH 1: safety gate (enabled / emergencyStopActive) 적용.
    @discardableResult
    public func handleMotion(id: String, from source: InputSource) -> BlendResult {
        // 사이클 36-fix HIGH 1 (코덱스): safety gate.
        if !enabled {
            safetyMessage = "Bridge 비활성 — motion 차단"
            return .rejectedSafety(reason: "bridge disabled")
        }
        if let session = session, session.pilotIsEmergency {
            safetyMessage = "긴급 정지 상태 — motion 차단 (recovery 필요)"
            return .rejectedSafety(reason: "emergency active")
        }
        guard let descriptor = pilotMotionCatalog.resolve(id) else {
            safetyMessage = "모션 '\(id)' — 등록 안 됨. 가능한 id: \(pilotMotionCatalog.knownIds.prefix(3).joined(separator: ", "))…"
            return .rejectedSafety(reason: "motion id \"\(id)\" not in catalog")
        }
        return handleMotion(descriptor, from: source)
    }

    /// **v1.20.12 사이클 18** — emergency recovery (사이클 10-fix CRITICAL 후속).
    /// session.emergencyStopActive=true 일 때 사용자 명시 recovery → flag clear, walking 미시작.
    /// 이후 handlePreset / handleTelloStick 가 다시 정상 동작.
    public func handleRecovery(from source: InputSource) {
        guard let session else {
            safetyMessage = "WalkLabSession 미연결"
            return
        }
        // **v1.20.22.1 사이클 28-fix LOW (코덱스)** — 이미 비 emergency 면 silent no-op.
        // 종전: "Emergency 상태 아님 — recovery 불필요" 메시지로 기존 safetyMessage 덮음 →
        // 두 곳 (Panel + HUD) 에서 거의 동시에 recovery 클릭 시 두 번째 호출이 이전 메시지 덮음.
        // 신규: silent no-op (safetyMessage 미변경) → 호출 idempotent.
        guard session.pilotIsEmergency else {
            return
        }
        session.pilotEmergencyExit()
        safetyMessage = nil
        // **v1.20.13.1 사이클 19-fix LOW 1 (코덱스)** — lastIntent clear.
        // 종전: lastIntent 는 emergency 그대로 → HUD sourceChip 가 stale ("긴급" 표시 유지).
        // 신규: nil 로 reset → HUD "대기" 로 복귀, recovery 완료 시각화.
        lastIntent = nil
        session.pilotPostEvent("emergency recovery — preset 입력 활성", source: source)
    }

    /// **v1.20.4 (2026-05-22) 사이클 10** — preset 직접 선택 (number key / future button).
    /// session.start (preflight 포함) 호출 + lastRobotEvent 갱신. `.idle` 은 session.stop.
    /// bridge 비활성 (enabled=false) 시 거부 + safetyMessage.
    public func handlePreset(_ preset: WalkLabPreset, from source: InputSource) {
        guard let session else {
            safetyMessage = "WalkLabSession 미연결 — bridge.session 설정 필요"
            return
        }
        if !enabled {
            safetyMessage = "Bridge 비활성 — preset 단축키 무시 (emergency 만 허용)"
            return
        }
        // **v1.20.4.1 사이클 10-fix CRITICAL (코덱스)** — emergency 상태에서 preset 재시작 차단.
        // 종전: Space (emergency) → 1 (preset) 순서로 입력 시 즉시 재시작 가능 (큰 안전 hole).
        // 신규: emergencyStopActive 동안 사용자 명시 recovery 전까지 preset 무시. emergency 만 통과.
        if session.pilotIsEmergency {
            safetyMessage = "긴급 정지 상태 — preset 단축키 차단 (recovery 필요)"
            return
        }
        if preset == .idle {
            // .idle == 정지. 현재 보행 중일 때만 의미 있음.
            if session.pilotIsWalking {
                session.pilotStop()
                session.pilotPostEvent("정지 (preset .idle)", source: source)
                safetyMessage = nil
            } else {
                safetyMessage = "이미 정지 상태"
            }
            return
        }
        // **v1.20.20 사이클 26 + 28-fix MEDIUM** — 같은 preset 재입력 idempotent (no-op).
        // 종전: alreadyWalking preflight 차단 + "march 진행 중" safety 메시지 — 게임 UX 거슬림.
        // 신규: 동일 preset 재입력 시 silent no-op (사용자 의도: 변경 없음).
        // 단 emergencyStopActive 체크는 위에서 이미 통과한 상태.
        // **사이클 28-fix MEDIUM (코덱스)**: telemetry 도 same-preset 경우 skip (UI 카운터 노이즈 차단).
        //
        // **v1.20.45 facade refactor**: same-preset / success / blocked 판정을 facade
        // (`pilotStart`) 에 위임. bridge 는 결과 enum 만 보고 safetyMessage / telemetry 결정.
        // 종전 3개 property (current / lastPreflightFailure / startBlockedReason) read →
        // 단일 method 호출로 축소.
        switch session.pilotStart(preset: preset) {
        case .sameAsCurrent:
            safetyMessage = nil  // 기존 메시지 clear (clean state).
        case .success:
            // 실 진입 (sim 정보성 noConnection 포함). 성공 처리.
            // **v1.20.17.1 사이클 23-fix MEDIUM 1 + 36-fix MEDIUM 2 (코덱스)** — 성공 path 에서만
            // telemetry. session.start 이 captureTrialStart → accumulator.reset → 재기록.
            // mirror 는 reset 영향 안 받음 — bridge lifetime, 본 path 에서 첫 증가.
            accumulator.recordPresetChange(source: source)
            presetChangeMirror += 1
            session.pilotPostEvent("preset \(preset.rawValue) 시작", source: source)
            safetyMessage = nil
        case .blocked(let userMessage):
            // preflight failure 의 userMessage 또는 startBlockedReason 합성 메시지.
            safetyMessage = userMessage
        }
    }

    // MARK: - Core process

    private func process(_ intent: PilotIntent) {
        lastIntent = intent
        // **v1.20.45 사이클 59** — latency tracker: input received stage.
        // nil (default) 시 record 호출 skip — overhead 0.
        latencyTracker?.record(stage: .inputReceived)
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
        // **v1.20.44 사이클 58 — security-auditor HIGH 1 fix**:
        // emergencyStopActive 동안 move/stop/motion intent 차단. emergency intent 만 통과.
        // 종전: handleMove 의 auto-start path 가 emergency 상태에서도 session.start 호출 → robot 재작동.
        // emergency Space → W → autostart .march 로 robot 깨어남. 큰 안전 hole.
        // 신규: 모든 non-emergency intent 차단 + 사용자에게 recovery 안내.
        if intent.kind != .emergency && session.pilotIsEmergency {
            accumulator.record(intent)
            safetyMessage = "긴급 정지 상태 — recovery 필요 (R 키 또는 Recover 버튼)"
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
        if !session.pilotIsWalking {
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
            if !session.pilotIsWalking {
                accumulator.record(intent)
                safetyMessage = "Auto-start (\(autoStartPreset.rawValue)) 차단 — 안전 검사 미통과"
                return
            }
            // 성공 → 아래 일반 처리로 fall-through.
            // **주의**: session.start 가 captureTrialStart 호출 → bridge.accumulator.reset() 발생.
            // 본 intent 는 새 trial 의 첫 입력 — reset 후 record. session.pilotBridge nil 시 reset
            // 발생 안 함 → 단일 record (이전 record 가 진입 즉시 발화 안 했으므로 OK).
            accumulator.record(intent)
            // **v1.20.29 사이클 35** — auto-start 도 preset transition telemetry (handlePreset 일관성).
            accumulator.recordPresetChange(source: intent.source)
            presetChangeMirror += 1
            // **사이클 9-fix LOW 1 (코덱스)** — lastRobotEvent overwrite 차단 위해 set 제거.
            // 종전: "🎮 ... auto-start" → applyAmplitude 즉시 "🕹 ... stride" 로 덮임 → 사용자 못 봄.
            // 사용자는 session.current 변화 (idle → march) 와 amplitude 메시지로 충분히 인지.
        } else {
            // 일반 (이미 walking 중) path — record.
            accumulator.record(intent)
        }

        // **v1.20.45 사이클 59** — safety 통과 완료 stage 기록.
        latencyTracker?.record(stage: .safetyGated)

        // 정상 처리 — Walking module amplitude 갱신.
        switch intent.kind {
        case .move(let cmd):
            applyAmplitude(cmd, in: session)
            safetyMessage = nil
        case .stop:
            applyAmplitude(.stop, in: session, applyHardZero: true)
            safetyMessage = nil
        case .motion(let id):
            // **v1.20.22 사이클 28** — pilotMotionCatalog 가 id resolve → MotionDescriptor → handleMotion.
            if let descriptor = pilotMotionCatalog.resolve(id) {
                _ = handleMotion(descriptor, from: intent.source)
            } else {
                safetyMessage = "motion '\(id)' — catalog 에 등록 없음 (catalog.knownIds 참조)"
            }
        case .emergency:
            break  // emergency 위에서 처리.
        }
    }

    /// **v1.18.0.2 (사이클 2) + 사이클 44** — MotionDescriptor 기반 motion intent 처리.
    /// PilotIntent.motion(String) 의 외부 caller 가 catalog 에서 descriptor 를 resolve 한 후 호출.
    /// MotionBlender.play 가 TransitionPolicy 통합 검증 → BlendResult 반환.
    /// **사이클 44**: handleMotion(id:) 와 동일 safety gate 적용 — descriptor 직접 호출 시도 차단.
    @discardableResult
    public func handleMotion(_ descriptor: MotionDescriptor, from source: InputSource) -> BlendResult {
        // **사이클 44**: safety gate (handleMotion(id:) 와 일치).
        if !enabled {
            safetyMessage = "Bridge 비활성 — motion 차단"
            return .rejectedSafety(reason: "bridge disabled")
        }
        if let session = session, session.pilotIsEmergency {
            safetyMessage = "긴급 정지 상태 — motion 차단 (recovery 필요)"
            return .rejectedSafety(reason: "emergency active")
        }
        let intent = PilotIntent(kind: .motion(descriptor.id), source: source)
        let result: BlendResult
        if let session = session {
            // **v1.20.45 facade refactor**: SafetyContext 합성을 facade 에 위임.
            // 종전 3개 property (balanceState / store?.bus / riskAcknowledged) read →
            // 단일 method 호출로 축소.
            result = motionBlender.play(descriptor, safetyContext: session.pilotSafetyContext())
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
            session?.pilotPostEvent("motion '\(descriptor.displayLabel)' 적용", source: source)
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
    ///
    /// **v1.20.45 facade refactor**: emergency 가드 / advanced=true 자동 활성 / slider write /
    /// syncCommandToEngine 호출은 `WalkLabSession+Pilot.swift` facade 에 위임. bridge 는
    /// smoothing 합성 + latency marker + lastRobotEvent 메시지만 담당.
    private func applyAmplitude(_ cmd: WalkingCommand, in session: WalkLabSession,
                                 applyHardZero: Bool = false) {
        // EMA blend — bridge 의 smoothing 책임. facade 에서 emergency 차단 시 false 반환.
        let final: WalkingCommand
        if applyHardZero {
            // **사이클 20-fix HIGH 1 (코덱스)** — .stop path 의 hard-zero.
            final = cmd
        } else {
            let α = max(0, min(1, smoothingFactor))  // clamp 0..1 (safety)
            let prev = session.pilotCurrentAmplitude
            final = WalkingCommand(
                strideMm: α * cmd.strideMm + (1 - α) * prev.strideMm,
                sideMm:   α * cmd.sideMm   + (1 - α) * prev.sideMm,
                turnDeg:  α * cmd.turnDeg  + (1 - α) * prev.turnDeg
            )
        }
        // facade — emergency 가드 / advanced 자동 활성 / slider write.
        // false 반환 시 emergency 상태 — engine sync / 메시지 모두 skip.
        guard session.pilotApplyAmplitude(final) else {
            return
        }
        // **v1.20.45 사이클 59** — slider mutation 완료. engine sync 직전.
        latencyTracker?.record(stage: .amplitudeApplied)
        session.pilotSyncEngine()
        // **v1.20.45 사이클 59** — engine sync 직후 — 사용자 체감 응답 끝점.
        // 실 motor 시간은 hw — 본 layer 까지만 측정.
        latencyTracker?.record(stage: .engineSynced)
        // 사용자 안내 — 어떤 source 가 명령했는지.
        if let source = lastIntent?.source {
            let now = session.pilotCurrentAmplitude
            session.pilotPostEvent("stride=\(Int(now.strideMm)) side=\(Int(now.sideMm)) turn=\(Int(now.turnDeg))", source: source)
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

    /// **v1.20.33 사이클 41** — 가장 최근 intent 의 timestamp. UI age 표시 용.
    public var lastInputAt: Date? {
        lastIntent?.timestamp
    }

    /// **v1.20.33 사이클 41** — 가장 최근 입력 이후 경과 시간 (초). nil = 입력 없음.
    public var lastInputAge: TimeInterval? {
        guard let t = lastInputAt else { return nil }
        return Date().timeIntervalSince(t)
    }

    /// **v1.20.37 사이클 48** — 입력이 최근 (< 2초) 인지 — HUD freshness 표시.
    public var isInputFresh: Bool {
        guard let age = lastInputAge else { return false }
        return age < 2.0
    }
}
