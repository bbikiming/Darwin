import Foundation
import ForgeCore
import GameController
import SwiftUI

/// Cockpit 화면의 single source of truth. 가상 조이스틱·외부 게임패드·키보드
/// 입력을 한곳에 모아 HUD 와 명령 dispatch 가 동일한 상태에서 갱신되도록 한다.
///
/// # 비유
///
/// 항공기 cockpit 의 instrumentation bus — 어떤 입력 (스틱/스로틀/페달) 이든
/// 같은 계기판에 표시되고 같은 actuator 로 흘러간다. 본 클래스는 그 instrumentation
/// bus 역할로, view 와 input 어댑터가 모두 읽기/쓰기 한 다발로 묶인다.
@MainActor
public final class CockpitState: ObservableObject {

    // MARK: - Stick state (visualised in HUD)

    /// Left stick: `(x, y)` — `x = +1` 우측, `y = -1` 위(전진).
    @Published public var leftStick: SIMD2<Double> = .zero
    /// Right stick: `(turn, throttle)` — `turn = +1` 좌회전.
    /// `throttle` 은 보류 (다리 로봇 → 미사용, 미래 머리 pitch / arm 등에 매핑 가능).
    @Published public var rightStick: SIMD2<Double> = .zero

    /// **Throttle slider** (사용자 raw 입력) — 0.5 (느림) ~ 1.5 (빠름).
    /// 정의: stick magnitude 가 amplitude (보폭), throttle 이 cadence (period 의 역
    /// 수). 본 값이 변경되면 `periodMs` 도 자동 derived 갱신.
    ///
    /// **이전 정의 (deprecated 의미)**: amplitude scale (mapper 안에서 stride 에 곱).
    /// 신규: cadence selector. mapper 는 stick magnitude 만 가지고 amplitude 결정.
    @Published public var speedScale: Double = 1.0

    /// **ROBOTIS Walking PERIOD_TIME (cadence)** — 한 보행 사이클 (좌발+우발) 의
    /// 시간 (ms). throttle slider (`speedScale`) 가 본 값을 derive: 0.5 → 850 (느
    /// 림), 1.5 → 600 (빠름). WalkLab freeform clamp 의 600..850 범위 안.
    ///
    /// # ROBOTIS Walking 의 속도 공식
    ///
    /// ```
    /// forward_speed_mmps = strideMm × 2000 / periodMs
    /// ```
    ///
    /// (2 step per cycle ÷ cycle_time_sec)
    ///
    /// stick magnitude → strideMm (보폭), throttle → periodMs (잦은 걸음). 두 축이
    /// 독립적으로 속도에 곱셈 작용.
    @Published public private(set) var periodMs: Double = 700

    // MARK: - Latest command + source

    /// 가장 최근 계산된 walk command (raw 목표) — readout HUD 에 표시.
    @Published public var lastCommand: WalkingCommand = .stop
    /// **모터로 송출되는 스무딩된 보행 명령** — `lastCommand`(raw 목표)를 30Hz EMA 로
    /// 추종 + 다축 결합 안전한계. 화면(walkAnimator)·게이지·실모터가 모두 이 값을 써
    /// 디지털 트윈(화면=시뮬=모터)을 유지하면서 다축 입력을 매끄럽게 만든다.
    @Published public private(set) var motorCommand: WalkingCommand = .stop
    /// 가장 최근 입력 source — HUD 의 "INPUT" 라벨에 표시.
    @Published public var lastSource: InputSource = .virtualJoystick

    // MARK: - Connection / safety

    /// 연결된 외부 컨트롤러 이름. nil = 미연결.
    @Published public var connectedController: String?
    /// 가장 최근 emergency 트리거 시각 — HUD 깜빡임용.
    @Published public var emergencyAt: Date?
    /// 가장 최근 복구 트리거 시각.
    @Published public var recoveryAt: Date?
    /// 볼 트래킹 (2026-06-02) — 가장 최근 토글 트리거 시각. 조종기 버튼이 set,
    /// PilotCockpitView 가 onChange 로 session.ballTrackingEnabled 를 뒤집는다.
    @Published public var ballTrackingToggleAt: Date?

    // MARK: - Simulated kinematics (chase camera 가 따라가는 값)
    //
    // **정직성**: 본 값은 실 robot 위치가 아닌 cockpit 자체의 시뮬레이션이다.
    // `simulationEnabled` 가 true 일 때만 chase scene 에 반영되며 UI 에는 "SIM"
    // 라벨이 보이도록 한다. 실 모터 명령은 WalkLabSession 경로를 사용해야 한다.

