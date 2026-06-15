import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.25 (2026-05-21) — 로봇 측 데이터 sparse logging 회귀 가드**.
///
/// 검증 대상: `docs/diagnosis/WALKLAB_REAL_ROBOT_MOTION_FAILURE_AUDIT_2026-05-20.md`
/// 후속 audit P0 robot-A / B / C / E / F.
///
/// 핵심 invariant:
/// - `WalkSessionSample` 의 새 7 필드 (jointStates, rawGyro/Accel XYZ, jointFailuresDelta,
///   busRttMs, boardButton) 가 모두 Optional + decodeIfPresent (backward-compat).
/// - `JointStateSnapshot` 의 약어 키 (g/a/sp/l/t/v/te) 가 JSON round-trip.
/// - 기존 jsonl (새 필드 없음) 도 decode 성공.
@MainActor
final class WalkLabV1125RobotDataTests: XCTestCase {

    // MARK: - JointStateSnapshot Codable round-trip

    func testJointStateSnapshotCodableRoundTrip() throws {
        let snap = JointStateSnapshot(
            g: 2048, a: 2050, sp: 100, l: 512, t: 42, v: 116, te: true
        )
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(JointStateSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
        XCTAssertEqual(decoded.trackingErrorRawSteps, 2)
    }

    /// JSON 키가 약어 (g/a/sp/l/t/v/te) — 디스크 size 최소화 검증.
    func testJointStateSnapshotJsonUsesAbbreviatedKeys() throws {
        let snap = JointStateSnapshot(g: 100, a: 200, sp: 50, l: 75, t: 30, v: 120, te: false)
        let data = try JSONEncoder().encode(snap)
        let json = String(data: data, encoding: .utf8)!
        // 약어 키만 등장해야 함 (presentPosition 등 긴 이름 X).
        XCTAssertTrue(json.contains("\"g\":100"))
        XCTAssertTrue(json.contains("\"a\":200"))
        XCTAssertTrue(json.contains("\"sp\":50"))
        XCTAssertTrue(json.contains("\"l\":75"))
        XCTAssertTrue(json.contains("\"t\":30"))
        XCTAssertTrue(json.contains("\"v\":120"))
        XCTAssertTrue(json.contains("\"te\":false"))
        XCTAssertFalse(json.contains("presentPosition"))
        XCTAssertFalse(json.contains("goalPosition"))
    }

    // MARK: - WalkSessionSample new fields backward-compat

    /// **신규 7 필드 round-trip**.
    func testWalkSessionSampleNewRobotFieldsRoundTrip() throws {
        let sample = WalkSessionSample(
            t: 100, preset: "march", intensityLevel: 1,
            imuRollDeg: 1.0, imuPitchDeg: -2.0,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "real", batteryVolts: 11.9, motorAvgTemp: 45.0,
            // robot-side new fields
            jointStates: [
                "rHipRoll": JointStateSnapshot(g: 2048, a: 2050, sp: 0, l: 100, t: 42, v: 119, te: true),
                "lHipRoll": JointStateSnapshot(g: 2048, a: 2047, sp: 0, l: 95, t: 41, v: 119, te: true)
            ],
            rawGyroXDps: 5.2, rawGyroYDps: -1.3, rawGyroZDps: 0.1,
            rawAccelXG: 0.02, rawAccelYG: 0.01, rawAccelZG: 0.98,
            jointFailuresDelta: ["rKnee": 3],
            busRttMs: 14.2,
            boardButton: 0x01
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: data)
        XCTAssertEqual(decoded.jointStates?["rHipRoll"]?.a, 2050)
        XCTAssertEqual(decoded.jointStates?["lHipRoll"]?.te, true)
        XCTAssertEqual(decoded.rawGyroXDps, 5.2)
        XCTAssertEqual(decoded.rawAccelZG, 0.98)
        XCTAssertEqual(decoded.jointFailuresDelta?["rKnee"], 3)
        XCTAssertEqual(decoded.busRttMs, 14.2)
        XCTAssertEqual(decoded.boardButton, 0x01)
    }

    /// **이전 jsonl (새 필드 없음) 도 decode 성공** (Optional + decodeIfPresent).
    func testWalkSessionSampleOldJsonStillDecodes() throws {
        let oldJson = """
        {
          "t": 100, "preset": "march", "intensityLevel": 1,
          "imuRollDeg": 1.0, "imuPitchDeg": -2.0,
          "correctorRollErrDeg": 0, "correctorPitchErrDeg": 0,
          "balanceState": "normal",
          "correctorDeltas": [0,0,0,0,0,0,0,0],
          "imuSource": "real"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: oldJson)
        XCTAssertEqual(decoded.preset, "march")
        // 새 필드 모두 nil 이어야 함.
        XCTAssertNil(decoded.jointStates)
        XCTAssertNil(decoded.rawGyroXDps)
        XCTAssertNil(decoded.rawGyroYDps)
        XCTAssertNil(decoded.rawGyroZDps)
        XCTAssertNil(decoded.rawAccelXG)
        XCTAssertNil(decoded.rawAccelYG)
        XCTAssertNil(decoded.rawAccelZG)
        XCTAssertNil(decoded.jointFailuresDelta)
        XCTAssertNil(decoded.busRttMs)
        XCTAssertNil(decoded.boardButton)
    }

    /// **partial 필드만 있는 jsonl** — 일부만 채워졌어도 decode 성공.
    func testWalkSessionSamplePartialRobotFieldsDecodes() throws {
        let partial = """
        {
          "t": 50, "preset": "slowWalk", "intensityLevel": 2,
          "imuRollDeg": 0.5, "imuPitchDeg": -1.0,
          "correctorRollErrDeg": 0, "correctorPitchErrDeg": 0,
          "balanceState": "normal",
          "correctorDeltas": [0,0,0,0,0,0,0,0],
          "imuSource": "real",
          "rawGyroXDps": 2.0,
          "rawAccelZG": 0.99
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: partial)
        XCTAssertEqual(decoded.rawGyroXDps, 2.0)
        XCTAssertEqual(decoded.rawAccelZG, 0.99)
        XCTAssertNil(decoded.rawGyroYDps, "missing 필드 → nil")
        XCTAssertNil(decoded.jointStates)
    }

    // MARK: - Tracking error helper

    func testTrackingErrorRawStepsPositive() {
        let snap = JointStateSnapshot(g: 2000, a: 2050, sp: 0, l: 0, t: 0, v: 0, te: true)
        XCTAssertEqual(snap.trackingErrorRawSteps, 50, "actual - goal = 50")
    }

    func testTrackingErrorRawStepsNegative() {
        let snap = JointStateSnapshot(g: 2050, a: 2000, sp: 0, l: 0, t: 0, v: 0, te: true)
        XCTAssertEqual(snap.trackingErrorRawSteps, -50)
    }

    func testTrackingErrorRawStepsZero() {
        let snap = JointStateSnapshot(g: 2048, a: 2048, sp: 0, l: 0, t: 0, v: 0, te: true)
        XCTAssertEqual(snap.trackingErrorRawSteps, 0)
    }

    // MARK: - v1.11.25 audit P0 robot-D — FSR

    /// **FsrSampleSnapshot Codable round-trip** (약어 키 fl/fr/rr/rl/x/y).
    func testFsrSampleSnapshotRoundTrip() throws {
        let snap = FsrSampleSnapshot(fl: 100, fr: 200, rr: 300, rl: 400, x: -42, y: 31)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(FsrSampleSnapshot.self, from: data)
        XCTAssertEqual(decoded, snap)
        XCTAssertEqual(decoded.totalPressure, 1000)
    }

    /// **JSON 약어 키 검증** — 디스크 size 절약.
    func testFsrSampleSnapshotJsonUsesAbbreviatedKeys() throws {
        let snap = FsrSampleSnapshot(fl: 100, fr: 200, rr: 300, rl: 400, x: 10, y: -5)
        let data = try JSONEncoder().encode(snap)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"fl\":100"))
        XCTAssertTrue(json.contains("\"fr\":200"))
        XCTAssertTrue(json.contains("\"rr\":300"))
        XCTAssertTrue(json.contains("\"rl\":400"))
        XCTAssertTrue(json.contains("\"x\":10"))
        XCTAssertTrue(json.contains("\"y\":-5"))
        XCTAssertFalse(json.contains("cellFrontLeft"))
        XCTAssertFalse(json.contains("centerX"))
    }

    /// **WalkSessionSample 에 fsr 필드 포함 round-trip**.
    func testWalkSessionSampleWithFsrRoundTrip() throws {
        let sample = WalkSessionSample(
            t: 100, preset: "march", intensityLevel: 1,
            imuRollDeg: 0, imuPitchDeg: 0,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "real", batteryVolts: nil, motorAvgTemp: nil,
            fsrLeft: FsrSampleSnapshot(fl: 110, fr: 120, rr: 130, rl: 140, x: 5, y: -3),
            fsrRight: FsrSampleSnapshot(fl: 200, fr: 210, rr: 220, rl: 230, x: -8, y: 4)
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: data)
        XCTAssertEqual(decoded.fsrLeft?.fl, 110)
        XCTAssertEqual(decoded.fsrLeft?.totalPressure, 500)
        XCTAssertEqual(decoded.fsrRight?.x, -8)
    }

    /// **FsrReading (Swift wrapper) 의 totalPressureRaw 계산**.
    func testFsrReadingTotalPressure() {
        let r = FsrReading(id: 111, cellFrontLeft: 100, cellFrontRight: 200,
                           cellRearRight: 300, cellRearLeft: 400, centerX: 0, centerY: 0)
        XCTAssertEqual(r.totalPressureRaw, 1000)
    }
}
