#if canImport(IOKit)
import Foundation
import SwiftUI

/// `DJIVirtualJoystickHIDClient` 를 cockpit 에 묶는 thin adapter.
///
/// 책임:
/// - HID client 의 raw report 를 받아 `DJIVirtualJoystickMapper` 로 변환.
/// - 변환 결과를 `CockpitState.apply(leftX:leftY:turn:from:)` 로 push (input source =
///   `.djiRC` — `InputSource` enum 에 이미 존재).
/// - 버튼 edge-trigger 로 emergency / recover 발화.
/// - `@Published` 상태 (`isStreaming`, `axisDiagnostics`) 를 노출해 cockpit 패널이
///   live 진단 표시 가능.
///
/// # Mock 데모 / GameController 와 공존
///
/// `CockpitGameControllerWatcher` (MFi 컨트롤러) 와 본 watcher 는 같은 cockpit 에
/// 동시 active 가능하다. 두 source 가 동시에 stick 입력을 push 해도 cockpit 은
/// 마지막 호출만 보존하므로 (race-free, `@MainActor` 직렬화), 한쪽이 idle 이면
/// 다른 쪽이 자연스럽게 통제권을 가진다. 단 mock demo 가 `startMockDemo()` 로
/// active 인 상태에서는 본 watcher 가 입력을 받지 않아야 사용자 혼란을 피할 수
/// 있으므로 cockpit 패널이 mock 진입 시 본 watcher 를 `pauseStreaming()` 시킨다.
@MainActor
public final class DJIVirtualJoystickWatcher: ObservableObject {

    // MARK: - Observable state

    /// HID 디바이스가 매칭되어 stream 이 활성인가.
    @Published public private(set) var isStreaming: Bool = false
    /// 사용자가 cockpit UI 에서 stream 을 일시 정지할 수 있다.
    @Published public var isPaused: Bool = false
    /// 가장 최근 디코딩된 report — 진단 UI 가 axis raw 값을 보여줄 때 사용.
    @Published public private(set) var lastReport: DJIVirtualJoystickReport?
    /// `lastReport` 가 도착한 시각 — staleness 표시.
    @Published public private(set) var lastReportAt: Date?
    /// 매칭된 디바이스 이름. nil = 매칭 안 됨.
    @Published public private(set) var connectedName: String?
    /// 마지막으로 발사된 cockpit-level 액션 라벨.
    @Published public private(set) var lastAction: String?

    /// 사용자가 cockpit 패널에서 토글하는 부호 반전.
    @Published public var inversion: DJIVirtualJoystickMapper.Inversion = .djiDefault

    // MARK: - Dependencies

    private weak var cockpit: CockpitState?
    private let client: DJIVirtualJoystickHIDClient

    // MARK: - Edge-trigger state

    private var previousButtons: [Bool] = Array(repeating: false, count: 24)
    private var previousStickWasZero: Bool = true

    public init(cockpit: CockpitState,
                clientOverride: DJIVirtualJoystickHIDClient? = nil) {
        // default arg 가 main-actor-isolated init() 을 호출하면 Swift 6 strict
        // concurrency 에서 caller (SwiftUI View struct init) 의 nonisolated 컨텍
        // 스트와 충돌. 본 클래스 자체가 @MainActor 라 내부에서 호출은 안전.
        self.cockpit = cockpit
        let resolved = clientOverride ?? DJIVirtualJoystickHIDClient()
        self.client = resolved

        resolved.onConnect = { [weak self] name in
            guard let self else { return }
            self.connectedName = name
            self.isStreaming = true
            self.cockpit?.setController(name: name)
        }
        resolved.onDisconnect = { [weak self] in
            guard let self else { return }
            self.connectedName = nil
            self.isStreaming = false
            self.cockpit?.setController(name: nil)
        }
        resolved.onReport = { [weak self] report in
            self?.handle(report: report)
        }
    }

    // MARK: - Lifecycle (cockpit panel calls these)

    public func start() {
        client.start()
    }

    public func stop() {
        client.stop()
        connectedName = nil
        isStreaming = false
        lastReport = nil
    }

    /// Mock 데모 진입 시 cockpit 패널이 호출 → 본 watcher 가 입력 무시.
    public func pauseStreaming() {
        isPaused = true
    }

    public func resumeStreaming() {
        isPaused = false
    }

