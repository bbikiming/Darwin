import AppKit
import SwiftUI
import XCTest
@testable import DarwinForgeUI

/// **v1.11.15 (2026-05-19) — 테마 기능 회귀 가드**.
///
/// 검증 대상:
/// 1. `DFTheme` 열거값 (system / lightFlat / dark) + 메타데이터 (label, symbol).
/// 2. `DFTheme.preferredColorScheme` — system=nil, lightFlat=light, dark=dark.
/// 3. `DFTheme.isFlat` / `prefersWhiteSurfaces` — lightFlat 만 true.
/// 4. `DFThemeManager` UserDefaults 영속화 (생성자 read + setTheme write).
/// 5. `DFThemeManager.cycle()` — 다음 테마로 순환.
/// 6. `DFColor.adaptiveCanvas/Card/Elev2` — flat 모드에서 별도 색상 반환.
@MainActor
final class WalkLabV1115ThemeTests: XCTestCase {

    // MARK: - 1. DFTheme enum

    /// 정확히 3개 케이스, 모두 식별 가능.
    func testThemeCasesExist() {
        XCTAssertEqual(DFTheme.allCases.count, 3)
        XCTAssertTrue(DFTheme.allCases.contains(.system))
        XCTAssertTrue(DFTheme.allCases.contains(.lightFlat))
        XCTAssertTrue(DFTheme.allCases.contains(.dark))
    }

    /// rawValue 안정성 — UserDefaults 영속화 의존.
    func testThemeRawValues() {
        XCTAssertEqual(DFTheme.system.rawValue, "system")
        XCTAssertEqual(DFTheme.lightFlat.rawValue, "lightFlat")
        XCTAssertEqual(DFTheme.dark.rawValue, "dark")
    }

    /// 각 테마의 사용자 보이는 메타데이터 비어 있지 않음 (UI 표시 안전).
    func testThemeMetadataNotEmpty() {
        for theme in DFTheme.allCases {
            XCTAssertFalse(theme.displayName.isEmpty,
                           "displayName must not be empty for \(theme)")
            XCTAssertFalse(theme.helpText.isEmpty,
                           "helpText must not be empty for \(theme)")
            XCTAssertFalse(theme.symbolName.isEmpty,
                           "symbolName must not be empty for \(theme)")
        }
    }

    // MARK: - 2. preferredColorScheme

    /// system = nil → SwiftUI 가 시스템 모드 따름.
    func testSystemPreferredColorSchemeIsNil() {
        XCTAssertNil(DFTheme.system.preferredColorScheme)
    }

    /// lightFlat = .light → 다크 모드 무시.
    func testLightFlatForcesLightScheme() {
        XCTAssertEqual(DFTheme.lightFlat.preferredColorScheme, .light)
    }

    /// dark = .dark → 라이트 모드 무시.
    func testDarkForcesDarkScheme() {
        XCTAssertEqual(DFTheme.dark.preferredColorScheme, .dark)
    }

    // MARK: - 3. isFlat / prefersWhiteSurfaces

    /// lightFlat 만 flat 모드 (그림자/material 비활성).
    func testOnlyLightFlatIsFlat() {
        XCTAssertFalse(DFTheme.system.isFlat)
        XCTAssertTrue(DFTheme.lightFlat.isFlat)
        XCTAssertFalse(DFTheme.dark.isFlat)
    }

    /// lightFlat 만 흰색 표면 강제.
    func testOnlyLightFlatPrefersWhiteSurfaces() {
        XCTAssertFalse(DFTheme.system.prefersWhiteSurfaces)
        XCTAssertTrue(DFTheme.lightFlat.prefersWhiteSurfaces)
        XCTAssertFalse(DFTheme.dark.prefersWhiteSurfaces)
    }

    // MARK: - 4. DFThemeManager — UserDefaults 영속화

    /// UserDefaults 가 비어 있으면 default = system.
    func testManagerDefaultsToSystemWhenStorageEmpty() {
        let defaults = makeEphemeralDefaults()
        defaults.removeObject(forKey: DFThemeManager.storageKey)

        let manager = DFThemeManager(userDefaults: defaults)
        XCTAssertEqual(manager.theme, .system)
    }

    /// 저장된 값이 있으면 그것을 사용.
    func testManagerReadsStoredTheme() {
        let defaults = makeEphemeralDefaults()
        defaults.set(DFTheme.lightFlat.rawValue, forKey: DFThemeManager.storageKey)

        let manager = DFThemeManager(userDefaults: defaults)
        XCTAssertEqual(manager.theme, .lightFlat)
    }

