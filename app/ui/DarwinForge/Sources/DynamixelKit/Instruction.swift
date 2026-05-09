import Foundation

public enum Instruction: UInt8, Sendable, CaseIterable {
    case ping = 0x01
    case readData = 0x02
    case writeData = 0x03
    case regWrite = 0x04
    case action = 0x05
    case factoryReset = 0x06
    case reboot = 0x08
    case syncWrite = 0x83
    case bulkRead = 0x92
}

public enum SpecialID {
    public static let controller: UInt8 = 200
    public static let broadcast: UInt8 = 254
    public static let rightFootFSR: UInt8 = 111
    public static let leftFootFSR: UInt8 = 112
}
