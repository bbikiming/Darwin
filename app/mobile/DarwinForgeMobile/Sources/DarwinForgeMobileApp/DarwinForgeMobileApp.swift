import SwiftUI

/// Top-level `App` scene used by the iOS DarwinForge Mobile Pilot binary.
///
/// `@main` is intentionally **not** applied here — when this module is
/// imported by an Xcode iOS app target, the app target's own entry file
/// applies `@main`. Keeping `@main` here as well caused a duplicate `_main`
/// symbol at link time when compiling the library with the test bundle.
///
/// Suggested Xcode entry point (paste into the iOS app target):
///
/// ```swift
/// import SwiftUI
/// import DarwinForgeMobileApp
///
/// @main
/// struct DarwinForgeMobileEntry: App {
///     var body: some Scene {
///         WindowGroup { RootView() }
///     }
/// }
/// ```
public struct DarwinForgeMobileApp: App {
    public init() {}
    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
