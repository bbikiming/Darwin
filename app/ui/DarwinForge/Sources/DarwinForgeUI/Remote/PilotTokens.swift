import SwiftUI

/// Remote Pilot 전용 색상 + 애니메이션 토큰. PRD §6.
public enum PilotColor {
    /// ARM 슬라이더 활성 + 강조.
    public static let armed        = Color(red: 0.10, green: 0.55, blue: 0.85)  // DFNeon.electric
    /// E-Stop 버튼.
    public static let estop        = Color(red: 0.95, green: 0.20, blue: 0.20)
    /// HighRisk 경고 표시.
    public static let highRisk     = Color(red: 0.95, green: 0.55, blue: 0.10)
    /// Caution 표시.
    public static let caution      = Color(red: 0.90, green: 0.75, blue: 0.10)
    /// 활성 모션 progress ring.
    public static let progressRing = Color(red: 0.10, green: 0.55, blue: 0.85)
    /// 준비 중 오버레이 배경.
    public static let comingSoon   = Color.black.opacity(0.45)
    /// D-pad 기본 버튼.
    public static let dpadButton   = Color.white.opacity(0.08)
    /// D-pad 눌림 강조.
    public static let dpadPressed  = Color(red: 0.10, green: 0.55, blue: 0.85).opacity(0.35)
}

public enum PilotAnim {
    /// ARM 슬라이더 spring 반환.
    public static let sliderReturn  = Animation.spring(response: 0.4, dampingFraction: 0.6)
    /// E-Stop flash.
    public static let estopFlash    = Animation.easeOut(duration: 0.3)
    /// 버튼 press feedback.
    public static let buttonPress   = Animation.easeInOut(duration: 0.08)
    /// 모드 picker 슬라이드.
    public static let modePicker    = Animation.spring(response: 0.35, dampingFraction: 0.75)
}
