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

    func testCompositeKnownIdsConcatenates() {
        let composite = CompositePilotMotionCatalog([
            PresetBackedPilotMotionCatalog(),
            PresetBackedPilotMotionCatalog()  // 중복 의도
        ])
        // 두 catalog 의 knownIds 합 = 2x WalkLabPreset count.
        XCTAssertEqual(composite.knownIds.count, WalkLabPreset.allCases.count * 2)
    }
}
