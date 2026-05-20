import XCTest
@testable import DarwinForgeUI

final class WalkSessionLoggerTests: XCTestCase {

    func testWritesHeaderSampleEventFooter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walklab-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = WalkSessionLogger(configuration: .init(directory: dir, fileNameOverride: "test"))
        let header = WalkSessionHeaderV2(
            sessionId: "test-1",
            startTimeIso: "2026-05-17T12:00:00.000Z",
            appVersion: "1.0.0-test",
            isRealRobot: false,
            preset: "march",
            walkTuning: WalkTuningSnapshot(periodMs: 600, xStrideM: 0.02, yStrideM: 0, aTurnRad: 0),
            balanceAlgorithmMode: "off",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "robotisOriginal",
            correctorIntensityLevelAtStart: 1,
            correctionApplyMode: "simOnly",
            imuSourceAtStart: "sim"
        )
        let url = try logger.open(header: header)

        let sample = WalkSessionSampleV2(
            tMs: 50,
            wallTimeIso: "2026-05-17T12:00:00.050Z",
            tickIndex: 0,
            tickDtMs: 50,
            preset: "march",
            walkPeriodMs: 600,
            walkCycleElapsedMs: 50,
            walkPhase01: 0.08,
            imuSource: "sim",
            imuRollDeg: 0.5,
            imuPitchDeg: -1.2,
            balanceAlgorithmMode: "off",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "robotisOriginal",
            correctionAppliedToRobot: false,
            observeOnly: true,
            effectivePitchErrDeg: -1.2,
            effectiveRollErrDeg: 0.5,
            correctorDeltas: [0,0,0,0,0,0,0,0],
            appliedDeltas: [0,0,0,0,0,0,0,0],
            maxCorrectionDeg: 15,
            balanceState: "ok",
            intensityLevel: 1
        )
        logger.write(sample)

        let event = WalkSessionEventV2(
            tMs: 100,
            wallTimeIso: "2026-05-17T12:00:00.100Z",
            kind: WalkSessionEventKind.observeOnlyEnabled.rawValue,
            message: "observe-only ON"
        )
        logger.write(event)
        logger.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("\"type\":\"header\""))
        XCTAssertTrue(content.contains("\"type\":\"sample\""))
        XCTAssertTrue(content.contains("\"type\":\"event\""))
        XCTAssertTrue(content.contains("\"type\":\"footer\""))
        XCTAssertEqual(logger.totalSamples, 1)
        XCTAssertEqual(logger.totalEvents, 1)
    }

    func testRoundTripDecodeMatchesLogger() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walklab-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let logger = WalkSessionLogger(configuration: .init(directory: dir, fileNameOverride: "round"))
        let header = WalkSessionHeaderV2(
            sessionId: "rt-1",
            startTimeIso: "2026-05-17T12:00:00.000Z",
            appVersion: "1.0.0-test",
            isRealRobot: true,
            supportMode: "floor",
            preset: "march",
            walkTuning: WalkTuningSnapshot(periodMs: 600, xStrideM: 0.02, yStrideM: 0, aTurnRad: 0),
            balanceAlgorithmMode: "robotisPControl",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "robotisOriginal",
            correctorIntensityLevelAtStart: 2,
            correctionApplyMode: "robotApplied",
            imuSourceAtStart: "real"
        )
        let url = try logger.open(header: header)
        for i in 0..<10 {
            let s = WalkSessionSampleV2(
                tMs: Double(i) * 50,
                wallTimeIso: "2026-05-17T12:00:00.000Z",
                tickIndex: i,
                tickDtMs: 50,
                preset: "march",
                walkPeriodMs: 600,
                walkCycleElapsedMs: Double(i) * 50,
                walkPhase01: Double(i) / 10,
                imuSource: "real",
                imuRollDeg: Double(i) * 0.1,
                imuPitchDeg: -10 + Double(i) * 0.3,
                balanceAlgorithmMode: "robotisPControl",
                balanceSignConvention: "robotisWalkingCpp",
                balanceGainProfile: "robotisOriginal",
                correctionAppliedToRobot: true,
                observeOnly: false,
                effectivePitchErrDeg: -10 + Double(i) * 0.3,
                effectiveRollErrDeg: Double(i) * 0.1,
                correctorDeltas: [0,0,-0.1,0.1,-0.3,0.3,0,0],
                appliedDeltas: [0,0,-0.1,0.1,-0.3,0.3,0,0],
                maxCorrectionDeg: 15,
                balanceState: "ok",
                intensityLevel: 2
            )
            logger.write(s)
        }
        logger.close()

        let decoded = try WalkSessionDecoder.decode(file: url)
        XCTAssertEqual(decoded.schemaVersion, .v2)
        XCTAssertEqual(decoded.samples.count, 10)
        XCTAssertEqual(decoded.header.balanceAlgorithmMode, "robotisPControl")
        XCTAssertNotNil(decoded.footer)
    }
}
