import Foundation
import GameController
import Observation

/// **v1.21.0 (2026-05-22) — macOS native 게임패드 통합 (Phase 4 후속)**.
///
/// PS4 / Xbox / Nimbus 등 `GCExtendedGamepad` 호환 컨트롤러를 polling 해서
/// `WalkLabRCBridge` 에 입력을 라우팅한다. 키보드/Tello 와 동일하게 `InputSource.gamepad`
/// 로 라벨되어 telemetry · safetyGate 가 일관 처리.
///
/// # 비유
///
/// 음악 시퀀서의 MIDI 패드 — 외부 컨트롤러가 어떤 물리 장치든 (USB / BT / iOS bridge)
/// 결과는 동일한 메시지 큐로 정규화. 본 adapter 도 같은 원리 — GCExtendedGamepad
/// 호환 시 PS4·Xbox·Nimbus 모두 동일 매핑.
///
/// # 의존 그래프
///
/// ```
///  GCController (또는 MockGamepad)        ← GamepadInputSource (protocol)
///         ↓ (Timer poll 30Hz)
///   GamepadPilotAdapter (본 클래스)
///         ↓
///   TelloRCMapper.map (stick → WalkingCommand)
///         ↓
///   bridge.handleMove / handleEmergency / handlePreset / handleRecovery
/// ```
///
/// # 매핑 (PS4 / Xbox 공통 — GCExtendedGamepad)
///
/// | 입력          | bridge 호출                         | 의미                |
/// | ------------- | ----------------------------------- | ------------------- |
/// | 좌 스틱 X·Y   | `handleMove`(side / stride)         | 보행 X·Y 이동       |
/// | 우 스틱 X     | `handleMove`(turn)                  | 좌·우 회전          |
/// | △ (Y)         | `handleEmergency`                   | 비상 정지           |
/// | □ (X)         | `handlePreset(.idle)`               | 정지 preset         |
/// | D-pad ↑       | `handlePreset(.march)`              | preset 1 (march)    |
/// | D-pad →       | `handlePreset(.slowWalk)`           | preset 2 (slow)     |
/// | D-pad ↓       | `handlePreset(.normalWalk)`         | preset 3 (normal)   |
/// | D-pad ←       | `handlePreset(.fastWalk)`           | preset 4 (fast)     |
/// | START (☰)     | `handleRecovery`                    | 긴급 정지 해제      |
///
/// # 안전
///
/// - 본 adapter 는 **순수 입력 라우터** — SafetyGate 검사는 bridge 가 일관 수행.
/// - 모든 버튼은 edge-trigger (눌렀다 떼는 순간만 1회 발화) — held 상태에서 spam 차단.
/// - 좌·우 스틱이 모두 deadzone 인 frame 은 1회만 `.stop` 전달 후 silent (UDP/CPU 절약).
/// - 컨트롤러 disconnect 시 자동 정리 — 사용자가 다시 연결 시 즉시 재바인딩.
///
/// # 테스트 가능성
///
/// `GamepadInputSource` protocol 로 실 `GCController` 의존을 추상화 — `MockGamepad`
/// 가 buttonsDown / stickState 를 수동 enqueue 해 결정론적 단위 테스트 가능.
/// CI / GitHub Actions 에 실 hardware 없어도 통과.
@MainActor
@Observable
public final class GamepadPilotAdapter {

    // MARK: - 외부 의존성

    /// 약한 참조 — bridge 가 owner. adapter 가 bridge 의 lifecycle 좌우하지 않음.
    public weak var bridge: WalkLabRCBridge?

    /// 입력 소스 추상화 — 실 GCController 또는 MockGamepad.
    private let source: GamepadInputSource

    /// stick → WalkingCommand 변환 scale. bridge.scale 와 별도 — 사용자가 게임패드
    /// 와 키보드 sensitivity 를 독립적으로 조정 가능.
    public var stickScale: TelloRCMapper.Scale = .default

    // MARK: - 관찰 가능 상태

    /// 현재 연결된 컨트롤러 이름. nil = 미연결.
    /// View 가 binding 으로 "PS4 컨트롤러 연결됨" 같은 라벨 표시 가능.
    public private(set) var connectedControllerName: String?

