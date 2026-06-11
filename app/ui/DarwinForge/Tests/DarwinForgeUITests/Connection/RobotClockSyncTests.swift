import XCTest
@testable import DarwinForgeUI

/// **O0 — 로봇 클럭 오프셋 EWMA 추정기** (walklab-onboard-teleop-upgrade O0-1).
final class RobotClockSyncTests: XCTestCase {

    func testFirstSample_seedsOffset() {
        let sync = RobotClockSync(alpha: 0.2)
        XCTAssertNil(sync.offsetMs)
        // robot ts = 10500, tx=10000, rx=10010 → mid=10005 → offset ≈ 495.
        XCTAssertTrue(sync.record(robotTsMs: 10500, txMs: 10000, rxMs: 10010))
        XCTAssertEqual(sync.offsetMs ?? 0, 495, accuracy: 0.001)
        XCTAssertEqual(sync.sampleCount, 1)
    }

    func testEwma_smoothsTowardNewSamples() {
        let sync = RobotClockSync(alpha: 0.5)
        sync.record(robotTsMs: 1000, txMs: 1000, rxMs: 1000)   // offset 0 (seed)
        // 두 번째 표본 offset 100 → EWMA 0 + 0.5*(100-0) = 50.
        sync.record(robotTsMs: 1100, txMs: 1000, rxMs: 1000)
        XCTAssertEqual(sync.offsetMs ?? -1, 50, accuracy: 0.001)
    }

    func testRejectsNegativeRtt() {
        let sync = RobotClockSync()
        // rx < tx → 클럭 역전/측정 오류 → 거부.
        XCTAssertFalse(sync.record(robotTsMs: 1000, txMs: 2000, rxMs: 1000))
        XCTAssertNil(sync.offsetMs)
    }

    func testRejectsExcessiveRtt() {
        let sync = RobotClockSync(maxAcceptableRttMs: 500)
        XCTAssertFalse(sync.record(robotTsMs: 1000, txMs: 1000, rxMs: 2000))  // rtt 1000 > 500
        XCTAssertNil(sync.offsetMs)
    }

    func testRobotToMacMs_nilUntilOffsetKnown() {
        let sync = RobotClockSync()
        XCTAssertNil(sync.robotToMacMs(12345))   // 표본 없음 → 추정 불가.
        sync.record(robotTsMs: 5000, txMs: 4000, rxMs: 4000)   // offset 1000
        XCTAssertEqual(sync.robotToMacMs(6000) ?? 0, 5000, accuracy: 0.001)
    }

    func testReset() {
        let sync = RobotClockSync()
        sync.record(robotTsMs: 1000, txMs: 1000, rxMs: 1000)
        XCTAssertNotNil(sync.offsetMs)
        sync.reset()
        XCTAssertNil(sync.offsetMs)
        XCTAssertEqual(sync.sampleCount, 0)
    }
}
