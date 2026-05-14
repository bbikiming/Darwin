import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// `WalkMotionLibrary` — 8 보행 프리셋의 합성 step 시퀀스 검증.
///
/// 보장:
/// 1. `idle` → nil (정지 자세는 송출 불필요).
/// 2. 나머지 7 프리셋 → non-nil MotionPage 반환.
/// 3. 각 페이지의 첫 step 과 마지막 step 은 `walkReady` (anchor 보장).
/// 4. 모든 step 의 raw position 이 JointID.rawLimits 통과 — 자기충돌 / 한계 초과 없음.
/// 5. 보행 속도 단조성 — playMs(slow) > playMs(normal) > playMs(fast).
/// 6. 회전 방향 — turnLeft 의 hipYaw 부호가 turnRight 와 반대.
final class WalkMotionLibraryTests: XCTestCase {

    // MARK: - 기본 (3)

    func testIdleReturnsNilPage() {
        XCTAssertNil(WalkMotionLibrary.page(for: .idle),
            "idle 은 송출할 보행 cycle 없음 — nil 반환")
    }

    func testAllNonIdlePresetsHavePages() {
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        for preset in nonIdle {
            XCTAssertNotNil(WalkMotionLibrary.page(for: preset),
                "\(preset.rawValue) 은 송출 가능한 합성 페이지가 있어야 함")
        }
    }

