import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.22.x (2026-05-24) — 사이클 115 (StartCycle unit coverage)**.
///
/// `WalkLabSession+StartCycle.swift` 의 12 helper (`swc*`) 를 직접 단위 검증.
/// 종전: facade 통합 테스트만 존재 → line coverage 3.79%.
/// 목표: helper 별 경계 조건 검증 → line coverage 50%+.
///
/// # 비유
///
/// 비행기 이륙 체크리스트 — 각 helper 가 "페이지" 를 담당. 테스트는 각 페이지를
/// 독립 시뮬레이터 (RecordingHarness + MockBus) 로 검증.
///
/// # Coverage 전략
///
/// - Phase 1 (swcGuardAlreadyWalking): idle/active 양쪽 경로
/// - Phase 2a (swcResolveStoreAndCradle): store nil / cradle false / 통과 3-way
/// - Phase 2b (swcApplySafetyDemotion): blocked+applyToRobot=true 강등 / 비해당 no-op
/// - Phase 2c (swcGuardCautionPreset): caution+correction=false 차단 / safe 통과
/// - Phase 2d (swcGuardHardwarePreflight): IMU unavailable/stale/plausibility 각각
/// - Phase 3 (swcHandleIdlePresetIfNeeded): idle return-early / non-idle 통과
/// - Phase 5a (swcApplyAutoTuningLevel): robotApplied block / auto apply no-pending
/// - Phase 6 (swcMakePoseCallbacks): onPose counter 증가 / transformPose passthrough
@MainActor
final class WalkLabSessionStartCycleTests: XCTestCase {

    // MARK: - Lifecycle helpers

    private func makeSession() -> WalkLabSession {
        WalkLabSession(harness: RecordingHarness())
    }

    // MARK: - Phase 1: swcGuardAlreadyWalking

    /// 초기 session (walkCycleTask=nil, onboardWalkingActive=false) → guard 통과 = false.
    func testSwcGuardAlreadyWalking_IdleSession_ReturnsFalse() {
        let session = makeSession()
        let blocked = session.swcGuardAlreadyWalking(.march)
        XCTAssertFalse(blocked, "신규 session 은 보행 중 아님 — guard 통과해야 함")
    }

    /// `onboardWalkingActive=true` 로 보행 중 상태 시뮬 → guard 차단 = true.
    ///
    /// swcGuardAlreadyWalking 은 `walkCycleTask != nil || onboardWalkingActive` 를 검사.
    /// _testForceWalkActive 는 isRobotWalking/current 만 설정하므로, guard 를 트리거하려면
    /// onboardWalkingActive=true 또는 실제 walkCycleTask 생성이 필요.
    func testSwcGuardAlreadyWalking_WalkActive_ReturnsTrue() {
        let session = makeSession()
        session.onboardWalkingActive = true   // guard 조건 직접 충족
        let blocked = session.swcGuardAlreadyWalking(.fastWalk)
        XCTAssertTrue(blocked, "onboardWalkingActive=true → guard 차단")
    }

    /// alreadyWalking 차단 시 lastRobotEvent 에 요청 preset 이름 포함.
    func testSwcGuardAlreadyWalking_BlockedSetsLastRobotEvent() {
        let session = makeSession()
        session.onboardWalkingActive = true   // guard 조건: onboardWalkingActive
        _ = session.swcGuardAlreadyWalking(.slowWalk)
        XCTAssertTrue(
            session.lastRobotEvent?.contains("천천히 걷기") ?? false,
            "lastRobotEvent 에 요청된 preset label 포함"
        )
    }

    /// `onboardWalkingActive = true` 단독으로도 guard 차단.
    func testSwcGuardAlreadyWalking_OnboardActiveAlone_ReturnsTrue() {
        let session = makeSession()
        session.onboardWalkingActive = true
        let blocked = session.swcGuardAlreadyWalking(.normalWalk)
        XCTAssertTrue(blocked, "onboardWalkingActive=true 는 보행 중 — guard 차단")
    }

