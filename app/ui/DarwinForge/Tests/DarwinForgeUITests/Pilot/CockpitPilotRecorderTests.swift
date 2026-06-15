import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **실 robot 테스트 데이터 recorder 검증**.
///
/// 스키마 round-trip (Codable) + summary 순수 계산 정확성 + 실제 디스크 JSONL
/// 영속화/재로딩 (임시 디렉토리 주입). 추후 개선 분석이 이 데이터에 의존하므로
/// 스키마/집계의 정확성이 핵심.
final class CockpitPilotRecorderTests: XCTestCase {

    // MARK: - Schema round-trip

    func test_manifest_codable_roundtrip() throws {
        let m = CockpitPilotManifest(
            sessionId: "cockpit-test", startedAtISO: "2026-05-29T00:00:00Z",
            appVersion: "1.24.0", realMotor: true, robotConnected: true,
            dxlPowerOn: true, controllerName: "DJI", balanceCorrectionAtStart: false)
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(CockpitPilotManifest.self, from: data)
        XCTAssertEqual(decoded, m)
        XCTAssertEqual(decoded.schemaVersion, CockpitPilotManifest.currentSchemaVersion)
    }

    func test_dispatch_codable_roundtrip() throws {
        let d = CockpitPilotDispatch(
            tMs: 1234, source: "djiRC",
            cmdStrideMm: 38, cmdSideMm: 0, cmdTurnDeg: 0, periodMs: 600,
            effStrideMm: 38, effSideMm: 0, effTurnDeg: 0,
            robotSpeedMmPerSec: 126.67, imuRollDeg: 1.2, imuPitchDeg: -0.5,
            balanceOn: true, accepted: true, gateReason: nil)
        let data = try JSONEncoder().encode(d)
        let decoded = try JSONDecoder().decode(CockpitPilotDispatch.self, from: data)
        XCTAssertEqual(decoded, d)
    }

    func test_event_codable_roundtrip() throws {
        let e = CockpitPilotEvent(tMs: 500, kind: .eStop, detail: "user")
        let data = try JSONEncoder().encode(e)
        let decoded = try JSONDecoder().decode(CockpitPilotEvent.self, from: data)
        XCTAssertEqual(decoded, e)
    }

    // MARK: - Summary 순수 계산

    private func dispatch(tMs: Double, speed: Double, accepted: Bool = true,
                          balanceOn: Bool = false, roll: Double = 0,
                          gate: String? = nil) -> CockpitPilotDispatch {
        CockpitPilotDispatch(
            tMs: tMs, source: "keyboard",
            cmdStrideMm: 38, cmdSideMm: 0, cmdTurnDeg: 0, periodMs: 600,
            effStrideMm: 38, effSideMm: 0, effTurnDeg: 0,
            robotSpeedMmPerSec: speed, imuRollDeg: roll, imuPitchDeg: 0,
            balanceOn: balanceOn, accepted: accepted, gateReason: gate)
    }

