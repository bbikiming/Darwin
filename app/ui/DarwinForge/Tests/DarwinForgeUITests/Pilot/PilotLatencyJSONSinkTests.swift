import XCTest
@testable import DarwinForgeUI

/// A1 — PilotLatencyTracer JSON session sink (cockpit-latency-hardening §6).
///
/// Cold-path, read-only. Proves the CODE behaves (encodes all 6 channels, writes
/// atomically, round-trips). The latency NUMBERS themselves are robot-deferred —
/// these tests do not assert any ms value is accurate, only that the structure is
/// faithful to whatever the tracer reports.
final class PilotLatencyJSONSinkTests: XCTestCase {

    private let sink = PilotLatencyJSONSink()

    // MARK: - testSinkEncodesAllChannelStatsToJSON

    func testSinkEncodesAllChannelStatsToJSON() throws {
        // A tracer with a couple of recorded samples on distinct channels.
        let tracer = PilotLatencyTracer(capacity: 64, enabled: true)
        tracer.recordStepJitter(deviationMs: 1.5)
        tracer.recordStepJitter(deviationMs: -2.0)
        tracer.recordWriteLatency(ms: 3.0)
        tracer.recordImuReadLatency(ms: 4.0)

        let report = sink.report(from: tracer)

        // All 6 channels must be present as keyed entries.
        XCTAssertEqual(report.channels.count, 6,
                       "report must carry exactly the 6 tracer channels")
        let keys = Set(report.channels.keys)
        XCTAssertEqual(keys, Set([
            "jitter", "write", "imuRead", "inputToSent", "inputToAck", "estopToSent"
        ]), "channel keys must match the 6 *Stats() accessors")

        // The jitter channel observed 2 samples — count must reflect the tracer.
        XCTAssertEqual(report.channels["jitter"]?.count, 2)
        XCTAssertEqual(report.channels["write"]?.count, 1)
        XCTAssertEqual(report.channels["imuRead"]?.count, 1)

        // startedAt/endedAt are epoch-ms and ordered.
        XCTAssertGreaterThan(report.startedAtEpochMs, 0)
        XCTAssertGreaterThanOrEqual(report.endedAtEpochMs, report.startedAtEpochMs)

        // JSON encodes cleanly with sorted keys (deterministic output).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let json = String(decoding: data, as: UTF8.self)
        for channel in ["jitter", "write", "imuRead", "inputToSent",
                        "inputToAck", "estopToSent"] {
            XCTAssertTrue(json.contains("\"\(channel)\""),
                          "encoded JSON must contain channel \(channel)")
        }
        // Reading the tracer must NOT have mutated it.
        XCTAssertEqual(tracer.jitterStats().count, 2,
                       "report() must be read-only — tracer state unchanged")
    }

    // MARK: - testSinkWritesToTempDirAndReturnsURL

    func testSinkWritesToTempDirAndReturnsURL() throws {
        let tracer = PilotLatencyTracer(capacity: 64, enabled: true)
        tracer.recordWriteLatency(ms: 7.0)
        let report = sink.report(from: tracer)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try sink.persist(report, into: dir)

        // File exists at the returned URL.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "persist must create the file at the returned URL")
        // Filename is "<epochMs>.json".
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".json"))
        let stem = url.deletingPathExtension().lastPathComponent
        XCTAssertNotNil(Int64(stem), "filename stem must be a numeric epoch-ms")

        // Re-decode round-trips equal to the original report.
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(LatencySessionReport.self, from: data)
        XCTAssertEqual(decoded, report, "persisted JSON must round-trip equal")
    }

    // MARK: - testEmptyTracerProducesValidZeroCountJSON

    func testEmptyTracerProducesValidZeroCountJSON() throws {
        let tracer = PilotLatencyTracer(capacity: 64, enabled: false)
        let report = sink.report(from: tracer)

        // Every channel reports zero count with zeroed percentiles.
        XCTAssertEqual(report.channels.count, 6)
        for (name, stat) in report.channels {
            XCTAssertEqual(stat.count, 0, "\(name) must be zero-count for empty tracer")
            XCTAssertEqual(stat.p50Ms, 0)
            XCTAssertEqual(stat.p95Ms, 0)
            XCTAssertEqual(stat.maxAbsMs, 0)
        }

        // Still produces valid, decodable JSON.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try sink.persist(report, into: dir)
        let decoded = try JSONDecoder().decode(
            LatencySessionReport.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded, report)
    }
}
