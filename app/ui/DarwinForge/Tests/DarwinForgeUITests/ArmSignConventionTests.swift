import ForgeCore
import SceneKit
import XCTest

@testable import DarwinForgeUI

/// **Arm sign convention regression** — 2026-05-13 hotfix.
///
/// ROBOTIS-OP2 URDF axis 기준으로 **"팔 앞쪽 = R shoulder pitch 양수, L 음수"** 가
/// 일관되게 적용되는지 확인. 이전엔 PoseLibrary / OfficialCatalogReference 가 정반대
/// 부호로 작성돼 "정면 가리키기" 가 실제로는 팔이 뒤로 가는 버그가 있었다.
///
/// 두 층의 검증:
///   1. **데이터 invariant** — pose 의 R/L abs 같고 부호 반대 (mirror pair),
///      "앞으로" 의도 entry 의 rShoulderPitch 가 양수.
///   2. **Geometry-level** — MeshRig 인스턴스로 pose 를 적용 후, 우측 elbow anchor 의
///      world position 이 walkReady 대비 ROBOTIS forward 방향 (rosToScn 적용 후
///      SceneKit -Z) 으로 이동했는지 확인.
final class ArmSignConventionTests: XCTestCase {

    // MARK: - 1. 데이터 invariant

    /// "정면 가리키기" 의도 자세는 rShoulderPitch 가 반드시 양수여야 한다 (URDF math).
    func testForwardIntentHasPositiveRShoulder() {
        let forwardIntentIds = [
            "point_forward",     // 오른팔 정면
            "handshake",         // 오른팔 앞으로
            "salute",            // 오른팔 위
            "wave_right",        // 오른손 위
        ]
        for id in forwardIntentIds {
            guard let pose = PoseLibrary.get(id)?.pose else {
                XCTFail("PoseLibrary 에서 \(id) 누락")
                continue
            }
            let deg = pose.degrees(.rShoulderPitch)
            XCTAssertGreaterThan(deg, 0,
                "\(id): rShoulderPitch 는 양수여야 함 (URDF axis (0,-1,0) 기준 forward). 실제: \(deg)°")
        }
    }

    /// "팔 위로 / 만세" 의도 자세는 R 양수 / L 음수 mirror pair 여야 한다.
    func testHandsUpHasMirrorPair() {
        let pose = PoseLibrary.get("hands_up")!.pose
        let r = pose.degrees(.rShoulderPitch)
        let l = pose.degrees(.lShoulderPitch)
        XCTAssertGreaterThan(r, 0, "hands_up: rShoulderPitch 양수여야 함. 실제: \(r)°")
        XCTAssertLessThan(l, 0,    "hands_up: lShoulderPitch 음수여야 함. 실제: \(l)°")
        XCTAssertEqual(r + l, 0, accuracy: 2,
            "hands_up: R+L = 0 (mirror pair invariant). 실제: \(r)+\(l)")
    }

    /// OfficialCatalogReference 의 모든 "forward / up" 의도 페이지가 URDF-consistent.
    func testOfficialCatalogArmIntentsArePositive() {
        let pages = OfficialCatalogReference.allPages()
        // thankYou (4), yesGo (23), wow (24), byeBye (38), clapPlease (54) — 모두 팔 앞·위.
        // sitDown (15) — 팔 살짝 앞 (counter-balance, R 양수).
        let armPositiveIds: Set<UInt8> = [4, 23, 24, 38, 54, 15]
        for page in pages where armPositiveIds.contains(page.id) {
            // page 의 중간 step (peak pose) 에서 R shoulder pitch 검사. 마지막 step 은
            // walkReady 복귀라 walkReady baseline 일 수 있어 peak 사용.
            let peakIdx = max(1, page.steps.count / 2)
            let peakPose = page.steps[peakIdx].toPose()
            let deg = peakPose.degrees(.rShoulderPitch)
            XCTAssertGreaterThan(deg, RobotPose.walkReady.degrees(.rShoulderPitch),
                "OfficialCatalog page \(page.id) (\(page.name)): peak step 의 rShoulderPitch 가 " +
                "walkReady (\(RobotPose.walkReady.degrees(.rShoulderPitch))°) 보다 양수쪽이어야 함 (팔 앞·위 의도). 실제: \(deg)°")
        }
    }

    /// 모든 mirror pair 자세는 R/L 부호 반대 + abs 거의 동일. tolerance ±10° —
    /// ROBOTIS walkReady raw (R=-48.34°, L=+41.31°) 자체가 7° 비대칭이라 mirror 자세
    /// 도 같은 비대칭이 R+L 잔차로 나타남. 부호 방향만 확실하면 OK.
    func testMirrorPairInvariantInPoseLibrary() {
        let mirrorIds = [
            "hands_up", "clap_ready", "clap_apart", "pray",
            "fighting_stance", "cheer", "throw_in_ready",
            "tree_pose", "mountain_pose"
        ]
        for id in mirrorIds {
            guard let pose = PoseLibrary.get(id)?.pose else { continue }
            let r = pose.degrees(.rShoulderPitch)
            let l = pose.degrees(.lShoulderPitch)
            // 부호 방향 검증 — 만세류 (R+, L-) 자세 한정.
            XCTAssertGreaterThan(r, 0, "\(id): rShoulderPitch 양수여야 함. 실제: \(r)°")
            XCTAssertLessThan(l, 0,    "\(id): lShoulderPitch 음수여야 함. 실제: \(l)°")
            // abs 차이 ≤ 10° (walkReady 7° 비대칭 + 의도적 미세 조정 여유).
            XCTAssertEqual(abs(r), abs(l), accuracy: 10,
                "\(id): |R| ≈ |L| 이어야 mirror pair. |R|=\(abs(r)), |L|=\(abs(l))")
        }
    }

