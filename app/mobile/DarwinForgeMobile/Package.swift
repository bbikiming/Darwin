// swift-tools-version: 5.10
import PackageDescription

// DarwinForge Mobile Pilot — iOS-first companion app.
//
// Architecture:
//   MobilePilotKit (Foundation-only, platform agnostic)
//     └── DarwinForgeMobileApp (SwiftUI, iOS 17+)
//
// MobilePilotKit can be unit-tested on macOS host with `swift test`.
// The SwiftUI app target is gated to iOS so that it can be wrapped by a
// thin Xcode project for TestFlight archive/upload.
//
// This package is intentionally separated from the macOS app package at
// `app/ui/DarwinForge` to keep AppKit/macOS-only code out of the iOS
// build graph (per PRD section 14 and ADR-001).

let package = Package(
    name: "DarwinForgeMobile",
    defaultLocalization: "ko",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "MobilePilotKit", targets: ["MobilePilotKit"]),
        .library(name: "DarwinForgeMobileApp", targets: ["DarwinForgeMobileApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MobilePilotKit",
            path: "Sources/MobilePilotKit"
        ),
        .target(
            name: "DarwinForgeMobileApp",
            dependencies: ["MobilePilotKit"],
            path: "Sources/DarwinForgeMobileApp",
            exclude: [
                "Resources/Info.plist.template"
            ]
        ),
        .testTarget(
            name: "MobilePilotKitTests",
            dependencies: ["MobilePilotKit"],
            path: "Tests/MobilePilotKitTests"
        ),
        .testTarget(
            name: "DarwinForgeMobileAppTests",
            dependencies: ["DarwinForgeMobileApp", "MobilePilotKit"],
            path: "Tests/DarwinForgeMobileAppTests"
        )
    ]
)
