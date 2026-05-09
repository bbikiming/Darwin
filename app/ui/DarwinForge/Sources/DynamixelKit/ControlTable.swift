import Foundation

/// CM-730 / CM-740 sub-controller register addresses (ID 200).
public enum CMRegister {
    public static let modelNumber: UInt8       = 0
    public static let version: UInt8           = 2
    public static let id: UInt8                = 3
    public static let baudRate: UInt8          = 4
    public static let returnDelayTime: UInt8   = 5
    public static let dxlPower: UInt8          = 24
    public static let ledPanel: UInt8          = 25
    public static let ledHeadL: UInt8          = 26
    public static let ledHeadH: UInt8          = 27
    public static let ledEyeL: UInt8           = 28
    public static let ledEyeH: UInt8           = 29
    public static let button: UInt8            = 30
    public static let gyroZ: UInt8             = 38
    public static let gyroY: UInt8             = 40
    public static let gyroX: UInt8             = 42
    public static let accelX: UInt8            = 44
    public static let accelY: UInt8            = 46
    public static let accelZ: UInt8            = 48
    public static let voltage: UInt8           = 50
    public static let micL: UInt8              = 51
    public static let micR: UInt8              = 67
}

/// MX-28T register addresses (servo IDs 1–20).
public enum MX28Register {
    public static let modelNumber: UInt8       = 0
    public static let id: UInt8                = 3
    public static let baudRate: UInt8          = 4
    public static let cwAngleLimit: UInt8      = 6
    public static let ccwAngleLimit: UInt8     = 8
    public static let torqueEnable: UInt8      = 24
    public static let led: UInt8               = 25
    public static let dGain: UInt8             = 26
    public static let iGain: UInt8             = 27
    public static let pGain: UInt8             = 28
    public static let goalPosition: UInt8      = 30
    public static let movingSpeed: UInt8       = 32
    public static let torqueLimit: UInt8       = 34
    public static let presentPosition: UInt8   = 36
    public static let presentSpeed: UInt8      = 38
    public static let presentLoad: UInt8       = 40
    public static let presentVoltage: UInt8    = 42
    public static let presentTemperature: UInt8 = 43
}
