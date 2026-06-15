import XCTest
@testable import ForgeCore

/// 사이클 245 (W2.6) — `PoseLibrary` 50+ 명명 pose lookup + 무결성 regression guard.
///
/// PoseLibrary 는 50+ NamedPose entry 를 `public static let all` 배열로 제공하며,
/// `get(_:)`, `search(_:)`, `byCategory(_:)` 의 3가지 lookup API 를 노출한다.
/// 이 테스트 묶음은 다음 회귀를 방지한다:
///
///   1. **Lookup API** — `get(_:)` case-sensitive 명세 lock-in, `search(_:)` 빈 입력 처리.
///   2. **Core pose 존재** — `idle / walk_ready / t_pose / bow_30 / wave_right` 등
///      이름이 docs / Pilot v1.5 / Motion Studio starter 페이지에서 hardcoded 로
///      참조되는 pose 가 누락되지 않도록 보장.
///   3. **ID 무결성** — 모든 `id` 가 unique, snake_case 영문 소문자 규약 유지.
///   4. **Category 분포** — 모든 category 가 최소 한 개 pose 를 보유 (UI 그리드에서
///      empty section 이 표시되지 않도록).
///   5. **Metadata** — `displayName`, `description`, `keywords` 가 비어 있지 않음.
///
/// 출처: `Sources/ForgeCore/PoseLibrary.swift`.
final class PoseLibraryTests: XCTestCase {

    // MARK: - Lookup API

    func testGetReturnsKnownPose() {
        XCTAssertNotNil(PoseLibrary.get("walk_ready"),
                        "walk_ready 는 Pilot v1.5 + Motion Studio 의 baseline pose — 누락 금지")
    }

    func testGetReturnsNilForUnknown() {
        XCTAssertNil(PoseLibrary.get("nonexistent_pose_xyz_123"),
                     "존재하지 않는 id 는 nil 반환해야 함 (force-unwrap crash 방지)")
    }

    /// `get(_:)` 는 case-sensitive — id 명세는 snake_case 영문 소문자. 대문자 입력은 nil.
    /// 이 동작이 의도된 명세임을 lock-in (이전에 case-insensitive 로 변경하려는 PR 차단).
    func testGetIsCaseSensitive() {
        XCTAssertNotNil(PoseLibrary.get("walk_ready"))
        XCTAssertNil(PoseLibrary.get("WALK_READY"),
                     "get 은 case-sensitive — 대문자 변종은 nil 반환 명세 lock-in")
        XCTAssertNil(PoseLibrary.get("Walk_Ready"))
    }

    func testGetReturnsNilForEmptyString() {
        XCTAssertNil(PoseLibrary.get(""),
                     "빈 문자열 입력은 nil 반환")
    }

    // MARK: - Core pose 존재 (회귀 가드)

    /// walk_ready — Pilot teleop ARM, BalanceCritical 안전 검증, Motion Studio
    /// starter page 의 baseline. 누락 시 다수 페이지가 빌드 시 컴파일 통과해도
    /// 런타임에 force-unwrap crash 가능.
    func testWalkReadyPoseExists() {
        let pose = PoseLibrary.get("walk_ready")
        XCTAssertNotNil(pose, "walk_ready 누락 — Pilot/Motion Studio baseline")
        XCTAssertEqual(pose?.pose, .walkReady,
                       "walk_ready entry 는 RobotPose.walkReady 와 동일해야 함")
    }

    func testIdlePoseExists() {
        let pose = PoseLibrary.get("idle")
        XCTAssertNotNil(pose, "idle 누락 — 진단/UI default 자세")
        XCTAssertEqual(pose?.pose, .walkReady,
                       "idle 은 워크랩과 동일 RobotPose.walkReady 사용")
    }

    func testTPoseExists() {
        let pose = PoseLibrary.get("t_pose")
        XCTAssertNotNil(pose, "t_pose 누락 — 캘리브레이션 표준")
        XCTAssertEqual(pose?.pose, .tPose,
                       "t_pose entry 는 RobotPose.tPose 와 동일해야 함")
    }

