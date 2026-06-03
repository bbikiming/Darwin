import Foundation
import GameController

/// `GCController`(MFi/BT 게임패드: Xbox / DualSense / Switch Pro / RG G01)를 표준
/// `ControllerSnapshot` 으로 노출하는 소스.
///
/// 기존 `CockpitGameControllerWatcher` 의 하드코딩 polling 을 프로토콜화 — 드라이버가
/// Mock 과 동일 인터페이스로 다룬다. 연결/해제는 `NotificationCenter` 구독.
///
/// # 축/버튼 매핑 (표준 인덱스 ↔ extendedGamepad)
/// - axis 0/1 = 좌스틱 X/Y, 2/3 = 우스틱 X/Y, 4/5 = LT/RT
/// - **Y축은 부호 반전** — GC native(위=+1) → snapshot(위=−1, 화면 관례).
/// - button 0..13 = A/B/X/Y, LB/RB, View/Menu, LSB/RSB, D-pad ↑↓←→.
@MainActor
public final class GCControllerSource: CockpitControllerSource {

    public private(set) var deviceKey:   String?
    public private(set) var displayName: String?
    public var onConnectionChange: (@MainActor (Bool) -> Void)?

    private weak var bound: GCController?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public var isConnected: Bool { bound?.extendedGamepad != nil }

    public func start() {
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
                }
            }
        })
    }

    public func stop() {
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
        observers.removeAll()
        bind(nil)
    }

    public func capture() -> ControllerSnapshot? {
        guard let pad = bound?.extendedGamepad else { return nil }
        // GC native Y: 위 = +1 → snapshot 관례(위 = −1)로 부호 반전.
        let axes: [Double] = [
            Double(pad.leftThumbstick.xAxis.value),
            -Double(pad.leftThumbstick.yAxis.value),
            Double(pad.rightThumbstick.xAxis.value),
            -Double(pad.rightThumbstick.yAxis.value),
            Double(pad.leftTrigger.value),
            Double(pad.rightTrigger.value),
        ]
        let buttons: [Bool] = [
            pad.buttonA.isPressed,
            pad.buttonB.isPressed,
            pad.buttonX.isPressed,
            pad.buttonY.isPressed,
            pad.leftShoulder.isPressed,
            pad.rightShoulder.isPressed,
            pad.buttonOptions?.isPressed ?? false,
            pad.buttonMenu.isPressed,
            pad.leftThumbstickButton?.isPressed ?? false,
            pad.rightThumbstickButton?.isPressed ?? false,
            pad.dpad.up.isPressed,
            pad.dpad.down.isPressed,
            pad.dpad.left.isPressed,
            pad.dpad.right.isPressed,
        ]
        return ControllerSnapshot(axes: axes, buttons: buttons)
    }

    // MARK: - 연결 바인딩

    private func bind(_ controller: GCController?) {
        let wasConnected = bound?.extendedGamepad != nil
        bound = controller
        // 모델 식별: productCategory 우선, vendorName 폴백 (CONN-02).
        displayName = controller?.vendorName ?? controller?.productCategory
        deviceKey   = controller.map { Self.deviceKey(for: $0) }
        let nowConnected = controller?.extendedGamepad != nil
        if nowConnected != wasConnected { onConnectionChange?(nowConnected) }
    }

    /// 모델명 → 프로파일 `deviceKey` 휴리스틱 (예: "gc.xbox", "gc.dualsense").
    private static func deviceKey(for controller: GCController) -> String {
        let id = (controller.productCategory).lowercased()
        if id.contains("dualsense") || id.contains("dualshock") { return "gc.dualsense" }
        if id.contains("xbox")                                   { return "gc.xbox" }
        if id.contains("switch")                                 { return "gc.switchpro" }
        return "gc.\(id.replacingOccurrences(of: " ", with: ""))"
    }
}
