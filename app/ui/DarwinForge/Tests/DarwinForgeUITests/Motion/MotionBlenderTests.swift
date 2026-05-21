import Foundation
import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **v1.18.0 (2026-05-21) Phase 3 — MotionBlender + TransitionPolicy + CompositeMotion 통합 테스트**.
@MainActor
final class MotionBlenderTests: XCTestCase {

    // MARK: - CompositeMotion init validation

    func testCompositeMotionAcceptsLowerWalkAndUpperPage() {
        let walk = MotionDescriptor.walk(.slowWalk)
        // mock page metadata — upper only (arms).
        let page = makeTestPage(slot: 1, bodyParts: [.rightArm, .leftArm])
        let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(page))
        XCTAssertNotNil(composite, "walk(lower) + page(upper) 정상 composite")
        XCTAssertEqual(composite?.safetyClass, .safe, "lower=walk(safe) + upper=page(safe) = safe")
        XCTAssertEqual(composite?.bodyRegions.count, 4)
        // walk 가 두 다리, page 가 두 팔.
        _ = walk
    }

    func testCompositeRejectsWhenChannelConflict() {
        // 두 motion 모두 lower (walk + 다리 사용 page) → 충돌.
        let lowerWalk = MotionDescriptor.walk(.march)
        let lowerPage = makeTestPage(slot: 2, bodyParts: [.rightLeg, .leftLeg])
        let composite = CompositeMotion(lower: lowerWalk, upper: .page(lowerPage))
        XCTAssertNil(composite, "두 motion 모두 lower channel — 충돌 거부")
    }

    func testCompositeRejectsWhenSameChannel() {
        // 두 motion 모두 upper.
        let upperA = makeTestPage(slot: 3, bodyParts: [.rightArm])
        let upperB = makeTestPage(slot: 4, bodyParts: [.leftArm])
        let composite = CompositeMotion(lower: .page(upperA), upper: .page(upperB))
        XCTAssertNil(composite, "두 motion 모두 upper — 같은 channel 거부")
    }

    func testCompositeMaxSafetyWins() {
        // walk (safe) + highRisk page → composite = highRisk.
        let highPage = makeTestPage(slot: 5, bodyParts: [.rightArm, .head], safety: .highRisk)
        let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(highPage))
        XCTAssertEqual(composite?.safetyClass, .highRisk,
                       "safe + highRisk = highRisk (max)")
    }

    // MARK: - MotionBlender

    func testPlaySingleLowerMotion() {
        let blender = MotionBlender()
        let result = blender.play(.walk(.slowWalk))
        XCTAssertTrue(result.isAccepted)
        XCTAssertNotNil(blender.lower)
        XCTAssertNil(blender.upper)
        XCTAssertTrue(blender.isPlaying)
    }

    func testPlaySingleUpperMotion() {
        let blender = MotionBlender()
        let page = makeTestPage(slot: 1, bodyParts: [.rightArm])
        let result = blender.play(.page(page))
        XCTAssertTrue(result.isAccepted)
        XCTAssertNil(blender.lower)
        XCTAssertNotNil(blender.upper)
    }

    func testCompositeBuildsBothChannels() {
        let blender = MotionBlender()
        let page = makeTestPage(slot: 1, bodyParts: [.rightArm, .leftArm])
        guard let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(page)) else {
            XCTFail("composite init")
            return
        }
        blender.play(composite: composite)
        XCTAssertNotNil(blender.lower)
        XCTAssertNotNil(blender.upper)
    }

    func testUpperFinishedClearsUpper_WhenNoLoop() {
        let blender = MotionBlender()
        let page = makeTestPage(slot: 1, bodyParts: [.rightArm])
        guard let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(page)) else {
            XCTFail("composite init")
            return
        }
        blender.play(composite: composite, upperLoops: false)
        XCTAssertNotNil(blender.upper)
        blender.upperFinished()
        XCTAssertNil(blender.upper, "loop=false → upperFinished 후 nil")
        XCTAssertNotNil(blender.lower, "lower 는 계속")
    }

    func testUpperFinishedKeepsUpper_WhenLoop() {
        let blender = MotionBlender()
        let page = makeTestPage(slot: 1, bodyParts: [.rightArm])
        guard let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(page)) else {
            XCTFail("composite init")
            return
        }
        blender.play(composite: composite, upperLoops: true)
        blender.upperFinished()
        XCTAssertNotNil(blender.upper, "loop=true → upper 유지")
    }

    func testEmergencyKillClearsAll() {
        let blender = MotionBlender()
        let page = makeTestPage(slot: 1, bodyParts: [.rightArm])
        guard let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(page)) else {
            XCTFail("composite init")
            return
        }
        blender.play(composite: composite, upperLoops: true)
        blender.emergencyKill()
        XCTAssertNil(blender.lower)
        XCTAssertNil(blender.upper)
        XCTAssertFalse(blender.isPlaying)
    }

    // MARK: - MotionTransitionPolicy

    func testPolicyAllowsNormalState() {
        let v = MotionTransitionPolicy.validate(
            target: .walk(.slowWalk),
            balanceState: .normal,
            robotConnected: false,
            riskAcknowledged: false
        )
        XCTAssertEqual(v, .allow)
    }

    func testPolicyBlocksEmergencyState() {
        let v = MotionTransitionPolicy.validate(
            target: .walk(.slowWalk),
            balanceState: .emergency,
            robotConnected: false,
            riskAcknowledged: false
        )
        XCTAssertFalse(v.isAllowed)
        if case .blocked = v { /* OK */ } else { XCTFail("blocked 기대") }
    }

    func testPolicyBlocksDangerState() {
        let v = MotionTransitionPolicy.validate(
            target: .walk(.slowWalk),
            balanceState: .danger,
            robotConnected: false,
            riskAcknowledged: false
        )
        XCTAssertFalse(v.isAllowed)
    }

    func testPolicyAllowsUpperOnlyDuringWarning() {
        let upperPage = makeTestPage(slot: 1, bodyParts: [.rightArm])
        let v = MotionTransitionPolicy.validate(
            target: .page(upperPage),
            balanceState: .warning,
            robotConnected: false,
            riskAcknowledged: false
        )
        XCTAssertEqual(v, .allow, "warning 에서 upper-only motion 은 허용")
    }

    func testPolicyBlocksLowerDuringWarning() {
        // walking 은 lower channel 점유.
        let v = MotionTransitionPolicy.validate(
            target: .walk(.fastWalk),
            balanceState: .warning,
            robotConnected: false,
            riskAcknowledged: false
        )
        XCTAssertFalse(v.isAllowed, "warning 에서 lower channel 차단")
    }

    func testPolicyRequiresConfirmForHighRisk() {
        let high = makeTestPage(slot: 1, bodyParts: [.rightArm], safety: .highRisk)
        let v = MotionTransitionPolicy.validate(
            target: .page(high),
            balanceState: .normal,
            robotConnected: false,
            riskAcknowledged: false
        )
        if case .requireConfirm = v { /* OK */ } else {
            XCTFail("highRisk 는 requireConfirm — 받은 verdict: \(v)")
        }
    }

    func testPolicyHighRiskAllowedWhenAcknowledged() {
        let high = makeTestPage(slot: 1, bodyParts: [.rightArm], safety: .highRisk)
        let v = MotionTransitionPolicy.validate(
            target: .page(high),
            balanceState: .normal,
            robotConnected: false,
            riskAcknowledged: true
        )
        XCTAssertEqual(v, .allow)
    }

    // MARK: - BodyPart extension

    func testBodyPartChannelClassification() {
        XCTAssertTrue(JointID.BodyPart.rightLeg.isLower)
        XCTAssertTrue(JointID.BodyPart.leftLeg.isLower)
        XCTAssertTrue(JointID.BodyPart.rightArm.isUpper)
        XCTAssertTrue(JointID.BodyPart.leftArm.isUpper)
        XCTAssertTrue(JointID.BodyPart.head.isUpper)
        XCTAssertEqual(JointID.BodyPart.rightLeg.channel, .lower)
        XCTAssertEqual(JointID.BodyPart.head.channel, .upper)
    }

    // MARK: - SafetyClass ordering

    func testSafetyClassOrdering() {
        XCTAssertLessThan(SafetyClass.safe, SafetyClass.caution)
        XCTAssertLessThan(SafetyClass.caution, SafetyClass.highRisk)
        XCTAssertEqual(max(SafetyClass.safe, .highRisk), .highRisk)
    }

    // MARK: - Boundary cases (코덱스 MEDIUM)

    /// teach 자세는 전신 점유 → acceptedFullBody 분기.
    func testTeachAssumedFullBody() {
        let blender = MotionBlender()
        let snap = TeachCapture.PoseSnapshot(name: "test pose", pose: .walkReady, capturedAt: Date())
        let result = blender.play(.teach(snap))
        if case .acceptedFullBody = result { /* OK */ } else {
            XCTFail("teach 는 전신 점유 — acceptedFullBody 기대, 실제: \(result)")
        }
        XCTAssertNotNil(blender.lower, "전신 motion 은 lower channel 에 저장")
    }

    /// 빈 occupied channel 거부.
    func testEmptyChannelMotionRejected() {
        let blender = MotionBlender()
        // bodyRegions 빈 page — 인공적 edge case.
        let emptyPage = makeTestPage(slot: 99, bodyParts: [])
        let result = blender.play(.page(emptyPage))
        XCTAssertEqual(result, .rejectedEmptyChannels)
    }

    /// safety policy 거부 — emergency 상태에서 motion 차단.
    func testSafetyContextBlocksDuringEmergency() {
        let blender = MotionBlender()
        let upperPage = makeTestPage(slot: 1, bodyParts: [.rightArm])
        let ctx = SafetyContext(
            balanceState: .emergency,
            robotConnected: false,
            riskAcknowledged: false
        )
        let result = blender.play(.page(upperPage), safetyContext: ctx)
        if case .rejectedSafety = result { /* OK */ } else {
            XCTFail("emergency 상태 — rejectedSafety 기대, 실제: \(result)")
        }
        XCTAssertNil(blender.upper, "rejected → state 변경 X")
    }

    /// safety context 없으면 검증 skip (sim mode).
    func testNoSafetyContextSkipsValidation() {
        let blender = MotionBlender()
        let result = blender.play(.walk(.slowWalk), safetyContext: nil)
        XCTAssertTrue(result.isAccepted)
    }

    /// composite 후 새 lower play 시 upper 유지.
    func testPlayingNewLowerKeepsExistingUpper() {
        let blender = MotionBlender()
        let upperPage = makeTestPage(slot: 1, bodyParts: [.rightArm])
        guard let composite = CompositeMotion(lower: .walk(.slowWalk), upper: .page(upperPage)) else {
            XCTFail("composite init"); return
        }
        blender.play(composite: composite)
        XCTAssertEqual(blender.upper?.id, MotionDescriptor.page(upperPage).id)

        // 새 lower (다른 walk) play.
        blender.play(.walk(.march))
        XCTAssertEqual(blender.lower?.id, MotionDescriptor.walk(.march).id, "lower 교체됨")
        XCTAssertEqual(blender.upper?.id, MotionDescriptor.page(upperPage).id, "upper 유지")
    }

    /// associated value 비교 — 같은 slot 다른 safety 는 != (코덱스 HIGH 1).
    func testMotionDescriptorEqualityRespectsSafety() {
        let safePage = makeTestPage(slot: 7, bodyParts: [.rightArm], safety: .safe)
        let highPage = makeTestPage(slot: 7, bodyParts: [.rightArm], safety: .highRisk)
        // 종전 id 기반은 == True 였음. 신규 associated value 기반 == False.
        XCTAssertNotEqual(MotionDescriptor.page(safePage), MotionDescriptor.page(highPage),
                          "같은 slot 의 다른 safety = != (HIGH 1 fix)")
    }

    // MARK: - Fixtures

    private func makeTestPage(
        slot: UInt8,
        bodyParts: [JointID.BodyPart],
        safety: SafetyClass = .safe
    ) -> MotionPageMetadata {
        MotionPageMetadata(
            slot: slot,
            rawName: "TEST",
            displayName: "test",
            displayNameKo: "테스트",
            safetyClass: safety,
            durationMs: 1000,
            rawChainDurationMs: nil,
            mp3Sync: nil,
            bodyRegions: bodyParts,
            icon: "circle",
            v1TargetPoseID: nil
        )
    }
}
