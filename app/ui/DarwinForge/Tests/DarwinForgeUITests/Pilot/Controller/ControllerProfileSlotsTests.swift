import XCTest
@testable import DarwinForgeUI

/// `ControllerProfileSlots` — 프로파일 슬롯 (설계 §E, Xbox 액세서리 패턴, 불변 값 타입).
final class ControllerProfileSlotsTests: XCTestCase {

    func test_default_has_single_xbox_slot() {
        let slots = ControllerProfileSlots.default
        XCTAssertEqual(slots.profiles.count, 1)
        XCTAssertEqual(slots.activeIndex, 0)
        XCTAssertEqual(slots.active, .xbox)
    }

    func test_selecting_clamps_out_of_range() {
        let slots = ControllerProfileSlots.default.selecting(99)
        XCTAssertEqual(slots.activeIndex, 0)
    }

    func test_updating_active_replaces_only_active_profile() {
        var custom = ControllerBindingProfile.xbox
        custom.name = "커스텀"
        let slots = ControllerProfileSlots.default.updatingActive(custom)
        XCTAssertEqual(slots.active.name, "커스텀")
        XCTAssertEqual(slots.profiles.count, 1)
    }

    func test_duplicate_appends_copy_and_selects_it() {
        let slots = ControllerProfileSlots.default.addingDuplicateOfActive()
        XCTAssertEqual(slots.profiles.count, 2)
        XCTAssertEqual(slots.activeIndex, 1)
        XCTAssertEqual(slots.active.name, "Xbox / RG G01 (기본) 사본")
        XCTAssertEqual(slots.active.bindings, ControllerBindingProfile.xbox.bindings)
    }

    func test_duplicate_name_collision_numbered() {
        let slots = ControllerProfileSlots.default
            .addingDuplicateOfActive()
            .selecting(0)
            .addingDuplicateOfActive()
        XCTAssertEqual(slots.profiles.count, 3)
        XCTAssertEqual(slots.active.name, "Xbox / RG G01 (기본) 사본 2")
    }

    func test_duplicate_respects_max_slot_count() {
        var slots = ControllerProfileSlots.default
        for _ in 0..<20 { slots = slots.addingDuplicateOfActive() }
        XCTAssertEqual(slots.profiles.count, ControllerProfileSlots.maxSlots)
    }

    func test_removing_active_keeps_at_least_one() {
        let slots = ControllerProfileSlots.default.removingActive()
        XCTAssertEqual(slots.profiles.count, 1)
    }

    func test_removing_active_adjusts_index() {
        let slots = ControllerProfileSlots.default
            .addingDuplicateOfActive()
            .removingActive()
        XCTAssertEqual(slots.profiles.count, 1)
        XCTAssertEqual(slots.activeIndex, 0)
        XCTAssertEqual(slots.active, .xbox)
    }
}

/// `ControllerBindingProfileStore` 슬롯 영속화 + v1 → v2 마이그레이션.
final class ControllerProfileSlotsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "test.controller.profile.slots"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_load_slots_defaults_to_xbox() {
        XCTAssertEqual(ControllerBindingProfileStore.loadSlots(defaults), .default)
    }

    func test_slots_roundtrip() {
        let slots = ControllerProfileSlots.default.addingDuplicateOfActive()
        ControllerBindingProfileStore.saveSlots(slots, into: defaults)
        XCTAssertEqual(ControllerBindingProfileStore.loadSlots(defaults), slots)
    }

    func test_migrates_v1_single_profile_to_slot_zero() {
        var legacy = ControllerBindingProfile.xbox
        legacy.name = "레거시 v1"
        ControllerBindingProfileStore.save(legacy, into: defaults)
        let slots = ControllerBindingProfileStore.loadSlots(defaults)
        XCTAssertEqual(slots.profiles.count, 1)
        XCTAssertEqual(slots.active.name, "레거시 v1")
    }

    func test_save_slots_keeps_v1_in_sync_with_active() {
        var custom = ControllerBindingProfile.xbox
        custom.name = "동기화 확인"
        let slots = ControllerProfileSlots.default.updatingActive(custom)
        ControllerBindingProfileStore.saveSlots(slots, into: defaults)
        XCTAssertEqual(ControllerBindingProfileStore.load(defaults).name, "동기화 확인")
    }
}
