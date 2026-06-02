import Foundation
import GameController
import MobilePilotKit

/// Production source backed by `GameController.framework`.
///
/// Auto-detects any MFi-compatible controller connected via Bluetooth or USB,
/// including DualSense, DualShock 4, Xbox Wireless Controller, and the subset
/// of DJI remote controllers (DJI RC, RC Pro) that expose themselves as MFi
/// HID devices when paired in "MFi controller" mode.
///
/// # Lifecycle
///
/// - `start()`: subscribes to `GCControllerDidConnect` / `…DidDisconnect`
///   notifications and binds to `GCController.current` if one is already
///   attached. `snapshot()` reads the latest `extendedGamepad` state directly
///   from the GameController API on each poll — no caching required.
/// - `stop()`: removes observers and clears the bound controller. Safe to call
///   multiple times.
///
/// # Sign convention
///
/// `GameController.framework` reports `yAxis.value = +1` when the stick is
/// pushed up. The `ExternalControllerStickMapper.map(...)` function expects
/// `leftY = +1` to also mean "up = forward", so we forward the value as-is and
/// let the mapper invert sign for `WalkFreeformInput.y` (DSJoystick convention,
/// `y = -1` is forward).
@MainActor
public final class GameControllerSource: ExternalControllerInputSource {

    public init() {}

    public private(set) var controllerName: String?

    /// Current controller bound to the source. nil until a notification or an
    /// explicit `start()` discovers one.
    private weak var bound: GCController?
    private var observers: [NSObjectProtocol] = []

    public func start() {
        // Pick up an already-connected controller before any notifications fire.
        bind(GCController.current ?? GCController.controllers().first)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                if let controller = note.object as? GCController {
                    self.bind(controller)
                }
            }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                if let disconnected = note.object as? GCController,
                   disconnected === self.bound {
                    self.bind(nil)
                }
            }
        })
    }

    public func stop() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        bind(nil)
    }

    public func snapshot() -> ExternalControllerSnapshot {
        guard let pad = bound?.extendedGamepad else {
            return ExternalControllerSnapshot(controllerName: controllerName,
                                              sticks: .neutral,
                                              buttons: .init())
        }
        let sticks = ExternalControllerStickState(
            leftX: pad.leftThumbstick.xAxis.value,
            // Keep GCController native sign: +1 = stick up.
            // ExternalControllerStickMapper flips this into joystick convention.
            leftY: pad.leftThumbstick.yAxis.value,
            rightX: pad.rightThumbstick.xAxis.value,
            rightY: pad.rightThumbstick.yAxis.value)
        let buttons = ExternalControllerButtonState(
            emergencyStop: pad.buttonB.isPressed,
            recover: pad.buttonY.isPressed,
            stopMotion: pad.buttonA.isPressed,
            // 볼 트래킹 (2026-06-02): X/Square — 빈 버튼. 누를 때마다 추적 on/off 토글.
            ballTrackToggle: pad.buttonX.isPressed)
        return ExternalControllerSnapshot(
            controllerName: controllerName,
            sticks: sticks,
            buttons: buttons)
    }

    // MARK: - Private

    private func bind(_ controller: GCController?) {
        bound = controller
        controllerName = controller?.vendorName ?? controller?.productCategory
    }
}
