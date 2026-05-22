import Foundation
import SwiftUI
import XCTest
@testable import DarwinForgeUI

/// **v1.21.1 (2026-05-22) — GamepadPilotPanel wire-up 통합 테스트**.
///
/// `GamepadPilotAdapter` 는 32 unit tests 로 검증됐지만 SwiftUI panel
/// (`GamepadPilotPanel`) 과 미연결 — 본 테스트는 패널 init / adapter 주입 /
/// lifecycle 시점 검증을 담당.
///
/// 실 `GCController` 의존 없이 `MockGamepad` 주입 가능한 `init(bridge:source:)`
/// overload 가 존재함을 보장 — CI / hardware-less 환경에서도 결정론적 통과.
///
/// # 검증 범위
///
/// 1. Panel 이 bridge 받아 adapter 를 owner-binding 한다 (인스턴스 식별)
/// 2. Mock source 주입 시 adapter 가 mock 의 controllerName 을 반영
/// 3. start()/stop() lifecycle 이 isRunning 토글
/// 4. pollOnce() 가 bridge 까지 도달 — emergency 발화 검증
/// 5. body 가 SwiftUI View — 어떤 throw 없이 렌더 트리 구성
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

    // MARK: - 1. Panel init + adapter 식별

    /// 패널이 init 시 adapter 생성 — bridge 주입 + 식별 가능.
    /// (mock source overload 가 없으면 본 테스트는 compile 자체 실패 — wire-up 보장)
    func testPanelInitCreatesAdapterWithMockSource() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        XCTAssertNotNil(panel.adapter, "패널은 adapter 인스턴스를 owner-bind")
        XCTAssertTrue(panel.adapter.bridge === bridge,
                      "adapter.bridge 는 panel 이 받은 bridge 인스턴스와 동일")
    }

    // MARK: - 2. Mock source binding

    /// Mock 주입 → adapter.start() 시점에 controllerName 동기화.
    /// 실 hardware 없이 컨트롤러 라벨 검증.
    func testPanelAdapterReflectsMockControllerName() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        XCTAssertNil(panel.adapter.connectedControllerName,
                     "start 전 — 컨트롤러 이름 nil")

        panel.adapter.start()
        defer { panel.adapter.stop() }

        XCTAssertEqual(panel.adapter.connectedControllerName, "TestPanelController",
                       "start 후 mock 의 이름 반영")
    }

    // MARK: - 3. Lifecycle — start / stop

    func testStartStopLifecycleToggle() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        XCTAssertFalse(panel.adapter.isRunning, "초기 미실행")

        panel.adapter.start()
        XCTAssertTrue(panel.adapter.isRunning, "start 후 실행")

        panel.adapter.stop()
        XCTAssertFalse(panel.adapter.isRunning, "stop 후 미실행")
    }

    // MARK: - 4. End-to-end input — pollOnce → bridge

    /// 사용자가 △ (faceTop) 누름 → adapter.pollOnce() → bridge.handleEmergency.
    /// panel 의 adapter wiring 이 실제 동작함을 입증.
    func testPanelAdapterRoutesEmergencyToBridge() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        session.start(.march)
        XCTAssertEqual(bridge.emergencyCount, 0, "사전: emergency 0회")

        mock.buttons.faceTop = true
        panel.adapter.pollOnce()

        XCTAssertEqual(bridge.emergencyCount, 1,
                       "△ 입력 → bridge.handleEmergency 1회")
        XCTAssertEqual(session.current, .idle, "emergency 효과 — idle 진입")
    }

    /// D-pad ↑ 입력 → preset.march. panel 의 adapter routing 검증.
    func testPanelAdapterRoutesDpadToPreset() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        XCTAssertEqual(session.current, .idle, "사전: idle")

        mock.buttons.dpadUp = true
        panel.adapter.pollOnce()

        XCTAssertEqual(session.current, .march, "D-pad ↑ → preset.march")
        XCTAssertGreaterThan(bridge.presetChangeMirror, 0, "preset mirror 증가")
    }

    // MARK: - 5. SwiftUI body 렌더링 (smoke)

    /// View body 가 throw 없이 구성. SwiftUI 의 lazy evaluation 라
    /// 실 rendering 은 못 하지만 view 트리 access 자체가 SwiftUI compile-check.
    func testPanelBodyConstructsWithoutCrash() {
        let panel = GamepadPilotPanel(bridge: bridge, source: mock)
        // body 는 some View — 단순 access 가 SwiftUI primitive 트리 build.
        _ = panel.body
        XCTAssertTrue(true, "body access 가 fatalError 없이 통과")
    }

    // MARK: - 6. Idempotent adapter ownership

    /// 패널이 두 번 init 되어도 (e.g. SwiftUI re-render) 각 인스턴스는 독립 adapter.
    /// @State property 라 SwiftUI 가 인스턴스 lifetime 관리 — 본 테스트는 init 단계만.
    func testTwoPanelInstancesHaveIndependentAdapters() {
        let mock2 = MockGamepad(controllerName: "SecondMock")
        let panel1 = GamepadPilotPanel(bridge: bridge, source: mock)
        let panel2 = GamepadPilotPanel(bridge: bridge, source: mock2)
        XCTAssertFalse(panel1.adapter === panel2.adapter,
                       "각 패널 인스턴스는 별개 adapter (서로 독립)")
    }
}
