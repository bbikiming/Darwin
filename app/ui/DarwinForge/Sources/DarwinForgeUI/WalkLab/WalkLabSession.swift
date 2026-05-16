import Combine
import ForgeCore
import SwiftUI

/// Walk Lab 의 ObservableObject — 현재 프리셋 / 고급 슬라이더 / 시뮬 결과 / 안전 상태.
///
/// 시뮬 vs 실 송출 (Sprint 16+):
///   - **프리셋 보행 cycle 실 송출 활성**: `WalkMotionLibrary.page(for:tuning:)` 로 합성한
///     step 시퀀스를 `runWalkCycle` Task 가 `Bus.setPosition` 으로 직접 송출.
///     bus 연결 + cradleConfirmed + (highRisk → riskAck) 조건 모두 만족 시.
///   - 고급 슬라이더 (보폭/측면/회전/주기/발 들기/균형) → 시뮬 엔진과 실 송출 page 모두에 반영.
///     ROBOTIS walking module 기반 keyframe을 재합성하고, 진행 중이면 짧게 debounce 후 재시작.
///   - 시뮬 50ms tick (foot trail / IMU / 온도) 는 기존대로 simTimer 가 갱신.
///   - `attach(store:)` 호출 전이면 송출 skip (테스트 / preview / 연결 전).
///   - emergencyStop / 균형 손실 / 온도 임계 시 walkCycleTask 즉시 cancel + walkReady 복귀.
@MainActor
public final class WalkLabSession: ObservableObject {
    // MARK: - 사용자 입력
    @Published public var current: WalkLabPreset = .idle
    @Published public var cradleConfirmed: Bool = false
    @Published public var advanced: Bool = false
    /// 보폭 (앞, mm/cycle). 0..50. WalkEngine 의 x (m) 와 매핑: x_m = strideMm / 1000.
    @Published public var strideMm: Double = 0
    /// 측면 보폭 (mm/cycle). -25..25. y_m = sideMm / 1000.
    @Published public var sideMm: Double = 0
    /// 회전 (°/cycle). -20..20. a_rad = turnDeg * π/180.
    @Published public var turnDeg: Double = 0
    @Published public var customPeriodMs: Double = 600
    /// 발 들기 높이 (mm). sim 영향 — 엔진 미반영 (BLOCKER C3 까지).
    @Published public var footHeightMm: Double = 40
    /// 균형 게인 (NimbRo lean_fb_gain 등가). sim 영향 — 엔진 미반영.
    @Published public var balanceGain: Double = 1.0
    /// 사용자 명시적 안전 한도 해제. Smart-clamp 무시, 단 critical 점수는 여전히 차단.
    @Published public var forceOverrideSafety: Bool = false
    @Published public var riskAcknowledged: Bool = false

    // MARK: - 레거시 호환 (기존 코드 경로 보존)
    /// `customX`/`customY`/`customA` 는 strideMm/sideMm/turnDeg 의 m 단위 view.
    /// 외부 코드(Walk.swift FFI 등) 는 m 단위를 기대하므로 변환.
    public var customX: Double {
        get { strideMm / 1000.0 }
        set { strideMm = newValue * 1000.0 }
    }
    public var customY: Double {
        get { sideMm / 1000.0 }
        set { sideMm = newValue * 1000.0 }
    }
    public var customA: Double {
        get { turnDeg * .pi / 180.0 }
        set { turnDeg = newValue * 180.0 / .pi }
    }

    // MARK: - 시뮬 / 실시간 상태
    @Published public var elapsedMs: UInt32 = 0
    @Published public var phaseLabel: String = "PHASE0"
    @Published public var leftFoot: SIMD3<Double> = .zero
    @Published public var rightFoot: SIMD3<Double> = .zero
    @Published public var footTrail: [FootTrailPoint] = []
    @Published public var imuRollDeg: Double = 0
    @Published public var imuPitchDeg: Double = 0
    /// **Stage 1 (v1.1 fall prevention)**: IMU 출처 표시 — UI 가 sim/real/stale 구분.
    @Published public private(set) var imuSource: ImuSource = .sim
    @Published public var maxMotorTemp: Double = 35.0
    @Published public var balanceLost: Bool = false
    @Published public var thermalAlarm: Bool = false

    /// IMU 데이터 출처 — Stage 1 wire-up 이후 도입.
    public enum ImuSource: Equatable, Sendable {
        /// 실 robot 미연결 또는 테스트 — `updateSimIMU` 모델 값.
        case sim
        /// 실 robot 연결 + `ConnectionStore.imuFilter` 5Hz polling 값.
        case real
        /// 실 robot 연결 됐으나 IMU 갱신 5초+ 지연 — 마지막 값 hold.
        case stale

        public var label: String {
            switch self {
            case .sim:   return "시뮬"
            case .real:  return "실 IMU"
            case .stale: return "IMU 지연"
            }
        }
    }

    // MARK: - Stage 2 (v1.1 fall prevention): 다단계 안전 임계

    /// 현재 IMU 기반 안전 상태. tick() 마다 갱신.
    @Published public private(set) var balanceState: BalanceState = .normal
    /// 자동 fall prevention 토글. false 면 emergency (30°) 만 작동. default true.
    @Published public var autoFallPrevention: Bool = true

    // MARK: - Stage 3 (v1.1 fall prevention): 예측 fall detection

    /// 최근 IMU sample ring buffer (최대 1초 / 5 sample).
    private var imuBuffer: [FallPredictor.Sample] = []
    /// 마지막 buffer push 시각 — 5Hz polling 동기화.
    private var lastBufferPushAt: Date?

    /// 예측 결과 — UI 게이지·countdown 용.
    @Published public private(set) var fallPrediction: FallPredictor.Prediction = .zero

    // MARK: - Stage 4 (v1.1 fall prevention): 실 balance feedback

