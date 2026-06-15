import Foundation
import MobilePilotKit

/// Deterministic test source. Tests push state via `setState(...)` and the
/// adapter polls `snapshot()` exactly as it would with a real controller.
@MainActor
public final class MockExternalController: ExternalControllerInputSource {

    public var controllerName: String?

    private var sticks: ExternalControllerStickState = .neutral
    private var buttons: ExternalControllerButtonState = .init()
    public private(set) var startCalls: Int = 0
    public private(set) var stopCalls: Int = 0

    public init(controllerName: String? = "MockController") {
        self.controllerName = controllerName
    }

    public func snapshot() -> ExternalControllerSnapshot {
        ExternalControllerSnapshot(controllerName: controllerName,
                                   sticks: sticks,
                                   buttons: buttons)
    }

    public func start() { startCalls += 1 }
    public func stop() { stopCalls += 1 }

    // MARK: - Test driving API

    /// Set the next snapshot the adapter will read. Independent fields so a
    /// test can move one stick without disturbing the others.
    public func setSticks(leftX: Float = 0, leftY: Float = 0,
                          rightX: Float = 0, rightY: Float = 0) {
        sticks = ExternalControllerStickState(leftX: leftX, leftY: leftY,
                                              rightX: rightX, rightY: rightY)
    }

    public func setButtons(emergencyStop: Bool = false,
                           recover: Bool = false,
                           stopMotion: Bool = false,
                           ballTrackToggle: Bool = false) {
        buttons = ExternalControllerButtonState(emergencyStop: emergencyStop,
                                                recover: recover,
                                                stopMotion: stopMotion,
                                                ballTrackToggle: ballTrackToggle)
    }

    public func reset() {
        sticks = .neutral
        buttons = .init()
    }
}
