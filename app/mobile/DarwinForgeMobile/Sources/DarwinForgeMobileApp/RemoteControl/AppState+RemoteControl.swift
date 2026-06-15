import Foundation
import MobilePilotKit

/// `AppState` exposes `streamWalk`, `releaseWalk`, and `performRecover` with
/// signatures that already match the bridge protocol. `performEStop(reason:)`
/// carries a default argument that doesn't satisfy a no-argument requirement,
/// so we add a zero-arg wrapper that forwards `.user` — the same default the
/// adapter would otherwise have to thread by hand.
extension AppState: RemoteControlBridge {
    public func performEStop() async {
        await performEStop(reason: .user)
    }
}
