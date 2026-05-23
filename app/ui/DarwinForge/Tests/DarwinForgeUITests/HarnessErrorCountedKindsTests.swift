import Foundation
import XCTest
@testable import DarwinForgeUI

/// 사이클 192 (codex critic MAJOR-1 cycle 188 fix): `errorCountedKinds` 단일 source
/// of truth + regression-proof 매핑 검증.
///
/// # 비유
///
/// 사고 분류 표 — 새 사고 유형 (cycle 181 plan_execution_failed 등) 이 표 에 등록
/// 안 되면 통계 보고서 가 0건 표시. 본 테스트 는 (1) 표 자체 가 일관 + (2) 알려진
/// error-level emit site 가 모두 표 에 등록 됨 + (3) 의도된 제외 (pilotEStop) 가
/// 의도대로 비카운트 보장.
final class HarnessErrorCountedKindsTests: XCTestCase {

    /// **검증 #1**: `errorCountedKinds` 와 `errorCountedRawValues` 정확 매핑.
    /// 두 constant 가 derived 라서 build 시 sync 보장 하지만 explicit assert 로 회귀
    /// 차단.
    func testErrorCountedKindsRawValuesMatch() {
        XCTAssertEqual(
            TelemetryRecorder.errorCountedRawValues,
            Set(TelemetryRecorder.errorCountedKinds.map { $0.rawValue }),
            "errorCountedRawValues 와 errorCountedKinds 의 raw value 가 다름 — drift"
        )
    }

    /// **검증 #2**: list 에 중복 없음.
    func testNoDuplicates() {
        let raws = TelemetryRecorder.errorCountedKinds.map { $0.rawValue }
        let unique = Set(raws)
        XCTAssertEqual(raws.count, unique.count,
                       "errorCountedKinds 에 중복 — drift 위험")
    }

    /// **검증 #3**: cycle 192 의 신규 추가 4건 모두 포함 — 회귀 가드.
    /// 종전 cycle 188 이 cycle 181/182 신규 만 추가했고 cycle 185 critic 가 발견 한
    /// connectFailure / poseApplyFailed / busEStop / walkLabEmergencyStop 가 본 cycle
    /// 192 에서 포함. 본 테스트 는 그 4 종 의 빠짐 차단.
    func testKnownErrorSitesIncluded() {
        let must: [TelemetryKind] = [
            .connectFailure,
            .poseApplyFailed,
            .busEStop,
            .walkLabEmergencyStop,
            // 누적 — cycle 188 이 추가한 것들.
            .claudePlanExecutionFailed,
            .remoteCommandError,
            // 원래 있었던 것들.
            .errorException,
            .claudeError,
            .busReadFail,
            .busWriteFail
        ]
        for k in must {
            XCTAssertTrue(
                TelemetryRecorder.errorCountedRawValues.contains(k.rawValue),
                "kind=\(k.rawValue) 가 errorCountedRawValues 에 누락 — meta.errorCount undercount"
            )
        }
    }

    /// **검증 #4**: pilotEStop + uiViewAppeared 의도된 제외 (design choice).
    /// - pilotEStop: level=.warn (사용자 안전 액션 — 시스템 오류 X).
    /// - uiViewAppeared: level=.trace (cycle 197 navigation 추적 — 사고 X).
    /// 분석 도구 가 별도 kind 카운트.
    func testIntentionalExclusions() {
        let mustNot: [TelemetryKind] = [
            .pilotEStop,        // level=.warn, design choice
            .uiViewAppeared     // cycle 199 critic 응답: level=.trace, exclude
        ]
        for k in mustNot {
            XCTAssertFalse(
                TelemetryRecorder.errorCountedRawValues.contains(k.rawValue),
                "kind=\(k.rawValue) 는 의도된 제외 — errorCount 포함 시 design 위반"
            )
        }
    }

    /// **검증 #5**: count regression — 신규 추가 시 본 테스트 깨져서 doc update 강제.
    /// cycle 196: 11건 (errorException + 4 connect/bus + 1 pose + 1 walk + 2 claude + 1 remote + 1 joint).
    /// 변경 시 USER_PILOT_GUIDE + harness/telemetry-harness.md 도 sync 필요.
    func testTotalErrorCountedKindCount() {
        XCTAssertEqual(
            TelemetryRecorder.errorCountedKinds.count, 11,
            "cycle 196 의 11건 — 변경 시 doc + audit 동기화 필요"
        )
    }

    // MARK: - end-to-end with recorder

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorCountedTests-\(UUID().uuidString)",
                                     isDirectory: true)
    }

    override func tearDown() async throws {
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
        try await super.tearDown()
    }

    /// **end-to-end 검증 #6**: 모든 errorCountedKind 가 .error level emit → errorCount += 1 each.
    func testAllErrorCountedKindsAccumulate() async throws {
        let meta = TelemetrySessionMeta(
            id: UUID().uuidString,
            started: ISO8601DateFormatter().string(from: Date()),
            appVersion: "test", appBuild: "0", os: "test", device: "test"
        )
        let recorder = try TelemetryRecorder(directory: tempDir, meta: meta)
        for kind in TelemetryRecorder.errorCountedKinds {
            await recorder.enqueue(TelemetryEvent(
                session: meta.id, seq: 0, wall: "t", mono: 0,
                kind: kind, level: .error, actor: .system))
        }
        await recorder.flush()
        let snapshot = await recorder.meta
        let expected = UInt64(TelemetryRecorder.errorCountedKinds.count)
        XCTAssertEqual(snapshot.errorCount, expected,
                       "각 kind 1회 .error emit → errorCount = kind 수")
    }

    /// **검증 #7**: 같은 kind 라도 level != .error → 비카운트.
    func testNonErrorLevelDoesNotCount() async throws {
        let meta = TelemetrySessionMeta(
            id: UUID().uuidString,
            started: ISO8601DateFormatter().string(from: Date()),
            appVersion: "test", appBuild: "0", os: "test", device: "test"
        )
        let recorder = try TelemetryRecorder(directory: tempDir, meta: meta)
        // connectFailure 가 .info level → 비카운트.
        await recorder.enqueue(TelemetryEvent(
            session: meta.id, seq: 0, wall: "t", mono: 0,
            kind: .connectFailure, level: .info, actor: .system))
        // 같은 kind 가 .error level → 카운트.
        await recorder.enqueue(TelemetryEvent(
            session: meta.id, seq: 0, wall: "t", mono: 0,
            kind: .connectFailure, level: .error, actor: .system))
        await recorder.flush()
        let snapshot = await recorder.meta
        XCTAssertEqual(snapshot.errorCount, 1,
                       ".error 만 count — .info 는 비카운트 (level gating)")
    }
}
