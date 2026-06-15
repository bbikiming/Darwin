import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// Wave 4.2.1 (사이클 V260-1) 회귀 가드.
///
/// `ConnectionStore.health` 로 분리된 health/telemetry state 의 mutator + computed 검증.
/// 종전 `store.lastSuccessAt` 등 직접 path 접근은 backward-compat delegate 로 유지되며,
/// 본 테스트는 새 path (`store.health.recordSuccess(...)`) + `isImuStale`/`isImuUnavailable`
/// 임계 동작을 격리해서 검증한다.
@MainActor
final class ConnectionHealthStoreTests: XCTestCase {

    // MARK: - 1. recordSuccess 증가

    func testRecordSuccessIncrements() {
        let store = ConnectionHealthStore()
        XCTAssertEqual(store.successCount, 0)
        XCTAssertNil(store.lastRoundTripMs)

        store.recordSuccess(rttMs: 12.5)
        XCTAssertEqual(store.successCount, 1)
        XCTAssertEqual(store.lastRoundTripMs, 12.5)
        XCTAssertNotNil(store.lastSuccessAt)

        store.recordSuccess(rttMs: 9.0)
        XCTAssertEqual(store.successCount, 2)
        XCTAssertEqual(store.lastRoundTripMs, 9.0)
    }

    // MARK: - 2. recordImuSuccess 가 lastImuRaw 와 sequence 갱신

    func testRecordImuSuccessUpdatesLastRaw() {
        let store = ConnectionHealthStore()
        XCTAssertNil(store.lastImuRaw)
        XCTAssertEqual(store.imuSequenceCount, 0)

        let sample = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 1.0, pitchDeg: 2.0)
        store.recordImuSuccess(raw: sample)

        XCTAssertEqual(store.lastImuRaw, sample)
        XCTAssertEqual(store.imuSequenceCount, 1)
        XCTAssertNotNil(store.lastImuSuccessAt)
        XCTAssertEqual(store.imuConsecutiveFailures, 0)
        XCTAssertNil(store.lastImuError)
    }

    // MARK: - 3. isImuStale 5초 임계

    func testIsImuStaleAfter5s() {
        let store = ConnectionHealthStore()
        // 초기: lastImuSuccessAt nil + failure 0 → false.
        XCTAssertFalse(store.isImuStale)

        // 6초 전 성공으로 강제 set (older than 5s).
        let oldDate = Date().addingTimeInterval(-6.0)
        let sample = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0)
        store.recordImuSuccess(raw: sample, at: oldDate)
        XCTAssertTrue(store.isImuStale, "6초 전 IMU 성공 → stale")

        // 방금 성공 → not stale.
        store.recordImuSuccess(raw: sample, at: Date())
        XCTAssertFalse(store.isImuStale, "방금 성공 → not stale")
    }

    // MARK: - 4. isImuUnavailable 3회 연속 실패

    func testIsImuUnavailableAfter3Failures() {
        let store = ConnectionHealthStore()
        XCTAssertFalse(store.isImuUnavailable)

        struct DummyError: Error {}
        store.recordImuFailure(error: DummyError())
        XCTAssertFalse(store.isImuUnavailable, "1회 — not unavailable")
        store.recordImuFailure(error: DummyError())
        XCTAssertFalse(store.isImuUnavailable, "2회 — not unavailable")
        store.recordImuFailure(error: DummyError())
        // 3회 + lastSuccessAt nil → unavailable.
        XCTAssertTrue(store.isImuUnavailable, "3회 연속 + 최초 성공 없음 → unavailable")
        XCTAssertEqual(store.imuConsecutiveFailures, 3)
        XCTAssertEqual(store.busReadFailureCount, 3, "bus read failure 도 동기 누적")
    }

    // MARK: - 5. reset 모든 카운터 초기화

    func testResetClearsAllCounters() {
        let store = ConnectionHealthStore()
        store.recordConnected(rttMs: 5.0)
        store.recordSuccess(rttMs: 4.0)
        store.recordFailure()
        let sample = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0)
        store.recordImuSuccess(raw: sample)
        store.bumpBusWriteFailure()
        store.bumpBusReadFailure()
        store.appendVoltage(7.4)
        store.appendAvgTemp(35.0)
        store.bumpFsrFailure()
        store.disableFsrPolling()

        // sanity — 모두 0/non-nil 이 아님 확인.
        XCTAssertGreaterThan(store.successCount, 0)
        XCTAssertGreaterThan(store.failureCount, 0)
        XCTAssertNotNil(store.connectedAt)
        XCTAssertNotNil(store.lastImuRaw)
        XCTAssertGreaterThan(store.busWriteFailureCount, 0)
        XCTAssertGreaterThan(store.busReadFailureCount, 0)
        XCTAssertFalse(store.voltageHistory.isEmpty)
        XCTAssertFalse(store.avgTempHistory.isEmpty)
        XCTAssertGreaterThan(store.fsrConsecutiveFailures, 0)
        XCTAssertTrue(store.fsrPollingDisabled)

        store.reset()

        XCTAssertEqual(store.successCount, 0)
        XCTAssertEqual(store.failureCount, 0)
        XCTAssertNil(store.connectedAt)
        XCTAssertNil(store.lastSuccessAt)
        XCTAssertNil(store.lastRoundTripMs)
        XCTAssertNil(store.lastImuRaw)
        XCTAssertNil(store.lastImuSuccessAt)
        XCTAssertEqual(store.imuConsecutiveFailures, 0)
        XCTAssertEqual(store.imuSequenceCount, 0)
        XCTAssertNil(store.lastImuError)
        XCTAssertEqual(store.busWriteFailureCount, 0)
        XCTAssertEqual(store.busReadFailureCount, 0)
        XCTAssertTrue(store.voltageHistory.isEmpty)
        XCTAssertTrue(store.avgTempHistory.isEmpty)
        XCTAssertNil(store.lastFsrLeft)
        XCTAssertNil(store.lastFsrRight)
        XCTAssertNil(store.lastFsrSuccessAt)
        XCTAssertEqual(store.fsrConsecutiveFailures, 0)
        XCTAssertFalse(store.fsrPollingDisabled)
    }
}
