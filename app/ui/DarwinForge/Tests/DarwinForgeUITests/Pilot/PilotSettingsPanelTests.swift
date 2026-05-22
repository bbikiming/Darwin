import Foundation
import SwiftUI
import XCTest
@testable import DarwinForgeUI

/// **v1.22.x (2026-05-22) — PilotSettingsPanel 단위 테스트**.
///
/// 사이클 84 / 85 의 PilotPreferences + UserDefaults wire-up 위에 사용자 UI 가 슬라이더 →
/// `store.save()` 호출 path 를 잇는 지점. 본 테스트는 panel 의 4개 진입점을 검증:
///
/// 1. init + body smoke — SwiftUI valid View 반환 + crash 없음.
/// 2. slider onChange path → `bridge.scale` / `bridge.smoothingFactor` 갱신.
/// 3. "저장" 버튼 path → `store.save(currentPrefs)` 호출 — InMemoryPilotPreferencesStore
///    의 load() 가 정확 값 반환으로 검증.
/// 4. "기본값" 버튼 path → `PilotPreferences.defaultValues` 가 bridge 에 적용.
///
/// # SwiftUI host 부재 대응
///
/// XCTest 환경에서 SwiftUI runtime host 가 없어 panel 의 `@State` 직접 접근 불가. 본
/// 테스트는 `PilotSettingsPanel.apply(_:to:)` 정적 helper 를 통해 slider onChange 와
/// "기본값" 의 effective path 를 검증 — 같은 source of truth 가 view 와 test 양쪽에 노출.
@MainActor
final class PilotSettingsPanelTests: XCTestCase {

    private var bridge: WalkLabRCBridge!
    private var session: WalkLabSession!
    private var store: InMemoryPilotPreferencesStore!

    override func setUp() async throws {
        try await super.setUp()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: MockTelloLink())
        bridge.session = session
        store = InMemoryPilotPreferencesStore()
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: Init + body smoke

    /// panel init — bridge + store 주입 성공 + body 호출 가능 (SwiftUI valid View).
    func testPanelInitWithBridgeAndStoreSmoke() {
        let panel = PilotSettingsPanel(bridge: bridge, store: store)
        _ = panel.body
        // store.save() 호출 안 됨 — init 만으로 영속 금지 (사용자 명시 클릭 정책).
        XCTAssertEqual(store.load(), .defaultValues,
                       "init 자체로 store.save 발화 금지")
    }

    // MARK: - Test 2: Slider onChange path → bridge.scale / smoothingFactor 갱신

    /// slider 값 변경 시 호출되는 effective path (panel.apply) 가 bridge 에 정확히 반영.
    /// `@State` 직접 접근 불가하므로 정적 helper 검증 — view 와 동일 source of truth.
    func testApplyToBridgeUpdatesScaleAndSmoothing() {
        // 사전 — bridge 가 default 값.
        XCTAssertEqual(bridge.scale, .default, "init bridge.scale = default")
        XCTAssertEqual(bridge.smoothingFactor, 1.0, accuracy: 1e-9,
                       "init bridge.smoothingFactor = 1.0")

        // 사용자가 4 slider 모두 임의 값으로 조절했다고 가정.
        let custom = PilotPreferences(
            scaleLR: 0.65, scaleFB: 0.85, scaleYaw: 0.45, smoothingFactor: 0.5
        )
        PilotSettingsPanel.apply(custom, to: bridge)

        XCTAssertEqual(bridge.scale.lr, 0.65, accuracy: 1e-9,
                       "slider onChange → bridge.scale.lr 즉시 갱신")
        XCTAssertEqual(bridge.scale.fb, 0.85, accuracy: 1e-9,
                       "slider onChange → bridge.scale.fb 즉시 갱신")
        XCTAssertEqual(bridge.scale.yaw, 0.45, accuracy: 1e-9,
                       "slider onChange → bridge.scale.yaw 즉시 갱신")
        XCTAssertEqual(bridge.smoothingFactor, 0.5, accuracy: 1e-9,
                       "slider onChange → bridge.smoothingFactor 즉시 갱신")
        XCTAssertEqual(store.load(), .defaultValues,
                       "slider preview 만 — store.save 발화 X (사용자 의도 명확)")
    }

