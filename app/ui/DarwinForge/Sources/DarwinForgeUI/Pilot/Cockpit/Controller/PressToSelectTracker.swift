import Foundation

/// 실패드 입력 → 다이어그램 컨트롤 **선택** (Steam Input 패턴, 설계 §B).
///
/// Listen(press-to-bind)과 달리 바인딩을 바꾸지 않고 선택만 한다. 엣지 기반 —
/// 같은 입력을 누르고 있는 동안에는 재선택 이벤트를 내지 않아 인스펙터가
/// 떨리지 않는다. 순수 값 타입: `updated(with:)` 가 새 트래커를 반환한다.
public struct PressToSelectTracker: Equatable, Sendable {

    /// 직전 프레임에서 감지된 바인딩 — 엣지 비교 기준.
    private let lastDetected: ControllerBinding?

    public init() {
        self.lastDetected = nil
    }

    private init(lastDetected: ControllerBinding?) {
        self.lastDetected = lastDetected
    }

    /// 스냅샷을 반영한 (새 트래커, 새 선택). 새 입력 엣지가 없으면 선택은 nil.
    public func updated(
        with snapshot: ControllerSnapshot
    ) -> (tracker: PressToSelectTracker, newSelection: ControllerBinding?) {
        let detected = ControllerBindingCapture.detect(snapshot)
        let next = PressToSelectTracker(lastDetected: detected)
        guard let detected, detected != lastDetected else { return (next, nil) }
        return (next, detected)
    }
}
