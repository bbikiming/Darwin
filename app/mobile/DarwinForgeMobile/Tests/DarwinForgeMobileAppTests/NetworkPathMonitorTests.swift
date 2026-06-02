import XCTest
@testable import DarwinForgeMobileApp

@MainActor
final class NetworkPathMonitorTests: XCTestCase {

    func test_initialState_isOptimisticallyOnline() {
        let monitor = NetworkPathMonitor()
        XCTAssertTrue(monitor.isOnline)
    }

    func test_offlineThenOnline_firesRestoredOnce() {
        let monitor = NetworkPathMonitor()
        var restoredCount = 0
        monitor.onRestored = { restoredCount += 1 }

        // online(초기) → offline: 콜백 없음.
        monitor.applyPath(isSatisfied: false)
        XCTAssertFalse(monitor.isOnline)
        XCTAssertEqual(restoredCount, 0)

        // offline → online: onRestored 1회.
        monitor.applyPath(isSatisfied: true)
        XCTAssertTrue(monitor.isOnline)
        XCTAssertEqual(restoredCount, 1)
    }

    func test_repeatedSameState_noDuplicateCallback() {
        let monitor = NetworkPathMonitor()
        var restoredCount = 0
        monitor.onRestored = { restoredCount += 1 }

        monitor.applyPath(isSatisfied: false)
        monitor.applyPath(isSatisfied: false)   // 동일 상태
        XCTAssertEqual(restoredCount, 0)

        monitor.applyPath(isSatisfied: true)
        monitor.applyPath(isSatisfied: true)    // 동일 상태 — 중복 콜백 없음
        XCTAssertEqual(restoredCount, 1)
    }

    func test_startingOnline_noSpuriousRestored() {
        let monitor = NetworkPathMonitor()
        var restoredCount = 0
        monitor.onRestored = { restoredCount += 1 }

        // 이미 online 인데 satisfied 통지 → 변화 없음 → 콜백 없음.
        monitor.applyPath(isSatisfied: true)
        XCTAssertEqual(restoredCount, 0)
    }

    func test_multipleCycles() {
        let monitor = NetworkPathMonitor()
        var restoredCount = 0
        monitor.onRestored = { restoredCount += 1 }

        monitor.applyPath(isSatisfied: false)
        monitor.applyPath(isSatisfied: true)    // +1
        monitor.applyPath(isSatisfied: false)
        monitor.applyPath(isSatisfied: true)    // +1
        XCTAssertEqual(restoredCount, 2)
    }
}
