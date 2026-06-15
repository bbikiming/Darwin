import Foundation

/// `DJIVirtualJoystickReport` → cockpit `apply(leftX:leftY:turn:)` 인자 변환.
///
/// # DJI Mode 2 (전 세계 대부분 사용자의 기본 stick 배치)
///
/// | DJI HID axis | 물리 스틱 | 드론 의미 | 본 로봇 매핑                |
/// | ------------ | --------- | -------- | --------------------------- |
/// | X            | 좌 X      | Yaw       | cockpit.turn (좌·우 회전)   |
/// | Y            | 좌 Y      | Throttle  | (미사용 — 로봇은 throttle 無) |
/// | Rx           | 우 X      | Roll      | cockpit.leftX (좌·우 측면)  |
/// | Ry           | 우 Y      | Pitch     | cockpit.leftY (전·후 이동)  |
/// | Z            | camera wheel | Tilt   | (예약 — 미래 머리 pitch)    |
///
/// # 부호 컨벤션
///
/// - `cockpit.apply(leftY:)` 는 DSJoystick convention 사용: **`leftY = -1` = 전진**
///   (가상 조이스틱의 위쪽 = 화면 위 = -y 좌표).
/// - DJI HID Ry: 스틱 위 = +660, 스틱 아래 = -660 (실측 가능, 일반 USB joystick
///   convention 동일). 따라서 **Ry → leftY 는 부호 반전 필요** (Ry +1 = forward = leftY -1).
/// - DJI HID Rx: 스틱 오른쪽 = +660 → cockpit.leftX 그대로 (+1 = 우측 측면).
/// - DJI HID X (yaw): 스틱 오른쪽 = +660 = 우회전. cockpit.turn 컨벤션 (+1 = 좌회전)
///   이므로 **X → turn 도 부호 반전 필요** (X +1 = right turn = turn -1).
///
/// # 부호 불확실성에 대한 안전장치
///
/// HID joystick 의 axis 부호는 제조사마다 ±가 다르다 — DJI RC3 의 실측 부호가 위
/// 가정과 다를 가능성도 있다. 사용자 검증 후 부호가 반대로 보이면 `Inversion` struct
/// 의 boolean 만 토글하면 코드 변경 없이 cockpit 패널에서 즉시 반전 가능 (Panel UI
/// 에 토글 노출). 따라서 본 mapper 는 **양방향 부호 모두 지원**한다.
public enum DJIVirtualJoystickMapper {

    /// Mapper 가 호출자에게 돌려주는 cockpit-ready stick 입력.
    ///
    /// `headPanNorm` / `headTiltNorm` 은 머리 동작 할당의 정규화 입력 (-1...1).
    /// rate 모드 컨벤션: +pan = 우, +tilt = 위. cockpit 이 각속도로 적분하므로
    /// 본 값은 "지금 머리를 어느 방향으로 얼마나 빨리 돌리는가"를 의미.
    public struct StickInput: Equatable, Sendable {
        public let leftX: Double
        public let leftY: Double
        public let turn: Double
        public let headPanNorm: Double
        public let headTiltNorm: Double
        public init(leftX: Double, leftY: Double, turn: Double,
                    headPanNorm: Double = 0, headTiltNorm: Double = 0) {
            self.leftX = leftX
            self.leftY = leftY
            self.turn = turn
            self.headPanNorm = headPanNorm
            self.headTiltNorm = headTiltNorm
        }
        public static let zero = StickInput(leftX: 0, leftY: 0, turn: 0)
    }

    /// 사용자가 cockpit 패널에서 토글할 부호 반전 옵션. default 는 위 docstring
    /// 의 표준 매핑 (Ry 와 X 부호 반전).
    public struct Inversion: Equatable, Sendable {
        /// `true` 면 우 스틱 forward 방향 부호 반전. (DJI default = true)
        public var invertForward: Bool
        /// `true` 면 우 스틱 좌·우 방향 부호 반전.
        public var invertLateral: Bool
        /// `true` 면 좌 스틱 좌·우 (yaw) 방향 부호 반전. (DJI default = true)
        public var invertTurn: Bool

        public init(invertForward: Bool = true,
                    invertLateral: Bool = false,
                    invertTurn: Bool = true) {
            self.invertForward = invertForward
            self.invertLateral = invertLateral
            self.invertTurn = invertTurn
        }

        public static let djiDefault = Inversion()
    }

    /// Deadzone — cockpit `VirtualJoystickMapper` 와 동일 (0.10). 두 매퍼를 같은
    /// 값으로 유지해 일관 stop 동작 보장.
    ///
    /// **0.05 → 0.10 상향 (뒤로 걷기 잔존 fix)**: 아날로그 스틱(DJI RC)의 중앙
    /// drift 가 ±0.06 수준이라 종전 0.05 deadzone 을 간신히 넘겨 미세 후진(-2~-5mm)
    /// 이 무한 dispatch → 로봇이 혼자 뒤로 걷는 잔존 발생. 0.10 으로 drift 를 흡수.
    public static let deadzone: Double = 0.10

    /// 매핑 본체.
    public static func map(_ report: DJIVirtualJoystickReport,
                           inversion: Inversion = .djiDefault) -> StickInput {
        let rawFwd = applyDeadzone(report.axisRy)
        let rawLat = applyDeadzone(report.axisRx)
        let rawTrn = applyDeadzone(report.axisX)
        let fwd = inversion.invertForward ? -rawFwd : rawFwd
        let lat = inversion.invertLateral ? -rawLat : rawLat
        let trn = inversion.invertTurn    ? -rawTrn : rawTrn
        return StickInput(leftX: lat, leftY: fwd, turn: trn)
    }

