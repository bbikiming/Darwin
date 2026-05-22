import Foundation
import SwiftUI
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) Phase 5 — VoicePilotPanel 통합 테스트**.
///
/// SwiftUI view 본체를 직접 render 하지 않고 (XCTest 환경에서 SwiftUI host 불가) view 가
/// 보유한 `VoicePilotAdapter` 의 lifecycle / state binding 을 검증.
///
/// # 검증 전략
///
/// `VoicePilotPanel` 의 init(bridge:recognizer:) 가 받은 `MockVoiceRecognizer` 를
/// `VoicePilotAdapter` 에 주입하고, adapter API 를 통해 토글 / state 변화 / 키워드 발화를
/// 검증. UI 레이어 자체보단 adapter wiring + bridge 연결의 정합성에 초점.
///
/// **자동 start 미발생 검증**: panel init 후 mock.didStart=false 보장 — 사용자 명시 호출
/// 시점까지 마이크 권한 요청 금지.
@MainActor
final class VoicePilotPanelTests: XCTestCase {

    private var mock: MockVoiceRecognizer!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockVoiceRecognizer()
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

    // MARK: - Test 1: Init 정상 동작

    /// panel init — bridge / recognizer 주입이 성공하고 view 가 valid View 타입 반환.
    func testPanelInitWithBridgeAndRecognizer() {
        let panel = VoicePilotPanel(bridge: bridge, recognizer: mock)
        // body 가 호출 가능 (compile-time 검증) → SwiftUI valid View.
        _ = panel.body
        XCTAssertFalse(mock.didStart,
                       "init 자체로 mock.start 호출 금지 — 자동 start 금지 정책")
    }

    // MARK: - Test 2: Adapter 가 mock recognizer 와 정상 wired

    /// panel 이 보유할 adapter 가 keyword 전달 시 bridge 에 정확히 도달하는지 검증.
    /// view 외부에서 동일 adapter 를 만들어 검증 — panel internal @State 는 SwiftUI host
    /// 없이 접근 불가하나 wiring 동작은 동일 path 라 동등.
    func testAdapterWiringRoutesRecognitionToBridge() {
        let adapter = VoicePilotAdapter(bridge: bridge, recognizer: mock)
        adapter.start()
        XCTAssertTrue(mock.didStart, "사용자 명시 start 후 mock.start 호출")
        mock.simulate("walk")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "wired adapter 가 walk 키워드 → preset.march 발화")
        XCTAssertEqual(bridge.lastIntent?.source, .voice,
                       "source=voice 로 bridge 전달")
    }

    // MARK: - Test 3: Toggle (start/stop) state 변화

    /// adapter.start → isListening=true, stop → false. panel toggle 버튼이 동일 경로 호출.
    func testToggleStartStopFlipsListeningState() {
        let adapter = VoicePilotAdapter(bridge: bridge, recognizer: mock)
        XCTAssertFalse(adapter.isListening, "초기 상태 — 미listen")
        adapter.start()
        XCTAssertTrue(adapter.isListening, "start 후 listening=true")
        XCTAssertTrue(mock.didStart)
        adapter.stop()
        XCTAssertFalse(adapter.isListening, "stop 후 listening=false")
        XCTAssertTrue(mock.didStop)
    }

    // MARK: - Test 4: Error binding — panel 이 lastError 표시

    /// recognizer 에러 콜백 발화 → adapter.lastError 갱신 → panel errorRow 가 노출 조건.
    /// panel 의 conditional rendering 은 SwiftUI host 없이 직접 검증 불가 → adapter state
    /// 가 panel 의 conditional 입력값임을 검증.
    func testErrorStatePropagatesToAdapter() {
        let adapter = VoicePilotAdapter(bridge: bridge, recognizer: mock)
        adapter.start()
        XCTAssertNil(adapter.lastError, "사전 — 에러 없음")
        mock.simulateError("마이크 권한 거부됨")
        XCTAssertEqual(adapter.lastError, "마이크 권한 거부됨",
                       "에러 message 가 adapter.lastError 에 기록 → panel 이 표시할 input")
        XCTAssertFalse(adapter.isListening, "에러 → listening=false 자동 전환")
    }

    // MARK: - Test 5: lastRecognized binding (UI 표시 input)

    /// 인식 결과 도착 → adapter.lastRecognized 갱신 → panel 의 "들린 말" row 가 노출 조건.
    func testRecognizedTextPropagatesToAdapter() {
        let adapter = VoicePilotAdapter(bridge: bridge, recognizer: mock)
        adapter.start()
        XCTAssertNil(adapter.lastRecognized, "사전 — 인식 없음")
        mock.simulate("지금 걸어줘")
        XCTAssertEqual(adapter.lastRecognized, "지금 걸어줘",
                       "lastRecognized 가 panel 의 recognizedTextRow 표시 input")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march",
                       "한국어 substring 매칭 → keyword badge 표시 input")
    }

    // MARK: - Test 6: Production init (실 SpeechFrameworkRecognizer)

    /// production init — 별도 recognizer 주입 없이 SpeechFrameworkRecognizer 가 자동 wired.
    /// view body 호출만으로 init 검증 — 실 마이크 활성 안 함 (자동 start 금지).
    func testProductionInitDoesNotActivateMicrophone() {
        let panel = VoicePilotPanel(bridge: bridge)
        _ = panel.body
        // 실 마이크 접근 검증은 unit test 환경에서 불가능. 본 테스트는 production init
        // path 가 compile + valid View 반환만 확인. 자동 start 금지는 init signature 가
        // recognizer 만 보유 (start 호출 없음) 로 정적 보장.
    }
}
