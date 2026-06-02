import Foundation

/// Pure mapping: virtual-joystick (x, y, turn, speedScale) → `WalkingCommand`.
///
/// Exposed as its own type so unit tests can pin down the maths without
/// instantiating a SwiftUI view or a bridge. Mirrors `TelloRCMapper` in
/// shape, but takes normalised joystick coordinates ([-1, +1]) instead of
/// Tello's integer stick range (-100..100).
///
/// # Convention (matches iOS `WalkFreeformInput` + Mac `WalkingCommand`)
///
/// - `x ∈ [-1, +1]` — +1 = stick right
/// - `y ∈ [-1, +1]` — -1 = stick up = forward (DSJoystick convention)
/// - `turn ∈ [-1, +1]` — sign defined by the panel's rotation control. The
///   mapper passes the value straight into `turnDeg` so the panel decides
///   what "+turn" means (the default panel maps the rotation slider so that
///   +1 = 좌회전 = +turnDeg, matching `WalkLabPreset.turnLeft`).
/// - `speedScale ∈ [0.5, 1.5]` — clamped multiplier applied to all axes.
///
/// # Baseline amplitude (speedScale = 1.0, max stick)
///
/// **Phase G upgrade (2026-05-29) — WalkLab freeform max 등가**:
///
/// - forward / backward: **38 mm/step** (was 25). WalkLab mobileFreeformClamp 의
///   stride 상한 = ROBOTIS Walking 의 안전한 fastWalk amplitude. 이를 max stick 에
///   할당해 사용자가 cockpit 만으로 robot 의 안전 max speed 도달 가능.
/// - lateral:            **22 mm/step** (was 15). freeform clamp 의 side 상한.
/// - turn:               **18 deg/step** (was 10). freeform clamp 의 turn 상한.
///
/// **속도 시나리오 (stride × 2000 / period — ROBOTIS Walking 공식)**:
///
/// - stick 1.0 + throttle 1.5 (period 600): 38 × 2000/600 = **126.7 mm/s** (max)
/// - stick 1.0 + throttle 0.5 (period 850): 38 × 2000/850 = **89.4 mm/s**
/// - stick 0.5 + throttle 1.5 (period 600): 19 × 2000/600 = **63.3 mm/s**
/// - stick 0.25 + throttle 1.0 (period 725): 9.5 × 2000/725 = **26.2 mm/s**
///
/// 가변성: stick 0..1 linear → strideMm 0..38 (선형). throttle 0.5..1.5 → period
/// 850..600 (역수). 결과 speed = (stick × 38) × 2000 / period — stick 에 선형,
/// throttle (cadence) 에 곱셈 작용. 두 축 독립으로 부드러운 가변 속도.
///
/// # speedScale 의 deprecated 의미
///
/// 종전 (V1) `speedScale` 은 amplitude scaling (mapper 안에서 stride × scale). 신규
/// (V2) 는 cadence (periodMs) 결정 — mapper 외부 (`CockpitState.periodMs`) 가 보존.
/// 따라서 본 mapper 의 `speedScale` 인자는 호환을 위해 남기지만 **기본값 1.0** 으
/// 로만 호출되는 게 정상 (CockpitState.apply 가 1.0 으로 호출).
public enum VirtualJoystickMapper {

    /// **0.05 → 0.10 상향 (뒤로 걷기 잔존 fix)**: 아날로그 스틱(DJI RC) 중앙
    /// drift(±0.06)가 종전 0.05 를 간신히 넘겨 미세 후진 명령이 무한 dispatch 됐다.
    /// `DJIVirtualJoystickMapper.deadzone` 과 동일 값 유지.
    public static let deadzone: Double = 0.10

    /// **stop snap epsilon** — deadzone 통과 후에도 남는 미세 amplitude 를 정확히 0
    /// 으로 snap 하는 임계값. `WalkingCommand.isStop`(=정확히 0) 이 자연히 true 가 돼
    /// 정지/auto-disarm 경로를 타므로, robot 이 혼자 뒤로 걷는 잔존이 소거된다.
    public static let strideStopEpsilonMm: Double = 3.0
    public static let sideStopEpsilonMm: Double = 2.0
    public static let turnStopEpsilonDeg: Double = 2.0

