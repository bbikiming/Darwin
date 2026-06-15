import Foundation
import MobilePilotKit

/// Thin protocol the controller adapter calls into.
///
/// `AppState` conforms to this so the adapter does not need a direct
/// dependency on `AppState` (which lets us spin up a stub bridge in tests
/// instead of the whole app state object).
@MainActor
public protocol RemoteControlBridge: AnyObject {
    /// Send a freeform walk frame. Adapter calls this ~30Hz while the user
    /// holds a stick; `AppState.streamWalk` throttles internally to ~10Hz.
    func streamWalk(_ input: WalkFreeformInput) async

    /// User released the sticks AND there is no rotation input.
    func releaseWalk() async

    /// User pressed the emergency-stop button on the controller.
    func performEStop() async

    /// User pressed the recover / re-arm button on the controller.
    func performRecover() async

    /// 볼 트래킹 (2026-06-02): 조종기 버튼(X)으로 로봇 온보드 헤드 추적 on/off 토글.
    func toggleBallTracking() async
}
