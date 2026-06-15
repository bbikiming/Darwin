import Foundation
import SwiftUI
import XCTest
@testable import DarwinForgeUI

/// **v1.21.1 (2026-05-22) — GamepadPilotPanel wire-up 통합 테스트**.
///
/// **사이클 72 (코덱스 HIGH-3) 갱신**: 종전 7 테스트는 `panel.ensureAdapter()` 후
/// `panel.adapter` read 했으나, `@State var adapter` 는 SwiftUI view hosting context
/// 안에서만 정상 작동 — XCTest 환경 (view tree 없음) 에서 `@State` setter 는 undefined
/// (Apple 공식 stance). 본 테스트는 이 제약을 인정 — 실 adapter routing 검증은
/// 32 `GamepadPilotAdapterTests` 가 담당, 본 suite 는 panel 구조 검증 (init / body
/// smoke) 만 수행.
///
/// # 검증 범위 (cycle 72 축소)
///
/// 1. Panel 이 두 init overload 로 init 가능 (compile-check)
/// 2. body 가 SwiftUI View — 어떤 throw 없이 렌더 트리 구성 (smoke)
///
/// adapter routing / lifecycle / 입력 처리는 `GamepadPilotAdapterTests` 가
/// 32 케이스로 검증 (MockGamepad 주입) → 본 테스트 중복 제거.
@MainActor
final class GamepadPilotPanelTests: XCTestCase {

    private var mock: MockGamepad!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGamepad(controllerName: "TestPanelController")
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: MockTelloLink())
        bridge.session = session
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 1. Panel init compile-check

    /// production init (실 GCController source) 가 compile + runtime crash 없이 생성.
    func testPanelInitProduction() {
        let panel = GamepadPilotPanel(bridge: bridge)
        // panel 인스턴스 생성 자체가 적어도 init crash 없음 보장.
        // SwiftUI View 는 struct → 단순 생성은 side effect 없음.
        _ = panel
    }

    /// 테스트 init (mock source) 가 compile + runtime crash 없이 생성.
    func testPanelInitWithMockSource() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        _ = panel
    }

    // MARK: - 2. SwiftUI body smoke

    /// View body 가 throw 없이 구성. SwiftUI 의 lazy evaluation 라
    /// 실 rendering 은 못 하지만 view 트리 access 자체가 SwiftUI compile-check.
    func testPanelBodyConstructsWithoutCrash() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        // body 는 some View — 단순 access 가 SwiftUI primitive 트리 build.
        _ = panel.body
    }

    /// production init 의 body 도 crash 없이 구성.
    func testPanelBodyProduction() {
        let panel = GamepadPilotPanel(bridge: bridge)
        _ = panel.body
    }

    // MARK: - 3. ensureAdapter idempotent (production code 단위 검증)

    /// `ensureAdapter()` 가 idempotent — 호출 자체가 crash 안 함.
    /// **주의**: @State 값 read 는 SwiftUI hosting context 외에서 undefined →
    /// 본 테스트는 함수 호출 자체의 안전성만 검증, adapter 값은 검증 안 함.
    func testEnsureAdapterIsIdempotent() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        panel.ensureAdapter()
        panel.ensureAdapter()  // 2번째 호출도 안전 (guard adapter == nil).
        panel.ensureAdapter()  // 3번째 — crash 없음.
    }
}
