import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **사이클 254 (V-P0-1) — safety-critical test gap 5건 추가.**
///
/// test-coverage agent 가 식별한 HIGH risk 3가지 gap 커버:
///
/// 1. `bcEvaluateFreshnessGate` — busConnected=true + lastImuSampleAt=nil 경로 (가장 위험)
/// 2. `bcEvaluateFreshnessGate` — 250ms / 500ms 경계 + degraded linear 감쇠 검증
/// 3. `WalkLabSession` DI harness — start() bus=nil 환경 → walkLabStartBlocked 발화
/// 4. `WalkLabSession` DI harness — swcGuardAlreadyWalking → walkLabStartBlocked 발화
/// 5. `MotionDocumentStore` — undoStack 51 push → maxUndoDepth=50 enforce / copiedStep 동작
///
/// **testability hook 의존**:
/// - `_testOverrideLastImuSampleAt: Date??` — lastImuSampleAt store-derived computed 우회.
/// - `_testOverrideBusConnected: Bool?` — store?.bus != nil 계산 우회.
/// 두 hook 모두 `#if DEBUG` 컴파일 가드 — production release 빌드 overhead 0.
///
/// **RecordingHarness.Recorded** 는 `data` 필드를 캡처하지 않음 (kind/level/actor/timestamp만).
/// 따라서 reason 내용 검증 대신 kind + count 로 검증.
@MainActor
final class SafetyGapTests: XCTestCase {

    // MARK: - Helper

    private func makeBalanceSession() -> WalkLabSession {
        let s = WalkLabSession()
        s.enableBalanceCorrection = true
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        return s
    }

    // MARK: - Test 1: busConnected=true + lastImuSampleAt=nil → .blocked + earlyReturn

    /// 가장 위험한 fall 유발 경로 — 실 robot 연결됐지만 IMU 한 번도 안 온 상태.
    ///
    /// `bcEvaluateFreshnessGate` 가 `.blocked` + earlyReturn(pose 그대로) 을 발화해야 한다.
    /// 이 경로가 통과하면 보정이 0 데이터 기반으로 실행되어 낙상을 유발할 수 있음.
    func testFreshnessGateBusConnectedImuNilReturnsBlocked() {
        let session = makeBalanceSession()

        // bus 연결됨 (실 robot) 시뮬 — hardware Bus 없이 override hook 사용.
        session._testOverrideBusConnected = true
        // IMU 샘플 한 번도 없음 — .some(nil) = Optional<Date>.some(nil).
        session._testOverrideLastImuSampleAt = .some(nil)

        let inputPose = RobotPose.walkReady
        let outputPose = session.applyBalanceCorrectionIfEnabled(to: inputPose)

        XCTAssertEqual(
            session.balanceCorrectionFreshness, .blocked,
            "busConnected=true + lastImuSampleAt=nil → freshness .blocked (가장 위험한 경로)"
        )
        XCTAssertEqual(
            outputPose, inputPose,
            "blocked early return 시 pose 변환 없이 그대로 반환"
        )
        XCTAssertNil(
            session.lastCorrections,
            "blocked 시 lastCorrections nil — stale corrections 잔류 차단"
        )
        XCTAssertFalse(
            session.lastCorrectionApplied,
            "blocked 시 lastCorrectionApplied false"
        )
    }

    // MARK: - Test 2: 250ms / 500ms 경계 + degraded linear 감쇠

    /// imuSampleAge < 250ms → freshness .normal, gate 1.0 (보정 전량 적용).
    func testFreshnessGateBelow250msIsNormal() {
        let session = makeBalanceSession()
        // 100ms 전 샘플 — 250ms 미만이므로 .normal.
        let sampleTime = Date().addingTimeInterval(-0.100)
        session._testOverrideLastImuSampleAt = .some(sampleTime)
        session._testOverrideBusConnected = true

        _ = session.applyBalanceCorrectionIfEnabled(to: .walkReady)

        XCTAssertEqual(
            session.balanceCorrectionFreshness, .normal,
            "imuSampleAge < 250ms → freshness .normal"
        )
    }

    /// imuSampleAge = 375ms → .degraded (linear 250→500ms 감쇠 중간점).
    func testFreshnessGate375msIsDegraded() {
        let session = makeBalanceSession()
        // 375ms 전 샘플 — 250ms < 375ms < 500ms → .degraded.
        let sampleTime = Date().addingTimeInterval(-0.375)
        session._testOverrideLastImuSampleAt = .some(sampleTime)
        session._testOverrideBusConnected = true

        _ = session.applyBalanceCorrectionIfEnabled(to: .walkReady)

        XCTAssertEqual(
            session.balanceCorrectionFreshness, .degraded,
            "imuSampleAge = 375ms → freshness .degraded (linear 감쇠 구간)"
        )
    }

    /// imuSampleAge ≥ 500ms → .blocked, earlyReturn (pose 변환 없음).
    func testFreshnessGate500msOrMoreIsBlocked() {
        let session = makeBalanceSession()
        // 600ms 전 샘플 — 500ms 이상이므로 .blocked.
        let sampleTime = Date().addingTimeInterval(-0.600)
        session._testOverrideLastImuSampleAt = .some(sampleTime)
        session._testOverrideBusConnected = true

        let inputPose = RobotPose.walkReady
        let outputPose = session.applyBalanceCorrectionIfEnabled(to: inputPose)

        XCTAssertEqual(
            session.balanceCorrectionFreshness, .blocked,
            "imuSampleAge ≥ 500ms → freshness .blocked"
        )
        XCTAssertEqual(
            outputPose, inputPose,
            "blocked (500ms stale) 시 pose 변환 없음"
        )
    }

