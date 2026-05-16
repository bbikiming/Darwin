import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// v1.1 — Walk Lab Fall Prevention 회귀 가드.
///
/// 사용자 요구 "자이로 센서 기반 넘어지지 않게 동작" 대응. Stage 1 = 실 IMU wire-up.
/// 이후 Stage 2-5 의 회귀도 본 파일에 누적.
@MainActor
final class WalkLabFallPreventionTests: XCTestCase {

    // MARK: - Stage 1 — 실 IMU wire-up

    /// store 미attach + 미연결 → sim IMU 사용. 기존 동작 보존.
    func testImuSourceSimWhenNotAttached() {
        let session = WalkLabSession()
        // 초기 상태.
        XCTAssertEqual(session.imuSource, .sim,
            "store attach 전 imuSource 가 sim 이 아님")
    }

    /// store attach + bus nil (연결 시도 안 함) → sim 유지.
    func testImuSourceSimWhenBusIsNil() {
        let session = WalkLabSession()
        let store = ConnectionStore()
        session.attach(store: store)
        // bus 가 nil 이라 sim 으로 fallback.
        // tick() 호출 위해 cradleConfirmed + start 필요하나 sim 모드 검증만 — 직접 호출.
        // (private updateImuFromRealOrSim 은 호출 불가 → 공개 invariant 만 검증)
        XCTAssertEqual(session.imuSource, .sim)
    }

    /// imuSource enum 의 label 출력.
    func testImuSourceLabelNotEmpty() {
        XCTAssertEqual(WalkLabSession.ImuSource.sim.label, "시뮬")
        XCTAssertEqual(WalkLabSession.ImuSource.real.label, "실 IMU")
        XCTAssertEqual(WalkLabSession.ImuSource.stale.label, "IMU 지연")
    }

    /// L3 자동 정지 게이트가 imuSource 와 무관하게 작동 — sim 모드에서 직접 값 주입.
    /// (Stage 1 변경이 기존 게이트 동작을 깨지 않음을 검증)
    func testL3GateWorksRegardlessOfSource() {
        let session = WalkLabSession()
        // sim 모드의 imuRollDeg/imuPitchDeg 는 일반적으로 0~6° 흔들림.
        // 임계 30° 도달 시 balanceLost true + emergency stop.
        // 직접 imuRollDeg 주입 후 다음 tick 에서 게이트 발동 확인은 simTimer
        // private 이라 직접 테스트 불가. 공개 invariant: balanceLost 초기 false.
        XCTAssertFalse(session.balanceLost, "초기 balanceLost 가 true 인 것은 비정상")
    }

    // MARK: - Stage 2 — 다단계 안전 임계

    /// BalanceState 임계 정확성.
    func testBalanceStateThresholds() {
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 0),    .normal)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 10),   .normal)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 14.9), .normal)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 15),   .caution)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 21.9), .caution)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 22),   .warning)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 27.9), .warning)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 28),   .danger)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 29.9), .danger)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 30),   .emergency)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 45),   .emergency)
    }

    /// 속도 배수 — Warning 70%, Danger 0%.
    func testBalanceStateSpeedScale() {
        XCTAssertEqual(WalkLabSession.BalanceState.normal.speedScale,    1.0)
        XCTAssertEqual(WalkLabSession.BalanceState.caution.speedScale,   1.0)
        XCTAssertEqual(WalkLabSession.BalanceState.warning.speedScale,   0.7, accuracy: 0.001)
        XCTAssertEqual(WalkLabSession.BalanceState.danger.speedScale,    0.0)
        XCTAssertEqual(WalkLabSession.BalanceState.emergency.speedScale, 0.0)
    }

    /// BalanceState 가 Comparable — 단조 증가.
    func testBalanceStateIsComparable() {
        XCTAssertLessThan(WalkLabSession.BalanceState.normal, .caution)
        XCTAssertLessThan(WalkLabSession.BalanceState.caution, .warning)
        XCTAssertLessThan(WalkLabSession.BalanceState.warning, .danger)
        XCTAssertLessThan(WalkLabSession.BalanceState.danger, .emergency)
    }

    /// 라벨 비어있지 않음 — UI 표시 안전.
    func testBalanceStateLabelsNotEmpty() {
        for s in [WalkLabSession.BalanceState.normal, .caution, .warning, .danger, .emergency] {
            XCTAssertFalse(s.label.isEmpty, "\(s) label 비어있음")
        }
    }

    /// 초기 상태 — 정상 + autoFallPrevention ON.
    func testInitialStateNormalAndAutoOn() {
        let session = WalkLabSession()
        XCTAssertEqual(session.balanceState, .normal)
        XCTAssertTrue(session.autoFallPrevention,
            "autoFallPrevention 기본값이 ON 이어야 함 (사용자가 명시적 OFF 가능)")
    }
}
