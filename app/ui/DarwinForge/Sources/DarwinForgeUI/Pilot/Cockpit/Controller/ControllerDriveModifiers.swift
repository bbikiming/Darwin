import Foundation

/// 데드맨 게이트 + 터보 스케일 — 이동/회전 주입값의 최종 변조 **순수 함수** 모음.
///
/// 드라이버 주입 직전에 적용한다. 안전 철학(PRD §13):
/// - 데드맨: enabled + 버튼 지정 + 비홀드 → 이동/회전 0. 버튼 미지정이면 게이트
///   불가로 보고 주행을 막지 않는다(설정 실수로 로봇이 벽돌이 되지 않게).
/// - 데드맨은 **이동/회전에만** 적용 — E-STOP/복구/머리는 게이트 대상이 아니다.
/// - 터보: 버튼 홀드 시 이동/회전 × `turboScale`, ±1 클램프.
public enum ControllerDriveModifiers {

    /// 터보 홀드 시 이동/회전 스케일 (1.0 = 변화 없음).
    public static let turboScale: Double = 1.3

    /// 데드맨 조건 충족 여부 — false 면 이동/회전 주입을 0 으로 게이트.
    public static func deadmanSatisfied(
        profile: ControllerBindingProfile,
        snapshot: ControllerSnapshot
    ) -> Bool {
        guard profile.deadmanEnabled, let index = profile.deadmanButtonIndex else {
            return true
        }
        return snapshot.button(index)
    }

    /// 터보 버튼 홀드 여부.
    public static func isTurboHeld(
        profile: ControllerBindingProfile,
        snapshot: ControllerSnapshot
    ) -> Bool {
        guard let index = profile.turboButtonIndex else { return false }
        return snapshot.button(index)
    }

    /// 이동/회전에 데드맨·터보를 적용한 최종 주입값.
    public static func modifiedDrive(
        leftX: Double, leftY: Double, turn: Double,
        deadmanSatisfied: Bool, turboHeld: Bool
    ) -> (leftX: Double, leftY: Double, turn: Double) {
        guard deadmanSatisfied else { return (0.0, 0.0, 0.0) }
        guard turboHeld else { return (leftX, leftY, turn) }
        func scaled(_ v: Double) -> Double { max(-1.0, min(1.0, v * turboScale)) }
        return (scaled(leftX), scaled(leftY), scaled(turn))
    }
}
