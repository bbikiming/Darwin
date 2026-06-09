import CoreGraphics
import Foundation

// MARK: - ControllerCalloutCategory

/// 콜아웃 색 카테고리 — 설계 문서 §A 의 색 코딩 규칙 (docs/design/controller-mapping-uiux.md).
/// 이동·회전 = 청록, 머리 = 보라, 안전 = 빨강, 보조(데드맨/터보) = 황색, 미설정 = 회색 점선.
public enum ControllerCalloutCategory: Equatable, Sendable {
    case movement
    case head
    case safety
    case assist
    case unbound
}

// MARK: - ControllerCalloutItem

/// 다이어그램 옆에 항상 표시되는 콜아웃 라벨 1개 — reWASD 패턴.
public struct ControllerCalloutItem: Equatable, Identifiable, Sendable {
    /// 컨트롤 식별자 ("LT", "B", "LS", "DPAD" …).
    public let id: String
    /// 물리 컨트롤 이름 ("LT", "L 스틱" …).
    public let controlLabel: String
    /// 할당 동작 요약 ("머리 좌", "이동", "회전·머리", "미설정" …).
    public let actionLabel: String
    public let category: ControllerCalloutCategory
    /// 안전 동작이 할당돼 잠금 표시가 필요한지.
    public let locked: Bool
    /// activator 모드 글리프 (toggle "⇄" 등). hold(기본)면 nil.
    public let modeGlyph: String?
    /// 라벨 탭 시 선택할 바인딩 — 매핑된 서브 바인딩 우선.
    public let selectionBinding: ControllerBinding
    /// 이 컨트롤을 구성하는 모든 서브 바인딩 — 라이브 글로우/선택 판정용.
    public let memberBindings: [ControllerBinding]
    /// `RGG01ControllerVisual` 560×330 캔버스 좌표의 리더라인 앵커.
    public let anchor: CGPoint
}

// MARK: - ControllerCalloutModel

/// 프로파일 → 콜아웃 컬럼(좌/우) 변환 순수 함수.
///
/// 집계 규칙:
/// - 단일 컨트롤(버튼/트리거): 할당 동작명 그대로. 없으면 데드맨/터보 보조 라벨,
///   그것도 아니면 "미설정".
/// - 집계 컨트롤(스틱/D패드): 서브 바인딩 동작들의 그룹을 모아 단일 그룹이면
///   그룹명("이동"), 복수면 "회전·머리" 처럼 연결.
/// - 센터 버튼(View/Menu)·스틱 클릭은 매핑된 경우에만 표시 (잡음 감소).
public enum ControllerCalloutModel {

    public static func columns(
        for profile: ControllerBindingProfile
    ) -> (left: [ControllerCalloutItem], right: [ControllerCalloutItem]) {
        let left = leftControls.compactMap { item($0, profile: profile) }
        let right = rightControls.compactMap { item($0, profile: profile) }
        return (left, right)
    }

    // MARK: - 컨트롤 정의

    /// 물리 컨트롤 기술자 — RG G01 전면 컨트롤 + 다이어그램 앵커.
    private struct ControlDescriptor {
        let id: String
        let label: String
        let bindings: [ControllerBinding]
        let anchor: CGPoint
        /// true 면 매핑이 없을 때 콜아웃을 생략한다.
        let hiddenWhenUnbound: Bool

        init(_ id: String, _ label: String, _ bindings: [ControllerBinding],
             anchor: CGPoint, hiddenWhenUnbound: Bool = false) {
            self.id = id
            self.label = label
            self.bindings = bindings
            self.anchor = anchor
            self.hiddenWhenUnbound = hiddenWhenUnbound
        }
    }

    private static let leftControls: [ControlDescriptor] = [
        ControlDescriptor("LT", "LT",
                          [.axis(index: 4, polarity: .positive), .axis(index: 4, polarity: .negative)],
                          anchor: CGPoint(x: 160, y: 58)),
        ControlDescriptor("LB", "LB", [.button(index: 4)], anchor: CGPoint(x: 212, y: 80)),
        ControlDescriptor("LS", "L 스틱",
                          [.axis(index: 1, polarity: .negative), .axis(index: 1, polarity: .positive),
                           .axis(index: 0, polarity: .negative), .axis(index: 0, polarity: .positive)],
                          anchor: CGPoint(x: 200, y: 150)),
        ControlDescriptor("DPAD", "D패드",
                          [.button(index: 10), .button(index: 11), .button(index: 12), .button(index: 13)],
                          anchor: CGPoint(x: 236, y: 210)),
        ControlDescriptor("VIEW", "View", [.button(index: 6)],
                          anchor: CGPoint(x: 262, y: 166), hiddenWhenUnbound: true),
        ControlDescriptor("LSB", "L 스틱 클릭", [.button(index: 8)],
                          anchor: CGPoint(x: 200, y: 150), hiddenWhenUnbound: true),
    ]

