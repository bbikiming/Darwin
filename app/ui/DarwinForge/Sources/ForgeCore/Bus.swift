import CForgeCore
import Foundation

/// 캐논 관절 ID — ROBOTIS-OP2 e-Manual 표준 actuator ID 와 1:1 매핑.
///
/// 팔   ID 1..6   (어깨 pitch/roll, 팔꿈치 — 한쪽 3 joint)
/// 다리 ID 7..18  (hip yaw/roll/pitch, 무릎, 발목 pitch/roll — 한쪽 6 joint)
/// 머리 ID 19,20  (pan/tilt)
/// 출처: <https://emanual.robotis.com/docs/en/platform/op2/getting_started/>
public enum JointID: UInt8, CaseIterable, Codable, Sendable, Hashable {
    case rShoulderPitch = 1,  lShoulderPitch = 2
    case rShoulderRoll  = 3,  lShoulderRoll  = 4
    case rElbow         = 5,  lElbow         = 6
    case rHipYaw        = 7,  lHipYaw        = 8
    case rHipRoll       = 9,  lHipRoll       = 10
    case rHipPitch      = 11, lHipPitch      = 12
    case rKnee          = 13, lKnee          = 14
    case rAnklePitch    = 15, lAnklePitch    = 16
    case rAnkleRoll     = 17, lAnkleRoll     = 18
    case headPan        = 19, headTilt       = 20

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
        case .rAnklePitch:    return "R_ANKLE_PITCH"
        case .lAnklePitch:    return "L_ANKLE_PITCH"
        case .rAnkleRoll:     return "R_ANKLE_ROLL"
        case .lAnkleRoll:     return "L_ANKLE_ROLL"
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
        case .rHipYaw, .rHipRoll, .rHipPitch, .rKnee, .rAnklePitch, .rAnkleRoll:
            return .rightLeg
        case .lHipYaw, .lHipRoll, .lHipPitch, .lKnee, .lAnklePitch, .lAnkleRoll:
            return .leftLeg
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

/// CM-730/CM-740 IMU raw + accel 기반 roll/pitch 도 — Sprint 18 Phase D3.
///
/// Rust `CmController::read_imu` 의 결과. accelerometer 기반 정적 tilt 추정 — 빠른 동작 중엔
/// drift 가능. 정밀 자세 추정은 walk::imu::ComplementaryFilter 필요.
public struct ImuRaw: Sendable, Equatable {
    public let gyroX: Int16
    public let gyroY: Int16
    public let gyroZ: Int16
    public let accelX: Int16
    public let accelY: Int16
    public let accelZ: Int16
    public let rollDeg: Double
    public let pitchDeg: Double

    /// raw → °/s. ±2000 dps / 32767.
    public var gyroXDps: Double { Double(gyroX) * 2000.0 / 32767.0 }
    public var gyroYDps: Double { Double(gyroY) * 2000.0 / 32767.0 }
    public var gyroZDps: Double { Double(gyroZ) * 2000.0 / 32767.0 }

    /// 테스트 / 시뮬레이션용 public init.
    public init(gyroX: Int16, gyroY: Int16, gyroZ: Int16,
                accelX: Int16, accelY: Int16, accelZ: Int16,
                rollDeg: Double, pitchDeg: Double) {
        self.gyroX = gyroX
        self.gyroY = gyroY
        self.gyroZ = gyroZ
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
    }

