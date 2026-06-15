import Foundation
@testable import ForgeCore
@testable import DarwinForgeUI

/// 사이클 269 (V269-2) — failure-injection mock bus consolidation.
///
/// 종전: 3 file 에 분산 (MockBusIntegrationTests.swift / MockBusExtraTests.swift)
/// 신규: Mocks/ 디렉토리 단일 file — BusInterface 변경 시 단일 위치 maintain.
///
/// 비유: 비행 시뮬레이터 "고장 패널"을 한 곳에 모아 놓은 것처럼, 모든 failure-injection
/// mock 을 이 파일에 집중 — 어떤 메서드가 어떤 조건에서 실패하는지 한눈에 파악 가능.

// =============================================================================
// MARK: - AlwaysFailingMockBus
// =============================================================================

/// 연속 실패가 필요한 테스트용 mock — `MockBus` 의 single-shot flag 와 달리,
/// 초기화 파라미터로 지정한 메서드는 **항상** throw.
///
/// 비유: 비행 시뮬레이터에서 "엔진 2번 완전 고장" 스위치를 ON 으로 잠근 채 훈련.
final class AlwaysFailingMockBus: BusInterface, @unchecked Sendable {

    private(set) var dxlPowerCallCount: Int = 0
    private(set) var torqueCallCount: Int = 0
    private(set) var pGainCallCount: Int = 0
    private(set) var movingSpeedCallCount: Int = 0
    private(set) var positionCallCount: Int = 0

    private let failDxlPower: Bool
    private let failTorque: Bool
    private let failPGain: Bool
    private let failMovingSpeed: Bool
    private let failPosition: Bool

    init(
        failTorque: Bool = false,
        failDxlPower: Bool = true,
        failPGain: Bool = false,
        failMovingSpeed: Bool = false,
        failPosition: Bool = false
    ) {
        self.failDxlPower = failDxlPower
        self.failTorque = failTorque
        self.failPGain = failPGain
        self.failMovingSpeed = failMovingSpeed
        self.failPosition = failPosition
    }

    func setDxlPower(_ on: Bool) throws {
        dxlPowerCallCount += 1
        if failDxlPower { throw ForgeError.io }
    }

    func setTorque(_ joint: JointID, enable: Bool) throws {
        torqueCallCount += 1
        if failTorque { throw ForgeError.io }
    }

    func setPGain(_ joint: JointID, value: UInt8) throws {
        pGainCallCount += 1
        if failPGain { throw ForgeError.io }
    }

    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {
        movingSpeedCallCount += 1
        if failMovingSpeed { throw ForgeError.io }
    }

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        positionCallCount += 1
        if failPosition { throw ForgeError.timeout }
        return position
    }

    func readState(_ joint: JointID) throws -> JointState {
        JointState(
            id: joint,
            torqueEnabled: false,
            goalPosition: 2048,
            presentPosition: 2048,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 120,
            presentTemperature: 25
        )
    }

    // MARK: - 나머지 BusInterface 요구 메서드 — 항상 성공 (본 파일 테스트에서 미사용)

    func ping(id: UInt8) throws {}

    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }

    func boardSnapshot() throws -> BoardSnapshot {
        throw ForgeError.io
    }

    func readImu() throws -> ImuRaw {
        ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0
        )
    }

    func readFsrLeft() throws -> FsrReading {
        FsrReading(
            id: 112,
            cellFrontLeft: 256, cellFrontRight: 256,
            cellRearRight: 256, cellRearLeft: 256,
            centerX: 0, centerY: 0
        )
    }

    func readFsrRight() throws -> FsrReading {
        FsrReading(
            id: 111,
            cellFrontLeft: 256, cellFrontRight: 256,
            cellRearRight: 256, cellRearLeft: 256,
            centerX: 0, centerY: 0
        )
    }

    func emergencyStop() throws {}

    func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws {}

    func motionPlayCancel() throws {}

    var isMotionPlaying: Bool { false }
}