    /// Walking.cpp::sensoryFeedback 패턴 — IMU error → 4 관절 그룹 delta.
    /// `enableBalanceCorrection = true` 시 보행 cycle pose 에 적용. **default OFF**
    /// (실 robot 검증 + Codex audit 완료 후 user 가 명시 ON).
    @Published public var enableBalanceCorrection: Bool = false
    /// 보정 활성 시 0~1초 ramp 시작 시점. nil 이면 ramp 미시작.
    private var correctionEnabledAt: Date?
    /// 최근 산정 보정 delta (UI 표시·디버그 용).
    @Published public private(set) var lastCorrections: BalanceCorrector.Corrections?
    /// Corrector 인스턴스 — `WalkParams.default()` gain 정합.
    public let balanceCorrector: BalanceCorrector = .robotisDefault

    /// 안전 상태 — `|max(|roll|, |pitch|)|` 기준 5단계.
    ///
    /// **임계** (deg):
    /// | 상태 | 임계 | 동작 |
    /// |---|---|---|
    /// | `.normal` | < 15° | 정상 |
    /// | `.caution` | 15-22° | UI 경고만 |
    /// | `.warning` | 22-28° | 보행 속도 70% 자동 감속 |
    /// | `.danger` | 28-30° | 자세 동결 (cycle 일시 정지) |
    /// | `.emergency` | ≥ 30° | 토크 OFF + walkReady 복귀 (기존 L3) |
    public enum BalanceState: Int, Comparable, Equatable, Sendable {
        case normal = 0, caution, warning, danger, emergency

        public static func < (l: BalanceState, r: BalanceState) -> Bool {
            l.rawValue < r.rawValue
        }

        /// IMU |max| 각도로부터 상태 결정.
        public static func from(maxTilt: Double) -> BalanceState {
            if maxTilt >= 30 { return .emergency }
            if maxTilt >= 28 { return .danger }
            if maxTilt >= 22 { return .warning }
            if maxTilt >= 15 { return .caution }
            return .normal
        }

        public var label: String {
            switch self {
            case .normal:    return "정상"
            case .caution:   return "주의"
            case .warning:   return "경고"
            case .danger:    return "위험"
            case .emergency: return "비상"
            }
        }

        /// 보행 속도 배수 (Stage 2 자동 감속).
        public var speedScale: Double {
            switch self {
            case .normal, .caution: return 1.0
            case .warning:          return 0.7  // 70% 감속
            case .danger:           return 0.0  // 자세 동결
            case .emergency:        return 0.0  // 정지
            }
        }
    }
    /// **Phase G11 (2026-05-15)**: 3D 모델 시각화용 현재 자세.
    ///
    /// 보행 중 매 step 갱신 (`runContinuousWalk` / `runWalkCycle` 에서 송출 직전 publish).
    /// sim mode (실 로봇 미연결) 도 50ms tick 마다 phase pose 합성해서 갱신 →
    /// `WalkLabView` 의 `RobotScene3D(pose: session.visualPose)` 가 받아서 모델 동작.
    @Published public var visualPose: RobotPose = .walkReady

    // MARK: - 세션 기록
    @Published public var history: [WalkLabRecord] = []

    // MARK: - 실 로봇 연결 (optional)
    /// 환경에서 주입되는 연결 store. nil 이면 sim only.
    private weak var store: ConnectionStore?
    /// 마지막 송출 상태 — UI 토스트용.
    @Published public private(set) var lastRobotEvent: String?
    /// 실 보행 cycle 진행 중인지 — UI badge / 토글 disable 용.
    @Published public private(set) var isRobotWalking: Bool = false

    /// Codex P0 fix (2026-05-13 3차): preflight 결과 + cycle 종료 후 결과 집계.
    /// 이전 v1.0 은 모든 write 를 `_ = try?` 로 silently swallow → "정상 종료" 처럼 보였음.
    @Published public private(set) var lastCycleResult: WalkCycleResult?
    @Published public private(set) var lastPreflightFailure: WalkPreflightFailure?

    /// 보행 cycle 의 진행 결과 — runWalkCycle 가 반환.
    public struct WalkCycleResult: Equatable, Sendable {
        public enum EndReason: Equatable, Sendable {
            case completedMaxDuration
            case userCancelled
            case lowerBodyWriteFailure
            case bulkWriteFailure
        }
        public let reason: EndReason
        public let stepsExecuted: Int
        public let speedWriteFailures: Int
        public let positionWriteFailures: Int
        public let lowerBodyPositionFails: [JointID]
        public let sampleError: String?

        public var userMessage: String {
            switch reason {
            case .completedMaxDuration:
                return "보행 종료 — 시간 도달 (\(stepsExecuted) step)"
            case .userCancelled:
                return "보행 취소 — 사용자/정지 신호 (\(stepsExecuted) step)"
            case .lowerBodyWriteFailure:
                let names = lowerBodyPositionFails.prefix(3).map { $0.name }.joined(separator: ", ")
                let suffix = sampleError.map { " · 예: \($0)" } ?? ""
                return "보행 중단 — 하체 위치쓰기 \(lowerBodyPositionFails.count)개 실패 (\(names)). 균형 위험\(suffix)"
            case .bulkWriteFailure:
                let suffix = sampleError.map { " · 예: \($0)" } ?? ""
                return "보행 중단 — 통신 절반 이상 실패 (위치 \(positionWriteFailures)·속도 \(speedWriteFailures))\(suffix)"
            }
        }

        public var isSuccess: Bool {
            switch reason {
            case .completedMaxDuration, .userCancelled: return true
            case .lowerBodyWriteFailure, .bulkWriteFailure: return false
            }
        }
    }

    /// 보행 cycle 시작 전 preflight 실패 사유.
    public struct WalkPreflightFailure: Equatable, Sendable {
        public enum Cause: Equatable, Sendable {
            case noConnection
            case cradleNotConfirmed
            case dxlPowerFailed(String)
            case lowerBodyTorqueFailed([JointID])
            case bulkTorqueFailed(failedCount: Int, total: Int)
        }
        public let cause: Cause
        public var userMessage: String {
            switch cause {
            case .noConnection:
                return "ℹ️ 시뮬 모드 — 로봇 미연결 (보행 cycle 미실행)"
            case .cradleNotConfirmed:
                return "⚠️ cradle 미확인 — 정비 스탠드 거치 후 다시 시도"
            case .dxlPowerFailed(let e):
                return "🛑 Dynamixel 전원 ON 실패 — \(e)"
            case .lowerBodyTorqueFailed(let joints):
                let names = joints.prefix(3).map { $0.name }.joined(separator: ", ")
                return "🛑 보행 시작 차단 — 하체 토크 \(joints.count)개 실패 (\(names)). USB·전원·ID 확인"
            case .bulkTorqueFailed(let f, let t):
                return "🛑 보행 시작 차단 — 상체 토크 \(f)/\(t) 실패. 통신 점검"
            }
        }
    }

