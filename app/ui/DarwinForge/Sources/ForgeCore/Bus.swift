import CForgeCore
import Foundation

/// 캐논 관절 ID — `docs/architecture/joint-conventions.md`.
public enum JointID: UInt8, CaseIterable, Codable, Sendable, Hashable {
    case rShoulderPitch = 1, lShoulderPitch = 2
    case rShoulderRoll  = 3, lShoulderRoll  = 4
    case rElbow         = 5, lElbow         = 6
    case rHipYaw        = 11, lHipYaw       = 12
    case rHipRoll       = 13, lHipRoll      = 14
    case rHipPitch      = 15, lHipPitch     = 16
    case rKnee          = 17, lKnee         = 18
    case headPan        = 19, headTilt      = 20

    /// 영문 식별자 (UI 라벨 + 기록용).
    public var name: String {
        switch self {
        case .rShoulderPitch: return "R_SHOULDER_PITCH"
        case .lShoulderPitch: return "L_SHOULDER_PITCH"
        case .rShoulderRoll:  return "R_SHOULDER_ROLL"
        case .lShoulderRoll:  return "L_SHOULDER_ROLL"
        case .rElbow:         return "R_ELBOW"
        case .lElbow:         return "L_ELBOW"
        case .rHipYaw:        return "R_HIP_YAW"
        case .lHipYaw:        return "L_HIP_YAW"
        case .rHipRoll:       return "R_HIP_ROLL"
        case .lHipRoll:       return "L_HIP_ROLL"
        case .rHipPitch:      return "R_HIP_PITCH"
        case .lHipPitch:      return "L_HIP_PITCH"
        case .rKnee:          return "R_KNEE"
        case .lKnee:          return "L_KNEE"
        case .headPan:        return "HEAD_PAN"
        case .headTilt:       return "HEAD_TILT"
        }
    }

    /// UI 그룹핑 — 신체 부위.
    public enum BodyPart: String, CaseIterable, Codable, Sendable {
        case rightArm = "Right Arm"
        case leftArm = "Left Arm"
        case rightLeg = "Right Leg"
        case leftLeg = "Left Leg"
        case head = "Head"
    }

    public var bodyPart: BodyPart {
        switch self {
        case .rShoulderPitch, .rShoulderRoll, .rElbow: return .rightArm
        case .lShoulderPitch, .lShoulderRoll, .lElbow: return .leftArm
        case .rHipYaw, .rHipRoll, .rHipPitch, .rKnee:  return .rightLeg
        case .lHipYaw, .lHipRoll, .lHipPitch, .lKnee:  return .leftLeg
        case .headPan, .headTilt:                       return .head
        }
    }
}

/// 한 관절의 실시간 상태.
public struct JointState: Sendable, Equatable {
    public let id: JointID
    public let torqueEnabled: Bool
    public let goalPosition: UInt16
    public let presentPosition: UInt16
    public let presentSpeed: UInt16
    public let presentLoad: UInt16
    public let presentVoltageRaw: UInt8
    public let presentTemperature: UInt8

    public var voltageVolts: Double { Double(presentVoltageRaw) / 10.0 }

    init(_ ffi: fc_joint_state) {
        self.id = JointID(rawValue: ffi.id) ?? .headPan
        self.torqueEnabled = ffi.torque_enabled != 0
        self.goalPosition = ffi.goal_position
        self.presentPosition = ffi.present_position
        self.presentSpeed = ffi.present_speed
        self.presentLoad = ffi.present_load
        self.presentVoltageRaw = ffi.present_voltage
        self.presentTemperature = ffi.present_temperature
    }
}

/// CM-730/CM-740 보드 스냅샷.
public struct BoardSnapshot: Sendable, Equatable {
    public let modelNumber: UInt16
    public let version: UInt8
    public let voltageRaw: UInt8
    public let button: UInt8

    public var voltageVolts: Double { Double(voltageRaw) / 10.0 }