// =============================================================================
// MARK: - AlwaysFailFsrMockBus
// =============================================================================

/// FSR read (좌/우 모두) 를 항상 throw 하는 mock — FSR 3회 consecutive fail 경로 검증용.
///
/// 비유: 발바닥 압력센서가 완전히 고장난 로봇 시뮬레이터.
/// board snapshot / joint reads 등 나머지 메서드는 항상 성공 (FSR 경로만 격리 검증).
final class AlwaysFailFsrMockBus: BusInterface, @unchecked Sendable {

    func readFsrLeft() throws -> FsrReading {
        throw ForgeError.timeout  // 항상 실패
    }

    func readFsrRight() throws -> FsrReading {
        throw ForgeError.timeout  // 항상 실패
    }

    // MARK: - 나머지 메서드 — 항상 성공 (FSR 경로 격리)

    func ping(id: UInt8) throws {}

    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }

    func boardSnapshot() throws -> BoardSnapshot {
        BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
    }

    func readImu() throws -> ImuRaw {
        ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0
        )
    }

    func setDxlPower(_ on: Bool) throws {}

    func setTorque(_ joint: JointID, enable: Bool) throws {}

    func emergencyStop() throws {}

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 { position }

    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}

    func setPGain(_ joint: JointID, value: UInt8) throws {}

    func readState(_ joint: JointID) throws -> JointState {
        JointState(
            id: joint,
            torqueEnabled: false,
            goalPosition: 2048,
            presentPosition: 2048,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 120,
            presentTemperature: 25
        )
    }

    func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws {}

    func motionPlayCancel() throws {}

    var isMotionPlaying: Bool { false }
}

// =============================================================================
// MARK: - SingleJointFailMockBus
// =============================================================================

/// 지정한 단일 관절의 `setPosition` 만 throw 하는 mock — lowerBody 선택적 실패 경로 검증용.
///
/// 비유: 로봇 관절 테스터에서 특정 서보만 "고장" 스위치를 켜고 나머지는 정상 운전.
/// `failJoint` 의 position write 만 실패, 나머지 모든 관절과 write 타입은 성공.
final class SingleJointFailMockBus: BusInterface, @unchecked Sendable {

    let failJoint: JointID
    private(set) var positionWrites: [(joint: JointID, raw: UInt16)] = []
    private(set) var failCount: Int = 0

    init(failJoint: JointID) {
        self.failJoint = failJoint
    }

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        if joint == failJoint {
            failCount += 1
            throw ForgeError.timeout  // 단일 관절만 실패
        }
        positionWrites.append((joint, position))
        return position
    }

    // MARK: - 나머지 메서드 — 항상 성공

    func ping(id: UInt8) throws {}

    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }

    func boardSnapshot() throws -> BoardSnapshot {
        BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
    }

    func readImu() throws -> ImuRaw {
        ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0
        )
    }

    func readFsrLeft() throws -> FsrReading {
        FsrReading(
            id: 112,
            cellFrontLeft: 256, cellFrontRight: 256,
            cellRearRight: 256, cellRearLeft: 256,
            centerX: 0, centerY: 0
        )
    }

    func readFsrRight() throws -> FsrReading {
        FsrReading(
            id: 111,
            cellFrontLeft: 256, cellFrontRight: 256,
            cellRearRight: 256, cellRearLeft: 256,
            centerX: 0, centerY: 0
        )
    }

    func setDxlPower(_ on: Bool) throws {}

    func setTorque(_ joint: JointID, enable: Bool) throws {}

    func emergencyStop() throws {}

    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}

    func setPGain(_ joint: JointID, value: UInt8) throws {}

    func readState(_ joint: JointID) throws -> JointState {
        JointState(
            id: joint,
            torqueEnabled: false,
            goalPosition: 2048,
            presentPosition: 2048,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 120,
            presentTemperature: 25
        )
    }

    func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws {}

    func motionPlayCancel() throws {}

    var isMotionPlaying: Bool { false }
}