    init(_ ffi: fc_imu_raw) {
        self.gyroX = ffi.gyro_x
        self.gyroY = ffi.gyro_y
        self.gyroZ = ffi.gyro_z
        self.accelX = ffi.accel_x
        self.accelY = ffi.accel_y
        self.accelZ = ffi.accel_z
        self.rollDeg = Double(ffi.roll_deg)
        self.pitchDeg = Double(ffi.pitch_deg)
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

/// Dynamixel Protocol 1.0 버스 핸들. PosixSerial 또는 TcpBus 위 wrapping.
///
/// `Bus`는 reference type — 닫힘은 deinit에서 자동 처리.
public final class Bus: @unchecked Sendable {
    private var handle: OpaquePointer?
    public let portPath: String
    public let baud: UInt32
    public let timeoutMs: UInt32

    /// USB 직렬 포트 open + Bus 생성.
    public init(portPath: String, baud: UInt32 = 1_000_000, timeoutMs: UInt32 = 200) throws {
        var err: Int32 = FC_OK
        let h = portPath.withCString { ptr in
            fc_bus_open(ptr, baud, timeoutMs, &err)
        }
        guard let h else {
            throw ForgeError.from(err) ?? .generic
        }
        self.handle = h
        self.portPath = portPath
        self.baud = baud
        self.timeoutMs = timeoutMs
    }

    /// 네트워크 endpoint(host:port)에 TCP 연결 + Bus 생성.
    /// 서버 측은 `forge serve --port /dev/... --bind 0.0.0.0:5530` 으로 USB 브리지를 노출.
    public init(networkHost: String,
                networkPort: UInt16,
                connectTimeoutMs: UInt32 = 3000,
                ioTimeoutMs: UInt32 = 250) throws {
        let addr = "\(networkHost):\(networkPort)"
        var err: Int32 = FC_OK
        let h = addr.withCString { ptr in
            fc_bus_open_tcp(ptr, connectTimeoutMs, ioTimeoutMs, &err)
        }
        guard let h else {
            throw ForgeError.from(err) ?? .generic
        }
        self.handle = h
        self.portPath = addr
        self.baud = 0
        self.timeoutMs = ioTimeoutMs
    }

    deinit {
        if let h = handle {
            fc_bus_close(h)
        }
    }

    private func raw() -> OpaquePointer? {
        handle
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

    /// CM-730/740 IMU read — 한 번에 gyro X/Y/Z + accel X/Y/Z + roll/pitch 도.
    /// Phase D3 (Sprint 18) — `fc_bus_read_imu` FFI 호출.
    public func readImu() throws -> ImuRaw {
        var ffi = fc_imu_raw()
        try checkForgeReturn(fc_bus_read_imu(raw(), &ffi))
        return ImuRaw(ffi)
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

    /// 한 관절 moving_speed 설정 — Dynamixel MX-28T address 32-33.
    /// 0 = 무제한 (default), 1-1023 = 단계별 (0.114 rpm per unit, 526 ≈ 60rpm = 1초/360°).
    public func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {
        try checkForgeReturn(fc_joint_set_moving_speed(self.raw(), joint.rawValue, speed))
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

    // MARK: - Motion play (Sprint 15 라이브러리 노출 — 2026-05-16 v1.1 통합)

    /// `motion_4096.bin` 의 `slot` 페이지를 실 robot 에 동기 송출.
    ///
    /// - Parameters:
    ///   - slot: 페이지 번호 (예: 24/27 단발, 9 walkready, 12/13 HighRisk get-up)
    ///   - binPath: nil 이면 `FORGE_MOTION_BIN` env 또는 소스 트리 기본 경로 사용
    ///   - dryRun: true 면 stdout 로그만 (실 송출 없음)
    ///   - confirmRisk: HighRisk 모션 (page 12/13 등) 실행 허용
    ///   - singleFootOk: 단일 발 지지 페이지 허용 (PRD §7.1 — confirmRisk 와 등가)
    ///   - followChain: `page.next_page` chain 을 따라감. 기본 false (단일 page only)
    ///   - maxChainDepth: chain 최대 깊이. 0 이면 내부 기본값 10
    ///
    /// **블로킹**. `Task.detached(priority: .userInitiated)` 또는 별도 thread 에서 호출.
    /// 취소는 다른 thread 에서 `motionPlayCancel()`.
    public func motionPlaySlot(
        slot: UInt8,
        binPath: String? = nil,
        dryRun: Bool = false,
        confirmRisk: Bool = false,
        singleFootOk: Bool = false,
        followChain: Bool = false,
        maxChainDepth: Int = 10
    ) throws {
        let result: Int32
        if let p = binPath {
            result = p.withCString { ptr in
                fc_motion_play_slot(
                    raw(), slot, ptr,
                    dryRun ? 1 : 0,
                    confirmRisk ? 1 : 0,
                    singleFootOk ? 1 : 0,
                    followChain ? 1 : 0,
                    UInt(max(0, maxChainDepth))
                )
            }
        } else {
            result = fc_motion_play_slot(
                raw(), slot, nil,
                dryRun ? 1 : 0,
                confirmRisk ? 1 : 0,
                singleFootOk ? 1 : 0,
                followChain ? 1 : 0,
                UInt(max(0, maxChainDepth))
            )
        }
        try checkForgeReturn(result)
    }

    /// 진행 중인 motion play 를 다른 thread 에서 취소. 다음 8 ms 체크 시점에 중단.
    public func motionPlayCancel() throws {
        try checkForgeReturn(fc_motion_play_cancel(raw()))
    }

    /// motion play 가 재생 중이면 true.
    public var isMotionPlaying: Bool {
        fc_motion_play_is_running(raw()) == 1
    }
}
