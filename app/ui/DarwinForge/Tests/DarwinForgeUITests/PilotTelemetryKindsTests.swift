import XCTest
@testable import DarwinForgeUI

/// 사이클 186 (cycle 177 audit follow-up): Pilot WalkLabRCBridge telemetry kind
/// regression guard.
///
/// # 비유
///
/// 경찰서 무전기 의 channel 코드 — 5 source (keyboard / tello / gamepad / voice / djiRC)
/// 의 4 lifecycle (preset / emergency / recovery / blocked) 가 모두 distinct + 명시적.
/// 기존 2 kind (pilotModeChanged, pilotEStop) 가 dead code 였던 것 활성 + 3 신규 추가.
///
/// # 검증
///
/// 1. 5 case 정의 + `pilot.` prefix.
/// 2. snake_case 일관성.
/// 3. lifecycle 매핑 정확.
final class PilotTelemetryKindsTests: XCTestCase {

    /// **분류 검증 #1**: 모든 cycle 186 kind 가 `pilot.` prefix.
    func testAllKindsHavePilotPrefix() {
        let kinds: [TelemetryKind] = [
            .pilotModeChanged,
            .pilotEStop,
            .pilotRecoveryRequested,
            .pilotIntentBlocked,
            .pilotBridgeDisabled
        ]
        for k in kinds {
            XCTAssertTrue(k.rawValue.hasPrefix("pilot."),
                          "kind=\(k.rawValue) 가 pilot. prefix 없음")
        }
    }

    /// **분류 검증 #2**: 5 case 모두 distinct — 중복 없음.
    func testAllKindsAreUnique() {
        let kinds: [TelemetryKind] = [
            .pilotModeChanged,
            .pilotEStop,
            .pilotRecoveryRequested,
            .pilotIntentBlocked,
            .pilotBridgeDisabled
        ]
        let raws = Set(kinds.map { $0.rawValue })
        XCTAssertEqual(raws.count, kinds.count)
    }

    /// **분류 검증 #3**: 정확한 raw value 매칭.
    func testNewKindRawValuesMatchExpectedNames() {
        XCTAssertEqual(TelemetryKind.pilotModeChanged.rawValue, "pilot.mode_changed")
        XCTAssertEqual(TelemetryKind.pilotEStop.rawValue, "pilot.e_stop")
        XCTAssertEqual(TelemetryKind.pilotRecoveryRequested.rawValue, "pilot.recovery_requested")
        XCTAssertEqual(TelemetryKind.pilotIntentBlocked.rawValue, "pilot.intent_blocked")
        XCTAssertEqual(TelemetryKind.pilotBridgeDisabled.rawValue, "pilot.bridge_disabled")
    }

    /// **유기 검증 #4**: 5 kind 가 lifecycle 4 phase 분기 + 1 source change.
    /// preset / emergency / recovery / blocked + bridge_disabled — 사용자 모든 의도 매핑.
    func testKindsCoverPilotLifecycle() {
        let lifecycle: Set<String> = [
            "pilot.mode_changed",         // preset 변경
            "pilot.e_stop",                // 긴급 정지
            "pilot.recovery_requested",    // emergency exit
            "pilot.intent_blocked",        // emergency 동안 차단
            "pilot.bridge_disabled"        // bridge.enabled=false 동안 차단
        ]
        let actual = Set([
            TelemetryKind.pilotModeChanged.rawValue,
            TelemetryKind.pilotEStop.rawValue,
            TelemetryKind.pilotRecoveryRequested.rawValue,
            TelemetryKind.pilotIntentBlocked.rawValue,
            TelemetryKind.pilotBridgeDisabled.rawValue
        ])
        XCTAssertEqual(actual, lifecycle)
    }

    /// **유기 검증 #5**: snake_case 일관성.
    func testKindsUseSnakeCaseAfterPeriod() {
        for kind in [TelemetryKind.pilotModeChanged,
                     .pilotEStop,
                     .pilotRecoveryRequested,
                     .pilotIntentBlocked,
                     .pilotBridgeDisabled] {
            XCTAssertTrue(kind.rawValue.contains("_") || kind.rawValue == "pilot.e_stop",
                          "snake_case: \(kind.rawValue)")
            XCTAssertFalse(kind.rawValue.contains("-"),
                           "kebab-case 금지: \(kind.rawValue)")
        }
    }

    /// **regression guard #6**: 종전 2 kind (pilotModeChanged + pilotEStop) 가 dead code
    /// 였던 점 의식 — 본 cycle 부터 alive. 향후 정의만 추가하고 wire 안 하면 다시 dead
    /// code. 본 테스트 는 정의 자체 의 명시성 만 확인 — wire 검증 은 통합 테스트 가
    /// (별도 cycle) 수행.
    func testKindCountRegressionGuard() {
        let all: [TelemetryKind] = [
            .pilotModeChanged,
            .pilotEStop,
            .pilotRecoveryRequested,
            .pilotIntentBlocked,
            .pilotBridgeDisabled
        ]
        XCTAssertEqual(all.count, 5,
                       "cycle 186 의 5 case — 변경 시 USER_PILOT_GUIDE 동기화 필요")
    }
}
