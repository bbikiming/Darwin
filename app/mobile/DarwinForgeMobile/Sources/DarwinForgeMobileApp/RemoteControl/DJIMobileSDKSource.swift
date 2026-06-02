import Foundation
import MobilePilotKit

/// **Phase B placeholder** — DJI Mobile SDK iOS bridge source.
///
/// DJI Mobile SDK is not yet vendored into this Swift Package — adding it
/// requires a static / xcframework artifact and entitlement plumbing per
/// DJI Developer guidelines. Until that happens, the production constructor
/// is gated with `@available(*, unavailable, ...)` so any accidental call
/// site fails to compile rather than silently no-op at runtime.
///
/// # Mirror of `DJIControllerAdapter` on macOS
///
/// `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/DJI/DJIControllerAdapter.swift`
/// uses the same `@available` gate — the iOS side adopts the exact pattern
/// so both platforms surface SDK adoption as a single, well-typed migration.
///
/// # Once the SDK lands
///
/// 1. Add the DJI SDK SPM/binary dependency to `Package.swift`.
/// 2. Remove the `@available(*, unavailable, ...)` attribute.
/// 3. Implement `start()` / `stop()` to register DJI RemoteController joystick
///    callbacks and translate them into `ExternalControllerSnapshot`.
/// 4. Drop `DJIMobileSDKSourceFactory.makeStubFailure` in favour of the real
///    factory.
@MainActor
public final class DJIMobileSDKSource: ExternalControllerInputSource {

    public var controllerName: String? { nil }

    @available(*, unavailable,
               message: "DJI Mobile SDK is not vendored yet. Use GameControllerSource for MFi-compatible DJI RC models, or add the DJI Mobile SDK package and remove this attribute.")
    public init() {
        fatalError("unreachable — gated by @available(unavailable)")
    }

    /// Test-only initialiser. Real adapter wiring should never reach this.
    /// Marked `internal` so production targets cannot accidentally call it.
    internal init(testOnly: ()) {}

    public func snapshot() -> ExternalControllerSnapshot { .neutral }
    public func start() {}
    public func stop() {}
}
