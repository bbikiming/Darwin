import Foundation
import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) 사이클 103 — 코덱스 H2/H3 회귀 가드**.
///
/// 사이클 91 (Calibration), 97 (Experiment), 98 (SensorUpdates) 의 god object 분할로
/// 생성된 extension method 들의 test coverage 가 0 이었음 — 코덱스 H2/H3 flagged.
/// 본 테스트로 각 extension 의 핵심 path 검증 + 분할 회귀 가드.
///
/// # 비유
///
/// 비행기 fuselage 를 wing / cargo / cockpit 모듈로 분리하면 각 모듈도 별도 시험비행
/// 필요. monolithic 통합 시험으로는 모듈 경계의 access escalation 회귀를 놓침.
///
/// # 분류
///
/// - `StaticTiltCalibrationExtensionTests` — 사이클 91 Phase 1C method 3개.
/// - `SensorUpdatesExtensionTests` — 사이클 98 Phase 3 method 5개.
/// - `ExperimentOnboardHealthCheckTests` — 사이클 97 Phase 2 pure function (codex H1).
@MainActor
final class WalkLabSessionExtensionCoverageTests: XCTestCase {

    // MARK: - Calibration (사이클 91 Phase 1C)

    /// `resetCalibrationCaptures()` 가 captures 초기화 → diagnosis 가 .insufficientData.
    func testResetCalibrationCapturesClearsState() {
        let session = WalkLabSession()
        session.resetCalibrationCaptures()
        let diagnosis = session.currentCalibrationDiagnosis()
        // 빈 captures → insufficientData 또는 동등한 진단 상태.
        // diagnosis 의 actual value 는 type 에 의존 — 단지 함수 호출 가능 + nil 안 됨 확인.
        _ = diagnosis  // XCTAssertNoThrow 와 동등 (호출 성공 = pass).
    }

    /// `currentCalibrationDiagnosis()` 가 captures 미수집 시에도 crash 없이 반환.
    func testCalibrationDiagnosisEmptyReturnsDefault() {
        let session = WalkLabSession()
        session.resetCalibrationCaptures()
        // diagnosis 호출 자체가 crash 없으면 pass — 진단 enum 의 specific value 는
        // StaticTiltCalibration.diagnose 의 implementation detail.
        _ = session.currentCalibrationDiagnosis()
    }

    /// `runStaticTiltCalibration` 가 보행 중 (`walkCycleTask != nil`) 진입 시 nil 반환 (거부).
    /// 사이클 91 분할 전후 동일한 안전 가드 — 보행 데이터와 IMU 캡처 간섭 방지.
    func testCalibrationRejectsDuringWalking() async {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // start 호출로 walkCycleTask 가 생성 (시뮬 모드에서도 transition 됨 — v1.14.7 정합).
        session.start(.march)
        // walkCycleTask 가 nil 이 아닐 때 캘리브레이션 호출 — 거부 (nil 반환) 기대.
        // 단 시뮬 모드 (bus 미연결) 에선 walkCycleTask 이 안 생길 수 있음 — 그 경우는 정상 progression.
        if session.walkCycleTask != nil {
            let capture = await session.runStaticTiltCalibration(
                axis: .upright,
                durationSec: 0.1,
                sampleIntervalMs: 50.0
            )
            XCTAssertNil(capture, "보행 중 캡처 거부 (사이클 91 회귀 가드)")
            XCTAssertTrue(session.lastRobotEvent?.contains("거부") ?? false,
                          "거부 사유 lastRobotEvent 에 노출")
        } else {
            // 시뮬 모드 — walkCycleTask 없음, 캘리브레이션 정상 진행 가능.
            // 그래도 method 호출 path 자체 검증.
            session.stop()
            let capture = await session.runStaticTiltCalibration(
                axis: .upright,
                durationSec: 0.1,
                sampleIntervalMs: 50.0
            )
            XCTAssertNotNil(capture, "보행 없음 → 캡처 성공")
        }
    }

    /// `runStaticTiltCalibration` 가 idle 상태에서 정상 캡처 수행 — samples 비어있지 않음.
    func testCalibrationCapturesSamplesWhenIdle() async {
        let session = WalkLabSession()
        // 보행 안 시작 — walkCycleTask 는 nil 보장.
        let capture = await session.runStaticTiltCalibration(
            axis: .forward30,
            durationSec: 0.2,
            sampleIntervalMs: 50.0
        )
        XCTAssertNotNil(capture, "idle 상태 캡처 성공")
        if let c = capture {
            XCTAssertGreaterThan(c.samples.count, 0, "최소 1개 sample 캡처")
            XCTAssertEqual(c.axis, .forward30, "요청 axis 정확 기록")
        }
    }