    /// 하체 (균형 critical) 관절 — bodyPart 기반으로 매번 계산.
    private static var lowerBodyJoints: Set<JointID> {
        Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
    }

    /// SwiftUI 한계 우회 — `.onAppear` 에서 env 가 도착하면 호출.
    public func attach(store: ConnectionStore) {
        self.store = store
    }

    // MARK: - 내부
    private let engine: WalkEngine
    private var simTimer: Timer?
    private var startTime: Date?
    /// Sim IMU 본체 흔들림 위상 (rad). tick 마다 ω·dt 누적.
    private var simSwayPhase: Double = 0
    /// 실 보행 cycle Task — start(preset) 시 시작, stop / emergency 시 cancel.
    private var walkCycleTask: Task<Void, Never>?
    /// 고급 슬라이더 연속 drag 중 실 보행 page 재합성을 debounce.
    private var walkTuningRestartTask: Task<Void, Never>?

    /// Sim 한 tick 의 dt (s). 50 ms.
    private let tickDtSec: Double = 0.05
    /// 모터 발열율 — 워킹 중 (°C/s). 약 6°C/min, 무거운 부하 가정.
    private let motorHeatRate: Double = 0.10
    /// 모터 자연 냉각율 — idle 중 (°C/s).
    private let motorCoolRate: Double = 0.04
    /// 모터 정상 평형 온도 (idle).
    private let motorAmbientTemp: Double = 35.0

    public init() {
        self.engine = WalkEngine()
    }

    /// 현재 효과적인 command — advanced 모드면 custom, 아니면 preset.
    public var effectiveCommand: (x: Double, y: Double, a: Double, enabled: Bool) {
        if advanced {
            return (customX, customY, customA, current != .idle)
        }
        return current.command
    }

    /// 현재 효과적인 주기 (ms) — advanced 면 customPeriodMs, 아니면 preset.
    public var effectivePeriodMs: Double {
        if advanced {
            return customPeriodMs
        }
        return Double(current.periodMs)
    }

