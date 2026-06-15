import XCTest
@testable import DarwinForgeUI

/// 사이클 172 (codex MINOR #3 + #4 fix): onboardBalanceSchemaWarningActive computed
/// property + onboardBalanceSchemaVerified UserDefaults persistence 검증.
@MainActor
final class WalkLabOnboardSchemaWarningTests: XCTestCase {

    private let key = WalkLabSession.onboardBalanceSchemaVerifiedKey
    /// 테스트 격리용 고유 UserDefaults suite — `--parallel` 시 다른 클래스와의
    /// `df.walklab.*` 키 공유 오염 방지. WalkLabSession 이 이 suite 로 영속화.
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.walklab.onboardschema.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        WalkLabSession.testDefaultsOverride = testDefaults
    }

    override func tearDown() async throws {
        WalkLabSession.testDefaultsOverride = nil
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    /// Mac sparse 모드 + balance ON → warning 비활성 (Onboard 만 적용).
    func testWarningInactiveInMacSparseMode() {
        let s = WalkLabSession()
        s.walkingEngine = .macSparseKeyframe
        s.enableBalanceCorrection = true
        s.onboardBalanceSchemaVerified = false
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "Mac sparse 모드는 Onboard schema 와 무관")
    }

    /// Onboard 모드 + balance OFF → warning 비활성.
    func testWarningInactiveWhenBalanceOff() {
        let s = WalkLabSession()
        s.walkingEngine = .robotisOnboard
        s.enableBalanceCorrection = false
        s.onboardBalanceSchemaVerified = false
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "balance OFF 면 robot 측 자이로 사용 안 함 → warning 불필요")
    }

    /// Onboard 모드 + balance ON + verified → warning 비활성.
    func testWarningInactiveWhenVerified() {
        let s = WalkLabSession()
        s.walkingEngine = .robotisOnboard
        s.enableBalanceCorrection = true
        s.onboardBalanceSchemaVerified = true
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "verified=true 면 daemon v2 인지 → warning dismiss")
    }

    /// Onboard 모드 + balance ON + unverified → warning 활성.
    func testWarningActiveWhenOnboardBalanceUnverified() {
        let s = WalkLabSession()
        s.walkingEngine = .robotisOnboard
        s.enableBalanceCorrection = true
        s.onboardBalanceSchemaVerified = false
        XCTAssertTrue(s.onboardBalanceSchemaWarningActive,
                      "Onboard + balance ON + unverified → silent failure 위험 경고")
    }

    /// computed property — currentWalkingEngineCommand 호출 없이 즉시 평가.
    func testWarningActiveImmediateNoSideEffect() {
        let s = WalkLabSession()
        s.walkingEngine = .robotisOnboard
        s.enableBalanceCorrection = true
        s.onboardBalanceSchemaVerified = false
        // currentWalkingEngineCommand() 호출 안 함 — 그래도 즉시 true.
        XCTAssertTrue(s.onboardBalanceSchemaWarningActive,
                      "computed property — 매 read 시 즉시 평가 (cycle 168 stale 문제 해소)")
    }

    /// onboardBalanceSchemaVerified UserDefaults persistence.
    func testVerifiedPersistedToUserDefaults() {
        let s1 = WalkLabSession()
        s1.onboardBalanceSchemaVerified = true
        XCTAssertTrue(testDefaults.bool(forKey: key),
                      "set true → UserDefaults 에 즉시 저장")

        let s2 = WalkLabSession()
        XCTAssertTrue(s2.onboardBalanceSchemaVerified,
                      "신규 session 도 UserDefaults 에서 자동 복원")
    }

    /// false 로 set 도 persisted.
    func testVerifiedFalsePersisted() {
        testDefaults.set(true, forKey: key)
        let s = WalkLabSession()
        XCTAssertTrue(s.onboardBalanceSchemaVerified, "초기값 true 복원")
        s.onboardBalanceSchemaVerified = false
        XCTAssertFalse(testDefaults.bool(forKey: key),
                       "false 도 persist")
    }
}
