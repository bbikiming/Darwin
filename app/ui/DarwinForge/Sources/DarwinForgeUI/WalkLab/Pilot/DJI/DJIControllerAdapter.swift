import Foundation
import Observation

/// **v1.22.0 (2026-05-22) 사이클 90 — DJI Controller Stub Adapter**.
///
/// 향후 DJI Mobile SDK / DJI Onboard SDK 통합 시 실 controller 입력 라우팅.
/// 현재는 stub — 외부 simulator / mock 만 사용.
///
/// # 의도
///
/// `.djiRC` InputSource 의 실 wiring 진입점 — `bridge.handleMove(_, from: .djiRC)`,
/// `bridge.handleEmergency(from: .djiRC)` 등 통일 path. SDK 통합 시 본 adapter 의
/// `DJIControllerInputSource` protocol 구현체만 교체.
///
/// # 비유
///
/// USB 직렬 포트 — 어떤 외부 장치가 꽂혀도 host 는 동일 byte stream 만 본다. 본 adapter
/// 도 같은 원리 — 실 DJI RC Pro USB HID 든 Tello 시뮬레이터든 동일한 `PilotIntent` 로
/// 정규화 후 bridge 에 전달.
///
/// # 의존 그래프
///
/// ```
///  DJI Mobile SDK / Tello bridge / MockDJIController   ← DJIControllerInputSource (protocol)
///         ↓ (Timer poll 30Hz)
///   DJIControllerAdapter (본 클래스)
///         ↓
///   TelloRCMapper.map (stick → WalkingCommand)
///         ↓
///   bridge.handleMove / handleEmergency / handlePreset / handleRecovery
/// ```
///
/// # 매핑 (사이클 90 — Gamepad/Voice adapter pattern 일치)
///
/// | 입력          | bridge 호출                         | 의미                |
/// | ------------- | ----------------------------------- | ------------------- |
/// | 좌 스틱 X·Y   | `handleMove`(side / stride)         | 보행 X·Y 이동       |
/// | 우 스틱 X     | `handleMove`(turn)                  | 좌·우 회전          |
/// | RTH (Home)    | `handleEmergency`                   | 비상 정지           |
/// | Pause         | `handlePreset(.idle)`               | 정지 preset         |
/// | C1 (custom 1) | `handleRecovery`                    | 긴급 정지 해제      |
///
/// # 안전 / production 미통합
///
/// - 본 adapter 는 **순수 입력 라우터** — SafetyGate 검사는 bridge 가 일관 수행.
/// - 모든 버튼은 edge-trigger (눌렀다 떼는 순간만 1회 발화) — held 상태에서 spam 차단.
/// - 좌·우 스틱이 모두 deadzone 인 frame 은 1회만 `.stop` 전달 후 silent (UDP/CPU 절약).
/// - emergency 버튼 발화 시 같은 frame 의 stick 처리 skip — Gamepad adapter 사이클 62
///   patch 의 동일 invariant (panic 입력 최우선).
/// - **production 미통합**: `init(bridge:)` 편의 생성자는 명시 stub 으로 `fatalError`.
///   실 DJI SDK SPM 패키지가 부재한 채로 production 코드가 본 adapter 의 production
///   constructor 를 의도치 않게 호출하면 즉시 실패 — silent malfunction (no-op stick)
///   보다 안전. 명시 테스트 / mock 만 `init(bridge:source:)` 통과.
///
/// # 테스트 가능성
///
/// `DJIControllerInputSource` protocol 로 향후 실 DJI SDK 의존을 추상화 — `MockDJIController`
/// 가 stickState / buttonsDown 을 수동 enqueue 해 결정론적 단위 테스트 가능. CI / GitHub
/// Actions 에 실 hardware / SDK 없어도 통과.
///
/// # SDK 통합 시 진입점
///
/// `ProductionDJIControllerSource` 신규 (별도 파일) 추가 후 `DJIControllerAdapter(bridge:
/// source: ProductionDJIControllerSource())` 발화. 본 어댑터 자체는 변경 불필요 — protocol
/// 추상화로 SDK lock-in 없음.
@MainActor
@Observable
public final class DJIControllerAdapter {

