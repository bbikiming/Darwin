import SwiftUI

/// 윈도우 폭에 따른 layout class — 모든 view 가 동일한 breakpoint 를 공유해 일관된 반응형.
///
/// 기준 (macOS):
///   - compact:  < 820  (13" 노트북 / 외부 화면 작게)
///   - regular:  < 1280 (일반 노트북 / 보통 외부 모니터)
///   - wide:    ≥ 1280  (대형 모니터 / 전체화면)
public enum ResponsiveSize: Equatable {
    case compact
    case regular
    case wide

    public init(width: CGFloat) {
        if width < 820 { self = .compact }
        else if width < 1280 { self = .regular }
        else { self = .wide }
    }

    public var isCompact: Bool { self == .compact }
    public var isAtLeastRegular: Bool { self != .compact }
    public var isWide: Bool { self == .wide }
}

public enum ResponsiveBreakpoints {
    public static let compact: CGFloat = 820
    public static let regular: CGFloat = 1280

    /// 윈도우 높이도 분류 — 작은 노트북 (≤ 800px) 일 때 일부 카드를 축소.
    public static let shortHeight: CGFloat = 800
}

/// EnvironmentKey 로 윈도우 폭을 자식 view 에 자동 전파.
private struct WindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1280
}
private struct WindowHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 900
}

public extension EnvironmentValues {
    var dfWindowWidth: CGFloat {
        get { self[WindowWidthKey.self] }
        set { self[WindowWidthKey.self] = newValue }
    }
    var dfWindowHeight: CGFloat {
        get { self[WindowHeightKey.self] }
        set { self[WindowHeightKey.self] = newValue }
    }
    var dfResponsiveSize: ResponsiveSize {
        ResponsiveSize(width: dfWindowWidth)
    }
}

/// 루트 view 에 한 번 부착 — 자식들은 `@Environment(\.dfWindowWidth)` 로 자동 접근.
public struct ResponsiveContainer<Content: View>: View {
    @ViewBuilder public let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        GeometryReader { geo in
            content()
                .environment(\.dfWindowWidth, geo.size.width)
                .environment(\.dfWindowHeight, geo.size.height)
        }
    }
}
