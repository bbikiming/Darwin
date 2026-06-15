import XCTest
@testable import DarwinForgeUI

/// 사이클 206 — Snapshot metadata UserDefaults 영속화 regression guard.
///
/// PII 경계: RobotPose joint data 는 디스크에 없음.
/// UserDefaults 격리: 각 테스트는 독립 suiteName UserDefaults 사용.
@MainActor
final class TeachSnapshotPersistenceTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.darwin.test.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// 격리된 UserDefaults 를 사용하는 TeachCapture 인스턴스.
    private func makeCapture() -> TeachCapture {
        TeachCapture(defaults: testDefaults)
    }

    /// snapshot() 은 livePose 를 기반으로 동작하므로, 직접 snapshotting 을 위한 헬퍼.
    /// TeachCapture.snapshot(name:) 이 `snapshots.insert` + `appendMeta` 를 수행.
    private func captureSnapshot(in capture: TeachCapture, name: String = "테스트 자세") {
        // livePose 는 .center 기본값이므로 snapshot() 직접 호출 가능.
        capture.snapshot(name: name)
    }

    // MARK: - Tests

    /// 신규 인스턴스는 메타데이터 없음.
    func testEmptyByDefault() {
        let capture = makeCapture()
        XCTAssertEqual(capture.persistedSnapshotCount, 0,
                       "새 인스턴스의 persistedSnapshotCount 는 0 이어야 함")
    }

    /// snapshot() 호출 후 메타데이터가 1개 추가되어야 함.
    func testCaptureAddsMetadata() {
        let capture = makeCapture()
        captureSnapshot(in: capture, name: "자세 A")
        XCTAssertEqual(capture.persistedSnapshotCount, 1,
                       "스냅샷 1개 캡처 후 persistedSnapshotCount 는 1 이어야 함")

        captureSnapshot(in: capture, name: "자세 B")
        XCTAssertEqual(capture.persistedSnapshotCount, 2,
                       "스냅샷 2개 캡처 후 persistedSnapshotCount 는 2 이어야 함")
    }

    /// deleteSnapshot() 호출 후 해당 메타데이터가 제거되어야 함.
    func testDeleteRemovesMetadata() throws {
        let capture = makeCapture()
        captureSnapshot(in: capture, name: "삭제 대상")
        captureSnapshot(in: capture, name: "유지 대상")
        XCTAssertEqual(capture.persistedSnapshotCount, 2)

        let toDelete = try XCTUnwrap(capture.snapshots.first)
        capture.deleteSnapshot(toDelete)

        XCTAssertEqual(capture.persistedSnapshotCount, 1,
                       "deleteSnapshot 후 persistedSnapshotCount 는 1 이어야 함")
    }

    /// clearSnapshots() 호출 후 메타데이터 전체가 삭제되어야 함.
    func testClearAllRemovesAll() {
        let capture = makeCapture()
        captureSnapshot(in: capture, name: "A")
        captureSnapshot(in: capture, name: "B")
        captureSnapshot(in: capture, name: "C")
        XCTAssertEqual(capture.persistedSnapshotCount, 3)

        capture.clearSnapshots()

        XCTAssertEqual(capture.persistedSnapshotCount, 0,
                       "clearSnapshots 후 persistedSnapshotCount 는 0 이어야 함")
    }

    /// 다른 TeachCapture 인스턴스 간에 메타데이터가 공유되어야 함 (앱 재시작 시뮬레이션).
    func testPersistsAcrossInstances() {
        let first = makeCapture()
        captureSnapshot(in: first, name: "재시작 전 자세")
        captureSnapshot(in: first, name: "재시작 전 자세 2")
        XCTAssertEqual(first.persistedSnapshotCount, 2)

        // 새 인스턴스 생성 — 앱 재시작 시뮬레이션.
        let second = makeCapture()
        XCTAssertEqual(second.persistedSnapshotCount, 2,
                       "재시작 후 새 인스턴스는 이전 메타데이터 수(2)를 유지해야 함")
        XCTAssertEqual(second.snapshots.count, 0,
                       "재시작 후 실제 pose 목록은 비어 있어야 함 (PII 경계)")
    }

    /// TelemetryKind.teachSnapshotMetaRestored 가 정의되어 있는지 확인.
    func testTelemetryKindExists() {
        let kind = TelemetryKind.teachSnapshotMetaRestored
        XCTAssertEqual(kind.rawValue, "teach.snapshot_meta_restored",
                       "teachSnapshotMetaRestored rawValue 가 'teach.snapshot_meta_restored' 이어야 함")
    }
}
