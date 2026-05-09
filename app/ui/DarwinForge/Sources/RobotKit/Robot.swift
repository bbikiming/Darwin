import Foundation

public enum RobotGeneration: String, Sendable, CaseIterable, Codable {
    case op   // 1st generation, CM-730 sub-controller
    case op2  // 2nd generation, CM-740 sub-controller
}

public enum ControllerModel: String, Sendable, Codable {
    case cm730
    case cm740
}

public struct Robot: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public var name: String
    public var generation: RobotGeneration
    public var controller: ControllerModel
    public var serialNumber: String?
    public var buildDate: Date?
    public var notes: String

    public init(id: UUID = UUID(),
                name: String,
                generation: RobotGeneration,
                controller: ControllerModel,
                serialNumber: String? = nil,
                buildDate: Date? = nil,
                notes: String = "") {
        self.id = id
        self.name = name
        self.generation = generation
        self.controller = controller
        self.serialNumber = serialNumber
        self.buildDate = buildDate
        self.notes = notes
    }
}

public extension Robot {
    /// Default fixtures for the user's two units.
    static let darwinOne = Robot(name: "Darwin-1G",
                                 generation: .op,
                                 controller: .cm730)
    static let darwinTwo = Robot(name: "Darwin-2G",
                                 generation: .op2,
                                 controller: .cm740)
}