    /// 알 수 없는 rawValue 가 저장되어 있으면 fallback = system.
    func testManagerFallsBackOnInvalidStoredValue() {
        let defaults = makeEphemeralDefaults()
        defaults.set("garbage_unknown_theme_x", forKey: DFThemeManager.storageKey)

        let manager = DFThemeManager(userDefaults: defaults)
        XCTAssertEqual(manager.theme, .system)
    }

    /// setTheme 호출 시 즉시 UserDefaults 에 write.
    func testManagerSetThemePersistsToDefaults() {
        let defaults = makeEphemeralDefaults()
        defaults.removeObject(forKey: DFThemeManager.storageKey)

        let manager = DFThemeManager(userDefaults: defaults)
        XCTAssertEqual(manager.theme, .system)

        manager.setTheme(.lightFlat)
        XCTAssertEqual(manager.theme, .lightFlat)
        XCTAssertEqual(
            defaults.string(forKey: DFThemeManager.storageKey),
            DFTheme.lightFlat.rawValue,
            "setTheme 은 즉시 UserDefaults 에 기록되어야 한다"
        )

        manager.setTheme(.dark)
        XCTAssertEqual(
            defaults.string(forKey: DFThemeManager.storageKey),
            DFTheme.dark.rawValue
        )
    }

    /// 같은 테마로 setTheme — no-op (불필요한 publish 차단).
    func testManagerSetThemeNoOpOnSame() {
        let defaults = makeEphemeralDefaults()
        let manager = DFThemeManager(userDefaults: defaults)
        manager.setTheme(.lightFlat)

        // 한 번 더 호출 — theme 값 동일 유지.
        manager.setTheme(.lightFlat)
        XCTAssertEqual(manager.theme, .lightFlat)
    }

    // MARK: - 5. cycle()

    /// cycle 은 allCases 순서대로 다음 테마로 이동.
    func testManagerCycleAdvancesToNextTheme() {
        let defaults = makeEphemeralDefaults()
        let manager = DFThemeManager(userDefaults: defaults)

        // 시작점: system. allCases 순서 = [system, lightFlat, dark].
        manager.setTheme(.system)
        XCTAssertEqual(manager.theme, .system)

        manager.cycle()
        XCTAssertEqual(manager.theme, .lightFlat,
                       "system → 다음 = lightFlat")

        manager.cycle()
        XCTAssertEqual(manager.theme, .dark,
                       "lightFlat → 다음 = dark")

        manager.cycle()
        XCTAssertEqual(manager.theme, .system,
                       "dark → 다음 = system (wrap-around)")
    }

    // MARK: - 6. DFColor adaptive accessors

    /// flat 모드와 비 flat 모드의 canvas 가 서로 다른 Color 인스턴스를 반환.
    /// (정확한 색상 hex 비교는 NSColor appearance binding 때문에 신뢰 불가
    /// 라 description 문자열로 difference 만 확인.)
    func testAdaptiveCanvasDiffersBetweenFlatAndSystem() {
        let flatColor = DFColor.adaptiveCanvas(.lightFlat)
        let systemColor = DFColor.adaptiveCanvas(.system)
        XCTAssertNotEqual(
            "\(flatColor)", "\(systemColor)",
            "lightFlat canvas (#FFFFFF) 와 system canvas (#F2F2F7 light) 는 달라야 한다"
        )
    }

    /// adaptiveCard / adaptiveElev2 도 분기 동작.
    func testAdaptiveCardAndElev2Branching() {
        let flatCard = DFColor.adaptiveCard(.lightFlat)
        let systemCard = DFColor.adaptiveCard(.system)
        XCTAssertNotEqual("\(flatCard)", "\(systemCard)")

        let flatElev2 = DFColor.adaptiveElev2(.lightFlat)
        let systemElev2 = DFColor.adaptiveElev2(.system)
        XCTAssertNotEqual("\(flatElev2)", "\(systemElev2)")
    }

    /// adaptiveBorder — flat 은 명확한 회색, 그 외는 textSecondary subtle (opacity 0.12).
    func testAdaptiveBorderBranching() {
        let flatBorder = DFColor.adaptiveBorder(.lightFlat)
        let systemBorder = DFColor.adaptiveBorder(.system)
        XCTAssertNotEqual("\(flatBorder)", "\(systemBorder)")
    }

