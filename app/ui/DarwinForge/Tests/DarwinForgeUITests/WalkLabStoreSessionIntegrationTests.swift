import XCTest
@testable import DarwinForgeUI

/// 사이클 175 — ConnectionStore + WalkLabSession 통합 chain 검증.
///
/// cycle 159 의 imuFastPollActive flag 가 WalkLabSession 의 walk start/stop 시
/// store 측에 정상 전파되는지 + 다양한 mode 의 일관성 확인.
@MainActor
final class WalkLabStoreSessionIntegrationTests: XCTestCase {

    /// **유기 검증 #1**: 신규 store + session 의 imuFastPollActive default = false.
    func testNewStoreSessionImuFastPollDefault() {
        let store = ConnectionStore()
        XCTAssertFalse(store.imuFastPollActive,
                       "신규 ConnectionStore default = false (5Hz idle)")
        let session = WalkLabSession()
        session.attach(store: store)
        XCTAssertFalse(store.imuFastPollActive,
                       "session attach 만으로는 변경 안 됨 (walk 시작 시에만)")
    }

    /// **유기 검증 #2**: store 측에서 imuFastPollActive set → session 측에서 read 가능.
    /// 양방향 (store ↔ session) 일관성 확인.
    func testStoreImuFastPollMutationVisible() {
        let store = ConnectionStore()
        let session = WalkLabSession()
        session.attach(store: store)
        XCTAssertFalse(session.store?.imuFastPollActive ?? true)

        // store 직접 mutate.
        store.imuFastPollActive = true
        XCTAssertTrue(session.store?.imuFastPollActive ?? false,
                      "store mutation 이 session.store reference 통해 즉시 visible")

        // 반대.
        store.imuFastPollActive = false
        XCTAssertFalse(session.store?.imuFastPollActive ?? true)
    }

    /// **유기 검증 #3**: store.imuFastPollActive 가 @Published —
    /// observer subscription 가능.
    func testImuFastPollIsPublished() {
        let store = ConnectionStore()
        var observed: [Bool] = []
        let cancellable = store.$imuFastPollActive.sink { observed.append($0) }
        defer { cancellable.cancel() }

        // 초기 + 2회 mutation.
        store.imuFastPollActive = true
        store.imuFastPollActive = false

        XCTAssertGreaterThanOrEqual(observed.count, 3,
                                     "초기값 (false) + 2 mutation observe (sink 가 즉시 + 매 set)")
        XCTAssertTrue(observed.contains(true))
        XCTAssertTrue(observed.contains(false))
    }

    /// **유기 검증 #4**: ConnectionStore + WalkLabSession 가 weak ref 관계 — store
    /// release 시 session.store == nil.
    func testStoreWeakRefRelease() {
        let session = WalkLabSession()
        do {
            let store = ConnectionStore()
            session.attach(store: store)
            XCTAssertNotNil(session.store)
            XCTAssertFalse(store.imuFastPollActive)
        } // store 여기서 out-of-scope.
        XCTAssertNil(session.store,
                     "weak ref — store deinit 후 session.store == nil")
    }

    /// **유기 검증 #5**: store attach 안 한 session 의 가드 일관성.
    /// store nil 시 walkingEngine 가져와도 시뮬 path 유지.
    func testSessionWithoutStoreGracefulSim() {
        let session = WalkLabSession()
        XCTAssertNil(session.store)
        XCTAssertEqual(session.imuSource, .sim,
                       "store 없으면 imuSource = sim")
        session.enableBalanceCorrection = true
        // applyBalanceCorrection 도 sim mode (bus nil 분기) — freshness = .normal.
        _ = session.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(session.balanceCorrectionFreshness, .normal)
    }

    /// **유기 검증 #6**: WalkingEngine 전환 (Mac sparse ↔ Onboard) 시 session +
    /// onboardBalanceSchemaWarningActive 관계.
    func testEngineSwitchDoesNotAffectStorePollRate() {
        let store = ConnectionStore()
        let session = WalkLabSession()
        session.attach(store: store)

        // 초기 — Mac sparse, store fast poll OFF.
        XCTAssertEqual(session.walkingEngine, .macSparseKeyframe)
        XCTAssertFalse(store.imuFastPollActive)

        // Onboard 로 전환 — start() 호출 안 함. store flag 변화 X.
        session.walkingEngine = .robotisOnboard
        XCTAssertFalse(store.imuFastPollActive,
                       "단순 engine 전환은 store poll rate 영향 없음. walk start 만 변경.")
    }
}
