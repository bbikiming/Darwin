import Foundation

/// **방법론 (Unity Input System + Unreal Enhanced Input + Steam Input Configurator)**:
///
/// 게임에서 사용자가 컨트롤러 키를 재매핑할 수 있게 하려면, **Action ↔ Binding**
/// 의 indirection layer 가 필요하다. Action 은 게임 의도 (예: "전진"), Binding 은
/// 그 의도를 만드는 물리 입력 (axis 또는 button). 사용자는 Action 의 binding 만
/// 갈아끼울 뿐 게임 코드가 보는 의도 자체는 일관 유지.
///
/// 본 파일은 cockpit 의 DJI controller 에 대한 그 layer 를 제공한다.
///
/// # 구성
///
/// - `CockpitAction`: 매핑 대상 cockpit 동작 (전후좌우 / 회전 / 안전 / 속도).
/// - `DJIInputBinding`: DJI HID 입력 — axis (polarity 포함) 또는 button index, 또는
///   `unbound` (사용자가 명시 비활성).
/// - `DJIBindingProfile`: action → binding 매핑 + 사용자 이름. UserDefaults JSON
///   저장. `.djiMode2` 기본 preset 포함.
public enum CockpitAction: String, CaseIterable, Codable, Sendable {
    case moveForward, moveBackward
    case strafeLeft, strafeRight
    case turnLeft, turnRight
    case headPanLeft, headPanRight
    case headTiltUp, headTiltDown
    case emergencyStop, recover

    public var label: String {
        switch self {
        case .moveForward:    return "전진"
        case .moveBackward:   return "후진"
        case .strafeLeft:     return "좌측 이동"
        case .strafeRight:    return "우측 이동"
        case .turnLeft:       return "좌회전"
        case .turnRight:      return "우회전"
        case .headPanLeft:    return "머리 좌"
        case .headPanRight:   return "머리 우"
        case .headTiltUp:     return "머리 위"
        case .headTiltDown:   return "머리 아래"
        case .emergencyStop:  return "긴급 정지"
        case .recover:        return "복구"
        }
    }

    /// 동작 군 — sheet 의 Section header 분류.
    public enum Group: String, CaseIterable {
        case movement = "이동"
        case rotation = "회전"
        case head = "머리"
        case safety = "안전"
    }

    public var group: Group {
        switch self {
        case .moveForward, .moveBackward, .strafeLeft, .strafeRight:
            return .movement
        case .turnLeft, .turnRight:
            return .rotation
        case .headPanLeft, .headPanRight, .headTiltUp, .headTiltDown:
            return .head
        case .emergencyStop, .recover:
            return .safety
        }
    }
}

/// DJI HID report 의 입력 종류 — mapper 가 매 frame 검사하여 binding 의 condition
/// 충족 여부 판정한다.
public enum DJIInputBinding: Codable, Hashable, Sendable {
    /// Stick axis — 5 종 (X/Y/Z/Rx/Ry). polarity 가 정의: positive 면 axis ≥ deadzone
    /// 일 때 action 가 1.0, negative 면 axis ≤ -deadzone 일 때 1.0.
    case axis(Axis, polarity: Polarity)
    /// Button index 0..23. 누르면 1.0 (digital).
    case button(Int)
    /// 명시 비활성 — 매핑 안 함.
    case unbound

    public enum Axis: String, Codable, CaseIterable, Sendable {
        case x   = "X"
        case y   = "Y"
        case z   = "Z"
        case rx  = "Rx"
        case ry  = "Ry"

        public var label: String { rawValue }

        /// 사용자에게 axis 가 어떤 물리 stick / wheel 인지 한국어로 안내.
        /// DJI Mode 2 표준 mapping 기준. manualPicker 에서 사용자가 의미 알고
        /// 선택하도록 메뉴 라벨에 부가 정보 표시.
        public var humanDescription: String {
            switch self {
            case .x:  return "좌 스틱 가로 (yaw)"
            case .y:  return "좌 스틱 세로 (throttle)"
            case .z:  return "카메라 휠 (tilt)"
            case .rx: return "우 스틱 가로 (roll)"
            case .ry: return "우 스틱 세로 (pitch)"
            }
        }
    }

    public enum Polarity: String, Codable, CaseIterable, Sendable {
        case positive = "+"
        case negative = "−"

        public var humanDescription: String {
            self == .positive ? "한쪽 방향" : "반대 방향"
        }
    }

    /// 사용자가 sheet 에서 보는 binding 라벨.
    public var displayLabel: String {
        switch self {
        case .axis(let ax, let pol):
            return "\(ax.label) \(pol.rawValue)"
        case .button(let idx):
            return "Button \(idx + 1)"
        case .unbound:
            return "—"
        }
    }

    /// 동일한 binding 인지 (conflict detection 용).
    public var isUnbound: Bool {
        if case .unbound = self { return true }
        return false
    }
}

/// 사용자 binding profile — UserDefaults JSON 저장.
public struct DJIBindingProfile: Codable, Equatable, Sendable {
    public var name: String
    public var bindings: [CockpitAction: DJIInputBinding]

    public init(name: String = "사용자",
                bindings: [CockpitAction: DJIInputBinding]) {
        self.name = name
        self.bindings = bindings
    }

