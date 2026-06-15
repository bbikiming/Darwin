import Foundation
import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **사이클 58 — MotionBlender.blendedPose 실 구현 검증**.
@MainActor
final class MotionBlenderBlendedPoseTests: XCTestCase {

    func testBlendedPoseReturnsWalkingWhenIdle() {
        let blender = MotionBlender()
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkingPose: walking)
        XCTAssertEqual(blended, walking, "idle → walking 그대로")
    }

    func testBlendedPoseLegacyAPIDelegates() {
        let blender = MotionBlender()
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkBasePose: walking)
        XCTAssertEqual(blended, walking, "legacy API 동일")
    }

    func testBlendedPoseUpperNilReturnsWalking() {
        let blender = MotionBlender()
        blender.play(.walk(.march))
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkingPose: walking)
        XCTAssertEqual(blended, walking, "lower=walk + upper=nil → walking")
    }

    func testBlendedPoseTeachReturnsSnapPose() {
        let blender = MotionBlender()
        let snap = TeachCapture.PoseSnapshot(
            name: "salute",
            pose: RobotPose.walkReady,
            capturedAt: Date()
        )
        blender.play(.teach(snap))
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkingPose: walking)
        XCTAssertEqual(blended, snap.pose, "teach 자세 전신 반환")
    }

    // MARK: - 추가 — 사용자 요구사항 1~5 커버 (사이클 58 보강)

    /// 임의 walking pose — 다리는 walkReady, 팔은 idle (자연 직립).
    private func walkingPose() -> RobotPose {
        var positions = RobotPose.walkReady.positions
        for joint in JointID.allCases where joint.bodyPart.isUpper {
            positions[joint] = RobotPose.idle.positions[joint] ?? 2048
        }
        return RobotPose(positions: positions)
    }

    private func makeTestPage(
        slot: UInt8,
        bodyParts: [JointID.BodyPart],
        v1TargetPoseID: String? = nil
    ) -> MotionPageMetadata {
        MotionPageMetadata(
            slot: slot, rawName: "TEST",
            displayName: "test", displayNameKo: "테스트",
            safetyClass: .safe, durationMs: 1000, rawChainDurationMs: nil,
            mp3Sync: nil, bodyRegions: bodyParts, icon: "circle",
            v1TargetPoseID: v1TargetPoseID
        )
    }

    /// 요구사항 1: walking pose (lower default + arms neutral) + upper "wave" page
    ///                → lower 그대로 + 팔 wave 자세
    func testWaveRightOverlaysOnlyRightArm() {
        let blender = MotionBlender()
        let wavePage = makeTestPage(
            slot: 38, bodyParts: [.rightArm], v1TargetPoseID: "wave_right"
        )
        blender.play(.page(wavePage))
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking)

        // 다리 — walking 그대로.
        for j: JointID in [.rHipPitch, .lHipPitch, .rKnee, .lKnee, .rAnklePitch, .lAnklePitch] {
            XCTAssertEqual(blended.raw(j), walking.raw(j),
                "\(j.name) — lower 채널 (walking 유지)")
        }
        // 머리 — walking 그대로 (wavePage 가 head 점유 안 함).
        XCTAssertEqual(blended.raw(.headPan), walking.raw(.headPan))
        XCTAssertEqual(blended.raw(.headTilt), walking.raw(.headTilt))

        // 오른팔 — wave_right 자세로 override.
        guard let wavePose = PoseLibrary.get("wave_right")?.pose else {
            XCTFail("wave_right 누락"); return
        }
        XCTAssertEqual(blended.raw(.rShoulderPitch), wavePose.raw(.rShoulderPitch),
            "오른 어깨 pitch wave_right 로")
        XCTAssertEqual(blended.raw(.rElbow), wavePose.raw(.rElbow),
            "오른 팔꿈치 wave_right 로")

        // 왼팔 — page bodyRegions 점유 X → walking 그대로.
        XCTAssertEqual(blended.raw(.lShoulderPitch), walking.raw(.lShoulderPitch))
    }

    /// 요구사항 4: composite motion — lower + upper 각각 채널 적용.
    func testCompositeAppliesBothChannelsIndependently() {
        let blender = MotionBlender()
        let wavePage = makeTestPage(
            slot: 38, bodyParts: [.rightArm], v1TargetPoseID: "wave_right"
        )
        guard let composite = CompositeMotion(
            lower: .walk(.slowWalk), upper: .page(wavePage)
        ) else { XCTFail("composite init"); return }
        blender.play(composite: composite)
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking)

        // lower (walk) — walking 그대로 (walking module 결과가 입력으로 들어옴).
        XCTAssertEqual(blended.raw(.rKnee), walking.raw(.rKnee))
        XCTAssertEqual(blended.raw(.lHipPitch), walking.raw(.lHipPitch))
        // upper (wave_right) — 오른팔 override.
        guard let wavePose = PoseLibrary.get("wave_right")?.pose else {
            XCTFail("wave_right"); return
        }
        XCTAssertEqual(blended.raw(.rShoulderPitch), wavePose.raw(.rShoulderPitch))
    }

    /// 요구사항 3 (강화): alpha 지원 — 0.5 fractional blend.
    func testAlphaHalfReturnsMidpoint() {
        let blender = MotionBlender()
        let wavePage = makeTestPage(
            slot: 38, bodyParts: [.rightArm], v1TargetPoseID: "wave_right"
        )
        blender.play(.page(wavePage))
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking, alpha: 0.5)

        guard let wavePose = PoseLibrary.get("wave_right")?.pose else {
            XCTFail("wave_right"); return
        }
        let expected = Int(
            (Double(walking.raw(.rShoulderPitch)) + Double(wavePose.raw(.rShoulderPitch))) / 2.0
        )
        XCTAssertEqual(blended.raw(.rShoulderPitch), expected, accuracy: 1,
            "alpha=0.5 → 산술 평균 (±1 raw 반올림)")
    }

    /// alpha=0 → walking 만, upper 영향 0.
    func testAlphaZeroIsPureWalking() {
        let blender = MotionBlender()
        let wavePage = makeTestPage(
            slot: 38, bodyParts: [.rightArm], v1TargetPoseID: "wave_right"
        )
        blender.play(.page(wavePage))
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking, alpha: 0.0)

        XCTAssertEqual(blended, walking,
            "alpha=0 → upper 영향 0, walking 그대로")
    }

    /// alpha>1 → 1.0 clamp.
    func testAlphaOverOneClamps() {
        let blender = MotionBlender()
        let wavePage = makeTestPage(
            slot: 38, bodyParts: [.rightArm], v1TargetPoseID: "wave_right"
        )
        blender.play(.page(wavePage))
        let walking = walkingPose()

        let over = blender.blendedPose(walkingPose: walking, alpha: 1.5)
        let full = blender.blendedPose(walkingPose: walking, alpha: 1.0)

        XCTAssertEqual(over, full, "alpha>1 → 1.0 clamp")
    }

    /// emergency kill 후 channels 모두 nil → walking 그대로.
    func testEmergencyKillReturnsWalkingUntouched() {
        let blender = MotionBlender()
        let wavePage = makeTestPage(
            slot: 38, bodyParts: [.rightArm], v1TargetPoseID: "wave_right"
        )
        blender.play(.page(wavePage))
        blender.emergencyKill()
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking)

        XCTAssertEqual(blended, walking, "kill 후 → walking 그대로")
    }

    /// v1TargetPoseID nil (e.g., chain page) → upper override skip, walking 유지.
    func testUpperPageWithoutTargetPoseIDIsNoop() {
        let blender = MotionBlender()
        let chainPage = makeTestPage(
            slot: 10, bodyParts: [.rightArm], v1TargetPoseID: nil
        )
        blender.play(.page(chainPage))
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking)

        XCTAssertEqual(blended, walking,
            "v1TargetPoseID nil → mapping 불가 → walking 유지")
    }

    /// head-only upper motion (nod_target) → 머리만 override, 팔/다리 walking 유지.
    func testHeadOnlyUpperOverridesHeadJointsOnly() {
        let blender = MotionBlender()
        let nodPage = makeTestPage(
            slot: 2, bodyParts: [.head], v1TargetPoseID: "nod_target"
        )
        blender.play(.page(nodPage))
        let walking = walkingPose()

        let blended = blender.blendedPose(walkingPose: walking)

        guard let nodPose = PoseLibrary.get("nod_target")?.pose else {
            XCTFail("nod_target 누락"); return
        }
        XCTAssertEqual(blended.raw(.headTilt), nodPose.raw(.headTilt),
            "headTilt nod_target 으로 override")
        // 팔 — walking 그대로.
        XCTAssertEqual(blended.raw(.rShoulderPitch), walking.raw(.rShoulderPitch))
        // 다리 — walking 그대로.
        XCTAssertEqual(blended.raw(.rKnee), walking.raw(.rKnee))
    }
}
