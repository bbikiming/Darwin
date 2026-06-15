import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// P0-H 회귀: prebundled motion library 검증.
///
/// 목표:
///   1. 첫 실행 시 사용자가 *바로 실행해 볼* 페이지가 5개 이상.
///   2. 모든 starter 페이지는 walk_ready로 시작·종료 (연속 재생 안전).
///   3. 모든 step의 자세가 16-DOF 중 적어도 1개 이상 채워져 있다.
///   4. 첫 페이지("기본 자세")는 0° idle 자세.
final class StarterMotionLibraryTests: XCTestCase {

    func testStarterPagesAreNotEmpty() {
        let pages = StarterMotionLibrary.starterPages()
        XCTAssertGreaterThanOrEqual(pages.count, 5,
            "P0-H: 첫 실행 motion library에 최소 5 페이지 필요 (idle, T-pose, bow, wave, sit)")
    }

    /// ReferenceMotionLibrary 의 4 카테고리 페이지가 starterPages 에 포함되어야 함.
    /// (walk progression test 6 + ergonomic 케어 + 인사 + 소셜)
    func testReferenceMotionLibraryIsIncluded() {
        let names = StarterMotionLibrary.starterPages().map(\.name)
        // 보행 테스트 6 페이지 — 위험도 오름차순 (1~6)
        for n in 1...6 {
            XCTAssertTrue(
                names.contains(where: { $0.hasPrefix("보행 테스트 \(n) —") }),
                "보행 테스트 \(n) 페이지가 starterPages 에 없음"
            )
        }
        // 카테고리별 대표 페이지가 적어도 하나 있어야 함
        XCTAssertTrue(names.contains(where: { $0.contains("거북목 케어") }), "ergonomic 페이지 없음")
        XCTAssertTrue(names.contains(where: { $0.contains("환영 인사") }), "환영 인사 페이지 없음")
        XCTAssertTrue(names.contains(where: { $0.contains("머리 긁기") }), "HROS5 소셜 페이지 없음")
    }

    /// ReferenceMotionLibrary 의 보행 progression 6 페이지가 walkReady 에서 시작·종료해야 함.
    func testWalkProgressionPagesAreSafe() {
        let pages = ReferenceMotionLibrary.walkProgressionPages(startId: 50)
        XCTAssertEqual(pages.count, 6, "보행 테스트는 정확히 6 페이지")
        for page in pages {
            guard let first = page.steps.first, let last = page.steps.last else {
                XCTFail("page \(page.id) (\(page.name)) — empty"); continue
            }
            XCTAssertEqual(first.toPose(), .walkReady,
                "보행 테스트 \(page.id) — 첫 step 이 walkReady 아님")
            XCTAssertEqual(last.toPose(), .walkReady,
                "보행 테스트 \(page.id) — 마지막 step 이 walkReady 아님")
        }
    }

    func testEveryPageHasAtLeastOneStep() {
        for page in StarterMotionLibrary.starterPages() {
            XCTAssertFalse(page.steps.isEmpty,
                "page \(page.id) (\(page.name)) 에 step이 없음")
        }
    }

    /// 첫 step과 마지막 step이 walk_ready 또는 idle (안전 자세) — 연속 재생 시 호환.
    func testStarterPagesStartAndEndAtSafePose() {
        let safePoses: [RobotPose] = [.walkReady, .idle]
        for page in StarterMotionLibrary.starterPages() {
            guard let firstStep = page.steps.first, let lastStep = page.steps.last else {
                XCTFail("page \(page.id) empty"); return
            }
            XCTAssertTrue(safePoses.contains(firstStep.toPose()),
                "page \(page.id) (\(page.name)) — 시작 자세가 walk_ready/idle 아님")
            XCTAssertTrue(safePoses.contains(lastStep.toPose()),
                "page \(page.id) (\(page.name)) — 종료 자세가 walk_ready/idle 아님 (연속 재생 위험)")
        }
    }

    /// 페이지 ID는 unique. RoboPlus 호환성 위해 중요.
    func testPageIdsAreUnique() {
        let pages = StarterMotionLibrary.starterPages()
        let ids = Set(pages.map(\.id))
        XCTAssertEqual(ids.count, pages.count, "starter page ID 중복")
    }

    /// 첫 페이지는 idle 자세를 시각적으로 보여주는 안내 page.
    func testFirstPageIsIdle() {
        guard let first = StarterMotionLibrary.starterPages().first else {
            XCTFail("no first page"); return
        }
        XCTAssertTrue(first.name.contains("기본") || first.name.lowercased().contains("idle"),
            "첫 페이지는 '기본 자세' 명명 (사용자가 처음 봤을 때 안전 자세를 인지)")
    }

    // MARK: - 사이클 246 (Wave 4.3.1) — starterDoc() 분리 regression guard

    /// `MotionStudioView` 가 첫 로딩 시 호출하는 `starterDoc()` 자체의 회귀 가드.
    /// 분리 전 (사이클 246 이전) 에는 `MotionStudioView.starterDoc()` 형태로 존재.
    func testStarterDocHasMinimumPages() {
        let doc = StarterMotionLibrary.starterDoc()
        XCTAssertGreaterThanOrEqual(doc.pages.count, 5,
                                    "starter 는 최소 5개 페이지 가져야 함")
    }

    /// `starterDoc()` 도 `starterPages()` 와 동일하게 모든 id 가 unique.
    func testStarterDocIDsAreUnique() {
        let doc = StarterMotionLibrary.starterDoc()
        let ids = doc.pages.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "page id 중복 없음")
    }

    /// 모든 페이지가 비어있지 않은 사용자-가독 이름을 가져야 함 (UI 표시 안전성).
    func testStarterDocAllPagesHaveNonEmptyName() {
        let doc = StarterMotionLibrary.starterDoc()
        for page in doc.pages {
            XCTAssertFalse(page.name.isEmpty, "id=\(page.id) name 비어있음")
        }
    }
}
