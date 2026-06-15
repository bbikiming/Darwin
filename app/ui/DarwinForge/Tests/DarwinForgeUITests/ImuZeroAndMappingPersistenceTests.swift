import XCTest
@testable import DarwinForgeUI

/// **2026-05-31 — A·E 영속 모델 검증**.
///
/// IMU 영점 캘리브레이션과 조종기 매핑 스냅샷이 (1) round-trip 영속되고, (2) canonical
/// 매핑이 누락 없이 보존되는지 확인. 둘 다 "유지/명확 저장" 요구의 회귀 가드.
final class ImuZeroAndMappingPersistenceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test.imuZeroMapping.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - ImuZeroCalibration

    func testImuZeroRoundTripPersists() {
        let defaults = makeDefaults()
        let store = UserDefaultsImuZeroCalibrationStore(defaults: defaults)
        XCTAssertNil(store.load(), "초기 상태는 영점 없음")

        let cal = ImuZeroCalibration(
            pitchZeroDeg: -18.4, rollZeroDeg: 1.2,
            capturedAtISO: "2026-05-31T00:00:00Z",
            sampleCount: 30, source: "auto_stillness"
        )
        store.save(cal)

        let loaded = store.load()
        XCTAssertEqual(loaded, cal, "저장 후 동일 값 복원 — launch 간 영속 보장")
    }

    func testImuZeroOverwriteKeepsLatest() {
        let defaults = makeDefaults()
        let store = UserDefaultsImuZeroCalibrationStore(defaults: defaults)
        store.save(.init(pitchZeroDeg: -20, rollZeroDeg: 0, capturedAtISO: "a", sampleCount: 30, source: "auto_stillness"))
        store.save(.init(pitchZeroDeg: -5, rollZeroDeg: 2, capturedAtISO: "b", sampleCount: 30, source: "manual"))
        XCTAssertEqual(store.load()?.pitchZeroDeg, -5)
        XCTAssertEqual(store.load()?.source, "manual")
    }

    // MARK: - GamepadButtonMapping

    func testMappingRoundTripPersists() {
        let defaults = makeDefaults()
        let store = GamepadMappingStore(defaults: defaults)
        XCTAssertNil(store.load(), "초기 상태는 매핑 없음")

        let mapping = GamepadButtonMapping.current(
            prefs: .defaultValues, nowISO: "2026-05-31T00:00:00Z"
        )
        store.save(mapping)
        XCTAssertEqual(store.load(), mapping, "조종기 매핑 round-trip 영속")
    }

    func testCanonicalMappingCoversCoreActions() {
        let actions = GamepadButtonMapping.canonicalBindings.map { $0.action }.joined(separator: " ")
        // 핵심 동작이 매핑 표에 모두 문서화돼 있어야 한다(회귀 가드).
        for keyword in ["emergency", "march", "slowWalk", "normalWalk", "fastWalk", "recovery"] {
            XCTAssertTrue(actions.contains(keyword), "canonical 매핑에 '\(keyword)' 누락")
        }
        // 버튼 식별자 중복 없음.
        let buttons = GamepadButtonMapping.canonicalBindings.map { $0.button }
        XCTAssertEqual(buttons.count, Set(buttons).count, "버튼 식별자 중복")
    }

    func testMappingSnapshotCarriesSensitivity() {
        let prefs = PilotPreferences(scaleLR: 0.5, scaleFB: 0.6, scaleYaw: 0.3, smoothingFactor: 0.8)
        let mapping = GamepadButtonMapping.current(prefs: prefs, nowISO: "t")
        XCTAssertEqual(mapping.scaleLR, 0.5)
        XCTAssertEqual(mapping.scaleFB, 0.6)
        XCTAssertEqual(mapping.scaleYaw, 0.3)
        XCTAssertEqual(mapping.smoothingFactor, 0.8)
    }
}
