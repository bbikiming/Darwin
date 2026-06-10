import Foundation
@testable import ForgeCore

/// 사이클 255 — `BusInterface` test-only in-memory mock.
///
/// 비유: 비행기 운항 훈련 시뮬레이터. 실제 활주로 (FFI / Dynamixel bus) 없이 가상 cockpit
/// 으로 조종 시퀀스를 검증. 실제 모터에 영향 없이 recovery / preflight / poseApply 의
/// 결정 트리를 단위 테스트.
///
/// **용도**: ConnectionStore 의 recovery (`recoverFromEStop`), poseApply
/// (`applyPoseSlowlyForRecovery`), preflight (`preflightForWalkCycle`) 의 unit test 에서
/// `Bus?` 자리에 주입. 모든 write 는 in-memory dict 누적, read 는 마지막 set 값 또는
/// pre-seeded 값 반환.
///
/// **failure injection**: `failNextSetPosition = true` 와 같이 single-shot failure 트리거
/// → 다음 호출에서 throw 후 auto-reset. 멀티 호출 실패가 필요하면 `failsRemaining` (없으면
/// 직접 토글) 패턴 사용.
///
/// **Sendable**: `Bus` 와 동일하게 `@unchecked Sendable`. 본 mock 은 main actor 또는
/// 단일 thread test harness 에서만 사용 — concurrent access 시 별도 lock 필요.
public final class MockBus: BusInterface, @unchecked Sendable {

    // MARK: - Recorded writes (assertion 용)

    public private(set) var positionWrites: [(joint: JointID, raw: UInt16)] = []
    public private(set) var speedWrites: [(joint: JointID, speed: UInt16)] = []
    public private(set) var torqueWrites: [(joint: JointID, enable: Bool)] = []
    public private(set) var pGainWrites: [(joint: JointID, value: UInt8)] = []
    public private(set) var dxlPowerWrites: [Bool] = []
    public private(set) var emergencyStopCount: Int = 0
    public private(set) var motionPlaySlotCalls: [(slot: UInt8, confirmRisk: Bool, dryRun: Bool)] = []
    public private(set) var motionPlayCancelCount: Int = 0
    public private(set) var pingCalls: [UInt8] = []

    /// `setPositions` 배치 호출 기록 — CommBatch 테스트에서 "1 batched call not N individual" 검증.
    public private(set) var batchPositionCalls: [[(joint: JointID, raw: UInt16)]] = []
    /// transport failure injection for `setPositions` batch call.
    public var failNextSetPositions: Bool = false

    // MARK: - In-memory state

    private var positions: [JointID: UInt16] = [:]
    private var speeds: [JointID: UInt16] = [:]
    private var torques: [JointID: Bool] = [:]
    private var pGains: [JointID: UInt8] = [:]

    // MARK: - Failure injection (single-shot — 호출 후 auto-reset)

    public var failNextSetPosition: Bool = false
    public var failNextSetTorque: Bool = false
    public var failNextSetMovingSpeed: Bool = false
    public var failNextSetPGain: Bool = false
    public var failNextSetDxlPower: Bool = false
    public var failNextEmergencyStop: Bool = false
    public var failNextReadImu: Bool = false
    public var failNextReadState: Bool = false
    public var failNextBoardSnapshot: Bool = false
    public var failNextPing: Bool = false

    // MARK: - Failure injection (지속 — 명시 해제 전까지 유지)

    /// L5 liveness 프로브 테스트용 — ping 을 상시 실패시킨다 (auto-reset 없음).
    public var alwaysFailPing: Bool = false
    public var failNextScan: Bool = false
    public var failNextReadFsrLeft: Bool = false
    public var failNextReadFsrRight: Bool = false
    public var failNextMotionPlaySlot: Bool = false
    public var failNextMotionPlayCancel: Bool = false

    // MARK: - Pre-seeded responses

    public var imuResponse: ImuRaw?
    public var boardSnapshotResponse: BoardSnapshot?
    public var fsrLeftResponse: FsrReading?
    public var fsrRightResponse: FsrReading?
    public var scanResponse: [UInt8] = []
    public var motionPlayingFlag: Bool = false

    public init() {}

    // MARK: - Bus discovery / health

    public func ping(id: UInt8) throws {
        if alwaysFailPing { throw ForgeError.timeout }
        if failNextPing {
            failNextPing = false
            throw ForgeError.timeout
        }
        pingCalls.append(id)
    }

