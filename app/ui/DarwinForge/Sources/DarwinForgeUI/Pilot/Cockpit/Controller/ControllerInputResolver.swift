import Foundation

/// `ControllerInputResolver.resolve` 의 결과 — cockpit 주입에 바로 쓰는 의미 출력.
///
/// 모든 값은 **`CockpitState.apply` / `applyHead` 관례** 로 정규화돼 있어 드라이버가
/// 추가 변환 없이 그대로 넘긴다.
public struct ResolvedControllerInput: Equatable, Sendable {

    // MARK: - 이동 (CockpitState.apply 관례)

    /// 좌우 이동 — +가 우(strafeRight). [-1, 1]
    public let leftX:  Double
    /// 전후 이동 — **−가 전진**(VirtualJoystickMapper 관례). [-1, 1]
    public let leftY:  Double
    /// 회전 — +가 우회전(turnRight). [-1, 1]
    public let turn:   Double

    // MARK: - 머리 (CockpitState.applyHead 관례)

    /// 머리 좌우 — +가 우(headPanRight). [-1, 1]
    public let headPan:  Double
    /// 머리 상하 — +가 위(headTiltUp). [-1, 1]
    public let headTilt: Double

    // MARK: - 안전/토글 버튼 (눌림 레벨, 드라이버가 edge-trigger)

    /// 긴급 정지 입력 눌림 여부.
    public let emergencyStop: Bool
    /// 복구 입력 눌림 여부.
    public let recover:       Bool
    /// 볼 트래킹 토글 입력 눌림 여부.
    public let ballTracking:  Bool

    public init(
        leftX: Double = 0, leftY: Double = 0, turn: Double = 0,
        headPan: Double = 0, headTilt: Double = 0,
        emergencyStop: Bool = false, recover: Bool = false, ballTracking: Bool = false
    ) {
        self.leftX         = leftX
        self.leftY         = leftY
        self.turn          = turn
        self.headPan       = headPan
        self.headTilt      = headTilt
        self.emergencyStop = emergencyStop
        self.recover       = recover
        self.ballTracking  = ballTracking
    }

    /// 모든 출력 0/false — 미입력·failsafe 시 기준.
    public static let neutral = ResolvedControllerInput()
}

/// `ControllerSnapshot` + `ControllerBindingProfile` → `ResolvedControllerInput` 변환의
/// **순수 함수** 모음. side-effect 없음 → 단위테스트 용이(M2 수용 기준).
///
/// 매핑 철학:
/// - 각 `CockpitAction` 의 바인딩을 [0, 1] 크기로 해석(`magnitude`).
/// - 반대 동작 쌍(전진↔후진 등)을 빼서 net 축값 산출 → 한 물리 축에 양쪽이 묶여도 안전.
public enum ControllerInputResolver {

    /// 단일 액션의 입력 크기 [0, 1].
    ///
    /// - 축 바인딩: `axisTuning.shaped(raw)` 의 **polarity 방향 성분만** 취함.
    ///   positive → max(0, shaped), negative → max(0, −shaped).
    /// - 버튼 바인딩: 눌림이면 1, 아니면 0.
    /// - unbound / 미설정: 0.
    public static func magnitude(
        of action: CockpitAction,
        in snapshot: ControllerSnapshot,
        profile: ControllerBindingProfile
    ) -> Double {
        guard let binding = profile.bindings[action] else { return 0.0 }

        switch binding {
        case .unbound:
            return 0.0

        case .button(let index):
            return snapshot.button(index) ? 1.0 : 0.0

        case .axis(let index, let polarity):
            let tuning = profile.axisTuning[index] ?? ControllerAxisTuning()
            let shaped = tuning.shaped(snapshot.axis(index))
            switch polarity {
            case .positive: return max(0.0, shaped)
            case .negative: return max(0.0, -shaped)
            }
        }
    }

    /// 단일 액션이 디지털로 눌렸는지 — 안전/토글 버튼 edge-trigger 판정용.
    /// 크기 > 0.5 를 눌림으로 본다(버튼=1, 축은 절반 이상 변위).
    public static func isPressed(
        _ action: CockpitAction,
        in snapshot: ControllerSnapshot,
        profile: ControllerBindingProfile
    ) -> Bool {
        magnitude(of: action, in: snapshot, profile: profile) > 0.5
    }

    /// 스냅샷 + 프로파일 → 의미 출력 전체.
    public static func resolve(
        _ snapshot: ControllerSnapshot,
        profile: ControllerBindingProfile
    ) -> ResolvedControllerInput {
        func m(_ a: CockpitAction) -> Double { magnitude(of: a, in: snapshot, profile: profile) }

        // 반대 쌍 차감 — net 축. 전진은 leftY 음수(VirtualJoystickMapper 관례)이므로
        // leftY = 후진 − 전진.
        let leftY    = m(.moveBackward) - m(.moveForward)
        let leftX    = m(.strafeRight)  - m(.strafeLeft)
        let turn     = m(.turnRight)    - m(.turnLeft)
        let headPan  = m(.headPanRight) - m(.headPanLeft)
        let headTilt = m(.headTiltUp)   - m(.headTiltDown)

        return ResolvedControllerInput(
            leftX: leftX, leftY: leftY, turn: turn,
            headPan: headPan, headTilt: headTilt,
            emergencyStop: isPressed(.emergencyStop, in: snapshot, profile: profile),
            recover:       isPressed(.recover,       in: snapshot, profile: profile),
            ballTracking:  isPressed(.ballTracking,  in: snapshot, profile: profile)
        )
    }
}