    // MARK: - 외부 의존성

    /// 약한 참조 — bridge 가 owner. adapter 가 bridge 의 lifecycle 좌우하지 않음.
    public weak var bridge: WalkLabRCBridge?

    /// 입력 소스 추상화 — 실 DJI SDK source 또는 MockDJIController.
    private let source: DJIControllerInputSource

    /// stick → WalkingCommand 변환 scale. bridge.scale 와 별도 — 사용자가 DJI RC
    /// 와 Tello sensitivity 를 독립적으로 조정 가능.
    public var stickScale: TelloRCMapper.Scale = .default

    // MARK: - 관찰 가능 상태

    /// 현재 연결된 컨트롤러 이름. nil = 미연결.
    /// View 가 binding 으로 "DJI RC Pro 연결됨" 같은 라벨 표시 가능.
    public private(set) var connectedControllerName: String?

    /// adapter 가 active 한가 (`start` 호출 후 `stop` 전).
    public private(set) var isRunning: Bool = false

    /// **테스트 편의** — 가장 최근에 fire 한 액션 라벨 (디버그 / 검증 용).
    /// nil = adapter 가 아직 입력 받지 못함.
    public internal(set) var lastActionLabel: String?

    // MARK: - 내부 상태 (edge detection)

    /// 직전 frame 의 button down 상태. 신규 down 검출용.
    private var previousButtonState: DJIControllerButtonState = .init()

    /// 직전 stick frame 이 deadzone (zero) 였는지. `.stop` 중복 발화 차단.
    private var previousStickWasZero: Bool = true

    /// polling timer — start 시 alloc, stop 시 invalidate.
    private var pollTimer: Timer?

    // MARK: - Init

    /// **Production constructor — 사이클 90 stub**.
    ///
    /// 실 DJI Mobile SDK / Onboard SDK SPM 패키지 미통합 — production code 가 본 생성자를
    /// 호출하면 silent malfunction (no-op stick) 보다 즉시 fatalError 가 더 안전. 명시
    /// mock 테스트만 `init(bridge:source:)` 사용 권장.
    ///
    /// # SDK 통합 후 절차
    ///
    /// 1. `ProductionDJIControllerSource: DJIControllerInputSource` 신규 (별도 파일).
    /// 2. 본 convenience init 의 fatalError 를 `self.init(bridge: bridge, source:
    ///    ProductionDJIControllerSource())` 로 교체.
    /// 3. `FiveSourcePilotPipelineTests.testDJIRCSourceIsPlaceholderNotYetWired` 갱신
    ///    (사이클 79 placeholder docstring 의 5단계 절차).
    /// **사이클 96 — 코덱스 HIGH-2 fix**: 종전 fatalError 던지는 convenience init →
    /// `@available(*, unavailable, ...)` 으로 compile-time error 격상. 외부 module 이
    /// 실수로 호출 시 runtime crash 가 아닌 compile error → 안전.
    /// 향후 DJI SDK 통합 시 본 attribute 제거 + 실제 ProductionDJIControllerSource 주입.
    @available(*, unavailable, message: "DJI SDK 미통합 — init(bridge:source:) 와 MockDJIController 사용. SDK 통합 시 cycle 91+ 의 절차 따라 적용.")
    public convenience init(bridge: WalkLabRCBridge?) {
        // unavailable 어트리뷰트로 compile 차단 — 본 body 는 unreachable.
        fatalError("unreachable")
    }

    /// 테스트 / 통합 진입점 — MockDJIController 또는 미래 production source 주입.
    public init(bridge: WalkLabRCBridge?, source: DJIControllerInputSource) {
        self.bridge = bridge
        self.source = source
    }

    // MARK: - Lifecycle

