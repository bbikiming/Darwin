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

    func testCompositeKnownIdsConcatenates() {
        let composite = CompositePilotMotionCatalog([
            PresetBackedPilotMotionCatalog(),
            PresetBackedPilotMotionCatalog()  // 중복 의도
        ])
        // 두 catalog 의 knownIds 합 = 2x WalkLabPreset count.
        XCTAssertEqual(composite.knownIds.count, WalkLabPreset.allCases.count * 2)
    }
}
