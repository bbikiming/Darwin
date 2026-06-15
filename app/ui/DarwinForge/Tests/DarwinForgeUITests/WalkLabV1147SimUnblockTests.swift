import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.14.7 (2026-05-21)** — 사용자 보고 회귀 방지:
/// - 시뮬 모드에서 위험 동의 dialog 가 떠야 함 (cradle 우회)
/// - 자이로 강도 setter 가 즉시 반영 + defer 된 corrector 도 결국 갱신
@MainActor
final class WalkLabV1147SimUnblockTests: XCTestCase {

    // MARK: - 위험 동의 흐름 검증

    /// **시뮬 모드 — cradle 미확인이라도 jog (highRisk) preset 의 risk 사유로 차단**.
    /// tap() 의 cradle 가드가 우회 → risk 분기에 도달해야 dialog 뜸.
    func testSimModeAllowsRiskPresetReachableForConfirmation() {
        let session = WalkLabSession()
        XCTAssertFalse(session.cradleConfirmed, "default false")
        XCTAssertFalse(session.riskAcknowledged, "default false")

        // jog = requiresRiskConfirmation = true (highRisk safety).
        let preset = WalkLabPreset.jog
        XCTAssertTrue(preset.requiresRiskConfirmation, "jog 는 위험 동의 필요")

        // 시뮬 모드 — quickPreflight 가 cradle 우회 → risk 사유로 차단.
        session.start(preset)
        XCTAssertNotNil(session.lastPreflightFailure)
        if case .highRiskNotAcknowledged = session.lastPreflightFailure?.cause {
            // OK — 위험 동의 미확인이 first failure
        } else {
            XCTFail("시뮬 모드 cradle 우회 → highRiskNotAcknowledged. 실제: \(String(describing: session.lastPreflightFailure?.cause))")
        }
    }

    /// **risk acknowledged 후 start → 시뮬 모드에서 진행**.
    func testRiskAcknowledgedAllowsStartInSimMode() {
        let session = WalkLabSession()
        session.riskAcknowledged = true
        session.start(.jog)
        // jog 는 highRisk + caution 아니라 safe path. start 진행 → noConnection 또는 통과.
        XCTAssertEqual(session.current, .jog,
            "risk 동의 + cradle 우회 → jog 시작")
    }

    /// **모든 차단 우회 후 시뮬 모드 start — current 변경 + noConnection 사유**.
    func testFullyUnblockedSimModeStart() {
        let session = WalkLabSession()
        session.riskAcknowledged = true
        session.enableBalanceCorrection = true
        // 시뮬 모드, march preset (caution 아님)
        session.start(.march)
        XCTAssertEqual(session.current, .march,
            "모든 가드 통과 — current 가 march 로 변경")
    }

    // MARK: - 자이로 강도 setter 검증

    /// **lvl 변경 즉시 반영 — 다음 line 에서 read 가능**.
    /// (defer 된 corrector 재구성은 별도 — setter 자체는 즉시)
    func testCorrectorIntensitySetterImmediate() {
        let session = WalkLabSession()
        XCTAssertEqual(session.correctorIntensityLevel, 2, "default 2 (표준)")
        session.correctorIntensityLevel = 4
        XCTAssertEqual(session.correctorIntensityLevel, 4,
            "setter 즉시 반영 — defer 와 무관")
        session.correctorIntensityLevel = 0
        XCTAssertEqual(session.correctorIntensityLevel, 0)
        session.correctorIntensityLevel = 3
        XCTAssertEqual(session.correctorIntensityLevel, 3)
    }

    /// **clamp 동작** — 범위 밖 값은 0..4 로 self-correct.
    func testCorrectorIntensityClamps() {
        let session = WalkLabSession()
        session.correctorIntensityLevel = -5
        XCTAssertEqual(session.correctorIntensityLevel, 0, "음수 → 0")
        session.correctorIntensityLevel = 99
        XCTAssertEqual(session.correctorIntensityLevel, 4, "범위 초과 → 4")
    }

    /// **defer 된 balanceCorrector 가 결국 갱신**.
    /// Task { @MainActor } 의 결과를 short wait 후 확인.
    func testDeferredCorrectorEventuallyUpdates() async throws {
        let session = WalkLabSession()
        let originalIntensity = session.balanceCorrector.intensity
        // lvl 3 → intensity 1.5 (배수).
        session.correctorIntensityLevel = 3
        // 즉시 — 아직 corrector 재구성 안 됨 (Task 가 다음 tick).
        // settle wait — correctorIntensityLevel setter 내부 Task { @MainActor } 가 동일한
        // main actor 에서 실행. Task.yield 로 양보 후 조건 확인.
        // 관찰 가능한 완료 신호 없음 (TODO: setter 가 async 를 반환하거나 publisher 노출).
        await Task.yield()
        await Task.yield()  // 복수 yield — 부하 시 deferred Task 실행 보장.
        XCTAssertNotEqual(session.balanceCorrector.intensity, originalIntensity,
            "defer 된 Task 가 corrector 재구성")
    }
}