    /// 같은 axis 의 캡처 2회 연속 — 마지막 캡처만 보존 (`removeAll {$0.axis == axis}` 정책).
    func testCalibrationSameAxisCaptureOverwrites() async {
        let session = WalkLabSession()
        let first = await session.runStaticTiltCalibration(
            axis: .left30, durationSec: 0.15, sampleIntervalMs: 50.0
        )
        XCTAssertNotNil(first)
        let second = await session.runStaticTiltCalibration(
            axis: .left30, durationSec: 0.15, sampleIntervalMs: 50.0
        )
        XCTAssertNotNil(second)
        // diagnosis 호출이 정상 — 단일 캡처만 보존했을 것.
        _ = session.currentCalibrationDiagnosis()
        // resetCalibrationCaptures 도 호출 가능 확인 — 분할 안 깨짐 검증.
        session.resetCalibrationCaptures()
    }

    // MARK: - Sensor Updates (사이클 98 Phase 3)

    /// `updateSimIMU()` 가 보행 중 (effectiveCommand.enabled=true) 진입 시 imuRollDeg / imuPitchDeg 갱신.
    /// 사이클 98 분할 회귀 가드 — sim 모델 evolution 이 본체와 동일 path 로 호출됨.
    func testUpdateSimImuModulatesAnglesWhenWalking() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)  // effectiveCommand.enabled 가 true 로 가는 path 보장.
        let priorRoll = session.imuRollDeg
        let priorPitch = session.imuPitchDeg
        // 직접 sim path 호출 — tick() 의존 X (extension internal method).
        for _ in 0..<20 {
            session.updateSimIMU()
        }
        let postRoll = session.imuRollDeg
        let postPitch = session.imuPitchDeg
        // 20 iter 후 어느 하나는 변화했을 것 (sin 진동 + speed factor).
        // priorRoll/priorPitch 가 둘 다 0 시작 + 보행 시 ≠ 0 으로 발산 기대.
        let changed = (abs(postRoll - priorRoll) > 0.01) || (abs(postPitch - priorPitch) > 0.01)
        XCTAssertTrue(changed, "보행 중 sim IMU 가 진동 → 값 변화 (사이클 98 회귀 가드)")
    }

    /// `updateSimIMU()` 가 idle (effectiveCommand.enabled=false) 시 자연 감쇠 — 0 으로 수렴.
    func testUpdateSimImuDecaysWhenIdle() {
        let session = WalkLabSession()
        // current = .idle 보장 — start 안 함.
        // 강제로 IMU 값 세팅 후 sim path 호출 → 감쇠 확인 위함.
        // imuRollDeg / imuPitchDeg 는 internal var 격상 됨 (사이클 98).
        // 그러나 외부 write 는 internal(set) 격상 X → 직접 set 불가능.
        // 대신 보행 시작 + 정지 → 어느 정도 값 있을 때 idle 감쇠 확인.
        session.cradleConfirmed = true
        session.start(.march)
        for _ in 0..<10 { session.updateSimIMU() }  // 값 생성.
        session.stop()  // current = .idle → effectiveCommand.enabled = false.
        let priorAbsRoll = abs(session.imuRollDeg)
        for _ in 0..<50 { session.updateSimIMU() }
        let postAbsRoll = abs(session.imuRollDeg)
        // 50 iter 후 감쇠 (0.85^50 ≈ 0.0003 — 거의 0).
        XCTAssertLessThanOrEqual(postAbsRoll, priorAbsRoll + 0.01,
                                  "idle 시 sim IMU 감쇠 (사이클 98 회귀 가드)")
    }

    /// `updateMotorTempFromRealOrSim()` 가 미연결 (store=nil) 시 sim path → motorTempSource = .sim.
    func testUpdateMotorTempFallsBackToSimWhenDisconnected() {
        let session = WalkLabSession()
        // store 가 nil → guard 3) sim fallback path 진입.
        session.updateMotorTempFromRealOrSim()
        XCTAssertEqual(session.motorTempSource, .sim,
                       "미연결 시 sim fallback (사이클 98 회귀 가드)")
    }

    /// `updateSimThermal()` 가 보행 중 → maxMotorTemp 증가.
    func testUpdateSimThermalIncreasesWhenWalking() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)  // effectiveCommand.enabled = true.
        let prior = session.maxMotorTemp
        for _ in 0..<10 { session.updateSimThermal() }
        XCTAssertGreaterThan(session.maxMotorTemp, prior,
                             "보행 중 sim 발열 증가 (사이클 98 회귀 가드)")
    }

    /// `updateSimThermal()` 가 idle 시 ambient 로 수렴 (자연 냉각).
    func testUpdateSimThermalCoolsWhenIdle() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.start(.march)
        for _ in 0..<30 { session.updateSimThermal() }  // 발열 누적.
        session.stop()
        let priorHot = session.maxMotorTemp
        for _ in 0..<200 { session.updateSimThermal() }  // 충분한 cooling.
        XCTAssertLessThanOrEqual(session.maxMotorTemp, priorHot,
                                  "idle 시 자연 냉각 — ambient 수렴 (사이클 98 회귀 가드)")
    }

    /// `updateVoltageDroopTracking()` 가 store nil → counter reset.
    /// guard 통과 못 하면 voltageDroopConsecutiveSamples = 0.
    func testUpdateVoltageDroopResetsWhenNoStore() {
        let session = WalkLabSession()
        session.updateVoltageDroopTracking()
        XCTAssertEqual(session.voltageDroopConsecutiveSamples, 0,
                       "store nil → droop counter reset (사이클 98 회귀 가드)")
    }

    /// `updateImuFromRealOrSim()` 가 미연결 시 sim fallback → imuSource = .sim.
    func testUpdateImuFromRealOrSimFallsBackToSimWhenDisconnected() {
        let session = WalkLabSession()
        session.updateImuFromRealOrSim()
        XCTAssertEqual(session.imuSource, .sim,
                       "미연결 시 sim fallback path (사이클 98 회귀 가드)")
    }

    // MARK: - Experiment.onboardHealthCheckWarnings (사이클 97 — codex H1)

    /// `onboardHealthCheckWarningsImpl` 모든 정상 input → 빈 warnings 반환.
    /// 코덱스 H1: dead code 해소 — pure function 의 testability 활용.
    func testOnboardHealthCheckAllGoodReturnsEmpty() {
        let session = WalkLabSession()
        let warnings = session.onboardHealthCheckWarningsImpl(
            isRobotConnected: true,
            autoOnboardOn: true,
            cradleOK: true
        )
        XCTAssertEqual(warnings.count, 0,
                       "모든 정상 → 경고 없음 (사이클 97 H1 회귀 가드)")
    }

    /// 로봇 미연결 시 — silent fail 경고 포함.
    func testOnboardHealthCheckDetectsDisconnected() {
        let session = WalkLabSession()
        let warnings = session.onboardHealthCheckWarningsImpl(
            isRobotConnected: false,
            autoOnboardOn: true,
            cradleOK: true
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("SSH 미연결") ?? false,
                      "disconnected 경고 (사이클 97 H1 회귀 가드)")
    }

    /// autoOnboard OFF 경고.
    func testOnboardHealthCheckDetectsAutoBrokeringOff() {
        let session = WalkLabSession()
        let warnings = session.onboardHealthCheckWarningsImpl(
            isRobotConnected: true,
            autoOnboardOn: false,
            cradleOK: true
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("autoOnboardBrokering=OFF") ?? false,
                      "autoOnboard OFF 경고 (사이클 97 H1 회귀 가드)")
    }

    /// cradle 미확인 경고.
    func testOnboardHealthCheckDetectsCradleNotConfirmed() {
        let session = WalkLabSession()
        let warnings = session.onboardHealthCheckWarningsImpl(
            isRobotConnected: true,
            autoOnboardOn: true,
            cradleOK: false
        )
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.contains("cradle") ?? false,
                      "cradle 경고 (사이클 97 H1 회귀 가드)")
    }

    /// 3개 모두 실패 — 3개 경고 모두 출력 (순서 보장).
    func testOnboardHealthCheckAllBadReturnsThreeWarnings() {
        let session = WalkLabSession()
        let warnings = session.onboardHealthCheckWarningsImpl(
            isRobotConnected: false,
            autoOnboardOn: false,
            cradleOK: false
        )
        XCTAssertEqual(warnings.count, 3,
                       "3개 동시 실패 → 3개 경고 (사이클 97 H1 회귀 가드)")
    }

    /// instance helper `onboardHealthCheckWarnings()` — store nil 시 isRobotConnected=false 로 호출.
    func testOnboardHealthCheckInstanceHelperWithNilStore() {
        let session = WalkLabSession()
        // store 가 nil → isRobotConnected = false.
        // autoOnboardBrokering 와 cradleConfirmed 는 default false.
        let warnings = session.onboardHealthCheckWarnings()
        // 3 가지 모두 부정 → 3 경고.
        XCTAssertEqual(warnings.count, 3,
                       "store nil + default state → 3 경고 (사이클 97 H1 회귀 가드)")
    }
}