    func testBow30PoseExists() {
        XCTAssertNotNil(PoseLibrary.get("bow_30"),
                        "bow_30 (가벼운 인사) 누락 — greeting category 핵심 entry")
    }

    func testWaveRightPoseExists() {
        XCTAssertNotNil(PoseLibrary.get("wave_right"),
                        "wave_right 누락 — Pilot v1.5 wave 단발 target")
    }

    /// Pilot v1.5 `v1TargetPoseID` set 에 직접 참조되는 핵심 entry — 누락 시
    /// Pilot 화면에서 force-unwrap 또는 빈 그리드 렌더링 발생.
    func testPilotV15CoreEntriesExist() {
        let pilotIds = [
            "walk_ready", "idle", "t_pose",
            "bow_30", "wave_right", "nod_target", "shake_target",
            "hands_up", "salute",
        ]
        for id in pilotIds {
            XCTAssertNotNil(PoseLibrary.get(id),
                            "Pilot v1.5 핵심 entry 누락: \(id)")
        }
    }

    // MARK: - ID 무결성

    /// 모든 NamedPose.id 가 unique 여야 함 — 중복 시 `get(_:)` 가 `first` 만 반환해
    /// 후속 entry 가 silently shadowed 되어 사용자에게 노출되지 않음.
    func testAllPoseIDsAreUnique() {
        let ids = PoseLibrary.all.map { $0.id }
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count,
                       "PoseLibrary.all 에 중복 id 존재 — 중복 = silently shadowed")
        // 중복 진단 추가 정보 — 어떤 id 가 중복인지 출력.
        if ids.count != uniqueIds.count {
            let duplicates = Dictionary(grouping: ids, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
                .sorted()
            XCTFail("중복 id 목록: \(duplicates.joined(separator: ", "))")
        }
    }

    /// 모든 id 가 영문 소문자 + 숫자 + underscore 만 사용하는 snake_case 규약 유지.
    /// 외부 docs / Pilot 화면에서 hardcoded 로 참조되는 식별자이므로 일관성 필수.
    func testAllPoseIDsAreSnakeCase() {
        let pattern = "^[a-z0-9_]+$"
        let regex = try! NSRegularExpression(pattern: pattern)
        for entry in PoseLibrary.all {
            let range = NSRange(entry.id.startIndex..., in: entry.id)
            let match = regex.firstMatch(in: entry.id, range: range)
            XCTAssertNotNil(match,
                            "id '\(entry.id)' 가 snake_case 규약 위반 (영문 소문자 + 숫자 + _ 만 허용)")
        }
    }

    func testAllPoseIDsAreNonEmpty() {
        for entry in PoseLibrary.all {
            XCTAssertFalse(entry.id.isEmpty, "빈 id 발견: displayName=\(entry.displayName)")
        }
    }

    // MARK: - Category 분포

    /// 모든 Category enum case 가 최소 한 개 pose 를 보유 — UI 그리드 empty
    /// section 방지. (새 category 추가 시 최소 한 entry 보장 강제.)
    func testEveryCategoryHasAtLeastOnePose() {
        for category in PoseLibrary.Category.allCases {
            let entries = PoseLibrary.byCategory(category)
            XCTAssertFalse(entries.isEmpty,
                           "Category .\(category) 에 pose 0건 — UI empty section 회귀")
        }
    }

    /// `byCategory(_:)` 가 정확히 해당 category 의 entry 만 반환.
    func testByCategoryReturnsOnlyMatchingEntries() {
        for category in PoseLibrary.Category.allCases {
            let entries = PoseLibrary.byCategory(category)
            for entry in entries {
                XCTAssertEqual(entry.category, category,
                               "byCategory(\(category)) 가 다른 category 의 entry 반환: \(entry.id) = \(entry.category)")
            }
        }
    }

    /// 모든 NamedPose 가 valid Category enum 안에 — Codable round-trip 안전성 보장.
    /// (CaseIterable 안에 없는 raw 값으로 손상된 entry 차단.)
    func testAllPosesHaveValidCategory() {
        let validCategories = Set(PoseLibrary.Category.allCases)
        for entry in PoseLibrary.all {
            XCTAssertTrue(validCategories.contains(entry.category),
                          "\(entry.id): unknown category \(entry.category)")
        }
    }

