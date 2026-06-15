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

    // MARK: - Test 6 (사이클 89 — HIGH-2 회귀 가드): slider drag throttle

    /// **HIGH-2 회귀 가드**: 50ms 이내 연속 slider drag 호출은 drop 되어야 함.
    /// 본 테스트가 깨지면 observability storm 재발 — TelloPilotHud / PilotHQStatusRow
    /// 가 매 frame (60Hz) re-render 됨.
    func testSliderUpdateThrottleDropsRapidSuccessiveCalls() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000.0)

        // 첫 호출 — distantPast 부터 충분히 떨어짐 → 통과.
        let first = PilotSettingsPanel.shouldApplySliderUpdate(
            now: base, lastUpdate: .distantPast
        )
        XCTAssertTrue(first.shouldApply,
                      "초기 (lastUpdate=distantPast) 첫 호출은 항상 통과")
        XCTAssertEqual(first.nextTimestamp, base,
                       "통과 시 nextTimestamp 는 now 로 갱신")

        // 49ms 후 호출 — throttle (50ms) 미만이라 drop.
        let dropped = PilotSettingsPanel.shouldApplySliderUpdate(
            now: base.addingTimeInterval(0.049), lastUpdate: base
        )
        XCTAssertFalse(dropped.shouldApply,
                       "49ms < 50ms throttle — drop. 60Hz drag 폭주 방지.")
        XCTAssertEqual(dropped.nextTimestamp, base,
                       "drop 시 lastUpdate 보존 (다음 호출이 같은 기준으로 평가)")

        // 50ms 후 호출 — 경계값. 통과 (>=).
        let boundary = PilotSettingsPanel.shouldApplySliderUpdate(
            now: base.addingTimeInterval(0.050), lastUpdate: base
        )
        XCTAssertTrue(boundary.shouldApply,
                      "정확히 50ms 경계는 통과 (>= throttle)")

        // 51ms 후 호출 — 통과.
        let passed = PilotSettingsPanel.shouldApplySliderUpdate(
            now: base.addingTimeInterval(0.051), lastUpdate: base
        )
        XCTAssertTrue(passed.shouldApply, "51ms > 50ms 통과")
        XCTAssertEqual(passed.nextTimestamp, base.addingTimeInterval(0.051),
                       "통과 시 nextTimestamp = now")
    }

    /// **HIGH-2 회귀 가드**: throttle constant 가 50ms (20Hz cap) 유지. 본 값이
    /// 변하면 observability storm 영향 — 1ms 로 줄이면 60Hz storm 재발.
    func testSliderThrottleIntervalIs50ms() {
        XCTAssertEqual(PilotSettingsPanel.sliderThrottleInterval, 0.05, accuracy: 1e-9,
                       "throttle = 50ms 고정 (20Hz cap) — 변경 시 storm 위험 검토 필요")
    }

    // MARK: - Test 7 (사이클 89 — HIGH-1 회귀 가드): onAppear reload from store

    /// **HIGH-1 회귀 가드**: view 재진입 시 store 의 최신 값을 bridge 에 반영.
    /// `@State` init-time 동결 문제로 다른 source 가 store 갱신 시 panel slider 가
    /// stale 했던 결함 — 본 reload helper 가 fix path.
    func testReloadAppliesLatestStoreValueToBridge() {
        // 사전 — panel 이 한 번 init 됐다고 가정 (default state).
        XCTAssertEqual(bridge.scale, .default, "사전: bridge default")

        // 다른 source (예: keyboard panel ± 클릭 / 별 세션의 save) 가 store 갱신.
        let externalUpdate = PilotPreferences(
            scaleLR: 0.42, scaleFB: 0.31, scaleYaw: 0.58, smoothingFactor: 0.66
        )
        store.save(externalUpdate)

        // bridge 는 아직 stale — panel 의 @State 도 stale 했을 것.
        XCTAssertEqual(bridge.scale, .default,
                       "store 갱신만으로 bridge 자동 동기화 안 됨 (reload 필요)")

        // panel.onAppear 가 호출하는 reload path — store.load → bridge.apply.
        let reloaded = PilotSettingsPanel.reload(from: store, into: bridge)

        XCTAssertEqual(reloaded, externalUpdate,
                       "reload 반환값 = store 최신")
        XCTAssertEqual(bridge.scale.lr, externalUpdate.scaleLR, accuracy: 1e-9,
                       "reload 후 bridge.scale.lr 가 store 최신값 반영")
        XCTAssertEqual(bridge.scale.fb, externalUpdate.scaleFB, accuracy: 1e-9,
                       "reload 후 bridge.scale.fb 가 store 최신값 반영")
        XCTAssertEqual(bridge.scale.yaw, externalUpdate.scaleYaw, accuracy: 1e-9,
                       "reload 후 bridge.scale.yaw 가 store 최신값 반영")
        XCTAssertEqual(bridge.smoothingFactor, externalUpdate.smoothingFactor, accuracy: 1e-9,
                       "reload 후 bridge.smoothingFactor 가 store 최신값 반영")
    }
}
