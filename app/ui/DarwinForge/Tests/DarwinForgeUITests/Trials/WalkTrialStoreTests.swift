import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.15.0 (2026-05-21) Phase 1 — WalkTrialStore CRUD + filter/sort 테스트**.
///
/// 각 test 는 임시 디렉토리에 격리된 store init (실 App Support 와 무관).
@MainActor
final class WalkTrialStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: WalkTrialStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkTrialStoreTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = WalkTrialStore(testDirectory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        try await super.tearDown()
    }

    // MARK: - CRUD

    func testAppendAndLoadById() {
        let trial = makeTrial(id: "t1", preset: "march", overallScore: 0.85)
        XCTAssertTrue(store.append(trial))
        let loaded = store.load(id: "t1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.config.preset, "march")
        XCTAssertEqual(loaded?.outcome.overallScore ?? 0, 0.85, accuracy: 1e-9)
    }

    func testIndexUpdatedAfterAppend() {
        let t1 = makeTrial(id: "t1", preset: "march", overallScore: 0.8)
        let t2 = makeTrial(id: "t2", preset: "jog", overallScore: 0.6)
        store.append(t1)
        store.append(t2)
        let index = store.allIndex()
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(Set(index.map { $0.id }), Set(["t1", "t2"]))
    }

    func testOverwriteSameId() {
        let t1 = makeTrial(id: "t1", preset: "march", overallScore: 0.5)
        store.append(t1)
        let t1Updated = makeTrial(id: "t1", preset: "march", overallScore: 0.9)
        store.append(t1Updated)
        XCTAssertEqual(store.allIndex().count, 1, "같은 id 덮어쓰기 — index 1개 유지")
        XCTAssertEqual(store.load(id: "t1")?.outcome.overallScore ?? 0, 0.9, accuracy: 1e-9)
    }

    func testUpdateLabel() {
        let t1 = makeTrial(id: "t1", preset: "march", overallScore: 0.8)
        store.append(t1)
        let label = UserLabel(rating: 4, freeText: "good", tags: ["smooth"], labeledAtIso: "2026-05-21T00:00:00Z")
        XCTAssertTrue(store.updateLabel(id: "t1", label: label))
        let loaded = store.load(id: "t1")
        XCTAssertEqual(loaded?.label?.rating, 4)
        XCTAssertEqual(loaded?.label?.tags, ["smooth"])
        // Index 도 rating 갱신.
        XCTAssertEqual(store.allIndex().first?.rating, 4)
    }

    func testDelete() {
        let t1 = makeTrial(id: "t1", preset: "march", overallScore: 0.8)
        store.append(t1)
        XCTAssertEqual(store.allIndex().count, 1)
        store.delete(id: "t1")
        XCTAssertEqual(store.allIndex().count, 0)
        XCTAssertNil(store.load(id: "t1"))
    }

    // MARK: - Filter

    func testFilterByPreset() {
        store.append(makeTrial(id: "a", preset: "march", overallScore: 0.7))
        store.append(makeTrial(id: "b", preset: "jog", overallScore: 0.5))
        store.append(makeTrial(id: "c", preset: "march", overallScore: 0.9))
        let result = store.query(filter: TrialFilter(preset: "march"))
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map { $0.id }), Set(["a", "c"]))
    }

    func testFilterByMinRating() {
        store.append(makeTrial(id: "low", preset: "march", overallScore: 0.5, rating: 2))
        store.append(makeTrial(id: "mid", preset: "march", overallScore: 0.7, rating: 3))
        store.append(makeTrial(id: "high", preset: "march", overallScore: 0.9, rating: 5))
        let result = store.query(filter: TrialFilter(minRating: 3))
        XCTAssertEqual(Set(result.map { $0.id }), Set(["mid", "high"]))
    }

    func testFilterByNoFallsOnly() {
        store.append(makeTrial(id: "clean", preset: "march", overallScore: 0.9, fallEvents: 0))
        store.append(makeTrial(id: "fell", preset: "march", overallScore: 0.4, fallEvents: 3))
        let result = store.query(filter: TrialFilter(noFallsOnly: true))
        XCTAssertEqual(result.map { $0.id }, ["clean"])
    }

    func testFilterByMinOverallScore() {
        store.append(makeTrial(id: "good", preset: "march", overallScore: 0.85))
        store.append(makeTrial(id: "ok", preset: "march", overallScore: 0.55))
        store.append(makeTrial(id: "bad", preset: "march", overallScore: 0.3))
        let result = store.query(filter: TrialFilter(minOverallScore: 0.6))
        XCTAssertEqual(result.map { $0.id }, ["good"])
    }

    // MARK: - Sort

    func testSortByOverallDesc() {
        store.append(makeTrial(id: "low", preset: "march", overallScore: 0.3))
        store.append(makeTrial(id: "high", preset: "march", overallScore: 0.9))
        store.append(makeTrial(id: "mid", preset: "march", overallScore: 0.6))
        let result = store.query(sort: .overallDesc)
        XCTAssertEqual(result.map { $0.id }, ["high", "mid", "low"])
    }

    func testSortByRatingDescPlacesUnratedLast() {
        store.append(makeTrial(id: "unrated", preset: "march", overallScore: 0.9, rating: 0))
        store.append(makeTrial(id: "3star", preset: "march", overallScore: 0.5, rating: 3))
        store.append(makeTrial(id: "5star", preset: "march", overallScore: 0.7, rating: 5))
        let result = store.query(sort: .ratingDesc)
        XCTAssertEqual(result.map { $0.id }, ["5star", "3star", "unrated"],
                       "rating 0 (미평가) 는 항상 마지막")
    }

    // MARK: - Persistence across instances

    func testPersistenceAcrossInstances() {
        let t1 = makeTrial(id: "t1", preset: "march", overallScore: 0.8)
        store.append(t1)
        // New store instance pointing at same directory.
        let store2 = WalkTrialStore(testDirectory: tempDir)
        XCTAssertEqual(store2.allIndex().count, 1)
        XCTAssertEqual(store2.load(id: "t1")?.config.preset, "march")
    }

    // MARK: - Fixtures

    private func makeTrial(
        id: String, preset: String, overallScore: Double,
        rating: Int = 0, fallEvents: Int = 0
    ) -> WalkTrial {
        let label: UserLabel? = rating > 0
            ? UserLabel(rating: rating, freeText: "", tags: [], labeledAtIso: "2026-05-21T00:00:00Z")
            : nil
        return WalkTrial(
            id: id,
            startedAtIso: "2026-05-21T10:00:00Z",
            endedAtIso: "2026-05-21T10:00:10Z",
            durationSec: 10,
            endReason: .userStop,
            config: TrialConfig(
                preset: preset, presetSafety: "safe", intensityLevel: 2,
                balanceConfig: .defaultRobotis,
                enableBalanceCorrection: true,
                tuning: TuningSnapshot(strideMm: 0, sideMm: 0, turnDeg: 0,
                                       periodMs: 600, footHeightMm: 40, balanceGain: 1.0),
                walkingEngine: "macSparseKeyframe",
                isRealRobot: false
            ),
            outcome: TrialOutcome(
                stabilityScore: overallScore, smoothnessScore: overallScore, energyScore: overallScore,
                overallScore: overallScore,
                stateDistribution: ["normal": 1.0, "caution": 0, "warning": 0, "danger": 0, "emergency": 0],
                fallEventCount: fallEvents, meanTimeBetweenFallsSec: nil,
                peakAbsRollDeg: 0, peakAbsPitchDeg: 0, meanAbsRollDeg: 0, meanAbsPitchDeg: 0,
                peakMotorTempC: 35, busWriteFailures: 0, stepsExecuted: 30, sampleCount: 100
            ),
            label: label,
            timeseries: nil
        )
    }
}
