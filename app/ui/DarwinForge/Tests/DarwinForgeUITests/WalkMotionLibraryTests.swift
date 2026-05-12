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

    // MARK: - .with() clamp 직접 검증 (Codex P2 보강)

    /// Codex 의 P2 지적: `testAllPosesWithinSoftwareLimits` 만으로는 `.with()` 가 이미 clamp
    /// 하므로 "원래 의도한 raw 가 limit 안" 인지 검증 불가 (자기 충족). 본 테스트는 합성 step
    /// 의 raw 가 `Kinematics.raw(fromDegrees:)` 의 원본 계산과 일치하는지 직접 비교한다 —
    /// `.with()` 의 clamp 가 발생했다면 두 값이 달라질 것이므로 false positive 차단.
    ///
    /// march step 1 = `liftFoot(.right, liftDeg: 18)` — 좌발이 지지, mirror joint 의 raw 가
    /// 종전 단방향 `0...150` limits 에서는 잘렸을 자리.
    func testLiftStepPreservesIntendedRawWithoutClamp() {
        guard let march = WalkMotionLibrary.page(for: .march) else {
            XCTFail("march page missing"); return
        }
        let liftDeg: Double = 18  // march 의 내부 상수와 일치.
        let liftR = march.steps[1].toPose()

        // liftFoot(.right) 의 의도된 lKnee = raw(-53 + liftDeg*0.4) ≈ raw(-45.8°).
        // 종전 lKnee.rawLimits=2048...3755 에서는 1527 → 2048 로 clamp (=왼다리 펴짐).
        let expectedLKnee = Kinematics.raw(fromDegrees: -53 + liftDeg * 0.4)
        XCTAssertEqual(liftR.raw(.lKnee), expectedLKnee,
            "march lift R 의 lKnee raw=\(liftR.raw(.lKnee)) 가 의도 \(expectedLKnee) 와 일치 (clamp 없음)")

        // 의도된 lAnklePitch = raw(-30 + liftDeg*0.3) ≈ raw(-24.6°).
        let expectedLAnkle = Kinematics.raw(fromDegrees: -30 + liftDeg * 0.3)
        XCTAssertEqual(liftR.raw(.lAnklePitch), expectedLAnkle,
            "march lift R 의 lAnklePitch 가 의도값 보존 (clamp 없음)")

        // 의도된 lHipPitch = raw(36 - liftDeg*0.2) = raw(32.4°). 항상 양수라 종전에도 OK 였음.
        let expectedLHip = Kinematics.raw(fromDegrees: 36 - liftDeg * 0.2)
        XCTAssertEqual(liftR.raw(.lHipPitch), expectedLHip)
    }

    /// march step 3 = `liftFoot(.left, liftDeg: 18)` — 우 발 지지, 좌 발 들기.
    /// 들린 좌 발의 lKnee 는 walkReady (-53°) 보다 더 음수로 — 가장 종전 clamp 위험 컸음.
    func testLeftLiftStepPreservesLeftKneeNegative() {
        guard let march = WalkMotionLibrary.page(for: .march) else {
            XCTFail("march page missing"); return
        }
        let liftDeg: Double = 18
        let liftL = march.steps[3].toPose()

        // liftFoot(.left) 의 lKnee = raw(-53 - liftDeg) ≈ raw(-71°).
        // 종전 0...150 limits → 1228 (-71° raw) 는 lKnee.rawLimits=2048...3755 밖 → 2048 로 clamp.
        let expectedLKnee = Kinematics.raw(fromDegrees: -53 - liftDeg)
        XCTAssertEqual(liftL.raw(.lKnee), expectedLKnee,
            "march lift L 의 lKnee raw=\(liftL.raw(.lKnee)) 가 의도 -71° (\(expectedLKnee)) 와 일치 — clamp 없음")

        // 우 지지 다리 의도값 — clamp 영향 없는 양수 영역이지만 회귀 보호용.
        let expectedRKnee = Kinematics.raw(fromDegrees: 53 - liftDeg * 0.4)
        XCTAssertEqual(liftL.raw(.rKnee), expectedRKnee)
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

    func testStepDeltaFromWalkReadyIsBounded() {
        // 변화 안전 — 각 step 의 모든 관절 변화량이 walkReady 대비 ±35° 이내.
        // critic 권고: lift step 의 무릎/hip 변화가 35° 를 넘으면 한쪽 발 지지 시
        // 균형 손실 위험 급증. jog 의 swing=16° + lift=22° → 합 38° 인데 부호 분산되어
        // 단일 관절 기준 변화는 30° 이내. 본 테스트는 그 상한.
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        let walkReady = RobotPose.walkReady
        let maxDeltaDeg = 35.0
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset) else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            for (idx, step) in page.steps.enumerated() {
                let pose = step.toPose()
                for joint in JointID.allCases {
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
        // 각 cycle 의 yaw anchor (index 1) hip yaw 비교 — 좌·우가 반대 부호여야 함.
        let leftYawL = left.steps[1].toPose().raw(.lHipYaw)
        let rightYawL = right.steps[1].toPose().raw(.lHipYaw)
        let center = 2048
        // 두 페이지가 center (2048) 의 반대 쪽에 있어야 회전 방향이 명확히 갈림.
        XCTAssertTrue((leftYawL - center) * (rightYawL - center) < 0,
            "turnLeft lHipYaw (\(leftYawL)) 과 turnRight lHipYaw (\(rightYawL)) 은 center=2048 의 반대 방향")
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
