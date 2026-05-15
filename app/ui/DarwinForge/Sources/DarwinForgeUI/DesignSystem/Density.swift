import SwiftUI

/// 화면 밀도 (Density) — 일반 / 전문가 / 데이터 dense.
///
/// 같은 컴포넌트라도 사용 맥락에 따라 spacing / touch target / font scale 이 달라야 한다.
///
/// 근거:
/// - Apple HIG Touch Targets — 일반 화면 44pt+ 권장, 키보드 중심 데스크탑은 28pt 까지 허용.
/// - Bloomberg Terminal / Linear 명령 팔레트 — 데이터 dense 에선 24pt 행 + 11pt 폰트.
/// - macOS Sidebar Wide 라이트모드 동시 시인성.
public enum DFDensity {
    /// 일반 사용자 화면 — Studio, Conversation, Teach, RemotePilot, MotionLibrary.
    ///
    /// 행 높이 ≥ 32pt, 폰트 ≥ 12pt, gutter ≥ 12pt.
    case regular
    /// 전문가/setup wizard — ConnectionWizard, Strategy, ExpertDashboard.
    ///
    /// 행 높이 ≥ 28pt, 폰트 ≥ 11pt, gutter ≥ 10pt.
    case compact
    /// 모니터링/진단 (Bloomberg style) — WalkDiagnostics, IMU 스트립차트.
    ///
    /// 행 높이 ≥ 22pt, 폰트 ≥ 10pt, gutter ≥ 8pt. 키보드 우선.
    case dataDense

    /// 본 density 의 표준 inner padding.
    public var innerPadding: CGFloat {
        switch self {
        case .regular: return DFSpace.md           // 16
        case .compact: return DFSpace.sm3          // 12
        case .dataDense: return DFSpace.sm         // 8
        }
    }
    /// 본 density 의 표준 행 높이.
    public var rowHeight: CGFloat {
        switch self {
        case .regular: return 32
        case .compact: return 28
        case .dataDense: return 22
        }
    }
    /// 본 density 의 본문 폰트 크기.
    public var bodyFontSize: CGFloat {
        switch self {
        case .regular: return DFFontSize.s12       // 12
        case .compact: return DFFontSize.s11       // 11
        case .dataDense: return DFFontSize.s10     // 10
        }
    }
    /// 본 density 의 캡션 폰트 크기.
    public var captionFontSize: CGFloat {
        switch self {
        case .regular: return DFFontSize.s11       // 11
        case .compact: return DFFontSize.s10       // 10
        case .dataDense: return DFFontSize.s9      // 9
        }
    }
    /// 본 density 의 row gutter (HStack spacing).
    public var rowGutter: CGFloat {
        switch self {
        case .regular: return DFSpace.sm3          // 12
        case .compact: return DFSpace.sm2          // 10
        case .dataDense: return DFSpace.sm         // 8
        }
    }
}

// MARK: - DFLayout — 패널/사이드바/모달 width 토큰

/// 화면 layout 의 고정 width/height 토큰.
///
/// 사용 규칙:
/// - `.frame(width: 240)` 같은 raw 호출 대신 본 토큰 이름으로 의도를 드러낸다.
/// - 토큰에 없는 width가 필요하면 본 enum 에 추가 (코드에 raw 분산 금지).
public enum DFLayout {
    // MARK: - Sidebar widths
    /// 좌측 메인 사이드바 collapsed (≈ icon-only) 폭.
    public static let sidebarCompact: CGFloat = 64
    /// 좌측 메인 사이드바 regular 폭 (icon + label).
    public static let sidebarRegular: CGFloat = 200
    /// 좌측 메인 사이드바 wide 폭 (icon + label + secondary info).
    public static let sidebarWide: CGFloat = 240
    /// 우측 인스펙터 패널 폭.
    public static let inspector: CGFloat = 320
    /// WalkLab/Diagnostics 좌측 컨트롤 패널 폭.
    public static let diagnosticLeft: CGFloat = 280
    /// WalkLab/Diagnostics 우측 raw data 패널 폭.
    public static let diagnosticRight: CGFloat = 300
    /// MotionLibrary detail card 폭.
    public static let motionDetail: CGFloat = 360
    /// Connection wizard step card 폭.
    public static let wizardStep: CGFloat = 560

    // MARK: - Modal / Dialog sizes
    public static let modalSmall: (w: CGFloat, h: CGFloat) = (w: 360, h: 240)
    public static let modalMedium: (w: CGFloat, h: CGFloat) = (w: 520, h: 380)
    public static let modalLarge: (w: CGFloat, h: CGFloat) = (w: 720, h: 520)

    // MARK: - Toolbar / Topbar
    /// 메인 윈도우 topbar 높이.
    public static let topbarH: CGFloat = 44
    /// Pilot diagnostics strip 높이.
    public static let pilotStripH: CGFloat = 28
    /// Pilot/Walk 헤더 높이.
    public static let headerH: CGFloat = 56
}

// MARK: - DFDataLayout — 차트/테이블/divider

/// 데이터 dense 화면 (차트, 테이블)의 표준 크기.
///
/// WalkDiagnostics / IMU 스트립차트 / Phase ribbon 에서만 사용.
public enum DFDataLayout {
    // MARK: - Chart heights
    /// 작은 sparkline / mini chart.
    public static let chartHSmall: CGFloat = 60
    /// 중간 strip chart (IMU 단일 축).
    public static let chartHMedium: CGFloat = 96
    /// 큰 telemetry chart (multi-axis).
    public static let chartHLarge: CGFloat = 140
    /// 풀 사이즈 진단 차트.
    public static let chartHFull: CGFloat = 220

    // MARK: - Table columns (Walk Diagnostics raw data table)
    public static let tableColTime: CGFloat = 80
    public static let tableColSignal: CGFloat = 110
    public static let tableColPhase: CGFloat = 90

    // MARK: - Divider / Stroke
    /// Divider 두께 (수평선 / 수직선 통일).
    public static let dividerH: CGFloat = 1
    /// Phase ribbon segment 두께.
    public static let phaseSegmentH: CGFloat = 6

    // MARK: - Code block (Remote Shell)
    public static let codeBlockMinH: CGFloat = 80
    public static let codeBlockMaxH: CGFloat = 360
    /// Command input button (send/copy) 폭.
    public static let commandInputButton: CGFloat = 80
}

// MARK: - View modifier — density 적용 helper

public extension View {
    /// 본 view 의 환경 density 를 지정한다. 자식 컴포넌트가 `@Environment(\.dfDensity)` 로 읽음.
    func dfDensity(_ density: DFDensity) -> some View {
        environment(\.dfDensity, density)
    }
}

private struct DFDensityKey: EnvironmentKey {
    static let defaultValue: DFDensity = .regular
}

public extension EnvironmentValues {
    /// 현재 화면의 density. 기본값 `.regular`.
    var dfDensity: DFDensity {
        get { self[DFDensityKey.self] }
        set { self[DFDensityKey.self] = newValue }
    }
}