    /// 입력 polling 시작. 이미 실행 중이면 no-op.
    ///
    /// **주의**: GamepadPilotAdapter 와 달리 NotificationCenter observer 미등록 — DJI SDK
    /// 의 controller connect 알림은 SDK 마다 형식이 다르므로 production source 가 자체
    /// notification 을 controllerName 변동으로 surface. 본 adapter 는 매 poll 시 source 의
    /// snapshot 에서 controllerName 만 sync — 단순/일관.
    public func start(pollInterval: TimeInterval = 1.0 / 30.0) {
        guard !isRunning else { return }
        isRunning = true

        // 현재 연결된 컨트롤러 즉시 인식 — telemetry 전에 호출해서 정확한 이름 캡처.
        refreshConnectedController()

        // 사이클 213 telemetry — DJI adapter 활성화.
        // 사이클 214 critic MINOR-3: refreshConnectedController 후 호출 → 정확한 controller_name.
        Harness.shared.record(
            .pilotAdapterStarted, level: .info, actor: .user,
            data: ["source": AnyCodable("dji"),
                   "controller_name": AnyCodable(connectedControllerName ?? "none")]
        )

        // Polling — Timer.scheduledTimer 가 main RunLoop 에 자동 install.
        // 테스트에서는 start() 미호출 + pollOnce() 수동 호출.
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        pollTimer = timer
    }

    /// 입력 polling 정지 + 내부 상태 reset.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        // 사이클 213 telemetry — DJI adapter 비활성화.
        Harness.shared.record(
            .pilotAdapterStopped, level: .info, actor: .user,
            data: ["source": AnyCodable("dji")]
        )

        pollTimer?.invalidate()
        pollTimer = nil

        previousButtonState = .init()
        previousStickWasZero = true
    }

    // **주의**: deinit 미정의. `@MainActor` 클래스의 deinit 는 nonisolated 라
    // MainActor-isolated property 접근 불가. 정리는 stop() 에서 수행 — 호출자가
    // adapter 사용 종료 시 명시 stop() 호출 필요.

    // MARK: - Polling

    /// **테스트 entry point** + Timer callback. source 의 현재 상태를 읽어 bridge 에 전달.
    ///
    /// # 처리 순서 (Gamepad 사이클 62 — 코덱스 HIGH 동일 패턴)
    ///
    /// 1. button edge detection 먼저 — emergency 발화 시 즉시 return → stick 처리 skip.
    /// 2. 일반 button (preset / recovery) 은 stick 과 동시 발생 허용 (race 없음).
    /// 3. stick → handleMove (emergency 미발화 frame 만).
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

        // 1. Button edge detection 먼저 (emergency 우선순위 보장).
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

    private func processSticks(_ sticks: DJIControllerStickState, bridge: WalkLabRCBridge) {
        // Stick value: -1.0 ... 1.0 (DJI RC spec, normalized).
        // TelloRCMapper 는 -100..100 int 기대 — Gamepad adapter 와 동일 정규화.
        let lr = Int((sticks.leftX * 100).rounded())
        let fb = Int((sticks.leftY * 100).rounded())  // forward = +y
        let yaw = Int((sticks.rightX * 100).rounded())

        let cmd = TelloRCMapper.map(lr: lr, fb: fb, ud: 0, yaw: yaw, scale: stickScale)

        if cmd.isStop {
            // 이미 zero 였으면 spam 차단 — 한 번만 stop.
            if !previousStickWasZero {
                bridge.handleMove(cmd, from: .djiRC)
                lastActionLabel = "stick stop"
            }
            previousStickWasZero = true
        } else {
            bridge.handleMove(cmd, from: .djiRC)
            lastActionLabel = "stick move"
            previousStickWasZero = false
        }
    }

    /// 버튼 edge detection. emergency 가 발화되었으면 `true` 반환 → caller (`pollOnce`)
    /// 가 stick 처리 skip. 일반 버튼은 always `false` (stick 과 동시 발생 안전).
    ///
    /// **순서**: emergency 를 먼저 검사 — 같은 frame 에 preset+emergency 가 함께 눌리면
    /// emergency 만 fire 하고 preset 은 다음 frame 으로 미룸 (panic 일관성).
    @discardableResult
    private func processButtons(_ buttons: DJIControllerButtonState, bridge: WalkLabRCBridge) -> Bool {
        // Emergency edge 최우선 — fire 시 즉시 return.
        if buttons.returnToHome && !previousButtonState.returnToHome {
            bridge.handleEmergency(from: .djiRC)
            lastActionLabel = "emergency (RTH / Home)"
            return true
        }
        // 일반 버튼 — 동일 frame 다중 fire 허용.
        if buttons.pause && !previousButtonState.pause {
            bridge.handlePreset(.idle, from: .djiRC)
            lastActionLabel = "preset idle (Pause)"
        }
        if buttons.customC1 && !previousButtonState.customC1 {
            bridge.handleRecovery(from: .djiRC)
            lastActionLabel = "recovery (C1)"
        }
        return false
    }

    // MARK: - Controller binding

    private func refreshConnectedController() {
        let prev = connectedControllerName
        connectedControllerName = source.controllerName
        // 사이클 213 telemetry — DJI 컨트롤러 연결/해제 변경 감지.
        if prev != connectedControllerName {
            Harness.shared.record(
                .pilotControllerChanged, level: .info, actor: .system,
                data: ["source": AnyCodable("dji"),
                       "controller_name": AnyCodable(connectedControllerName ?? "none"),
                       "connected": AnyCodable(connectedControllerName != nil)]
            )
        }
    }
}

