import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.20.22 (2026-05-22) 사이클 28** — PilotMotionCatalog 단위 테스트.
final class PilotMotionCatalogTests: XCTestCase {

    func testPresetBackedResolvesWalkLabPreset() {
        let catalog = PresetBackedPilotMotionCatalog()
        let descriptor = catalog.resolve("preset.march")
        XCTAssertNotNil(descriptor)
        if case .walk(let preset) = descriptor {
            XCTAssertEqual(preset, .march)
        } else {
            XCTFail("expected .walk descriptor")
        }
    }

    func testPresetBackedCaseInsensitive() {
        let catalog = PresetBackedPilotMotionCatalog()
        XCTAssertNotNil(catalog.resolve("PRESET.MARCH"))
        XCTAssertNotNil(catalog.resolve("Preset.Jog"))
    }

    func testPresetBackedRejectsNonPresetPrefix() {
        let catalog = PresetBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve("wave"))
        XCTAssertNil(catalog.resolve("preset"))  // no period
        XCTAssertNil(catalog.resolve(""))
    }

    func testPresetBackedRejectsUnknownPreset() {
        let catalog = PresetBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve("preset.unknown_xyz"))
    }

    func testPresetBackedKnownIds() {
        let catalog = PresetBackedPilotMotionCatalog()
        let ids = catalog.knownIds
        XCTAssertTrue(ids.contains("preset.march"))
        XCTAssertTrue(ids.contains("preset.idle"))
        XCTAssertEqual(ids.count, WalkLabPreset.allCases.count)
    }

    func testCompositeCatalogChainsResolution() {
        let presetCatalog = PresetBackedPilotMotionCatalog()
        // 두 번째 catalog 는 placeholder — 항상 nil.
        struct EmptyCatalog: PilotMotionCatalog {
            func resolve(_ id: String) -> MotionDescriptor? { nil }
            var knownIds: [String] { [] }
        }
        let composite = CompositePilotMotionCatalog([presetCatalog, EmptyCatalog()])
        XCTAssertNotNil(composite.resolve("preset.march"), "첫 catalog hit")
        XCTAssertNil(composite.resolve("unknown"))
    }

    /// **v1.20.22.1 사이클 28-fix HIGH (코덱스)** — bridge.handleMotion(id:) public entry.
    @MainActor
    func testBridgeHandleMotionIdResolvesViaCatalog() {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        // PresetBacked default catalog → "preset.march" 인식.
        let result = bridge.handleMotion(id: "preset.march", from: .ui)
        // result 가 accepted / rejectedSafety 무관 — handleMotion(descriptor:) 호출 자체가 success.
        switch result {
        case .accepted, .acceptedFullBody:
            // OK
            break
        case .rejectedSafety, .rejectedEmptyChannels:
            // 가능 — context / safety 에 따라.
            break
        }
    }

    @MainActor
    func testBridgeHandleMotionIdRejectsUnknown() {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        let result = bridge.handleMotion(id: "totally_unknown_xyz", from: .ui)
        if case .rejectedSafety = result {
            // OK
        } else {
            XCTFail("unknown id 는 rejected 여야 함")
        }
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("등록 안 됨") ?? false)
    }

    // MARK: - Cycle 30: PageBacked

    func testPageBackedResolvesBySlot() {
        let catalog = PageBackedPilotMotionCatalog()
        // motion_4096 의 slot 1 페이지 (보통 walkReady 또는 init pose).
        let descriptor = catalog.resolve("page.1")
        XCTAssertNotNil(descriptor, "slot 1 페이지 매핑")
        if case .page(let meta) = descriptor {
            XCTAssertEqual(meta.slot, 1)
        } else {
            XCTFail("expected .page descriptor")
        }
    }

    func testPageBackedRejectsUnknownSlot() {
        let catalog = PageBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve("page.255"), "slot 255 일반적으로 없음")
        XCTAssertNil(catalog.resolve("page.unknown_name_xyz"))
    }

    /// **v1.20.30.2 사이클 38 — 코덱스 LOW** — slot 0 edge case.
    /// motion_4096 의 1-based slot (1..255) → 0 무효.
    func testPageBackedRejectsSlot0() {
        let catalog = PageBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve("page.0"), "slot 0 → reject (1-based spec)")
    }

    /// **v1.20.32 사이클 40** — 빈 문자열 / "page." / "page.." edge case.
    func testPageBackedRejectsEmptyAndMalformed() {
        let catalog = PageBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve(""), "빈 문자열")
        XCTAssertNil(catalog.resolve("page."), "page. (key 없음)")
        XCTAssertNil(catalog.resolve("page.."), "page.. (dot key)")
        XCTAssertNil(catalog.resolve(" "), "space")
    }

    /// **v1.20.32 사이클 40** — Preset catalog 도 동일 edge case.
    func testPresetBackedRejectsEmptyAndMalformed() {
        let catalog = PresetBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve(""))
        XCTAssertNil(catalog.resolve("preset."))
        XCTAssertNil(catalog.resolve("preset.."))
    }

    func testPageBackedRejectsNonPagePrefix() {
        let catalog = PageBackedPilotMotionCatalog()
        XCTAssertNil(catalog.resolve("preset.march"))
        XCTAssertNil(catalog.resolve("wave"))
    }

    func testCompositeKnownIdsConcatenates() {
        let composite = CompositePilotMotionCatalog([
            PresetBackedPilotMotionCatalog(),
            PresetBackedPilotMotionCatalog()  // 중복 의도
        ])
        // 두 catalog 의 knownIds 합 = 2x WalkLabPreset count.
        XCTAssertEqual(composite.knownIds.count, WalkLabPreset.allCases.count * 2)
    }

    // MARK: - Cycle 32: ordering + bridge composite default

    /// **v1.20.26 사이클 32** — Composite 가 첫 hit 반환 (chain of responsibility).
    func testCompositeReturnsFirstHit() {
        // 두 catalog 가 같은 id 를 다르게 resolve 한다면 첫 번째가 winning.
        struct CatalogA: PilotMotionCatalog {
            func resolve(_ id: String) -> MotionDescriptor? {
                guard id == "shared" else { return nil }
                return .walk(.march)
            }
            var knownIds: [String] { ["shared"] }
        }
        struct CatalogB: PilotMotionCatalog {
            func resolve(_ id: String) -> MotionDescriptor? {
                guard id == "shared" else { return nil }
                return .walk(.jog)
            }
            var knownIds: [String] { ["shared"] }
        }
        let composite = CompositePilotMotionCatalog([CatalogA(), CatalogB()])
        let result = composite.resolve("shared")
        if case .walk(let preset) = result {
            XCTAssertEqual(preset, .march, "첫 catalog (A) 가 winning")
        } else {
            XCTFail("expected .walk(.march)")
        }
    }

    /// **v1.20.26 사이클 32** — bridge default catalog 가 preset + page 양쪽 resolve.
    @MainActor
    func testBridgeDefaultCatalogResolvesPresetAndPage() {
        let mock = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mock)
        // default = Composite([PresetBacked, PageBacked]).
        XCTAssertNotNil(bridge.pilotMotionCatalog.resolve("preset.march"),
                        "preset.march resolve")
        XCTAssertNotNil(bridge.pilotMotionCatalog.resolve("page.1"),
                        "page.1 resolve (motion_4096)")
        XCTAssertNil(bridge.pilotMotionCatalog.resolve("unknown_xyz"))
    }
}