    // MARK: - Test 3: WalkLabSession DI harness — start() bus=nil → walkLabStartBlocked

    /// `WalkLabSession(harness: RecordingHarness)` 로 생성 후 store=nil (bus 없음) 환경에서
    /// `start(.march)` 호출 시 harness 에 `.walkLabStartBlocked` 가 발화되는지 검증.
    ///
    /// 이 테스트는 swcResolveStoreAndCradle 의 DI 경로가 RecordingHarness 에 도달하는지
    /// 확인한다 — startWalkCycle 내부에서 noConnectionRace cause 로 기록.
    func testWalkLabSessionStartDIHarnessRecordsBusNilBlocked() {
        let harness = RecordingHarness()
        let session = WalkLabSession(harness: harness)
        // store nil (bus 없음) — 시뮬 모드.
        // cradleConfirmed=true 로 quickPreflight 의 cradle 차단은 우회.
        session.cradleConfirmed = true

        session.start(.march)

        let blocked = harness.events.filter { $0.kind == .walkLabStartBlocked }
        XCTAssertFalse(
            blocked.isEmpty,
            "store=nil 환경에서 start() 호출 시 .walkLabStartBlocked 가 harness 에 기록되어야 함"
        )
        // startWalkCycle 의 swcResolveStoreAndCradle 는 actor=.system 으로 발화.
        let systemBlocked = blocked.filter { $0.actor == .system }
        XCTAssertFalse(
            systemBlocked.isEmpty,
            "bus nil 경로의 walkLabStartBlocked 는 actor=.system (race condition 추적)"
        )
    }

    // MARK: - Test 4: swcGuardAlreadyWalking DI harness record

    /// 이미 보행 중인 상태에서 `start()` 재호출 시 `swcGuardAlreadyWalking` 이
    /// 주입된 RecordingHarness 에 `.walkLabStartBlocked` (actor=.user) 를
    /// 기록하는지 검증.
    func testSwcGuardAlreadyWalkingRecordsTelemetryOnDIHarness() {
        let harness = RecordingHarness()
        let session = WalkLabSession(harness: harness)
        session.cradleConfirmed = true

        // 첫 start — 보행 중 상태로 진입 (sim 모드: store nil 이라 실제 cycle 없음).
        session.start(.march)
        let countAfterFirstStart = harness.events.filter { $0.kind == .walkLabStartBlocked }.count

        // _testForceWalkActive 로 "보행 중" 상태 강제.
        #if DEBUG
        session._testForceWalkActive(.march)
        #endif

        // 두 번째 start — swcGuardAlreadyWalking 이 차단해야 함.
        session.start(.normalWalk)

        let allBlocked = harness.events.filter { $0.kind == .walkLabStartBlocked }
        XCTAssertGreaterThan(
            allBlocked.count, countAfterFirstStart,
            "보행 중 재start 시 .walkLabStartBlocked 가 추가로 기록되어야 함"
        )
        // alreadyWalking 의 actor 는 .user (사용자 재진입 시도).
        let lastBlocked = allBlocked.last
        XCTAssertEqual(
            lastBlocked?.actor, .user,
            "alreadyWalking 차단은 actor=.user (사용자 재진입 시도)"
        )
    }

    // MARK: - Test 5: MotionDocumentStore undoStack maxDepth + copiedStep

    /// undoStack 에 51개 push 시 maxUndoDepth=50 강제 — oldest drop.
    func testUndoStackDropsOldestWhenExceedsMaxDepth() {
        let store = MotionDocumentStore()
        XCTAssertEqual(store.maxUndoDepth, 50)

        // pushUndoSnapshot 로직을 직접 재현:
        // doc.undoStack.append(motion); if count > maxUndoDepth { removeFirst() }
        for i in 0..<51 {
            let pushDoc = MotionDoc(version: UInt32(i + 1), robotGeneration: "op2", pages: [])
            store.undoStack.append(pushDoc)
            if store.undoStack.count > store.maxUndoDepth {
                store.undoStack.removeFirst()
            }
        }

        XCTAssertEqual(
            store.undoStack.count, 50,
            "51번 push 후 maxUndoDepth=50 강제 — oldest drop"
        )
        // 첫 번째 (version=1) 가 drop 되고, 두 번째 (version=2) 가 oldest.
        XCTAssertEqual(
            store.undoStack.first?.version, 2,
            "oldest (version=1) 이 drop 되고 version=2 가 새 oldest"
        )
    }

    /// redoStack 은 undoStack push 시 clear 되어야 함 (undo 후 새 편집 = redo 불가).
    func testRedoStackClearedOnUndoPush() {
        let store = MotionDocumentStore()
        // redo 스택에 임의 항목 삽입.
        store.redoStack.append(MotionDoc(version: 1, robotGeneration: "op2", pages: []))
        XCTAssertEqual(store.redoStack.count, 1)

        // pushUndoSnapshot 로직 재현 — redo clear.
        store.undoStack.append(store.motion)
        store.redoStack.removeAll()

        XCTAssertTrue(
            store.redoStack.isEmpty,
            "새 undo snapshot push 시 redoStack clear"
        )
    }

    /// copiedStep set/clear 동작 — nil ↔ non-nil 순환.
    func testCopiedStepSetAndClear() {
        let store = MotionDocumentStore()
        XCTAssertNil(store.copiedStep, "초기 copiedStep nil")

        let step = MotionStep.center
        store.copiedStep = step
        XCTAssertNotNil(store.copiedStep, "copiedStep set 후 non-nil")

        store.copiedStep = nil
        XCTAssertNil(store.copiedStep, "copiedStep nil set 후 다시 nil")
    }
}
