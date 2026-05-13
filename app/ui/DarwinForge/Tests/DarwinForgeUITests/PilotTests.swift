import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// Sprint 15 Remote Pilot v1.0 — 단위 테스트.
final class PilotTests: XCTestCase {

    // MARK: - MotionCatalog (4)

    func testMotionCatalogHasMain7Slots() {
        XCTAssertEqual(MotionCatalog.actionBarMainSlots, [1, 4, 15, 12, 13, 9, 23],
            "PRD §7.1 메인 7 페이지 슬롯 순서 동결")
        XCTAssertEqual(MotionCatalog.actionBarMain.count, 7)
    }

    func testMotionCatalogHas16Pages() {
        // PRD §7.1 (7) + §7.2 (9) = 16.
        XCTAssertEqual(MotionCatalog.all.count, 16,
            "v1.5 까지 표시되는 16 페이지 catalog")
    }

    func testMotionCatalogKoreanLabels() {
        XCTAssertEqual(MotionCatalog.find(slot: 1)?.displayNameKo,   "기본 자세")
        XCTAssertEqual(MotionCatalog.find(slot: 4)?.displayNameKo,   "감사 인사")
        XCTAssertEqual(MotionCatalog.find(slot: 9)?.displayNameKo,   "보행 자세")
        XCTAssertEqual(MotionCatalog.find(slot: 12)?.displayNameKo,  "오른발 차기")
        XCTAssertEqual(MotionCatalog.find(slot: 13)?.displayNameKo,  "왼발 차기")
        XCTAssertEqual(MotionCatalog.find(slot: 15)?.displayNameKo,  "앉기")
        XCTAssertEqual(MotionCatalog.find(slot: 23)?.displayNameKo,  "출발!")
    }

    func testHighRiskSlotsAreKicks() {
        // PRD §7.1 — page 12/13 이 HighRisk (confirm 필수).
        XCTAssertEqual(MotionCatalog.find(slot: 12)?.safetyClass, .highRisk)
        XCTAssertEqual(MotionCatalog.find(slot: 13)?.safetyClass, .highRisk)
        XCTAssertTrue(MotionCatalog.find(slot: 12)!.safetyClass.requiresConfirm)
        // Safe 슬롯 6 개는 confirm 불필요.
        for slot: UInt8 in [1, 4, 9, 15, 23] {
            XCTAssertEqual(MotionCatalog.find(slot: slot)?.safetyClass, .safe,
                "slot \(slot) 은 Safe 여야 함")
        }
    }

    // MARK: - PilotFeatureFlags (2)

    func testFeatureFlagsV1_0Matrix() {
        // v1.0 = 메인 7 만 활성, 나머지 OFF.
        let f = PilotFeatureFlags.v1_0
        XCTAssertTrue(f.actionBarMain)
        XCTAssertFalse(f.actionBarMore)
        XCTAssertFalse(f.imuTelemetry)
        XCTAssertFalse(f.autoRecovery)
        XCTAssertFalse(f.headTracking)
        XCTAssertFalse(f.ballFollow)
        XCTAssertFalse(f.camera)
        XCTAssertFalse(f.hsvTuning)
        XCTAssertFalse(f.bridgeNetwork)
        XCTAssertFalse(f.dpadRealMotor)
        XCTAssertFalse(f.pageChain)
        XCTAssertFalse(f.mp3Playback)
    }

    func testFeatureFlagsProgressionMatrix() {
        // PRD §1 단계별 활성화 매트릭스 — v1.5 부터는 Codex 권고 (2026-05-13) 로
        // "작동하는 것처럼 보이는 기능" 차단을 위해 안전 부분집합으로 재정의.
        //
        // v1.5 안전 범위:
        //   - actionBarMore: 9 페이지 시트 활성 (단, 2개 slot 은 단발 자세, 2개는 chain 미구현 nil)
        //   - bridgeNetwork: 네트워크 endpoint UI 노출 (forge serve 데몬 가정)
        // v1.5 에서 여전히 OFF (별도 FFI / 데몬 필요):
        //   - imuTelemetry / autoRecovery / headTracking / ballFollow / camera / hsvTuning / dpadRealMotor / pageChain / mp3Playback
        XCTAssertTrue(PilotFeatureFlags.v1_5.actionBarMore)
        XCTAssertTrue(PilotFeatureFlags.v1_5.bridgeNetwork)
        XCTAssertFalse(PilotFeatureFlags.v1_5.camera)
        XCTAssertFalse(PilotFeatureFlags.v1_5.imuTelemetry)
        XCTAssertFalse(PilotFeatureFlags.v1_5.dpadRealMotor)
        XCTAssertFalse(PilotFeatureFlags.v1_5.pageChain)

        // v1_1_future / v2_future 는 미래 단계 placeholder — 실제 활성 시 별도 Sprint.
        XCTAssertTrue(PilotFeatureFlags.v1_1_future.imuTelemetry)
        XCTAssertTrue(PilotFeatureFlags.v1_1_future.autoRecovery)
        XCTAssertTrue(PilotFeatureFlags.v1_1_future.headTracking)
        XCTAssertFalse(PilotFeatureFlags.v1_1_future.dpadRealMotor)

        XCTAssertTrue(PilotFeatureFlags.v2_future.dpadRealMotor)
        XCTAssertTrue(PilotFeatureFlags.v2_future.camera)
        XCTAssertTrue(PilotFeatureFlags.v2_future.mp3Playback)
    }