    /// adapter 가 active 한가 (start 호출 후 stop 전).
    public private(set) var isRunning: Bool = false

    /// **테스트 편의** — 가장 최근에 fire 한 액션 라벨 (디버그 / 검증 용).
    /// nil = adapter 가 아직 입력 받지 못함.
    public internal(set) var lastActionLabel: String?

    // MARK: - 내부 상태 (edge detection)

    /// 직전 frame 의 button down 상태. 신규 down 검출용.
    private var previousButtonState: GamepadButtonState = .init()

    /// 직전 stick frame 이 deadzone (zero) 였는지. `.stop` 중복 발화 차단.
    private var previousStickWasZero: Bool = true

    /// polling timer — start 시 alloc, stop 시 invalidate.
    private var pollTimer: Timer?

    /// 연결 알림 observer token — stop 시 unregister.
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    // MARK: - Init

    /// Production init — 기본 `GCControllerInputSource` 사용.
    public convenience init(bridge: WalkLabRCBridge?) {
        self.init(bridge: bridge, source: GCControllerInputSource())
    }

    /// 테스트 init — MockGamepad 등 임의 source 주입.
    public init(bridge: WalkLabRCBridge?, source: GamepadInputSource) {
        self.bridge = bridge
        self.source = source
    }

    // MARK: - Lifecycle

