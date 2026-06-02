import XCTest
@testable import DarwinForgeUI

/// Unit tests for FallTelemetryRingBuffer — capacity cap, eviction order, snapshot ordering.
final class FallTelemetryRingBufferTests: XCTestCase {

    // MARK: - Helpers

    private func makeSample(tMs: Double) -> FallTelemetrySample {
        FallTelemetrySample(
            tMs: tMs, imuRollDeg: 0, imuPitchDeg: 0,
            gyroXDps: 0, gyroYDps: 0, gyroZDps: 0,
            accelXG: 0, accelYG: 0, accelZG: 0,
            balanceState: "normal", autoRecoveryPhase: "idle"
        )
    }

    // MARK: - Capacity cap

    func testCapacityDefault() {
        let buf = FallTelemetryRingBuffer()
        XCTAssertEqual(buf.capacity, FallTelemetryRingBuffer.defaultCapacity)
        XCTAssertEqual(FallTelemetryRingBuffer.defaultCapacity, 150)
    }

    func testCapacityCustom() {
        let buf = FallTelemetryRingBuffer(capacity: 5)
        XCTAssertEqual(buf.capacity, 5)
    }

    func testCapacityNotExceeded_exactlyCapacity() {
        var buf = FallTelemetryRingBuffer(capacity: 3)
        for i in 0..<3 {
            buf.push(makeSample(tMs: Double(i)))
        }
        XCTAssertEqual(buf.sampleCount, 3, "Buffer should hold exactly capacity samples")
    }

    func testCapacityNotExceeded_overCapacity() {
        var buf = FallTelemetryRingBuffer(capacity: 3)
        for i in 0..<10 {
            buf.push(makeSample(tMs: Double(i)))
        }
        XCTAssertEqual(buf.sampleCount, 3, "Buffer must not grow beyond capacity")
    }

    // MARK: - Eviction order

    func testEvictionOrder_oldestDropped() {
        var buf = FallTelemetryRingBuffer(capacity: 3)
        for i in 0..<5 {
            buf.push(makeSample(tMs: Double(i)))
        }
        // After pushing 0,1,2,3,4 with capacity 3 → [2,3,4] retained.
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 3)
        XCTAssertEqual(snap[0].tMs, 2.0, "Oldest retained = tMs 2")
        XCTAssertEqual(snap[1].tMs, 3.0)
        XCTAssertEqual(snap[2].tMs, 4.0, "Newest = tMs 4")
    }

    // MARK: - Snapshot ordering

    func testSnapshotOrdering_chronological() {
        var buf = FallTelemetryRingBuffer(capacity: 5)
        for i in 0..<5 {
            buf.push(makeSample(tMs: Double(i) * 100.0))
        }
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 5)
        for i in 0..<4 {
            XCTAssertLessThan(snap[i].tMs, snap[i + 1].tMs,
                "snapshot must be in chronological (oldest→newest) order")
        }
    }

    func testSnapshotEmpty() {
        let buf = FallTelemetryRingBuffer(capacity: 10)
        XCTAssertTrue(buf.snapshot().isEmpty, "Empty buffer yields empty snapshot")
    }

    func testSnapshotBeforeFullCapacity() {
        var buf = FallTelemetryRingBuffer(capacity: 5)
        buf.push(makeSample(tMs: 0))
        buf.push(makeSample(tMs: 1))
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[0].tMs, 0)
        XCTAssertEqual(snap[1].tMs, 1)
    }

    // MARK: - Clear

    func testClear() {
        var buf = FallTelemetryRingBuffer(capacity: 5)
        for i in 0..<5 { buf.push(makeSample(tMs: Double(i))) }
        buf.clear()
        XCTAssertEqual(buf.sampleCount, 0)
        XCTAssertTrue(buf.snapshot().isEmpty)
    }

    // MARK: - Wrap-around correctness

    func testWrapAround_severalPushes() {
        // capacity 4, push 7 → 4,5,6 retained (last 3 after extra wrap).
        // Actually with capacity 4 and 7 pushes: last 4 = 3,4,5,6.
        var buf = FallTelemetryRingBuffer(capacity: 4)
        for i in 0..<7 {
            buf.push(makeSample(tMs: Double(i)))
        }
        let snap = buf.snapshot()
        XCTAssertEqual(snap.count, 4)
        XCTAssertEqual(snap.map { $0.tMs }, [3.0, 4.0, 5.0, 6.0],
            "Last 4 samples in order after wrap-around")
    }
}
