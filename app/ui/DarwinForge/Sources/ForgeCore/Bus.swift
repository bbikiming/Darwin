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
/// **v1.11.25 (2026-05-21) audit P0 robot-D** — ROBOTIS-OP2 FSR (Force Sensitive Resistor) board.
///
/// 두 개의 FSR board (left foot ID 112, right foot ID 111) 가 발 sole 의 4 cell 압력 +
/// center-of-pressure (X, Y) 를 측정. ZMP-기반 보행 안정성 분석의 객관 지표.
public struct FsrReading: Sendable, Equatable {
    /// Dynamixel ID (111=right, 112=left).
    public let id: UInt8
    /// 4 cell 압력 raw (0..1023). [front-left, front-right, rear-right, rear-left].
    public let cellFrontLeft: UInt16
    public let cellFrontRight: UInt16
    public let cellRearRight: UInt16
    public let cellRearLeft: UInt16
    /// 중심점 X (사용자 시점 좌측=음수, -127..127). 0 = 발 중앙.
    public let centerX: Int8
    /// 중심점 Y (앞=음수, -127..127).
    public let centerY: Int8

    /// 4 cell 합 — 발 total 압력 (raw). 큰 값 = 그 발에 weight 더 실림.
    public var totalPressureRaw: UInt32 {
        UInt32(cellFrontLeft) + UInt32(cellFrontRight) + UInt32(cellRearRight) + UInt32(cellRearLeft)
    }

    init(_ ffi: FfiFsrReading) {
        self.id = ffi.id
        self.cellFrontLeft = ffi.cell_fl
        self.cellFrontRight = ffi.cell_fr
        self.cellRearRight = ffi.cell_rr
        self.cellRearLeft = ffi.cell_rl
        self.centerX = ffi.center_x
        self.centerY = ffi.center_y
    }

    /// 테스트 / 시뮬레이션용 public init.
    public init(id: UInt8,
                cellFrontLeft: UInt16, cellFrontRight: UInt16,
                cellRearRight: UInt16, cellRearLeft: UInt16,
                centerX: Int8, centerY: Int8) {
        self.id = id
        self.cellFrontLeft = cellFrontLeft
        self.cellFrontRight = cellFrontRight
        self.cellRearRight = cellRearRight
        self.cellRearLeft = cellRearLeft
        self.centerX = centerX
        self.centerY = centerY
    }
}

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

    /// 사이클 255 — 테스트 / 시뮬레이션용 public init.
    /// MockBus 가 in-memory 위치/torque 로부터 JointState 합성할 때 사용.
    public init(id: JointID,
                torqueEnabled: Bool,
                goalPosition: UInt16,
                presentPosition: UInt16,
                presentSpeed: UInt16,
                presentLoad: UInt16,
                presentVoltageRaw: UInt8,
                presentTemperature: UInt8) {
        self.id = id
        self.torqueEnabled = torqueEnabled
        self.goalPosition = goalPosition
        self.presentPosition = presentPosition
        self.presentSpeed = presentSpeed
        self.presentLoad = presentLoad
        self.presentVoltageRaw = presentVoltageRaw
        self.presentTemperature = presentTemperature
    }
}

/// CM-730/CM-740 IMU raw + accel 기반 roll/pitch 도 — Sprint 18 Phase D3 → v1.7 정정.
///
/// **v1.7 (2026-05-17) 정정 — ABI break**: gyro/accel raw 가 `Int16` 에서 `UInt16` 으로 변경.
/// ROBOTIS-OP2 v1.6.0 `CM730::MakeWord` 가 unsigned u16 zero-extend, 그리고 10-bit ADC 의
/// center 가 512 (`MotionManager.cpp:73`) 인 사실에 맞춤. 종전 i16 + ±32767 scaling 가정은
/// 잘못이었고 직립 시 atan2(raw≈512, raw≈512) ≈ 45° false-tilt 의 원인이었음.
///
/// Rust `CmController::read_imu` 의 결과. accelerometer 기반 정적 tilt 추정 — 빠른 동작 중엔
/// drift 가능. 정밀 자세 추정은 walk::imu::ComplementaryFilter 필요.
public struct ImuRaw: Sendable, Equatable {
    /// CM-730/740 IMU ADC center (10-bit). ROBOTIS-OP2 firmware 기준 512.
    public static let adcCenter: Double = 512.0

