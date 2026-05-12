import Combine
import ForgeCore
import SwiftUI

/// Walk Lab 의 ObservableObject — 현재 프리셋 / 고급 슬라이더 / 시뮬 결과 / 안전 상태.
///
/// 시뮬 vs 실 송출:
///   - 슬라이더 (보폭/측면/회전/주기) → sim only. walk::engine 의 실 IK 가 v1.5
///     에서 완성된 후 실 보행 송출 (BLOCKER C3).
///   - 프리셋 start/stop → bus 연결 + cradle 확인 시 정적 자세 송출:
///       · start → walkReady (정적 직립, T-pose 하체)
///       · stop → walkReady 자세 유지 (직립 상태)
///       · emergencyStop → ConnectionStore.emergencyStop (토크 OFF)
///   - `attach(store:)` 호출 전이면 송출 skip (테스트 / preview / 연결 전).
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
    @Published public var maxMotorTemp: Double = 35.0
    @Published public var balanceLost: Bool = false
    @Published public var thermalAlarm: Bool = false

    // MARK: - 세션 기록
    @Published public var history: [WalkLabRecord] = []

    // MARK: - 실 로봇 연결 (optional)
    /// 환경에서 주입되는 연결 store. nil 이면 sim only.
    private weak var store: ConnectionStore?
    /// 마지막 송출 상태 — UI 토스트용.
    @Published public private(set) var lastRobotEvent: String?

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
        startTime = Date()

        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: tickDtSec, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        // 실 로봇 송출 — bus 연결 + cradle 확인 시 walkReady 정적 자세로.
        // 슬라이더(보폭/측면 등) 는 v1.5 IK 완성까지 sim only — 자세만 송출.
        sendRobotPose(.walkReady, eventLabel: "보행 자세 송출 — \(preset.label)")
    }

    /// 진행 중 sim 에 현재 슬라이더/프리셋 값을 재밀어넣는다.
    /// advanced 슬라이더가 움직였을 때 view 측에서 호출.
    public func syncCommandToEngine() {
        let cmd = effectiveCommand
        engine.setCommand(x: cmd.x, y: cmd.y, a: cmd.a, enabled: cmd.enabled)
        engine.setPeriodMs(effectivePeriodMs)
    }

    /// 정지 — 시뮬 멈춤, 기록 누적, 실 로봇은 walkReady 정적 자세 유지.
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

        // 실 로봇 — walkReady 정적 자세 유지 (서있는 상태). 진행 중이었을 때만 송출.
        if wasRunning {
            sendRobotPose(.walkReady, eventLabel: "정지 — 직립 자세 유지")
        }
    }

    /// 비상 정지 — Stop + risk reset + 실 로봇 토크 OFF.
    public func emergencyStop() {
        // 시뮬 정지 — stop() 안에서 자세 송출이 일어나면 위험. 토크 OFF 먼저.
        store?.emergencyStop()
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
    /// 슬라이더 보행 명령은 v1.5 IK 까지 sim only — 본 메서드는 자세 전환 only.
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

        updateSimIMU()
        updateSimThermal()

        // 자동 stop (시간 초과)
        if let start = startTime {
            let secs = Date().timeIntervalSince(start)
            if current.maxDurationSec > 0 && Int(secs) >= current.maxDurationSec {
                stop()
            }
        }

        // L3 — 균형 손실
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
