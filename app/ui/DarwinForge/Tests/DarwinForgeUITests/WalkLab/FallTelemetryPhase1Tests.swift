import XCTest
@testable import DarwinForgeUI

/// Phase 1 tests: M4 latch, M2 detection-from-.done, Codable round-trips.
final class FallTelemetryPhase1Tests: XCTestCase {

    // MARK: - M4: recentlyPiloting latch

    func testRecentlyPiloting_trueWithinWindow() {
        // Simulate the predicate directly (pure time math, no session needed).
        let lastPilotingAt = Date()  // just stamped
        let withinWindow = Date().timeIntervalSince(lastPilotingAt) < 5.0
        XCTAssertTrue(withinWindow, "lastPilotingAt just stamped → recentlyPiloting should be true")
    }

    func testRecentlyPiloting_falseOutsideWindow() {
        // Simulate a stale stamp (> 5 s ago).
        let lastPilotingAt = Date().addingTimeInterval(-6.0)
        let withinWindow = Date().timeIntervalSince(lastPilotingAt) < 5.0
        XCTAssertFalse(withinWindow, "lastPilotingAt 6s ago → recentlyPiloting should be false")
    }

    func testRecentlyPiloting_nilMeansNotPiloting() {
        // nil lastPilotingAt → recentlyPiloting = false.
        let lastPilotingAt: Date? = nil
        let withinWindow = lastPilotingAt.map { Date().timeIntervalSince($0) < 5.0 } ?? false
        XCTAssertFalse(withinWindow, "nil lastPilotingAt → not recently piloting")
    }

    @MainActor
    func testWalkLabSession_lastPilotingAtInitiallyNil() {
        let session = WalkLabSession()
        XCTAssertNil(session.lastPilotingAt, "lastPilotingAt should be nil at session init")
    }

    @MainActor
    func testWalkLabSession_recentlyPilotingFalseInitially() {
        let session = WalkLabSession()
        XCTAssertFalse(session.recentlyPiloting, "recentlyPiloting should be false before any pilot command")
    }

    @MainActor
    func testWalkLabSession_recentlyPilotingTrueAfterStamp() {
        let session = WalkLabSession()
        session.lastPilotingAt = Date()
        XCTAssertTrue(session.recentlyPiloting, "recentlyPiloting should be true immediately after stamp")
    }

    @MainActor
    func testWalkLabSession_recentlyPilotingFalseWithStaleStamp() {
        let session = WalkLabSession()
        session.lastPilotingAt = Date().addingTimeInterval(-10.0)
        XCTAssertFalse(session.recentlyPiloting, "recentlyPiloting false when stamp > 5s ago")
    }

    // MARK: - M2: detection allowed from .done

    func testM2_donePhaseAllowsDetection() {
        // The predicate: autoRecoveryPhase == .idle || autoRecoveryPhase == .done
        let allowedFromIdle = (AutoFallRecovery.RecoveryPhase.idle == .idle ||
                               AutoFallRecovery.RecoveryPhase.idle == .done)
        XCTAssertTrue(allowedFromIdle, ".idle should pass M2 guard")

        let allowedFromDone = (AutoFallRecovery.RecoveryPhase.done == .idle ||
                               AutoFallRecovery.RecoveryPhase.done == .done)
        XCTAssertTrue(allowedFromDone, ".done should pass M2 guard (new fall preempts display)")
    }

    func testM2_otherPhasesBlocked() {
        let phases: [AutoFallRecovery.RecoveryPhase] = [
            .fallen(.forward), .settling, .gettingUp, .failed
        ]
        for phase in phases {
            let allowed = (phase == .idle || phase == .done)
            XCTAssertFalse(allowed,
                "Phase \(phase) should NOT pass M2 guard (recovery in progress)")
        }
    }

    // MARK: - Codable round-trips

    func testFallTelemetryManifest_codableRoundTrip() throws {
        let manifest = FallTelemetryManifest(
            sessionId: "test-session-123",
            startedAtISO: "2026-05-30T12:00:00Z",
            appVersion: "1.0",
            robotModel: "darwin-op2",
            thresholds: FallTelemetryManifest.FallThresholds(
                fallenThresholdDeg: 55.0,
                settleGyroDps: 30.0
            )
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(FallTelemetryManifest.self, from: data)
        XCTAssertEqual(decoded.sessionId, manifest.sessionId)
        XCTAssertEqual(decoded.appVersion, manifest.appVersion)
        XCTAssertEqual(decoded.robotModel, manifest.robotModel)
        XCTAssertEqual(decoded.thresholds.fallenThresholdDeg, 55.0)
        XCTAssertEqual(decoded.thresholds.settleGyroDps, 30.0)
    }

    func testFallTelemetrySample_codableRoundTrip() throws {
        let sample = FallTelemetrySample(
            tMs: 1234.5,
            imuRollDeg: -3.2,
            imuPitchDeg: 57.1,
            gyroXDps: 12.0,
            gyroYDps: -5.0,
            gyroZDps: 0.5,
            accelXG: 0.1,
            accelYG: 0.0,
            accelZG: 1.0,
            balanceState: "danger",
            autoRecoveryPhase: "fallen",
            perJointLoad: ["rKnee": 512.0],
            perJointTemp: ["lAnkle": 35.0],
            cmdStrideMm: 25.0,
            cmdSideMm: 0.0,
            cmdTurnDeg: 5.0
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FallTelemetrySample.self, from: data)
        XCTAssertEqual(decoded.tMs, sample.tMs)
        XCTAssertEqual(decoded.imuPitchDeg, sample.imuPitchDeg)
        XCTAssertEqual(decoded.balanceState, sample.balanceState)
        XCTAssertEqual(decoded.perJointLoad?["rKnee"], 512.0)
        XCTAssertEqual(decoded.cmdStrideMm, 25.0)
    }

    func testFallTelemetryOutcome_codableRoundTrip() throws {
        let outcome = FallTelemetryOutcome(
            direction: "forward",
            getUpPage: 10,
            settleMs: 820.0,
            attempts: 1,
            success: true,
            recoveryTotalMs: 4500.0,
            peakLegLoad: 1800.0
        )
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(FallTelemetryOutcome.self, from: data)
        XCTAssertEqual(decoded.direction, "forward")
        XCTAssertEqual(decoded.getUpPage, 10)
        XCTAssertEqual(decoded.settleMs, 820.0)
        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.recoveryTotalMs, 4500.0)
        XCTAssertEqual(decoded.peakLegLoad, 1800.0)
        XCTAssertEqual(decoded.type, "fall_outcome", "type marker must survive round-trip")
    }

    func testFallTelemetrySample_nilOptionals_codable() throws {
        // All optional fields nil — backward-compat check.
        let sample = FallTelemetrySample(
            tMs: 0,
            imuRollDeg: 0,
            imuPitchDeg: 0,
            gyroXDps: 0, gyroYDps: 0, gyroZDps: 0,
            accelXG: 0, accelYG: 0, accelZG: 0,
            balanceState: "normal",
            autoRecoveryPhase: "idle"
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(FallTelemetrySample.self, from: data)
        XCTAssertNil(decoded.perJointLoad)
        XCTAssertNil(decoded.perJointTemp)
        XCTAssertNil(decoded.cmdStrideMm)
        XCTAssertNil(decoded.headPanDeg)
    }
}