    /// L3G4200D 계열 ±2000dps / 10-bit ADC ±512 LSB → 1 LSB ≈ 3.91 °/s. provisional.
    public static let gyroDpsPerLsb: Double = 2000.0 / 512.0

    /// ADXL345 계열 ±2g / 10-bit ADC. 1g ≈ 256 LSB. provisional.
    public static let accelGPerLsb: Double = 1.0 / 256.0

    public let gyroX: UInt16
    public let gyroY: UInt16
    public let gyroZ: UInt16
    public let accelX: UInt16
    public let accelY: UInt16
    public let accelZ: UInt16
    public let rollDeg: Double
    public let pitchDeg: Double

    /// raw - 512 (centered LSB). 안전 logic 은 이걸 우선 사용.
    public var gyroXCentered: Double { Double(gyroX) - Self.adcCenter }
    public var gyroYCentered: Double { Double(gyroY) - Self.adcCenter }
    public var gyroZCentered: Double { Double(gyroZ) - Self.adcCenter }
    public var accelXCentered: Double { Double(accelX) - Self.adcCenter }
    public var accelYCentered: Double { Double(accelY) - Self.adcCenter }
    public var accelZCentered: Double { Double(accelZ) - Self.adcCenter }

    /// centered raw → °/s (provisional scale).
    public var gyroXDps: Double { gyroXCentered * Self.gyroDpsPerLsb }
    public var gyroYDps: Double { gyroYCentered * Self.gyroDpsPerLsb }
    public var gyroZDps: Double { gyroZCentered * Self.gyroDpsPerLsb }

    /// centered raw → g (provisional scale).
    public var accelXG: Double { accelXCentered * Self.accelGPerLsb }
    public var accelYG: Double { accelYCentered * Self.accelGPerLsb }
    public var accelZG: Double { accelZCentered * Self.accelGPerLsb }