    /// 시뮬 robot 평면 이동/회전을 chase scene 에 반영할지. 사용자 보고:
    /// 카메라가 robot 을 따라가도록 (걷는 듯한 grid 흐름 효과) 기본 ON. "SIM"
    /// 라벨 + 토글은 그대로 유지하여 사용자가 끌 수 있다.
    @Published public var simulationEnabled: Bool = true
    /// 시뮬레이션상의 robot heading (yaw, deg). +1 = 좌회전 (turnLeft 일관).
    @Published public var simHeadingDeg: Double = 0
    /// 시뮬레이션상의 robot 평면 좌표 (mm). x = world-x, y = world-z.
    @Published public var simPositionMM: SIMD2<Double> = .zero
    /// **WalkMotionLibrary 기반 30Hz 보행 pose stream**. stick 입력 변하면
    /// freeformContinuousWalkPlan 의 cycle 을 시간 기반으로 재생 + linear
    /// interpolation. stick 정지 시 0.4 초 ease 후 walkReady 로 복귀.
    @Published public var animatedPose: RobotPose = .walkReady

    /// **머리 조종 (rate 모드 적분 각도, deg)** — 동작 할당으로 들어온 입력을
    /// `integrate()` 가 각속도로 적분한 결과. 실 모터(servo 19 HEAD_PAN / 20
    /// HEAD_TILT) 송출 + 3D 시뮬 머리 회전에 사용. 공식 허용 범위(`Kinematics`):
    /// pan ±90°, tilt ±45°. +pan = 우, +tilt = 위.
    @Published public private(set) var headPanDeg: Double = 0
    /// **M-head-tilt-baseline fix (2026-05-30)**: `RobotPose.walkReady.headTilt = raw 2161
    /// ≈ +10°`. 종전 0° 초기값은 cockpit 진입 직후 사용자 첫 tilt 입력 시 10° 강하(drop)
    /// 를 유발. walkReady tilt baseline 으로 seed 하여 첫 입력이 그 위치에서 시작하게 함.
    /// Pan 은 walkReady = raw 2048 = 0° 로 현행과 동일.
    @Published public private(set) var headTiltDeg: Double = Kinematics.degrees(fromRaw: 2161)

    /// 현재 머리 입력 norm (-1...1) — `applyHead` 가 갱신, `integrate()` 가 소비.
    /// rate 적분의 입력일 뿐이라 published 불필요 (관찰 대상은 적분된 각도).
    private var headInputPanNorm: Double = 0
    private var headInputTiltNorm: Double = 0
    /// detented 카메라 휠(Z) 등 이산 입력을 EMA 로 연속화한 머리 norm — integrate 가
    /// 적분에 사용. 종전 raw norm 직접 적분은 휠 클릭마다 각속도가 튀어 tilt 가 끊겼다.
    private var smoothedHeadPanNorm: Double = 0
    private var smoothedHeadTiltNorm: Double = 0

    /// 명령 스무딩 EMA 계수 (30Hz). 0.25 ≈ 0.3s ramp — 반응성 유지하며 급변 완화.
    private static let commandSmoothingAlpha: Double = 0.25
    /// 머리 입력 스무딩 EMA 계수 — detented 휠 클릭을 부드러운 각속도 전환으로.
    /// 2026-06-02: 0.25→0.5 — 스무딩이 강하면 머리 반응이 "한참 뒤". 0.5 로 지연 감소.
    private static let headSmoothingAlpha: Double = 0.5

    /// 머리 가동 한계 (deg) — `Kinematics` 의 headPan/headTilt degreeLimits 와 일치.
    private let headPanLimit: ClosedRange<Double> = -90...90
    private let headTiltLimit: ClosedRange<Double> = -45...45

    /// 현재 눌려 있는 키보드 키 (WASD/QE/Space/R). UI overlay 가 활성 키를
    /// 시각화하여 사용자가 어느 키가 인식되었는지 즉시 확인할 수 있게 한다.
    @Published public var keyPressed: Set<Character> = []

    /// 시뮬 속도 (mm/sec, deg/sec) — speed gauge HUD 가 표시. 실 robot 보행 속도
    /// 와 다른 시뮬용 multiplier 가 곱해진 값.
    @Published public var simForwardSpeedMmPerSec: Double = 0
    @Published public var simLateralSpeedMmPerSec: Double = 0
    @Published public var simTurnSpeedDegPerSec: Double = 0