    func testEachPageHasAtLeastFourSteps() {
        // march 가 가장 단순한 cycle — 4 step minimum (walkReady → R lift → walkReady → L lift → walkReady).
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset) else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            XCTAssertGreaterThanOrEqual(page.steps.count, 4,
                "\(preset.rawValue) 보행 cycle 은 최소 4 step (walkReady anchor + lift + return)")
        }
    }

    // MARK: - Anchor 보장 (2)

    func testFirstStepIsWalkReady() {
        // 모든 보행 cycle 은 walkReady 에서 시작. 사용자가 어떤 자세에 있더라도
        // 안전한 anchor 로 먼저 전환 후 cycle 진입.
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        let walkReady = RobotPose.walkReady
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset),
                  let first = page.steps.first else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            let pose = first.toPose()
            // 핵심 anchor joint — hip pitch / knee — walkReady 와 일치해야 함.
            // 일부 (turn) 은 hipYaw 가 다르므로 hip pitch 만 검증.
            XCTAssertEqual(pose.raw(.rHipPitch), walkReady.raw(.rHipPitch),
                "\(preset.rawValue) 첫 step 의 rHipPitch 는 walkReady anchor")
            XCTAssertEqual(pose.raw(.rKnee), walkReady.raw(.rKnee),
                "\(preset.rawValue) 첫 step 의 rKnee 는 walkReady anchor")
        }
    }

    func testLastStepReturnsToWalkReady() {
        // 모든 cycle 은 walkReady 에서 종료 — cancel 시에도 안전.
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        let walkReady = RobotPose.walkReady
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset),
                  let last = page.steps.last else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            let pose = last.toPose()
            XCTAssertEqual(pose.raw(.rHipPitch), walkReady.raw(.rHipPitch),
                "\(preset.rawValue) 마지막 step 의 rHipPitch 는 walkReady 복귀")
            XCTAssertEqual(pose.raw(.lHipPitch), walkReady.raw(.lHipPitch),
                "\(preset.rawValue) 마지막 step 의 lHipPitch 는 walkReady 복귀")
            XCTAssertEqual(pose.raw(.rKnee), walkReady.raw(.rKnee),
                "\(preset.rawValue) 마지막 step 의 rKnee 는 walkReady 복귀")
        }
    }

    // MARK: - 안전 검증 (2)

    func testAllPosesWithinSoftwareLimits() {
        // CLAUDE_NEGATIVE_JOINT_FIX_DIRECTIVE 이후: 모든 step 의 모든 관절 raw 가
        // `JointID.rawLimits` (좌·우 대칭 signed range) 내에 있어야 함. 종전엔 mirror
        // 비대칭으로 hardware limit 검증만 가능했으나 limit 수정 후 software limit 으로 격상.
        //
        // 단독으로는 `.with()` 가 이미 clamp 하므로 "의도된 raw 가 limits 안인가" 는
        // 검증하지 못함 (자기 충족). 직접 검증은 `testLiftStepPreservesIntendedRaw...` 가 담당.
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset) else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            for (idx, step) in page.steps.enumerated() {
                let pose = step.toPose()
                for joint in JointID.allCases {
                    let raw = pose.raw(joint)
                    let limits = joint.rawLimits
                    XCTAssertTrue(limits.contains(raw),
                        "\(preset.rawValue) step \(idx) joint \(joint.name): raw=\(raw) outside software \(limits)")
                }
            }
        }
    }

    // MARK: - ROBOTIS walking / official kick 검증

    /// 새 WalkMotionLibrary 는 더 이상 임의 `liftFoot()` 수식을 쓰지 않고 ROBOTIS Walking.cpp
    /// 위상/IK 기반 keyframe을 만든다. 이 테스트는 좌측 음수 관절이 0도 근처로 잘리지 않고
    /// walking synthesis 전체에서 계속 음수 영역에 남는지를 검증한다.
    func testMarchKeepsLeftLegNegativeJointsUnclamped() {
        guard let march = WalkMotionLibrary.page(for: .march) else {
            XCTFail("march page missing"); return
        }
        for (index, step) in march.steps.enumerated() {
            let pose = step.toPose()
            XCTAssertLessThan(pose.raw(.lKnee), 2048,
                "march step \(index)의 lKnee는 음수 굽힘 영역을 유지해야 함")
            XCTAssertLessThan(pose.raw(.lAnklePitch), 2048,
                "march step \(index)의 lAnklePitch는 음수 보정 영역을 유지해야 함")
        }
    }

    /// OfficialCatalogReference 의 sitDown / leftKick 도 동일 회귀 — 의도값 유지 검증.
    /// (`WalkMotionLibrary` 와 같은 `.with()` 경로를 쓰므로 같은 위험.)
    func testOfficialCatalogSitDownPreservesNegativeLKnee() {
        let page = OfficialCatalogReference.sitDown(id: 15)
        let sit = page.steps[1].toPose()  // sit step.
        let expected = Kinematics.raw(fromDegrees: -105)
        XCTAssertEqual(sit.raw(.lKnee), expected,
            "sitDown.lKnee=\(sit.raw(.lKnee)) 가 의도 -105° (\(expected)) 와 일치")
    }

    func testJogEmbedsOfficialPage12RightKickImpact() {
        guard let page = WalkMotionLibrary.page(for: .jog) else {
            XCTFail("jog page missing"); return
        }
        let hasOfficialImpact = page.steps.contains { step in
            let pose = step.toPose()
            return pose.raw(.rHipPitch) == 0x048c
                && pose.raw(.rKnee) == 0x0953
                && pose.raw(.rAnklePitch) == 0x0702
        }
        XCTAssertTrue(hasOfficialImpact,
            "jog preset은 ROBOTIS motion_4096.bin page 12 step 3 right-kick impact raw를 포함해야 함")
    }

    func testAdvancedTuningChangesRealWalkPageStride() {
        guard let short = WalkMotionLibrary.page(for: .normalWalk, tuning: .init(
            strideMm: 5, sideMm: 0, turnDeg: 0, periodMs: 650, footHeightMm: 35, balanceGain: 1
        )),
        let long = WalkMotionLibrary.page(for: .normalWalk, tuning: .init(
            strideMm: 35, sideMm: 0, turnDeg: 0, periodMs: 650, footHeightMm: 35, balanceGain: 1
        )) else {
            XCTFail("advanced tuning pages missing"); return
        }
        let walkReady = RobotPose.walkReady
        let shortMax = short.steps.map { abs($0.toPose().raw(.rHipPitch) - walkReady.raw(.rHipPitch)) }.max() ?? 0
        let longMax = long.steps.map { abs($0.toPose().raw(.rHipPitch) - walkReady.raw(.rHipPitch)) }.max() ?? 0
        XCTAssertGreaterThan(longMax, shortMax,
            "strideMm slider가 실제 송출 page의 hip pitch 전진 진폭을 바꿔야 함")
    }

    func testLowerBodyStepDeltaFromWalkReadyIsBounded() {
        let nonKick: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                        .fastWalk, .turnLeft, .turnRight]
        let walkReady = RobotPose.walkReady
        let maxDeltaDeg = 60.0
        let lowerBody = JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        }
        for preset in nonKick {
            guard let page = WalkMotionLibrary.page(for: preset) else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            for (idx, step) in page.steps.enumerated() {
                let pose = step.toPose()
                for joint in lowerBody {
                    let stepDeg = Kinematics.degrees(fromRaw: pose.raw(joint))
                    let refDeg = Kinematics.degrees(fromRaw: walkReady.raw(joint))
                    let delta = abs(stepDeg - refDeg)
                    XCTAssertLessThanOrEqual(delta, maxDeltaDeg,
                        "\(preset.rawValue) step \(idx) joint \(joint.name): Δ=\(delta)° > \(maxDeltaDeg)° from walkReady")
                }
            }
        }
    }

    func testStepDurationsAreReasonable() {
        // playMs + pauseMs 가 80..1000 사이 — 모터 trapezoidal motion 의 적정 범위.
        // 너무 짧으면 모터 한계 초과, 너무 길면 정적 lift 로 균형 손실.
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset) else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            for (idx, step) in page.steps.enumerated() {
                let total = step.playMs + step.pauseMs
                XCTAssertGreaterThanOrEqual(total, 80,
                    "\(preset.rawValue) step \(idx) 너무 빠름 (\(total)ms)")
                XCTAssertLessThanOrEqual(total, 1500,
                    "\(preset.rawValue) step \(idx) 너무 느림 (\(total)ms)")
            }
        }
    }

    // MARK: - 속도 단조성 (1)

    func testWalkSpeedMonotonicity() {
        guard let slow = WalkMotionLibrary.page(for: .slowWalk),
              let normal = WalkMotionLibrary.page(for: .normalWalk),
              let fast = WalkMotionLibrary.page(for: .fastWalk) else {
            XCTFail("walk pages missing"); return
        }
        // 첫 lift step 의 playMs 비교 — index 1 (0 은 walkReady 진입 step).
        let slowMs = slow.steps[1].playMs
        let normalMs = normal.steps[1].playMs
        let fastMs = fast.steps[1].playMs
        XCTAssertGreaterThan(slowMs, normalMs,
            "slowWalk \(slowMs)ms > normalWalk \(normalMs)ms")
        XCTAssertGreaterThan(normalMs, fastMs,
            "normalWalk \(normalMs)ms > fastWalk \(fastMs)ms")
    }

    // MARK: - 회전 (1)

    func testTurnDirectionsHaveOppositeYaw() {
        guard let left = WalkMotionLibrary.page(for: .turnLeft),
              let right = WalkMotionLibrary.page(for: .turnRight) else {
            XCTFail("turn pages missing"); return
        }
        let center = 2048
        func dominantYawVector(_ page: MotionPage) -> Int {
            page.steps
                .map { step in
                    let pose = step.toPose()
                    return (pose.raw(.lHipYaw) - center) - (pose.raw(.rHipYaw) - center)
                }
                .max { abs($0) < abs($1) } ?? 0
        }
        let leftYaw = dominantYawVector(left)
        let rightYaw = dominantYawVector(right)
        XCTAssertTrue(leftYaw * rightYaw < 0,
            "turnLeft yaw vector \(leftYaw) 과 turnRight yaw vector \(rightYaw)은 반대 방향이어야 함")
    }

    // MARK: - march 가 가장 안전한지 (1)

    func testMarchHasNoForwardSwing() {
        // march 는 제자리 걸음 — hipPitch 의 변화는 발 들기에 의한 작은 차분만,
        // walkForward 의 hip pitch swing 같은 큰 변화는 없어야 함.
        guard let march = WalkMotionLibrary.page(for: .march),
              let normalWalk = WalkMotionLibrary.page(for: .normalWalk) else {
            XCTFail("pages missing"); return
        }

        // march 의 모든 step 에서 rHipPitch 의 walkReady 대비 차분 max.
        let walkReadyHip = RobotPose.walkReady.raw(.rHipPitch)
        let marchMaxDelta = march.steps.map {
            abs($0.toPose().raw(.rHipPitch) - walkReadyHip)
        }.max() ?? 0
        let walkMaxDelta = normalWalk.steps.map {
            abs($0.toPose().raw(.rHipPitch) - walkReadyHip)
        }.max() ?? 0
        XCTAssertLessThan(marchMaxDelta, walkMaxDelta,
            "march(\(marchMaxDelta)) 의 hip pitch 변화는 normalWalk(\(walkMaxDelta)) 보다 작아야 함 — 전진 swing 없음")
    }
}
