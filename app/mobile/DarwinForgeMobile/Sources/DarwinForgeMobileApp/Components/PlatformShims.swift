import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cross-platform color helpers. The iOS app uses iOS system colors; when
/// the same source compiles on macOS for unit tests, we fall back to
/// generic SwiftUI colors so the type-check passes.
public extension Color {
    static var dfBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var dfSecondaryBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

extension View {
    @ViewBuilder
    func dfInlineNavigationTitle() -> some View {
        #if canImport(UIKit)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func dfTrailingToolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if canImport(UIKit)
        self.toolbar {
            ToolbarItem(placement: .topBarTrailing, content: content)
        }
        #else
        self.toolbar {
            ToolbarItem(placement: .automatic, content: content)
        }
        #endif
    }
}