    /// 모델 번호로 추정한 컨트롤러.
    public var controllerLabel: String {
        switch modelNumber {
        case 730: return "CM-730 (1st gen / OP)"
        case 740: return "CM-740 (2nd gen / OP2)"
        default:  return "Unknown (\(modelNumber))"
        }
    }

    init(_ ffi: fc_board_snapshot) {
        self.modelNumber = ffi.model_number
        self.version = ffi.version
        self.voltageRaw = ffi.voltage_raw
        self.button = ffi.button
    }
}

/// Dynamixel Protocol 1.0 버스 핸들. PosixSerial 위 wrapping.
///
/// `Bus`는 reference type — 닫힘은 deinit에서 자동 처리.
public final class Bus: @unchecked Sendable {
    private var handle: OpaquePointer?
    public let portPath: String
    public let baud: UInt32
    public let timeoutMs: UInt32

    /// 직렬 포트 open + Bus 생성.
    public init(portPath: String, baud: UInt32 = 1_000_000, timeoutMs: UInt32 = 200) throws {
        var err: Int32 = FC_OK
        let h = portPath.withCString { ptr in
            fc_bus_open(ptr, baud, timeoutMs, &err)
        }
        guard let h else {
            throw ForgeError.from(err) ?? .generic
        }
        self.handle = OpaquePointer(h)
        self.portPath = portPath
        self.baud = baud
        self.timeoutMs = timeoutMs
    }

    deinit {
        if let h = handle {
            fc_bus_close(UnsafeMutablePointer(h))
        }
    }

    private func raw() -> UnsafeMutablePointer<fc_bus>? {
        handle.map { UnsafeMutablePointer($0) }
    }

    /// 단일 ID PING (응답 없으면 throw).
    public func ping(id: UInt8) throws {
        try checkForgeReturn(fc_bus_ping(raw(), id))
    }

    /// 범위 lo...hi 스캔 — 응답한 ID 목록.
    public func scan(lo: UInt8 = 1, hi: UInt8 = 20) throws -> [UInt8] {
        var err: Int32 = FC_OK
        guard let raw = fc_bus_scan(self.raw(), lo, hi, &err) else {
            if err == FC_OK { return [] }
            throw ForgeError.from(err) ?? .generic
        }
        guard let s = consumeForgeString(raw), !s.isEmpty else { return [] }
        return s.split(separator: "\n").compactMap { UInt8($0) }
    }

    /// CM 보드 상태 read (ID 200).
    public func boardSnapshot() throws -> BoardSnapshot {
        var ffi = fc_board_snapshot()
        try checkForgeReturn(fc_bus_board_snapshot(raw(), &ffi))
        return BoardSnapshot(ffi)
    }

    /// CM의 Dynamixel 전원 게이트 set.
    public func setDxlPower(_ on: Bool) throws {
        try checkForgeReturn(fc_bus_set_dxl_power(raw(), on ? 1 : 0))
    }

    /// 한 관절 토크 enable/disable.
    public func setTorque(_ joint: JointID, enable: Bool) throws {
        try checkForgeReturn(fc_joint_set_torque(raw(), joint.rawValue, enable ? 1 : 0))
    }

    /// 한 관절 goal position. 안전 한계로 clamp 후 적용된 값 반환.
    @discardableResult
    public func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        var clamped: UInt16 = 0
        try checkForgeReturn(fc_joint_set_position(self.raw(), joint.rawValue, position, &clamped))
        return clamped
    }

    /// 한 관절 상태 read.
    public func readState(_ joint: JointID) throws -> JointState {
        var ffi = fc_joint_state()
        try checkForgeReturn(fc_joint_read_state(raw(), joint.rawValue, &ffi))
        return JointState(ffi)
    }

    /// 모든 관절 토크 OFF — 소프트 e-stop.
    public func emergencyStop() throws {
        try checkForgeReturn(fc_emergency_stop(raw()))
    }
}
