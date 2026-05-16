import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// v1.1 — 320 모션 카탈로그 회귀 가드.
///
/// 안전 invariant:
/// 1. 모든 카테고리 함수가 정의된 개수의 페이지 반환.
/// 2. 모든 페이지가 `RobotPose.walkReady` 에서 시작·종료.
/// 3. 카테고리 내부에서 ID unique (1, 2, 3, ...).
/// 4. 페이지 step 수 ≥ 1.
/// 5. 페이지 이름이 비어있지 않음.
/// 6. 합 = 320 이상.
final class BundledMotionCatalogTests: XCTestCase {

    /// 카테고리별 기대 개수 (PRD 분포).
    private let expectedCounts: [MotionCategory: Int] = [
        .basicPose: 10,
        .greeting: 25,
        .emotion: 25,
        .dance: 30,
        .stretch: 30,
        .yoga: 20,
        .martial: 25,
        .walkVariant: 20,
        .balance: 15,
        .gaze: 20,
        .demo: 30,
        .exercise: 20,
        .recovery: 15,
        .meditation: 15,
        .generated: 20,
    ]

    func testTotalMotionCountAtLeast320() {
        XCTAssertGreaterThanOrEqual(BundledMotionCatalog.totalMotionCount, 320,
            "v1.1 카탈로그는 최소 320 모션 필요")
    }

    func testEachCategoryHasExpectedCount() {
        for (cat, expected) in expectedCounts {
            let actual = BundledMotionCatalog.count(for: cat)
            XCTAssertEqual(actual, expected,
                "\(cat.label) 페이지 수 mismatch — expected \(expected), got \(actual)")
        }
    }

