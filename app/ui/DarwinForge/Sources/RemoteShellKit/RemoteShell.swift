import Foundation
import NIOCore

public struct RemoteHost: Sendable, Equatable {
    public var hostname: String
    public var port: Int
    public var username: String

    public init(hostname: String, port: Int = 22, username: String) {
        self.hostname = hostname
        self.port = port
        self.username = username
    }
}

public protocol RemoteShell: Sendable {
    func run(_ command: String) async throws -> String
    func upload(localPath: String, remotePath: String) async throws
    func download(remotePath: String, localPath: String) async throws
}