    /// 테스트 / 시뮬레이션용 public init — UInt16 raw 10-bit ADC.
    public init(gyroX: UInt16, gyroY: UInt16, gyroZ: UInt16,
                accelX: UInt16, accelY: UInt16, accelZ: UInt16,
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

    /// 사이클 255 — 테스트 / 시뮬레이션용 public init.
    /// MockBus + recovery/preflight test 가 BoardSnapshot 직접 생성.
    public init(modelNumber: UInt16,
                version: UInt8,
                voltageRaw: UInt8,
                button: UInt8) {
        self.modelNumber = modelNumber
        self.version = version
        self.voltageRaw = voltageRaw
        self.button = button
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

    /// **v1.11 CRITICAL (2026-05-17 debugger agent 발견)**: USB-TTL half-duplex bus 의
    /// packet collision 차단. ConnectionStore 의 IMU loop / telemetry loop / WalkLabSession
    /// 의 position write 가 모두 같은 Bus 인스턴스를 `Task.detached` 로 동시 접근 →
    /// `bus.send()` + `bus.recv()` 의 transaction 이 interleave 되어 잘못된 status packet
    /// 을 consume.
    ///
    /// 종전: `@unchecked Sendable` 만 선언, 실제 보호 없음 → 거짓 안전 약속.
    /// 신규: **transactional public methods** 가 `locked { ... }` 안에서 실행 →
    /// 한 transaction (send + recv) 이 atomic. 적용 대상:
    ///   - `ping`, `scan`, `boardSnapshot`, `readImu`, `setDxlPower`, `setTorque`,
    ///     `setPosition`, `setMovingSpeed`, `setPGain`, `readState`, `emergencyStop`
    ///
    /// **의도적으로 unlocked** (v1.11.1 2026-05-18 사용자 review 정정):
    ///   - `motionPlaySlot`: 수초~수십초 long-running. 그 안에서 USB transaction 이
    ///     반복적으로 일어나고 자체적으로 cancel 토큰 polling. lock 으로 감싸면
    ///     motion 재생 중 IMU/telemetry read 가 완전 차단됨 → fall prevention 불가.
    ///     Rust forge-core 가 자체 lock-free transaction 으로 안전 보장.
    ///   - `motionPlayCancel`: 다른 thread 에서 호출 가능해야 cancel 작동 (lock 시 dead).
    ///   - `isMotionPlaying`: read-only 상태 query, atomic int load.
    ///
    /// **부수효과**: transactional access 가 serialize 되므로 IMU read 와 position
    /// write 가 queue 되어 latency 증가 가능. 그러나 packet collision 으로 인한
    /// invalid data 보다 안전.
    private let serialLock = NSRecursiveLock()

    /// Helper — closure 안의 코드를 serialLock 안에서 실행.
    private func locked<T>(_ block: () throws -> T) rethrows -> T {
        serialLock.lock()
        defer { serialLock.unlock() }
        return try block()
    }

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

    // v1.11: 모든 throws method 는 `locked { ... }` 안에서 실행 → packet collision 차단.

    public func ping(id: UInt8) throws {
        try locked { try checkForgeReturn(fc_bus_ping(raw(), id)) }
    }

    public func scan(lo: UInt8 = 1, hi: UInt8 = 20) throws -> [UInt8] {
        try locked {
            var err: Int32 = FC_OK
            guard let raw = fc_bus_scan(self.raw(), lo, hi, &err) else {
                if err == FC_OK { return [] }
                throw ForgeError.from(err) ?? .generic
            }
            guard let s = consumeForgeString(raw), !s.isEmpty else { return [] }
            return s.split(separator: "\n").compactMap { UInt8($0) }
        }
    }

    public func boardSnapshot() throws -> BoardSnapshot {
        try locked {
            var ffi = fc_board_snapshot()
            try checkForgeReturn(fc_bus_board_snapshot(raw(), &ffi))
            return BoardSnapshot(ffi)
        }
    }

    public func readImu() throws -> ImuRaw {
        try locked {
            var ffi = fc_imu_raw()
            try checkForgeReturn(fc_bus_read_imu(raw(), &ffi))
            return ImuRaw(ffi)
        }
    }

    /// **v1.11.25 (2026-05-21) audit P0 robot-D** — 좌측 발 FSR (ID 112) read.
    ///
    /// board 미장착 robot (개발용 일부) 에서는 timeout 으로 throw. 호출자가 try? 로
    /// fallback 처리 → 한 번 실패한 후 polling 주기 늘려서 spam 차단 권장.
    public func readFsrLeft() throws -> FsrReading {
        try locked {
            var ffi = FfiFsrReading(id: 0, cell_fl: 0, cell_fr: 0, cell_rr: 0, cell_rl: 0, center_x: 0, center_y: 0)
            try checkForgeReturn(fc_bus_read_fsr_left(raw(), &ffi))
            return FsrReading(ffi)
        }
    }

    /// 우측 발 FSR (ID 111) read.
    public func readFsrRight() throws -> FsrReading {
        try locked {
            var ffi = FfiFsrReading(id: 0, cell_fl: 0, cell_fr: 0, cell_rr: 0, cell_rl: 0, center_x: 0, center_y: 0)
            try checkForgeReturn(fc_bus_read_fsr_right(raw(), &ffi))
            return FsrReading(ffi)
        }
    }

    public func setDxlPower(_ on: Bool) throws {
        try locked { try checkForgeReturn(fc_bus_set_dxl_power(raw(), on ? 1 : 0)) }
    }

    public func setTorque(_ joint: JointID, enable: Bool) throws {
        try locked { try checkForgeReturn(fc_joint_set_torque(raw(), joint.rawValue, enable ? 1 : 0)) }
    }

    @discardableResult
    public func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        try locked {
            var clamped: UInt16 = 0
            try checkForgeReturn(fc_joint_set_position(self.raw(), joint.rawValue, position, &clamped))
            return clamped
        }
    }

    /// 다중 관절 동시 goal position 설정 (SYNC_WRITE 1패킷). 안전 한계는 Rust 측에서 clamp.
    ///
    /// SYNC_WRITE 는 status packet 을 반환하지 않으므로 per-joint 응답 확인 불가.
    /// transport 실패(USB I/O error 등) 만 throw 로 노출. per-servo liveness 는
    /// Phase 2 BULK_READ 에서 추가 예정.
    ///
    /// - Parameter targets: `(JointID, rawPosition)` 쌍 배열. 빈 배열이면 no-op.
    public func setPositions(_ targets: [(JointID, UInt16)]) throws {
        guard !targets.isEmpty else { return }
        try locked {
            let ids: [UInt8] = targets.map { $0.0.rawValue }
            let raws: [UInt16] = targets.map { $0.1 }
            try ids.withUnsafeBufferPointer { idsBuf in
                try raws.withUnsafeBufferPointer { rawsBuf in
                    try checkForgeReturn(
                        fc_joint_set_positions_many(
                            self.raw(),
                            idsBuf.baseAddress,
                            rawsBuf.baseAddress,
                            UInt(targets.count)
                        )
                    )
                }
            }
        }
    }

    public func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {
        try locked { try checkForgeReturn(fc_joint_set_moving_speed(self.raw(), joint.rawValue, speed)) }
    }

    /// 다중 관절 moving speed 동시 설정 (SYNC_WRITE 1패킷, L5 2026-06-11).
    /// 보행 prologue 의 관절별 개별 write 20회(+status 왕복)를 1패킷으로.
    /// SYNC_WRITE 는 status packet 없음 — transport 실패만 throw.
    public func setMovingSpeeds(_ joints: [JointID], speed: UInt16) throws {
        guard !joints.isEmpty else { return }
        try locked {
            let ids: [UInt8] = joints.map { $0.rawValue }
            try ids.withUnsafeBufferPointer { idsBuf in
                try checkForgeReturn(
                    fc_joint_set_moving_speeds_many(
                        self.raw(),
                        idsBuf.baseAddress,
                        UInt(joints.count),
                        speed
                    )
                )
            }
        }
    }

    public func setPGain(_ joint: JointID, value: UInt8) throws {
        try locked { try checkForgeReturn(fc_joint_set_p_gain(self.raw(), joint.rawValue, value)) }
    }

    public func readState(_ joint: JointID) throws -> JointState {
        try locked {
            var ffi = fc_joint_state()
            try checkForgeReturn(fc_joint_read_state(raw(), joint.rawValue, &ffi))
            return JointState(ffi)
        }
    }

    public func emergencyStop() throws {
        // S4: 락 획득 *전에* 선점 플래그를 set — 보행 status 폴 등 진행 중 read 가
        // 락을 물고 있어도 다음 read 슬라이스에서 조기 abort 돼 락이 즉시 풀린다.
        // fc_emergency_stop 은 송출 완료 후 선점 플래그를 자동 해제한다.
        fc_bus_request_estop_preempt(raw())
        try locked { try checkForgeReturn(fc_emergency_stop(raw())) }
    }

    /// **S4 — E-STOP 선점 요청**. 직렬화 락 *없이* in-flight read 를 abort 시킨다.
    public func requestEstopPreempt() {
        fc_bus_request_estop_preempt(raw())
    }

    /// 선점 플래그 해제 (정지 송출 없이 선점만 거둘 때).
    public func clearEstopPreempt() {
        fc_bus_clear_estop_preempt(raw())
    }

    /// 응답 timeout(ms) 변경 — 보행 중 락 보유 상한 축소용. 락 안에서 backend mutate.
    public func setIoTimeout(ms: UInt32) {
        locked { _ = fc_bus_set_io_timeout(raw(), ms) }
    }

    // MARK: - Motion play (Sprint 15 라이브러리 노출 — 2026-05-16 v1.1 통합)

    /// `motion_4096.bin` 의 `slot` 페이지를 실 robot 에 동기 송출.
    ///
    /// - Parameters:
    ///   - slot: 페이지 번호 (예: 24/27 단발, 9 walkready, 10/11 = get-up (f up/b up); 12/13 = kick (rk/lk))
    ///   - binPath: nil 이면 `FORGE_MOTION_BIN` env 또는 소스 트리 기본 경로 사용
    ///   - dryRun: true 면 stdout 로그만 (실 송출 없음)
    ///   - confirmRisk: HighRisk 모션 실행 허용 (get-up page 10/11 포함)
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