    /// **사용자 정의 binding profile 기반 매핑** (사용자 키 매핑 sheet 가 saved
    /// profile 을 watcher 에 push 한 뒤 본 메서드가 호출됨).
    ///
    /// 각 cockpit action 의 binding 을 보고 해당 axis 또는 button 의 polarity-aware
    /// 값을 합성:
    ///   - moveForward / moveBackward: ±leftY (DSJoystick 컨벤션: forward=-y)
    ///   - strafeRight / strafeLeft:   ±leftX (right=+x)
    ///   - turnRight / turnLeft:       ±turn  (left turn=+turn)
    ///
    /// 동일 action 에 두 binding (예: forward 와 backward 가 동시 활성) 이 모두 1.0
    /// 이면 둘이 상쇄 → 0. 사용자가 양쪽을 동일 axis 의 같은 polarity 로 잘못 매핑
    /// 한 경우에도 robot 이 갑자기 폭주하지 않는 안전 invariant.
    public static func map(_ report: DJIVirtualJoystickReport,
                           profile: DJIBindingProfile) -> StickInput {
        let fwd = bindingValue(.moveForward, in: profile, report: report)
            - bindingValue(.moveBackward, in: profile, report: report)
        let right = bindingValue(.strafeRight, in: profile, report: report)
            - bindingValue(.strafeLeft, in: profile, report: report)
        let leftTurn = bindingValue(.turnLeft, in: profile, report: report)
            - bindingValue(.turnRight, in: profile, report: report)
        // 머리 — 같은 축에 양극을 잘못 매핑해도 상쇄(0)되는 동일 안전 invariant.
        // +pan = 우, +tilt = 위 (rate 컨벤션).
        let headPan = bindingValue(.headPanRight, in: profile, report: report)
            - bindingValue(.headPanLeft, in: profile, report: report)
        let headTilt = bindingValue(.headTiltUp, in: profile, report: report)
            - bindingValue(.headTiltDown, in: profile, report: report)
        // DSJoystick 컨벤션: forward = leftY -1. profile 시맨틱은 양수 = forward 이라
        // 부호 반전.
        return StickInput(leftX: right, leftY: -fwd, turn: leftTurn,
                          headPanNorm: headPan, headTiltNorm: headTilt)
    }

    /// 한 action 의 binding 이 만족하는 정도 (0.0 ~ 1.0). axis 면 magnitude,
    /// button 이면 1.0 또는 0.0.
    private static func bindingValue(_ action: CockpitAction,
                                     in profile: DJIBindingProfile,
                                     report: DJIVirtualJoystickReport) -> Double {
        guard let binding = profile.bindings[action] else { return 0 }
        switch binding {
        case .unbound:
            return 0
        case .axis(let axis, let polarity):
            let raw = axisValue(axis, in: report)
            let masked = applyDeadzone(raw)
            switch polarity {
            case .positive: return masked > 0 ? masked : 0
            case .negative: return masked < 0 ? -masked : 0
            }
        case .button(let idx):
            return (idx >= 0 && idx < report.buttons.count && report.buttons[idx]) ? 1 : 0
        }
    }

    private static func axisValue(_ axis: DJIInputBinding.Axis,
                                  in report: DJIVirtualJoystickReport) -> Double {
        switch axis {
        case .x:  return report.axisX
        case .y:  return report.axisY
        case .z:  return report.axisZ
        case .rx: return report.axisRx
        case .ry: return report.axisRy
        }
    }

    /// Profile 의 button binding 으로부터 cockpit safety actions 추출.
    public static func buttonActions(report: DJIVirtualJoystickReport,
                                     profile: DJIBindingProfile) -> ButtonActions {
        let estop = bindingValue(.emergencyStop, in: profile, report: report) >= 1.0
        let rec = bindingValue(.recover, in: profile, report: report) >= 1.0
        let ballTrack = bindingValue(.ballTracking, in: profile, report: report) >= 1.0
        return ButtonActions(emergencyStop: estop, recover: rec, ballTracking: ballTrack)
    }

    /// 버튼 → cockpit safety action 매핑.
    ///
    /// HID 디스크립터가 24개 버튼을 모두 정의했지만, DJI RC3 는 일부만 실제로 발화.
    /// 가장 명확한 두 가지만 사용 — UI 에서 사용자가 확장 가능.
    public struct ButtonActions: Equatable, Sendable {
        public let emergencyStop: Bool
        public let recover: Bool
        /// 볼 트래킹 (2026-06-02) — 온보드 헤드 추적 토글 버튼.
        public let ballTracking: Bool

        public init(emergencyStop: Bool = false, recover: Bool = false,
                    ballTracking: Bool = false) {
            self.emergencyStop = emergencyStop
            self.recover = recover
            self.ballTracking = ballTracking
        }

        /// Button 1 (index 0) = emergency. Button 2 (index 1) = recover.
        /// Button 3 (index 2) = 볼 트래킹 토글. 사용자가 실측으로 다른 버튼 사용 원하면
        /// binding sheet 에서 재매핑 가능.
        public static func from(_ buttons: [Bool]) -> ButtonActions {
            ButtonActions(
                emergencyStop: buttons.count > 0 && buttons[0],
                recover:       buttons.count > 1 && buttons[1],
                ballTracking:  buttons.count > 2 && buttons[2])
        }
    }

    // MARK: - Private

    private static func applyDeadzone(_ v: Double) -> Double {
        abs(v) < deadzone ? 0 : v
    }
}
