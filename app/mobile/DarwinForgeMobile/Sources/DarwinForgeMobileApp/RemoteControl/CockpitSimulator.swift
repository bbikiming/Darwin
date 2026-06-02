import Foundation
import Combine
import MobilePilotKit

/// **iOS 측 가상 조종 시뮬레이터** — Mac `CockpitState.integrate()` 의 30Hz 적분 로직을
/// iOS 앱 내부로 이식한 것. 조이스틱 입력만으로 sim 위치·속도·헤딩·거리·trail 을 시각화한다.
///
/// # 비유
///
/// 비행 시뮬레이터의 instrument bus — 조종간(조이스틱) 입력이 들어오면 instrumentation
/// (속도계, 고도계, 헤딩 컴퍼스, 미니맵) 이 모두 같은 source 로 갱신된다.
///
/// # 왜 클라이언트 사이드 시뮬?
///
/// Mac 의 `MobileRelayServer.broadcastTelemetry()` 는 robot 의 *상태* (배터리/온도/지연/safety/uiState)
/// 만 보낸다. Cockpit 의 sim 위치·속도·trail 은 Mac 측 화면 전용 (PilotCockpitView 의
/// CockpitState) 이라 iOS 가 받을 수 없다. 두 가지 해결책 중:
///
///   (1) 새 텔레메트리 페이로드 추가 (Mac↔iOS 프로토콜 확장)
///   (2) iOS 자체 시뮬로 동일 시각 경험 제공 (왕복 latency 0, robot 미연결도 작동)
///
/// 두 번째를 택했다. 본 시뮬은 robot 의 실 위치가 *아닌* 조종 의도 (intent) 의 reflection
/// 으로 명시한다. UI 는 "SIM" 라벨로 사용자에게 정직히 표시한다.
///
/// # ROBOTIS Walking 속도 공식 (Mac 과 동일)
///
/// ```
/// forward_speed_mmps = strideMm × 2000 / periodMs
/// ```
///
/// (2 step / cycle ÷ cycle_time_sec) — sec 단위로 환산. iOS 도 정확히 같은 공식을 사용해
/// 사용자가 Mac Cockpit 과 iOS 앱 사이를 오갈 때 게이지 숫자가 일치한다.
@MainActor
public final class CockpitSimulator: ObservableObject {

    // MARK: - Public published state (UI 가 구독)

    /// 현재 조이스틱 입력 (정규화). x=-1..1 (좌-우), y=-1..1 (위는 -, 전진), turn=-1..1 (좌 +).
    @Published public private(set) var stickX: Double = 0
    @Published public private(set) var stickY: Double = 0
    @Published public private(set) var stickTurn: Double = 0

    /// Throttle 0.5~1.5. periodMs 도 자동 derive.
    @Published public private(set) var speedScale: Double = 1.0

    /// 보행 cadence (ms). 850 = 느림, 600 = 빠름. speedScale 로부터 derive.
    @Published public private(set) var periodMs: Double = 725

    /// Sim heading (deg). +1 = 좌회전 누적.
    @Published public private(set) var simHeadingDeg: Double = 0

    /// Sim 평면 위치 (mm). x = world-x, y = world-z.
    @Published public private(set) var simPositionMM: SIMD2<Double> = .zero

    /// 명령된 속도 (mm/sec, deg/sec) — ROBOTIS Walking 공식 기반. 게이지 표시용.
    @Published public private(set) var forwardSpeedMmPerSec: Double = 0
    @Published public private(set) var lateralSpeedMmPerSec: Double = 0
    @Published public private(set) var turnSpeedDegPerSec: Double = 0

    /// Peak forward speed (mm/sec) — 1초 hold 후 frame-rate independent decay.
    @Published public private(set) var peakForwardSpeedMmPerSec: Double = 0

    /// 누적 거리 (mm) — frame-by-frame 적분.
    @Published public private(set) var totalDistanceMm: Double = 0

    /// 미니맵 경로 trail (최대 60 포인트, 약 2초 분량 @ 30 Hz).
    @Published public private(set) var pathTrail: [SIMD2<Double>] = []

    /// Sim 활성화 토글. false 면 적분 정지 (조이스틱은 여전히 명령 전송).
    @Published public var simulationEnabled: Bool = true {
        didSet {
            // 비활성화 시 즉시 게이지 0 으로 가라앉히고 사용자에게 "정지" 시각화.
            if !simulationEnabled {
                resetVisuals()
            }
        }
    }

    // MARK: - Cockpit baseline 상수 (Mac VirtualJoystickMapper 와 동일)

    /// 전진 stride max (mm/step). Mac VirtualJoystickMapper.cockpitStrideMm.
    public static let cockpitStrideMm: Double = 38.0
    /// 측면 stride max (mm/step). Mac VirtualJoystickMapper.cockpitSideMm.
    public static let cockpitSideMm: Double = 22.0
    /// 회전 max (deg/step). Mac VirtualJoystickMapper.cockpitTurnDeg.
    public static let cockpitTurnDeg: Double = 18.0

    private let maxTrailLen: Int = 60
    private let integrationHz: Double = 30.0

