import Foundation
import RobotKit
import RemoteShellKit

/// Paths the on-board Linux exposes. See `docs/research/upstream-survey.md` §2.
public enum OnboardPath {
    public static let dataDir = "/darwin/Data"
    public static let configIni = "/darwin/Data/config.ini"
    public static let walkingIni = "/darwin/Data/walking.ini"
    public static let actionPages = "/darwin/Data/motion_4096.bin"
}

public struct OnboardSync: Sendable {
    public let shell: any RemoteShell

    public init(shell: any RemoteShell) {
        self.shell = shell
    }

    public func fetchConfigIni() async throws -> String {
        try await shell.run("cat \(OnboardPath.configIni)")
    }

    public func fetchWalkingIni() async throws -> String {
        try await shell.run("cat \(OnboardPath.walkingIni)")
    }

    public func stopDemo() async throws {
        // The default demo is launched from /etc/rc.local on stock images.
        // Tighten this guard before merging.
        _ = try await shell.run("pkill -f /darwin/Linux/project/demo/demo || true")
    }
}
