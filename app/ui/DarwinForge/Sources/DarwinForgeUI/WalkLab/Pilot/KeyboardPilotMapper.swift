import Foundation
import SwiftUI

/// **v1.20.2 (2026-05-22) 사이클 8 — Keyboard pilot input mapper**.
///
/// Tello / DJI 조종기가 없을 때도 macOS 키보드만으로 PilotIntent 파이프라인을
/// 작동시키는 가상 stick 매퍼. WASD = stride/side, QE = yaw, Space = emergency.
/// 사용자가 다중 키를 동시에 누르면 (예: W+D) 대각선 이동.
///
/// # 게임 캐릭터 비유
///
/// 일반 FPS 게임의 WASD 조종과 동일:
/// - W: 앞으로 (stride+)
/// - S: 뒤로 (stride-)
/// - A: 왼쪽 strafe (side-)
/// - D: 오른쪽 strafe (side+)
/// - Q: 좌회전 (yaw-)
/// - E: 우회전 (yaw+)
/// - Space: 비상 정지 (모든 모터 차단)
///
/// 화살표 키도 WASD 와 동일 매핑 (사용자 선택).
///
/// # 안전
///
/// 본 매퍼는 **순수 함수** — bridge 의 SafetyGate 가 별도 검증. emergency 만 즉시 발화.
/// 매핑 자체는 TelloRCMapper.map 을 재사용 — clamp / deadzone 일관성.

/// 키보드 입력의 의미적 키. macOS KeyEquivalent 의 추상화.
public enum PilotKey: Hashable, Sendable, CaseIterable {
    case forward     // W / ↑
    case backward    // S / ↓
    case left        // A / ←
    case right       // D / →
    case turnLeft    // Q
    case turnRight   // E
    case emergency   // Space

    /// 디스플레이 라벨 (사용자 UI 노출).
    public var label: String {
        switch self {
        case .forward:   return "W / ↑"
        case .backward:  return "S / ↓"
        case .left:      return "A / ←"
        case .right:     return "D / →"
        case .turnLeft:  return "Q"
        case .turnRight: return "E"
        case .emergency: return "Space"
        }
    }

    /// 한국어 설명.
    public var koreanDescription: String {
        switch self {
        case .forward:   return "전진"
        case .backward:  return "후진"
        case .left:      return "좌측 이동"
        case .right:     return "우측 이동"
        case .turnLeft:  return "좌회전"
        case .turnRight: return "우회전"
        case .emergency: return "긴급 정지"
        }
    }
}

/// 키보드 입력 → WalkingCommand 매핑 + 키 해석.
/// **v1.20.2.1 사이클 8-fix LOW (코덱스)** — Sendable 명시 (stateless 계약 명확화).
public enum KeyboardPilotMapper: Sendable {

    /// 현재 누르고 있는 키 set 을 가상 stick value (-100..100) → WalkingCommand 변환.
    /// 단일 키 = full 강도 (100), 조합 = 각 축 합산 (W+D = fb 100 + lr 100 = 대각선).
    /// 충돌 (W+S) = 0 (서로 상쇄).
    public static func mapToCommand(
        pressedKeys: Set<PilotKey>,
        scale: TelloRCMapper.Scale = .default
    ) -> WalkingCommand {
        var fb = 0
        var lr = 0
        var yaw = 0
        if pressedKeys.contains(.forward)   { fb += 100 }
        if pressedKeys.contains(.backward)  { fb -= 100 }
        if pressedKeys.contains(.left)      { lr -= 100 }
        if pressedKeys.contains(.right)     { lr += 100 }
        if pressedKeys.contains(.turnLeft)  { yaw -= 100 }
        if pressedKeys.contains(.turnRight) { yaw += 100 }
        // TelloRCMapper 재사용 — clamp + deadzone 일관성.
        return TelloRCMapper.map(lr: lr, fb: fb, ud: 0, yaw: yaw, scale: scale)
    }

    /// Space (emergency) 가 눌렸는지 — 별도 채널. handleEmergency 호출 신호.
    public static func isEmergencyPressed(_ pressedKeys: Set<PilotKey>) -> Bool {
        pressedKeys.contains(.emergency)
    }

    /// SwiftUI `KeyEquivalent` → `PilotKey` resolution. nil = 모르는 키.
    /// W/A/S/D/Q/E + 화살표 + Space 만 인식.
    public static func resolve(_ key: KeyEquivalent) -> PilotKey? {
        // KeyEquivalent.character 로 비교.
        switch key.character {
        case "w", "W", "\u{F700}": return .forward     // \u{F700} = NSUpArrowFunctionKey
        case "s", "S", "\u{F701}": return .backward
        case "a", "A", "\u{F702}": return .left
        case "d", "D", "\u{F703}": return .right
        case "q", "Q":              return .turnLeft
        case "e", "E":              return .turnRight
        case " ":                   return .emergency
        default: break
        }
        // SwiftUI 의 static 화살표 키도 비교.
        if key == .upArrow    { return .forward }
        if key == .downArrow  { return .backward }
        if key == .leftArrow  { return .left }
        if key == .rightArrow { return .right }
        if key == .space      { return .emergency }
        return nil
    }

    /// 본 매퍼가 처리할 모든 KeyEquivalent — onKeyPress 의 keys 파라미터에 전달.
    /// **v1.20.4 사이클 10**: 0-7 숫자 키 추가 — preset 단축키.
    public static let allHandledKeys: [KeyEquivalent] = [
        "w", "a", "s", "d", "q", "e",
        .upArrow, .downArrow, .leftArrow, .rightArrow,
        .space,
        "0", "1", "2", "3", "4", "5", "6", "7"
    ]

    /// **v1.20.4 사이클 10** — 숫자 키 → WalkLabPreset 매핑 (게임 컨트롤러 단축키).
    /// 0 = idle (stop), 1=march, 2=slowWalk, 3=normalWalk, 4=fastWalk,
    /// 5=jog (highRisk), 6=turnLeft, 7=turnRight.
    /// `nil` = 매핑 없는 키 (8, 9, A, B 등).
    public static func resolvePreset(_ key: KeyEquivalent) -> WalkLabPreset? {
        switch key.character {
        case "0": return .idle
        case "1": return .march
        case "2": return .slowWalk
        case "3": return .normalWalk
        case "4": return .fastWalk
        case "5": return .jog
        case "6": return .turnLeft
        case "7": return .turnRight
        default:  return nil
        }
    }
}