    private static let rightControls: [ControlDescriptor] = [
        ControlDescriptor("RT", "RT",
                          [.axis(index: 5, polarity: .positive), .axis(index: 5, polarity: .negative)],
                          anchor: CGPoint(x: 400, y: 58)),
        ControlDescriptor("RB", "RB", [.button(index: 5)], anchor: CGPoint(x: 348, y: 80)),
        ControlDescriptor("Y", "Y", [.button(index: 3)], anchor: CGPoint(x: 382, y: 116)),
        ControlDescriptor("X", "X", [.button(index: 2)], anchor: CGPoint(x: 356, y: 142)),
        ControlDescriptor("B", "B", [.button(index: 1)], anchor: CGPoint(x: 408, y: 142)),
        ControlDescriptor("A", "A", [.button(index: 0)], anchor: CGPoint(x: 382, y: 168)),
        ControlDescriptor("RS", "R 스틱",
                          [.axis(index: 3, polarity: .negative), .axis(index: 3, polarity: .positive),
                           .axis(index: 2, polarity: .negative), .axis(index: 2, polarity: .positive)],
                          anchor: CGPoint(x: 350, y: 218)),
        ControlDescriptor("MENU", "Menu", [.button(index: 7)],
                          anchor: CGPoint(x: 298, y: 166), hiddenWhenUnbound: true),
        ControlDescriptor("RSB", "R 스틱 클릭", [.button(index: 9)],
                          anchor: CGPoint(x: 350, y: 218), hiddenWhenUnbound: true),
    ]

    // MARK: - 아이템 생성

    private static func item(
        _ control: ControlDescriptor,
        profile: ControllerBindingProfile
    ) -> ControllerCalloutItem? {
        let boundPairs: [(binding: ControllerBinding, action: CockpitAction)] =
            control.bindings.flatMap { binding in
                profile.actions(boundTo: binding).map { (binding, $0) }
            }
        let actions = boundPairs.map(\.action)

        if actions.isEmpty && control.hiddenWhenUnbound { return nil }

        let (label, category) = summary(actions: actions, control: control, profile: profile)
        let selection = boundPairs.first?.binding ?? control.bindings[0]
        let glyph: String? = actions.count == 1
            ? activatorGlyph(profile.activators[actions[0]])
            : nil

        return ControllerCalloutItem(
            id: control.id,
            controlLabel: control.label,
            actionLabel: label,
            category: category,
            locked: actions.contains { $0.isSafetyCritical },
            modeGlyph: glyph,
            selectionBinding: selection,
            memberBindings: control.bindings,
            anchor: control.anchor
        )
    }

    /// 동작 목록 → (요약 라벨, 카테고리).
    private static func summary(
        actions: [CockpitAction],
        control: ControlDescriptor,
        profile: ControllerBindingProfile
    ) -> (String, ControllerCalloutCategory) {
        if actions.isEmpty {
            if let assist = assistLabel(control, profile: profile) { return (assist, .assist) }
            return ("미설정", .unbound)
        }
        if actions.count == 1 {
            return (actions[0].label, category(of: [actions[0].group]))
        }
        let groups = orderedUniqueGroups(actions)
        let label = groups.count == 1 ? groups[0].rawValue
                                      : groups.map(\.rawValue).joined(separator: "·")
        return (label, category(of: groups))
    }

    /// 매핑 없는 버튼의 데드맨/터보 보조 라벨.
    private static func assistLabel(
        _ control: ControlDescriptor,
        profile: ControllerBindingProfile
    ) -> String? {
        guard control.bindings.count == 1,
              case .button(let index) = control.bindings[0] else { return nil }
        if profile.deadmanEnabled && profile.deadmanButtonIndex == index { return "데드맨 홀드" }
        if profile.turboButtonIndex == index { return "터보" }
        return nil
    }

    private static func orderedUniqueGroups(_ actions: [CockpitAction]) -> [CockpitAction.Group] {
        let present = Set(actions.map(\.group))
        return CockpitAction.Group.allCases.filter { present.contains($0) }
    }

    /// 카테고리 우선순위: 안전 > 이동·회전 > 머리.
    private static func category(of groups: [CockpitAction.Group]) -> ControllerCalloutCategory {
        if groups.contains(.safety) { return .safety }
        if groups.contains(.movement) || groups.contains(.rotation) { return .movement }
        return .head
    }

    private static func activatorGlyph(_ type: ActivatorType?) -> String? {
        switch type {
        case .toggle: return "⇄"
        case .longPress: return "⏺"
        case .start: return "▸"
        case .hold, .none: return nil
        default: return "·"
        }
    }
}

// MARK: - ControllerBinding.rgg01Label

public extension ControllerBinding {
    /// RG G01/Xbox 표준 레이아웃의 사람 친화 입력명 — 토스트·콜아웃용.
    /// 표준 범위 밖 인덱스는 `displayLabel` 폴백.
    var rgg01Label: String {
        switch self {
        case .unbound:
            return "—"
        case .button(let index):
            let names = ["A", "B", "X", "Y", "LB", "RB", "View", "Menu", "LSB", "RSB",
                         "D패드 ↑", "D패드 ↓", "D패드 ←", "D패드 →"]
            return index >= 0 && index < names.count ? names[index] : displayLabel
        case .axis(let index, let polarity):
            switch index {
            case 0: return polarity == .negative ? "L스틱 ←" : "L스틱 →"
            case 1: return polarity == .negative ? "L스틱 ↑" : "L스틱 ↓"
            case 2: return polarity == .negative ? "R스틱 ←" : "R스틱 →"
            case 3: return polarity == .negative ? "R스틱 ↑" : "R스틱 ↓"
            case 4: return "LT"
            case 5: return "RT"
            default: return displayLabel
            }
        }
    }
}
