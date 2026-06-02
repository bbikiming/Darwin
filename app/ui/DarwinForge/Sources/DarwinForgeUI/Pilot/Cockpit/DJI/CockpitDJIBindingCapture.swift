import Foundation

/// **Listen-mode capture** — Unity Input System 의 "Press any button" / Steam
/// Input Configurator 의 click-to-bind 와 동일 패턴.
///
/// 사용자가 sheet 에서 한 action 의 "Listen" 버튼을 누르면, 본 detector 가 다음
/// 들어오는 `DJIVirtualJoystickReport` 들에서 가장 의미 있는 입력 한 개를 찾아낸다.
///
/// # 우선순위 (HID 의 동시 입력 disambiguation)
///
/// 1. **Button 우선** — 사용자가 명시적으로 누른 button 은 가장 명백한 의도.
/// 2. **그 다음 가장 큰 axis** — 둘 이상 axis 가 동시에 움직이면 (|value| 최대) 하나만.
/// 3. **deadzone 이하는 무시** — 자연스러운 stick drift 흡수.
///
/// 본 struct 는 순수 함수형 — state 없고 단일 report 입력 → 단일 binding 출력 또는 nil.
public enum DJIBindingCapture {

    /// Listen mode 의 deadzone — `DJIVirtualJoystickMapper.deadzone` (0.05) 보다 약간
    /// 크게 (0.30) 잡아 사용자가 명백히 stick 을 움직였을 때만 감지. drift 가 의도로
    /// 잘못 잡히는 false positive 차단.
    public static let listenDeadzone: Double = 0.30

    /// 한 report 에서 가장 의미 있는 입력을 추출. 의미 있는 입력이 없으면 nil.
    public static func detect(_ report: DJIVirtualJoystickReport) -> DJIInputBinding? {
        // 1. Button 우선.
        for (i, pressed) in report.buttons.enumerated() where pressed {
            return .button(i)
        }
        // 2. Axis — 가장 큰 magnitude.
        let axes: [(DJIInputBinding.Axis, Double)] = [
            (.x,  report.axisX),
            (.y,  report.axisY),
            (.z,  report.axisZ),
            (.rx, report.axisRx),
            (.ry, report.axisRy),
        ]
        let best = axes.max { abs($0.1) < abs($1.1) }
        guard let (axis, value) = best, abs(value) >= listenDeadzone else {
            return nil
        }
        return .axis(axis, polarity: value > 0 ? .positive : .negative)
    }
}
