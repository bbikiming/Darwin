import Foundation

/// 범용 게임패드 입력 → 로봇 의도 매핑의 물리 입력 기술자.
///
/// DJI `DJIInputBinding` 의 axis-as-enum 을 **Int 인덱스** 로 일반화.
/// GCController 표준 축/버튼 인덱스를 그대로 사용하므로 HID 폴백 경로와 동일
/// 인덱스 체계를 공유한다.
///
/// # 표준 인덱스 관례 (Xbox / RG G01 레이아웃)
///
/// **축 (axis)**
/// - 0 = LS X (좌스틱 가로)
/// - 1 = LS Y (좌스틱 세로, –위/+아래)
/// - 2 = RS X (우스틱 가로)
/// - 3 = RS Y (우스틱 세로)
/// - 4 = LT (왼쪽 트리거, 0..1)
/// - 5 = RT (오른쪽 트리거, 0..1)
///
/// **버튼 (button)**
/// - 0 = A, 1 = B, 2 = X, 3 = Y
/// - 4 = LB, 5 = RB
/// - 6 = View(Back), 7 = Menu(Start)
/// - 8 = LSB(좌스틱 클릭), 9 = RSB(우스틱 클릭)
/// - 10 = D-pad ↑, 11 = D-pad ↓, 12 = D-pad ←, 13 = D-pad →
public enum ControllerBinding: Codable, Hashable, Sendable {
    /// 아날로그 축 — 인덱스 + 방향성.
    /// polarity positive → 양의 방향이 동작 유발 (예: LS Y 위로 당기면 negative → moveForward 는 .negative).
    case axis(index: Int, polarity: Polarity)
    /// 디지털 버튼 — 인덱스.
    case button(index: Int)
    /// 명시 비활성 — 매핑 없음.
    case unbound

    // MARK: - Polarity

    /// 아날로그 축의 동작 방향.
    public enum Polarity: String, Codable, CaseIterable, Sendable {
        case positive = "+"
        case negative = "−"

        public var humanDescription: String {
            self == .positive ? "앞쪽/오른쪽" : "뒤쪽/왼쪽"
        }
    }

    // MARK: - Helpers

    /// 사용자에게 표시하는 짧은 라벨.
    public var displayLabel: String {
        switch self {
        case .axis(let idx, let pol):
            return "Axis \(idx) \(pol.rawValue)"
        case .button(let idx):
            return "Button \(idx)"
        case .unbound:
            return "—"
        }
    }

    /// 비활성 여부.
    public var isUnbound: Bool {
        if case .unbound = self { return true }
        return false
    }
}
