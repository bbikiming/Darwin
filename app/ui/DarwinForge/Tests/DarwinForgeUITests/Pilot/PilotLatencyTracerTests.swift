import XCTest
@testable import DarwinForgeUI

/// **bus D0 계측** — PilotLatencyTracer 의 지터/지연 통계·게이트 검증.
final class PilotLatencyTracerTests: XCTestCase {
    func testDisabledByDefault_recordsNothing() {
        let tracer = PilotLatencyTracer(capacity: 16)
        for v in [1.0, 2.0, 3.0] { tracer.recordStepJitter(deviationMs: v) }
        XCTAssertEqual(tracer.jitterStats().count, 0)
        XCTAssertNil(tracer.hudSummary())
    }

    func testEnabled_recordsJitterPercentiles() {
        let tracer = PilotLatencyTracer(capacity: 128, enabled: true)
        // 0..<100 ms 편차 100개 → p50≈50, p95≈95.
        for v in 0..<100 { tracer.recordStepJitter(deviationMs: Double(v)) }
        let s = tracer.jitterStats()
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.p50Ms, 50, accuracy: 1.0)
        XCTAssertEqual(s.p95Ms, 95, accuracy: 1.0)
        XCTAssertEqual(s.maxAbsMs, 99, accuracy: 0.001)
    }

    func testMaxAbsUsesMagnitude_forSignedJitter() {
        let tracer = PilotLatencyTracer(capacity: 16, enabled: true)
        for v in [-12.0, 3.0, -1.0, 5.0] { tracer.recordStepJitter(deviationMs: v) }
        XCTAssertEqual(tracer.jitterStats().maxAbsMs, 12, accuracy: 0.001)
    }

    func testRingWrapsAtCapacity() {
        let tracer = PilotLatencyTracer(capacity: 4, enabled: true)
        for v in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] { tracer.recordStepJitter(deviationMs: v) }
        // 마지막 4개(3,4,5,6)만 보존.
        let s = tracer.jitterStats()
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.maxAbsMs, 6, accuracy: 0.001)
    }

    func testSeparateChannels_writeAndImu() {
        let tracer = PilotLatencyTracer(capacity: 16, enabled: true)
        tracer.recordWriteLatency(ms: 0.5)
        tracer.recordImuReadLatency(ms: 2.5)
        XCTAssertEqual(tracer.writeStats().count, 1)
        XCTAssertEqual(tracer.writeStats().p95Ms, 0.5, accuracy: 0.001)
        XCTAssertEqual(tracer.imuReadStats().count, 1)
        XCTAssertEqual(tracer.imuReadStats().p95Ms, 2.5, accuracy: 0.001)
        // jitter 채널은 비어 있어야(채널 독립).
        XCTAssertEqual(tracer.jitterStats().count, 0)
    }

    func testHudSummary_presentWhenEnabledWithData() {
        let tracer = PilotLatencyTracer(capacity: 16, enabled: true)
        tracer.recordStepJitter(deviationMs: 4.0)
        tracer.recordWriteLatency(ms: 0.6)
        let summary = tracer.hudSummary()
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("jitter") ?? false)
        XCTAssertTrue(summary?.contains("n=1") ?? false)
    }

    func testSetEnabledToggle_andReset() {
        let tracer = PilotLatencyTracer(capacity: 16)
        XCTAssertFalse(tracer.isEnabled)
        tracer.setEnabled(true)
        XCTAssertTrue(tracer.isEnabled)
        tracer.recordStepJitter(deviationMs: 10)
        XCTAssertEqual(tracer.jitterStats().count, 1)
        tracer.reset()
        XCTAssertEqual(tracer.jitterStats().count, 0)
    }

    func testConfigureFromDefaults() {
        let suite = "PilotLatencyTracerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PilotLatencyTracer.enabledDefaultsKey)
        let tracer = PilotLatencyTracer(capacity: 8)
        tracer.configureFromDefaults(defaults)
        XCTAssertTrue(tracer.isEnabled)
    }
}