    /// 현재 슬라이더 조합의 낙상 위험 점수 (사이드바 게이지 + start gate 공유).
    /// advanced 모드일 때만 의미. 그 외는 preset 의 안전 분류가 우선.
    public var stabilityScore: WalkStabilityResult {
        WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: strideMm,
            sideMm: sideMm,
            turnDeg: turnDeg,
            periodMs: customPeriodMs,
            footHeightMm: footHeightMm,
            balanceGain: balanceGain
        ))
    }

    /// 시작 가능한가? advanced 모드의 critical 점수는 차단. preset 모드는 risk confirm 흐름.
    public var canStart: Bool {
        guard cradleConfirmed else { return false }
        if advanced {
            return stabilityScore.category != .critical
        }
        return true
    }

    /// 프리셋 시작 — 시뮬 50 ms tick + 실 로봇 정적 자세 송출 (bus 연결 시).
    public func start(_ preset: WalkLabPreset) {
        guard cradleConfirmed else { return }
        if preset.requiresRiskConfirmation, !riskAcknowledged { return }
        // advanced 모드에서 critical 조합이면 시작 차단 — 사용자가 슬라이더로 직접 위험 조합을
        // 만든 경우 (preset 의 risk confirm 과는 별개).
        if advanced && stabilityScore.category == .critical { return }

        current = preset
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)
        footTrail.removeAll()
        simSwayPhase = 0
        balanceLost = false
        thermalAlarm = false
        // **Stage 3 (v1.1 fall prevention)**: 새 보행 시작 시 buffer reset —
        // 이전 cycle 의 stale sample 로 score 거짓 발동 방지.
        imuBuffer.removeAll()
        lastBufferPushAt = nil
        fallPrediction = .zero
        balanceState = .normal
        // **Stage 4 (v1.1 fall prevention)**: corrector ramp 재시작.
        correctionEnabledAt = enableBalanceCorrection ? Date() : nil
        lastCorrections = nil
        startTime = Date()

        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: tickDtSec, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        // 실 보행 cycle 송출 — bus 연결 + cradle 확인 시 WalkMotionLibrary 의
        // 합성 step 시퀀스를 직접 모터에 전송. preset 종료 / cancel 시 walkReady 복귀.
        startWalkCycle(preset)
    }

    /// 진행 중 sim 에 현재 슬라이더/프리셋 값을 재밀어넣는다.
    /// advanced 슬라이더가 움직였을 때 view 측에서 호출.
    public func syncCommandToEngine() {
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)

        guard advanced, isRobotWalking, current != .idle else { return }
        guard stabilityScore.category != .critical else {
            cancelWalkCycle(eventLabel: "고급 슬라이더 위험도 critical — 보행 중단")
            return
        }

        let preset = current
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.advanced,
                  self.isRobotWalking,
                  self.current == preset else { return }
            self.startWalkCycle(preset)
            self.lastRobotEvent = "🤖 고급 슬라이더 반영 — \(preset.label)"
        }
    }

    /// 정지 — 시뮬 멈춤, 기록 누적, 실 보행 cycle cancel + walkReady 복귀.
    public func stop() {
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        let wasRunning = startTime != nil
        if let start = startTime {
            history.insert(WalkLabRecord(
                preset: current,
                durationSec: Int(Date().timeIntervalSince(start)),
                endedAt: Date()
            ), at: 0)
            if history.count > 12 { history.removeLast() }
        }
        startTime = nil
        current = .idle
        // sway 도 zero 로 디케이 — 다음 tick 에서 매끄럽게 감소.

        // 실 보행 cycle cancel — Task 내부에서 walkReady 복귀 후 종료.
        if wasRunning {
            cancelWalkCycle(eventLabel: "정지 — 직립 자세 복귀")
        }
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
    }

    /// 비상 정지 — Stop + risk reset + 실 로봇 토크 OFF.
    public func emergencyStop() {
        // 1. 보행 cycle 즉시 cancel — 모터 송출 중지.
        walkCycleTask?.cancel()
        walkCycleTask = nil
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
        isRobotWalking = false
        // 2. 토크 OFF — 토크 OFF 가 들어가야 임의 모터 명령 잔여를 무력화.
        store?.emergencyStop()
        // 3. 시뮬 정지.
        simTimer?.invalidate()
        simTimer = nil
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        startTime = nil
        current = .idle
        riskAcknowledged = false
        balanceLost = false
        lastRobotEvent = "🛑 토크 OFF — 비상 정지"
        // 온도는 그대로 — 사용자가 확인 후 자연 냉각.
    }

    /// 실 로봇에 정적 자세 송출. bus 미연결 / cradle 미확인 / cancelled 시 skip.
    /// 단발 자세 송출. 반복 보행은 `startWalkCycle` 경로가 담당.
    private func sendRobotPose(_ pose: RobotPose, eventLabel: String) {
        guard let store = store, store.bus != nil else {
            lastRobotEvent = "ℹ️ 시뮬 모드 — 로봇 미연결 (\(eventLabel))"
            return
        }
        guard cradleConfirmed else {
            lastRobotEvent = "⚠️ cradle 미확인 — 실 송출 차단"
            return
        }
        lastRobotEvent = "🤖 \(eventLabel)"
        Task { @MainActor in
            await store.applyPoseSmoothly(pose)
        }
    }

    // MARK: - 실 보행 cycle 송출 (Sprint 16+)

    /// `WalkMotionLibrary` 의 합성 step 시퀀스를 모터에 직접 송출 시작.
    ///
    /// **Codex P0 fix (2026-05-13 3차)**:
    /// - cycle 시작 전 preflight (bus / cradle / dxl_power / 하체 토크) 강제 확인.
    /// - 하체 토크 1개라도 실패면 cycle 차단 (silent failure 방지).
    /// - runWalkCycle 가 `WalkCycleResult` 반환 — cycle 종료 사유 사용자에게 표시.
    ///
    /// 이전 task 가 있으면 cancel + 완료 대기 후 새 cycle 시작 — preset 전환 race 방지.
    private func startWalkCycle(_ preset: WalkLabPreset) {
        guard let store = store, let bus = store.bus else {
            let f = WalkPreflightFailure(cause: .noConnection)
            lastPreflightFailure = f
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            return
        }
        guard cradleConfirmed else {
            let f = WalkPreflightFailure(cause: .cradleNotConfirmed)
            lastPreflightFailure = f
            lastRobotEvent = f.userMessage + " (\(preset.label))"
            return
        }

        // Preflight — dxl_power ON + 모든 토크 ON. 하체 1개라도 실패면 차단.
        if let failure = preflightForWalkCycle(bus: bus) {
            lastPreflightFailure = failure
            lastRobotEvent = failure.userMessage + " (\(preset.label))"
            return
        }
        lastPreflightFailure = nil

        // **Phase G10 (2026-05-15)**: 보행 모드 분기.
        //   - 연속 보행 가능 preset (march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight)
        //     → continuousWalkPlan + runContinuousWalk (entry → 무한 cycle → exit).
        //     매 cycle 끝마다 walkReady 자세로 돌아가지 않음 → 자연스러운 보행.
        //   - jog → page(for:tuning:) + runWalkCycle(loop=false) (기존 동작 — kick chain).
        //   - idle → 정적 walkReady.
        let prev = walkCycleTask
        prev?.cancel()
        let presetLabel = preset.label
        let maxDurationSec = preset.maxDurationSec
        let lowerBody = Self.lowerBodyJoints

        if preset == .idle {
            sendRobotPose(.walkReady, eventLabel: "보행 anchor — \(presetLabel)")
            return
        }

        // Phase G11 — 3D 모델 동기화 closure. weak self 로 retain cycle 회피.
        let onPose: @MainActor @Sendable (RobotPose) -> Void = { [weak self] pose in
            self?.visualPose = pose
        }

        // 연속 보행 plan 시도.
        if let plan = WalkMotionLibrary.continuousWalkPlan(for: preset, tuning: currentWalkTuning()) {
            isRobotWalking = true
            lastRobotEvent = "🤖 연속 보행 시작 — \(presetLabel)"
            walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
                await prev?.value
                let result = await Self.runContinuousWalk(
                    bus: bus, plan: plan,
                    maxDurationSec: maxDurationSec,
                    lowerBodyJoints: lowerBody,
                    onPose: onPose
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isRobotWalking = false
                    self.lastCycleResult = result
                    if result.isSuccess {
                        self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                    } else {
                        self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                    }
                }
            }
            return
        }

        // jog (kick chain) — 단발 page + oneShot.
        guard let page = WalkMotionLibrary.page(for: preset, tuning: currentWalkTuning()) else {
            sendRobotPose(.walkReady, eventLabel: "보행 anchor — \(presetLabel)")
            return
        }
        isRobotWalking = true
        lastRobotEvent = "🤖 보행 cycle 송출 시작 — \(presetLabel)"
        walkCycleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await prev?.value
            let result = await Self.runWalkCycle(
                bus: bus, page: page,
                maxDurationSec: maxDurationSec,
                lowerBodyJoints: lowerBody,
                loop: false,   // jog 는 kick chain 끝나면 종료.
                onPose: onPose
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRobotWalking = false
                self.lastCycleResult = result
                if result.isSuccess {
                    self.lastRobotEvent = "✅ \(result.userMessage) — walkReady 복귀 (\(presetLabel))"
                } else {
                    self.lastRobotEvent = "🛑 \(result.userMessage) (\(presetLabel))"
                }
            }
        }
    }

    private func currentWalkTuning() -> WalkMotionLibrary.AdvancedTuning? {
        guard advanced else { return nil }
        return WalkMotionLibrary.AdvancedTuning(
            strideMm: strideMm,
            sideMm: sideMm,
            turnDeg: turnDeg,
            periodMs: customPeriodMs,
            footHeightMm: footHeightMm,
            balanceGain: balanceGain
        )
    }

    /// Preflight: dxl_power ON + 모든 토크 ON. 하체 실패 / 상체 4개+ 실패 시 차단.
    /// Codex P0 권고: WalkLab cycle 이 torque OFF 상태에서 시작해도 silent 했던 버그 차단.
    private func preflightForWalkCycle(bus: Bus) -> WalkPreflightFailure? {
        // 1. dxl_power ON.
        do { try bus.setDxlPower(true) }
        catch { return WalkPreflightFailure(cause: .dxlPowerFailed(error.localizedDescription)) }

        // 2. 모든 관절 토크 ON. 실패 카운트.
        var failedJoints: [JointID] = []
        for j in JointID.allCases {
            do { try bus.setTorque(j, enable: true) }
            catch { failedJoints.append(j) }
        }
        let lowerBodyFails = failedJoints.filter { Self.lowerBodyJoints.contains($0) }
        if !lowerBodyFails.isEmpty {
            return WalkPreflightFailure(cause: .lowerBodyTorqueFailed(lowerBodyFails))
        }
        if failedJoints.count > 3 {
            return WalkPreflightFailure(cause: .bulkTorqueFailed(
                failedCount: failedJoints.count,
                total: JointID.allCases.count
            ))
        }
        return nil
    }

    /// 보행 cycle cancel + walkReady 안전 복귀. stop / emergency / preset 전환 시 호출.
    /// task 가 자체적으로 walkReady 복귀를 수행하지만, cancel 응답 지연을 보장하기 위해
    /// `sendRobotPose` 로 명시 송출 (applyPoseSmoothly 의 검증된 분할/부하 watchdog 경로).
    private func cancelWalkCycle(eventLabel: String) {
        guard let task = walkCycleTask else { return }
        task.cancel()
        walkCycleTask = nil
        walkTuningRestartTask?.cancel()
        walkTuningRestartTask = nil
        isRobotWalking = false
        sendRobotPose(.walkReady, eventLabel: eventLabel)
    }

    /// **Phase G10 (2026-05-15)** — 연속 보행 실제 송출 루프.
    ///
    /// 한 cycle 끝마다 walkReady 자세로 돌아가지 않고 phase[5] → phase[0] 으로 직접
    /// 이어붙임. 사용자 체감: 끊김 없는 자연스러운 보행.
    ///
    /// 흐름:
    ///   1. moving speed 설정 (1회).
    ///   2. **entry** step 송출 (walkReady → phase[0] 전환, longer playMs).
    ///   3. **cycle** step 무한 반복:
    ///      - 6 phase 송출 (anchor 없음)
    ///      - phase[5] 끝나면 다음 iter 의 phase[0] 으로 자연 wrap
    ///        (모터 trapezoidal motion 이 playMs 안에서 보간)
    ///      - cancel / maxDuration / 하체 통신 실패 시 break.
    ///   4. **exit** step — walkReady 안전 복귀.
    private static func runContinuousWalk(
        bus: Bus, plan: WalkMotionLibrary.ContinuousWalkPlan, maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0

        // 1. moving speed 설정 (1회).
        let cycleSpeed: UInt16 = 256
        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: cycleSpeed) }
            catch {
                speedFailures += 1
                sampleError = "\(joint.name) 속도쓰기: \(error.localizedDescription)"
            }
        }

        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        // 한 step 송출 helper — closure 캡처 X (concurrency 안전).
        func sendStep(_ step: MotionStep, previousIn: RobotPose) async -> RobotPose {
            let target = step.toPose()
            // **Phase G11**: 3D 모델 갱신 — main actor 로 publish (실 로봇 송출 전에).
            if let onPose {
                await onPose(target)
            }
            let changed = target.changedJoints(from: previousIn)
            for joint in changed {
                let rawVal = UInt16(clamping: target.raw(joint))
                do { _ = try bus.setPosition(joint, raw: rawVal) }
                catch {
                    positionFailures += 1
                    sampleError = "\(joint.name) 위치쓰기: \(error.localizedDescription)"
                    if lowerBodyJoints.contains(joint) {
                        lowerBodyPositionFails.insert(joint)
                    }
                }
            }
            let totalMs = max(80, step.playMs + step.pauseMs)
            let ns = UInt64(totalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            return target
        }

        // 2. Entry — walkReady → phase[0] (1회만).
        entryLoop: for step in plan.entry {
            if Task.isCancelled { cancelledMidStep = true; break entryLoop }
            previous = await sendStep(step, previousIn: previous)
            stepsExecuted += 1
            if !lowerBodyPositionFails.isEmpty {
                endReason = .lowerBodyWriteFailure
                break entryLoop
            }
        }

        // 3. Cycle — 6 phase 무한 반복 (anchor 없음 → 매 cycle 끝마다 phase[5] → phase[0] wrap).
        if endReason == .completedMaxDuration && !cancelledMidStep && lowerBodyPositionFails.isEmpty {
            cycleLoop: while !Task.isCancelled {
                if let end = endDate, Date() >= end { break cycleLoop }
                for step in plan.cycle {
                    if Task.isCancelled { cancelledMidStep = true; break cycleLoop }
                    if let end = endDate, Date() >= end { break cycleLoop }
                    previous = await sendStep(step, previousIn: previous)
                    stepsExecuted += 1

                    if !lowerBodyPositionFails.isEmpty {
                        endReason = .lowerBodyWriteFailure
                        break cycleLoop
                    }
                    if positionFailures > max(3, JointID.allCases.count / 2) {
                        endReason = .bulkWriteFailure
                        break cycleLoop
                    }
                }
            }
        }
        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        // 4. Exit — walkReady 안전 복귀. cancel 후에도 토크 OFF 보다는 복귀가 안전 (낙상 risk).
        for step in plan.exit {
            let target = step.toPose()
            // Phase G11 — 3D 모델 갱신.
            if let onPose {
                await onPose(target)
            }
            let changedFinal = target.changedJoints(from: previous)
            for joint in changedFinal {
                let rawVal = UInt16(clamping: target.raw(joint))
                do { _ = try bus.setPosition(joint, raw: rawVal) }
                catch {
                    positionFailures += 1
                    sampleError = "\(joint.name) 복귀쓰기: \(error.localizedDescription)"
                }
            }
            // Exit 의 playMs 동안 모터가 walkReady 도달하도록 대기.
            let totalMs = max(80, step.playMs + step.pauseMs)
            let ns = UInt64(totalMs) * 1_000_000
            try? await Task.sleep(nanoseconds: ns)
            previous = target
        }

        return WalkCycleResult(
            reason: endReason,
            stepsExecuted: stepsExecuted,
            speedWriteFailures: speedFailures,
            positionWriteFailures: positionFailures,
            lowerBodyPositionFails: Array(lowerBodyPositionFails),
            sampleError: sampleError
        )
    }

    /// 보행 cycle 실제 송출 루프 — `Task.detached` 내부 실행.
    ///
    /// **Codex P0 fix (2026-05-13 3차)**:
    /// - 모든 `try?` 제거 — speed/position write 실패 카운트 + 마지막 에러 sample.
    /// - 하체 position write 실패 1개 이상 → 즉시 cycle 중단 (균형 위험).
    /// - 결과를 `WalkCycleResult` 로 반환 — 호출자가 사용자에게 surface.
    ///
    /// 설계:
    /// - moving speed 1회만 설정 (매 step 호출 안 함 — 패킷 절약).
    /// - 변경된 관절만 setPosition — `RobotPose.changedJoints(from:)` 사용.
    /// - playMs + pauseMs 동안 모터의 trapezoidal motion 자체 보간을 신뢰 → 그 후 다음 step.
    /// - Task.detached 이므로 main thread block 없음.
    private static func runWalkCycle(
        bus: Bus, page: MotionPage, maxDurationSec: Int,
        lowerBodyJoints: Set<JointID>,
        loop: Bool = true,
        onPose: (@MainActor @Sendable (RobotPose) -> Void)? = nil
    ) async -> WalkCycleResult {
        var speedFailures = 0
        var positionFailures = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var sampleError: String? = nil
        var stepsExecuted = 0

        // 1. cycle 시작 — moving speed 1회 설정. RoboPlus 기본 32 ≈ 60 rpm 의 4배 — 빠른 보행 대응.
        let cycleSpeed: UInt16 = 256
        for joint in JointID.allCases {
            do { try bus.setMovingSpeed(joint, speed: cycleSpeed) }
            catch {
                speedFailures += 1
                sampleError = "\(joint.name) 속도쓰기: \(error.localizedDescription)"
            }
        }

        // 2. step loop. walkReady 가 항상 prev — 변경된 관절만 차분 송출.
        var previous: RobotPose = .walkReady
        let endDate: Date? = maxDurationSec > 0
            ? Date().addingTimeInterval(TimeInterval(maxDurationSec))
            : nil
        var endReason: WalkCycleResult.EndReason = .completedMaxDuration
        var cancelledMidStep = false

        cycleLoop: repeat {
            for step in page.steps {
                if Task.isCancelled { cancelledMidStep = true; break cycleLoop }
                if let end = endDate, Date() >= end { break cycleLoop }

                let target = step.toPose()
                // Phase G11 — 3D 모델 갱신.
                if let onPose {
                    await onPose(target)
                }
                let changed = target.changedJoints(from: previous)
                for joint in changed {
                    let rawVal = UInt16(clamping: target.raw(joint))
                    do { _ = try bus.setPosition(joint, raw: rawVal) }
                    catch {
                        positionFailures += 1
                        sampleError = "\(joint.name) 위치쓰기: \(error.localizedDescription)"
                        if lowerBodyJoints.contains(joint) {
                            lowerBodyPositionFails.insert(joint)
                        }
                    }
                }
                previous = target
                stepsExecuted += 1

                // 하체 position write 실패 1개 이상 → 즉시 중단 (균형 위험).
                if !lowerBodyPositionFails.isEmpty {
                    endReason = .lowerBodyWriteFailure
                    break cycleLoop
                }
                // 통신 죽음 — 한 step 안에 절반 이상 실패면 cycle 중단.
                if positionFailures > max(3, JointID.allCases.count / 2) {
                    endReason = .bulkWriteFailure
                    break cycleLoop
                }

                let totalMs = max(80, step.playMs + step.pauseMs)
                let ns = UInt64(totalMs) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        } while loop && !Task.isCancelled
        if endReason == .completedMaxDuration && (cancelledMidStep || Task.isCancelled) {
            endReason = .userCancelled
        }

        // 3. 종료 정리 — walkReady 안전 복귀. 하체 실패 후에도 토크 OFF 보다는
        // walkReady 시도가 안전 (낙상 risk 가 더 큼). 실패해도 결과에 반영.
        let walkReady = RobotPose.walkReady
        // Phase G11 — 3D 모델 walkReady 복귀 시각화.
        if let onPose {
            await onPose(walkReady)
        }
        let changedFinal = walkReady.changedJoints(from: previous)
        for joint in changedFinal {
            let rawVal = UInt16(clamping: walkReady.raw(joint))
            do { _ = try bus.setPosition(joint, raw: rawVal) }
            catch {
                positionFailures += 1
                sampleError = "\(joint.name) 복귀쓰기: \(error.localizedDescription)"
            }
        }

        return WalkCycleResult(
            reason: endReason,
            stepsExecuted: stepsExecuted,
            speedWriteFailures: speedFailures,
            positionWriteFailures: positionFailures,
            lowerBodyPositionFails: Array(lowerBodyPositionFails),
            sampleError: sampleError
        )
    }

    private func tick() {
        let foot = engine.tick(dtMs: 50)
        leftFoot = foot.leftXYZ
        rightFoot = foot.rightXYZ
        elapsedMs = UInt32(foot.elapsedMs)
        phaseLabel = foot.phase.label

        // foot trail 누적
        footTrail.append(FootTrailPoint(
            t: Date(),
            left: foot.leftXYZ,
            right: foot.rightXYZ
        ))
        if footTrail.count > 200 { footTrail.removeFirst(footTrail.count - 200) }

        // **Phase G11 (2026-05-15)**: sim mode 에서도 3D 모델 보행 시각화.
        //
        // 실 로봇 연결 안 됐을 때 (또는 ARM 안 된 상태) `isRobotWalking == false` 라
        // `runContinuousWalk` 의 onPose 가 호출되지 않음. sim 50ms tick 으로 phase 보간 후
        // visualPose 갱신해서 모델이 보행 따라 움직이도록.
        //
        // 실 로봇 송출 중 (`isRobotWalking == true`) 이면 onPose 가 권한 — sim 덮어쓰기 회피.
        //
        // **Phase G12 (Codex audit 4th pass, 2026-05-15)**: 이전 sim mode 가
        // `(strideMm: 25, sideMm: 0, turnDeg: 0)` 하드코드 → preset 무시 → 모든 preset 이
        // 동일 보행 자세로 시각화됐던 P0 버그. `defaultTuning(for: current)` 로 정정해서
        // march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight 가 각각 다른 보행 자세.
        if !isRobotWalking, current != .idle {
            let effectiveTuning: WalkMotionLibrary.AdvancedTuning = advanced
                ? WalkMotionLibrary.AdvancedTuning(
                    strideMm: strideMm, sideMm: sideMm, turnDeg: turnDeg,
                    periodMs: customPeriodMs, footHeightMm: footHeightMm, balanceGain: balanceGain
                  )
                : WalkMotionLibrary.defaultTuning(for: current)
            let period = effectiveTuning.periodMs
            let phaseFraction = (Double(elapsedMs).truncatingRemainder(dividingBy: period)) / period
            let phasedTimeMs = phaseFraction * period
            if let pose = WalkMotionLibrary.simWalkingPose(timeMs: phasedTimeMs, tuning: effectiveTuning) {
                // **Stage 4 (v1.1 fall prevention)**: sim mode 에서도 corrector 적용
                // → 시각화에 보정 효과 미리보기 (실 robot 미연결 상태에서도 검증).
                visualPose = applyBalanceCorrectionIfEnabled(to: pose)
            }
        } else if current == .idle, !isRobotWalking {
            // idle 상태 → walkReady 로 부드럽게 복귀 (sim).
            visualPose = .walkReady
        }

        updateImuFromRealOrSim()
        updateSimThermal()
        updateFallPrediction()

        // **Stage 2 (v1.1 fall prevention)**: 다단계 임계 분기.
        // `autoFallPrevention = false` 면 emergency (30°) 만 작동 — 기존 동작 보존.
        let maxTilt = max(abs(imuRollDeg), abs(imuPitchDeg))
        balanceState = BalanceState.from(maxTilt: maxTilt)

        if autoFallPrevention {
            applyBalanceMitigation()

            // **Stage 3 (v1.1 fall prevention)**: predictor 가 emergency 권고 → L3 도달
            // 전에 선제 emergency. 0.3-0.5s 빠른 정지로 낙상 위험 ↓.
            if fallPrediction.recommendEmergency {
                balanceLost = true
                emergencyStop()
            }
        }

        // 자동 stop (시간 초과)
        if let start = startTime {
            let secs = Date().timeIntervalSince(start)
            if current.maxDurationSec > 0 && Int(secs) >= current.maxDurationSec {
                stop()
            }
        }

        // L3 — 균형 손실 (실 IMU 또는 sim 둘 다 동일 임계, 기존 동작)
        if abs(imuRollDeg) > 30 || abs(imuPitchDeg) > 30 {
            balanceLost = true
            emergencyStop()
        }

        // L4 — 온도 임계
        if maxMotorTemp >= 60 {
            thermalAlarm = true
            emergencyStop()
        }
    }

    /// **Stage 4 (v1.1 fall prevention)**: Balance corrector 적용 helper.
    ///
    /// `enableBalanceCorrection = true` 시 IMU error 기반 4 그룹 delta 적용. gain
    /// ramp 1초 (시작 0% → 100%) 로 oscillation 방지.
    ///
    /// **호출 위치**:
    /// - sim mode 의 `visualPose` 갱신 (검증용 미리보기)
    /// - **실 motor 송출** 은 `runWalkCycle` / `runContinuousWalk` 가 onPose 직전
    ///   별도 호출 (BLOCKER C3 의 실 IK 완성 후 wire). 본 PR 에선 sim 만.
    ///
    /// 입력 pose 는 보통 보행 cycle 의 phase target. roll/pitch error 는 현재 IMU.
    public func applyBalanceCorrectionIfEnabled(to pose: RobotPose) -> RobotPose {
        guard enableBalanceCorrection else { return pose }
        let now = Date()
        if correctionEnabledAt == nil { correctionEnabledAt = now }
        let ramp = correctionEnabledAt.map { now.timeIntervalSince($0) } ?? 1.0

        let corrections = balanceCorrector.corrections(
            rollErrDeg: imuRollDeg,
            pitchErrDeg: imuPitchDeg
        )
        lastCorrections = corrections

        return balanceCorrector.apply(
            to: pose,
            rollErrDeg: imuRollDeg,
            pitchErrDeg: imuPitchDeg,
            enabled: true,
            secondsSinceEnable: ramp
        )
    }

    /// **Stage 3 (v1.1 fall prevention)**: IMU ring buffer 갱신 + predictor 호출.
    ///
    /// 5Hz IMU polling 동기화 — `lastBufferPushAt` 기준 ≥ 150ms 경과 시에만 push.
    /// (50ms tick × 4 ≈ 200ms 의미. 150ms 임계는 polling jitter 허용).
    /// sim mode 에서도 호출 — sim IMU 의 sin 흔들림으로 predictor 동작 검증 가능.
    ///
    /// gyro 데이터:
    /// - 실 mode (`imuSource == .real`): `store.lastTelemetry.imu` 의 gyroXDps/YDps
    /// - sim mode: derivative — `(roll_now - roll_prev) / dt` 를 gyro 로 근사
    private func updateFallPrediction() {
        let now = Date()
        // Polling jitter 허용 — 너무 잦은 push 회피.
        if let last = lastBufferPushAt, now.timeIntervalSince(last) < 0.15 {
            // 그대로 마지막 prediction 유지 (재계산 X — score 변동 줄임).
            return
        }

        // Gyro 추출 — 실 IMU 우선, sim 은 derivative 근사.
        var gyroX: Double = 0
        var gyroY: Double = 0
        if imuSource == .real, let s = store, let imu = s.lastTelemetry?.imu {
            gyroX = Double(imu.gyroXDps)
            gyroY = Double(imu.gyroYDps)
        } else if let prev = imuBuffer.last {
            let dt = now.timeIntervalSince(prev.timestamp)
            if dt > 0.001 {
                gyroX = (imuRollDeg - prev.rollDeg) / dt    // deg / sec
                gyroY = (imuPitchDeg - prev.pitchDeg) / dt
            }
        }

        let sample = FallPredictor.Sample(
            timestamp: now,
            rollDeg: imuRollDeg,
            pitchDeg: imuPitchDeg,
            gyroXDps: gyroX,
            gyroYDps: gyroY
        )
        FallPredictor.append(sample, to: &imuBuffer)
        lastBufferPushAt = now

        fallPrediction = FallPredictor.predict(samples: imuBuffer, now: now)
    }

    /// **Stage 2 (v1.1 fall prevention)**: 다단계 임계 별 자동 mitigation.
    ///
    /// Warning (22-28°) — engine 속도 70% 자동 감속.
    /// Danger (28-30°) — engine enabled=false (자세 동결).
    /// Emergency (≥ 30°) 는 별도 L3 게이트가 처리 (토크 OFF + walkReady).
    ///
    /// `autoFallPrevention = false` 면 호출 안 됨 — 기존 30° emergency 만 작동.
    /// Sim mode + 실 mode 모두 동일 적용 (sim 자가검증 가능).
    private func applyBalanceMitigation() {
        switch balanceState {
        case .normal, .caution:
            // 정상·주의 — engine 그대로. UI 만 색 변화.
            break
        case .warning:
            // 70% 자동 감속 — engine 의 x_amplitude 만 줄임. period/y/a 유지.
            let cmd = effectiveCommand
            engine.setCommand(
                x: cmd.x * BalanceState.warning.speedScale,
                y: cmd.y,
                a: cmd.a,
                enabled: cmd.enabled
            )
        case .danger:
            // 자세 동결 — engine 정지 (보행 cycle 일시 멈춤). emergency 직전 단계.
            engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        case .emergency:
            // 즉시 L3 게이트 (별도 처리). 본 helper 는 아무 동작 X.
            break
        }
    }

    /// **Stage 1 (v1.1 fall prevention)**: 실 robot 연결 시 `ConnectionStore.imuFilter`
    /// 의 실 IMU 값 사용 (5Hz polling 자동 갱신). 미연결·stale 시 sim 모델 fallback.
    ///
    /// L3 자동 정지 게이트 (`|roll/pitch| > 30°`) 는 동일하게 작동 — 실 IMU 가
    /// 30° 도달하면 즉시 emergency.
    private func updateImuFromRealOrSim() {
        // 1) 실 robot 연결 + IMU 신선도 확인.
        if let s = store, s.bus != nil, !s.imuFilter.isStale() {
            imuRollDeg = s.imuFilter.rollDeg
            imuPitchDeg = s.imuFilter.pitchDeg
            imuSource = .real
            return
        }
        // 2) IMU stale (5초+ 갱신 없음) → 안전 가드. UI 에 노출.
        if let s = store, s.bus != nil, s.imuFilter.isStale() {
            imuSource = .stale
            // 값은 유지 (마지막 알려진) — sim 덮어쓰기 회피.
            return
        }
        // 3) 그 외 (미연결 / 테스트) → 기존 sim 모델 fallback.
        updateSimIMU()
        imuSource = .sim
    }

    /// Sim IMU — 워킹 중 본체 흔들림 모델.
    /// roll ≈ 4° 피크 (좌우), pitch ≈ 2° 피크 (전후), 속도 ↑ → 진폭 ↑.
    /// idle 일 때는 0 으로 수렴 (지수 디케이).
    private func updateSimIMU() {
        let cmd = effectiveCommand
        let periodMs = max(effectivePeriodMs, 200.0)
        let omega = 2.0 * .pi / (periodMs / 1000.0)
        simSwayPhase += omega * tickDtSec

        if cmd.enabled {
            // 속도 비례 보정 — x_amplitude 가 0.04 이면 +50% 진폭.
            let speedFactor = 1.0 + min(abs(cmd.x) / 0.04, 1.0) * 0.5
            let baseRoll = 4.0 * speedFactor
            let basePitch = 2.0 * speedFactor
            imuRollDeg = baseRoll * sin(simSwayPhase + .pi / 2)
            imuPitchDeg = basePitch * sin(simSwayPhase * 2)
        } else {
            // 자연 감쇠 — 한 tick 에 15% 감소.
            imuRollDeg *= 0.85
            imuPitchDeg *= 0.85
            if abs(imuRollDeg) < 0.05 { imuRollDeg = 0 }
            if abs(imuPitchDeg) < 0.05 { imuPitchDeg = 0 }
        }
    }

    /// Sim thermal — 워킹 중 모터 발열 + idle 시 자연 냉각.
    /// 단조 증가/감소. 자동정지(60°C) 게이트 검증을 위한 시뮬.
    private func updateSimThermal() {
        let cmd = effectiveCommand
        if cmd.enabled {
            maxMotorTemp += motorHeatRate * tickDtSec
        } else if maxMotorTemp > motorAmbientTemp {
            maxMotorTemp -= motorCoolRate * tickDtSec
            if maxMotorTemp < motorAmbientTemp {
                maxMotorTemp = motorAmbientTemp
            }
        }
    }
}

public struct FootTrailPoint: Identifiable, Hashable {
    public let id = UUID()
    public let t: Date
    public let left: SIMD3<Double>
    public let right: SIMD3<Double>
}

public struct WalkLabRecord: Identifiable, Hashable {
    public let id = UUID()
    public let preset: WalkLabPreset
    public let durationSec: Int
    public let endedAt: Date

    public var summary: String {
        "\(preset.label) × \(durationSec)s"
    }
}