    // MARK: - Search

    func testSearchByKeywordReturnsMatch() {
        // "wave" 키워드는 wave_right / wave_right_b / wave_left 에 존재.
        let result = PoseLibrary.search("wave")
        XCTAssertNotNil(result, "'wave' 검색은 매치되는 pose 가 있어야 함")
        // id contains "wave" 또는 keywords 에 wave 포함.
        if let r = result {
            let matchedID = r.id.contains("wave")
            let matchedKW = r.keywords.contains(where: { $0.lowercased().contains("wave") })
            XCTAssertTrue(matchedID || matchedKW,
                          "'wave' 검색 결과 \(r.id) 가 wave 와 무관")
        }
    }

    func testSearchByIDReturnsExactMatch() {
        // id contains 가 score +5 로 최고 가중치 — id 완전 일치 시 그 entry 반환.
        let result = PoseLibrary.search("walk_ready")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, "walk_ready",
                       "id 'walk_ready' 검색은 동일 id entry 반환해야 함 (score 가중치)")
    }

    func testSearchEmptyReturnsNil() {
        XCTAssertNil(PoseLibrary.search(""), "빈 검색어는 nil 반환")
        XCTAssertNil(PoseLibrary.search("   "), "공백 only 검색어는 trim 후 nil 반환")
    }

    func testSearchUnknownReturnsNil() {
        // "xqzbgp" — 어떤 id/displayName/keyword/description substring 과도 매치 X.
        // 주의: search 알고리즘은 양방향 contains 검사 (q contains keyword 도 +3 score)
        // → 짧은 keyword ("v", "no") 가 query 안에 substring 으로 들어가면 false-match.
        XCTAssertNil(PoseLibrary.search("xqzbgp"),
                     "어떤 entry 와도 매치 안 되는 검색어는 nil")
    }

    /// 한국어 keyword 검색 지원 — "인사" 는 bow_30 / bow_60 / nod_target 등에 존재.
    func testSearchKoreanKeyword() {
        let result = PoseLibrary.search("인사")
        XCTAssertNotNil(result, "한국어 키워드 '인사' 검색 결과 있어야 함")
    }

    // MARK: - Metadata

    func testAllPosesHaveNonEmptyDisplayName() {
        for entry in PoseLibrary.all {
            XCTAssertFalse(entry.displayName.isEmpty,
                           "\(entry.id): displayName 비어 있음")
        }
    }

    func testAllPosesHaveNonEmptyDescription() {
        for entry in PoseLibrary.all {
            XCTAssertFalse(entry.description.isEmpty,
                           "\(entry.id): description 비어 있음")
        }
    }

    func testAllPosesHaveAtLeastOneKeyword() {
        for entry in PoseLibrary.all {
            XCTAssertFalse(entry.keywords.isEmpty,
                           "\(entry.id): keywords 가 비어 있음 — search 매칭 불가")
        }
    }

    // MARK: - Pose joint coverage

    /// walk_ready 는 ROBOTIS-OP2 20 DOF 모두 명시적으로 정의 (head + arm + leg).
    /// joint coverage 가 부족하면 누락 joint 가 default 2048 (center) 로 fallback 되어
    /// 안전하지 않은 자세가 send 될 위험.
    func testWalkReadyJointCoverageMin() {
        let pose = PoseLibrary.get("walk_ready")?.pose
        XCTAssertNotNil(pose)
        // walk_ready 는 20 joint 모두 정의 (RobotPose.walkReady 정의 참조).
        XCTAssertGreaterThanOrEqual(pose?.positions.count ?? 0, 18,
                                    "walk_ready joint coverage 최소 18 개 (실제로는 20). 누락 시 unsafe default 위험")
    }

    // MARK: - Counts

    /// 50+ NamedPose — docs/PoseLibrary.swift 헤더 주석에서 약속. 회귀 시 명시 실패.
    func testPoseCountIsAtLeast50() {
        XCTAssertGreaterThanOrEqual(PoseLibrary.all.count, 50,
                                    "PoseLibrary 헤더 docstring 의 '50+ 명명 자세' 약속 위반")
    }
}
