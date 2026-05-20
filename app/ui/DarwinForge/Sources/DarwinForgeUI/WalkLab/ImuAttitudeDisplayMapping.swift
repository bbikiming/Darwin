import Foundation

/// **v1.11.19 (2026-05-20)** — 표시 전용 IMU pitch/roll 정규화 helper.
///
/// 모든 UI 컴포넌트 (3D viewport, LiveGyroPanel, SceneGyroMiniOverlay,
/// IMUGauge, CircularGyroMeter) 가 동일한 display 값을 사용하도록 보장.
///
/// **표시 전용** — 로봇 명령 송출, corrector 계산, motor write 에 사용하지 마세요.
///
/// 처리:
/// 1. NaN / Inf → 0 치환
/// 2. pitch convention 정규화 (`.imuRaw` → 그대로, `.negateForwardIsNegative` → 부호 반전)
/// 3. ±`clampDeg` 범위 clamp (display saturation)
public enum ImuAttitudeDisplayMapping {

    /// display clamp 한계 (deg). BalanceState.emergency = 50° 정합.
    public static let defaultClampDeg: Double = 50.0

    /// raw IMU 값 → display 값 변환.
    ///
    /// - Parameters:
    ///   - rawRoll: `WalkLabSession.imuRollDeg` (raw).
    ///   - rawPitch: `WalkLabSession.imuPitchDeg` (raw).
    ///   - convention: `BalancePitchInputConvention` — pitch 부호 정규화 방향.
    ///   - clampDeg: display clamp 한계. default 50°.
    /// - Returns: `(displayRoll, displayPitch)` — 모든 UI 에서 공유할 값.
    public static func map(
        rawRoll: Double,
        rawPitch: Double,
        convention: BalancePitchInputConvention,
        clampDeg: Double = defaultClampDeg
    ) -> (roll: Double, pitch: Double) {
        let safeRoll = rawRoll.isFinite ? rawRoll : 0
        var safePitch = rawPitch.isFinite ? rawPitch : 0

        switch convention {
        case .imuRaw:
            break
        case .negateForwardIsNegative:
            safePitch = -safePitch
        }

        let clampedRoll = max(-clampDeg, min(clampDeg, safeRoll))
        let clampedPitch = max(-clampDeg, min(clampDeg, safePitch))

        return (clampedRoll, clampedPitch)
    }

    /// 단일 축 NaN/Inf guard + clamp. roll 에 사용 (convention 무관).
    public static func sanitize(_ value: Double, clampDeg: Double = defaultClampDeg) -> Double {
        let safe = value.isFinite ? value : 0
        return max(-clampDeg, min(clampDeg, safe))
    }

    /// convention + NaN/Inf guard **without** clamp — 진단 UI 숫자용.
    ///
    /// `map()` 의 ±50° clamp 는 그래픽 보호용. L3 status tile 등
    /// 진단 숫자는 raw 70° 도 70° 로 표시해야 정보 손실 없음.
    public static func normalizeConvention(
        rawRoll: Double,
        rawPitch: Double,
        convention: BalancePitchInputConvention
    ) -> (roll: Double, pitch: Double) {
        let safeRoll = rawRoll.isFinite ? rawRoll : 0
        var safePitch = rawPitch.isFinite ? rawPitch : 0
        if convention == .negateForwardIsNegative {
            safePitch = -safePitch
        }
        return (safeRoll, safePitch)
    }
}