    /// Peak forward speed (mm/sec) — gauge 의 peak-hold marker. 더 큰 값이 들어
    /// 오면 즉시 갱신, 1초 후에 1% / frame 감쇠.
    @Published public var peakForwardSpeedMmPerSec: Double = 0
    private var peakHoldUntil: Date?
    /// 누적 이동 거리 (mm). simPositionMM 의 frame-to-frame Δ 누적 (방향 무관).
    @Published public var totalDistanceMm: Double = 0
    /// Position minimap 의 path trail — 마지막 60 포인트 (약 2초 분량 @ 30 Hz).
    @Published public var pathTrail: [SIMD2<Double>] = []
    private let maxTrailLen: Int = 60

    /// **CharacterController-style velocity (m/s)** — Unity `CharacterController.
    /// velocity` 등가. integrate() 가 desired velocity 와 lerp 보간으로 갱신.
    /// stick release 시 즉시 0 이 아니라 deceleration rate 로 부드럽게 감속.
    @Published public var simVelocityMps: SIMD2<Double> = .zero

    /// Angular velocity (deg/sec) — linear 와 동일 lerp. heading 적분에 사용.
    private var currentTurnSpeedDps: Double = 0
    /// 각 키별 자동 release 작업 — 중복 누름 시 cancel 후 재시작 (hold 시 깜빡임 차단).
    private var keyReleaseTasks: [Character: Task<Void, Never>] = [:]

    /// **Hybrid keyboard 입력 — heldKeys set (single source-of-truth)**.
    ///
    /// CockpitKeyboardHotkeys (`.keyboardShortcut`) 와 CockpitKeyboardMonitor
    /// (`NSEvent`) 가 둘 다 본 set 을 갱신하는 권위 store. 직접 mutation 금지 —
    /// `insertHeldKey(_:)` / `removeHeldKey(_:)` 만 사용 (race 방지 + 자동 applyHeldKeys).
    ///
    /// **HIGH #1 fix (code review)**: 종전 monitor 가 자체 local `heldKeys` set 을
    /// 갖고 그것으로 state.applyHeldKeys 호출 → state.heldKeys 가 monitor 의 view 로
    /// overwritten, hotkeys 가 갱신한 키가 사라지는 race. 단일 source-of-truth 로 변경.
    @Published public private(set) var heldKeys: Set<Character> = []
    /// keyboardShortcut fire 후 OS auto-repeat 가 250ms 이내 다시 fire 하지 않으면
    /// 키가 stuck. timer 로 자동 release — monitor 가 키 떼는 걸 못 잡아도 안전.
    private var heldKeyTimers: [Character: Task<Void, Never>] = [:]

    /// 외부에서 키 hold 시작 — heldKeys 에 추가 후 applyHeldKeys 자동 갱신.
    /// hotkeys / monitor 가 모두 본 API 만 사용. (HIGH #2 — encapsulation)
    public func insertHeldKey(_ key: Character) {
        heldKeys.insert(key)
        applyHeldKeys(heldKeys)
    }

    /// 외부에서 키 hold 해제 — heldKeys 에서 제거 후 applyHeldKeys 자동 갱신.
    public func removeHeldKey(_ key: Character) {
        heldKeys.remove(key)
        heldKeyTimers[key]?.cancel()
        heldKeyTimers[key] = nil
        applyHeldKeys(heldKeys)
    }

    /// 이번 step 의 마지막 sim 적분 시각 — dt 계산용.
    private var lastIntegrationAt: Date?
    /// 30 Hz integrator timer.
    private var integratorTimer: Timer?
    /// 보행 pose stream 생성기. integrate() 가 매 tick 호출.
    private let walkAnimator = CockpitWalkAnimator()

    public init() {}

    // MARK: - Sim lifecycle

