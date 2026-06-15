import Foundation

// MARK: - FailsafeBehavior

/// 연결 끊김 시 로봇 동작 선택.
/// 기본 `.freeze` — 보행 즉시 정지 + 현재 자세 유지 (PRD §13 결정).
public enum FailsafeBehavior: String, Codable, Sendable {
    /// 즉시 정지 + 현재 자세 유지. (기본)
    case freeze
    /// 앉기 자세로 전환.
    case sit
    /// 안전 정지 모션 실행.
    case safeStop
}

// MARK: - ControllerSetBindingResult

/// `ControllerBindingProfile.setting(_:for:)` 의 결과.
/// `SetBindingResult` (DJI 파일) 와 이름 충돌을 피하기 위해 `ControllerSetBindingResult` 사용.
public enum ControllerSetBindingResult: Equatable {
    /// 정상 적용 (swap 없음).
    case applied
    /// 정상 적용 — 함께 unbound 된 다른 액션 목록.
    case appliedWithSwap([CockpitAction])
    /// 안전 액션을 unbound 하려는 시도 거부.
    case rejectedSafetyUnbound(CockpitAction)
    /// 안전 액션의 바인딩을 다른 액션이 강탈 시도 거부.
    case rejectedSafetyStolen(CockpitAction)
}

// MARK: - ControllerBindingConflict

/// 바인딩 충돌 종류.
public enum ControllerBindingConflict: Equatable {
    /// 동일 입력(바인딩)에 다수 액션이 할당됨 — 의도 충돌.
    case duplicateInput(binding: ControllerBinding, actions: [CockpitAction])
    /// 안전 액션이 unbound 상태 — 위험.
    case safetyCriticalUnbound(CockpitAction)
}

// MARK: - ControllerBindingProfile

/// 범용 게임패드 바인딩 프로파일 — 순수 값 타입.
///
/// 편집은 mutation 없이 **새 프로파일을 반환하는 순수 함수** 로 수행.
/// `DJIBindingProfile.setBinding` 의 mutating 패턴과 달리 불변성 원칙을 따른다.
///
/// # 표준 인덱스 관례 (Xbox / RG G01 레이아웃)
///
/// **축 (axis)**
/// - 0 = LS X, 1 = LS Y, 2 = RS X, 3 = RS Y, 4 = LT, 5 = RT
///
/// **버튼 (button)**
/// - 0 = A, 1 = B, 2 = X, 3 = Y
/// - 4 = LB, 5 = RB
/// - 6 = View(Back), 7 = Menu(Start)
/// - 8 = LSB, 9 = RSB
/// - 10 = D↑, 11 = D↓, 12 = D←, 13 = D→
public struct ControllerBindingProfile: Codable, Equatable, Sendable {

    // MARK: - 프로퍼티

    public var name:              String
    /// 장치 식별자 (예: "gc.xbox", "hid.2ca3.1021").
    public var deviceKey:         String
    /// 액션 → 바인딩 매핑.
    public var bindings:          [CockpitAction: ControllerBinding]
    /// 축 인덱스 → 튜닝 파라미터.
    public var axisTuning:        [Int: ControllerAxisTuning]
    /// 액션 → 활성화 타입.
    public var activators:        [CockpitAction: ActivatorType]
    /// 데드맨 활성 여부 (기본 ON — PRD §13 결정).
    public var deadmanEnabled:    Bool
    /// 데드맨 버튼 인덱스 (기본 4 = LB).
    public var deadmanButtonIndex: Int?
    /// 터보 버튼 인덱스 (기본 5 = RB).
    public var turboButtonIndex:  Int?
    /// 연결 끊김 failsafe 동작 (기본 .freeze — PRD §13 결정).
    public var failsafe:          FailsafeBehavior

    // MARK: - Initializer

    public init(
        name:               String,
        deviceKey:          String,
        bindings:           [CockpitAction: ControllerBinding]  = [:],
        axisTuning:         [Int: ControllerAxisTuning]         = [:],
        activators:         [CockpitAction: ActivatorType]      = [:],
        deadmanEnabled:     Bool                                = true,
        deadmanButtonIndex: Int?                                = 4,
        turboButtonIndex:   Int?                                = 5,
        failsafe:           FailsafeBehavior                    = .freeze
    ) {
        self.name               = name
        self.deviceKey          = deviceKey
        self.bindings           = bindings
        self.axisTuning         = axisTuning
        self.activators         = activators
        self.deadmanEnabled     = deadmanEnabled
        self.deadmanButtonIndex = deadmanButtonIndex
        self.turboButtonIndex   = turboButtonIndex
        self.failsafe           = failsafe
    }

    // MARK: - 불변 편집