    // MARK: - Inversion mutators (Panel 의 toggle binding 진입점)
    //
    // `@Published var inversion` 의 nested property 를 직접 수정하면
    // `@Published` 가 KVO 알림을 emit 하지 않는다 (struct 의 mutating var 는
    // self 재할당이 아니라 in-place 변경이라). 따라서 SwiftUI Binding 에서
    // `hidWatcher.inversion.invertForward = $0` 가 view rerender 를 트리거 안
    // 한다. 본 메소드들은 새 Inversion 인스턴스로 교체해 published 알림을
    // 명시 발사한다.

    public func toggleInvertForward(_ on: Bool) {
        inversion = DJIVirtualJoystickMapper.Inversion(
            invertForward: on,
            invertLateral: inversion.invertLateral,
            invertTurn:    inversion.invertTurn)
    }

    public func toggleInvertLateral(_ on: Bool) {
        inversion = DJIVirtualJoystickMapper.Inversion(
            invertForward: inversion.invertForward,
            invertLateral: on,
            invertTurn:    inversion.invertTurn)
    }

    public func toggleInvertTurn(_ on: Bool) {
        inversion = DJIVirtualJoystickMapper.Inversion(
            invertForward: inversion.invertForward,
            invertLateral: inversion.invertLateral,
            invertTurn:    on)
    }

    // MARK: - Binding profile (user-defined key mapping)

    /// 사용자가 sheet 에서 편집한 binding profile. nil 이면 종전 `inversion` 기반
    /// hardcoded mapping 사용 (backward compat). profile 이 set 되면 report 처리에서
    /// 본 profile 의 axis/button mapping 으로 stick 합성 + safety action 발사.
    @Published public private(set) var bindingProfile: DJIBindingProfile?

    public func applyBindingProfile(_ profile: DJIBindingProfile) {
        self.bindingProfile = profile
    }

    // MARK: - Report handling

    private func handle(report: DJIVirtualJoystickReport) {
        lastReport = report
        lastReportAt = Date()

        // 사용자가 일시 정지했으면 stick 도, button 도 cockpit 으로 전달 안 함.
        guard !isPaused, let cockpit else { return }

        // Stick 매핑 — profile 우선, 없으면 종전 inversion 기반 매핑.
        let stick: DJIVirtualJoystickMapper.StickInput
        if let profile = bindingProfile {
            stick = DJIVirtualJoystickMapper.map(report, profile: profile)
        } else {
            stick = DJIVirtualJoystickMapper.map(report, inversion: inversion)
        }
        let isZero = stick.leftX == 0 && stick.leftY == 0 && stick.turn == 0
        if !isZero {
            cockpit.apply(leftX: stick.leftX,
                          leftY: stick.leftY,
                          turn:  stick.turn,
                          from:  .djiRC)
            lastAction = "stick"
            previousStickWasZero = false
        } else if !previousStickWasZero {
            // 한 번만 stop 전달.
            cockpit.apply(leftX: 0, leftY: 0, turn: 0, from: .djiRC)
            lastAction = "stop"
            previousStickWasZero = true
        }

        // 머리 동작 할당 — profile 경로에서만 존재. rate 모드라 stick 의 edge-trigger
        // 와 독립적으로 매 report norm 을 전달해 integrate() 가 각속도로 적분한다.
        // (norm 이 0이면 적분이 멈춰 머리 각도 유지 — 별도 stop edge 불필요.)
        if bindingProfile != nil {
            cockpit.applyHead(panNorm: stick.headPanNorm,
                              tiltNorm: stick.headTiltNorm)
        }

        // Button edge-trigger — profile 우선, 없으면 hardcoded mapping.
        let actions: DJIVirtualJoystickMapper.ButtonActions
        let prevActions: DJIVirtualJoystickMapper.ButtonActions
        if let profile = bindingProfile {
            actions = DJIVirtualJoystickMapper.buttonActions(report: report, profile: profile)
            let prevReport = DJIVirtualJoystickReport(
                axisX: 0, axisY: 0, axisZ: 0, axisRx: 0, axisRy: 0,
                buttons: previousButtons)
            prevActions = DJIVirtualJoystickMapper.buttonActions(report: prevReport,
                                                                 profile: profile)
        } else {
            actions = DJIVirtualJoystickMapper.ButtonActions.from(report.buttons)
            prevActions = DJIVirtualJoystickMapper.ButtonActions.from(previousButtons)
        }
        if actions.emergencyStop && !prevActions.emergencyStop {
            cockpit.triggerEmergency()
            cockpit.release()
            lastAction = "emergency"
            previousStickWasZero = true
        } else if actions.recover && !prevActions.recover {
            cockpit.triggerRecovery()
            lastAction = "recover"
        }
        previousButtons = report.buttons
    }
}
#endif
