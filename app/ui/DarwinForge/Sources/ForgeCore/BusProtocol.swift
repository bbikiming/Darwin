import Foundation

/// 사이클 255 — `Bus` interface 추상화.
///
/// 비유: 자동차 운전석 (인터페이스) 과 엔진 (구현) 을 분리. 시뮬레이터 운전석 (MockBus)
/// 으로 같은 페달/핸들을 조작하면 실 엔진 대신 가상 엔진이 반응. 도로 (테스트 코드) 위에서
/// 새 운전 시나리오를 안전하게 검증.
///
/// 종전: `ConnectionStore.bus` 가 hardware-bound `Bus` (FFI / `fc_*` C-binding) 만 받음 →
/// recovery / poseApply / preflight 의 25 caller 가 mock 없이는 unit test 불가능.
/// **test-coverage agent 가 발견한 가장 큰 testing gap**.
///
/// 신규: protocol 로 분리 → test 에서 `MockBus` 주입 가능. recovery 의 P_GAIN 복원,
/// poseApply 의 SafeMotion verdict, preflight 의 dxlPower / torque 시퀀스 모두 unit test.
///
/// **Sendable**: `Bus` 가 `@unchecked Sendable` 이고 내부적으로 `NSRecursiveLock` 으로
/// transaction 직렬화. `MockBus` 도 `@unchecked Sendable` 로 동일 보장 (in-memory dict
/// 접근은 main actor / single thread 에서만 — test harness 가 보증).
public protocol BusInterface: AnyObject, Sendable {

    // MARK: - Bus discovery / health

    func ping(id: UInt8) throws
    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8]
    func boardSnapshot() throws -> BoardSnapshot
    func readImu() throws -> ImuRaw

    // MARK: - FSR (foot pressure sensors)

    func readFsrLeft() throws -> FsrReading
    func readFsrRight() throws -> FsrReading

    // MARK: - Power / torque

    func setDxlPower(_ on: Bool) throws
    func setTorque(_ joint: JointID, enable: Bool) throws
    func emergencyStop() throws

    // MARK: - Joint write

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16
    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws
    func setPGain(_ joint: JointID, value: UInt8) throws

    // MARK: - Joint read

    func readState(_ joint: JointID) throws -> JointState

    // MARK: - Motion play (Sprint 15)

    func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws

    func motionPlayCancel() throws

    var isMotionPlaying: Bool { get }
}

/// `Bus` 는 이미 모든 BusInterface 메서드를 구현 — empty conformance.
extension Bus: BusInterface {}
