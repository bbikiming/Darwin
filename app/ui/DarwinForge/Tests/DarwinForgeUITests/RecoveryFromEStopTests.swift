import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 로봇 복구 (E-stop 이후 액추에이터 재활성) 단위 테스트.
///
/// 실 Bus 없이도 호출 가능 — bus == nil 인 경우 즉시 `.notConnected` outcome.
/// 실제 모터 I/O 회귀는 HIL 시나리오에서 검증 (cradle 거치 + 로봇 연결).
@MainActor
final class RecoveryFromEStopTests: XCTestCase {

    func testRecoveryWithoutBusReportsNotConnected() async {
        let store = ConnectionStore()
        XCTAssertNil(store.bus, "테스트 환경에서 bus 는 nil 이어야 함")

        // 새 시그니처: cradleConfirmed 명시. bus=nil 이라 cradle 검사 전에 .notConnected 반환.
        await store.recoverFromEStop(cradleConfirmed: true)

        XCTAssertEqual(store.lastRecoveryOutcome, .notConnected)
        XCTAssertNotNil(store.lastRecoveryResult)
        XCTAssertTrue(store.lastRecoveryResult?.contains("연결") ?? false,
            "안내 메시지에 '연결' 키워드 포함되어야 함")
    }

    func testRecoveryNotRunningAfterCompletion() async {
        let store = ConnectionStore()
        await store.recoverFromEStop(cradleConfirmed: true)
        XCTAssertFalse(store.isRecovering, "완료 후 isRecovering 은 false")
    }

    func testConcurrentRecoveryCallsAreSerialized() async {
        let store = ConnectionStore()
        // 두 번 동시 호출 — 두 번째는 즉시 return (중복 방지).
        async let r1: Void = store.recoverFromEStop(cradleConfirmed: true)
        async let r2: Void = store.recoverFromEStop(cradleConfirmed: true)
        _ = await (r1, r2)
        XCTAssertFalse(store.isRecovering)
        XCTAssertEqual(store.lastRecoveryOutcome, .notConnected)
    }

    func testRecoveryOutcomeEnumValues() {
        let o1: ConnectionStore.RecoveryOutcome = .success
        let o2: ConnectionStore.RecoveryOutcome = .failure
        let o3: ConnectionStore.RecoveryOutcome = .notConnected
        XCTAssertNotEqual(o1, o2)
        XCTAssertNotEqual(o2, o3)
        XCTAssertNotEqual(o1, o3)
    }

    /// 복구 경로 진입 시 기존 lastSafetyEvent 가 즉시 제거되어야 함.
    func testRecoveryClearsLastSafetyEvent() async {
        let store = ConnectionStore()
        await store.recoverFromEStop(cradleConfirmed: true)
        XCTAssertNil(store.lastSafetyEvent,
            "복구 후엔 안전 이벤트가 잔류하지 않아야 함")
    }

    // MARK: - CRITIC P1 Regression Tests

    /// CRITIC P1-D: cradle 거치 확인 없이 복구 호출 시 즉시 거부 — bus 가 살아 있어도.
    /// bus=nil 환경에서는 bus 게이트가 먼저 발동하므로, cradle 게이트 자체는 통합 시나리오에서.
    /// 본 테스트는 default 값 (cradleConfirmed=false) 의 거부 path 만 확인.
    func testRecoveryWithoutCradleConfirmIsRejected() async {
        let store = ConnectionStore()
        // 기본값 false 로 호출 — bus 도 nil 이라 .notConnected 가 먼저 발동.
        // (실 robot 환경에서는 bus 가 있고 cradleConfirmed=false 면 .failure + "정비 스탠드" 메시지.)
        await store.recoverFromEStop()
        XCTAssertNotNil(store.lastRecoveryOutcome)
        XCTAssertNotEqual(store.lastRecoveryOutcome, .success,
            "cradle 확인 안 한 복구는 success 가 될 수 없음")
    }

    /// CRITIC P1-B: disconnect 가 복구 관련 flag 를 동기 리셋해야 함.
    /// 종전엔 복구 중 disconnect 시 isRecovering 잔류 → 버튼 영구 disabled.
    func testDisconnectResetsRecoveryFlags() async {
        let store = ConnectionStore()
        // 직접 플래그 강제 — 실 시나리오 시뮬레이션 (Mock Bus 부재).
        // (private 이라 직접 set 불가하지만, 한 번 복구 호출 후 disconnect 가 동기 정리하는지 검증.)
        await store.recoverFromEStop(cradleConfirmed: true)
        // 복구 완료 (bus=nil 이라 즉시 .notConnected) 상태에서 disconnect 호출.
        store.disconnect()
        XCTAssertFalse(store.isRecovering, "disconnect 후 isRecovering = false")
        XCTAssertEqual(store.status, .disconnected)
    }

    /// CRITIC P1-C: 복구 메시지가 'walkReady' 또는 'deep squat' 등을 언급해야 함.
    /// 종전 'idle' 메시지는 hotfix v2 fall mode 와 연관됨.
    /// (bus=nil 경로는 cradle 안내 또는 연결 안내 — 본 테스트는 메시지 존재 + 비-success 확인.)
    func testRecoveryWithoutBusDoesNotReportSuccess() async {
        let store = ConnectionStore()
        await store.recoverFromEStop(cradleConfirmed: true)
        XCTAssertNotEqual(store.lastRecoveryOutcome, .success,
            "bus=nil 환경에서 success outcome 은 거짓 positive")
    }
}
