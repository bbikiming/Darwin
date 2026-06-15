import SwiftUI

/// **텔레메트리 경로/엔진 모드 (SSH 온보드 ↔ LAN 패리티, W5)**.
///
/// # 비유
///
/// 자동차 계기판이 "엔진 직결 센서"로 읽는지 "OBD 스캐너"로 읽는지에 따라 표시
/// 신뢰도가 다른 것과 같다. LAN(5530 브리지)은 Mac `Bus` 가 모든 값(전압·IMU·
/// 관절·온도)을 직접 폴링하지만, 온보드(SSH)는 로봇이 `/tmp/df-walklab-telemetry`
/// 에 쓴 IMU·전압만 받아온다(관절/온도 없음). 어느 경로인지 UI 가 정직하게 표시
/// 해야 사용자가 "초록불=실시간"을 오해하지 않는다.
///
/// # 계약 (ssh-parity-contract §D.5)
///
/// `ConnectionStore.telemetryMode` (W3 선언)를 뷰(W5)가 읽어 다음을 구동한다:
/// - 경로/엔진 배지 ("온보드(SSH)" vs "Mac 키프레임/LAN")
/// - staleness 탈색 (`!isLive` 또는 `.onboardStale` → HUD 숫자 desaturate)
/// - 온도 pill (`!hasThermal` → "열 오프라인")
/// - "안전게이트" 배너 (`safetyBanner` — Mac 게이트 실제 동작 여부; 온보드는 "로봇 자율")
public enum TelemetryMode: String, Sendable, Equatable {
    /// 5530 브리지 → Mac `Bus` 폴링 (전체: 전압+IMU+관절+온도).
    case lan
    /// SSH 업링크 라이브 (전압+IMU; 관절/온도 없음).
    case onboard
    /// 온보드 선택됐으나 1.5초 내 신선 샘플 없음.
    case onboardStale
    /// 라이브 데이터 없음.
    case offline

    /// 신선한 텔레메트리가 흐르는가 (HUD 탈색/표시용). LAN·온보드 라이브 모두 true.
    public var isLive: Bool { self == .lan || self == .onboard }

    /// L4 열 게이트가 동작 가능한가 — 온보드 모드는 관절 온도가 없어 LAN 에서만 true.
    public var hasThermal: Bool { self == .lan }

    /// **정직성 fix (2026-06-02, codex HIGH)**: Mac-side L0(전압)/L3(기울기)/L4(열) 비상
    /// 게이트가 **실제로 동작**하는가. 온보드는 bus 가 없어 그 게이트들이 안 돌고(전압=미상,
    /// onboard roll/pitch 미계산) → **온라인 아님**. 온보드 안전은 로봇 demo 자체가 담당
    /// (자동 일어나기/정지). 종전: `isLive` 로 판단해 온보드를 "안전게이트 온라인"으로 거짓 표시.
    public enum SafetyBannerLevel { case ok, caution, danger }
    public var safetyBanner: (text: String, level: SafetyBannerLevel) {
        switch self {
        case .lan:          return ("안전게이트 온라인 — Mac 모니터링(전압·기울기·열)", .ok)
        case .onboard:      return ("안전게이트: 로봇 자율 — Mac 게이트 미작동", .caution)
        case .onboardStale: return ("텔레메트리 지연 — SSH 응답 확인", .caution)
        case .offline:      return ("안전게이트 오프라인", .danger)
        }
    }

    /// 짧은 한국어 라벨.
    public var label: String {
        switch self {
        case .lan:          return "LAN"
        case .onboard:      return "온보드"
        case .onboardStale: return "온보드(지연)"
        case .offline:      return "오프라인"
        }
    }

    /// 경로/엔진 배지 풀 라벨 — 사용자가 "어느 경로로 걷는가"를 한눈에.
    public var pathLabel: String {
        switch self {
        case .lan:          return "Mac 키프레임/LAN"
        case .onboard:      return "온보드(SSH)"
        case .onboardStale: return "온보드(SSH·지연)"
        case .offline:      return "경로 없음"
        }
    }

    /// SF Symbol — 배지/배너 아이콘.
    public var iconSystemName: String {
        switch self {
        case .lan:          return "cable.connector"
        case .onboard:      return "cpu.fill"
        case .onboardStale: return "cpu"
        case .offline:      return "wifi.slash"
        }
    }

    /// 데이터가 신선하지 않아 HUD 숫자를 탈색(desaturate)해야 하는가.
    /// `!isLive` (오프라인) 또는 온보드 지연 시 true.
    public var shouldDesaturate: Bool { !isLive || self == .onboardStale }

    /// 디자인 시스템 상태색 — 배지/배너 tint.
    public var tint: Color {
        switch self {
        case .lan:          return DFColor.success
        case .onboard:      return DFColor.success
        case .onboardStale: return DFColor.warning
        case .offline:      return DFColor.textSecondary
        }
    }
}
