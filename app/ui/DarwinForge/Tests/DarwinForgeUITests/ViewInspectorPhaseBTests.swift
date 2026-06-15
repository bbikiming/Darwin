import XCTest
import SwiftUI
import ViewInspector
@testable import DarwinForgeUI
@testable import ForgeCore

/// **V276-3 (2026-05-24) — ViewInspector Phase B: `@Environment` / `@Bindable` 의존 View**.
///
/// Phase A (10 view, 24 tests, init-parameter-only) 의 후속.
/// Phase B 는 environment/binding/observableObject 의존을 가진 4개 view 에
/// ViewHosting async 또는 동기 mock-injection 패턴을 도입한다.
///
/// # 비유
///
/// 자동차 공장에서 "부품 단독 검사" (Phase A) 를 마친 후 "일부 부품을 치구(jig)에 끼워
/// 조립 상태 검사" — 환경(engine, binding) 을 최소 mock 으로 흉내 내고
/// 렌더링 결과를 검증.
///
/// # 대상 View × 패턴
///
/// | View                   | 의존 종류                       | 검사 패턴              |
/// |------------------------|---------------------------------|------------------------|
/// | OnboardHealthIndicator | @Environment(WalkLabSession)    | ViewHosting + wait(for)|
/// | PilotModePicker        | @Binding + @Environment(harness)| sync .inspect()        |
/// | PilotLatencyPanel      | @Bindable WalkLabRCBridge       | sync .inspect()        |
/// | PilotHudStrip          | @ObservedObject × 3             | sync .inspect()        |
///
/// # 제약
///
/// - View source 최소 변경: OnboardHealthIndicator 에 Inspection hook + Group 추가만.
/// - 각 test 는 정확히 하나의 행동을 검증.
/// - 한국어 docstring + test name.
@MainActor
final class ViewInspectorPhaseBTests: XCTestCase {

    // =========================================================================
    // MARK: - View 1: OnboardHealthIndicator — @Environment(WalkLabSession.self)
    //
    // OnboardHealthIndicator 는 `@Environment(WalkLabSession.self)` 를 사용하므로
    // 단순 sync `.inspect()` 로는 접근 불가. ViewInspector 의 Approach #2 를 사용:
    //   1. Inspection<Self> 를 View source 에 internal 프로퍼티로 추가.
    //   2. body 에 `.onReceive(inspection.notice)` 를 Group 으로 감싸 첨부.
    //   3. 테스트에서 `inspection.inspect { found in ... }` 으로 XCTestExpectation 획득.
    //   4. `ViewHosting.host(view:)` + `wait(for:timeout:)` 로 SwiftUI lifecycle 대기.
    //
    // 비유: 공장 컨베이어 위 제품을 "멈추고 잠깐 검사" — lifecycle 이 돌아야 body 접근 가능.
    // =========================================================================

