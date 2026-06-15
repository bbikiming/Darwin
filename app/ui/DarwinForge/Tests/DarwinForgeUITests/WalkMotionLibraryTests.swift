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
        // playMs + pauseMs 가 적정 범위 — 모터 trapezoidal motion.
        // **Phase G6 (Codex audit P1-6)**: 임계 80→64 — ROBOTIS 공식 page 12 right kick
        // 의 step 3/5 는 72ms (raw 9 × 8ms) 인데 이전 80ms 임계가 공식 raw 와 충돌.
        // 64ms (raw 8) 는 ROBOTIS 합리적 하한 — MX-28 trapezoidal 의 짧은 swing.
        let nonIdle: [WalkLabPreset] = [.march, .slowWalk, .normalWalk,
                                         .fastWalk, .jog, .turnLeft, .turnRight]
        for preset in nonIdle {
            guard let page = WalkMotionLibrary.page(for: preset) else {
                XCTFail("\(preset.rawValue) page missing"); continue
            }
            for (idx, step) in page.steps.enumerated() {
                let total = step.playMs + step.pauseMs
                XCTAssertGreaterThanOrEqual(total, 64,
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

    // MARK: - Phase G6 (Codex audit P1-6): page 12 official timing

    /// **GPT audit P1-6 (2026-05-14)**: jog preset 의 embedded right kick (page 12) 의
    /// step play/pause 시간이 공식 motion_4096.bin 과 일치해야 한다.
    ///
    /// 공식 timing (`Action.cpp` step.time × 8 ms / step.pause × 8 ms):
    /// | step | play | pause | total |
    /// | 1 | 496 | 0 | 496 |
    /// | 2 | 200 | 0 | 200 |
    /// | 3 | 72 | 0 | 72 |
    /// | 4 | 72 | 144 | 216 |
    /// | 5 | 72 | 0 | 72 |
    /// | 6 | 112 | 0 | 112 |
    /// | 7 | 496 | 0 | 496 |
    /// | sum | 1520 | 144 | **1664** |
    ///
    /// 이전 버전은 step 3-6 의 play 가 160ms 였음 → 총 1976ms = +312ms (+18.75%) 더 길었음.
    func testJogPageEmbedsOfficialPage12KickTiming() {
        guard let jog = WalkMotionLibrary.page(for: .jog) else {
            XCTFail("jog page missing"); return
        }
        // jog page 구조: walkReady anchor + walking 6 phase + page 12 kick 7 step + walkReady anchor
        // = 1 + 6 + 7 + 1 = 15 step. Kick step 은 index 7..=13.
        XCTAssertEqual(jog.steps.count, 15,
            "jog page = 1 anchor + 6 walking phase + 7 kick step + 1 anchor")

        // Step 7~13 이 kick steps — 공식 timing 검증.
        let expectedTiming: [(play: Int, pause: Int)] = [
            (496, 0),     // step 1 — kick 시작
            (200, 0),     // step 2
            (72, 0),      // step 3 — 공식 짧은 빠른 swing
            (72, 144),    // step 4 — 충격 + 144ms hold
            (72, 0),      // step 5
            (112, 0),     // step 6
            (496, 0),     // step 7 — kick 종료
        ]
        let kickSteps = Array(jog.steps[7...13])
        XCTAssertEqual(kickSteps.count, 7)
        for (i, step) in kickSteps.enumerated() {
            XCTAssertEqual(step.playMs, expectedTiming[i].play,
                "kick step \(i+1) play time — 공식: \(expectedTiming[i].play)ms")
            XCTAssertEqual(step.pauseMs, expectedTiming[i].pause,
                "kick step \(i+1) pause time — 공식: \(expectedTiming[i].pause)ms")
        }

        // 총 kick duration 1664ms (공식).
        let kickTotalMs = kickSteps.reduce(0) { $0 + $1.playMs + $1.pauseMs }
        XCTAssertEqual(kickTotalMs, 1664,
            "공식 page 12 kick total = 1520 play + 144 pause = 1664 ms")
    }

    // MARK: - Phase G5 (Codex audit P1-5): MotionCatalog chain duration parity

    /// **GPT audit P1-5**: chain page (24, 38, 54) 의 rawChainDurationMs 가 공식
    /// motion_4096.bin 의 next_page chain 총 시간과 일치해야 한다. 사용자에게 보일 때
    /// "공식 모션" 라벨이면 이 시간 사용 — 단발 자세 durationMs 와 별도.
    func testMotionCatalogChainDurationParity() {
        let chainExpected: [(slot: UInt8, chainMs: UInt32)] = [
            (24, 8192),  // d2 → d2 (chain)
            (38, 7696),  // d2 (=bye bye) chain
            (54, 8296),  // int → 55 → 56 → 58 chain
        ]
        for (slot, expectedChain) in chainExpected {
            guard let meta = MotionCatalog.find(slot: slot) else {
                XCTFail("slot \(slot) missing in catalog"); continue
            }
            XCTAssertEqual(meta.rawChainDurationMs, expectedChain,
                "slot \(slot) (\(meta.rawName)) — 공식 chain duration \(expectedChain)ms")
            // 단발 transition durationMs 는 chain 보다 짧아야 함 — 사용자 혼동 방지.
            XCTAssertLessThan(meta.durationMs, expectedChain,
                "slot \(slot) v1 single-pose durationMs (\(meta.durationMs)) 는 chain (\(expectedChain)) 보다 짧아야 함")
        }
        // single page (next_page=0) 는 rawChainDurationMs = nil 이어야 함.
        for slot: UInt8 in [1, 4, 9, 12, 13, 15] {
            let meta = MotionCatalog.find(slot: slot)!
            XCTAssertNil(meta.rawChainDurationMs,
                "slot \(slot) is single page — rawChainDurationMs must be nil")
        }
    }

    /// **Phase G8 (Codex audit follow-up, 2026-05-15) — 옵션 A**: chain page 의
    /// `isChain` 과 `effectiveDurationMs` computed property 검증. UI 가 caption /
    /// alert 에서 사용.
    func testMotionCatalogChainHelperProperties() {
        // chain page 들 — isChain == true, effectiveDurationMs == rawChainDurationMs.
        for (slot, expectedChain): (UInt8, UInt32) in [(24, 8192), (38, 7696), (54, 8296)] {
            let meta = MotionCatalog.find(slot: slot)!
            XCTAssertTrue(meta.isChain, "slot \(slot) is chain page")
            XCTAssertEqual(meta.effectiveDurationMs, expectedChain,
                "effectiveDurationMs uses chain duration when available")
        }
        // single page — isChain == false, effectiveDurationMs == durationMs.
        for slot: UInt8 in [1, 4, 9, 12, 13, 15] {
            let meta = MotionCatalog.find(slot: slot)!
            XCTAssertFalse(meta.isChain, "slot \(slot) is single page")
            XCTAssertEqual(meta.effectiveDurationMs, meta.durationMs,
                "effectiveDurationMs falls back to durationMs for single page")
        }
    }

    /// **GPT audit P1-5**: page 13 Left Kick 도 v1TargetPoseID 가 있어야 함.
    /// 이전엔 nil 이어서 Right Kick / Left Kick UX 비대칭이었음.
    func testPage13LeftKickHasV1TargetPose() {
        let lk = MotionCatalog.find(slot: 13)!
        XCTAssertNotNil(lk.v1TargetPoseID,
            "page 13 Left Kick v1TargetPoseID 누락 — Pilot 메인 7 비대칭 UX")
        XCTAssertEqual(lk.v1TargetPoseID, "kick_forward_left")
        // PoseLibrary 에 실제로 등록돼 있어야 함.
        XCTAssertNotNil(PoseLibrary.get("kick_forward_left"),
            "kick_forward_left pose 가 PoseLibrary 에 누락")
    }

    /// **GPT audit P1-5**: page 38 raw name 은 공식 bin 에서 `d2` — 이전 `d2 bye` 는 잘못.
    func testPage38RawNameMatchesOfficialBin() {
        let bye = MotionCatalog.find(slot: 38)!
        XCTAssertEqual(bye.rawName, "d2",
            "page 38 raw name 공식 bin = 'd2' (display name 만 'Bye Bye')")
        XCTAssertEqual(bye.displayNameKo, "손 흔들기")  // display 는 자유 — 한국어 라벨 유지
    }

    // MARK: - Phase G10 (2026-05-15): 연속 보행 (Continuous Walking)

    /// **Phase G10**: continuousWalkPlan 이 walking preset (jog 제외) 에 대해 nil 아닌 결과 반환.
    /// jog 와 idle 만 nil.
    func testContinuousWalkPlanAvailableForAllWalkingPresets() {
        let walking: [WalkLabPreset] = [.march, .slowWalk, .normalWalk, .fastWalk, .turnLeft, .turnRight]
        for preset in walking {
            let plan = WalkMotionLibrary.continuousWalkPlan(for: preset)
            XCTAssertNotNil(plan, "\(preset.rawValue) 는 연속 보행 plan 이 있어야 함")
        }
        // jog 는 kick chain 으로 종료되는 단발 — nil.
        XCTAssertNil(WalkMotionLibrary.continuousWalkPlan(for: .jog),
            "jog 는 단발 kick chain — 연속 보행 plan nil")
        // idle 은 합성 페이지 자체가 없음.
        XCTAssertNil(WalkMotionLibrary.continuousWalkPlan(for: .idle))
    }

    /// **Phase G10 핵심**: cycle 부분에 walkReady anchor 가 없어야 함 (매 cycle 끝 끊김 차단).
    /// 6 phase keyframe step 만 — period=600ms 기준 step 마다 100ms playMs.
    func testContinuousWalkPlanCycleHasNoWalkReadyAnchor() {
        let plan = WalkMotionLibrary.continuousWalkPlan(for: .normalWalk)!
        XCTAssertEqual(plan.cycle.count, 6, "cycle = 6 phase keyframe (anchor 없음)")

        let walkReadyPose = RobotPose.walkReady
        for (i, step) in plan.cycle.enumerated() {
            let pose = step.toPose()
            // 자세가 walkReady 와 정확히 일치하지 않아야 함 (그러면 phase keyframe 의미 X).
            // 최소 한 관절은 차이가 있어야 — sparse keyframe 의 의도.
            let allSame = JointID.allCases.allSatisfy { joint in
                pose.raw(joint) == walkReadyPose.raw(joint)
            }
            XCTAssertFalse(allSame,
                "cycle step \(i) 자세가 walkReady 와 동일 — anchor flap 회귀")
        }
    }

    /// **Phase G10**: entry 는 walkReady 자세 (보행 시작 전 자세 정렬) — 1 step.
    /// exit 도 walkReady (보행 종료 후 안전 복귀) — 1 step.
    func testContinuousWalkPlanEntryAndExitAreWalkReadyAnchors() {
        let plan = WalkMotionLibrary.continuousWalkPlan(for: .normalWalk)!
        XCTAssertEqual(plan.entry.count, 1, "entry = walkReady → phase[0] transition 1 step")
        XCTAssertEqual(plan.exit.count, 1, "exit = phase[5] → walkReady 1 step")

        // entry step 의 자세 = walkReady (실제 모터 transition 은 trapezoidal motion).
        let entryPose = plan.entry[0].toPose()
        let walkReadyPose = RobotPose.walkReady
        for joint in JointID.allCases {
            XCTAssertEqual(entryPose.raw(joint), walkReadyPose.raw(joint),
                "entry 자세 — walkReady 와 동일 (\(joint.name))")
        }
        // exit 도 동일.
        let exitPose = plan.exit[0].toPose()
        for joint in JointID.allCases {
            XCTAssertEqual(exitPose.raw(joint), walkReadyPose.raw(joint),
                "exit 자세 — walkReady 와 동일 (\(joint.name))")
        }
    }

    // MARK: - Phase G11 (2026-05-15): 3D 모델 시각화 동기화

    /// **Phase G11**: `simWalkingPose` 가 보행 phase 따라 non-nil pose 반환.
    /// 3D 모델 동기화의 핵심 — sim mode 에서도 모델이 보행 따라 움직이려면 이 함수가
    /// non-trivial pose 반환해야 함.
    func testSimWalkingPoseReturnsNonNilForValidTuning() {
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 25, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0
        )
        // period 600ms 의 phase=0.5 시각 → 한 cycle 중간.
        let pose = WalkMotionLibrary.simWalkingPose(timeMs: 300, tuning: tuning)
        XCTAssertNotNil(pose, "sim walking pose 합성 실패 — 3D 모델 정적 표시될 위험")
    }

    /// **Phase G11**: 다른 시각의 sim pose 는 서로 달라야 함 (정적 표시 회귀 차단).
    func testSimWalkingPoseChangesOverTime() {
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 30, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0
        )
        let poseA = WalkMotionLibrary.simWalkingPose(timeMs: 100, tuning: tuning)!
        let poseB = WalkMotionLibrary.simWalkingPose(timeMs: 300, tuning: tuning)!
        let poseC = WalkMotionLibrary.simWalkingPose(timeMs: 500, tuning: tuning)!

        // 적어도 하나의 다리/팔 관절은 시간에 따라 달라야 함 — 정적 X.
        let mobile: [JointID] = [.rHipPitch, .lHipPitch, .rKnee, .lKnee, .rShoulderPitch, .lShoulderPitch]
        var anyChange = false
        for joint in mobile {
            if poseA.raw(joint) != poseB.raw(joint) || poseB.raw(joint) != poseC.raw(joint) {
                anyChange = true
                break
            }
        }
        XCTAssertTrue(anyChange,
            "sim walking pose 가 시간에 따라 동일 — 3D 모델 정적 표시 회귀")
    }

    /// **Phase G11**: WalkLabSession 의 visualPose 초기값 = walkReady.
    /// 보행 시작 전엔 정적 walkReady 자세로 3D 모델 표시.
    @MainActor
    func testWalkLabSessionInitialVisualPoseIsWalkReady() {
        let session = WalkLabSession()
        // 모든 관절이 walkReady 와 동일.
        let walkReady = RobotPose.walkReady
        for joint in JointID.allCases {
            XCTAssertEqual(session.visualPose.raw(joint), walkReady.raw(joint),
                "visualPose 초기값 \(joint.name) 이 walkReady 와 다름")
        }
    }

    // MARK: - Phase G12 (Codex audit 4th pass, 2026-05-15): preset 별 시각화 차이

    /// **Phase G12 P0 회귀 가드**: 각 preset 의 defaultTuning 이 정확히 다른 값을 가진다.
    /// 이전 버그는 `WalkLabSession.tick` sim mode 가 모든 preset 에 `strideMm: 25` 하드코드
    /// → 어떤 preset 을 선택해도 모델 애니메이션 동일했음. defaultTuning 의 정량 차이가
    /// preset 별 시각화 차이의 근거.
    ///
    /// **v1.8 (2026-05-17) 정정**: 사용자 보고 "회전 동작 괴해짐" + "각 모션 제대로 안 됨".
    /// turn: stride 8 + turnDeg 20° → foot 직진 + hip twist 만 (호 X).
    /// 정정: stride 18 + turnDeg 35° → 진짜 호 그리기. fastWalk stride 45 → 38 (IK 안정 margin).
    func testWalkMotionDefaultTuningDiffersPerPreset() {
        // v1.8 design intent — turn 은 호 그리기 (stride+turn 동시), fast 는 IK 안전 margin.
        let expected: [(preset: WalkLabPreset, stride: Double, turn: Double, period: Double)] = [
            (.march,      0,  0,    650),
            (.slowWalk,   12, 0,    800),  // ~15 mm/s
            (.normalWalk, 28, 0,    600),  // ~47 mm/s
            (.fastWalk,   38, 0,    450),  // ~85 mm/s (45→38 안정성)
            (.turnLeft,   18, 25,   700),  // 호 그리기 (stride 18 + turn 25°, safety-gated)
            (.turnRight,  18, -25,  700),
        ]
        for e in expected {
            let t = WalkMotionLibrary.defaultTuning(for: e.preset)
            XCTAssertEqual(t.strideMm, e.stride, accuracy: 0.01,
                "\(e.preset.rawValue) stride 가 design intent (\(e.stride)) 와 다름")
            XCTAssertEqual(t.turnDeg, e.turn, accuracy: 0.01,
                "\(e.preset.rawValue) turn 이 design intent (\(e.turn)°) 와 다름")
            XCTAssertEqual(t.periodMs, e.period, accuracy: 0.01,
                "\(e.preset.rawValue) period 가 design intent (\(e.period)ms) 와 다름")
        }
    }

    /// **Phase G12 P0 회귀 가드**: preset 별 simWalkingPose 가 서로 다른 자세 합성.
    /// 같은 시각 (timeMs=300ms) 에서 march vs normalWalk 의 hip_pitch / knee 가 raw 단위로
    /// 식별 가능한 차이를 보임. 동일 결과 = 옛 하드코드 회귀.
    func testWalkMotionSimPosesDifferAcrossPresets() {
        let timeMs = 300.0   // 한 cycle 의 절반 지점.
        let presets: [WalkLabPreset] = [.march, .slowWalk, .normalWalk, .fastWalk]
        var hipPitchByPreset: [WalkLabPreset: Int] = [:]
        for p in presets {
            let tuning = WalkMotionLibrary.defaultTuning(for: p)
            let pose = WalkMotionLibrary.simWalkingPose(timeMs: timeMs, tuning: tuning)!
            hipPitchByPreset[p] = pose.raw(.rHipPitch)
        }

        // march (stride=0) 와 fastWalk (stride=32) 의 hip_pitch 가 명확히 다름.
        // strideMm 차이가 32mm — 보행 진폭 차이로 hip 자세 raw 가 최소 5 raw (~0.4°) 이상.
        let marchHip = hipPitchByPreset[.march]!
        let fastHip = hipPitchByPreset[.fastWalk]!
        XCTAssertGreaterThanOrEqual(abs(marchHip - fastHip), 5,
            "march vs fastWalk hip_pitch 차이 < 5 raw — preset 효과가 안 나타남 (옛 하드코드 회귀)")

        // turnLeft vs turnRight 도 검증 — yaw command 가 부호 반대.
        let leftTuning = WalkMotionLibrary.defaultTuning(for: .turnLeft)
        let rightTuning = WalkMotionLibrary.defaultTuning(for: .turnRight)
        let leftPose = WalkMotionLibrary.simWalkingPose(timeMs: timeMs, tuning: leftTuning)!
        let rightPose = WalkMotionLibrary.simWalkingPose(timeMs: timeMs, tuning: rightTuning)!
        // hip_yaw 가 좌우 회전에서 부호 반대 또는 다른 값이어야 함.
        let leftYaw = leftPose.raw(.rHipYaw)
        let rightYaw = rightPose.raw(.rHipYaw)
        XCTAssertNotEqual(leftYaw, rightYaw,
            "turnLeft vs turnRight 의 R_HIP_YAW raw 가 동일 — turn 효과가 안 나타남")
    }

    /// **Phase G12 회귀 가드**: continuousWalkPlan 도 preset 별 다른 cycle 자세 합성.
    /// `WalkMotionLibrary.continuousWalkPlan(for:tuning:)` 의 cycle step 자세 차이로 검증.
    func testContinuousWalkPlanCyclesDifferAcrossPresets() {
        let marchPlan = WalkMotionLibrary.continuousWalkPlan(for: .march)!
        let fastPlan = WalkMotionLibrary.continuousWalkPlan(for: .fastWalk)!
        // 두 plan 모두 6 phase 의 cycle.
        XCTAssertEqual(marchPlan.cycle.count, 6)
        XCTAssertEqual(fastPlan.cycle.count, 6)
        // 같은 phase index 의 자세가 stride 차이로 인해 달라야 함.
        let marchPhase0 = marchPlan.cycle[0].toPose()
        let fastPhase0 = fastPlan.cycle[0].toPose()
        let marchHip = marchPhase0.raw(.rHipPitch)
        let fastHip = fastPhase0.raw(.rHipPitch)
        XCTAssertGreaterThanOrEqual(abs(marchHip - fastHip), 5,
            "march vs fastWalk continuousWalkPlan phase[0] hip 자세 동일 — 하드코드 회귀")
    }

    /// **Phase G10 핵심**: phase 0 (시작) 과 phase 5 (끝) 사이 거리가 매끄러운 wrap 범위.
    /// period=600 ms × 11% (0.92→0.03 사이) ≈ 66 ms 시간 폭 안에서 보간 가능해야.
    /// 너무 큰 차이는 jerk 유발.
    func testContinuousWalkPlanCycleWrapDistanceWithinModerateRange() throws {
        let plan = try XCTUnwrap(WalkMotionLibrary.continuousWalkPlan(for: .normalWalk))
        let firstPose = plan.cycle[0].toPose()
        let lastEntry = try XCTUnwrap(plan.cycle.last)
        let lastPose = lastEntry.toPose()
        // 주요 관절 (hip/knee/ankle) 의 raw 차이 — wrap 시 모터가 한 step 안에 보간해야 함.
        let criticalJoints: [JointID] = [
            .rHipPitch, .lHipPitch, .rKnee, .lKnee, .rAnklePitch, .lAnklePitch
        ]
        for joint in criticalJoints {
            let diff = abs(Int(firstPose.raw(joint)) - Int(lastPose.raw(joint)))
            // 한 cycle 의 wrap 거리 — phase[5]=0.92 → phase[0]=0.03 (대략 같은 위상).
            // ROBOTIS Walking.cpp 의 wrap-around 가 매끄러우니 raw 차이 작아야 함.
            // 500 raw (≈44°) 미만이면 playMs=100ms 안에 모터 trapezoidal 가능.
            XCTAssertLessThan(diff, 500,
                "\(joint.name) wrap 거리 \(diff) raw — 너무 크면 cycle 끊김. 6 sample phase 부족 가능성.")
        }
    }
}
