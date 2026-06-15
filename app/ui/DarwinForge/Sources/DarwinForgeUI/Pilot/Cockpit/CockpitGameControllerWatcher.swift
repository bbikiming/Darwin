import Foundation
import GameController
import SwiftUI

/// MFi/BT 게임패드 (Xbox / DualSense / DJI RC MFi) 입력을 polling 해서 cockpit
/// state 에 넘기는 lightweight 어댑터.
///
/// `GamepadPilotAdapter` (WalkLab) 와는 별도 — cockpit 은 standalone 화면이라
/// 자체 polling loop 를 가진다. 30 Hz 폴링, `start()` / `stop()` 으로 lifecycle
/// 관리. NotificationCenter 로 연결/해제 감지하여 `state.connectedController` 갱신.
@MainActor
public final class CockpitGameControllerWatcher {

    private weak var state: CockpitState?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var bound: GCController?
    /// **CRITICAL #3 fix (code review)**: 버튼 edge-trigger 상태. 종전엔
    /// `state.emergencyAt == nil` 으로 fire 여부 결정 → 한 번 set 되면 이후 emergency
    /// 가 영원히 비활성. button press → release → press 의 사이클 추적으로 전환.
    private var prevButtonB: Bool = false
    private var prevButtonY: Bool = false

    public init(state: CockpitState) {
        self.state = state
    }

    public func start(pollInterval: TimeInterval = 1.0 / 30.0) {
        guard pollTimer == nil else { return }

        bind(GCController.current ?? GCController.controllers().first)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                if let c = note.object as? GCController { self?.bind(c) }
            }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                if let c = note.object as? GCController, c === self?.bound {
                    self?.bind(nil)
                    // S2: 끊김 failsafe — stale 스틱 명령 즉시 zero (로봇 보행 정지).
                    self?.state?.inputSourceLost()
                }
            }
        })

        // L3: .common 모드 — 트래킹 중에도 게임패드 폴 + B 버튼 E-STOP 감지 지속.
        pollTimer = CockpitTimers.repeating(pollInterval) { [weak self] in
            self?.pollOnce()
        }
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
        observers.removeAll()
        bind(nil)
    }

    private func bind(_ controller: GCController?) {
        bound = controller
        state?.setController(name: controller?.vendorName ?? controller?.productCategory)
    }

    private func pollOnce() {
        guard let state, let pad = bound?.extendedGamepad else { return }
        // GameController convention: yAxis +1 = up.
        // VirtualJoystickMapper expects y = -1 = up (forward), so we flip.
        let lx = Double(pad.leftThumbstick.xAxis.value)
        let ly = Double(pad.leftThumbstick.yAxis.value) // GC native: +1 up
        let rx = Double(pad.rightThumbstick.xAxis.value)
        // Translate to DSJoystick convention before handing to apply():
        //   forward (stick up) → leftY = -1.
        state.apply(leftX: lx, leftY: -ly, turn: rx, from: .gamepad)
        // Button: B = emergency, Y = recover. Edge-trigger (rising edge only)
        // 으로 hold 시 spam 차단 + 한 번 emergency 후 release/repress 정상 작동.
        let curB = pad.buttonB.isPressed
        if curB && !prevButtonB { state.triggerEmergency() }
        prevButtonB = curB
        let curY = pad.buttonY.isPressed
        if curY && !prevButtonY { state.triggerRecovery() }
        prevButtonY = curY
    }
}