// MARK: - DJIControllerInputSource protocol (테스트 추상화)

/// DJI 컨트롤러 입력 source 의 추상화. 향후 실 DJI Mobile SDK / Onboard SDK 또는
/// `MockDJIController`.
///
/// `snapshot()` 은 호출 시점의 stick + button 상태를 한 번에 반환 — race-free.
/// `controllerName` 은 사용자 표시 용 (예: "DJI RC Pro", "DJI Smart Controller").
@MainActor
public protocol DJIControllerInputSource: AnyObject {
    /// 현재 연결된 controller 의 product name. nil = 미연결.
    var controllerName: String? { get }

    /// 현재 stick + button 상태 캡쳐.
    func snapshot() -> DJIControllerSnapshot
}

/// adapter 가 polling 1회에 받는 입력 상태.
public struct DJIControllerSnapshot: Equatable, Sendable {
    public let controllerName: String?
    public let sticks: DJIControllerStickState
    public let buttons: DJIControllerButtonState

    public init(
        controllerName: String?,
        sticks: DJIControllerStickState,
        buttons: DJIControllerButtonState
    ) {
        self.controllerName = controllerName
        self.sticks = sticks
        self.buttons = buttons
    }

    public static let neutral = DJIControllerSnapshot(
        controllerName: nil,
        sticks: .neutral,
        buttons: .init()
    )
}

/// 두 stick 의 현재 좌표 (-1.0 ... 1.0).
///
/// DJI Mobile SDK 의 `DJIRCHardwareJoystickState` 는 -660..660 raw range 를 쓰지만 본
/// protocol 추상화 단계에서는 Gamepad adapter 와 동일하게 -1.0..1.0 으로 정규화 — bridge
/// 의 `TelloRCMapper` 가 동일 변환.
public struct DJIControllerStickState: Equatable, Sendable {
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

    public static let neutral = DJIControllerStickState()
}

/// 버튼 down 상태 — adapter 가 edge-trigger 판정에 사용.
///
/// DJI RC Pro / Smart Controller 의 hardware 버튼 매핑 — SDK 통합 시 raw event 를 본
/// struct 로 정규화. 추가 버튼 (C2, FN 등) 은 후속 phase 에서 확장.
public struct DJIControllerButtonState: Equatable, Sendable {
    /// RTH (Return-to-Home) 버튼 — emergency.
    /// drone 에서 "긴급 회항" 의미 → robot 에서 "긴급 정지" 로 매핑.
    public var returnToHome: Bool = false
    /// Pause / Stop 버튼 — preset idle.
    public var pause: Bool = false
    /// C1 (사용자 정의 버튼 1) — recovery.
    /// emergency 후 복구 진입점 — Gamepad 의 START 와 동일 역할.
    public var customC1: Bool = false
    /// C2 (사용자 정의 버튼 2) — 예약 (현재 미할당).
    public var customC2: Bool = false

    public init() {}
}