    /// `action` 에 `binding` 을 적용한 **새 프로파일** 을 반환.
    ///
    /// 규칙:
    /// - 안전 액션을 unbound 로 설정하면 `.rejectedSafetyUnbound` 반환.
    /// - 새 바인딩이 이미 다른 액션에 할당돼 있으면 1:1 invariant swap (기존 → unbound).
    ///   단 swap 대상이 안전 액션이면 `.rejectedSafetyStolen` 반환.
    public func setting(
        _ binding: ControllerBinding,
        for action: CockpitAction
    ) -> (profile: ControllerBindingProfile, result: ControllerSetBindingResult) {
        // 안전 액션 unbound 거부
        if binding.isUnbound && action.isSafetyCritical {
            return (self, .rejectedSafetyUnbound(action))
        }

        var newBindings = bindings
        var swapped: [CockpitAction] = []

        if !binding.isUnbound {
            // 1:1 invariant: 같은 바인딩을 사용 중인 다른 액션 해제
            for other in actions(boundTo: binding) where other != action {
                if other.isSafetyCritical {
                    return (self, .rejectedSafetyStolen(other))
                }
                newBindings[other] = .unbound
                swapped.append(other)
            }
        }

        newBindings[action] = binding

        var updated = self
        updated.bindings = newBindings
        let result: ControllerSetBindingResult = swapped.isEmpty
            ? .applied
            : .appliedWithSwap(swapped)
        return (updated, result)
    }

    // MARK: - 조회

    /// `binding` 에 매핑된 모든 액션.
    public func actions(boundTo binding: ControllerBinding) -> [CockpitAction] {
        bindings.compactMap { $0.value == binding ? $0.key : nil }
    }

    /// 현재 프로파일의 충돌 목록.
    ///
    /// - 동일 입력에 여러 액션 → `duplicateInput`
    /// - 안전 액션이 unbound → `safetyCriticalUnbound`
    public func conflicts() -> [ControllerBindingConflict] {
        var result: [ControllerBindingConflict] = []

        // 중복 입력 감지
        var bindingToActions: [ControllerBinding: [CockpitAction]] = [:]
        for (action, binding) in bindings {
            if !binding.isUnbound {
                bindingToActions[binding, default: []].append(action)
            }
        }
        for (binding, acts) in bindingToActions where acts.count > 1 {
            result.append(.duplicateInput(binding: binding, actions: acts.sorted(by: { $0.rawValue < $1.rawValue })))
        }

        // 안전 액션 미할당 감지
        for action in CockpitAction.allCases where action.isSafetyCritical {
            let bound = bindings[action]
            if bound == nil || bound!.isUnbound {
                result.append(.safetyCriticalUnbound(action))
            }
        }

        return result
    }

    // MARK: - 프리셋

    /// Xbox / RG G01 레이아웃 기본 프리셋 (PRD §5).
    ///
    /// - LS Y(axis 1, negative) → moveForward  (스틱 위로 당기면 negative)
    /// - LS Y(axis 1, positive) → moveBackward
    /// - LS X(axis 0, negative) → strafeLeft
    /// - LS X(axis 0, positive) → strafeRight
    /// - RS X(axis 2, negative) → turnLeft
    /// - RS X(axis 2, positive) → turnRight
    /// - RS Y(axis 3, negative) → headTiltUp
    /// - RS Y(axis 3, positive) → headTiltDown
    /// - LT(axis 4, positive)   → headPanLeft
    /// - RT(axis 5, positive)   → headPanRight
    /// - Button 1 (B)           → emergencyStop
    /// - Button 3 (Y)           → recover
    /// - Button 2 (X)           → ballTracking
    /// deadmanEnabled=true, deadmanButtonIndex=4(LB).
    public static let xbox: ControllerBindingProfile = {
        let defaultTuning = ControllerAxisTuning()
        var tuning: [Int: ControllerAxisTuning] = [:]
        for i in 0...5 { tuning[i] = defaultTuning }

        return ControllerBindingProfile(
            name: "Xbox / RG G01 (기본)",
            deviceKey: "gc.xbox",
            bindings: [
                .moveForward:   .axis(index: 1, polarity: .negative),
                .moveBackward:  .axis(index: 1, polarity: .positive),
                .strafeLeft:    .axis(index: 0, polarity: .negative),
                .strafeRight:   .axis(index: 0, polarity: .positive),
                .turnLeft:      .axis(index: 2, polarity: .negative),
                .turnRight:     .axis(index: 2, polarity: .positive),
                .headTiltUp:    .axis(index: 3, polarity: .negative),
                .headTiltDown:  .axis(index: 3, polarity: .positive),
                .headPanLeft:   .axis(index: 4, polarity: .positive),
                .headPanRight:  .axis(index: 5, polarity: .positive),
                .emergencyStop: .button(index: 1),
                .recover:       .button(index: 3),
                .ballTracking:  .button(index: 2),
            ],
            axisTuning: tuning,
            activators: [:],
            deadmanEnabled: true,
            deadmanButtonIndex: 4,
            turboButtonIndex: 5,
            failsafe: .freeze
        )
    }()

    /// DualSense 레이아웃 기본 프리셋 (Xbox 와 동일 매핑, deviceKey 만 다름).
    public static let dualSense: ControllerBindingProfile = {
        var p = xbox
        p.name = "DualSense (기본)"
        p.deviceKey = "gc.dualsense"
        return p
    }()

    /// 모든 액션 unbound — 처음부터 사용자가 직접 설정.
    public static let empty: ControllerBindingProfile = ControllerBindingProfile(
        name: "비어 있음",
        deviceKey: "custom",
        bindings: Dictionary(
            uniqueKeysWithValues: CockpitAction.allCases.map { ($0, .unbound) }
        ),
        deadmanEnabled: true
    )
}
