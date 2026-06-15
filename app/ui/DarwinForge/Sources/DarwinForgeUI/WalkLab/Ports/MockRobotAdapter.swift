#if DEBUG
import Foundation
import ForgeCore

/// **V287-3** — RobotPort 의 test-only in-memory implementation.
///
/// # 비유
///
/// 비행기 운항 훈련 시뮬레이터 (MockBus 와 동일 정책). RobotPort 의 port-level
/// mock — `BusInterface` MockBus 보다 한 단계 위에서 domain-level 검증.
///
/// # Sendable
///
/// MockBus 와 동일 — `@unchecked Sendable`, 단일 thread test harness 가정.
public final class MockRobotAdapter: RobotPort, @unchecked Sendable {

    // MARK: - Configurable state

    public var simulatedDxlPower: Bool = true
    public var simulatedStatus: RobotConnectionStatus = .connected(latencyMs: 1.0)
    public var simulatedImu: ImuRaw = ImuRaw(
        gyroX: 512, gyroY: 512, gyroZ: 512,
        accelX: 512, accelY: 512, accelZ: 768,  // ~1g downward
        rollDeg: 0, pitchDeg: 0
    )

    // MARK: - Failure injection (single-shot, auto-reset)

    public var failNextWrite: Bool = false
    public var failNextWriteBatch: Bool = false
    public var failNextReadIMU: Bool = false
    public var failNextRecover: Bool = false

    // MARK: - Recorded calls (assertion 용)

    public private(set) var writeCount: Int = 0
    public private(set) var batchWriteCount: Int = 0
    public private(set) var emergencyStopCount: Int = 0
    public private(set) var recoverCount: Int = 0
    public private(set) var lastWrite: (joint: JointID, raw: UInt16)?

    public init() {}

    // MARK: - RobotPort

    public var isDxlPowerOn: Bool { simulatedDxlPower }
    public var connectionStatus: RobotConnectionStatus { simulatedStatus }

    @discardableResult
    public func writeJointPosition(
        _ joint: JointID, raw: UInt16
    ) async throws -> UInt16 {
        if failNextWrite {
            failNextWrite = false
            throw RobotPortError.writeFailed(joint: joint, code: -3)
        }
        guard simulatedDxlPower else { throw RobotPortError.dxlPowerOff }
        writeCount += 1
        lastWrite = (joint, raw)
        return raw
    }

    public func writeJointPositions(_ targets: [JointID: UInt16]) async throws {
        if failNextWriteBatch {
            failNextWriteBatch = false
            throw RobotPortError.busDisconnected
        }
        guard simulatedDxlPower else { throw RobotPortError.dxlPowerOff }
        batchWriteCount += 1
    }

    public func readIMU() async throws -> ImuRaw {
        if failNextReadIMU {
            failNextReadIMU = false
            throw RobotPortError.imuStale
        }
        return simulatedImu
    }

    public func emergencyStop() async {
        emergencyStopCount += 1
        simulatedDxlPower = false
        simulatedStatus = .emergencyStopped
    }

    public func recover() async throws {
        if failNextRecover {
            failNextRecover = false
            throw RobotPortError.busDisconnected
        }
        recoverCount += 1
        simulatedDxlPower = true
        simulatedStatus = .connected(latencyMs: 1.0)
    }
}
#endif
