import Foundation

public enum IPCClass: Int, Sendable, Codable, CaseIterable {
    case class1 = 1, class2 = 2, class3 = 3
}

public enum InsulationMaterial: String, Sendable, Codable, CaseIterable {
    case pvc, fep, ptfe, silicone, tpe
}

public enum SignalType: String, Sendable, Codable, CaseIterable {
    case powerVcc, ground, ttlData, analog
    case rs485A, rs485B, usbDataPlus, usbDataMinus
    case dynamixelBus
    case shieldDrain
}

public enum ConnectorFamily: String, Sendable, Codable, CaseIterable {
    case jstXH, jstPH, jstZH, jstSH
    case molexMiniFitJr, molexPicoBlade
    case hiroseDF13
    case robotisTTL3P
    case xt60, deansT
}

public struct Connector: Sendable, Codable, Equatable {
    public let id: UUID
    public var partNumber: String
    public var family: ConnectorFamily
    public var pinCount: Int
    public var pitchMm: Double
    public var ratedCurrentA: Double
    public var ratedVoltageV: Double
    public var gender: Gender

    public enum Gender: String, Sendable, Codable { case plug, receptacle }

    public init(id: UUID = UUID(),
                partNumber: String,
                family: ConnectorFamily,
                pinCount: Int,
                pitchMm: Double,
                ratedCurrentA: Double,
                ratedVoltageV: Double,
                gender: Gender) {
        self.id = id
        self.partNumber = partNumber
        self.family = family
        self.pinCount = pinCount
        self.pitchMm = pitchMm
        self.ratedCurrentA = ratedCurrentA
        self.ratedVoltageV = ratedVoltageV
        self.gender = gender
    }
}

public struct Conductor: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public var label: String
    public var awg: Int
    public var insulation: InsulationMaterial
    public var color: String
    public var shielded: Bool
    public var signalType: SignalType
    public var netName: String

    public init(id: UUID = UUID(),
                label: String,
                awg: Int,
                insulation: InsulationMaterial,
                color: String,
                shielded: Bool,
                signalType: SignalType,
                netName: String) {
        self.id = id
        self.label = label
        self.awg = awg
        self.insulation = insulation
        self.color = color
        self.shielded = shielded
        self.signalType = signalType
        self.netName = netName
    }
}

public struct Harness: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public var robotID: UUID
    public var name: String
    public var ipcClass: IPCClass
    public var totalLengthMm: Int
    public var installedAt: Date?
    public var description: String

    public init(id: UUID = UUID(),
                robotID: UUID,
                name: String,
                ipcClass: IPCClass = .class2,
                totalLengthMm: Int = 0,
                installedAt: Date? = nil,
                description: String = "") {
        self.id = id
        self.robotID = robotID
        self.name = name
        self.ipcClass = ipcClass
        self.totalLengthMm = totalLengthMm
        self.installedAt = installedAt
        self.description = description
    }
}

public enum FailureMode: String, Sendable, Codable, CaseIterable {
    case open, short, intermittent
    case insulationDamage, connectorBroken
    case strainReliefFail, fatigueBreak
}

public struct MaintenanceLogEntry: Sendable, Codable, Identifiable {
    public let id: UUID
    public var harnessID: UUID
    public var date: Date
    public var technician: String
    public var failureMode: FailureMode?
    public var notes: String

    public init(id: UUID = UUID(),
                harnessID: UUID,
                date: Date,
                technician: String,
                failureMode: FailureMode? = nil,
                notes: String = "") {
        self.id = id
        self.harnessID = harnessID
        self.date = date
        self.technician = technician
        self.failureMode = failureMode
        self.notes = notes
    }
}
