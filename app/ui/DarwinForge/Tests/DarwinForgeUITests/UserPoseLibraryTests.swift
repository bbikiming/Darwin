import XCTest
@testable import ForgeCore

/// 사이클 234 — UserPoseLibrary CRUD + 영속화 regression guard.
///
/// UserDefaults 격리: 각 테스트는 독립 suiteName UserDefaults 사용.
@MainActor
final class UserPoseLibraryTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.darwin.test.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeLibrary() -> UserPoseLibrary {
        UserPoseLibrary(defaults: testDefaults)
    }

    private var dummyPose: RobotPose { .center }

    // MARK: - Init

    /// 신규 인스턴스는 비어 있어야 함.
    func testEmptyByDefault() {
        let lib = makeLibrary()
        XCTAssertTrue(lib.entries.isEmpty,
                      "새 인스턴스의 entries 는 비어 있어야 함")
    }

    // MARK: - Save

    /// save 후 entries 에 1건 추가.
    func testSaveAddsEntry() {
        let lib = makeLibrary()
        lib.save(name: "테스트 자세", pose: dummyPose)
        XCTAssertEqual(lib.entries.count, 1)
        XCTAssertEqual(lib.entries.first?.name, "테스트 자세")
        XCTAssertEqual(lib.entries.first?.category, "user")
    }

    /// save 시 빈 이름은 "캡처 N" 으로 자동 부여.
    func testSaveEmptyNameFallback() {
        let lib = makeLibrary()
        lib.save(name: "  ", pose: dummyPose)
        XCTAssertEqual(lib.entries.first?.name, "캡처 1",
                       "빈 이름은 '캡처 N' 으로 대체되어야 함")
    }

    /// save 는 최신 항목이 앞에 (insert at 0).
    func testSaveInsertsAtFront() {
        let lib = makeLibrary()
        lib.save(name: "A", pose: dummyPose)
        lib.save(name: "B", pose: dummyPose)
        XCTAssertEqual(lib.entries.first?.name, "B",
                       "최신 저장 항목이 entries[0] 에 위치해야 함")
    }

    /// keywords 전달 확인.
    func testSaveWithKeywords() {
        let lib = makeLibrary()
        lib.save(name: "인사", pose: dummyPose, keywords: ["greeting", "wave"])
        XCTAssertEqual(lib.entries.first?.keywords, ["greeting", "wave"])
    }

    // MARK: - Remove

    /// remove 후 entries 에서 삭제.
    func testRemoveDeletesEntry() throws {
        let lib = makeLibrary()
        lib.save(name: "삭제 대상", pose: dummyPose)
        lib.save(name: "유지 대상", pose: dummyPose)
        XCTAssertEqual(lib.entries.count, 2)

        let toDelete = try XCTUnwrap(lib.entries.last)
        lib.remove(toDelete)

        XCTAssertEqual(lib.entries.count, 1)
        XCTAssertEqual(lib.entries.first?.name, "유지 대상")
    }

    /// 존재하지 않는 entry remove 는 no-op.
    func testRemoveNonexistentIsNoop() {
        let lib = makeLibrary()
        lib.save(name: "A", pose: dummyPose)
        let fake = UserPoseLibrary.Entry(
            name: "fake", pose: dummyPose
        )
        lib.remove(fake)
        XCTAssertEqual(lib.entries.count, 1,
                       "존재하지 않는 entry 제거는 entries 수에 영향 없어야 함")
    }

    // MARK: - Rename

    /// rename 후 이름 변경.
    func testRenameUpdatesName() throws {
        let lib = makeLibrary()
        lib.save(name: "원래 이름", pose: dummyPose)
        let entry = try XCTUnwrap(lib.entries.first)
        lib.rename(entry, to: "새 이름")
        XCTAssertEqual(lib.entries.first?.name, "새 이름")
    }

    /// 존재하지 않는 entry rename 은 no-op.
    func testRenameNonexistentIsNoop() {
        let lib = makeLibrary()
        lib.save(name: "A", pose: dummyPose)
        let fake = UserPoseLibrary.Entry(name: "fake", pose: dummyPose)
        lib.rename(fake, to: "B")
        XCTAssertEqual(lib.entries.first?.name, "A",
                       "존재하지 않는 entry rename 은 기존 데이터를 변경하지 않아야 함")
    }

    // MARK: - Clear

    /// clear 후 모든 항목 삭제.
    func testClearRemovesAll() {
        let lib = makeLibrary()
        lib.save(name: "A", pose: dummyPose)
        lib.save(name: "B", pose: dummyPose)
        lib.save(name: "C", pose: dummyPose)
        XCTAssertEqual(lib.entries.count, 3)

        lib.clear()

        XCTAssertTrue(lib.entries.isEmpty,
                      "clear 후 entries 는 비어 있어야 함")
    }

    // MARK: - Search

    /// 이름 기반 검색.
    func testSearchByName() {
        let lib = makeLibrary()
        lib.save(name: "인사 자세", pose: dummyPose)
        lib.save(name: "춤 자세", pose: dummyPose)

        let result = lib.search("인사")
        XCTAssertEqual(result?.name, "인사 자세")
    }

    /// keyword 기반 검색.
    func testSearchByKeyword() {
        let lib = makeLibrary()
        lib.save(name: "Greeting", pose: dummyPose, keywords: ["wave", "hello"])

        let result = lib.search("wave")
        XCTAssertEqual(result?.name, "Greeting")
    }

    /// 빈 쿼리는 nil 반환.
    func testSearchEmptyQueryReturnsNil() {
        let lib = makeLibrary()
        lib.save(name: "자세", pose: dummyPose)
        XCTAssertNil(lib.search("  "),
                     "빈/공백 쿼리는 nil 반환해야 함")
    }

    /// 매칭 없으면 nil.
    func testSearchNoMatchReturnsNil() {
        let lib = makeLibrary()
        lib.save(name: "자세 A", pose: dummyPose)
        XCTAssertNil(lib.search("존재하지않는"),
                     "매칭 결과 없으면 nil 반환해야 함")
    }

    /// 대소문자 무시 검색.
    func testSearchCaseInsensitive() {
        let lib = makeLibrary()
        lib.save(name: "HelloPose", pose: dummyPose)
        XCTAssertNotNil(lib.search("hellopose"),
                        "검색은 대소문자를 구분하지 않아야 함")
    }

    // MARK: - Persistence

    /// 다른 인스턴스 간에 데이터 공유 (앱 재시작 시뮬레이션).
    func testPersistsAcrossInstances() {
        let first = makeLibrary()
        first.save(name: "영구 자세 A", pose: dummyPose)
        first.save(name: "영구 자세 B", pose: dummyPose)
        XCTAssertEqual(first.entries.count, 2)

        // 새 인스턴스 생성 — 앱 재시작 시뮬레이션.
        let second = makeLibrary()
        XCTAssertEqual(second.entries.count, 2,
                       "재시작 후 새 인스턴스는 이전 데이터를 유지해야 함")
        XCTAssertEqual(second.entries.first?.name, "영구 자세 B")
    }

    /// remove 후 영속 반영.
    func testRemovePersists() throws {
        let lib = makeLibrary()
        lib.save(name: "삭제할 자세", pose: dummyPose)
        let entry = try XCTUnwrap(lib.entries.first)
        lib.remove(entry)

        let reloaded = makeLibrary()
        XCTAssertTrue(reloaded.entries.isEmpty,
                      "remove 후 재시작해도 삭제 상태가 유지되어야 함")
    }

    /// rename 후 영속 반영.
    func testRenamePersists() throws {
        let lib = makeLibrary()
        lib.save(name: "원래", pose: dummyPose)
        let entry = try XCTUnwrap(lib.entries.first)
        lib.rename(entry, to: "변경됨")

        let reloaded = makeLibrary()
        XCTAssertEqual(reloaded.entries.first?.name, "변경됨",
                       "rename 후 재시작해도 변경된 이름이 유지되어야 함")
    }

    /// clear 후 영속 반영.
    func testClearPersists() {
        let lib = makeLibrary()
        lib.save(name: "임시", pose: dummyPose)
        lib.clear()

        let reloaded = makeLibrary()
        XCTAssertTrue(reloaded.entries.isEmpty,
                      "clear 후 재시작해도 빈 상태가 유지되어야 함")
    }
}