    /// 다리 / 발목 부호 — 같은 author 실수가 leg motion 에도 있었던 2 차 hotfix 검증.
    func testForwardLegIntentHasNegativeRHipPitch() {
        // "발 앞으로" 의도 자세는 r_hip_pitch 음수 (URDF axis (0,+1,0), 음수 = forward).
        let forwardLegIds = [
            "squat_down",        // 다리 forward squat
            "sit_chair",         // 앉기 (forward flex)
            "lunge_right",       // 오른발 앞 lunge
            "kick_forward_right",// 오른발 앞 차기
            "warrior_pose",      // R 발 앞 yoga
            "soccer_kick_right_swing", // 오른발 임팩트
        ]
        for id in forwardLegIds {
            guard let pose = PoseLibrary.get(id)?.pose else {
                XCTFail("PoseLibrary 에서 \(id) 누락")
                continue
            }
            let deg = pose.degrees(.rHipPitch)
            XCTAssertLessThan(deg, 0,
                "\(id): rHipPitch 음수여야 함 (URDF forward flex). 실제: \(deg)°")
        }
    }

    /// "발 뒤로" 의도 자세는 r_hip_pitch 양수.
    func testBackwardLegIntentHasPositiveRHipPitch() {
        let backwardLegIds = [
            "kick_back_right",          // 오른발 뒤로 빼기
            "soccer_kick_right_back",   // 오른발 백스윙
        ]
        for id in backwardLegIds {
            guard let pose = PoseLibrary.get(id)?.pose else { continue }
            let deg = pose.degrees(.rHipPitch)
            XCTAssertGreaterThan(deg, 0,
                "\(id): rHipPitch 양수여야 함 (R 발 뒤). 실제: \(deg)°")
        }
    }

    /// "왼발 lift / forward" 의도 자세는 l_hip_pitch 양수.
    func testLeftLegLiftHasPositiveLHipPitch() {
        let leftForwardIds = [
            "tree_pose",     // 왼발 들기
        ]
        for id in leftForwardIds {
            guard let pose = PoseLibrary.get(id)?.pose else { continue }
            let deg = pose.degrees(.lHipPitch)
            XCTAssertGreaterThan(deg, 0,
                "\(id): lHipPitch 양수여야 함 (L 발 앞·위). 실제: \(deg)°")
        }
    }

    // MARK: - 2. Geometry-level (MeshRig)

    /// "정면 가리키기" 적용 시 우측 elbow anchor 의 world position 이 ROBOTIS forward
    /// 방향 (SceneKit -Z) 으로 이동했는지 확인.
    ///
    /// rosToScn 행렬: ROS X+(forward) → SceneKit Z-. 따라서 elbow 가 forward 쪽으로
    /// 이동하면 worldPosition.z 가 더 음수가 된다.
    @MainActor
    func testRightElbowMovesForwardWithPositiveShoulderPitch() throws {
        let rig: MeshRig
        do {
            rig = try MeshRig()
        } catch {
            throw XCTSkip("MeshRig STL 로드 실패 — 환경 의존: \(error)")
        }

        // 1) walkReady 적용 → 기준 worldPosition 캡처.
        rig.apply(pose: .walkReady)
        guard let elbowAnchor = rig.joints[.rElbow] else {
            return XCTFail("rElbow anchor 없음")
        }
        // SceneKit 은 transform 평가가 lazy 라 worldTransform 호출 강제.
        let basePos = elbowAnchor.worldPosition

        // 2) point_forward 적용 (rShoulderPitch +90).
        let forwardPose = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: +90)
        ])
        rig.apply(pose: forwardPose)
        let forwardPos = elbowAnchor.worldPosition

        // 검증: SceneKit Z 가 더 음수가 됐어야 forward.
        XCTAssertLessThan(forwardPos.z, basePos.z,
            "rShoulderPitch +90° 후 elbow 의 SceneKit Z (=ROS X 매핑) 가 더 음수여야 함 " +
            "(ROS forward). base z=\(basePos.z), forward z=\(forwardPos.z)")

        // 3) point_backward 확인 (rShoulderPitch -90).
        let backwardPose = RobotPose.walkReady.with([
            .rShoulderPitch: Kinematics.raw(fromDegrees: -90)
        ])
        rig.apply(pose: backwardPose)
        let backwardPos = elbowAnchor.worldPosition
        XCTAssertGreaterThan(backwardPos.z, basePos.z,
            "rShoulderPitch -90° 후 elbow 의 z 가 더 양수여야 함 (ROS backward). " +
            "base z=\(basePos.z), backward z=\(backwardPos.z)")
    }

    /// 좌측도 동일 — lShoulderPitch -90° 가 좌측 elbow 를 forward 로 이동.
    @MainActor
    func testLeftElbowMovesForwardWithNegativeShoulderPitch() throws {
        let rig: MeshRig
        do {
            rig = try MeshRig()
        } catch {
            throw XCTSkip("MeshRig STL 로드 실패: \(error)")
        }

        rig.apply(pose: .walkReady)
        guard let leftElbow = rig.joints[.lElbow] else {
            return XCTFail("lElbow anchor 없음")
        }
        let basePos = leftElbow.worldPosition

        let forwardPose = RobotPose.walkReady.with([
            .lShoulderPitch: Kinematics.raw(fromDegrees: -90)
        ])
        rig.apply(pose: forwardPose)
        let forwardPos = leftElbow.worldPosition

        XCTAssertLessThan(forwardPos.z, basePos.z,
            "lShoulderPitch -90° 후 좌측 elbow 의 z 가 더 음수여야 함 (ROS forward, mirror). " +
            "base z=\(basePos.z), forward z=\(forwardPos.z)")
    }
}