    /// 입력 polling 시작 + GCController connect/disconnect 알림 등록.
    /// 이미 실행 중이면 no-op.
    public func start(pollInterval: TimeInterval = 1.0 / 30.0) {
        guard !isRunning else { return }
        isRunning = true

        // 현재 연결된 컨트롤러 즉시 인식.
        refreshConnectedController()

        // GCController 알림 등록 — 실 GCController source 만 의미 있으나 mock 도 무해.
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConnectedController() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConnectedController() }
        }

        // Polling — Timer.scheduledTimer 가 main RunLoop 에 자동 install.
        // 테스트에서는 start() 미호출 + pollOnce() 수동 호출.
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        pollTimer = timer
    }

    /// 입력 polling 정지 + 알림 unregister + 내부 상태 reset.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        pollTimer?.invalidate()
        pollTimer = nil

        if let token = connectObserver {
            NotificationCenter.default.removeObserver(token)
            connectObserver = nil
        }
        if let token = disconnectObserver {
            NotificationCenter.default.removeObserver(token)
            disconnectObserver = nil
        }

        previousButtonState = .init()
        previousStickWasZero = true
    }

    // **주의**: deinit 미정의. `@MainActor` 클래스의 deinit 는 nonisolated 라
    // MainActor-isolated property 접근 불가. 정리는 stop() 에서 수행 — 호출자가
    // adapter 사용 종료 시 명시 stop() 호출 필요. NotificationCenter observer 는
    // adapter weak self capture 라 dangling reference 안전 (Apple modern API).

    // MARK: - Polling

    /// **테스트 entry point** + Timer callback. source 의 현재 상태를 읽어 bridge 에 전달.
    ///
    /// # 처리 순서 (사이클 62 — 코덱스 HIGH 수정)
    ///
    /// 종전: stick → button 순서로 처리 → emergency edge 가 같은 frame 의 stick move 뒤에
    /// 처리되어 1 frame 의 race window. 사용자가 emergency(△) 와 stick 을 동시 입력 시
    /// stick 의 amplitude write 가 emergency 가드보다 먼저 발생.
    ///
    /// 수정 후: **button edge → emergency 발화 시 즉시 return** → stick 처리 skip.
    /// 일반 button (preset / recovery) 은 stick 과 동시 발생 허용 (race 없음 — 별 통로).
    ///
    /// # 의도
    ///
    /// emergency 는 최고 우선순위 — 같은 frame 의 다른 입력은 모두 silent drop. UI 일관성
    /// 보다 안전 invariant 우선 (panic 입력의 의미: "지금 즉시 멈춰").
    public func pollOnce() {
        guard let bridge = bridge else { return }
        let snapshot = source.snapshot()

        // 컨트롤러 이름 sync (mock 에서도 valid).
        connectedControllerName = snapshot.controllerName

        // 1. Button edge detection 먼저 (사이클 62 — emergency 우선순위 보장).
        // emergency 발화 시 stick 처리 skip → return 후 다음 frame.
        let emergencyFired = processButtons(snapshot.buttons, bridge: bridge)
        previousButtonState = snapshot.buttons

        if emergencyFired {
            // emergency 발화 frame 의 stick 은 무시 — 다음 frame 에서 정상 재개.
            // previousStickWasZero 는 갱신 안 함 → 다음 frame 의 stick zero 시 stop 1회 발화 가능.
            return
        }

        // 2. Stick → handleMove (emergency 가 발화 안 했을 때만).
        processSticks(snapshot.sticks, bridge: bridge)
    }

    private func processSticks(_ sticks: GamepadStickState, bridge: WalkLabRCBridge) {
        // Stick value: -1.0 ... 1.0 (GCExtendedGamepad spec). TelloRCMapper 는 -100..100 int 기대.
        let lr = Int((sticks.leftX * 100).rounded())
        let fb = Int((sticks.leftY * 100).rounded())  // forward = +y
        let yaw = Int((sticks.rightX * 100).rounded())

        let cmd = TelloRCMapper.map(lr: lr, fb: fb, ud: 0, yaw: yaw, scale: stickScale)

        if cmd.isStop {
            // 이미 zero 였으면 spam 차단 — 한 번만 stop.
            if !previousStickWasZero {
                bridge.handleMove(cmd, from: .gamepad)
                lastActionLabel = "stick stop"
            }
            previousStickWasZero = true
        } else {
            bridge.handleMove(cmd, from: .gamepad)
            lastActionLabel = "stick move"
            previousStickWasZero = false
        }
    }

    /// 버튼 edge detection. emergency 가 발화되었으면 `true` 반환 → caller (pollOnce)
    /// 가 stick 처리 skip. 일반 버튼은 always `false` (stick 과 동시 발생 안전).
    ///
    /// **순서**: emergency 를 먼저 검사 — 같은 frame 에 preset+emergency 가 함께 눌리면
    /// emergency 만 fire 하고 preset 은 다음 frame 으로 미룸 (panic 일관성).
    @discardableResult
    private func processButtons(_ buttons: GamepadButtonState, bridge: WalkLabRCBridge) -> Bool {
        // Emergency edge 최우선 — fire 시 즉시 return.
        if buttons.faceTop && !previousButtonState.faceTop {
            bridge.handleEmergency(from: .gamepad)
            lastActionLabel = "emergency (faceTop / △ / Y)"
            return true
        }
        // 일반 버튼 — 동일 frame 다중 fire 허용 (D-pad 두 방향 동시 등은 hardware 측 무시).
        if buttons.faceLeft && !previousButtonState.faceLeft {
            bridge.handlePreset(.idle, from: .gamepad)
            lastActionLabel = "preset idle (faceLeft / □ / X)"
        }
        if buttons.dpadUp && !previousButtonState.dpadUp {
            bridge.handlePreset(.march, from: .gamepad)
            lastActionLabel = "preset 1: march (D-pad ↑)"
        }
        if buttons.dpadRight && !previousButtonState.dpadRight {
            bridge.handlePreset(.slowWalk, from: .gamepad)
            lastActionLabel = "preset 2: slowWalk (D-pad →)"
        }
        if buttons.dpadDown && !previousButtonState.dpadDown {
            bridge.handlePreset(.normalWalk, from: .gamepad)
            lastActionLabel = "preset 3: normalWalk (D-pad ↓)"
        }
        if buttons.dpadLeft && !previousButtonState.dpadLeft {
            bridge.handlePreset(.fastWalk, from: .gamepad)
            lastActionLabel = "preset 4: fastWalk (D-pad ←)"
        }
        if buttons.menu && !previousButtonState.menu {
            bridge.handleRecovery(from: .gamepad)
            lastActionLabel = "recovery (START / ☰)"
        }
        return false
    }

    // MARK: - Controller binding

    private func refreshConnectedController() {
        connectedControllerName = source.controllerName
    }
}

// MARK: - GamepadInputSource protocol (테스트 추상화)

