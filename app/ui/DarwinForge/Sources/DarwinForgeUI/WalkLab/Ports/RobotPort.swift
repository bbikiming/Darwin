import Foundation
import ForgeCore

/// **V287-3 (2026-05-24, Hexagonal Architecture, V286-4 권고)** — Robot I/O 경계.
///
/// # 비유 (Hexagonal Architecture, Cockburn 2005)
///
/// WalkLabSession 이 "내부 도메인" — gait pattern, balance 계산. RobotPort 가
/// "외부 어댑터" 와의 port. 실제 어댑터는:
/// - `DXLAdapter`: 실 ROBOTIS-OP2 (BusInterface wrapper) — V288 예정
/// - `MockRobotAdapter`: 테스트 (in-memory state) — 본 cycle
/// - `ReplayAdapter`: 과거 session jsonl 재생 — V289 예정
///
/// 동일 도메인 코드가 3 환경에서 동작.
///
/// # 안전 (V282-5 CRITICAL 직접 차단)
///
/// 모든 joint write 는 본 protocol 경유 → `writeJointPosition` 단일 gate 통과.
/// V282-5 "WalkCycleEngine bus.setPosition 우회" CRITICAL fix 의 backbone.
/// `WalkLabSession+WalkCycleEngine.swift` line 120/236/350/425 의 4개 직접
/// 호출이 V288 에서 본 port 경유로 교체 예정.
///
/// # async/Sendable
///
/// Swift Concurrency 정렬 위해 `async` 채택. DXLAdapter 는 actor isolation 위 호출.
public protocol RobotPort: Sendable {

    /// dxlPower 상태 — write gate prerequisite.
    var isDxlPowerOn: Bool { get async }

    /// connection 상태 (UI + diagnostic + SLO).
    var connectionStatus: RobotConnectionStatus { get async }

    /// 단일 joint position write. dxlPower OFF 시 throw + emergencyStop.
    /// V282-5 SSoT — 모든 joint write canonical entry point.
    @discardableResult
    func writeJointPosition(_ joint: JointID, raw: UInt16) async throws -> UInt16

    /// 일괄 write (50Hz tick 최적). SYNC_WRITE 한 transaction.
    func writeJointPositions(_ targets: [JointID: UInt16]) async throws

    /// IMU read — stale 시 `RobotPortError.imuStale` throw.
    func readIMU() async throws -> ImuRaw

    /// E-Stop — chain 전체 (torque OFF + walkSession cancel + dxlPower=false).
    /// V282-5 SSoT — 모든 entry point 가 본 method 호출.
    func emergencyStop() async

    /// recovery — preflight 통과 후만.
    func recover() async throws
}

/// connection 상태 — UI / 진단 / SLO 측정 공통.
public enum RobotConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(latencyMs: Double)
    case recovering
    case emergencyStopped
}

/// Error 통일 — port caller fallback 단일 패턴.
/// `ForgeError` 는 FFI-near 저수준, `RobotPortError` 는 domain-aware 고수준.
public enum RobotPortError: Error, Equatable {
    case dxlPowerOff
    case busDisconnected
    case timeout(after: TimeInterval)
    case writeFailed(joint: JointID, code: Int32)
    case imuStale
}
