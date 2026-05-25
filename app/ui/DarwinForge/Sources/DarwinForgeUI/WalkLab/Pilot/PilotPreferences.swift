import Foundation
import SwiftUI

/// **v1.22.0 (2026-05-22) — 사이클 84: pilot 사용자 설정 영속화 모델**.
///
/// `WalkLabRCBridge.scale` (sensitivity) + `smoothingFactor` 가 매 launch 마다 default
/// 초기화 → 사용자가 매번 재설정해야 함. 본 model + Store 가 UserDefaults 에 영속.
///
/// # 비유
///
/// 게임 컨트롤러 sensitivity slider — 한 번 설정하면 다음 게임 세션에도 유지.
/// 본 model 은 사용자 선호 조작 감도 / 부드러움 4 차원을 묶어 한 번에 저장.
///
/// # 4 차원
///
/// - `scaleLR`: side stick 감도 (default 0.3 — TelloRCMapper.Scale.default)
/// - `scaleFB`: forward/back stick 감도 (default 0.4)
/// - `scaleYaw`: turn stick 감도 (default 0.2)
/// - `smoothingFactor`: EMA α (default 1.0 = no smooth, 0.5 = 게임 UX)
public struct PilotPreferences: Equatable, Codable, Sendable {
    public let scaleLR: Double
    public let scaleFB: Double
    public let scaleYaw: Double
    public let smoothingFactor: Double

    public init(scaleLR: Double, scaleFB: Double, scaleYaw: Double, smoothingFactor: Double) {
        self.scaleLR = scaleLR
        self.scaleFB = scaleFB
        self.scaleYaw = scaleYaw
        self.smoothingFactor = smoothingFactor
    }

    /// TelloRCMapper.Scale.default 와 동기 + smoothing 1.0 (no smooth).
    public static let defaultValues = PilotPreferences(
        scaleLR: 0.3, scaleFB: 0.4, scaleYaw: 0.2, smoothingFactor: 1.0
    )
}

/// 사용자 설정 영속화 store 추상화 — production (UserDefaults) + test (InMemory).
public protocol PilotPreferencesStore: Sendable {
    func load() -> PilotPreferences
    func save(_ prefs: PilotPreferences)
}

/// In-memory 구현 — 테스트 / preview 용.
public final class InMemoryPilotPreferencesStore: PilotPreferencesStore, @unchecked Sendable {
    private var _prefs: PilotPreferences = .defaultValues
    private let lock = NSLock()

    public init() {}

    public func load() -> PilotPreferences {
        lock.lock()
        defer { lock.unlock() }
        return _prefs
    }

    public func save(_ prefs: PilotPreferences) {
        lock.lock()
        defer { lock.unlock() }
        _prefs = prefs
    }
}

/// UserDefaults 기반 구현 — production app launch 간 영속.
///
/// # Key schema (v1)
///
/// - `pilot.scaleLR.v1` (Double)
/// - `pilot.scaleFB.v1` (Double)
/// - `pilot.scaleYaw.v1` (Double)
/// - `pilot.smoothingFactor.v1` (Double)
///
/// 4개 key 모두 존재해야 load 가 saved value 반환 — 부분 corrupt 시 default fallback.
/// 향후 schema 변경 시 `.v2` 사용 + migration helper 추가.
public final class UserDefaultsPilotPreferencesStore: PilotPreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults

    private static let keyLR  = "pilot.scaleLR.v1"
    private static let keyFB  = "pilot.scaleFB.v1"
    private static let keyYaw = "pilot.scaleYaw.v1"
    private static let keySmooth = "pilot.smoothingFactor.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PilotPreferences {
        // **사이클 88 — 코덱스 MEDIUM-1 fix**: type-safe Double cast.
        // 종전: `defaults.double(forKey:)` 가 String corrupt 시 silent 0.0 반환 →
        // scale.fb = 0 → stick 입력 무효화 (게임 캐릭터 멈춤). 사용자 진단 불가.
        // 신규: `object(forKey:) as? Double` 패턴 — Double 아니면 nil → default fallback.
        guard let lr     = defaults.object(forKey: Self.keyLR)     as? Double,
              let fb     = defaults.object(forKey: Self.keyFB)     as? Double,
              let yaw    = defaults.object(forKey: Self.keyYaw)    as? Double,
              let smooth = defaults.object(forKey: Self.keySmooth) as? Double else {
            return .defaultValues
        }
        return PilotPreferences(
            scaleLR: lr, scaleFB: fb, scaleYaw: yaw, smoothingFactor: smooth
        )
    }

    public func save(_ prefs: PilotPreferences) {
        defaults.set(prefs.scaleLR,         forKey: Self.keyLR)
        defaults.set(prefs.scaleFB,         forKey: Self.keyFB)
        defaults.set(prefs.scaleYaw,        forKey: Self.keyYaw)
        defaults.set(prefs.smoothingFactor, forKey: Self.keySmooth)
    }
}

// MARK: - SwiftUI Environment 전파 (RootView → WalkLabView → PilotSettingsPanel)
//
// `PilotPreferencesStore` 는 protocol 이라 `@EnvironmentObject` 사용 불가
// (ObservableObject 미준수, sendable 한 단순 store). 본 환경 키가 부모 view
// 가 자식 view 에 instance 를 명시 전파하는 통로.

/// 환경 기본값 — in-memory store. 실 propagate 안 된 view 에선 영속 안 됨 (안전 fallback).
///
/// CI fix (2026-05-25, PR #42): `@preconcurrency EnvironmentKey` syntax 는
/// Xcode 16+ / Swift 6 에서만 받아들임. CI macos-14 default Xcode 는 거부 →
/// 해당 attribute 를 제거하고 일반 declaration 으로 변경.
private struct PilotPreferencesStoreEnvKey: EnvironmentKey {
    static let defaultValue: PilotPreferencesStore = InMemoryPilotPreferencesStore()
}

public extension EnvironmentValues {
    /// `@Environment(\.pilotPreferencesStore)` 로 자식 view 가 접근.
    /// RootView 가 launch 시 UserDefaults backed store 를 `.environment(\.pilotPreferencesStore, ...)`
    /// 로 주입 → WalkLabView → PilotSettingsPanel 까지 자동 전파.
    var pilotPreferencesStore: PilotPreferencesStore {
        get { self[PilotPreferencesStoreEnvKey.self] }
        set { self[PilotPreferencesStoreEnvKey.self] = newValue }
    }
}