/// 게임패드 입력 source 의 추상화. 실 `GCController` 또는 `MockGamepad`.
///
/// `snapshot()` 은 호출 시점의 stick + button 상태를 한 번에 반환 — race-free.
/// `controllerName` 은 사용자 표시 용 (예: "DualSense Wireless Controller").
@MainActor
public protocol GamepadInputSource: AnyObject {
    /// 현재 연결된 controller 의 product name. nil = 미연결.
    var controllerName: String? { get }

    /// 현재 stick + button 상태 캡쳐.
    func snapshot() -> GamepadSnapshot
}

/// adapter 가 polling 1회에 받는 입력 상태.
public struct GamepadSnapshot: Equatable, Sendable {
    public let controllerName: String?
    public let sticks: GamepadStickState
    public let buttons: GamepadButtonState

    public init(
        controllerName: String?,
        sticks: GamepadStickState,
        buttons: GamepadButtonState
    ) {
        self.controllerName = controllerName
        self.sticks = sticks
        self.buttons = buttons
    }

    public static let neutral = GamepadSnapshot(
        controllerName: nil,
        sticks: .neutral,
        buttons: .init()
    )
}

/// 두 stick 의 현재 좌표 (-1.0 ... 1.0).
public struct GamepadStickState: Equatable, Sendable {
    public let leftX: Float
    public let leftY: Float
    public let rightX: Float
    public let rightY: Float

    public init(leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0) {
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
    }

    public static let neutral = GamepadStickState()
}

/// 버튼 down 상태 — adapter 가 edge-trigger 판정에 사용.
public struct GamepadButtonState: Equatable, Sendable {
    /// △ (PS) / Y (Xbox) — emergency.
    public var faceTop: Bool = false
    /// □ (PS) / X (Xbox) — preset idle.
    public var faceLeft: Bool = false
    /// ○ (PS) / B (Xbox) — 예약 (현재 미할당).
    public var faceRight: Bool = false
    /// × (PS) / A (Xbox) — 예약 (현재 미할당).
    public var faceBottom: Bool = false

    public var dpadUp: Bool = false
    public var dpadRight: Bool = false
    public var dpadDown: Bool = false
    public var dpadLeft: Bool = false

    /// ☰ / START 버튼 — recovery.
    public var menu: Bool = false
    /// SHARE / Back 버튼 — 예약 (현재 미할당).
    public var options: Bool = false

    public init() {}
}

// MARK: - GCController source 구현

/// 실 `GCController` (PS4 / Xbox / Nimbus) 의 GCExtendedGamepad profile 을 snapshot.
/// macOS 14+ 표준 — 별도 entitlement 불요.
@MainActor
public final class GCControllerInputSource: GamepadInputSource {

    public init() {}

    public var controllerName: String? {
        // 가장 먼저 발견된 extendedGamepad 컨트롤러 사용 — 다중 컨트롤러 환경은 향후 phase.
        GCController.controllers().first(where: { $0.extendedGamepad != nil })?.vendorName
    }

    public func snapshot() -> GamepadSnapshot {
        guard let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }),
              let gp = controller.extendedGamepad else {
            return .neutral
        }

        let sticks = GamepadStickState(
            leftX: gp.leftThumbstick.xAxis.value,
            leftY: gp.leftThumbstick.yAxis.value,
            rightX: gp.rightThumbstick.xAxis.value,
            rightY: gp.rightThumbstick.yAxis.value
        )

        var buttons = GamepadButtonState()
        buttons.faceTop    = gp.buttonY.isPressed
        buttons.faceLeft   = gp.buttonX.isPressed
        buttons.faceRight  = gp.buttonB.isPressed
        buttons.faceBottom = gp.buttonA.isPressed

        buttons.dpadUp    = gp.dpad.up.isPressed
        buttons.dpadRight = gp.dpad.right.isPressed
        buttons.dpadDown  = gp.dpad.down.isPressed
        buttons.dpadLeft  = gp.dpad.left.isPressed

        buttons.menu    = gp.buttonMenu.isPressed
        buttons.options = gp.buttonOptions?.isPressed ?? false

        return GamepadSnapshot(
            controllerName: controller.vendorName,
            sticks: sticks,
            buttons: buttons
        )
    }
}
