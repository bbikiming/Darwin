import XCTest
@testable import DarwinForgeUI

/// Auto Fall-Recovery 순수 로직 유닛 테스트.
///
/// 실 robot 없이 실행 가능 (AutoFallRecovery 는 순수 함수 네임스페이스).
///
/// # 검증 항목
/// - `detectFall`: pitch ±60 → direction, ±30 → nil, boundary ±55
/// - `getUpPage`: .forward == 10, .backward == 11 (공식 페이지 번호 명시 검증)
/// - `isSettled`: hypot 기반 30 dps 임계
/// - `RecoveryPhase` Equatable
final class AutoFallRecoveryTests: XCTestCase {

    // MARK: - detectFall

    func testDetectFall_forwardAboveThreshold() {
        let result = AutoFallRecovery.detectFall(pitchDeg: 60.0)
        XCTAssertEqual(result, .forward,
            "pitch +60° (> 55° threshold) 는 .forward 낙하")
    }

    func testDetectFall_backwardAboveThreshold() {
        let result = AutoFallRecovery.detectFall(pitchDeg: -60.0)
        XCTAssertEqual(result, .backward,
            "pitch -60° (< -55° threshold) 는 .backward 낙하")
    }

    func testDetectFall_noFallSmallAngle() {
        let result = AutoFallRecovery.detectFall(pitchDeg: 30.0)
        XCTAssertNil(result,
            "pitch +30° 는 threshold(55°) 미만 — 낙하 아님")
    }

    func testDetectFall_noFallNegativeSmallAngle() {
        let result = AutoFallRecovery.detectFall(pitchDeg: -30.0)
        XCTAssertNil(result,
            "pitch -30° 는 threshold(-55°) 초과 — 낙하 아님")
    }

    func testDetectFall_boundaryExactForward() {
        // 경계값 포함 (>=)
        XCTAssertEqual(AutoFallRecovery.detectFall(pitchDeg: 55.0), .forward,
            "pitch == +55° 는 정확히 경계 — .forward")
    }

    func testDetectFall_boundaryExactBackward() {
        XCTAssertEqual(AutoFallRecovery.detectFall(pitchDeg: -55.0), .backward,
            "pitch == -55° 는 정확히 경계 — .backward")
    }

    func testDetectFall_justBelowBoundary() {
        XCTAssertNil(AutoFallRecovery.detectFall(pitchDeg: 54.99),
            "pitch 54.99° 는 threshold 미만 — nil")
    }

    func testDetectFall_justAboveBoundaryNegative() {
        XCTAssertNil(AutoFallRecovery.detectFall(pitchDeg: -54.99),
            "pitch -54.99° 는 threshold 초과 (abs 미만) — nil")
    }

    func testDetectFall_zero() {
        XCTAssertNil(AutoFallRecovery.detectFall(pitchDeg: 0.0),
            "pitch 0° — 낙하 아님")
    }

    // MARK: - getUpPage (ROBOTIS 공식 검증 — 절대 변경 불가)

    /// **CRITICAL**: ROBOTIS-OP2 공식 page 번호 직접 검증.
    /// motion_4096.bin 파싱 + firmware backup 검증으로 확정.
    /// page 12/13 은 kick (rk/lk) — get-up 절대 사용 불가.
    func testGetUpPage_forwardIsPage10() {
        XCTAssertEqual(AutoFallRecovery.FallDirection.forward.getUpPage, 10,
            "FORWARD get-up = page 10 ('f up') — ROBOTIS 공식 검증값")
    }

    func testGetUpPage_backwardIsPage11() {
        XCTAssertEqual(AutoFallRecovery.FallDirection.backward.getUpPage, 11,
            "BACKWARD get-up = page 11 ('b up') — ROBOTIS 공식 검증값")
    }

    func testGetUpPage_neverKickPages() {
        // kick 페이지 12/13 이 아님을 명시 검증
        XCTAssertNotEqual(AutoFallRecovery.FallDirection.forward.getUpPage, 12,
            "forward get-up 은 kick page 12(rk) 가 절대 아님")
        XCTAssertNotEqual(AutoFallRecovery.FallDirection.forward.getUpPage, 13,
            "forward get-up 은 kick page 13(lk) 가 절대 아님")
        XCTAssertNotEqual(AutoFallRecovery.FallDirection.backward.getUpPage, 12,
            "backward get-up 은 kick page 12(rk) 가 절대 아님")
        XCTAssertNotEqual(AutoFallRecovery.FallDirection.backward.getUpPage, 13,
            "backward get-up 은 kick page 13(lk) 가 절대 아님")
    }