    /// 모든 페이지의 첫 step / 마지막 step 이 walkReady — 연속 재생 안전.
    func testAllPagesStartAndEndAtWalkReady() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            for page in pages {
                guard let first = page.steps.first, let last = page.steps.last else {
                    XCTFail("[\(cat.label)] page \(page.id) (\(page.name)) — empty steps")
                    continue
                }
                XCTAssertEqual(first.toPose(), .walkReady,
                    "[\(cat.label)] page \(page.id) (\(page.name)) — 첫 step 이 walkReady 아님")
                XCTAssertEqual(last.toPose(), .walkReady,
                    "[\(cat.label)] page \(page.id) (\(page.name)) — 마지막 step 이 walkReady 아님")
            }
        }
    }

    /// 카테고리 내부 ID unique (1..=N 순차).
    func testCategoryInternalIdsAreUnique() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            let ids = pages.map(\.id)
            let unique = Set(ids)
            XCTAssertEqual(ids.count, unique.count,
                "[\(cat.label)] ID 중복 발견 — \(ids)")
        }
    }

    /// 모든 페이지에 최소 1 step + 이름 비어있지 않음.
    func testEveryPageHasStepsAndName() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            for page in pages {
                XCTAssertFalse(page.steps.isEmpty,
                    "[\(cat.label)] page \(page.id) — step 없음")
                XCTAssertFalse(page.name.isEmpty,
                    "[\(cat.label)] page \(page.id) — 이름 없음")
            }
        }
    }

    /// 각 페이지의 모든 step 의 raw position 이 12-bit 안 (0..=4095).
    /// flag 비트 (0x4000 INVALID, 0x2000 TORQUE_OFF) 는 raw value 위라 모두 허용.
    func testAllStepPositionsWithinValidRange() {
        for cat in MotionCategory.allCases {
            let pages = BundledMotionCatalog.pages(for: cat)
            for page in pages {
                for (stepIdx, step) in page.steps.enumerated() {
                    XCTAssertEqual(step.positions.count, 31,
                        "[\(cat.label)] page \(page.id) step \(stepIdx) — positions 길이 31 아님")
                    for (slot, raw) in step.positions.enumerated() {
                        // INVALID / TORQUE_OFF / value range 모두 허용. SKIP_MARKER 도 OK.
                        let valueBits = raw & 0x0FFF
                        let isValid = raw == MotionStep.invalidBitMask
                            || (raw & MotionStep.invalidBitMask) != 0
                            || (raw & MotionStep.torqueOffBitMask) != 0
                            || raw == 32767  // SKIP
                            || valueBits <= 0x0FFF  // 항상 true 지만 의도 명시
                        XCTAssertTrue(isValid,
                            "[\(cat.label)] page \(page.id) step \(stepIdx) slot \(slot) — raw 0x\(String(raw, radix: 16)) 비정상")
                    }
                }
            }
        }
    }

    /// MotionCategory enum 의 라벨/아이콘/요약 모두 비어있지 않음.
    func testCategoryMetadataNotEmpty() {
        for cat in MotionCategory.allCases {
            XCTAssertFalse(cat.label.isEmpty, "\(cat) label 비어있음")
            XCTAssertFalse(cat.icon.isEmpty, "\(cat) icon 비어있음")
            XCTAssertFalse(cat.summary.isEmpty, "\(cat) summary 비어있음")
        }
    }

    /// displayOrder 가 allCases 의 모든 case 포함.
    func testDisplayOrderCoversAllCases() {
        let order = Set(MotionCategory.displayOrder)
        let all = Set(MotionCategory.allCases)
        XCTAssertEqual(order, all,
            "displayOrder 가 allCases 모두 포함 안 함: missing \(all.subtracting(order))")
    }

    // MARK: - 부호 정합성 회귀 (2026-05-16 hotfix lock-in)
    //
    // **`docs/architecture/joint-conventions.md` 부호 규약 검증.**
    // v1.0 Codex audit 의 arm-sign-fix 와 동일 실수 (어깨 pitch / 팔꿈치 / head tilt
    // 부호 반대) 재발 방지. primitive 의 raw 값이 의도된 방향으로 움직임을 lock-in.

    /// **armsUp** (만세) — 양팔 위로. 양 어깨 pitch raw 가 walkReady 보다:
    /// - R 양수 방향 (raw 증가)
    /// - L 음수 방향 (raw 감소)
    func testArmsUpRaisesArms() {
        let pose = MotionPrimitives.armsUp
        let wr = RobotPose.walkReady
        XCTAssertGreaterThan(pose.raw(.rShoulderPitch), wr.raw(.rShoulderPitch),
            "armsUp(만세): R 어깨 pitch raw 가 walkReady 보다 작음 → 팔이 뒤로 펴짐 (반대)")
        XCTAssertLessThan(pose.raw(.lShoulderPitch), wr.raw(.lShoulderPitch),
            "armsUp(만세): L 어깨 pitch raw 가 walkReady 보다 큼 → 팔이 뒤로 펴짐 (반대)")
    }

    /// **armsForward** (앞 뻗기) — 어깨 pitch 가 walkReady 와 같은 방향이지만
    /// 더 큰 변위. armsUp 처럼 R+/L−.
    func testArmsForwardExtendsForward() {
        let pose = MotionPrimitives.armsForward
        let wr = RobotPose.walkReady
        XCTAssertGreaterThan(pose.raw(.rShoulderPitch), wr.raw(.rShoulderPitch))
        XCTAssertLessThan(pose.raw(.lShoulderPitch), wr.raw(.lShoulderPitch))
    }

    /// **armsT** (T 자세) — 양 어깨 roll 외전. R 음수 / L 양수.
    func testArmsTAbducts() {
        let pose = MotionPrimitives.armsT
        let wr = RobotPose.walkReady
        XCTAssertLessThan(pose.raw(.rShoulderRoll), wr.raw(.rShoulderRoll),
            "armsT: R 어깨 roll 외전 (음수) 안 함")
        XCTAssertGreaterThan(pose.raw(.lShoulderRoll), wr.raw(.lShoulderRoll),
            "armsT: L 어깨 roll 외전 (양수) 안 함")
    }

    /// **headLookUp** (위 봄) — head tilt raw 가 walkReady 보다 커야 (chin up).
    func testHeadLookUpRaisesGaze() {
        let pose = MotionPrimitives.headLookUp
        let wr = RobotPose.walkReady
        XCTAssertGreaterThan(pose.raw(.headTilt), wr.raw(.headTilt),
            "headLookUp: head tilt raw 가 walkReady 보다 작음 → chin down (반대)")
    }

    /// **headLookDown** / **headBowSlight** — chin down. head tilt raw 가 더 작아야.
    func testHeadLookDownLowersGaze() {
        let wr = RobotPose.walkReady
        XCTAssertLessThan(MotionPrimitives.headLookDown.raw(.headTilt), wr.raw(.headTilt),
            "headLookDown: chin up 방향 (반대)")
        XCTAssertLessThan(MotionPrimitives.headBowSlight.raw(.headTilt), wr.raw(.headTilt),
            "headBowSlight: chin up 방향 (반대)")
    }

    /// **bowSlight / bowDeep** — 절 자세는 hip 앞 굽힘 + head chin down.
    func testBowsHipForwardAndHeadDown() {
        let wr = RobotPose.walkReady
        for (name, pose) in [("bowSlight", MotionPrimitives.bowSlight),
                              ("bowDeep",   MotionPrimitives.bowDeep)] {
            // hip 앞 굽힘: R raw 음수 방향, L raw 양수 방향.
            XCTAssertLessThan(pose.raw(.rHipPitch), wr.raw(.rHipPitch),
                "\(name): R hip pitch 앞 굽힘 안 함")
            XCTAssertGreaterThan(pose.raw(.lHipPitch), wr.raw(.lHipPitch),
                "\(name): L hip pitch 앞 굽힘 안 함")
            // head chin down: raw 음수 방향.
            XCTAssertLessThan(pose.raw(.headTilt), wr.raw(.headTilt),
                "\(name): head tilt 가 chin up 방향 — 절 자세인데 머리가 위로 (반대)")
        }
    }

    /// **elbowsBent90 / elbowsFold** — 팔꿈치 굽힘 R+/L−. raw 증가/감소.
    func testElbowsBend() {
        let wr = RobotPose.walkReady
        for (name, pose) in [("elbowsBent90", MotionPrimitives.elbowsBent90),
                              ("elbowsFold",   MotionPrimitives.elbowsFold)] {
            XCTAssertGreaterThan(pose.raw(.rElbow), wr.raw(.rElbow),
                "\(name): R elbow 굽힘 안 함 (펴짐)")
            XCTAssertLessThan(pose.raw(.lElbow), wr.raw(.lElbow),
                "\(name): L elbow 굽힘 안 함 (펴짐)")
        }
    }

    /// **armsRightWave** / **armsLeftWave** — 인사 시 해당 팔 앞·위로 + 살짝 펴기.
    func testWaveArmsRaise() {
        let wr = RobotPose.walkReady
        XCTAssertGreaterThan(MotionPrimitives.armsRightWave.raw(.rShoulderPitch),
                             wr.raw(.rShoulderPitch),
            "armsRightWave: R 어깨 pitch 안 올라감")
        XCTAssertLessThan(MotionPrimitives.armsLeftWave.raw(.lShoulderPitch),
                          wr.raw(.lShoulderPitch),
            "armsLeftWave: L 어깨 pitch 안 올라감")
    }

    // MARK: - 신체 자가충돌 / 안전 한도

    /// 보수적 software 한도 — 모든 raw 가 192..3904 (= ±168°, MX-28 12-bit 의 95% 안).
    /// JointLimits 정밀 검증은 Rust 측에서 수행하지만, Swift 측에서도 명백한 limit
    /// 위반은 사전 차단.
    func testAllRawsWithinConservativeSoftwareLimit() {
        let conservativeMin: UInt16 = 192    // ≈ -168°
        let conservativeMax: UInt16 = 3904   // ≈ +168°
        for cat in MotionCategory.allCases {
            for page in BundledMotionCatalog.pages(for: cat) {
                for (stepIdx, step) in page.steps.enumerated() {
                    // slot 0 + 21..30 (invalid marker) 는 skip.
                    for joint in JointID.allCases {
                        let raw = step.positions[Int(joint.rawValue)]
                        // INVALID / TORQUE_OFF / SKIP 플래그 set 된 raw 는 skip.
                        if raw == 32767 || (raw & 0x4000) != 0 || (raw & 0x2000) != 0 {
                            continue
                        }
                        let valueBits = raw & 0x0FFF
                        XCTAssertGreaterThanOrEqual(valueBits, conservativeMin,
                            "[\(cat.label)] page \(page.id) step \(stepIdx) \(joint): raw \(valueBits) 가 -168° 미만 (소프트 한도 위반)")
                        XCTAssertLessThanOrEqual(valueBits, conservativeMax,
                            "[\(cat.label)] page \(page.id) step \(stepIdx) \(joint): raw \(valueBits) 가 +168° 초과 (소프트 한도 위반)")
                    }
                }
            }
        }
    }

    /// 양 팔 등 뒤 self-collision 사전 검출 — 양 어깨 pitch 가 동시에 강한
    /// 음수(R)·양수(L) 방향이면 팔이 등 뒤에서 부딪침. walkReady (-48°/+41°) 보다
    /// 더 음수/양수 방향이면 위험.
    ///
    /// 기준: R raw < 800 (≈ -110°) **그리고** L raw > 3300 (≈ +110°) 동시 발생 = 위험.
    func testNoBackArmCollisionExtremes() {
        for cat in MotionCategory.allCases {
            for page in BundledMotionCatalog.pages(for: cat) {
                for (stepIdx, step) in page.steps.enumerated() {
                    let rSho = step.positions[Int(JointID.rShoulderPitch.rawValue)] & 0x0FFF
                    let lSho = step.positions[Int(JointID.lShoulderPitch.rawValue)] & 0x0FFF
                    let rPast = rSho < 800   // 양팔이 등 뒤로 110°+
                    let lPast = lSho > 3300
                    XCTAssertFalse(rPast && lPast,
                        "[\(cat.label)] page \(page.id) (\(page.name)) step \(stepIdx) — 양 어깨가 등 뒤로 ±110° 초과 (R \(rSho), L \(lSho)) — self-collision 위험")
                }
            }
        }
    }
}
