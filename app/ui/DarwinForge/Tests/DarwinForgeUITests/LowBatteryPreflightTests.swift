// V288-5: `#if DEBUG` wrap — _testOverride* hooks 는 DEBUG-only.
// release test build 에서 symbol 부재로 인한 컴파일 에러 방지.
// XCTest 는 항상 DEBUG 빌드 → test 동작 무변경.
#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **V288-4 (2026-05-24) — Low battery preflight L1 block (OC8 STPA)**.
///
/// # 비유
///
/// 자동차 연료 경고등이 켜진 상태에서 고속도로 진입로로 들어서려 해도
/// 게이트가 차단하는 것과 같다. 연료(배터리)가 부족하면 시동(보행) 자체가
/// 불가능 — 도중에 서는 것보다 출발 전 차단이 안전하다.
///
/// LiPo 3S 한계: 셀당 3.5V × 3 = 10.5V. 이하면 즉시 throw — override 불가.
///
/// # 검증 대상
///
/// `WalkLabSession.quickPreflight(for:)` 의 8번째 guard — battery L1 차단.
/// 실 로봇 연결 시에만 적용 (시뮬 모드는 통과).
@MainActor
final class LowBatteryPreflightTests: XCTestCase {

    // MARK: - Helpers

    /// store 없이 `_testOverrideVoltageVolts` 만으로 voltage 를 주입하는 session.
    private func makeSession(voltage: Double?) -> WalkLabSession {
        let session = WalkLabSession(harness: RecordingHarness())
        // 실 로봇 연결 시뮬: store 없이 voltage override 만으로는 bus guard 가
        // 통과 안 되므로, 아래 두 단계로 battery 차단 경로를 노출:
        // 1) _testOverrideVoltageVolts 로 voltage 주입 (voltageForGate 위임)
        // 2) _testOverrideBusConnected=true 로 "bus 연결" 조건 충족
        session._testOverrideVoltageVolts = voltage
        session._testOverrideBusConnected = true
        // quickPreflight 의 앞선 guard 를 통과시키기 위한 최소 설정.
        session.cradleConfirmed = true
        return session
    }

    // MARK: - 경계값 테스트 (boundary: 10.5V)

    /// 10.4V → lowBatteryStartBlocked throw (10.5V 미만).
    func testVoltage_104V_IsBlocked() {
        let session = makeSession(voltage: 10.4)
        let failure = session.quickPreflight(for: .march)
        XCTAssertNotNil(failure, "10.4V 는 10.5V 미만 — preflight 차단해야 함")
        XCTAssertEqual(
            failure?.cause,
            .lowBatteryStartBlocked(voltage: 10.4, threshold: WalkLabSession.lowBatteryThreshold),
            "cause 가 lowBatteryStartBlocked 여야 함"
        )
    }

    /// 10.5V → lowBatteryStartBlocked (경계값 포함, 보수적 안전 정책).
    func testVoltage_105V_IsBlocked() {
        let session = makeSession(voltage: 10.5)
        let failure = session.quickPreflight(for: .march)
        XCTAssertNotNil(failure, "10.5V 는 경계값 — 보수적 정책으로 차단")
        if case .lowBatteryStartBlocked(let v, _) = failure?.cause {
            XCTAssertEqual(v, 10.5, accuracy: 0.001)
        } else {
            XCTFail("cause 가 lowBatteryStartBlocked 여야 함, 실제: \(String(describing: failure?.cause))")
        }
    }

    /// 10.6V → 통과 (10.5V 초과).
    func testVoltage_106V_Passes() {
        let session = makeSession(voltage: 10.6)
        let failure = session.quickPreflight(for: .march)
        XCTAssertNil(failure, "10.6V 는 threshold 초과 — preflight 통과해야 함")
    }

    /// 11.0V → 정상 통과.
    func testVoltage_110V_Passes() {
        let session = makeSession(voltage: 11.0)
        let failure = session.quickPreflight(for: .march)
        XCTAssertNil(failure, "11.0V 는 정상 — preflight 통과해야 함")
    }

