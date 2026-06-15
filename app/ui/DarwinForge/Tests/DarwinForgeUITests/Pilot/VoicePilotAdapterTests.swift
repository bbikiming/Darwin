import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) — VoicePilotAdapter 단위 테스트**.
///
/// 실 `SFSpeechRecognizer` / 마이크 없이 `MockVoiceRecognizer` 로 인식 결과를 enqueue 해
/// adapter → bridge 경로의 정확한 매핑 (각 키워드 → bridge 의 정확한 method 호출) 과
/// unknown keyword silent 보장을 검증.
///
/// # 검증 전략
///
/// `bridge.handleMotion(id:from:)` 호출 후 bridge 의 `lastIntent` 가 `.motion(<id>)` 로
/// 설정됨 — handleMotion 의 부수효과. session.current 직접 변경은 MotionBlender 책임이지만
/// walking module 미연결 (sim) 시 일어나지 않으므로 lastIntent 로 검증. emergency / recovery
/// 는 session 상태에 직접 영향 (emergencyStopActive) 이라 그것으로 검증.
@MainActor
final class VoicePilotAdapterTests: XCTestCase {

    private var mock: MockVoiceRecognizer!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!
    private var adapter: VoicePilotAdapter!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockVoiceRecognizer()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: MockTelloLink())
        bridge.session = session
        adapter = VoicePilotAdapter(bridge: bridge, recognizer: mock)
    }

    override func tearDown() async throws {
        adapter.stop()
        adapter = nil
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 기본 / lifecycle

    func testAdapterInitDefaults() {
        XCTAssertFalse(adapter.isListening, "init 후 미실행")
        XCTAssertNil(adapter.lastRecognized, "입력 없음 → 인식 텍스트 nil")
        XCTAssertNil(adapter.lastMatchedKeyword, "매칭 없음 → keyword nil")
        XCTAssertNil(adapter.lastError, "에러 없음")
    }

    func testStartSetsListening() {
        adapter.start()
        XCTAssertTrue(adapter.isListening, "start 후 listening=true")
        XCTAssertTrue(mock.didStart, "mock recognizer start 호출")
        XCTAssertNotNil(mock.resultHandler, "결과 handler 등록")
        XCTAssertNotNil(mock.errorHandler, "에러 handler 등록")
    }

    func testStopClearsListening() {
        adapter.start()
        XCTAssertTrue(adapter.isListening)
        adapter.stop()
        XCTAssertFalse(adapter.isListening, "stop 후 listening=false")
        XCTAssertTrue(mock.didStop, "mock recognizer stop 호출")
    }

    func testStartIsIdempotent() {
        adapter.start()
        let firstStartCount = mock.startCount
        adapter.start()  // 두 번째 start — no-op.
        XCTAssertTrue(adapter.isListening)
        XCTAssertEqual(mock.startCount, firstStartCount, "두 번째 start no-op")
    }

    func testStopWhenNotListeningIsNoOp() {
        XCTAssertFalse(adapter.isListening)
        adapter.stop()  // listening 아닐 때 stop — no-op.
        XCTAssertFalse(mock.didStop, "listening 아닐 때 mock.stop 미호출")
    }

    func testStartFailurePropagatesError() {
        mock.startError = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "engine init failed"]
        )
        adapter.start()
        XCTAssertFalse(adapter.isListening, "start 실패 → listening=false")
        XCTAssertNotNil(adapter.lastError, "에러 메시지 기록")
        XCTAssertTrue(adapter.lastError?.contains("engine init failed") ?? false,
                      "에러 원본 포함")
    }

    func testRecognizerErrorCallbackUpdatesAdapter() {
        adapter.start()
        XCTAssertTrue(adapter.isListening)
        mock.simulateError("권한 거부")
        XCTAssertFalse(adapter.isListening, "에러 콜백 후 listening=false")
        XCTAssertEqual(adapter.lastError, "권한 거부")
    }

    // MARK: - Keyword spotting (한국어)

    func testKoreanMarchKeywordCallsHandleMotion() {
        adapter.start()
        mock.simulate("걸어")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "handleMotion(id: preset.march) → lastIntent.kind = .motion(walk:march)")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march")
        XCTAssertEqual(adapter.lastRecognized, "걸어")
        XCTAssertEqual(bridge.lastIntent?.source, .voice, "source = voice")
    }

    func testKoreanMarchInSentenceMatches() {
        adapter.start()
        mock.simulate("지금 걸어줘")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "문장 내 '걸어' substring 매칭 → motion 발화")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march")
    }

    func testKoreanStopKeywordCallsHandleMotion() {
        adapter.start()
        mock.simulate("정지")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:idle"),
                       "preset.idle → lastIntent.kind = .motion(walk:idle)")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.idle")
    }

    func testKoreanJogKeywordCallsHandleMotion() {
        session.enableBalanceCorrection = true  // jog 는 caution preset 가능성 — 안전 활성.
        adapter.start()
        mock.simulate("조깅")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:jog"),
                       "preset.jog → lastIntent.kind = .motion(walk:jog)")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.jog")
    }

    func testKoreanEmergencyKeywordCallsEmergency() {
        session.start(.march)
        XCTAssertEqual(bridge.emergencyCount, 0)
        adapter.start()
        mock.simulate("비상")
        XCTAssertEqual(bridge.emergencyCount, 1, "비상 → emergency 1회")
        XCTAssertEqual(adapter.lastMatchedKeyword, "emergency")
        XCTAssertTrue(session.emergencyStopActive, "session emergency 활성")
    }

    func testKoreanRecoveryKeywordCallsRecovery() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive, "사전: emergency 활성")
        adapter.start()
        mock.simulate("복구")
        XCTAssertFalse(session.emergencyStopActive, "복구 → emergencyStopActive=false")
        XCTAssertEqual(adapter.lastMatchedKeyword, "recovery")
    }

    // MARK: - Keyword spotting (영어)

    func testEnglishWalkKeywordCallsHandleMotion() {
        adapter.start()
        mock.simulate("walk")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "walk → preset.march motion 발화")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march")
    }

    func testEnglishMarchKeywordCallsHandleMotion() {
        adapter.start()
        mock.simulate("march")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"))
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march")
    }

    func testEnglishWalkInSentenceMatches() {
        adapter.start()
        mock.simulate("please walk now")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "문장 내 'walk' substring 매칭")
    }

    func testEnglishStopKeywordCallsHandleMotion() {
        adapter.start()
        mock.simulate("stop")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:idle"))
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.idle")
    }

    func testEnglishIdleKeywordCallsHandleMotion() {
        adapter.start()
        mock.simulate("idle")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:idle"))
    }

    func testEnglishJogKeywordCallsHandleMotion() {
        session.enableBalanceCorrection = true
        adapter.start()
        mock.simulate("jog")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:jog"))
    }

    func testEnglishEmergencyKeywordCallsEmergency() {
        session.start(.march)
        adapter.start()
        mock.simulate("emergency")
        XCTAssertEqual(bridge.emergencyCount, 1)
        XCTAssertEqual(adapter.lastMatchedKeyword, "emergency")
    }

    func testEnglishRecoverKeywordCallsRecovery() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)
        adapter.start()
        mock.simulate("recover")
        XCTAssertFalse(session.emergencyStopActive)
        XCTAssertEqual(adapter.lastMatchedKeyword, "recovery")
    }

    // MARK: - Case insensitivity

    func testKeywordMatchIsCaseInsensitive() {
        adapter.start()
        mock.simulate("WALK")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "대문자 'WALK' 도 매칭")
    }

    func testMixedCaseSentenceMatches() {
        adapter.start()
        mock.simulate("Please MARCH now")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"),
                       "혼합 대소문자 substring 매칭")
    }

    // MARK: - Unknown keyword silent

    func testUnknownKeywordDoesNotCallBridge() {
        adapter.start()
        mock.simulate("hello world")
        XCTAssertNil(bridge.lastIntent, "bridge 미호출")
        XCTAssertEqual(bridge.emergencyCount, 0, "emergency 미발화")
        XCTAssertNil(adapter.lastMatchedKeyword, "매칭 없음 → keyword nil")
        XCTAssertEqual(adapter.lastRecognized, "hello world",
                       "lastRecognized 는 갱신 — '들리긴 함' 시각화")
    }

    func testUnknownKoreanKeywordSilent() {
        adapter.start()
        mock.simulate("안녕하세요")
        XCTAssertNil(bridge.lastIntent, "bridge 미호출")
        XCTAssertNil(adapter.lastMatchedKeyword)
        XCTAssertEqual(adapter.lastRecognized, "안녕하세요")
    }

    func testEmptyStringRecognitionSilent() {
        adapter.start()
        mock.simulate("")
        XCTAssertNil(bridge.lastIntent)
        XCTAssertNil(adapter.lastMatchedKeyword)
        XCTAssertEqual(adapter.lastRecognized, "")
    }

    // MARK: - 우선순위 (안전 우선)

    /// 한 발화에 "비상" + "걸어" 둘 다 포함 → emergency 가 우선.
    /// adapter 내부 처리 순서: emergency → recovery → march → idle → jog.
    func testSafetyKeywordWinsOverMotionKeyword() {
        session.start(.march)
        adapter.start()
        mock.simulate("비상 걸어")
        XCTAssertEqual(bridge.emergencyCount, 1, "emergency 우선")
        XCTAssertEqual(adapter.lastMatchedKeyword, "emergency")
        XCTAssertTrue(session.emergencyStopActive, "session 도 emergency 상태")
    }

    func testEnglishEmergencyWinsOverWalk() {
        session.start(.march)
        adapter.start()
        mock.simulate("emergency walk")
        XCTAssertEqual(bridge.emergencyCount, 1)
        XCTAssertEqual(adapter.lastMatchedKeyword, "emergency")
    }

    // MARK: - Bridge nil safety

    func testNilBridgeIsNoOp() {
        let orphan = VoicePilotAdapter(bridge: nil, recognizer: mock)
        orphan.start()
        // bridge 없으면 simulate 도 crash 안 함.
        mock.simulate("walk")
        XCTAssertNil(orphan.lastRecognized, "bridge nil → handleRecognition guard early-exit")
        XCTAssertNil(orphan.lastMatchedKeyword)
    }

    // MARK: - Multiple recognitions (interim → final 시뮬레이션)

    func testInterimAndFinalResultsBothProcessed() {
        adapter.start()
        mock.simulate("걸")  // interim — 매칭 없음.
        XCTAssertNil(adapter.lastMatchedKeyword)
        XCTAssertEqual(adapter.lastRecognized, "걸")

        mock.simulate("걸어")  // final — 매칭.
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"))
    }

    func testConsecutiveRecognitionsUpdateState() {
        adapter.start()
        mock.simulate("walk")
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.march")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:march"))

        mock.simulate("stop")
        XCTAssertEqual(bridge.lastIntent?.kind, .motion("walk:idle"))
        XCTAssertEqual(adapter.lastMatchedKeyword, "preset.idle")
    }

    // MARK: - InputSource = voice 검증

    func testAllVoiceCallsUseVoiceInputSource() {
        adapter.start()
        mock.simulate("walk")
        XCTAssertEqual(bridge.lastIntent?.source, .voice)

        mock.simulate("emergency")
        XCTAssertEqual(bridge.lastIntent?.source, .voice)
    }

    func testVoiceInputSourceHasKoreanLabel() {
        XCTAssertEqual(InputSource.voice.label, "음성")
        XCTAssertEqual(InputSource.voice.icon, "mic.fill")
        XCTAssertEqual(InputSource.voice.rawValue, "voice")
    }
}

// MARK: - MockVoiceRecognizer

/// **테스트 전용** — `VoiceRecognizing` 의 manual 구현. start/stop 횟수 추적 + 결과/에러
/// 콜백을 테스트가 직접 trigger.
@MainActor
final class MockVoiceRecognizer: VoiceRecognizing {
    var resultHandler: ((String) -> Void)?
    var errorHandler: ((String) -> Void)?
    var didStart: Bool = false
    var didStop: Bool = false
    var startCount: Int = 0
    var startError: Error?

    func setOnResult(_ handler: @escaping @MainActor (String) -> Void) {
        self.resultHandler = handler
    }

    func setOnError(_ handler: @escaping @MainActor (String) -> Void) {
        self.errorHandler = handler
    }

    func start() throws {
        if let err = startError {
            throw err
        }
        didStart = true
        startCount += 1
    }

    func stop() {
        didStop = true
    }

    /// 테스트 가 임의 인식 결과를 enqueue.
    func simulate(_ text: String) {
        resultHandler?(text)
    }

    /// 테스트 가 임의 에러를 enqueue.
    func simulateError(_ message: String) {
        errorHandler?(message)
    }
}
