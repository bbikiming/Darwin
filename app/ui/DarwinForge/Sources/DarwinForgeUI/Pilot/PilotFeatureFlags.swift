import Foundation

/// Remote Pilot v1.0~v2 단계별 활성화 플래그.
///
/// PRD §4.1 "한 번 설계, 단계별 활성화" 원칙. 같은 UI 코드가 빌드 변경 한 줄로
/// v1.0 → v1.1 → v1.5 → v2 로 점진 활성화. UserDefaults
/// `df.pilot.featureLevel` 로 베타/개발 빌드에서 override 가능.
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

    /// v1.1 — IMU 텔레메트리 + 자동 낙상 복구 + head 추적 추가.
    public static let v1_1: PilotFeatureFlags = {
        var f = v1_0
        f.imuTelemetry = true
        f.autoRecovery = true
        f.headTracking = true
        f.ballFollow = true   // head 추적만, walk OFF — engine 내부 분기
        return f
    }()

    /// v1.5 — 카메라, HSV 튜닝, bridge, "+ 더 보기", page chain 활성.
    public static let v1_5: PilotFeatureFlags = {
        var f = v1_1
        f.actionBarMore = true
        f.camera = true
        f.hsvTuning = true
        f.bridgeNetwork = true
        f.pageChain = true
        return f
    }()

    /// v2 — D-pad 실 모터 송출 + mp3 동기.
    public static let v2: PilotFeatureFlags = {
        var f = v1_5
        f.dpadRealMotor = true
        f.mp3Playback = true
        return f
    }()

    /// 런타임 active level — UserDefaults override 가능.
    public static let active: PilotFeatureFlags = {
        let raw = UserDefaults.standard.string(forKey: "df.pilot.featureLevel")
        switch raw {
        case "v1.1": return .v1_1
        case "v1.5": return .v1_5
        case "v2":   return .v2
        case "v1.0", nil, .some(""): return .v1_0
        default: return .v1_0
        }
    }()
}