    // MARK: - 시뮬 모드 (bus 미연결) — 차단 없음

    /// bus 미연결 (시뮬 모드) + 낮은 voltage → 차단 없음.
    func testSimMode_LowVoltage_IsNotBlocked() {
        let session = WalkLabSession(harness: RecordingHarness())
        // _testOverrideBusConnected = nil (기본값) → 시뮬 모드
        session._testOverrideVoltageVolts = 9.0  // 극단적 낮음
        session.cradleConfirmed = true
        let failure = session.quickPreflight(for: .march)
        // 시뮬 모드는 battery 차단 없음 (다른 사유 가능)
        if let f = failure {
            XCTAssertNotEqual(
                f.cause,
                .lowBatteryStartBlocked(voltage: 9.0, threshold: WalkLabSession.lowBatteryThreshold),
                "시뮬 모드에서는 battery 차단이 발생하면 안 됨"
            )
        }
    }

    // MARK: - voltage 정보 없음 (nil) — 통과 (fail-safe: 없으면 차단 안 함)

    /// voltage 정보 없음 → 차단 없음 (telemetry 미수신 시 보행 허용).
    func testVoltage_Nil_IsNotBlocked() {
        let session = makeSession(voltage: nil)
        let failure = session.quickPreflight(for: .march)
        if let f = failure {
            XCTAssertNotEqual(
                f.cause,
                .lowBatteryStartBlocked(voltage: 0, threshold: WalkLabSession.lowBatteryThreshold),
                "voltage 정보 없으면 battery 차단 발생하면 안 됨"
            )
        }
    }

    // MARK: - userMessage 내용 검증

    /// userMessage 가 전압 수치와 threshold 를 포함해야 함.
    func testUserMessage_ContainsVoltageAndThreshold() {
        let failure = WalkLabSession.WalkPreflightFailure(cause: .lowBatteryStartBlocked(voltage: 10.4, threshold: 10.5))
        XCTAssertTrue(
            failure.userMessage.contains("10.4"),
            "userMessage 에 현재 전압(10.4V) 포함 필요. 실제: \(failure.userMessage)"
        )
        XCTAssertTrue(
            failure.userMessage.contains("10.5"),
            "userMessage 에 threshold(10.5V) 포함 필요. 실제: \(failure.userMessage)"
        )
    }

    // MARK: - diagnosticCode

    /// diagnosticCode 는 고정 문자열 — telemetry 분류용.
    func testDiagnosticCode_IsLowBatteryStartBlocked() {
        let failure = WalkLabSession.WalkPreflightFailure(cause: .lowBatteryStartBlocked(voltage: 10.4, threshold: 10.5))
        XCTAssertEqual(failure.diagnosticCode, "lowBatteryStartBlocked")
    }

    // MARK: - start() 통합 — lastPreflightFailure 설정

    /// start() 가 battery 차단 시 lastPreflightFailure 에 cause 기록.
    func testStart_LowBattery_SetsLastPreflightFailure() {
        let session = makeSession(voltage: 10.4)
        session.start(.march)
        XCTAssertNotNil(session.lastPreflightFailure, "battery 차단 시 lastPreflightFailure 기록")
        if case .lowBatteryStartBlocked(let v, _) = session.lastPreflightFailure?.cause {
            XCTAssertEqual(v, 10.4, accuracy: 0.001)
        } else {
            XCTFail("lastPreflightFailure.cause 가 lowBatteryStartBlocked 여야 함")
        }
        XCTAssertEqual(session.current, .idle, "battery 차단 시 current 미변경")
    }

    /// start() 가 battery 차단 시 startBlockedReason 에 diagnosticCode 기록.
    func testStart_LowBattery_SetsStartBlockedReason() {
        let session = makeSession(voltage: 10.4)
        session.start(.march)
        XCTAssertEqual(session.startBlockedReason, "lowBatteryStartBlocked")
    }
}
#endif