    /// CockpitView appear 시 호출 — integrator 시작.
    public func startSimulation() {
        guard integratorTimer == nil else { return }
        lastIntegrationAt = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                     repeats: true) { [weak self] _ in
            Task { @MainActor in self?.integrate() }
        }
        integratorTimer = t
    }

    /// CockpitView disappear 시 호출 — timer 정리.
    public func stopSimulation() {
        integratorTimer?.invalidate()
        integratorTimer = nil
        lastIntegrationAt = nil
    }

    /// Robot 을 원점으로 reset — 새 세션 시작 시.
    public func resetSimulation() {
        simHeadingDeg = 0
        simPositionMM = .zero
        simVelocityMps = .zero
        currentTurnSpeedDps = 0
        walkAnimator.reset()
        animatedPose = .walkReady
        peakForwardSpeedMmPerSec = 0
        totalDistanceMm = 0
        pathTrail.removeAll()
    }

    /// stick → command 적분. 30Hz 마다 호출.
    ///
    /// # 단위 변환
    /// - `strideMm` (mm/step) → 약 stride/0.6s = 1.67 × mm/sec
    /// - `turnDeg` (deg/step) → 1.67 × deg/sec
    /// step period 는 WalkLab 의 slowWalk(600 ms) 기준. 시뮬용이라 cadence 보존
    /// 보다 사용자 체감 속도가 중요.
    private func integrate() {
        let now = Date()
        guard let last = lastIntegrationAt else {
            lastIntegrationAt = now
            return
        }
        let dt = now.timeIntervalSince(last)
        lastIntegrationAt = now
        guard dt > 0, dt < 0.5 else { return }   // sleep wake 같은 큰 점프 무시

        // 보행 pose stream — sim 토글과 무관하게 항상 갱신.
        // (sim 토글은 robot 의 평면 위치/방향만 좌우; 다리 swing 은 stick 누름에
        // 따라 항상 시각화되어야 사용자가 "조이스틱이 인식되고 있다"는 신호를
        // 직접 본다.)
        //
        // **Digital Twin (ROBOTIS Walking PERIOD_TIME)**: cockpit.periodMs 를 그
        // 대로 animator 에 전달. 실 motor 도 같은 periodMs (pilotApplyAmplitude-
        // WithPeriod) — 화면 다리 swing 속도 = 실 robot cadence.
        // **명령 스무딩** — motorCommand 를 lastCommand(raw 목표)로 EMA 추종 + 다축
        // 결합 안전한계 + 미세값 snap. 화면(walkAnimator)·게이지·실모터가 공통으로 이
        // 값을 써 디지털 트윈을 유지하면서 다축 입력을 매끄럽고 안정적으로 만든다.
        motorCommand = CockpitCommandSmoother.step(
            current: motorCommand, target: lastCommand,
            alpha: Self.commandSmoothingAlpha,
            strideMax: VirtualJoystickMapper.cockpitStrideMm,
            sideMax: VirtualJoystickMapper.cockpitSideMm,
            turnMax: VirtualJoystickMapper.cockpitTurnDeg)
        let cmd = motorCommand
        walkAnimator.update(
            commandStrideMm: cmd.strideMm,
            commandSideMm: cmd.sideMm,
            commandTurnDeg: cmd.turnDeg,
            periodMs: periodMs,
            enabled: !cmd.isStop)
        var pose = walkAnimator.pose

        // **머리 rate 적분** — sim 토글과 무관 (실 모터만 쓸 때도 머리는 돌아야 함).
        // 입력 norm 을 각속도로 적분 → 공식 한계 clamp → 1° 양자화 후 변화 시에만
        // publish (100Hz HID jitter 를 소수 write 로 압축). 3D 시뮬 pose 에도 반영해
        // 로봇 없이도 머리 회전을 확인.
        // **pan 부호 반전**: ROBOTIS HEAD_PAN 의 raw 증가가 로봇 기준 좌회전이라,
        // 사용자 "우(+headPanNorm)" 의도를 raw 감소(음의 각도)로 매핑해야 좌우가 맞는다.
        //
        // **양자화 제거 (드드득 fix)**: 종전 1° `rounded()` 는 currentDeg 에 반올림된
        // 값을 재투입해 작은 입력(부분 기울임)의 적분을 삼켰다 → 누적 실패로 멈췄다가
        // 1° 씩 튀는 계단 움직임. 다리 walkAnimator 처럼 30Hz 연속 각도로 누적하면
        // 시뮬(MeshRig)·실모터 모두 매끄럽게 추종한다.
        // 입력 norm EMA — detented 카메라 휠(Z=tilt)의 이산 점프를 연속 각속도로
        // 부드럽게(Y=pan 도 동일·무해). 그 다음 rate 적분. pan 은 부호 반전(우=+).
        smoothedHeadPanNorm = CockpitCommandSmoother.ema(
            smoothedHeadPanNorm, headInputPanNorm, alpha: Self.headSmoothingAlpha)
        smoothedHeadTiltNorm = CockpitCommandSmoother.ema(
            smoothedHeadTiltNorm, headInputTiltNorm, alpha: Self.headSmoothingAlpha)
        headPanDeg = CockpitHeadKinematics.integrate(
            currentDeg: headPanDeg, inputNorm: -smoothedHeadPanNorm,
            rateDegPerSec: CockpitHeadKinematics.panRateDegPerSec,
            dt: dt, limit: headPanLimit)
        headTiltDeg = CockpitHeadKinematics.integrate(
            currentDeg: headTiltDeg, inputNorm: smoothedHeadTiltNorm,
            rateDegPerSec: CockpitHeadKinematics.tiltRateDegPerSec,
            dt: dt, limit: headTiltLimit)
        pose = pose
            .with(.headPan, raw: Kinematics.raw(fromDegrees: headPanDeg))
            .with(.headTilt, raw: Kinematics.raw(fromDegrees: headTiltDeg))
        animatedPose = pose

        // 정직성: 시뮬 모드 토글이 OFF 면 robot 의 sim 위치/방향을 갱신하지 않는다.
        guard simulationEnabled else { return }

        // **방법론 (Unity CharacterController + Unreal Movement Component)**:
        //
        // game character 의 perceived motion 은 두 가지 layer:
        //   (1) desired velocity = stick input × max speed
        //   (2) current velocity = lerp(current, desired, accel/decel × dt)
        //
        // (2) 의 보간이 stick release 시 즉시 정지 대신 부드러운 감속을 만들어
        // 게임처럼 felt — Unity 의 `Vector3.SmoothDamp` / Unreal 의
        // `MaxAcceleration / BrakingDeceleration` 와 등가.
        //
        // 실 motor dispatch (`pilotApplyAmplitude`) 는 본 시뮬 속도 영향 없음.
        let maxLinearMps: Double = 1.6           // 사람 보행 속도 (~1.4 m/s) 약간 위
        let maxAngularDps: Double = 90.0         // deg/sec (사람 turn 속도)
        let acceleration: Double = 6.0           // 1/sec — 가속 (stick 누르면 0.17초에 max)
        let deceleration: Double = 9.0           // 1/sec — 감속 (stick 떼면 0.11초에 stop)

        // **냉정 점검 fix (4.8) — 게이지/화면/실모터 3자 일치**:
        //
        // 실 motor 는 `pilotApplyFreeform` → `mobileFreeformClamp` 를 거친 값으로
        // 송출한다 (stride -30...38, side ±22, turn ±18). 종전 integrate() 는
        //   (a) 정규화 분모가 stale 25/15/10 (Phase G 에서 38/22/18 로 변경됐는데
        //       미반영) → 전진 full 시 38/25=1.52 로 카메라/위치 52% 과구동.
        //   (b) gauge 가 freeform clamp 안 한 cmd 를 사용 → 후진 -38 표시하나 실
        //       motor 는 -30 (27% 과대, 거짓 표시).
        // effectiveCmd 를 motor 와 동일하게 clamp 후 게이지·정규화 모두 이 값 사용.
        let effTuning = WalkMotionLibrary.mobileFreeformClamp(
            WalkMotionLibrary.AdvancedTuning(
                strideMm: cmd.strideMm, sideMm: cmd.sideMm, turnDeg: cmd.turnDeg,
                periodMs: periodMs, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13.0))
        let effStrideMm = effTuning.strideMm
        let effSideMm = effTuning.sideMm
        let effTurnDeg = effTuning.turnDeg

        // 정규화 분모 = cockpit baseline (전진 max). 후진은 clamp 로 -30/38 = -0.79.
        let inputFwd = effStrideMm / VirtualJoystickMapper.cockpitStrideMm  // [-0.79, +1]
        let inputLat = effSideMm / VirtualJoystickMapper.cockpitSideMm
        let inputTurn = effTurnDeg / VirtualJoystickMapper.cockpitTurnDeg

        // Desired velocity (m/s) — stick × max speed × speedScale.
        let scale = max(0.5, min(1.5, speedScale))
        let desiredVx = inputLat * maxLinearMps * scale
        let desiredVy = inputFwd * maxLinearMps * scale
        let desiredW = inputTurn * maxAngularDps * scale

        // **HIGH #3 fix (code review)**: frame-rate independent lerp.
        //
        // 종전 `alpha = min(1, rate*dt)` 는 high-dt frame (예: 시스템 lag, sleep
        // wake) 에서 1.0 으로 clamp → 즉시 desired 로 jump (가속도 의미 잃음).
        // 정통 공식 `alpha = 1 - exp(-rate * dt)` 는 dt 가 어떤 값이어도 매끄러운
        // exponential approach 보장 — Unity `Mathf.SmoothDamp` / Unreal
        // `FInterpTo` 의 정확한 form.
        let isAccelerating = !cmd.isStop
        let linearRate = isAccelerating ? acceleration : deceleration
        let alphaLin = 1.0 - exp(-linearRate * dt)
        simVelocityMps = SIMD2(
            simVelocityMps.x + (desiredVx - simVelocityMps.x) * alphaLin,
            simVelocityMps.y + (desiredVy - simVelocityMps.y) * alphaLin)

        // Snap velocity to zero when very small — 잔여 drift 제거.
        if abs(simVelocityMps.x) < 0.01 { simVelocityMps.x = 0 }
        if abs(simVelocityMps.y) < 0.01 { simVelocityMps.y = 0 }

        // **HIGH #5 fix**: angular velocity 도 동일 lerp 적용 — linear 와 turn 사이
        // 의 가속/감속 비대칭 제거. 종전 dHeading = desiredW * dt (즉시 적용) 였음.
        currentTurnSpeedDps = currentTurnSpeedDps
            + (desiredW - currentTurnSpeedDps) * alphaLin

        // **방법론 변경 (ROBOTIS Walking 속도 공식)**:
        //
        // `forward_speed_mmps = strideMm × 2000 / periodMs`
        //
        // 종전: game-physics lerp 의 simVelocity (사람 보행속도 1.6 m/s 한계 기반,
        // max ~1600 mm/s 표시) 가 사용자에게 "실 robot 1.6 m/s 로 움직임" 환상.
        // 신규: 실 ROBOTIS Walking 모듈의 commanded speed 를 그대로 표시 — stick
        // 끝까지 + throttle max 시 ~127 mm/s, throttle min 시 ~89 mm/s. 사용자가
        // "실 robot 의 이동속도" 를 정확히 인지.
        //
        // simVelocityMps 는 chase camera 의 시각 follow 용으로 유지 (게임 felt).
        //
        // **거짓 없는 게이지**: effStride/Side/Turn (= 실 motor 가 받는 clamp 값) 으로
        // 계산. 후진 full 시 -30 × 2000/period (실제 robot 속도) 표시 — 종전 -38 의
        // 27% 과대 표시 제거.
        simForwardSpeedMmPerSec = effStrideMm * 2000.0 / periodMs
        simLateralSpeedMmPerSec = effSideMm * 2000.0 / periodMs
        simTurnSpeedDegPerSec   = effTurnDeg * 2000.0 / periodMs

        // Peak-hold (forward magnitude). 1초 hold, 그 후 frame-rate independent decay.
        let fwdMag = abs(simForwardSpeedMmPerSec)
        let now2 = Date()
        if fwdMag > peakForwardSpeedMmPerSec {
            peakForwardSpeedMmPerSec = fwdMag
            peakHoldUntil = now2.addingTimeInterval(1.0)
        } else if let hold = peakHoldUntil, now2 > hold {
            // dt-based exponential decay (방법론 #8 review feedback)
            let decay = pow(0.985, dt * 30)
            peakForwardSpeedMmPerSec *= decay
            if peakForwardSpeedMmPerSec < 1 { peakForwardSpeedMmPerSec = 0 }
        }

        // 누적 거리 — **거짓 없는 odometer (MINOR fix)**: 종전 simVelocityMps
        // (game-physics lerp, max 1.6 m/s) 사용 → 실 robot (max ~0.13 m/s) 의 약
        // 12배 과대 표시. 이제 ROBOTIS commanded speed (forward/lateral mm/sec) 의
        // magnitude 로 적분 — 게이지와 동일 source.
        let robotSpeedMmPerSec = hypot(simForwardSpeedMmPerSec, simLateralSpeedMmPerSec)
        totalDistanceMm += robotSpeedMmPerSec * dt

        // Heading 적분 — lerped angular velocity 사용 (linear 와 대칭).
        simHeadingDeg += currentTurnSpeedDps * dt
        // Rotate velocity vector by current heading to world frame.
        let theta = simHeadingDeg * .pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        // robot frame velocity (m/s):
        //   forward (heading=0) = SceneKit +Z (facingAnchor flip 후)
        //   right   (heading=0) = SceneKit -X
        // velocity components: vy = forward, vx = lateral right
        // world delta per frame (m): velocity * dt, then rotate.
        let vForwardMps = simVelocityMps.y
        let vLateralMps = simVelocityMps.x
        let worldVxMps = vForwardMps * sinT - vLateralMps * cosT
        let worldVzMps = vForwardMps * cosT + vLateralMps * sinT
        // World position in mm (m × 1000 × dt).
        simPositionMM = SIMD2(simPositionMM.x + worldVxMps * 1000 * dt,
                              simPositionMM.y + worldVzMps * 1000 * dt)

        // Path trail — minimap 이 표시. 1cm 이상 움직였을 때만 새 포인트 추가
        // (60 포인트 ring buffer, 약 2-4초 분량).
        if let last = pathTrail.last {
            let movedMm = hypot(simPositionMM.x - last.x, simPositionMM.y - last.y)
            if movedMm > 10 {
                pathTrail.append(simPositionMM)
            }
        } else {
            pathTrail.append(simPositionMM)
        }
        if pathTrail.count > maxTrailLen {
            pathTrail.removeFirst(pathTrail.count - maxTrailLen)
        }
    }

    // MARK: - Mutations

    /// 가상 조이스틱 / 외부 컨트롤러 / 키보드가 호출. stick → WalkingCommand 변환
    /// 후 `lastCommand` 갱신. 입력 source 도 함께 기록.
    ///
    /// **방법론 변경 (ROBOTIS Walking)**: 종전 `speedScale` 을 mapper 에 전달해
    /// amplitude 에 곱했으나, 이제 mapper 는 순수 stick → amplitude. throttle (속
    /// 도) 은 `periodMs` 로 분리 — `dispatchRealMotorIfAllowed` 가 amplitude +
    /// period 함께 dispatch.
    public func apply(leftX: Double, leftY: Double,
                      turn: Double,
                      from source: InputSource) {
        leftStick = SIMD2(leftX, leftY)
        rightStick = SIMD2(turn, 0)
        lastSource = source
        // Cockpit 은 WalkLab freeform clamp max (38/22/18) 사용 — ROBOTIS Walking
        // 의 안전 한계까지 도달 가능. Mac VirtualJoystickPanel + iOS 의 legacy
        // baseline (25/15/10) 과 분리 — cockpit 사용자가 더 큰 범위 사용.
        lastCommand = VirtualJoystickMapper.map(
            x: leftX, y: leftY, turn: turn,
            speedScale: 1.0,
            strideMmMax: VirtualJoystickMapper.cockpitStrideMm,
            sideMmMax:   VirtualJoystickMapper.cockpitSideMm,
            turnDegMax:  VirtualJoystickMapper.cockpitTurnDeg)
    }

    /// 머리 동작 할당 입력 — **rate 모드**라 norm (-1...1) 만 저장하고 각도 적분은
    /// `integrate()` 가 30Hz 로 수행. `apply()` 와 완전 독립이라 보행하면서 동시에
    /// 머리를 돌릴 수 있다 (서로의 상태를 덮어쓰지 않음).
    ///
    /// - Parameters:
    ///   - panNorm: 좌우 입력 (-1...1). +가 우(headPanRight).
    ///   - tiltNorm: 상하 입력 (-1...1). +가 위(headTiltUp).
    public func applyHead(panNorm: Double, tiltNorm: Double) {
        headInputPanNorm = panNorm
        headInputTiltNorm = tiltNorm
    }

    public func setSpeedScale(_ scale: Double) {
        let clamped = min(max(0.5, scale), 1.5)
        speedScale = clamped
        // **방법론 (ROBOTIS Walking)**: throttle → cadence. periodMs 를 derive.
        // Linear 매핑: 0.5 → 850 (느림), 1.0 → 725 (보통), 1.5 → 600 (빠름).
        // WalkLab freeform clamp 의 [600, 850] 범위 안.
        periodMs = 850.0 - 250.0 * (clamped - 0.5)
        // Re-derive command — Cockpit max baseline 명시 (38/22/18).
        lastCommand = VirtualJoystickMapper.map(
            x: leftStick.x, y: leftStick.y, turn: rightStick.x,
            speedScale: 1.0,
            strideMmMax: VirtualJoystickMapper.cockpitStrideMm,
            sideMmMax:   VirtualJoystickMapper.cockpitSideMm,
            turnDegMax:  VirtualJoystickMapper.cockpitTurnDeg)
    }

    public func triggerEmergency() {
        emergencyAt = Date()
    }

    public func triggerRecovery() {
        recoveryAt = Date()
    }

    /// 볼 트래킹 (2026-06-02) — 조종기 버튼이 호출. timestamp 갱신 → view 가 토글 적용.
    public func triggerBallTrackingToggle() {
        ballTrackingToggleAt = Date()
    }

    public func setController(name: String?) {
        connectedController = name
    }

    /// 모든 입력 reset — onDisappear / E-Stop 직후 호출.
    public func release() {
        leftStick = .zero
        rightStick = .zero
        lastCommand = .stop
        // 스무딩 우회 — E-Stop/이탈 시 모터 명령 즉시 정지(안전 최우선, ramp 안 함).
        motorCommand = .stop
        // 머리 회전 입력 중단 — 적분이 멈춰 현재 각도를 유지 (E-Stop 시 머리가
        // 갑자기 정면으로 튕기지 않음). 각도(headPanDeg/headTiltDeg)는 보존.
        headInputPanNorm = 0
        headInputTiltNorm = 0
        smoothedHeadPanNorm = 0
        smoothedHeadTiltNorm = 0
        // **LOW #19 fix**: keyReleaseTasks 가 view dealloc 시 정리되지 않으면 누수.
        // release() 가 명시적 cleanup 진입점.
        for task in keyReleaseTasks.values { task.cancel() }
        keyReleaseTasks.removeAll()
        keyPressed.removeAll()
        // **냉정 점검 MEDIUM fix (4.8)**: heldKeys / heldKeyTimers 도 정리.
        // 종전엔 release() 후에도 heldKeys 에 stuck 키 (monitor keyUp 누락 시) +
        // 미취소 timer 가 잔존 → E-Stop 후 사용자가 새 키 누르면 ghost 키와 합성돼
        // 예상 외 모션 (예: "w" stuck + "d" → 전진+우). E-Stop = 전 입력 clear 보장.
        for timer in heldKeyTimers.values { timer.cancel() }
        heldKeyTimers.removeAll()
        heldKeys.removeAll()
    }

    /// 키보드 hotkey 가 fire 했을 때 호출. 활성 키를 0.25 초 동안 표시 (hold 동작
    /// 의 시각적 근사). 동일 키가 다시 fire 되면 timer 가 reset 되어 깜빡임 없음.
    /// **legacy** — CockpitKeyboardMonitor 가 keyDown/keyUp 정확 추적하므로 본 메서드는
    /// 마우스/외부 컨트롤러용 1-shot tap 표시에만 사용.
    public func markKeyPressed(_ key: Character) {
        keyPressed.insert(key)
        keyReleaseTasks[key]?.cancel()
        keyReleaseTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.keyPressed.remove(key)
                self?.keyReleaseTasks[key] = nil
            }
        }
    }

    // MARK: - Keyboard hold/release (CockpitKeyboardMonitor 가 호출)

    /// keyDown 시 호출 — keyPressed 에 추가 (hold 동안 유지, timer auto-remove 없음).
    public func markHold(_ key: Character) {
        keyPressed.insert(key)
    }

    /// keyUp 시 호출 — keyPressed + heldKeys 에서 제거. NSEvent monitor 가 호출.
    /// Tap-key (Space/R) 시각 표시 clear 도 함께.
    public func releaseKey(_ key: Character) {
        keyPressed.remove(key)
        heldKeys.remove(key)
        heldKeyTimers[key]?.cancel()
        heldKeyTimers[key] = nil
        applyHeldKeys(heldKeys)
    }

    /// keyboardShortcut hidden button fire 후 호출 — 250ms 내에 다음 fire (OS
    /// auto-repeat) 가 없으면 키 release. monitor keyUp 이 fire 안 해도 안전.
    /// **HIGH #6 fix**: MainActor.run 진입 후 Task.isCancelled 재확인 — 첫 check 와
    /// sleep 사이에 cancel 발생해도 stale fire 차단.
    public func scheduleHeldKeyAutoRelease(_ key: Character) {
        heldKeyTimers[key]?.cancel()
        heldKeyTimers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                self.heldKeys.remove(key)
                self.applyHeldKeys(self.heldKeys)
                self.heldKeyTimers[key] = nil
            }
        }
    }

    /// 단발 tap (Space / R) — markKeyPressed 와 같은 250ms auto-clear.
    public func markKeyTap(_ key: Character) {
        markKeyPressed(key)
    }

    /// 현재 held 키 set 으로부터 desired stick vector 를 합성하여 `apply(...)` 호출.
    /// 합성 규칙은 `CockpitKeyboardCompose.compose` 에 위임 — pure 함수로 단위 테
    /// 스트 가능. 여러 키 동시 가능 (예: W+D = 전진+측면우).
    public func applyHeldKeys(_ keys: Set<Character>) {
        let v = CockpitKeyboardCompose.compose(keys)
        apply(leftX: v.leftX, leftY: v.leftY, turn: v.turn, from: .keyboard)
    }
}
