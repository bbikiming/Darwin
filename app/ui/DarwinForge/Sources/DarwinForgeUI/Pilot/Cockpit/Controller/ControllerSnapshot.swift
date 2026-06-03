import Foundation

/// 컨트롤러 소스(GCController / HID 폴백)가 매 frame 산출하는 **정규화된** 입력 스냅샷.
///
/// 소스 종류와 무관하게 동일 표현을 갖는 값 타입 — `CockpitControllerSource` 가 이
/// 타입만 노출하므로 리졸버/드라이버는 GC 든 HID 든 차이를 모른다.
///
/// # 인덱스 관례
/// `ControllerBinding` 의 표준 인덱스 체계를 그대로 따른다.
///
/// **축 (axes, 각 [-1, 1])**
/// - 0 = LS X, 1 = LS Y, 2 = RS X, 3 = RS Y, 4 = LT, 5 = RT
///   Y축(1·3)은 **화면 관례 −위/+아래** — M1 프리셋(`moveForward = axis(1, negative)`)과
///   일치. GC native(위=+1)와 반대이므로 `GCControllerSource` 가 Y 부호를 뒤집어 채운다.
///
/// **버튼 (buttons, bool)**
/// - 0 = A, 1 = B, 2 = X, 3 = Y, 4 = LB, 5 = RB
/// - 6 = View, 7 = Menu, 8 = LSB, 9 = RSB
/// - 10 = D↑, 11 = D↓, 12 = D←, 13 = D→
public struct ControllerSnapshot: Equatable, Sendable {

    /// 표준 축 개수 (LS X/Y, RS X/Y, LT, RT).
    public static let standardAxisCount = 6
    /// 표준 버튼 개수 (A..Y, LB/RB, View/Menu, LSB/RSB, D-pad 4).
    public static let standardButtonCount = 14

    /// 정규화 축값 — 각 원소 [-1, 1] (트리거 4/5 는 [0, 1]).
    public let axes:    [Double]
    /// 디지털 버튼 눌림 상태.
    public let buttons: [Bool]

    public init(axes: [Double], buttons: [Bool]) {
        self.axes    = axes
        self.buttons = buttons
    }

    /// 모든 축 0, 모든 버튼 미눌림인 중립 스냅샷.
    public static let neutral = ControllerSnapshot(
        axes:    Array(repeating: 0.0, count: standardAxisCount),
        buttons: Array(repeating: false, count: standardButtonCount)
    )

    // MARK: - 안전 접근자

    /// `index` 축값 — 범위 밖이면 0 (방어적).
    public func axis(_ index: Int) -> Double {
        guard index >= 0, index < axes.count else { return 0.0 }
        return axes[index]
    }

    /// `index` 버튼 눌림 — 범위 밖이면 false (방어적).
    public func button(_ index: Int) -> Bool {
        guard index >= 0, index < buttons.count else { return false }
        return buttons[index]
    }
}
