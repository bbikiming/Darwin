import Foundation
import XCTest
@testable import DarwinForgeUI

/// **사이클 84 — PilotPreferences 영속화 단위 테스트**.
///
/// In-memory store 와 UserDefaults store 양쪽 검증. UserDefaults 는 isolated suite
/// 사용 — 다른 테스트 / 다른 실행 사이 pollution 차단.
final class PilotPreferencesTests: XCTestCase {

    // MARK: - PilotPreferences value semantics

    func testDefaultValuesMatchTelloRCMapper() {
        let d = PilotPreferences.defaultValues
        XCTAssertEqual(d.scaleLR, 0.3, accuracy: 1e-9, "lr 0.3 (Tello default)")
        XCTAssertEqual(d.scaleFB, 0.4, accuracy: 1e-9, "fb 0.4")
        XCTAssertEqual(d.scaleYaw, 0.2, accuracy: 1e-9, "yaw 0.2")
        XCTAssertEqual(d.smoothingFactor, 1.0, accuracy: 1e-9, "smoothing 1.0 (no smooth)")
    }

    func testEquatable() {
        let a = PilotPreferences.defaultValues
        let b = PilotPreferences.defaultValues
        XCTAssertEqual(a, b)
        let c = PilotPreferences(scaleLR: 0.5, scaleFB: 0.5, scaleYaw: 0.5, smoothingFactor: 0.5)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - InMemoryPilotPreferencesStore

    func testInMemoryStoreInitialIsDefault() {
        let store = InMemoryPilotPreferencesStore()
        XCTAssertEqual(store.load(), .defaultValues, "초기 default")
    }

    func testInMemoryStoreSaveLoad() {
        let store = InMemoryPilotPreferencesStore()
        let custom = PilotPreferences(scaleLR: 0.7, scaleFB: 0.6, scaleYaw: 0.5, smoothingFactor: 0.3)
        store.save(custom)
        XCTAssertEqual(store.load(), custom, "save 후 load 가 정확 값 반환")
    }

    func testInMemoryStoreMultipleOverwrites() {
        let store = InMemoryPilotPreferencesStore()
        let p1 = PilotPreferences(scaleLR: 0.5, scaleFB: 0.5, scaleYaw: 0.5, smoothingFactor: 0.5)
        let p2 = PilotPreferences(scaleLR: 0.9, scaleFB: 0.9, scaleYaw: 0.9, smoothingFactor: 0.9)
        store.save(p1)
        store.save(p2)
        XCTAssertEqual(store.load(), p2, "마지막 save 가 우선")
    }

    // MARK: - UserDefaultsPilotPreferencesStore

    /// UserDefaults 의 isolated suite — 다른 테스트 / 실행 사이 격리.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    func testUserDefaultsStoreInitiallyReturnsDefault() {
        let isolated = makeIsolatedDefaults()
        let store = UserDefaultsPilotPreferencesStore(defaults: isolated)
        XCTAssertEqual(store.load(), .defaultValues,
                       "key 없는 isolated suite → default 반환")
    }

    func testUserDefaultsStoreSaveLoadRoundtrip() {
        let isolated = makeIsolatedDefaults()
        let store = UserDefaultsPilotPreferencesStore(defaults: isolated)
        let custom = PilotPreferences(scaleLR: 0.8, scaleFB: 0.7, scaleYaw: 0.6, smoothingFactor: 0.4)
        store.save(custom)
        XCTAssertEqual(store.load(), custom, "UserDefaults save → load 정확")
    }

    func testUserDefaultsStorePartialKeysFallsBackToDefault() {
        let isolated = makeIsolatedDefaults()
        // 일부 key 만 — load 가 default 반환 (consistency).
        isolated.set(0.8, forKey: "pilot.scaleLR.v1")
        let store = UserDefaultsPilotPreferencesStore(defaults: isolated)
        XCTAssertEqual(store.load(), .defaultValues,
                       "부분 key 만 있으면 default — 일부 corrupt 시 안전 fallback")
    }

    /// **사이클 88 — 코덱스 MEDIUM-1 fix**: String corruption 시 silent 0.0 차단.
    /// 종전: defaults.double(forKey:) 가 String 으로 corrupt 된 값을 0.0 으로 silent 처리 →
    /// scale.fb = 0 → stick 무효화 + 사용자 진단 불가.
    /// 신규: `as? Double` 캐스트 실패 시 default fallback.
    func testUserDefaultsStoreStringCorruptFallsBackToDefault() {
        let isolated = makeIsolatedDefaults()
        // 4 key 모두 존재하지만 1개가 String corrupt (사용자가 직접 plist 편집 시나리오).
        isolated.set(0.5, forKey: "pilot.scaleLR.v1")
        isolated.set("CORRUPT", forKey: "pilot.scaleFB.v1")  // String — Double 아님
        isolated.set(0.3, forKey: "pilot.scaleYaw.v1")
        isolated.set(0.8, forKey: "pilot.smoothingFactor.v1")
        let store = UserDefaultsPilotPreferencesStore(defaults: isolated)
        XCTAssertEqual(store.load(), .defaultValues,
                       "1개라도 Double 아닌 type → 전체 default fallback (silent 0.0 차단)")
    }

    // MARK: - 사이클 88 — 코덱스 HIGH-3 회귀 (concurrent save/load NSLock 검증)

    /// **사이클 88 — 코덱스 HIGH-3 fix**: NSLock 의 race-safety 실증.
    /// concurrent save → load 가 어떤 saved value 든 정확히 반환 (data race / 부분 write 없음).
    func testInMemoryStoreConcurrentSaveLoadIsThreadSafe() {
        let store = InMemoryPilotPreferencesStore()
        let iterations = 100
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()

        // 100 concurrent save + 100 concurrent load.
        for i in 0..<iterations {
            group.enter()
            queue.async {
                let lr = Double(i) / Double(iterations)
                store.save(PilotPreferences(scaleLR: lr, scaleFB: 0.4, scaleYaw: 0.2, smoothingFactor: 1.0))
                group.leave()
            }
            group.enter()
            queue.async {
                _ = store.load()  // crash 없이 정상 반환 (NSLock 동기화).
                group.leave()
            }
        }
        group.wait()

        // 최종 load 는 어떤 saved value (race winner) — 단 부분 write 없음.
        let final = store.load()
        XCTAssertGreaterThanOrEqual(final.scaleLR, 0.0,
                                    "scaleLR 정상 range — 부분 write 부재")
        XCTAssertLessThanOrEqual(final.scaleLR, 1.0)
        // 다른 field 는 변경 안 했으므로 default 유지 확인.
        XCTAssertEqual(final.scaleFB, 0.4, accuracy: 1e-9)
    }

    /// Codable roundtrip — 향후 JSON export 또는 다른 backend 용.
    func testCodableRoundtrip() throws {
        let original = PilotPreferences(scaleLR: 0.5, scaleFB: 0.6, scaleYaw: 0.7, smoothingFactor: 0.8)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PilotPreferences.self, from: data)
        XCTAssertEqual(decoded, original, "Codable roundtrip 정확")
    }
}
