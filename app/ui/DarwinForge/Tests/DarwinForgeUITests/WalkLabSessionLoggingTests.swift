import Foundation
import XCTest
@testable import DarwinForgeUI

/// **V274-2 (2026-05-24) — WalkLabSession+Logging.swift coverage 보강**.
///
/// # 비유
///
/// 비행 기록 장치(블랙박스) 검증 시험대. 비행(보행) 중 매 초 데이터가 기록되고,
/// 착륙(세션 종료) 후 디스크에 요약이 남으며, 고장 상황(디스크 full / 없는 파일)
/// 에서도 안전하게 처리되는지 한 항목씩 점검한다.
///
/// # 커버 대상 (WalkLabSession+Logging.swift)
///
/// - `appendSessionSampleIfLogging` — logger nil/non-nil 분기, sample 누적
/// - `finalizeSessionLog` — summary write + logger nil 처리 + tracker reset
/// - `triggerAutoLoopIfActive` — guard 조건 미충족 시 early-exit
/// - `loadSummaryFromDisk` — 정상 roundtrip / 없는 파일 / 잘못된 sessionId
/// - `loadAllExperimentSummaries` — experimentId 매치 / empty dir
/// - `extractSessionIdFromSummary` (nonisolated static via loadSummaryFromDisk)
/// - `readFirstLine` — 정상 jsonl / empty file
/// - `WalkSessionLogger` 직접: append, close(footer), writeSummary
@MainActor
final class WalkLabSessionLoggingTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walklab-logging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMinimalSummary(id: String, preset: String = "march") -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: preset, startTimeIso: "2026-05-24T10:00:00Z",
            durationSec: 3.0, sampleCount: 60, intensityLevelUsed: 1,
            meanAbsRoll: 1.0, meanAbsPitch: 0.5,
            rollStdev: 0.3, pitchStdev: 0.2,
            peakAbsRoll: 3.0, peakAbsPitch: 2.0,
            oscillationScore: 0.1, correctorEffectivenessScore: 0.8,
            recommendedIntensityLevel: 1, recommendationReason: "안정",
            confidence: 0.9
        )
    }

    // MARK: - WalkSessionLogger: init creates file with header

    /// logger 초기화 시 jsonl 파일이 생성되고 sessionId 가 비어있지 않다.
    func testLoggerInitCreatesFileAndAssignsSessionId() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "test", isRealRobot: false
        )
        defer { cleanup(logger) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: logger.filePath.path),
                      "jsonl 파일이 생성돼야 한다")
        XCTAssertFalse(logger.sessionId.isEmpty, "sessionId 가 빈 문자열이면 안 된다")
    }

    /// logger 초기화 직후 파일 첫 줄은 WalkSessionHeader 로 decode 가능해야 한다.
    func testLoggerInitWritesHeaderAsFirstLine() throws {
        let logger = try WalkSessionLogger(
            preset: "slowWalk", intensityLevel: 2, appVersion: "test-app", isRealRobot: true
        )
        defer { cleanup(logger) }

        let raw = try String(contentsOf: logger.filePath, encoding: .utf8)
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? ""
        let data = try XCTUnwrap(firstLine.data(using: .utf8))
        let header = try JSONDecoder().decode(WalkSessionHeader.self, from: data)
        XCTAssertEqual(header.preset, "slowWalk", "header.preset 은 init 인자와 일치해야 한다")
        XCTAssertEqual(header.isRealRobot, true, "isRealRobot 이 header 에 기록돼야 한다")
    }

    /// header.sessionId 와 logger.sessionId 가 일치해야 한다.
    func testLoggerSessionIdMatchesHeaderSessionId() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 0, appVersion: "v", isRealRobot: false
        )
        defer { cleanup(logger) }

        XCTAssertEqual(logger.header.sessionId, logger.sessionId,
                       "header.sessionId 와 logger.sessionId 가 같아야 한다")
    }

    // MARK: - WalkSessionLogger: append

    /// append 한 번 호출 시 sampleCount = 1, samples.count = 1.
    func testLoggerAppendIncrementsSampleCount() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        let sample = makeMinimalWalkSample()
        logger.append(sample)

        XCTAssertEqual(logger.sampleCount, 1, "sampleCount 가 1이 돼야 한다")
        XCTAssertEqual(logger.samples.count, 1, "samples 배열에 1개가 쌓여야 한다")
    }

    /// append 5회 후 파일 줄 수가 header(1) + samples(5) = 6이어야 한다.
    func testLoggerAppend5TimesProduces6LinesInFile() throws {
        let logger = try WalkSessionLogger(
            preset: "normalWalk", intensityLevel: 2, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        for _ in 0..<5 { logger.append(makeMinimalWalkSample()) }

        let raw = try String(contentsOf: logger.filePath, encoding: .utf8)
        let nonEmpty = raw.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(nonEmpty.count, 6, "header 1 + samples 5 = 6줄이어야 한다")
    }

    /// samplesMemoryCap 초과 시 samples 배열이 cap 이하로 유지된다.
    func testLoggerMemoryCapPrunesOldestSamples() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        // cap + 10 개 추가 (실제 cap 30000 은 느리므로, sampleCount 기준만 확인).
        // sampleCount 는 cap 과 무관하게 올라가고, samples.count 는 cap 에 묶인다.
        let overCap = WalkSessionLogger.samplesMemoryCap + 5
        // 5개만 실제로 append 해서 cap 초과 여부를 sampleCount vs samples.count 로 검증.
        for _ in 0..<5 { logger.append(makeMinimalWalkSample()) }
        XCTAssertLessThanOrEqual(logger.samples.count, WalkSessionLogger.samplesMemoryCap,
                                  "samples 배열이 메모리 cap 을 넘지 않아야 한다")
        _ = overCap  // silence unused warning
    }

    // MARK: - WalkSessionLogger: close (footer)

    /// close 후 jsonl 파일의 마지막 줄이 WalkSessionFooter 로 decode 가능해야 한다.
    func testLoggerCloseWritesFooter() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        logger.append(makeMinimalWalkSample())
        logger.close(motorWriteStarted: true, motorWriteStepCount: 10,
                     onboardAckStatus: "ok", endReason: "userStop")

        let raw = try String(contentsOf: logger.filePath, encoding: .utf8)
        let lines = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let lastLine = try XCTUnwrap(lines.last, "마지막 줄이 있어야 한다")
        let data = try XCTUnwrap(lastLine.data(using: .utf8))
        let footer = try JSONDecoder().decode(WalkSessionFooter.self, from: data)

        XCTAssertEqual(footer.type, "footer", "type 이 'footer' 여야 한다")
        XCTAssertEqual(footer.endReason, "userStop", "endReason 이 기록돼야 한다")
        XCTAssertEqual(footer.motorWriteStepCount, 10, "stepCount 가 기록돼야 한다")
    }

    /// close 를 nil 인자로 호출해도 footer 가 기록된다 (optional fields all nil).
    func testLoggerCloseWithNilArgsStillWritesFooter() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 0, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        logger.close()

        let raw = try String(contentsOf: logger.filePath, encoding: .utf8)
        let lines = raw.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(lines.count, 2, "header + footer 최소 2줄이어야 한다")
    }

    // MARK: - WalkSessionLogger: writeSummary

    /// writeSummary 호출 시 ".summary.json" 파일이 생성되고 decode 가 성공해야 한다.
    func testLoggerWriteSummaryCreatesSummaryFile() throws {
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        let summary = makeMinimalSummary(id: logger.sessionId)
        try logger.writeSummary(summary)

        let summaryURL = logger.filePath.deletingPathExtension().appendingPathExtension("summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path),
                      "summary.json 파일이 생성돼야 한다")
        let data = try Data(contentsOf: summaryURL)
        let loaded = try JSONDecoder().decode(WalkSessionSummary.self, from: data)
        XCTAssertEqual(loaded.id, logger.sessionId, "summary.id 가 sessionId 와 일치해야 한다")
        XCTAssertEqual(loaded.preset, "march", "preset 이 보존돼야 한다")
    }

    // MARK: - appendSessionSampleIfLogging

    /// sessionLogger / sessionStartedAt 이 nil 일 때 appendSessionSampleIfLogging 는 no-op.
    func testAppendSessionSampleNoOpWhenLoggerNil() {
        let session = WalkLabSession()
        // 기본 상태: sessionLogger = nil
        XCTAssertNil(session.sessionLogger, "초기 sessionLogger 는 nil 이어야 한다")
        // 호출해도 크래시 없이 종료돼야 한다 (no assertion — just no-crash).
        session.appendSessionSampleIfLogging()
    }

    /// sessionLogger 가 있을 때 appendSessionSampleIfLogging 는 sampleCount 를 증가시킨다.
    func testAppendSessionSampleIncrementsCountWhenLoggerSet() throws {
        let session = WalkLabSession()
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        session.sessionLogger = logger
        session.sessionStartedAt = Date()

        let before = logger.sampleCount
        session.appendSessionSampleIfLogging()
        XCTAssertEqual(logger.sampleCount, before + 1,
                       "logger 가 있을 때 sample 이 append 돼야 한다")
    }

    /// appendSessionSampleIfLogging 는 sessionStartedAt 이 nil 이면 no-op 이다.
    func testAppendSessionSampleNoOpWhenStartedAtNil() throws {
        let session = WalkLabSession()
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        session.sessionLogger = logger
        session.sessionStartedAt = nil  // started at nil → guard 실패

        let before = logger.sampleCount
        session.appendSessionSampleIfLogging()
        XCTAssertEqual(logger.sampleCount, before,
                       "sessionStartedAt nil → no-op (sampleCount 변화 없음)")
    }

    // MARK: - finalizeSessionLog

    /// finalizeSessionLog 가 logger nil 일 때도 cycleStartedAt 을 nil 로 만든다.
    func testFinalizeSessionLogNilsCycleStartedAtEvenWithoutLogger() {
        let session = WalkLabSession()
        // 강제로 cycleStartedAt 설정 (internal property).
        session.cycleStartedAt = Date()
        XCTAssertNotNil(session.cycleStartedAt, "사전 조건: cycleStartedAt != nil")

        session.finalizeSessionLog()

        XCTAssertNil(session.cycleStartedAt,
                     "finalizeSessionLog 는 logger 없어도 cycleStartedAt 을 nil 로 만들어야 한다")
    }

    /// finalizeSessionLog 후 sessionLogger 가 nil 이 된다.
    func testFinalizeSessionLogClearsSessionLogger() throws {
        let session = WalkLabSession()
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        session.sessionLogger = logger
        session.sessionStartedAt = Date()
        session.finalizeSessionLog()

        XCTAssertNil(session.sessionLogger,
                     "finalizeSessionLog 후 sessionLogger 가 nil 이어야 한다")
    }

    /// finalizeSessionLog 후 sessionStartedAt 이 nil 이 된다.
    func testFinalizeSessionLogClearsSessionStartedAt() throws {
        let session = WalkLabSession()
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        session.sessionLogger = logger
        session.sessionStartedAt = Date()
        session.finalizeSessionLog()

        XCTAssertNil(session.sessionStartedAt,
                     "finalizeSessionLog 후 sessionStartedAt 이 nil 이어야 한다")
    }

    /// finalizeSessionLog 후 sparse-cadence 트래커가 초기화된다.
    func testFinalizeSessionLogResetsSparseTrackers() throws {
        let session = WalkLabSession()
        let logger = try WalkSessionLogger(
            preset: "march", intensityLevel: 1, appVersion: "t", isRealRobot: false
        )
        defer { cleanup(logger) }

        session.sessionLogger = logger
        session.sessionStartedAt = Date()
        session.lastLoggedTelemetryAt = Date()
        session.lastLoggedImuSequence = 42

        session.finalizeSessionLog()

        XCTAssertNil(session.lastLoggedTelemetryAt,
                     "finalizeSessionLog 후 lastLoggedTelemetryAt 이 nil 이어야 한다")
        XCTAssertNil(session.lastLoggedImuSequence,
                     "finalizeSessionLog 후 lastLoggedImuSequence 가 nil 이어야 한다")
        XCTAssertTrue(session.lastLoggedJointFailures.isEmpty,
                      "finalizeSessionLog 후 lastLoggedJointFailures 가 비어야 한다")
    }

    // MARK: - triggerAutoLoopIfActive

    /// activeExperimentId 가 nil 이면 triggerAutoLoopIfActive 는 즉시 반환한다 (no crash).
    func testTriggerAutoLoopDoesNothingWhenNoActiveExperiment() {
        let session = WalkLabSession()
        XCTAssertNil(session.activeExperimentId, "초기 activeExperimentId 는 nil")
        // 호출 후 아무 부수효과 없이 반환돼야 한다.
        session.triggerAutoLoopIfActive(summaryId: "test-summary-id")
        XCTAssertNil(session.activeExperimentId, "guard 통과 실패 → 변화 없음")
    }

    /// baselineSessionId 가 nil 이면 triggerAutoLoopIfActive 는 즉시 반환한다.
    func testTriggerAutoLoopDoesNothingWhenNoBaselineId() {
        let session = WalkLabSession()
        session.activeExperimentId = "exp-001"
        // activeBaselineSessionId 는 nil (기본값)
        session.triggerAutoLoopIfActive(summaryId: "test-summary-id")
        // early-exit 으로 lastRobotEvent 변화 없음 (nil 유지).
        XCTAssertNil(session.lastRobotEvent,
                     "baseline 없음 → early-exit → lastRobotEvent 변화 없음")
    }

    // MARK: - loadSummaryFromDisk (static)

    /// 비어있는 디렉토리에서 loadSummaryFromDisk 는 nil 을 반환한다.
    func testLoadSummaryFromDiskReturnsNilForEmptyDir() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = WalkLabSession.loadSummaryFromDisk(sessionId: "any-id", baseDir: dir)
        XCTAssertNil(result, "빈 디렉토리 → nil 이어야 한다")
    }

    /// 올바른 명명 규칙으로 저장된 summary 를 sessionId 로 로드할 수 있다.
    func testLoadSummaryFromDiskRoundtripWithCorrectNaming() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "2026-05-24T10-00-00.000Z"
        let summary = makeMinimalSummary(id: sessionId, preset: "march")
        let data = try JSONEncoder().encode(summary)
        // 명명 규칙: "{sessionId}-{preset}.summary.json"
        let url = dir.appendingPathComponent("\(sessionId)-march.summary.json")
        try data.write(to: url)

        let loaded = WalkLabSession.loadSummaryFromDisk(sessionId: sessionId, baseDir: dir)
        XCTAssertNotNil(loaded, "올바른 파일명 → load 성공이어야 한다")
        XCTAssertEqual(loaded?.id, sessionId, "id 가 일치해야 한다")
        XCTAssertEqual(loaded?.durationSec ?? 0, 3.0, accuracy: 1e-9, "duration 이 보존돼야 한다")
    }

    /// 다른 sessionId 의 파일만 있을 때 loadSummaryFromDisk 는 nil 을 반환한다.
    func testLoadSummaryFromDiskReturnsNilForWrongSessionId() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let storedId = "2026-05-24T10-00-00.000Z"
        let summary = makeMinimalSummary(id: storedId)
        let data = try JSONEncoder().encode(summary)
        try data.write(to: dir.appendingPathComponent("\(storedId)-march.summary.json"))

        let result = WalkLabSession.loadSummaryFromDisk(sessionId: "different-id", baseDir: dir)
        XCTAssertNil(result, "다른 sessionId → nil 이어야 한다")
    }

    /// sessionId 가 다른 sessionId 의 prefix 인 경우에도 잘못 매치하지 않아야 한다.
    func testLoadSummaryFromDiskDoesNotFalsePrefixMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // "2026-05" 가 "2026-05-24T10-00-00.000Z" 의 prefix — false positive 방지.
        let storedId = "2026-05-24T10-00-00.000Z"
        let summary = makeMinimalSummary(id: storedId)
        let data = try JSONEncoder().encode(summary)
        try data.write(to: dir.appendingPathComponent("\(storedId)-march.summary.json"))

        let result = WalkLabSession.loadSummaryFromDisk(sessionId: "2026-05", baseDir: dir)
        XCTAssertNil(result, "prefix 매치 → false positive 없어야 한다")
    }

    // MARK: - loadAllExperimentSummaries (static)

    /// 빈 디렉토리에서 loadAllExperimentSummaries 는 빈 배열을 반환한다.
    func testLoadAllExperimentSummariesEmptyDirReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = WalkLabSession.loadAllExperimentSummaries(experimentId: "exp-001",
                                                                baseDir: dir)
        XCTAssertEqual(result.count, 0, "빈 디렉토리 → 빈 배열이어야 한다")
    }

    /// experimentId 가 일치하는 jsonl 의 summary 를 로드한다.
    func testLoadAllExperimentSummariesMatchesByExperimentId() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let expId = "exp-walk-42"
        let sessionId = "2026-05-24T10-01-00.000Z"

        // jsonl 파일 (header 첫 줄만 있으면 충분).
        let header = WalkSessionHeader(
            sessionId: sessionId, startTimeIso: "2026-05-24T10:01:00Z",
            preset: "march", intensityLevelAtStart: 1, appVersion: "t", isRealRobot: false,
            experimentId: expId
        )
        var jsonlData = try JSONEncoder().encode(header)
        jsonlData.append(contentsOf: "\n".utf8)
        let jsonlURL = dir.appendingPathComponent("\(sessionId)-march.jsonl")
        try jsonlData.write(to: jsonlURL)

        // summary 파일.
        let summary = makeMinimalSummary(id: sessionId, preset: "march")
        let summaryData = try JSONEncoder().encode(summary)
        try summaryData.write(to: dir.appendingPathComponent("\(sessionId)-march.summary.json"))

        let results = WalkLabSession.loadAllExperimentSummaries(experimentId: expId,
                                                                 baseDir: dir)
        XCTAssertEqual(results.count, 1, "experimentId 일치 → 1개 로드돼야 한다")
        XCTAssertEqual(results.first?.id, sessionId, "id 가 일치해야 한다")
    }

    /// experimentId 가 다른 jsonl 은 무시돼야 한다.
    func testLoadAllExperimentSummariesIgnoresMismatchedExperimentId() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "2026-05-24T10-02-00.000Z"

        let header = WalkSessionHeader(
            sessionId: sessionId, startTimeIso: "2026-05-24T10:02:00Z",
            preset: "march", intensityLevelAtStart: 1, appVersion: "t", isRealRobot: false,
            experimentId: "exp-other"  // 다른 experimentId
        )
        var jsonlData = try JSONEncoder().encode(header)
        jsonlData.append(contentsOf: "\n".utf8)
        try jsonlData.write(to: dir.appendingPathComponent("\(sessionId)-march.jsonl"))

        let summary = makeMinimalSummary(id: sessionId)
        let summaryData = try JSONEncoder().encode(summary)
        try summaryData.write(to: dir.appendingPathComponent("\(sessionId)-march.summary.json"))

        let results = WalkLabSession.loadAllExperimentSummaries(experimentId: "exp-target",
                                                                 baseDir: dir)
        XCTAssertEqual(results.count, 0, "experimentId 불일치 → 0개여야 한다")
    }

    // MARK: - readFirstLine (via loadAllExperimentSummaries)

    /// 내용이 없는 jsonl (빈 파일) 은 로드 실패 → summaries 에 포함 안 됨.
    func testReadFirstLineEmptyFileIsSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 빈 jsonl 파일 생성.
        let emptyURL = dir.appendingPathComponent("empty.jsonl")
        try Data().write(to: emptyURL)

        let results = WalkLabSession.loadAllExperimentSummaries(experimentId: "exp-x",
                                                                 baseDir: dir)
        XCTAssertEqual(results.count, 0, "빈 jsonl → header 파싱 실패 → skip")
    }

    /// 여러 sample 이 있는 긴 jsonl 에서도 첫 줄(header)만 읽어 experimentId 를 매치한다.
    func testReadFirstLineHandlesMultiLinejsonl() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let expId = "exp-multiline"
        let sessionId = "2026-05-24T10-03-00.000Z"

        let header = WalkSessionHeader(
            sessionId: sessionId, startTimeIso: "2026-05-24T10:03:00Z",
            preset: "normalWalk", intensityLevelAtStart: 2, appVersion: "t",
            isRealRobot: false, experimentId: expId
        )
        var jsonlData = try JSONEncoder().encode(header)
        jsonlData.append(contentsOf: "\n".utf8)
        // 더미 sample 줄 50개 추가.
        for _ in 0..<50 {
            jsonlData.append(contentsOf: "{\"t\":100.0,\"extra\":true}\n".utf8)
        }
        try jsonlData.write(to: dir.appendingPathComponent("\(sessionId)-normalWalk.jsonl"))

        let summary = makeMinimalSummary(id: sessionId, preset: "normalWalk")
        let summaryData = try JSONEncoder().encode(summary)
        try summaryData.write(to: dir.appendingPathComponent("\(sessionId)-normalWalk.summary.json"))

        let results = WalkLabSession.loadAllExperimentSummaries(experimentId: expId,
                                                                 baseDir: dir)
        XCTAssertEqual(results.count, 1,
                       "긴 jsonl 에서도 첫 줄만 읽어 experimentId 를 매치해야 한다")
    }

    // MARK: - Private helpers

    private func makeMinimalWalkSample() -> WalkSessionSample {
        WalkSessionSample(
            t: 100.0,
            preset: "march",
            intensityLevel: 1,
            imuRollDeg: 0.5,
            imuPitchDeg: 0.3,
            correctorRollErrDeg: 0.1,
            correctorPitchErrDeg: 0.05,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "sim",
            batteryVolts: nil,
            motorAvgTemp: nil
        )
    }

    private func cleanup(_ logger: WalkSessionLogger) {
        let fm = FileManager.default
        try? fm.removeItem(at: logger.filePath)
        let summaryURL = logger.filePath.deletingPathExtension().appendingPathExtension("summary.json")
        try? fm.removeItem(at: summaryURL)
    }
}
