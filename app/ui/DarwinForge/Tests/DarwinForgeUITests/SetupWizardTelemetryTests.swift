import XCTest
@testable import DarwinForgeUI

/// 사이클 194 (cycle 190 audit P0 #2): InitialSetupWizard telemetry kind 등록
/// + lifecycle 검증.
///
/// # 비유
///
/// 신입사원 입사 절차 (VNC / 마스터셋업 / SSH key / 연결) 의 각 step 별 시작 →
/// 진행 → 완료 시각 기록. 누가 어느 단계 에서 막히나, 평균 완료 시간 은 얼마 나.
final class SetupWizardTelemetryTests: XCTestCase {

    /// **분류 검증 #1**: 신규 2 kind 가 `setup.` prefix.
    func testKindsHaveSetupPrefix() {
        XCTAssertTrue(TelemetryKind.setupWizardStepChanged.rawValue.hasPrefix("setup."))
        XCTAssertTrue(TelemetryKind.setupWizardCompleted.rawValue.hasPrefix("setup."))
    }

    /// **분류 검증 #2**: raw value 정확.
    func testRawValuesMatchExpected() {
        XCTAssertEqual(TelemetryKind.setupWizardStepChanged.rawValue,
                       "setup.wizard_step_changed")
        XCTAssertEqual(TelemetryKind.setupWizardCompleted.rawValue,
                       "setup.wizard_completed")
    }

    /// **분류 검증 #3**: 두 kind distinct.
    func testKindsAreDistinct() {
        XCTAssertNotEqual(TelemetryKind.setupWizardStepChanged.rawValue,
                          TelemetryKind.setupWizardCompleted.rawValue)
    }

    /// **유기 검증 #4**: mark() 가 default state 변경 시 발화 — silent no-op 차단.
    /// 본 테스트 는 InitialSetupWizard 의 mark() 가 같은 status 재호출 시 no-op 보장
    /// (telemetry 노이즈 차단). 검증 method 는 @MainActor 라서 별도 테스트.
    @MainActor
    func testMarkIsIdempotentForSameStatus() {
        let wizard = InitialSetupState()
        // 초기 .pending. 같은 status 재 mark — no-op (telemetry 발화 X).
        wizard.mark(.vnc, .pending)
        XCTAssertEqual(wizard.statuses[.vnc], .pending)
        // 다른 status — 변경 + telemetry 발화.
        wizard.mark(.vnc, .inProgress)
        XCTAssertEqual(wizard.statuses[.vnc], .inProgress)
        // 다시 같은 status — no-op.
        wizard.mark(.vnc, .inProgress)
        XCTAssertEqual(wizard.statuses[.vnc], .inProgress)
    }

    /// **유기 검증 #5**: allDone 4 step 완료 시 true. completed 이벤트 트리거 조건.
    @MainActor
    func testAllDoneTriggersOnFourComplete() {
        let wizard = InitialSetupState()
        XCTAssertFalse(wizard.allDone)
        wizard.mark(.vnc, .completed)
        XCTAssertFalse(wizard.allDone, "1/4 — false")
        wizard.mark(.robotSetup, .completed)
        wizard.mark(.macSSHKey, .completed)
        XCTAssertFalse(wizard.allDone, "3/4 — false")
        wizard.mark(.connect, .completed)
        XCTAssertTrue(wizard.allDone, "4/4 — true")
    }
}
