import XCTest
@testable import DarwinForgeUI

/// 사이클 196 (cycle 190 audit P1 #3): JointControlView telemetry kind
/// regression guard — Torque ON/OFF + action buttons silent fail 차단.
///
/// # 비유
///
/// 공장 제어판 의 버튼 — 누를 때 마다 작업일지 에 "누가, 어떤 버튼, 언제" 가 기록
/// 되어야 한다. 본 테스트 는 (1) 두 kind 가 `joint.` prefix + (2) raw value 정확
/// + (3) jointActionFailed 가 errorCountedKinds 에 등록 됨 — 실패 카운트 누락 방지.
final class JointControlTelemetryKindsTests: XCTestCase {

    /// **분류 검증 #1**: 신규 2 kind 가 `joint.` prefix.
    func testKindsHaveJointPrefix() {
        XCTAssertTrue(
            TelemetryKind.jointActionRequested.rawValue.hasPrefix("joint."),
            "jointActionRequested 가 joint. prefix 없음"
        )
        XCTAssertTrue(
            TelemetryKind.jointActionFailed.rawValue.hasPrefix("joint."),
            "jointActionFailed 가 joint. prefix 없음"
        )
    }

    /// **분류 검증 #2**: raw value 정확.
    func testRawValues() {
        XCTAssertEqual(
            TelemetryKind.jointActionRequested.rawValue,
            "joint.action_requested"
        )
        XCTAssertEqual(
            TelemetryKind.jointActionFailed.rawValue,
            "joint.action_failed"
        )
    }

    /// **분류 검증 #3**: jointActionFailed 가 errorCountedKinds SOT 에 포함 (cycle 192).
    /// 실패 이벤트 가 meta.errorCount 에 반영 되지 않으면 운영자 통계 undercount.
    func testJointActionFailedInErrorCountedKinds() {
        XCTAssertTrue(
            TelemetryRecorder.errorCountedRawValues.contains(
                TelemetryKind.jointActionFailed.rawValue
            ),
            "jointActionFailed 가 errorCountedRawValues 에 누락 — meta.errorCount undercount"
        )
    }
}
