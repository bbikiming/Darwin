import SwiftUI

/// Remote Pilot 전용 색/애니메이션 토큰 (PRD §6).
/// 기존 DFColor / DFAnimation 위에서 의미 라벨만 부여.
public enum PilotColor {
    public static let dpadActive    = DFColor.accent
    public static let dpadIdle      = DFColor.elev2
    public static let speedSafe     = DFColor.success
    public static let speedCaution  = DFColor.warning
    public static let speedDanger   = DFColor.danger

    public static let stateIdle     = DFColor.textSecondary
    public static let stateLooking  = DFColor.warning
    public static let stateApproach = DFColor.accent
    public static let stateLockedOn = DFColor.success
    public static let stateLost     = DFColor.danger

    public static let holdCharging  = DFColor.warning
    public static let holdFull      = DFColor.danger

    public static let safetySafe     = DFColor.success
    public static let safetyCaution  = DFColor.warning
    public static let safetyHighRisk = DFColor.danger

    public static let headReticle   = DFColor.info
    public static let ballReticle   = DFColor.forge
    public static let comingSoon    = DFColor.warning

    /// ARM 슬라이더 그라데이션 — 미장착 → 장착.
    public static let armUnlocked   = DFColor.forge
    public static let armLocked     = DFColor.success
}

public enum PilotAnim {
    public static let dpadPress      = Animation.spring(response: 0.12, dampingFraction: 0.7)
    public static let stateChange    = Animation.spring(response: 0.35, dampingFraction: 0.75)
    public static let gauge          = Animation.easeOut(duration: 0.22)
    public static let motionProgress = Animation.linear(duration: 0.25)
    public static let modeSwitch     = Animation.easeInOut(duration: 0.30)
    public static let lockPop        = Animation.spring(response: 0.25, dampingFraction: 0.5)
    public static let blobTrack      = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.85)
    public static let headTrack      = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.85)
    public static let fallRecovery   = Animation.easeInOut(duration: 0.4)
    public static let flashRed       = Animation.easeOut(duration: 0.3)
}