    // MARK: - PilotFeatureLevel picker (v1.5 신규)

    func testFeatureLevelEnumMaps() {
        XCTAssertEqual(PilotFeatureLevel.v1_0.rawValue, "v1.0")
        XCTAssertEqual(PilotFeatureLevel.v1_5.rawValue, "v1.5")
        XCTAssertEqual(PilotFeatureLevel.v1_0.flags.actionBarMore, false)
        XCTAssertEqual(PilotFeatureLevel.v1_5.flags.actionBarMore, true)
    }

    // MARK: - PilotSafetyGate (3)

    @MainActor
    func testSafetyGateBlocksUnarmedMotion() {
        let gate = PilotSafetyGate()
        let meta = MotionCatalog.find(slot: 4)!  // 감사 인사 (Safe)
        XCTAssertEqual(gate.allowMotion(meta, confirmRisk: false), .blockUnarmed)
    }

    @MainActor
    func testSafetyGateAllowsArmedSafeMotion() {
        let gate = PilotSafetyGate()
        gate.arm()
        let safeMeta = MotionCatalog.find(slot: 1)!
        XCTAssertEqual(gate.allowMotion(safeMeta, confirmRisk: false), .allow)
    }

    @MainActor
    func testSafetyGateRequiresConfirmForHighRisk() {
        let gate = PilotSafetyGate()
        gate.arm()
        let highRiskMeta = MotionCatalog.find(slot: 12)!  // 오른발 차기
        XCTAssertEqual(gate.allowMotion(highRiskMeta, confirmRisk: false),
                       .requireHighRiskConfirm)
        XCTAssertEqual(gate.allowMotion(highRiskMeta, confirmRisk: true), .allow)
    }

    // MARK: - PilotMode + Catalog v1 sendability (3)

    func testV1SendableMatchesPoseLibraryEntries() {
        // 모든 v1TargetPoseID 가 PoseLibrary 에 실제로 존재해야 함.
        for meta in MotionCatalog.all {
            guard let poseID = meta.v1TargetPoseID else { continue }
            XCTAssertNotNil(
                PoseLibrary.get(poseID),
                "slot \(meta.slot) (\(meta.displayNameKo)) → poseID '\(poseID)' 누락"
            )
        }
    }

    func testV1SendableCountIsAtLeastFive() {
        // v1.0 에서 실제 송출되는 페이지는 7 중 최소 5 (왼발 차기 mirror pose 누락 등 허용).
        let count = MotionCatalog.actionBarMain.filter { $0.v1TargetPoseID != nil }.count
        XCTAssertGreaterThanOrEqual(count, 5,
            "메인 7 중 최소 5 페이지는 v1.0 에서 실 송출 가능해야 함")
    }

    func testPilotModePickerHasManualAndBallFollow() {
        XCTAssertEqual(PilotMode.allCases, [.manual, .ballFollow])
        XCTAssertEqual(PilotMode.manual.label, "수동")
        XCTAssertEqual(PilotMode.ballFollow.label, "공 자동 추적")
    }

    // MARK: - SafetyClass equality (1)

    func testSafetyClassLabels() {
        XCTAssertEqual(SafetyClass.safe.koreanLabel, "안전")
        XCTAssertEqual(SafetyClass.caution.koreanLabel, "주의")
        XCTAssertEqual(SafetyClass.highRisk.koreanLabel, "위험")
        XCTAssertFalse(SafetyClass.safe.requiresConfirm)
        XCTAssertFalse(SafetyClass.caution.requiresConfirm)
        XCTAssertTrue(SafetyClass.highRisk.requiresConfirm)
    }
}