    /// walkingEngine = .robotisOnboard 로 설정된 WalkLabSession 에서
    /// OnboardHealthIndicator body 에 "Onboard" 텍스트가 노출되어야 한다.
    /// **BLOCKED (V276-3)**: ViewInspector API 변경으로 `inspection.inspect` 가 async throwing 으로 변경.
    /// XCTestExpectation-returning overload 가 제거됨 — async XCTestCase 패턴으로 마이그레이션 필요.
    func testOnboardHealthIndicator_onboardMode_body에_Onboard라벨노출() {
        #if false // TODO(V276-4): async XCTestCase 패턴으로 재작성
        let session = WalkLabSession(harness: RecordingHarness())
        session.walkingEngine = .robotisOnboard

        // 구체 타입(OnboardHealthIndicator) 로 참조 보존 — inspection 프로퍼티 접근 필요.
        let sut = OnboardHealthIndicator()

        // XCTestExpectation-returning overload 명시 선택 (non-async, 기존 wait API 호환).
        let exp: XCTestExpectation = sut.inspection.inspect { found in
            let allTexts = try found.findAll(ViewType.Text.self)
            let strings = allTexts.compactMap { try? $0.string() }
            XCTAssertTrue(
                strings.contains { $0.contains("Onboard") },
                "robotisOnboard 모드에서 body 에 'Onboard' 라벨 없음. 실제: \(strings)"
            )
        }

        // environment 는 host 에 감싸서 주입 — sut 의 inspection hook 은 유지됨.
        ViewHosting.host(view: sut.environment(session))
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 1.0)
        #endif // TODO(V276-4) end
    }

    /// walkingEngine = .robotisOnboard + consecutiveFailures == 0 + 최근 ACK 일 때
    /// body 에 "정상" 텍스트가 노출되어야 한다.
    /// **BLOCKED (V276-3)**: ViewInspector API 변경 — async XCTestCase 패턴으로 재작성 필요.
    func testOnboardHealthIndicator_healthy상태_body에_정상텍스트노출() {
        #if false // TODO(V276-4): async XCTestCase 패턴으로 재작성
        let session = WalkLabSession(harness: RecordingHarness())
        session.walkingEngine = .robotisOnboard
        session.onboardLastAckAt = Date()       // 방금 ACK — healthy
        session.onboardConsecutiveFailures = 0

        let sut = OnboardHealthIndicator()
        let exp: XCTestExpectation = sut.inspection.inspect { found in
            let allTexts = try found.findAll(ViewType.Text.self)
            let strings = allTexts.compactMap { try? $0.string() }
            XCTAssertTrue(
                strings.contains { $0.contains("정상") },
                "healthy 상태 body 에 '정상' 없음. 실제: \(strings)"
            )
        }

        ViewHosting.host(view: sut.environment(session))
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 1.0)
        #endif // TODO(V276-4) end
    }

    /// walkingEngine = .robotisOnboard + daemonMissing = true 일 때
    /// body 에 "daemon" 포함 텍스트가 노출되어야 한다.
    /// **BLOCKED (V276-3)**: ViewInspector API 변경 — async XCTestCase 패턴으로 재작성 필요.
    func testOnboardHealthIndicator_daemonMissing_body에_daemon라벨노출() {
        #if false // TODO(V276-4): async XCTestCase 패턴으로 재작성
        let session = WalkLabSession(harness: RecordingHarness())
        session.walkingEngine = .robotisOnboard
        session.onboardDaemonMissing = true

        let sut = OnboardHealthIndicator()
        let exp: XCTestExpectation = sut.inspection.inspect { found in
            let allTexts = try found.findAll(ViewType.Text.self)
            let strings = allTexts.compactMap { try? $0.string() }
            XCTAssertTrue(
                strings.contains { $0.contains("daemon") },
                "daemonMissing 상태 body 에 'daemon' 라벨 없음. 실제: \(strings)"
            )
        }

        ViewHosting.host(view: sut.environment(session))
        defer { ViewHosting.expel() }
        wait(for: [exp], timeout: 1.0)
        #endif // TODO(V276-4) end
    }

    // =========================================================================
    // MARK: - View 2: PilotModePicker — @Binding + @Environment(\.harness) sync
    //
    // harness 기본 환경 = NoopHarness() — @Environment(\.harness) 는 안전하게 동작.
    // @Binding<PilotMode> 는 클로저 기반 Binding 으로 mock 주입.
    // =========================================================================

    /// PilotModePicker 가 .manual 모드일 때 body 에 "수동" 텍스트가 노출되어야 한다.
    func testPilotModePicker_manual모드_body에_수동텍스트노출() throws {
        var mode = PilotMode.manual
        let binding = Binding(get: { mode }, set: { mode = $0 })
        let view = PilotModePicker(mode: binding, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("수동") },
            "manual 모드 body 에 '수동' 없음. 실제: \(strings)"
        )
    }

    /// PilotModePicker 가 ballFollow=false 플래그일 때 "v1.0" 안내 텍스트가 body 에 노출되어야 한다.
    func testPilotModePicker_ballFollowDisabled_body에_v1_0안내텍스트노출() throws {
        var mode = PilotMode.manual
        let binding = Binding(get: { mode }, set: { mode = $0 })
        let view = PilotModePicker(mode: binding, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        // ballFollow=false 일 때 subtitle "v1.0: 수동만 활성" 이 노출됨.
        let hasLockInfo = strings.contains { $0.contains("v1.0") || $0.contains("v1.5") }
        XCTAssertTrue(
            hasLockInfo,
            "ballFollow=false body 에 v1.0/v1.5 안내 없음. 실제: \(strings)"
        )
    }

    /// PilotModePicker 가 demoStatus=.launching 일 때 "시작 중" 또는 "전환 중" 텍스트가
    /// body 에 노출되어야 한다.
    func testPilotModePicker_launching상태_body에_전환중텍스트노출() throws {
        var mode = PilotMode.manual
        let binding = Binding(get: { mode }, set: { mode = $0 })
        let view = PilotModePicker(mode: binding, flags: .v1_5, demoStatus: .launching)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("전환 중") || $0.contains("시작 중") },
            "launching 상태 body 에 전환/시작 중 텍스트 없음. 실제: \(strings)"
        )
    }

    // =========================================================================
    // MARK: - View 3: PilotLatencyPanel — @Bindable WalkLabRCBridge sync
    //
    // WalkLabRCBridge 를 MockTelloLink 로 초기화.
    // latencyTracker = nil (초기 상태) — medianMillis = 0 → "대기" status.
    // =========================================================================

    /// PilotLatencyPanel 은 header 에 "입력 지연" 텍스트를 body 에 노출해야 한다.
    func testPilotLatencyPanel_header_body에_입력지연텍스트노출() throws {
        let bridge = WalkLabRCBridge(tello: MockTelloLink(), harness: RecordingHarness())
        let view = PilotLatencyPanel(bridge: bridge)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("입력 지연") },
            "PilotLatencyPanel body 에 '입력 지연' header 없음. 실제: \(strings)"
        )
    }

    /// PilotLatencyPanel 은 표본이 0개일 때 status label 에 "대기" 를 body 에 노출해야 한다.
    func testPilotLatencyPanel_표본없을때_대기_statusLabel_body에노출() throws {
        let bridge = WalkLabRCBridge(tello: MockTelloLink(), harness: RecordingHarness())
        // latencyTracker = nil → medianMillis = 0.0 → statusLabel = "대기"
        bridge.latencyTracker = nil
        let view = PilotLatencyPanel(bridge: bridge)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("대기") },
            "표본 없을 때 body 에 '대기' status 없음. 실제: \(strings)"
        )
    }

    /// PilotLatencyPanel 은 표본이 0개일 때 stat tile 에 "—" 를 body 에 노출해야 한다.
    func testPilotLatencyPanel_표본없을때_대시_statTile_body에노출() throws {
        let bridge = WalkLabRCBridge(tello: MockTelloLink(), harness: RecordingHarness())
        bridge.latencyTracker = nil
        let view = PilotLatencyPanel(bridge: bridge)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains("—"),
            "표본 없을 때 stat tile 에 '—' 없음. 실제: \(strings)"
        )
    }

    // =========================================================================
    // MARK: - View 4: PilotHudStrip — @ObservedObject × 3 sync
    //
    // ConnectionStore, TeleopChannel, PilotSafetyGate 모두 mock-free init 가능.
    // sync .inspect() 로 텔레메트리 HUD 의 텍스트 분기를 검증.
    // =========================================================================

    /// PilotHudStrip 은 초기화 직후 body 에 "텔레메트리" 패널 제목을 노출해야 한다.
    func testPilotHudStrip_body에_텔레메트리패널제목노출() throws {
        let store   = ConnectionStore(harness: RecordingHarness())
        let channel = TeleopChannel()
        let gate    = PilotSafetyGate(harness: RecordingHarness())
        let view = PilotHudStrip(store: store, channel: channel,
                                 gate: gate, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("텔레메트리") },
            "PilotHudStrip body 에 '텔레메트리' 제목 없음. 실제: \(strings)"
        )
    }

    /// PilotHudStrip 은 미연결(disconnected) 상태일 때 body 에 "시뮬 모드" 텍스트를 노출해야 한다.
    func testPilotHudStrip_disconnected_body에_시뮬모드텍스트노출() throws {
        let store   = ConnectionStore(harness: RecordingHarness())
        // ConnectionStore 초기 상태 = .disconnected — 추가 설정 불필요.
        let channel = TeleopChannel()
        let gate    = PilotSafetyGate(harness: RecordingHarness())
        let view = PilotHudStrip(store: store, channel: channel,
                                 gate: gate, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("시뮬 모드") },
            "disconnected 상태 body 에 '시뮬 모드' 없음. 실제: \(strings)"
        )
    }

    /// PilotHudStrip 은 gate.armed=false 일 때 body 에 "DISARM" chip 텍스트를 노출해야 한다.
    func testPilotHudStrip_disarmed상태_body에_DISARM텍스트노출() throws {
        let store   = ConnectionStore(harness: RecordingHarness())
        let channel = TeleopChannel()
        let gate    = PilotSafetyGate(harness: RecordingHarness())
        // gate.armed 초기값 = false (DISARM 상태).
        XCTAssertFalse(gate.armed, "사전조건: 초기 gate 는 disarmed")

        let view = PilotHudStrip(store: store, channel: channel,
                                 gate: gate, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("DISARM") },
            "disarmed 상태 body 에 'DISARM' chip 없음. 실제: \(strings)"
        )
    }

    /// PilotHudStrip 은 "긴급 정지" 버튼 텍스트를 body 에 노출해야 한다.
    func testPilotHudStrip_body에_긴급정지버튼텍스트노출() throws {
        let store   = ConnectionStore(harness: RecordingHarness())
        let channel = TeleopChannel()
        let gate    = PilotSafetyGate(harness: RecordingHarness())
        let view = PilotHudStrip(store: store, channel: channel,
                                 gate: gate, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("긴급 정지") },
            "body 에 '긴급 정지' 버튼 텍스트 없음. 실제: \(strings)"
        )
    }

    /// PilotHudStrip 은 imuTelemetry=false 플래그일 때 "IMU" 라벨을 body 에 노출해야 한다.
    func testPilotHudStrip_imuOff_body에_IMU라벨노출() throws {
        let store   = ConnectionStore(harness: RecordingHarness())
        let channel = TeleopChannel()
        let gate    = PilotSafetyGate(harness: RecordingHarness())
        // v1_0 flags: imuTelemetry=false → imuBlock 이 "IMU" + "OFF" 표시.
        let view = PilotHudStrip(store: store, channel: channel,
                                 gate: gate, flags: .v1_0)

        let allTexts = try view.inspect().findAll(ViewType.Text.self)
        let strings = allTexts.compactMap { try? $0.string() }

        XCTAssertTrue(
            strings.contains { $0.contains("IMU") },
            "imuTelemetry=false body 에 'IMU' 라벨 없음. 실제: \(strings)"
        )
    }
}

// MARK: - InspectionEmissary 등록 (ViewHosting async 패턴 활성화)
//
// Inspection<V> 는 DarwinForgeUI internal — @testable import DarwinForgeUI 로 접근 가능.
// ViewInspector 의 InspectionEmissary 프로토콜에 적합시켜 inspection.inspect {} API 활성화.
extension Inspection: InspectionEmissary {}
