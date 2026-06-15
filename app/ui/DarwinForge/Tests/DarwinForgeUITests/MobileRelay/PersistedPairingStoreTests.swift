import XCTest
@testable import DarwinForgeUI

final class PersistedPairingStoreTests: XCTestCase {

    /// 각 테스트마다 격리된 UserDefaults suiteName 을 사용해 표준 defaults 를 오염시키지 않는다.
    /// **`--parallel` fix**: suiteName 을 테스트마다 고유(UUID)하게 — 종전 고정 이름은
    /// 6개 테스트가 같은 suite 를 동시에 removePersistentDomain/write 해 서로 오염시켰다.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PersistedPairingStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 저장/읽기 round-trip

    func testWriteThenReadReturnsSameCode() {
        let store = PersistedPairingStore(defaults: defaults)
        store.write("123456")
        XCTAssertEqual(store.read(), "123456")
    }

    func testReadWhenEmptyReturnsNil() {
        let store = PersistedPairingStore(defaults: defaults)
        XCTAssertNil(store.read())
    }

    // MARK: - clear → nil

    func testClearMakesReadReturnNil() {
        let store = PersistedPairingStore(defaults: defaults)
        store.write("999999")
        store.clear()
        XCTAssertNil(store.read())
    }

    // MARK: - 새 store 인스턴스 간 공유 (UserDefaults 공유)

    func testTwoStoreInstancesShareSameDefaults() {
        let storeA = PersistedPairingStore(defaults: defaults)
        let storeB = PersistedPairingStore(defaults: defaults)
        storeA.write("777777")
        XCTAssertEqual(storeB.read(), "777777")
    }

    // MARK: - 빈 문자열 → nil 취급

    func testEmptyStringTreatedAsNil() {
        let store = PersistedPairingStore(defaults: defaults)
        store.write("")
        XCTAssertNil(store.read())
    }

    // MARK: - 덮어쓰기

    func testOverwriteWithNewCode() {
        let store = PersistedPairingStore(defaults: defaults)
        store.write("111111")
        store.write("222222")
        XCTAssertEqual(store.read(), "222222")
    }
}