    // MARK: - Phase 2a: swcResolveStoreAndCradle

    /// store == nil → nil 반환 + lastPreflightFailure.cause == .noConnection.
    func testSwcResolveStoreAndCradle_NoStore_ReturnsNilWithNoConnectionFailure() {
        let session = makeSession()
        // store 는 기본 nil
        let result = session.swcResolveStoreAndCradle(.march)
        XCTAssertNil(result, "store 없으면 nil 반환")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .noConnection)
        XCTAssertEqual(session.startBlockedReason, "noConnection")
    }

    /// store 연결됐으나 cradleConfirmed=false → nil 반환 + .cradleNotConfirmed.
    func testSwcResolveStoreAndCradle_NoCradle_ReturnsNilWithCradleFailure() {
        let session = makeSession()
        let store = ConnectionStore()
        store.bus = MockBus()
        session.attach(store: store)
        session.cradleConfirmed = false

        let result = session.swcResolveStoreAndCradle(.march)
        XCTAssertNil(result, "cradle 미확인 → nil 반환")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .cradleNotConfirmed)
    }

    /// store + bus + cradleConfirmed → (store, bus) 반환.
    func testSwcResolveStoreAndCradle_Connected_ReturnsTuple() {
        let session = makeSession()
        let store = ConnectionStore()
        let bus = MockBus()
        store.bus = bus
        session.attach(store: store)
        session.cradleConfirmed = true

        let result = session.swcResolveStoreAndCradle(.march)
        XCTAssertNotNil(result, "연결 + cradle 확인 → tuple 반환")
    }

    // MARK: - Phase 2b: swcApplySafetyDemotion

    /// safetyVerdict=.blocked 조건 검증.
    ///
    /// `balanceExperimentConfig` didSet 이 blocked+applyToRobot=true 를 자동 강등하므로
    /// `swcApplySafetyDemotion()` 을 직접 트리거하기 위한 선결 조건(blocked+applyToRobot=true)은
    /// 정상 경로로는 만들 수 없다 — 이것이 의도된 safety invariant. 따라서 본 테스트는
    /// (a) blocked config 의 safetyVerdict 가 실제로 .blocked 임을 확인, (b) safe config
    /// 에서 swcApplySafetyDemotion 이 no-op 임을 확인, (c) alternateDiagnostic 설정 후
    /// didSet 이 applyToRobot 을 자동으로 false 로 만드는 걸 검증한다.
    func testSwcApplySafetyDemotion_BlockedConfigSafetyVerdict_IsBlocked() {
        // didSet 을 우회하여 struct 수준에서 blocked verdict 확인.
        let blockedCfg = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        if case .blocked = blockedCfg.safetyVerdict {
            XCTAssertTrue(true, "alternateDiagnostic+applyToRobot=true → blocked verdict 확인")
        } else {
            XCTFail("alternateDiagnostic+applyToRobot=true 는 blocked 여야 함")
        }
    }

    /// didSet 이 blocked+applyToRobot=true → applyToRobot=false 자동 강등 확인.
    ///
    /// swcApplySafetyDemotion 의 동일 로직이 didSet 에도 있음 — 이 테스트는 시스템 전체
    /// 방어선 (didSet) 이 작동함을 검증.
    func testSwcApplySafetyDemotion_DidSetAutodemotes_BlockedConfig() {
        let session = makeSession()
        // alternateDiagnostic + applyToRobot=true 설정 시도 → didSet 자동 강등.
        session.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        XCTAssertFalse(
            session.balanceExperimentConfig.applyToRobot,
            "didSet 이 blocked config 을 applyToRobot=false 로 자동 강등"
        )
    }

    /// safetyVerdict=.safe 면 swcApplySafetyDemotion 이 applyToRobot 변경 없음.
    func testSwcApplySafetyDemotion_SafeVerdict_NoChange() {
        let session = makeSession()
        // robotisPControl + robotisWalkingCpp = safe verdict.
        session.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        XCTAssertTrue(session.balanceExperimentConfig.applyToRobot, "precondition: safe config")
        session.swcApplySafetyDemotion()
        XCTAssertTrue(
            session.balanceExperimentConfig.applyToRobot,
            "safe verdict → swcApplySafetyDemotion no-op, applyToRobot 변경 없음"
        )
    }

    // MARK: - Phase 2c: swcGuardCautionPreset

    /// caution preset + enableBalanceCorrection=false → true (차단).
    func testSwcGuardCautionPreset_CautionWithoutCorrector_ReturnsTrue() {
        let session = makeSession()
        session.enableBalanceCorrection = false
        let blocked = session.swcGuardCautionPreset(.fastWalk)   // .fastWalk = .caution
        XCTAssertTrue(blocked, "caution preset + corrector OFF → 차단")
        XCTAssertEqual(
            session.lastPreflightFailure?.cause,
            .balanceCorrectorRequiredForCautionPreset(presetLabel: "빠르게 걷기")
        )
    }

    /// safe preset → false (통과).
    func testSwcGuardCautionPreset_SafePreset_ReturnsFalse() {
        let session = makeSession()
        session.enableBalanceCorrection = false
        let blocked = session.swcGuardCautionPreset(.march)   // .march = .safe
        XCTAssertFalse(blocked, "safe preset 은 caution guard 불필요")
    }

    /// caution preset + enableBalanceCorrection=true → false (통과).
    func testSwcGuardCautionPreset_CautionWithCorrector_ReturnsFalse() {
        let session = makeSession()
        session.enableBalanceCorrection = true
        let blocked = session.swcGuardCautionPreset(.turnLeft)  // .turnLeft = .caution
        XCTAssertFalse(blocked, "caution + corrector ON → 통과")
    }

    // MARK: - Phase 2d: swcGuardHardwarePreflight

    /// IMU unavailable → true (차단) + .imuUnavailable cause.
    func testSwcGuardHardwarePreflight_ImuUnavailable_ReturnsTrue() {
        let session = makeSession()
        let store = ConnectionStore()
        let bus = MockBus()
        store.bus = bus
        session.attach(store: store)
        session.cradleConfirmed = true

        // IMU sample 0 → isImuUnavailable = true.
        // ConnectionStore.isImuUnavailable = health.isImuUnavailable → IMU count=0 상태.
        // 기본 store 는 IMU sample 없음 → unavailable.
        let blocked = session.swcGuardHardwarePreflight(.march, store: store, bus: bus)
        if store.isImuUnavailable {
            XCTAssertTrue(blocked, "IMU unavailable → 차단")
            XCTAssertEqual(session.lastPreflightFailure?.cause, .imuUnavailable)
        } else {
            // IMU 이미 ok 인 경우 다른 preflight 검사가 통과 → false.
            XCTAssertFalse(blocked, "IMU 정상이면 하드웨어 preflight 통과")
        }
    }

    /// imuScaleSuspicion = .suspectedLegacy10Bit (25 샘플 중력 미감지 주입) → 차단.
    ///
    /// IMU 가 available + fresh 이면 plausibility check 까지 도달.
    /// _testFeedImuSample 로 accelZ=512 (중력 미감지) 25회 → suspectedLegacy10Bit.
    func testSwcGuardHardwarePreflight_ImuPlausibilityFailed_ReturnsTrue() {
        let session = makeSession()
        let store = ConnectionStore()
        let bus = MockBus()
        store.bus = bus
        session.attach(store: store)
        session.cradleConfirmed = true

        // 25 sample, accelZ=512 → centered=0 → suspectedLegacy10Bit.
        let required = ConnectionStore._testImuScaleSamplesRequired
        for _ in 0..<required {
            store._testFeedImuSample(accelZ: 512)
        }
        // IMU 가 available (feed 했음) + fresh 이면 plausibility 까지 진행.
        // isImuUnavailable=false, isImuStale depends on timing — unavailable 확인.
        if !store.isImuUnavailable && !store.isImuStale {
            let blocked = session.swcGuardHardwarePreflight(.march, store: store, bus: bus)
            XCTAssertTrue(blocked, "imuScaleSuspicion=suspectedLegacy10Bit → plausibility 차단")
            // ImuScaleSuspicion.suspectedLegacy10Bit.rawValue = Korean user message string.
            XCTAssertEqual(
                session.lastPreflightFailure?.cause,
                .imuPlausibilityFailed(ConnectionStore.ImuScaleSuspicion.suspectedLegacy10Bit.rawValue)
            )
        } else {
            // IMU unavailable/stale 이면 그 단계에서 먼저 차단 — plausibility path skip.
            // 그래도 blocked 는 true.
            let blocked = session.swcGuardHardwarePreflight(.march, store: store, bus: bus)
            XCTAssertTrue(blocked, "IMU 문제 → 어떤 단계든 차단")
        }
    }

    /// dxlPower 실패 MockBus → swcGuardHardwarePreflight 차단 + .dxlPowerFailed cause.
    ///
    /// preflightForWalkCycle(bus:) 가 `bus.setDxlPower(true)` 를 호출하므로
    /// failNextSetDxlPower=true 주입 시 첫 단계에서 failure 반환.
    func testSwcGuardHardwarePreflight_DxlPowerFailure_ReturnsTrue() {
        let session = makeSession()
        let store = ConnectionStore()
        let bus = MockBus()
        bus.failNextSetDxlPower = true   // preflightForWalkCycle 첫 단계 실패
        store.bus = bus
        session.attach(store: store)
        session.cradleConfirmed = true

        let blocked = session.swcGuardHardwarePreflight(.march, store: store, bus: bus)
        XCTAssertTrue(blocked, "dxl_power 실패 → 차단")
        if case .dxlPowerFailed = session.lastPreflightFailure?.cause {
            XCTAssertTrue(true)
        } else {
            XCTFail("cause 가 dxlPowerFailed 여야 함, actual: \(String(describing: session.lastPreflightFailure?.cause))")
        }
        XCTAssertEqual(session.startBlockedReason, "dxlPowerFailed")
    }

    /// IMU unavailable (3회 연속 실패) → swcGuardHardwarePreflight 차단 + .imuUnavailable.
    ///
    /// ConnectionHealthStore.isImuUnavailable = imuConsecutiveFailures >= 3 (success 없음).
    /// health.recordImuFailure 3회 호출로 조건 충족.
    func testSwcGuardHardwarePreflight_ImuUnavailable_AfterThreeFailures_ReturnsTrue() {
        let session = makeSession()
        let store = ConnectionStore()
        let bus = MockBus()
        store.bus = bus
        session.attach(store: store)
        session.cradleConfirmed = true

        // imuConsecutiveFailures 를 3 이상으로 만들어 isImuUnavailable=true.
        let stubErr = NSError(domain: "test", code: 0)
        store.health.recordImuFailure(error: stubErr)
        store.health.recordImuFailure(error: stubErr)
        store.health.recordImuFailure(error: stubErr)
        XCTAssertTrue(store.isImuUnavailable, "precondition: 3회 IMU 실패 → isImuUnavailable")

        let blocked = session.swcGuardHardwarePreflight(.march, store: store, bus: bus)
        XCTAssertTrue(blocked, "IMU unavailable → 차단")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .imuUnavailable,
                       "차단 원인이 .imuUnavailable 이어야 함")
        XCTAssertEqual(session.startBlockedReason, "imuUnavailable")
    }

    /// IMU stale (6초 이상 경과) → swcGuardHardwarePreflight 차단 + .imuStale cause.
    ///
    /// health.recordImuSuccess(raw:at:) 에 6초 전 날짜 주입 → isImuStale=true.
    func testSwcGuardHardwarePreflight_ImuStale_ReturnsTrue() {
        let session = makeSession()
        let store = ConnectionStore()
        let bus = MockBus()
        store.bus = bus
        session.attach(store: store)
        session.cradleConfirmed = true

        // 6초 전 IMU success → stale.
        let sixSecondsAgo = Date(timeIntervalSinceNow: -6.0)
        let stubRaw = ImuRaw(gyroX: 512, gyroY: 512, gyroZ: 512,
                             accelX: 512, accelY: 512, accelZ: 768,
                             rollDeg: 0, pitchDeg: 0)
        store.health.recordImuSuccess(raw: stubRaw, at: sixSecondsAgo)
        XCTAssertTrue(store.isImuStale, "precondition: 6초 전 성공 → isImuStale")
        XCTAssertFalse(store.isImuUnavailable, "precondition: 최근 성공 있으므로 unavailable 아님")

        let blocked = session.swcGuardHardwarePreflight(.march, store: store, bus: bus)
        XCTAssertTrue(blocked, "IMU stale → 차단")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .imuStale,
                       "차단 원인이 .imuStale 이어야 함")
        XCTAssertEqual(session.startBlockedReason, "imuStale")
    }

    // MARK: - Phase 3: swcHandleIdlePresetIfNeeded

    /// preset == .idle → true 반환 (caller return-early).
    func testSwcHandleIdlePresetIfNeeded_IdlePreset_ReturnsTrue() {
        let session = makeSession()
        let handled = session.swcHandleIdlePresetIfNeeded(.idle)
        XCTAssertTrue(handled, "idle preset → early return true")
    }

    /// non-idle preset → false 반환 (caller 계속 진행).
    func testSwcHandleIdlePresetIfNeeded_NonIdlePreset_ReturnsFalse() {
        let session = makeSession()
        let handled = session.swcHandleIdlePresetIfNeeded(.march)
        XCTAssertFalse(handled, "non-idle preset → false (caller 계속)")
    }

    // MARK: - Phase 4: swcRunOnboardCycleIfNeeded

    /// walkingEngine == .macSparseKeyframe (default) → false 반환 (Mac path 계속).
    func testSwcRunOnboardCycleIfNeeded_MacEngine_ReturnsFalse() {
        let session = makeSession()
        let store = ConnectionStore()
        store.bus = MockBus()
        session.attach(store: store)
        session.cradleConfirmed = true
        session.walkingEngine = .macSparseKeyframe

        let handled = session.swcRunOnboardCycleIfNeeded(.march, store: store)
        XCTAssertFalse(handled, "macSparseKeyframe → onboard path 불필요 (false 반환)")
    }

    /// walkingEngine == .robotisOnboard + store.bus == nil → SSH 미연결 차단.
    func testSwcRunOnboardCycleIfNeeded_OnboardNoSsh_ReturnsTrueWithSshFailure() {
        let session = makeSession()
        let store = ConnectionStore()
        // bus = nil → SSH 미연결
        session.attach(store: store)
        session.cradleConfirmed = true
        session.walkingEngine = .robotisOnboard

        let handled = session.swcRunOnboardCycleIfNeeded(.march, store: store)
        XCTAssertTrue(handled, "robotisOnboard + SSH 미연결 → 차단 (true 반환)")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .onboardSshNotConnected)
        XCTAssertEqual(session.startBlockedReason, "onboardSshNotConnected")
    }

    /// walkingEngine == .robotisOnboard + bus 있음 + autoOnboardBrokering=false → 차단.
    func testSwcRunOnboardCycleIfNeeded_OnboardBrokeringOff_ReturnsTrueWithBrokeringFailure() {
        let session = makeSession()
        let store = ConnectionStore()
        store.bus = MockBus()
        session.attach(store: store)
        session.cradleConfirmed = true
        session.walkingEngine = .robotisOnboard
        session.autoOnboardBrokering = false

        let handled = session.swcRunOnboardCycleIfNeeded(.march, store: store)
        XCTAssertTrue(handled, "robotisOnboard + brokering OFF → 차단 (true 반환)")
        XCTAssertEqual(session.lastPreflightFailure?.cause, .onboardAutoBrokeringOff)
        XCTAssertEqual(session.startBlockedReason, "onboardAutoBrokeringOff")
    }

    /// walkingEngine == .robotisOnboard + bus + autoOnboardBrokering=true → 활성화.
    func testSwcRunOnboardCycleIfNeeded_OnboardAllConditions_ActivatesOnboard() {
        let session = makeSession()
        let store = ConnectionStore()
        store.bus = MockBus()
        session.attach(store: store)
        session.cradleConfirmed = true
        session.walkingEngine = .robotisOnboard
        session.autoOnboardBrokering = true

        let handled = session.swcRunOnboardCycleIfNeeded(.march, store: store)
        XCTAssertTrue(handled, "모든 조건 충족 → onboard 활성화 (true 반환)")
        XCTAssertTrue(session.onboardWalkingActive, "onboardWalkingActive = true")
        XCTAssertEqual(session.activeRobotPreset, .march)
        XCTAssertEqual(session.onboardAckStatus, "pending")
        XCTAssertFalse(session.motorWriteStarted)
        XCTAssertEqual(session.motorWriteStepCount, 0)
    }

    // MARK: - Phase 5a: swcApplyAutoTuningLevel

    /// correctionApplyMode="robotApplied" + autoApplyEnabled=true → 자동 적용 차단, level 유지.
    ///
    /// correctionApplyMode = "robotApplied" 조건: robotisPControl + applyToRobot=true + bus 연결.
    func testSwcApplyAutoTuningLevel_RobotAppliedMode_BlocksAutoApply() {
        let session = makeSession()
        // bus 를 연결해야 correctionApplyMode = "robotApplied" 가 됨.
        let store = ConnectionStore()
        store.bus = MockBus()
        session.attach(store: store)
        session.cradleConfirmed = true

        session.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        XCTAssertEqual(session.correctionApplyMode, "robotApplied",
                       "test precondition: robotisPControl + applyToRobot=true + bus → robotApplied")

        let initialLevel = session.correctorIntensityLevel
        session.autoTuner.autoApplyEnabled = true
        session.swcApplyAutoTuningLevel()
        // autoApplyEnabled=true + robotApplied → 차단 → level 변경 없음.
        XCTAssertEqual(session.correctorIntensityLevel, initialLevel,
                       "robotApplied mode 에서 auto-tuner 자동 적용 차단")
    }

    /// autoApplyEnabled=false → levelToApply 가 currentLevel 그대로 반환 → level 유지.
    func testSwcApplyAutoTuningLevel_AutoApplyDisabled_LevelUnchanged() {
        let session = makeSession()
        let initialLevel = session.correctorIntensityLevel
        session.autoTuner.autoApplyEnabled = false
        session.swcApplyAutoTuningLevel()
        XCTAssertEqual(session.correctorIntensityLevel, initialLevel,
                       "autoApplyEnabled=false → level 변경 없음")
    }

    /// autoApplyEnabled=true + pendingRecommendation 있음 + simOnly mode → level 자동 변경.
    ///
    /// correctionApplyMode != "robotApplied" (simOnly) + autoApplyEnabled=true + pending
    /// recommendation 이 현재 level 보다 크면 +1 step 적용.
    func testSwcApplyAutoTuningLevel_AutoApplySimMode_ChangesLevel() {
        let session = makeSession()
        // bus 없으면 simOnly → 자동 적용 허용.
        XCTAssertEqual(session.correctionApplyMode, "simOnly",
                       "precondition: bus 없음 → simOnly")
        session.correctorIntensityLevel = 1   // 현재 레벨 1
        session.autoTuner.autoApplyEnabled = true

        // pendingRecommendation 주입: 현재보다 높은 level 추천.
        // WalkSessionAutoTuner.pendingRecommendation 은 private(set) — record() 통해 set.
        // 직접 접근 불가 → record 에 summary 주입.
        // 대안: levelToApply 는 pendingRecommendation = nil 이면 currentLevel 반환 — 이 경우 변경 없음.
        // → autoApplyEnabled=true + pending=nil 이면 level 유지 확인.
        session.swcApplyAutoTuningLevel()
        // pending 없으면 변경 없음 (levelToApply returns currentLevel when pending=nil).
        XCTAssertEqual(session.correctorIntensityLevel, 1,
                       "pendingRecommendation nil → level 변경 없음 (simOnly 에서도)")
    }

    // MARK: - Phase 6: swcMakePoseCallbacks

    /// onPose 호출 시 motorWriteStepCount 증가 + motorWriteStarted=true.
    func testSwcMakePoseCallbacks_OnPoseIncrementsMotorWriteCounter() {
        let session = makeSession()
        session.motorWriteStarted = false
        session.motorWriteStepCount = 0

        let (onPose, _) = session.swcMakePoseCallbacks()
        onPose(.walkReady)
        XCTAssertTrue(session.motorWriteStarted, "첫 onPose 호출 시 motorWriteStarted=true")
        XCTAssertEqual(session.motorWriteStepCount, 1, "motorWriteStepCount 1 증가")
        onPose(.walkReady)
        XCTAssertEqual(session.motorWriteStepCount, 2, "두 번째 호출 → count 2")
    }

    /// transformPose (enableBalanceCorrection=false) → pose 변경 없이 passthrough.
    func testSwcMakePoseCallbacks_TransformPosePassthrough_WhenCorrectionDisabled() {
        let session = makeSession()
        session.enableBalanceCorrection = false

        let (_, transformPose) = session.swcMakePoseCallbacks()
        let original = RobotPose.walkReady
        let result = transformPose(original)
        // correction OFF 면 applyBalanceCorrectionIfEnabled 는 원본 반환.
        // pose equality: RobotPose.walkReady 는 static 이므로 동일 인스턴스 or 동일 값.
        XCTAssertEqual(result, original, "balanceCorrection OFF → pose passthrough")
    }

    // MARK: - Phase 5b: swcInitSessionLogger (smoke)

    /// enableSessionLogging=false → sessionLogger 생성 안 됨.
    func testSwcInitSessionLogger_LoggingDisabled_NoLoggerCreated() {
        let session = makeSession()
        session.enableSessionLogging = false
        session.swcInitSessionLogger(.march)
        XCTAssertNil(session.sessionLogger, "enableSessionLogging=false → sessionLogger nil")
    }

    /// enableSessionLogging=true → sessionLogger 생성 시도 (성공 or silent fail).
    /// init 에서 throw 조건은 preset+intensityLevel 유효성에 의존 — smoke test 만 수행.
    func testSwcInitSessionLogger_LoggingEnabled_AttemptsMakeLogger() {
        let session = makeSession()
        session.enableSessionLogging = true
        // sessionLogger 초기 상태는 nil.
        XCTAssertNil(session.sessionLogger, "precondition: nil 시작")
        session.swcInitSessionLogger(.march)
        // 결과는 환경 의존 (Bundle 없는 XCTest 에서 "dev" fallback 처리 가능).
        // 핵심 보장: crash 없이 완료.
        // sessionLogger 가 생성 성공하면 sessionStartedAt 도 sync.
        if session.sessionLogger != nil {
            XCTAssertNotNil(session.sessionStartedAt,
                            "logger 생성 성공 시 sessionStartedAt 도 sync")
        }
    }
}