    /// DJI Mode 2 표준 (전 세계 대부분 사용자의 기본 stick 배치).
    ///
    /// - 우 스틱 Y (Ry +/-)  → forward / backward
    /// - 우 스틱 X (Rx +/-)  → strafe right / left
    /// - 좌 스틱 X (X +/-)   → turn right / left (yaw)
    /// - 카메라 휠 Z (Z +/-) → 머리 위 / 아래 (tilt) — 보행 미사용 축 재활용
    /// - 좌 스틱 Y (Y +/-)   → 머리 우 / 좌 (pan) — throttle 축이 다리 로봇에 미사용
    /// - Button 1            → emergency stop
    /// - Button 2            → recover
    public static let djiMode2: DJIBindingProfile = DJIBindingProfile(
        name: "DJI Mode 2 (기본)",
        bindings: [
            // Ry positive 가 DJI 의 stick "위" — DSJoystick 의 "forward (-y)" 에 매핑.
            // mapper 가 부호 처리하므로 여기는 입력 그대로 표기.
            .moveForward:    .axis(.ry, polarity: .positive),
            .moveBackward:   .axis(.ry, polarity: .negative),
            .strafeRight:    .axis(.rx, polarity: .positive),
            .strafeLeft:     .axis(.rx, polarity: .negative),
            .turnRight:      .axis(.x,  polarity: .positive),
            .turnLeft:       .axis(.x,  polarity: .negative),
            // 머리 — 보행에 쓰지 않는 카메라 휠(Z)·좌스틱 세로(Y) 에 기본 할당.
            // 사용자는 binding sheet 에서 다른 축/버튼으로 자유 재매핑 가능.
            .headTiltUp:     .axis(.z,  polarity: .positive),
            .headTiltDown:   .axis(.z,  polarity: .negative),
            .headPanRight:   .axis(.y,  polarity: .positive),
            .headPanLeft:    .axis(.y,  polarity: .negative),
            .emergencyStop:  .button(0),
            .recover:        .button(1),
        ])

    /// 모든 action 이 unbound 인 빈 profile — 처음부터 사용자가 직접 설정.
    public static let empty: DJIBindingProfile = DJIBindingProfile(
        name: "비어 있음",
        bindings: Dictionary(uniqueKeysWithValues:
            CockpitAction.allCases.map { ($0, .unbound) }))

    // MARK: - Conflict detection

    /// 동일 binding 이 이미 매핑된 action 을 검색 — sheet 가 사용자에게 경고하거나
    /// 자동 swap 할 때 사용.
    public func actions(boundTo binding: DJIInputBinding) -> [CockpitAction] {
        bindings.compactMap { $0.value == binding ? $0.key : nil }
    }

    /// `action` 에 새 `binding` 을 적용. 결과 보고용 enum 으로 sheet 가 사용자에게
    /// 정확한 결과를 안내한다. 안전 action 의 보호 + 1:1 invariant 유지.
    @discardableResult
    public mutating func setBinding(_ binding: DJIInputBinding,
                                    for action: CockpitAction) -> SetBindingResult {
        // 안전 action 은 unbound 거부 — 사용자가 실수로 안전장치를 영구 해제 차단.
        if binding.isUnbound, action.isSafetyCritical {
            return .rejectedSafetyUnbound(action)
        }
        var swapped: [CockpitAction] = []
        if !binding.isUnbound {
            // 기존에 같은 binding 을 사용하던 다른 action 은 해제.
            for other in actions(boundTo: binding) where other != action {
                if other.isSafetyCritical {
                    return .rejectedSafetyStolen(other)
                }
                bindings[other] = .unbound
                swapped.append(other)
            }
        }
        bindings[action] = binding
        return swapped.isEmpty ? .applied : .appliedWithSwap(swapped)
    }
}

/// `setBinding` 의 정확한 결과 — sheet 가 사용자에게 적절한 메시지 표시용.
public enum SetBindingResult: Equatable {
    /// 정상 적용 (swap 없음).
    case applied
    /// 정상 적용 — 함께 unbound 된 다른 action 목록 (1:1 invariant).
    case appliedWithSwap([CockpitAction])
    /// 안전 action 의 unbound 시도 거부.
    case rejectedSafetyUnbound(CockpitAction)
    /// 안전 action 의 binding 을 다른 action 이 강탈하려 시도 거부.
    case rejectedSafetyStolen(CockpitAction)
}

extension CockpitAction {
    /// 안전상 절대 unbound 되면 안 되는 action. 사용자가 매핑 해제 시도하면 차단.
    public var isSafetyCritical: Bool {
        switch self {
        case .emergencyStop, .recover: return true
        default:                       return false
        }
    }
}

// MARK: - Persistence (UserDefaults JSON)

/// UserDefaults 의 key — 단일 사용자라 가정. 멀티 프로파일 지원 시 array 또는
/// 별도 file 로 확장 가능.
private let kDJIBindingProfileKey = "cockpit.dji.binding.profile.v1"

public enum DJIBindingProfileStore {
    /// 저장된 profile 또는 default (DJI Mode 2).
    public static func load(_ defaults: UserDefaults = .standard) -> DJIBindingProfile {
        guard let data = defaults.data(forKey: kDJIBindingProfileKey),
              let profile = try? JSONDecoder().decode(DJIBindingProfile.self,
                                                     from: data) else {
            return .djiMode2
        }
        return profile
    }

    public static func save(_ profile: DJIBindingProfile,
                            into defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: kDJIBindingProfileKey)
    }

    public static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: kDJIBindingProfileKey)
    }
}