    // MARK: - Internal sim state

    /// CharacterController-style velocity (m/s) — 가속/감속 lerp 의 결과.
    private var simVelocityMps: SIMD2<Double> = .zero
    /// 적분되는 angular velocity (deg/s).
    private var currentTurnSpeedDps: Double = 0

    private var lastIntegrationAt: Date?
    private var integratorTimer: Timer?
    private var peakHoldUntil: Date?

    public init() {}

    // MARK: - Lifecycle

    /// 화면 onAppear 시 호출. 30Hz integrator 시작.
    public func start() {
        guard integratorTimer == nil else { return }
        lastIntegrationAt = Date()
        let interval = 1.0 / integrationHz
        let timer = Timer.scheduledTimer(withTimeInterval: interval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in self?.integrate() }
        }
        integratorTimer = timer
    }

    /// 화면 onDisappear 시 호출. timer 정리 + 상태 reset.
    public func stop() {
        integratorTimer?.invalidate()
        integratorTimer = nil
        lastIntegrationAt = nil
        release()
    }

    /// 모든 입력 + 누적 상태 reset. E-Stop / 화면 사라짐 / 사용자 reset 호출.
    public func release() {
        stickX = 0
        stickY = 0
        stickTurn = 0
        resetVisuals()
    }

    /// 위치/거리/trail 만 reset (입력 유지). simulationEnabled = false 시 사용.
    public func resetVisuals() {
        simVelocityMps = .zero
        currentTurnSpeedDps = 0
        simHeadingDeg = 0
        simPositionMM = .zero
        peakForwardSpeedMmPerSec = 0
        totalDistanceMm = 0
        pathTrail.removeAll()
        forwardSpeedMmPerSec = 0
        lateralSpeedMmPerSec = 0
        turnSpeedDegPerSec = 0
    }

    // MARK: - Input ingestion

    /// 조이스틱/회전 dial 가 호출. WalkFreeformInput 으로 합성된 후 sim 갱신.
    public func apply(input: WalkFreeformInput) {
        stickX = input.x
        stickY = input.y
        stickTurn = input.turn
        setSpeedScale(input.speedScale)
    }

    /// Throttle slider 가 호출. Mac CockpitState.setSpeedScale 과 동일한 derive.
    public func setSpeedScale(_ scale: Double) {
        let clamped = min(max(0.5, scale), 1.5)
        speedScale = clamped
        // Linear 매핑 (Mac 과 동일): 0.5 → 850 (느림), 1.5 → 600 (빠름).
        periodMs = 850.0 - 250.0 * (clamped - 0.5)
    }

    // MARK: - Integration core

    /// 30Hz tick. dt 기반 frame-rate independent 적분 — 시스템 lag / sleep wake 후에도 안전.
    private func integrate() {
        let now = Date()
        guard let last = lastIntegrationAt else {
            lastIntegrationAt = now
            return
        }
        let dt = now.timeIntervalSince(last)
        lastIntegrationAt = now
        guard dt > 0, dt < 0.5 else { return }   // 큰 점프 (sleep wake 등) 무시

        // 게이지는 simulationEnabled 와 무관하게 항상 갱신 — 사용자가 "조이스틱이
        // 인식되고 있다" 는 즉시 피드백을 받을 수 있어야 함.
        updateCommandedSpeeds(dt: dt)

        // 위치 적분은 simulationEnabled 일 때만.
        guard simulationEnabled else { return }
        integrateMotion(dt: dt)
    }

    /// ROBOTIS Walking 공식으로 commanded speed (mm/s, deg/s) 갱신 + peak hold/decay.
    private func updateCommandedSpeeds(dt: TimeInterval) {
        // Mac CockpitState 와 동일: clamp(stick) × baseline × 2000 / periodMs.
        let effStrideMm = stickY * (-1) * CockpitSimulator.cockpitStrideMm   // y up = forward
        let effSideMm = stickX * CockpitSimulator.cockpitSideMm
        let effTurnDeg = stickTurn * CockpitSimulator.cockpitTurnDeg

        // 후진은 Mac 의 mobileFreeformClamp 에서 strideMm 이 -30 으로 clamp 됨 (full 38 ×
        // -1 = -38 이 아니라 -30). 동일 정직성 — 후진 시 -30 clamp 적용.
        let clampedStride = max(min(effStrideMm, CockpitSimulator.cockpitStrideMm), -30.0)

        forwardSpeedMmPerSec = clampedStride * 2000.0 / periodMs
        lateralSpeedMmPerSec = effSideMm * 2000.0 / periodMs
        turnSpeedDegPerSec   = effTurnDeg * 2000.0 / periodMs

        // Peak-hold (전진 magnitude). 1초 유지 후 frame-rate independent decay.
        let fwdMag = abs(forwardSpeedMmPerSec)
        if fwdMag > peakForwardSpeedMmPerSec {
            peakForwardSpeedMmPerSec = fwdMag
            peakHoldUntil = Date().addingTimeInterval(1.0)
        } else if let hold = peakHoldUntil, Date() > hold {
            let decay = pow(0.985, dt * 30)
            peakForwardSpeedMmPerSec *= decay
            if peakForwardSpeedMmPerSec < 1 { peakForwardSpeedMmPerSec = 0 }
        }
    }

    /// CharacterController-style position 적분. exp lerp 로 가속/감속 → felt smooth.
    private func integrateMotion(dt: TimeInterval) {
        // Mac CockpitState 와 동일 상수.
        let maxLinearMps: Double = 1.6
        let maxAngularDps: Double = 90.0
        let acceleration: Double = 6.0
        let deceleration: Double = 9.0

        let inputFwd = (-stickY)
        let inputLat = stickX
        let inputTurn = stickTurn

        // Desired velocity.
        let scale = max(0.5, min(1.5, speedScale))
        let desiredVx = inputLat * maxLinearMps * scale
        let desiredVy = inputFwd * maxLinearMps * scale
        let desiredW = inputTurn * maxAngularDps * scale

        // Frame-rate independent lerp: alpha = 1 - exp(-rate * dt). Unity SmoothDamp 등가.
        let isAccelerating = abs(desiredVx) > 0.01 || abs(desiredVy) > 0.01 || abs(desiredW) > 0.1
        let linearRate = isAccelerating ? acceleration : deceleration
        let alphaLin = 1.0 - exp(-linearRate * dt)
        simVelocityMps = SIMD2(
            simVelocityMps.x + (desiredVx - simVelocityMps.x) * alphaLin,
            simVelocityMps.y + (desiredVy - simVelocityMps.y) * alphaLin)

        // 잔여 drift snap to zero.
        if abs(simVelocityMps.x) < 0.01 { simVelocityMps.x = 0 }
        if abs(simVelocityMps.y) < 0.01 { simVelocityMps.y = 0 }

        // Angular 도 동일 lerp.
        currentTurnSpeedDps = currentTurnSpeedDps
            + (desiredW - currentTurnSpeedDps) * alphaLin

        // 누적 거리 — ROBOTIS commanded speed magnitude 기반 (정직 odometer).
        let robotSpeedMmPerSec = hypot(forwardSpeedMmPerSec, lateralSpeedMmPerSec)
        totalDistanceMm += robotSpeedMmPerSec * dt

        // Heading 적분.
        simHeadingDeg += currentTurnSpeedDps * dt

        // World frame rotation.
        let theta = simHeadingDeg * .pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        let vForwardMps = simVelocityMps.y
        let vLateralMps = simVelocityMps.x
        let worldVxMps = vForwardMps * sinT - vLateralMps * cosT
        let worldVzMps = vForwardMps * cosT + vLateralMps * sinT

        simPositionMM = SIMD2(simPositionMM.x + worldVxMps * 1000 * dt,
                              simPositionMM.y + worldVzMps * 1000 * dt)

        // Path trail — 1cm 이상 움직였을 때만 새 포인트. ring buffer.
        if let last = pathTrail.last {
            let movedMm = hypot(simPositionMM.x - last.x, simPositionMM.y - last.y)
            if movedMm > 10 {
                appendTrail(simPositionMM)
            }
        } else {
            appendTrail(simPositionMM)
        }
    }

    /// Trail 추가 — immutable 패턴으로 새 array 생성 (Combine publish 안정).
    private func appendTrail(_ point: SIMD2<Double>) {
        var next = pathTrail
        next.append(point)
        if next.count > maxTrailLen {
            next.removeFirst(next.count - maxTrailLen)
        }
        pathTrail = next
    }

    // MARK: - Derived helpers (UI 가 사용)

    /// 0..1 정규화된 전진 속도 magnitude (게이지 채움 비율).
    public var forwardSpeedNorm: Double {
        let maxMmps = CockpitSimulator.cockpitStrideMm * 2000.0 / 600.0  // ~127
        return min(abs(forwardSpeedMmPerSec) / maxMmps, 1.0)
    }

    /// 0..1 정규화된 측면 속도 magnitude.
    public var lateralSpeedNorm: Double {
        let maxMmps = CockpitSimulator.cockpitSideMm * 2000.0 / 600.0  // ~73
        return min(abs(lateralSpeedMmPerSec) / maxMmps, 1.0)
    }

    /// 0..1 정규화된 회전 속도 magnitude.
    public var turnSpeedNorm: Double {
        let maxDeg = CockpitSimulator.cockpitTurnDeg * 2000.0 / 600.0  // ~60
        return min(abs(turnSpeedDegPerSec) / maxDeg, 1.0)
    }

    /// 현재 stride (mm/step) — readout 표시용.
    public var commandedStrideMm: Double {
        stickY * -1 * CockpitSimulator.cockpitStrideMm
    }

    /// 현재 측면 stride (mm/step).
    public var commandedSideMm: Double {
        stickX * CockpitSimulator.cockpitSideMm
    }

    /// 현재 회전 (deg/step).
    public var commandedTurnDeg: Double {
        stickTurn * CockpitSimulator.cockpitTurnDeg
    }

    /// 정지 여부 (게이지/banner 표시).
    public var isStopped: Bool {
        abs(stickX) < 0.05 && abs(stickY) < 0.05 && abs(stickTurn) < 0.05
    }
}
