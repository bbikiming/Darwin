import SwiftUI

/// **v1.11.15 (2026-05-19)** — DarwinForge 테마 기능.
///
/// 세 가지 옵션:
/// - `system`: macOS 시스템 라이트/다크 자동 추적 (기본값).
/// - `lightFlat`: 흰색 플랫 — `.light` 강제 + 표면을 순백 톤으로 + 그림자 비활성.
///   사용자 요청 (2026-05-19) — "흰색의 플랫한 스타일의 GUI" 명시 옵션.
/// - `dark`: 다크 모드 강제 (어두운 환경 작업용).
///
/// 영속화: `UserDefaults` (key `DFTheme`).
/// 주입: `DarwinForgeApp` 이 `@StateObject` 로 보유하고
///       `.environmentObject(themeManager)` + `.environment(\.dfTheme, theme)` +
///       `.preferredColorScheme(theme.preferredColorScheme)` 로 root 에 적용.
public enum DFTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case lightFlat
    case dark

    public var id: String { rawValue }

    /// 사용자에게 보이는 라벨 (Picker / 메뉴).
    public var displayName: String {
        switch self {
        case .system:    return "시스템"
        case .lightFlat: return "흰색 플랫"
        case .dark:      return "다크"
        }
    }

    /// 짧은 설명 (Picker description / tooltip).
    public var helpText: String {
        switch self {
        case .system:    return "macOS 시스템 모드를 따릅니다 (라이트/다크 자동)."
        case .lightFlat: return "순백 배경 + 그림자 없는 평평한 표면. 화면이 밝고 단순합니다."
        case .dark:      return "다크 모드 강제. 어두운 환경에 적합."
        }
    }

    /// SF Symbol 이름 (메뉴 / 토글 UI).
    public var symbolName: String {
        switch self {
        case .system:    return "circle.lefthalf.filled"
        case .lightFlat: return "sun.max"
        case .dark:      return "moon.fill"
        }
    }

    /// SwiftUI `preferredColorScheme` 적용값. nil 이면 시스템 모드 따름.
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:    return nil
        case .lightFlat: return .light
        case .dark:      return .dark
        }
    }

    /// 플랫 모드 — 그림자/머터리얼/네온 효과 비활성화.
    /// 현재는 `lightFlat` 만 true. 향후 `darkFlat` 등 확장 가능.
    public var isFlat: Bool {
        self == .lightFlat
    }

    /// 흰색 톤 강제 여부 — canvas/card 를 순백 계열로 override.
    public var prefersWhiteSurfaces: Bool {
        self == .lightFlat
    }
}

/// 테마 매니저 — 단일 source of truth.
///
/// `DarwinForgeApp` 이 `@StateObject` 로 보유. UserDefaults 와 자동 동기화.
@MainActor
public final class DFThemeManager: ObservableObject {
    /// UserDefaults 영속화 키.
    public static let storageKey = "DFTheme"

    /// 현재 테마. 변경 시 자동으로 UserDefaults 에 기록.
    @Published public private(set) var theme: DFTheme

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        if let raw = userDefaults.string(forKey: Self.storageKey),
           let parsed = DFTheme(rawValue: raw) {
            self.theme = parsed
        } else {
            self.theme = .system
        }
    }

    private let defaults: UserDefaults

    /// 테마 지정. 같은 값이면 no-op (불필요한 publish 차단).
    public func setTheme(_ newTheme: DFTheme) {
        guard theme != newTheme else { return }
        theme = newTheme
        defaults.set(newTheme.rawValue, forKey: Self.storageKey)
    }

    /// 다음 테마로 순환 (메뉴 단축키 ⌘⇧T 용).
    public func cycle() {
        let all = DFTheme.allCases
        guard !all.isEmpty else { return }
        let idx = all.firstIndex(of: theme) ?? 0
        let next = all[(idx + 1) % all.count]
        setTheme(next)
    }
}

// MARK: - EnvironmentKey

/// SwiftUI 환경 키 — view modifier 들이 현재 테마를 읽어 분기.
///
/// 사용:
/// ```swift
/// @Environment(\.dfTheme) private var theme: DFTheme
/// ...
/// if theme.isFlat { ... } else { ... }
/// ```
private struct DFThemeEnvKey: EnvironmentKey {
    static let defaultValue: DFTheme = .system
}

public extension EnvironmentValues {
    var dfTheme: DFTheme {
        get { self[DFThemeEnvKey.self] }
        set { self[DFThemeEnvKey.self] = newValue }
    }
}

// MARK: - Notifications (메뉴 ↔ RootView 연결)

public extension Notification.Name {
    /// 메뉴 / 외부에서 테마 설정 요청. object 는 `DFTheme.rawValue` 문자열.
    static let dfSetTheme = Notification.Name("DarwinForge.SetTheme")
    /// 다음 테마로 순환 (⌘⇧T).
    static let dfCycleTheme = Notification.Name("DarwinForge.CycleTheme")
}
