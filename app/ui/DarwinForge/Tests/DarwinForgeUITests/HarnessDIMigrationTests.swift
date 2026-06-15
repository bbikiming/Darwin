import ForgeCore
import XCTest
@testable import DarwinForgeUI

// MARK: - HarnessDIMigrationTests (Wave 3 Phase 3.2, 사이클 242)
//
// 회귀 가드 — Phase 3.2 Top 5 caller 가 주입된 HarnessFacade 로 record 호출하는지 검증.
//
// 검증 대상 (4 backend caller — View 는 SwiftUI Environment 주입 패턴이므로
// 본 backend 검증으로 충분):
//
//   1. ConnectionStore   — connect 시도 → harness.record(.connectAttempt) 발화
//   2. ConversationViewModel — clear() → harness.record(.claudeSessionCleared)
//   3. WalkLabSession    — cradleConfirmed 토글 → harness.record(.walkLabConfigChange)
//   4. MotionPlayer      — load(page) → harness.record(.motionLoad)
//
// 5. RemoteShellView 는 SwiftUI View — Environment 주입 패턴이라 직접 init injection
//    불가. body 렌더 + button tap simulate 가 ViewInspector 없이 어려움 — 본 회귀
//    가드는 backend 4건. EnvironmentValues+Harness 의 default 가 NoopHarness 라
//    RootView 의 .environment(\.harness, LiveHarness.shared) 누락 시 telemetry
//    silent 누락 — RootView 의 env 주입 자체가 별도 manual 검증 포인트.
@MainActor
final class HarnessDIMigrationTests: XCTestCase {

    // MARK: - ConnectionStore

    /// ConnectionStore init 시 RecordingHarness 가 contextProviderRegistered 받는지.
    /// 등록 자체 — 첫 record() 발화 안 해도 registerContextProvider 호출이 init 안에 있음.
    func testConnectionStoreInjectedHarnessReceivesContextProviderRegistration() {
        let harness = RecordingHarness()
        _ = ConnectionStore(harness: harness)
        XCTAssertTrue(harness.contextProviderRegistered,
            "ConnectionStore.init 이 주입된 harness 에 registerContextProvider 호출해야 함")
    }

    /// disconnect() 호출 시 .connectDisconnect 발화. 다른 경로는 bus 가 필요해 mock 어려움.
    func testConnectionStoreDisconnectRecordsTelemetry() {
        let harness = RecordingHarness()
        let store = ConnectionStore(harness: harness)
        // 초기 상태에서도 disconnect 발화 — 사용자 명시 행위.
        store.disconnect()
        let disconnectEvents = harness.events.filter { $0.kind == .connectDisconnect }
        XCTAssertEqual(disconnectEvents.count, 1,
            "disconnect() 호출 시 .connectDisconnect telemetry 한 번 발화해야 함")
        XCTAssertEqual(disconnectEvents.first?.actor, .user)
        XCTAssertEqual(disconnectEvents.first?.level, .notice)
    }

    // MARK: - ConversationViewModel

    /// clear() 호출 시 .claudeSessionCleared 발화.
    func testConversationViewModelClearRecordsTelemetry() {
        let harness = RecordingHarness()
        let commander = ClaudeCommander()
        let dispatcher = IntentDispatcher()
        let vm = ConversationViewModel(
            commander: commander,
            dispatcher: dispatcher,
            harness: harness
        )

        vm.clear()
        let cleared = harness.events.filter { $0.kind == .claudeSessionCleared }
        XCTAssertEqual(cleared.count, 1,
            "clear() 호출 시 .claudeSessionCleared telemetry 한 번 발화해야 함")
        XCTAssertEqual(cleared.first?.actor, .user)
    }

    // MARK: - WalkLabSession

    /// cradleConfirmed 토글 시 .walkLabConfigChange 발화 (didSet 안에서).
    func testWalkLabSessionCradleToggleRecordsTelemetry() {
        let harness = RecordingHarness()
        let session = WalkLabSession(harness: harness)

        // 초기 false → true 전환 (didSet 가 oldValue 비교 후 발화).
        session.cradleConfirmed = true

        let configChanges = harness.events.filter { $0.kind == .walkLabConfigChange }
        XCTAssertEqual(configChanges.count, 1,
            "cradleConfirmed 토글 시 .walkLabConfigChange 한 번 발화해야 함")
        XCTAssertEqual(configChanges.first?.actor, .user)
    }

    // MARK: - MotionPlayer

    /// load(page:) 호출 시 .motionLoad 발화.
    func testMotionPlayerLoadRecordsTelemetry() {
        let harness = RecordingHarness()
        let player = MotionPlayer(harness: harness)

        // 최소 1 step 페이지 — telemetry 발화에 step count 만 영향.
        // MotionStep default = center (모든 관절 raw 2048), playTime 32 (256 ms).
        let page = MotionPage(id: 99, name: "test-page", steps: [.center])

        player.load(page)

        let loaded = harness.events.filter { $0.kind == .motionLoad }
        XCTAssertEqual(loaded.count, 1,
            "load(page:) 호출 시 .motionLoad telemetry 한 번 발화해야 함")
        XCTAssertEqual(loaded.first?.actor, .user)
        XCTAssertEqual(loaded.first?.level, .info)
    }
}