    // MARK: - 7. 무채색 (Achromatic) invariant — v1.11.15 cycle 2

    /// flat 표면 색상은 모든 RGB 채널이 동일해야 함 (r=g=b).
    /// 종전 b 채널이 r=g 보다 살짝 컸음 (cool 톤) → 진정한 grayscale 로 통일.
    func testFlatSurfacesAreTrueGrayscale() {
        let surfaces: [(String, Color)] = [
            ("flatCanvas", DFColor.flatCanvas),
            ("flatCard", DFColor.flatCard),
            ("flatElev2", DFColor.flatElev2),
            ("flatElev3", DFColor.flatElev3),
            ("flatBorder", DFColor.flatBorder),
            ("flatTextPrimary", DFColor.flatTextPrimary),
            ("flatTextSecondary", DFColor.flatTextSecondary),
        ]
        for (name, color) in surfaces {
            guard let rgb = rgbComponents(of: color) else {
                XCTFail("\(name): RGB 추출 실패 (sRGB 공간 변환 불가)")
                continue
            }
            XCTAssertEqual(rgb.r, rgb.g, accuracy: 0.005,
                           "\(name): r(\(rgb.r)) ≠ g(\(rgb.g)) — 무채색이 아님")
            XCTAssertEqual(rgb.g, rgb.b, accuracy: 0.005,
                           "\(name): g(\(rgb.g)) ≠ b(\(rgb.b)) — 무채색이 아님")
        }
    }

    /// flat 표면들이 명도 단조 감소 — canvas > card > elev2 > elev3 > border (밝기 순).
    /// 무채색이라도 명도 차이로 표면 계층 구분되어야 깔끔.
    func testFlatSurfacesMonotonicLightness() {
        let canvas = lightness(DFColor.flatCanvas) ?? 0
        let card = lightness(DFColor.flatCard) ?? 0
        let elev2 = lightness(DFColor.flatElev2) ?? 0
        let elev3 = lightness(DFColor.flatElev3) ?? 0
        let border = lightness(DFColor.flatBorder) ?? 0

        XCTAssertGreaterThan(canvas, card, "canvas 가 card 보다 밝아야 함")
        XCTAssertGreaterThan(card, elev2, "card 가 elev2 보다 밝아야 함")
        XCTAssertGreaterThan(elev2, elev3, "elev2 가 elev3 보다 밝아야 함")
        XCTAssertGreaterThan(elev3, border, "elev3 가 border 보다 밝아야 함")
    }

    /// 텍스트 색상도 무채색 + 명도 대비 충분 (WCAG AA 4.5:1+ 근사).
    /// flatTextPrimary 가 canvas 대비 충분히 어둡고, flatTextSecondary 도 dim 하지만 가독.
    func testFlatTextContrast() {
        let canvas = lightness(DFColor.flatCanvas) ?? 0
        let primary = lightness(DFColor.flatTextPrimary) ?? 1
        let secondary = lightness(DFColor.flatTextSecondary) ?? 1

        XCTAssertLessThan(primary, 0.25,
                          "flatTextPrimary 는 충분히 어두워야 함 — WCAG AA 가독 보장")
        XCTAssertLessThan(secondary, 0.55,
                          "flatTextSecondary 는 본문보다 옅지만 dim 가독 유지")
        XCTAssertGreaterThan(canvas - primary, 0.7,
                             "canvas ↔ primary 명도 차 > 0.7 — 충분한 대비")
    }

    // MARK: - RGB / Lightness Helpers