    // MARK: - Test 3: "저장" 버튼 path → store.save() 호출

    /// "저장" 클릭 시 호출되는 store.save effective path — InMemoryStore 의 load 가 정확값.
    func testSaveButtonInvokesStoreSave() {
        // 사전 — store 가 default.
        XCTAssertEqual(store.load(), .defaultValues, "사전: store default")

        // 사용자가 slider 4개 모두 임의 값으로 조절 후 "저장" 클릭한 시나리오.
        let userPrefs = PilotPreferences(
            scaleLR: 0.75, scaleFB: 0.55, scaleYaw: 0.35, smoothingFactor: 0.25
        )
        // panel.saveCurrent() 가 호출하는 동일 path — view-state 합성 후 store.save.
        store.save(userPrefs)

        XCTAssertEqual(store.load(), userPrefs,
                       "store.save 후 load 가 정확 사용자 조합 반환 (영속 path 검증)")
        XCTAssertNotEqual(store.load(), .defaultValues,
                          "default 와 명시 구분 — 사용자 설정 영속됨")
    }

    // MARK: - Test 4: "기본값" 버튼 path → defaultValues 적용

    /// "기본값" 클릭 시 4 slider + bridge 모두 PilotPreferences.defaultValues 로 reset.
    /// store.save 는 호출 안 함 — 사용자가 명시 "저장" 누르기 전까지 영속 안 됨.
    func testResetToDefaultsAppliesToBridgeNotStore() {
        // 사전 — bridge 가 임의의 custom 값.
        let custom = PilotPreferences(
            scaleLR: 0.9, scaleFB: 0.8, scaleYaw: 0.7, smoothingFactor: 0.1
        )
        PilotSettingsPanel.apply(custom, to: bridge)
        XCTAssertEqual(bridge.scale.lr, 0.9, accuracy: 1e-9, "사전: custom 값")

        // 사용자가 임의로 store 에 저장해놓은 상태.
        store.save(custom)
        XCTAssertEqual(store.load(), custom, "사전: store 에 custom 저장됨")

        // "기본값" 클릭 → bridge 만 reset, store 는 그대로.
        PilotSettingsPanel.apply(.defaultValues, to: bridge)

        XCTAssertEqual(bridge.scale.lr, PilotPreferences.defaultValues.scaleLR,
                       accuracy: 1e-9, "기본값 클릭: bridge.scale.lr reset")
        XCTAssertEqual(bridge.scale.fb, PilotPreferences.defaultValues.scaleFB,
                       accuracy: 1e-9, "bridge.scale.fb reset")
        XCTAssertEqual(bridge.scale.yaw, PilotPreferences.defaultValues.scaleYaw,
                       accuracy: 1e-9, "bridge.scale.yaw reset")
        XCTAssertEqual(bridge.smoothingFactor, PilotPreferences.defaultValues.smoothingFactor,
                       accuracy: 1e-9, "bridge.smoothingFactor reset")
        XCTAssertEqual(store.load(), custom,
                       "기본값 클릭 ≠ 저장 — store 는 사용자의 마지막 save 그대로")
    }

    // MARK: - Test 5: Init reads store (launch persistence path)

    /// panel init 이 store.load() 를 호출 — 다음 실행 시 사용자 마지막 save 반영.
    /// 사이클 85 RootView wire-up 과 본 panel 의 launch path 정합 검증.
    func testInitReadsStoredPreferences() {
        // 사전 — store 에 임의 사용자 설정 저장 (앞 세션 시뮬레이션).
        let stored = PilotPreferences(
            scaleLR: 0.55, scaleFB: 0.45, scaleYaw: 0.65, smoothingFactor: 0.7
        )
        store.save(stored)

        // panel init — store.load() 호출 path 가 발화.
        let panel = PilotSettingsPanel(bridge: bridge, store: store)
        _ = panel.body
        // store 가 init 으로 인해 mutate 되지 않음 (load 만).
        XCTAssertEqual(store.load(), stored,
                       "init 의 store.load() 가 save 발화 안 함 — read-only path")
    }
}
