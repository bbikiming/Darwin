import Foundation
import RobotKit
import HarnessKit

/// In-memory store. The production target swaps this for SwiftData
/// `@Model` types — kept out of the package skeleton so that domain
/// types stay testable without a SwiftData schema dance.
public actor Store {
    public private(set) var robots: [Robot] = []
    public private(set) var harnesses: [Harness] = []

    public init() {}

    public func add(_ robot: Robot) {
        robots.append(robot)
    }

    public func add(_ harness: Harness) {
        harnesses.append(harness)
    }

    public func harnesses(for robotID: UUID) -> [Harness] {
        harnesses.filter { $0.robotID == robotID }
    }
}