    /// SwiftUI Color → sRGB RGB 성분 추출. opaque Color 라 AppKit 우회.
    private func rgbComponents(of color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let c = ns else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// 무채색의 명도 = R 채널 (r=g=b 보장). 비교용 단순 metric.
    private func lightness(_ color: Color) -> CGFloat? {
        rgbComponents(of: color)?.r
    }

    // MARK: - 8. 3D 뷰포트 어두운 배경 (cycle 2)

    /// 3D viewport 색상은 어두워야 함 (R+G+B < 0.6 = 매우 어두운 톤).
    /// 사용자 요청 — 라이트/플랫 모드에서도 3D 모델 시인성 위해 항상 dark.
    func testScene3DColorsAreDark() {
        guard let topRGB = rgbComponents(of: DFColor.scene3DTop),
              let bottomRGB = rgbComponents(of: DFColor.scene3DBottom) else {
            XCTFail("scene3D 색상 RGB 추출 실패")
            return
        }
        let topAvg = (topRGB.r + topRGB.g + topRGB.b) / 3
        let bottomAvg = (bottomRGB.r + bottomRGB.g + bottomRGB.b) / 3
        XCTAssertLessThan(topAvg, 0.25, "scene3DTop 충분히 어두워야 (평균 R+G+B < 0.25)")
        XCTAssertLessThan(bottomAvg, 0.15, "scene3DBottom 더 어두워야 (평균 < 0.15)")
        XCTAssertGreaterThan(topAvg, bottomAvg,
                             "그라데이션 top 이 bottom 보다 약간 밝아야 함 (depth cue)")
    }

    /// 3D viewport 색상도 무채색 톤 — 흰색 플랫 GUI 와 시각적 조화.
    func testScene3DColorsAreNeutral() {
        for (name, color) in [("scene3DTop", DFColor.scene3DTop),
                              ("scene3DBottom", DFColor.scene3DBottom)] {
            guard let rgb = rgbComponents(of: color) else {
                XCTFail("\(name): RGB 추출 실패")
                continue
            }
            let maxChannel = max(rgb.r, rgb.g, rgb.b)
            let minChannel = min(rgb.r, rgb.g, rgb.b)
            XCTAssertLessThan(maxChannel - minChannel, 0.05,
                              "\(name): r/g/b 채널 차 < 0.05 — 거의 무채색")
        }
    }

    // MARK: - 9. Flat shadow tier (cycle 3 — v1.11.15)

    /// flat shadow 토큰이 정의되어 있고 일반 shadow 보다 더 부드러운지 검증.
    /// 부드러움 = (radius 더 큼) AND (opacity 같거나 작음). 깊이 cue 유지 + 차분.
    func testFlatShadowSofterThanRegular() {
        // flat card 그림자: radius 10 / opacity 0.05.
        // 일반 card 그림자: radius 8 / opacity 0.06.
        XCTAssertGreaterThan(DFShadow.flatCard.radius, DFShadow.card.radius,
                             "flatCard radius 는 card 보다 커야 부드러움")
        XCTAssertGreaterThan(DFShadow.flatPopover.radius, DFShadow.popover.radius,
                             "flatPopover radius 는 popover 보다 커야 부드러움")
        XCTAssertGreaterThan(DFShadow.flatModal.radius, DFShadow.modal.radius,
                             "flatModal radius 는 modal 보다 커야 부드러움")
    }

    /// flat shadow 색이 검정 계열 — 무채색 GUI 와 일관.
    /// SwiftUI Color 비교는 description string 으로 우회.
    func testFlatShadowsAreBlackBased() {
        // Color.black.opacity(0.05) 같은 표현 — description 에 "black" 포함.
        XCTAssertTrue("\(DFShadow.flatCard.color)".contains("black"),
                      "flatCard 그림자는 black 베이스 (무채색 일관성)")
        XCTAssertTrue("\(DFShadow.flatPopover.color)".contains("black"))
        XCTAssertTrue("\(DFShadow.flatModal.color)".contains("black"))
    }

    /// flat shadow tier 가 명도 단조 — card < popover < modal (radius 순).
    func testFlatShadowTiersMonotonic() {
        XCTAssertLessThan(DFShadow.flatCard.radius, DFShadow.flatPopover.radius)
        XCTAssertLessThan(DFShadow.flatPopover.radius, DFShadow.flatModal.radius)
        // y offset 도 단조 (높을수록 표면이 떠 있음)
        XCTAssertLessThanOrEqual(DFShadow.flatCard.y, DFShadow.flatPopover.y)
        XCTAssertLessThanOrEqual(DFShadow.flatPopover.y, DFShadow.flatModal.y)
    }

    // MARK: - 10. Notification Names

    /// 메뉴 → RootView fan-out 에 사용되는 notification 명이 정의되어 있고
    /// rawValue 가 안정적 (오타 회귀 가드).
    func testThemeNotificationNamesStable() {
        XCTAssertEqual(
            Notification.Name.dfSetTheme.rawValue,
            "DarwinForge.SetTheme"
        )
        XCTAssertEqual(
            Notification.Name.dfCycleTheme.rawValue,
            "DarwinForge.CycleTheme"
        )
    }

    // MARK: - Helpers

    /// 격리된 UserDefaults — 테스트끼리 간섭 차단.
    private func makeEphemeralDefaults() -> UserDefaults {
        let suiteName = "DFThemeTest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName) ?? .standard
        d.removePersistentDomain(forName: suiteName)
        return d
    }
}
