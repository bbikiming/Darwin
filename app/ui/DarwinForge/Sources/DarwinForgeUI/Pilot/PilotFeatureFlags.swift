import Foundation

/// Pilot feature 활성 단계 — UserDefaults `df.pilot.featureLevel` 의 enum 표현.
///
/// **Codex 권고 (2026-05-13)**: 이전 v1.0 은 `static let active` 라 앱 재시작 전까지 고정.
/// v1.5 부터는 `@AppStorage("df.pilot.featureLevel")` 로 즉시 반영. UI 의 feature picker
/// 가 raw value 를 set 하면 `RemotePilotView` 가 즉시 새 flags 로 rebuild.
public enum PilotFeatureLevel: String, CaseIterable, Sendable, Identifiable {
    case v1_0 = "v1.0"
    case v1_5 = "v1.5"

    public var id: String { rawValue }

    /// 사용자 표시 라벨.
    public var label: String {
        switch self {
        case .v1_0: return "v1.0 안정"
        case .v1_5: return "v1.5 진단+안전"
        }
    }

    /// 한 줄 설명 — tooltip.
    public var subtitle: String {
        switch self {
        case .v1_0:
            return "Action Bar 7 메인 페이지만 활성. 진단/추가 페이지 비활성."
        case .v1_5:
            return "v1.0 + 진단 패널 + 안전한 추가 페이지 (head/arm 단발). IMU/카메라/D-pad 실송출은 별도 Sprint."
        }
    }

    public var flags: PilotFeatureFlags {
        switch self {
        case .v1_0: return .v1_0
        case .v1_5: return .v1_5
        }
    }
}

/// Remote Pilot v1.0~v2 단계별 활성화 플래그.
///
/// PRD §4.1 "한 번 설계, 단계별 활성화" 원칙. 같은 UI 코드가 빌드 변경 한 줄로
/// v1.0 → v1.5 로 점진 활성화. v1.1 / v2 의 IMU/카메라/D-pad 실송출 등 FFI 필요 기능은
/// 별도 Sprint 에서 활성 — v1.5 에 임시로 켜면 "작동하는 것처럼 보이는 기능" 위험 (Codex 권고).
public struct PilotFeatureFlags: Sendable, Equatable {
    public var actionBarMain: Bool
    public var actionBarMore: Bool
    public var imuTelemetry: Bool
    public var autoRecovery: Bool
    public var headTracking: Bool
    public var ballFollow: Bool
    public var camera: Bool
    public var hsvTuning: Bool
    public var bridgeNetwork: Bool
    public var dpadRealMotor: Bool
    public var pageChain: Bool
    public var mp3Playback: Bool

    public init(
        actionBarMain: Bool,
        actionBarMore: Bool,
        imuTelemetry: Bool,
        autoRecovery: Bool,
        headTracking: Bool,
        ballFollow: Bool,
        camera: Bool,
        hsvTuning: Bool,
        bridgeNetwork: Bool,
        dpadRealMotor: Bool,
        pageChain: Bool,
        mp3Playback: Bool
    ) {
        self.actionBarMain = actionBarMain
        self.actionBarMore = actionBarMore
        self.imuTelemetry = imuTelemetry
        self.autoRecovery = autoRecovery
        self.headTracking = headTracking
        self.ballFollow = ballFollow
        self.camera = camera
        self.hsvTuning = hsvTuning
        self.bridgeNetwork = bridgeNetwork
        self.dpadRealMotor = dpadRealMotor
        self.pageChain = pageChain
        self.mp3Playback = mp3Playback
    }

    /// v1.0 — Action Bar 메인 7개 활성, 나머지 OFF.
    public static let v1_0 = PilotFeatureFlags(
        actionBarMain: true,  actionBarMore: false,
        imuTelemetry: false,  autoRecovery: false,
        headTracking: false,  ballFollow: false,
        camera: false,        hsvTuning: false,
        bridgeNetwork: false, dpadRealMotor: false,
        pageChain: false,     mp3Playback: false
    )

    /// v1.5 — Sprint 17 안전 범위 (Codex 권고 반영).
    ///
    /// **활성**:
    ///   - `actionBarMore`: + 더 보기 9 페이지 시트 (단, 7 개는 v1TargetPoseID nil 이라 거부됨)
    ///   - `bridgeNetwork`: 네트워크 endpoint UI 노출 — robot 측 `forge serve` 데몬 가정.
    ///
    /// **여전히 OFF** (별도 FFI / 외부 데몬 필요, "작동하는 것처럼 보이는" 위험 차단):
    ///   - `imuTelemetry` / `autoRecovery` / `headTracking` / `ballFollow`: CmController::read_imu 미구현.
    ///   - `camera` / `hsvTuning`: robot 측 mjpg-streamer 셋업 가이드 별도.
    ///   - `dpadRealMotor`: BLOCKER C3 (실 IK) 미해결.
    ///   - `pageChain` / `mp3Playback`: motion_play 라이브러리 추출 필요 + 라이선스.
    public static let v1_5: PilotFeatureFlags = {
        var f = v1_0
        f.actionBarMore = true
        f.bridgeNetwork = true
        return f
    }()

    /// 미래 단계 placeholder — 실제 활성 시 별도 PRD + Sprint.
    public static let v1_1_future: PilotFeatureFlags = {
        var f = v1_5
        f.imuTelemetry = true
        f.autoRecovery = true
        f.headTracking = true
        f.ballFollow = true
        return f
    }()

    public static let v2_future: PilotFeatureFlags = {
        var f = v1_1_future
        f.camera = true
        f.hsvTuning = true
        f.dpadRealMotor = true
        f.pageChain = true
        f.mp3Playback = true
        return f
    }()
}