    func test_summary_peak_and_mean_speed() {
        let dispatches = [
            dispatch(tMs: 0, speed: 50),
            dispatch(tMs: 100, speed: 126.67),
            dispatch(tMs: 200, speed: 80),
        ]
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: dispatches, events: [], endTMs: 300)
        XCTAssertEqual(s.peakSpeedMmPerSec, 126.67, accuracy: 0.01, "최대 속도")
        XCTAssertEqual(s.meanSpeedMmPerSec, (50 + 126.67 + 80) / 3, accuracy: 0.01)
        XCTAssertEqual(s.dispatchCount, 3)
        XCTAssertEqual(s.acceptedCount, 3)
    }

    func test_summary_commanded_distance_trapezoidal() {
        // 0ms@0, 1000ms@100mm/s, 2000ms@100mm/s.
        // 사다리꼴: (0+100)/2×1 + (100+100)/2×1 = 50 + 100 = 150 mm.
        let dispatches = [
            dispatch(tMs: 0, speed: 0),
            dispatch(tMs: 1000, speed: 100),
            dispatch(tMs: 2000, speed: 100),
        ]
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: dispatches, events: [], endTMs: 2000)
        XCTAssertEqual(s.commandedDistanceMm, 150, accuracy: 0.5,
                       "사다리꼴 적분 거리")
    }

    func test_summary_rejected_not_counted_in_distance() {
        // 거부된 dispatch 는 거리/속도 집계 제외.
        let dispatches = [
            dispatch(tMs: 0, speed: 0, accepted: true),
            dispatch(tMs: 1000, speed: 999, accepted: false, gate: "로봇 미연결"),
        ]
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: dispatches, events: [], endTMs: 1000)
        XCTAssertEqual(s.acceptedCount, 1)
        XCTAssertEqual(s.rejectedCount, 1)
        XCTAssertEqual(s.peakSpeedMmPerSec, 0, "거부 dispatch 의 999 는 peak 제외")
        XCTAssertEqual(s.gateReasonHistogram["로봇 미연결"], 1)
    }

    func test_summary_balance_duty_percent() {
        let dispatches = [
            dispatch(tMs: 0, speed: 50, balanceOn: true),
            dispatch(tMs: 100, speed: 50, balanceOn: true),
            dispatch(tMs: 200, speed: 50, balanceOn: false),
            dispatch(tMs: 300, speed: 50, balanceOn: false),
        ]
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: dispatches, events: [], endTMs: 400)
        XCTAssertEqual(s.balanceDutyPercent, 50, accuracy: 0.01,
                       "보정 ON 2/4 = 50%")
    }

    func test_summary_peak_tilt_from_imu() {
        let dispatches = [
            dispatch(tMs: 0, speed: 50, roll: 3.0),
            dispatch(tMs: 100, speed: 50, roll: -12.5),
            dispatch(tMs: 200, speed: 50, roll: 8.0),
        ]
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: dispatches, events: [], endTMs: 300)
        XCTAssertEqual(s.peakAbsRollDeg, 12.5, accuracy: 0.01,
                       "최대 |roll| = 12.5 (안정성 지표)")
    }

    func test_summary_event_counts() {
        let events = [
            CockpitPilotEvent(tMs: 10, kind: .autoArm),
            CockpitPilotEvent(tMs: 20, kind: .eStop),
            CockpitPilotEvent(tMs: 30, kind: .recover),
            CockpitPilotEvent(tMs: 40, kind: .eStop),
            CockpitPilotEvent(tMs: 50, kind: .maxDuration),
        ]
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: [], events: events, endTMs: 60)
        XCTAssertEqual(s.eStopCount, 2)
        XCTAssertEqual(s.autoArmCount, 1)
        XCTAssertEqual(s.maxDurationCount, 1)
    }

    func test_summary_empty_session_safe() {
        let s = CockpitPilotSummary.compute(
            sessionId: "t", dispatches: [], events: [], endTMs: 0)
        XCTAssertEqual(s.dispatchCount, 0)
        XCTAssertEqual(s.peakSpeedMmPerSec, 0)
        XCTAssertEqual(s.meanSpeedMmPerSec, 0)
        XCTAssertEqual(s.commandedDistanceMm, 0)
        XCTAssertEqual(s.balanceDutyPercent, 0)
    }

    // MARK: - Recorder 디스크 영속화 (임시 디렉토리)

    @MainActor
    func test_recorder_writes_jsonl_and_summary() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-rec-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifest = CockpitPilotManifest(
            sessionId: "sess1", startedAtISO: "2026-05-29T00:00:00Z",
            appVersion: "1.24.0", realMotor: true, robotConnected: true,
            dxlPowerOn: true, controllerName: "DJI", balanceCorrectionAtStart: true)
        let rec = CockpitPilotRecorder(manifest: manifest, rootOverride: tmp)

        rec.logEvent(.sessionStart)
        rec.logDispatch(
            source: "djiRC", cmdStrideMm: 38, cmdSideMm: 0, cmdTurnDeg: 0,
            periodMs: 600, effStrideMm: 38, effSideMm: 0, effTurnDeg: 0,
            robotSpeedMmPerSec: 126.67, imuRollDeg: 1.0, imuPitchDeg: 0,
            balanceOn: true, accepted: true, gateReason: nil)
        rec.logEvent(.eStop)
        XCTAssertEqual(rec.dispatchCount, 1)
        XCTAssertEqual(rec.eventCount, 2)

        let summary = rec.finalize()
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.dispatchCount, 1)
        XCTAssertEqual(summary?.eStopCount, 1)

        // 파일이 실제로 디스크에 쓰였는지 확인.
        let dir = tmp.appendingPathComponent("sess1")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path),
                      "manifest.json 존재")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("dispatches.jsonl").path),
                      "dispatches.jsonl 존재")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("events.jsonl").path),
                      "events.jsonl 존재")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("summary.json").path),
                      "summary.json 존재")

        // dispatches.jsonl 의 1줄을 재파싱 — round-trip 무결성.
        let dispatchData = try Data(contentsOf: dir.appendingPathComponent("dispatches.jsonl"))
        let line = String(decoding: dispatchData, as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? ""
        let parsed = try JSONDecoder().decode(
            CockpitPilotDispatch.self, from: Data(line.utf8))
        XCTAssertEqual(parsed.source, "djiRC")
        XCTAssertEqual(parsed.effStrideMm, 38, accuracy: 0.01)
        XCTAssertEqual(parsed.robotSpeedMmPerSec, 126.67, accuracy: 0.01)
    }

    @MainActor
    func test_recorder_finalize_idempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-rec-idem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let manifest = CockpitPilotManifest(
            sessionId: "s", startedAtISO: "x", appVersion: "1.0",
            realMotor: false, robotConnected: false, dxlPowerOn: false,
            controllerName: nil, balanceCorrectionAtStart: false)
        let rec = CockpitPilotRecorder(manifest: manifest, rootOverride: tmp)
        XCTAssertNotNil(rec.finalize(), "첫 finalize → summary 반환")
        XCTAssertNil(rec.finalize(), "두 번째 finalize → nil (idempotent)")
        // finalize 후 append 는 무시 (guard).
        rec.logEvent(.eStop)
        XCTAssertEqual(rec.eventCount, 0, "finalize 후 append 무시")
    }
}