    public func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] {
        if failNextScan {
            failNextScan = false
            throw ForgeError.io
        }
        return scanResponse
    }

    public func boardSnapshot() throws -> BoardSnapshot {
        if failNextBoardSnapshot {
            failNextBoardSnapshot = false
            throw ForgeError.timeout
        }
        guard let snap = boardSnapshotResponse else {
            // 명시 seed 없으면 IO 에러 — test 가 의도적으로 BoardSnapshot 사용 시 set 필수.
            throw ForgeError.io
        }
        return snap
    }

    public func readImu() throws -> ImuRaw {
        if failNextReadImu {
            failNextReadImu = false
            throw ForgeError.timeout
        }
        return imuResponse ?? Self.defaultImu
    }

    // MARK: - FSR

    public func readFsrLeft() throws -> FsrReading {
        if failNextReadFsrLeft {
            failNextReadFsrLeft = false
            throw ForgeError.timeout
        }
        return fsrLeftResponse ?? Self.defaultFsrLeft
    }

    public func readFsrRight() throws -> FsrReading {
        if failNextReadFsrRight {
            failNextReadFsrRight = false
            throw ForgeError.timeout
        }
        return fsrRightResponse ?? Self.defaultFsrRight
    }

    // MARK: - Power / torque

    public func setDxlPower(_ on: Bool) throws {
        if failNextSetDxlPower {
            failNextSetDxlPower = false
            throw ForgeError.io
        }
        dxlPowerWrites.append(on)
    }

    public func setTorque(_ joint: JointID, enable: Bool) throws {
        if failNextSetTorque {
            failNextSetTorque = false
            throw ForgeError.io
        }
        torqueWrites.append((joint, enable))
        torques[joint] = enable
    }

    public func emergencyStop() throws {
        if failNextEmergencyStop {
            failNextEmergencyStop = false
            throw ForgeError.io
        }
        emergencyStopCount += 1
        // emergency stop = 전체 torque OFF.
        for j in JointID.allCases { torques[j] = false }
    }

    // MARK: - Joint write

    @discardableResult
    public func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        if failNextSetPosition {
            failNextSetPosition = false
            throw ForgeError.timeout
        }
        positionWrites.append((joint, position))
        positions[joint] = position
        return position
    }

    /// `setPositions` — SYNC_WRITE 1패킷 시뮬. 전체 배치를 `batchPositionCalls` 에 기록하고,
    /// 각 target 을 `positionWrites` 에도 개별 추가해 기존 assertion 과 호환.
    public func setPositions(_ targets: [(JointID, UInt16)]) throws {
        guard !targets.isEmpty else { return }
        if failNextSetPositions {
            failNextSetPositions = false
            throw ForgeError.io
        }
        let batch = targets.map { (joint: $0.0, raw: $0.1) }
        batchPositionCalls.append(batch)
        for (joint, raw) in targets {
            positionWrites.append((joint, raw))
            positions[joint] = raw
        }
    }

    public func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {
        if failNextSetMovingSpeed {
            failNextSetMovingSpeed = false
            throw ForgeError.io
        }
        speedWrites.append((joint, speed))
        speeds[joint] = speed
    }

    public func setPGain(_ joint: JointID, value: UInt8) throws {
        if failNextSetPGain {
            failNextSetPGain = false
            throw ForgeError.io
        }
        pGainWrites.append((joint, value))
        pGains[joint] = value
    }

    // MARK: - Joint read

    public func readState(_ joint: JointID) throws -> JointState {
        if failNextReadState {
            failNextReadState = false
            throw ForgeError.timeout
        }
        // 합리적 default — mid-position, idle motor.
        let pos = positions[joint] ?? 2048
        return JointState(
            id: joint,
            torqueEnabled: torques[joint] ?? false,
            goalPosition: pos,
            presentPosition: pos,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 120,   // 12.0V
            presentTemperature: 25
        )
    }

    // MARK: - Motion play

    public func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws {
        if failNextMotionPlaySlot {
            failNextMotionPlaySlot = false
            throw ForgeError.io
        }
        motionPlaySlotCalls.append((slot, confirmRisk, dryRun))
    }

    public func motionPlayCancel() throws {
        if failNextMotionPlayCancel {
            failNextMotionPlayCancel = false
            throw ForgeError.io
        }
        motionPlayCancelCount += 1
        motionPlayingFlag = false
    }

    public var isMotionPlaying: Bool {
        motionPlayingFlag
    }

    // MARK: - Test helpers

    /// 모든 누적 write/read 카운터 reset (test scenario 간 격리).
    public func resetRecordedWrites() {
        positionWrites = []
        speedWrites = []
        torqueWrites = []
        pGainWrites = []
        dxlPowerWrites = []
        emergencyStopCount = 0
        motionPlaySlotCalls = []
        motionPlayCancelCount = 0
        pingCalls = []
        batchPositionCalls = []
    }

    /// 외부에서 in-memory position 직접 seed — readState 가 그 값 반환.
    public func seedPosition(_ joint: JointID, raw: UInt16) {
        positions[joint] = raw
    }

    // MARK: - Default responses (호출자가 seed 안 했을 때 합리적 기본값)

    private static let defaultImu = ImuRaw(
        gyroX: 512, gyroY: 512, gyroZ: 512,
        accelX: 512, accelY: 512, accelZ: 768,
        rollDeg: 0, pitchDeg: 0
    )

    private static let defaultFsrLeft = FsrReading(
        id: 112,
        cellFrontLeft: 256, cellFrontRight: 256,
        cellRearRight: 256, cellRearLeft: 256,
        centerX: 0, centerY: 0
    )

    private static let defaultFsrRight = FsrReading(
        id: 111,
        cellFrontLeft: 256, cellFrontRight: 256,
        cellRearRight: 256, cellRearLeft: 256,
        centerX: 0, centerY: 0
    )
}
