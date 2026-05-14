import SwiftUI

/// DarwinForge 의미 팔레트 (Semantic Palettes).
///
/// `DFColor` 가 "원자 토큰"이라면, 본 파일은 그 토큰을 도메인 의미에 매핑한 alias 다.
/// 사용 측에서 `.red/.green/.orange` 대신 의미 이름으로 의도를 드러내기 위해 존재.
///
/// 근거:
/// - KS S ISO 7010 안전 색상 (위험=빨강, 주의=노랑, 정보=파랑, 안전=초록).
/// - WCAG 2.2 §1.4.11 Non-Text Contrast — 의미 전달 색상은 인접 배경 대비 ≥ 3.0:1.
/// - Apple HIG Color & Accessibility — Increase Contrast / Reduce Transparency 자동 적응.
/// - Coblis 색각 이상 시뮬레이션 — 적/녹 색각 이상자에게도 패턴/아이콘 동반 권장.

// MARK: - Safety Palette (위험/안전/주의/비활성)

/// 안전 정보 색상 — 로봇 동작/제어 영역의 위험 수준 표기.
///
/// 사용 위치:
/// - E-Stop 버튼, 복구/리커버리 액션, 모션 위험도 칩
/// - WalkLab simOnly 표시, 연결 상태 indicator
///
/// 색상은 모두 `DFColor` 의 원자 토큰을 alias 하며, 다크모드/HC 모드 자동 적응.
public enum DFSafetyColor {
    /// 안전 — 정상 동작, 연결됨, 검증된 모션.
    public static let safe: Color = DFColor.success
    /// 주의 — 한계 근접, 시뮬레이션 전용, 미검증 모션.
    public static let caution: Color = DFColor.warning
    /// 위험 — E-Stop, fault, 미연결, 안전선 외 모션.
    public static let highRisk: Color = DFColor.danger
    /// 비활성 — disabled, 대기, N/A.
    public static let disabled: Color = DFColor.textSecondary.opacity(DFOpacity.disabled)
}

// MARK: - Load Palette (토크/부하 4단계)

/// 토크/부하 4단계 — 모터 부하 모니터링용.
///
/// 사용 위치:
/// - TorqueLoadGrid, TorqueLoadSidebar
/// - Joint load 표시, IMU 가속도 한계 표시
///
/// 4단계:
/// - normal (≤ 60%) = success (초록)
/// - moderate (60-80%) = warning (노랑)
/// - high (80-95%) = highRisk (주황) — DFColor 미존재 → light/dark hex
/// - critical (≥ 95%) = danger (빨강)
public enum DFLoadColor {
    /// 정상 부하 — 60% 이하.
    public static let normal: Color = DFColor.success
    /// 보통 부하 — 60% ~ 80%.
    public static let moderate: Color = DFColor.warning
    /// 높은 부하 — 80% ~ 95%. 주황 (warning 보다 진함, danger 보다 옅음).
    public static let high: Color = Color(light: "#FF7A1A", dark: "#FF9F0A")
    /// 임계 부하 — 95% 이상. 즉시 조치 필요.
    public static let critical: Color = DFColor.danger
    /// 측정 불가 / 비활성.
    public static let unknown: Color = DFColor.textSecondary.opacity(DFOpacity.disabled)

    /// 0.0 ~ 1.0 부하율을 받아 단계별 색상 반환.
    /// - Parameter ratio: 0.0 (no load) ~ 1.0+ (overload).
    public static func color(forRatio ratio: Double) -> Color {
        switch ratio {
        case ..<0.6: return normal
        case 0.6..<0.8: return moderate
        case 0.8..<0.95: return high
        default: return critical
        }
    }
}

// MARK: - Connection Palette (연결 상태 4단계)

/// 연결 상태 색상 — Connection / Pilot / WalkLab 헤더 indicator.
///
/// `ConnectionStore.Status` 와 1:1 매핑되어 모든 화면이 같은 색을 사용한다.
public enum DFConnectionColor {
    /// 연결됨 — 실 로봇 telemetry 수신.
    public static let connected: Color = DFColor.success
    /// 연결 중 / reconnect.
    public static let connecting: Color = DFColor.warning
    /// 연결 안 됨 — 오프라인.
    public static let disconnected: Color = DFColor.textSecondary
    /// 연결 오류 — 명시적 실패 상태.
    public static let error: Color = DFColor.danger
    /// 시뮬레이션 전용 — 실 로봇 없이 동작.
    public static let simOnly: Color = DFColor.info
}

// MARK: - Chart Palette (Telemetry 6채널)

/// 텔레메트리/진단 차트 6채널 팔레트.
///
/// 근거: ColorBrewer Set1 (qualitative, 색각 이상 안전), Apple Charts default 변형.
/// gyro/accel 3축은 X(빨강)/Y(초록)/Z(파랑) RGB 통상 매핑 유지.
/// filter/raw 비교는 보조 채널 (purple/orange) 사용.
public enum DFChartPalette {
    // MARK: - Gyro 3-axis (rad/s)
    public static let gyroX: Color = Color(light: "#E41A1C", dark: "#FF6B6D")  // 빨강
    public static let gyroY: Color = Color(light: "#4DAF4A", dark: "#7FE07B")  // 초록
    public static let gyroZ: Color = Color(light: "#377EB8", dark: "#6FAFE0")  // 파랑

    // MARK: - Accel 3-axis (m/s²)
    public static let accelX: Color = Color(light: "#984EA3", dark: "#C68AD1")  // 보라
    public static let accelY: Color = Color(light: "#FF7F00", dark: "#FFAE5C")  // 주황
    public static let accelZ: Color = Color(light: "#A65628", dark: "#D49070")  // 갈색

    // MARK: - Filter / Raw 비교
    /// Raw signal — 강한 색 (원본).
    public static let raw: Color = Color(light: "#E41A1C", dark: "#FF6B6D")
    /// Filtered signal — 차분한 색 (가공).
    public static let filtered: Color = Color(light: "#377EB8", dark: "#6FAFE0")
    /// Reference / target.
    public static let reference: Color = DFColor.textSecondary

    // MARK: - Phase (보행 단계)
    /// 양발 지지 (DSP).
    public static let phaseDSP: Color = DFColor.info
    /// 단발 지지 (SSP) — 왼발.
    public static let phaseSSPL: Color = Color(light: "#984EA3", dark: "#C68AD1")
    /// 단발 지지 (SSP) — 오른발.
    public static let phaseSSPR: Color = Color(light: "#FF7F00", dark: "#FFAE5C")
    /// 비행/스윙.
    public static let phaseSwing: Color = DFColor.torque

    /// 3축 gyro 채널 순회용.
    public static let gyroAxes: [Color] = [gyroX, gyroY, gyroZ]
    /// 3축 accel 채널 순회용.
    public static let accelAxes: [Color] = [accelX, accelY, accelZ]
}

// MARK: - Motion Safety Palette (모션 라이브러리)

/// 모션 라이브러리의 안전 등급 색상.
///
/// MotionLibraryView, PoseLibrary 의 safety category 표시용.
public enum DFMotionSafetyColor {
    /// 검증됨 — 실 로봇에서 안전 확인.
    public static let verified: Color = DFSafetyColor.safe
    /// 미검증 — 시뮬레이션만, 실 로봇 미사용.
    public static let unverified: Color = DFSafetyColor.caution
    /// 위험 — 실 로봇 사용 금지 / 검증 실패.
    public static let dangerous: Color = DFSafetyColor.highRisk
    /// 비활성 — 보관용 / 사용 안 함.
    public static let archived: Color = DFSafetyColor.disabled
}
