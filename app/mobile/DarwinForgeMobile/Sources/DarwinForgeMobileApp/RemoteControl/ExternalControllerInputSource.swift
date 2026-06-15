import Foundation
import MobilePilotKit

/// External controller input source — abstraction over a physical controller.
///
/// Two production implementations live alongside this protocol:
/// - `GameControllerSource` — Apple `GameController.framework` (MFi / DualSense /
///   Xbox / DJI RC models that expose themselves as MFi over BT/USB). Always
///   available on iOS 17+.
/// - `DJIMobileSDKSource` — DJI Mobile SDK bridge. Marked `@available(*,
///   unavailable, ...)` until the SDK package is integrated (Phase B+).
///
/// The `MockExternalController` lives in the same folder and is used in unit
/// tests so the adapter logic can be exercised on CI without a physical device.
///
/// # 비유
///
/// USB serial port — the host code only sees a byte stream, not which device
/// is plugged in. Same here: the adapter polls `snapshot()` 30 Hz and routes
/// the normalised state to `streamWalk` regardless of which controller is
/// actually attached.
@MainActor
public protocol ExternalControllerInputSource: AnyObject {
    /// Display name of the connected controller. `nil` = no controller.
    /// Examples: "DualSense Wireless Controller", "Xbox Wireless Controller",
    /// "DJI RC Pro".
    var controllerName: String? { get }

    /// Snapshot of the controller state at the moment of the call. Pure read —
    /// the adapter calls this 30 Hz from a Timer to keep semantics simple
    /// (race-free) without forcing every source to push events.
    func snapshot() -> ExternalControllerSnapshot

    /// Optional hook the adapter calls when it starts polling. Sources that
    /// drive their own event loop (e.g. DJI SDK callbacks) can use this to
    /// register listeners; sources that only respond to polling can ignore it.
    func start()

    /// Tear-down hook paired with `start()`.
    func stop()
}

public struct ExternalControllerSnapshot: Equatable, Sendable {
    public let controllerName: String?
    public let sticks: ExternalControllerStickState
    public let buttons: ExternalControllerButtonState

    public init(controllerName: String?,
                sticks: ExternalControllerStickState,
                buttons: ExternalControllerButtonState) {
        self.controllerName = controllerName
        self.sticks = sticks
        self.buttons = buttons
    }

    public static let neutral = ExternalControllerSnapshot(
        controllerName: nil,
        sticks: .neutral,
        buttons: .init())
}

/// Stick coordinates normalised to `[-1, +1]`.
///
/// # Convention (DSJoystick / CommandBuilder.walkFreeform alignment)
/// - `leftX`: +1 = stick right, -1 = stick left → joystick X
/// - `leftY`: +1 = stick up = forward, -1 = stick down = backward
///   (NB: GameController.framework reports +1 up natively; we flip if needed
///    in the source so the adapter always sees the convention above)
/// - `rightX`: +1 = stick right = right turn, -1 = stick left = left turn
public struct ExternalControllerStickState: Equatable, Sendable {
    public let leftX: Float
    public let leftY: Float
    public let rightX: Float
    public let rightY: Float

    public init(leftX: Float = 0, leftY: Float = 0,
                rightX: Float = 0, rightY: Float = 0) {
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
    }

    public static let neutral = ExternalControllerStickState()
}

/// Button down-state. The adapter performs edge detection (1-shot per press).
///
/// # Mapping rationale
/// - `emergencyStop`: B button / Circle (PlayStation) / RTH on DJI RC.
///   Drone "return-to-home" maps semantically to robot "emergency stop" — the
///   user reflex of pressing the panic button is preserved across device types.
/// - `recover`: Y button / Triangle (PlayStation) / C1 on DJI RC.
///   Used to clear an active e-stop and re-arm.
/// - `stopMotion`: A button / Cross (PlayStation) / Pause on DJI RC.
///   Stops walking (deadman release equivalent for the controller path).
/// - `ballTrackToggle`: X button / Square (PlayStation). 볼 트래킹(로봇 온보드 자동
///   헤드 추적) on/off 토글 — 누를 때마다 상태가 뒤집힌다 (2026-06-02).
public struct ExternalControllerButtonState: Equatable, Sendable {
    public var emergencyStop: Bool = false
    public var recover: Bool = false
    public var stopMotion: Bool = false
    public var ballTrackToggle: Bool = false

    public init(emergencyStop: Bool = false,
                recover: Bool = false,
                stopMotion: Bool = false,
                ballTrackToggle: Bool = false) {
        self.emergencyStop = emergencyStop
        self.recover = recover
        self.stopMotion = stopMotion
        self.ballTrackToggle = ballTrackToggle
    }
}

/// Pure mapping: `ExternalControllerSnapshot` → `WalkFreeformInput`.
///
/// Exposed separately so unit tests can pin down the maths without spinning
/// up a real adapter or controller.
public enum ExternalControllerStickMapper {

    /// Deadzone radius below which sticks are treated as centred. Matches
    /// `WalkFreeformInput.isMoving` (0.05) so adapter and command builder
    /// agree on what counts as "stop".
    public static let deadzone: Double = 0.05

    /// Map a snapshot to a freeform walk input.
    ///
    /// - `leftY` (joystick up) → forward (xMm > 0)
    /// - `leftX` (joystick right) → lateral right (yMm > 0)
    /// - `rightX` (right stick right) → right turn (aDeg < 0 — matches
    ///   `WalkPreset.turnRight.aDeg = -8`)
    /// - `speedScale` is provided by the caller (typically the UI speed tier).
    public static func map(_ snapshot: ExternalControllerSnapshot,
                           speedScale: Double = 1.0) -> WalkFreeformInput {
        let lx = applyDeadzone(Double(snapshot.sticks.leftX))
        let ly = applyDeadzone(Double(snapshot.sticks.leftY))
        let rx = applyDeadzone(Double(snapshot.sticks.rightX))

        // CommandBuilder.walkFreeform reads `input.y` with the convention that
        // -1 = up = forward (DSJoystick). GameController.framework reports +1
        // up for `yAxis.value`, so the source flips the sign before populating
        // `leftY` — by the time the snapshot arrives here, `leftY = +1` means
        // "stick up = forward" too. We pass it through with the joystick-style
        // sign so the same mapping works for both UI joystick and physical.
        return WalkFreeformInput(x: lx,
                                 y: -ly,
                                 turn: rx,
                                 speedScale: speedScale)
    }

    private static func applyDeadzone(_ v: Double) -> Double {
        abs(v) < deadzone ? 0 : v
    }
}
