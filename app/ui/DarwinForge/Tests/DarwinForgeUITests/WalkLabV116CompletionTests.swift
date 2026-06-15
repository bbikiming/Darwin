import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.6 (2026-05-18) — 4건 fix 회귀 가드**.
///
/// 1. Custom gainProfile expert slider — 4 gain didSet trigger 시 corrector 재생성
/// 2. autoOnboardBrokering @Published default OFF
/// 3. monitoringExpanded default true (UserDefaults 미설정 시)
/// 4. Custom gain 이 실제 corrector 에 반영
@MainActor
final class WalkLabV116CompletionTests: XCTestCase {

    /// 테스트 격리용 고유 UserDefaults suite — `--parallel` 시 다른 클래스와의
    /// `df.walklab.*` 키 공유 오염 방지. WalkLabSession 이 이 suite 로 영속화.
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "test.walklab.v116.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
        await MainActor.run { WalkLabSession.testDefaultsOverride = testDefaults }
    }

    override func tearDown() async throws {
        await MainActor.run { WalkLabSession.testDefaultsOverride = nil }
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - 1. Custom gain didSet → corrector 재생성

    /// **회귀 가드**: gainProfile=.custom 일 때 customHipRollGain 변경 → corrector 재생성.
    func testCustomGainProfileAppliesUserHipRollGain() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .custom,
            applyToRobot: true
        )
        // 사용자 지정 — 0.5 (default) → 1.5 변경.
        s.customHipRollGain = 1.5
        XCTAssertEqual(s.balanceCorrector.hipRollGain, 1.5, accuracy: 1e-9,
            ".custom + customHipRollGain=1.5 → corrector.hipRollGain=1.5")
    }

    /// **회귀 가드**: .custom 아닐 때 customGain 변경해도 corrector unchanged.
    func testCustomGainIgnoredWhenProfileNotCustom() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,  // .custom 아님
            applyToRobot: true
        )
        let beforeHipRoll = s.balanceCorrector.hipRollGain  // robotisOriginal = 0.5
        s.customHipRollGain = 1.5  // .custom 아니라 reject
        XCTAssertEqual(s.balanceCorrector.hipRollGain, beforeHipRoll, accuracy: 1e-9,
            ".robotisOriginal + customHipRollGain=1.5 → corrector unchanged")
    }

    /// 4 axis 각각 검증.
    func testAllFourCustomGainsApply() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .custom,
            applyToRobot: true
        )
        s.customHipRollGain = 0.8
        s.customKneeGain = 0.6
        s.customAnklePitchGain = 1.2
        s.customAnkleRollGain = 0.7
        XCTAssertEqual(s.balanceCorrector.hipRollGain, 0.8, accuracy: 1e-9)
        XCTAssertEqual(s.balanceCorrector.kneeGain, 0.6, accuracy: 1e-9)
        XCTAssertEqual(s.balanceCorrector.anklePitchGain, 1.2, accuracy: 1e-9)
        XCTAssertEqual(s.balanceCorrector.ankleRollGain, 0.7, accuracy: 1e-9)
    }

    // MARK: - 2. autoOnboardBrokering default

    /// **회귀 가드**: autoOnboardBrokering default OFF (안전).
    func testAutoOnboardBrokeringDefaultsOff() {
        let s = WalkLabSession()
        XCTAssertFalse(s.autoOnboardBrokering,
            "default OFF — 사용자가 명시 ON 후에만 SSH 자동 send")
    }

    // MARK: - 3. monitoringExpanded default

    /// **회귀 가드 — UserDefaults 미설정 시 default true**.
    /// (단일 process 안에서 UserDefaults 변경 — 격리 보장 위해 unique key 사용)
    func testMonitoringExpandedDefaultsTrueWhenUnset() {
        let key = "df.walklab.monitoringExpanded"
        testDefaults.removeObject(forKey: key)
        let s = WalkLabSession()
        XCTAssertTrue(s.monitoringExpanded,
            "UserDefaults 미설정 시 monitoringExpanded default = true (v1.11.6 UX fix)")
        // 부작용: init 이 UserDefaults 에 true 를 write — 검증.
        XCTAssertTrue(testDefaults.bool(forKey: key),
            "init 이 UserDefaults 에 true 저장 — persistence 보장")
    }

    /// **회귀 가드 — UserDefaults 명시 false 면 false 유지** (사용자 선택 보존).
    func testMonitoringExpandedRespectsExplicitFalse() {
        let key = "df.walklab.monitoringExpanded"
        testDefaults.set(false, forKey: key)
        let s = WalkLabSession()
        XCTAssertFalse(s.monitoringExpanded,
            "사용자가 false 설정한 경우 보존")
    }

    // MARK: - 4. WalkingEngineCommand round-trip (Sample → cmd)

    /// **회귀 가드**: customGain 값들이 WalkingEngineCommand 의 hipPitchOffset 과 독립.
    /// 즉 두 시스템 (balance corrector / robot walking onboard) 가 separate 한 trim.
    func testCustomGainAndHipPitchOffsetAreIndependent() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .custom,
            applyToRobot: true
        )
        s.customHipRollGain = 1.0
        s.hipPitchOffsetTrimDeg = 5.0
        s.current = .march
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        // hipPitchOffsetDeg 는 trim 값 그대로 (gain 과 무관).
        XCTAssertEqual(cmd.hipPitchOffsetDeg, 5.0, accuracy: 0.01)
        // corrector.hipRollGain 은 custom 값.
        XCTAssertEqual(s.balanceCorrector.hipRollGain, 1.0, accuracy: 1e-9)
    }
}
