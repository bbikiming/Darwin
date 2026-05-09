// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DarwinForge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DarwinForge", targets: ["DarwinForgeApp"]),
        .executable(name: "darwinforge", targets: ["DarwinForgeCLI"]),
        .library(name: "RobotKit", targets: ["RobotKit"]),
        .library(name: "HarnessKit", targets: ["HarnessKit"]),
        .library(name: "DynamixelKit", targets: ["DynamixelKit"]),
        .library(name: "SerialPortKit", targets: ["SerialPortKit"]),
        .library(name: "RemoteShellKit", targets: ["RemoteShellKit"]),
        .library(name: "OnboardSyncKit", targets: ["OnboardSyncKit"]),
        .library(name: "PersistenceKit", targets: ["PersistenceKit"]),
        .library(name: "WireVizBridge", targets: ["WireVizBridge"]),
        .library(name: "DarwinForgeUI", targets: ["DarwinForgeUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.10.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0")
    ],
    targets: [
        // MARK: Infrastructure
        .target(
            name: "SerialPortKit",
            path: "Sources/SerialPortKit"
        ),
        .target(
            name: "DynamixelKit",
            dependencies: ["SerialPortKit"],
            path: "Sources/DynamixelKit"
        ),
        .target(
            name: "RemoteShellKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ],
            path: "Sources/RemoteShellKit"
        ),

        // MARK: Domain (no infra deps allowed)
        .target(
            name: "RobotKit",
            path: "Sources/RobotKit"
        ),
        .target(
            name: "HarnessKit",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/HarnessKit"
        ),

        // MARK: Application services
        .target(
            name: "OnboardSyncKit",
            dependencies: ["RemoteShellKit", "RobotKit"],
            path: "Sources/OnboardSyncKit"
        ),
        .target(
            name: "PersistenceKit",
            dependencies: ["RobotKit", "HarnessKit"],
            path: "Sources/PersistenceKit"
        ),
        .target(
            name: "WireVizBridge",
            dependencies: ["HarnessKit"],
            path: "Sources/WireVizBridge"
        ),

        // MARK: UI
        .target(
            name: "DarwinForgeUI",
            dependencies: [
                "RobotKit",
                "HarnessKit",
                "DynamixelKit",
                "OnboardSyncKit",
                "PersistenceKit",
                "WireVizBridge"
            ],
            path: "Sources/DarwinForgeUI"
        ),

        // MARK: Executables
        .executableTarget(
            name: "DarwinForgeApp",
            dependencies: ["DarwinForgeUI"],
            path: "Sources/DarwinForgeApp"
        ),
        .executableTarget(
            name: "DarwinForgeCLI",
            dependencies: [
                "RobotKit",
                "HarnessKit",
                "DynamixelKit",
                "SerialPortKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/DarwinForgeCLI"
        ),

        // MARK: Tests
        .testTarget(
            name: "DynamixelKitTests",
            dependencies: ["DynamixelKit"],
            path: "Tests/DynamixelKitTests"
        ),
        .testTarget(
            name: "RobotKitTests",
            dependencies: ["RobotKit"],
            path: "Tests/RobotKitTests"
        ),
        .testTarget(
            name: "HarnessKitTests",
            dependencies: ["HarnessKit"],
            path: "Tests/HarnessKitTests"
        )
    ]
)