    // MARK: - isSettled

    func testIsSettled_belowThreshold() {
        XCTAssertTrue(AutoFallRecovery.isSettled(gyroXDps: 10.0, gyroYDps: 10.0),
            "hypot(10,10) = 14.1 < 30 dps — 정착됨")
    }

    func testIsSettled_aboveThreshold() {
        XCTAssertFalse(AutoFallRecovery.isSettled(gyroXDps: 25.0, gyroYDps: 25.0),
            "hypot(25,25) ≈ 35.4 > 30 dps — 미정착")
    }

    func testIsSettled_exactThreshold() {
        // hypot(x,0) = x, 30.0 < 30.0 는 false
        XCTAssertFalse(AutoFallRecovery.isSettled(gyroXDps: 30.0, gyroYDps: 0.0),
            "hypot(30,0) = 30.0 — threshold (< 30) 미충족, 미정착")
    }

    func testIsSettled_zero() {
        XCTAssertTrue(AutoFallRecovery.isSettled(gyroXDps: 0.0, gyroYDps: 0.0),
            "gyro 0 — 완전 정착")
    }

    func testIsSettled_customThreshold() {
        XCTAssertTrue(AutoFallRecovery.isSettled(gyroXDps: 8.0, gyroYDps: 5.0, thresholdDps: 10.0),
            "hypot(8,5) ≈ 9.4 < custom threshold 10 — 정착됨")
        XCTAssertFalse(AutoFallRecovery.isSettled(gyroXDps: 8.0, gyroYDps: 5.0, thresholdDps: 9.0),
            "hypot(8,5) ≈ 9.4 > custom threshold 9 — 미정착")
    }

    // MARK: - 상수 값 명시 검증

    func testConstants_fallenThreshold() {
        XCTAssertEqual(AutoFallRecovery.fallenThresholdDeg, 55.0,
            "낙하 임계 55° — L3(50°) 보다 높게 설정")
    }

    func testConstants_settleGyroDps() {
        XCTAssertEqual(AutoFallRecovery.settleGyroDps, 30.0,
            "정착 자이로 임계 30 dps")
    }

    func testConstants_settleConsecutiveSamples() {
        XCTAssertEqual(AutoFallRecovery.settleConsecutiveSamples, 5,
            "정착 연속 샘플 5회 (=500ms @ 100ms polling)")
    }

    func testConstants_maxGetUpAttempts() {
        XCTAssertEqual(AutoFallRecovery.maxGetUpAttempts, 2,
            "최대 get-up 시도 2회")
    }

    func testConstants_settleTimeoutSec() {
        XCTAssertEqual(AutoFallRecovery.settleTimeoutSec, 4.0,
            "정착 타임아웃 4초")
    }

    // MARK: - RecoveryPhase Equatable

    func testRecoveryPhase_equatable() {
        XCTAssertEqual(AutoFallRecovery.RecoveryPhase.idle, .idle)
        XCTAssertEqual(AutoFallRecovery.RecoveryPhase.fallen(.forward),
                       AutoFallRecovery.RecoveryPhase.fallen(.forward))
        XCTAssertNotEqual(AutoFallRecovery.RecoveryPhase.fallen(.forward),
                          AutoFallRecovery.RecoveryPhase.fallen(.backward))
        XCTAssertEqual(AutoFallRecovery.RecoveryPhase.settling, .settling)
        XCTAssertEqual(AutoFallRecovery.RecoveryPhase.gettingUp, .gettingUp)
        XCTAssertEqual(AutoFallRecovery.RecoveryPhase.done, .done)
        XCTAssertEqual(AutoFallRecovery.RecoveryPhase.failed, .failed)
    }

    // MARK: - WalkLabSession 초기 상태 검증

    @MainActor
    func testWalkLabSession_defaultEnableAutoGetUp() {
        let session = WalkLabSession()
        XCTAssertTrue(session.enableAutoGetUp,
            "enableAutoGetUp 기본값 true")
    }

    @MainActor
    func testWalkLabSession_defaultAutoRecoveryPhase() {
        let session = WalkLabSession()
        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "autoRecoveryPhase 초기값 .idle")
    }
}