    /// **Legacy baseline** — Mac VirtualJoystickPanel + iOS CommandBuilder 가
    /// 사용. 안전 보수적 amplitude.
    public static let legacyStrideMm: Double = 25.0
    public static let legacySideMm:   Double = 15.0
    public static let legacyTurnDeg:  Double = 10.0

    /// **Cockpit upgrade — WalkLab freeform clamp max (ROBOTIS Walking 안전 한계)**.
    /// Cockpit 사용자가 stick 끝까지 + throttle max 시 robot 의 max safe speed
    /// (126.7 mm/s) 도달. WalkLab advanced 와 동일 capacity.
    public static let cockpitStrideMm: Double = 38.0
    public static let cockpitSideMm:   Double = 22.0
    /// **18 → 12 보수화 (다리 충돌 fix)**: turnDeg 가 hip-yaw bias(±turnDeg) + 보행
    /// cMove(±12.5°)와 합쳐져 ROBOTIS hip-yaw 안전 임계(60°)에 근접해 고각 회전 시
    /// 무릎·엉덩이가 겹쳤다. 12° 면 12+12.5=24.5° 로 35° 마진 확보(조종성 유지).
    public static let cockpitTurnDeg:  Double = 12.0

    /// Stick → WalkingCommand. amplitude max 는 caller 가 결정 (default = legacy).
    /// Cockpit 은 `cockpit*` baseline 명시.
    public static func map(x: Double,
                           y: Double,
                           turn: Double,
                           speedScale: Double = 1.0,
                           strideMmMax: Double? = nil,
                           sideMmMax: Double? = nil,
                           turnDegMax: Double? = nil) -> WalkingCommand {
        let scale = min(max(0.5, speedScale), 1.5)
        let xC = applyDeadzone(x)
        let yC = applyDeadzone(y)
        let tC = applyDeadzone(turn)

        let strideBase = strideMmMax ?? legacyStrideMm
        let sideBase   = sideMmMax   ?? legacySideMm
        let turnBase   = turnDegMax  ?? legacyTurnDeg

        // y < 0 means "stick up" → forward stride (strideMm > 0).
        let strideMm = (-yC) * strideBase * scale
        let sideMm   = xC * sideBase * scale
        let turnDeg  = tC * turnBase * scale

        // **snap-to-zero (뒤로 걷기 잔존 fix)**: deadzone 통과 후 남는 미세 amplitude
        // (스틱 drift 기인 -2~-5mm 등)를 정확히 0 으로 → isStop=true → 정지/auto-disarm
        // 경로 → 잔존 후진 소거. 모든 입력 source(DJI/게임패드/마우스/키보드) 공통 적용.
        let strideSnapped = abs(strideMm) < strideStopEpsilonMm ? 0 : strideMm
        let sideSnapped   = abs(sideMm)   < sideStopEpsilonMm   ? 0 : sideMm
        let turnSnapped   = abs(turnDeg)  < turnStopEpsilonDeg  ? 0 : turnDeg

        // Clamp 범위 = base × 1.5 (speedScale 1.5 시 saturation 보호).
        return WalkingCommand(
            strideMm: clamp(strideSnapped, range: -(strideBase * 1.5)...(strideBase * 1.5)),
            sideMm:   clamp(sideSnapped,   range: -(sideBase * 1.5)...(sideBase * 1.5)),
            turnDeg:  clamp(turnSnapped,   range: -(turnBase * 1.5)...(turnBase * 1.5)))
    }

    private static func applyDeadzone(_ v: Double) -> Double {
        abs(v) < deadzone ? 0 : v
    }

    private static func clamp(_ value: Double, range: ClosedRange<Double>) -> Double {
        max(range.lowerBound, min(range.upperBound, value))
    }
}
