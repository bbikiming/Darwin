import XCTest
@testable import DarwinForgeUI

/// 맥 마이크 체크 스토어 — mock 캡처로 레벨/전사/에러/정지 흐름 결정론 검증.
@MainActor
final class MacMicCheckStoreTests: XCTestCase {

    /// 콜백을 보관하고 simulate 로 임의 이벤트를 발화하는 mock.
    private final class MockCapture: MacMicCapturing {
        var onLevel: (@MainActor (Double, Double) -> Void)?
        var onTranscript: (@MainActor (String) -> Void)?
        var onError: (@MainActor (String) -> Void)?
        var startCalls = 0
        var stopCalls = 0
        var startError: Error?

        func setOnLevel(_ handler: @escaping @MainActor (Double, Double) -> Void) { onLevel = handler }
        func setOnTranscript(_ handler: @escaping @MainActor (String) -> Void) { onTranscript = handler }
        func setOnError(_ handler: @escaping @MainActor (String) -> Void) { onError = handler }
        func start() throws { startCalls += 1; if let e = startError { throw e } }
        func stop() { stopCalls += 1 }

        func simulateLevel(_ rms: Double, _ peak: Double) { onLevel?(rms, peak) }
        func simulateTranscript(_ text: String) { onTranscript?(text) }
        func simulateError(_ message: String) { onError?(message) }
    }

    private enum DummyError: Error { case boom }

    func testStartBeginsRecording() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(mock.startCalls, 1)
        XCTAssertNil(store.errorMessage)
    }

    func testLevelUpdatesAndSignalDetected() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        mock.simulateLevel(0.10, 0.20)
        mock.simulateLevel(0.30, 0.55)
        mock.simulateLevel(0.05, 0.08) // 최근값은 낮아도 max 는 유지
        XCTAssertEqual(store.level, 0.05, accuracy: 1e-9)
        XCTAssertEqual(store.maxLevel, 0.30, accuracy: 1e-9)
        XCTAssertEqual(store.peakObserved, 0.55, accuracy: 1e-9)
        XCTAssertTrue(store.signalDetected)
    }

    func testQuietSessionNoSignal() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        mock.simulateLevel(0.005, 0.01) // 잡음 바닥
        XCTAssertFalse(store.signalDetected)
    }

    func testTranscriptUpdates() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        mock.simulateTranscript("안녕")
        mock.simulateTranscript("안녕하세요 다윈")
        XCTAssertEqual(store.transcript, "안녕하세요 다윈")
        XCTAssertTrue(store.hasTranscript)
    }

    func testErrorStopsRecording() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        mock.simulateError("권한 거부됨")
        XCTAssertEqual(store.errorMessage, "권한 거부됨")
        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.hasFinished)
    }

    func testStartThrowHandledAsError() {
        let mock = MockCapture()
        mock.startError = DummyError.boom
        let store = MacMicCheckStore(capture: mock)
        store.start()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isRecording)
    }

    func testStopFinishes() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        store.stop()
        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.hasFinished)
        XCTAssertEqual(mock.stopCalls, 1)
    }

    func testToggleStartsThenStops() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.toggle()
        XCTAssertTrue(store.isRecording)
        store.toggle()
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(mock.startCalls, 1)
        XCTAssertEqual(mock.stopCalls, 1)
    }

    func testRestartResetsState() {
        let mock = MockCapture()
        let store = MacMicCheckStore(capture: mock)
        store.start()
        mock.simulateLevel(0.4, 0.6)
        mock.simulateTranscript("이전 세션")
        store.stop()
        // 재시작 시 이전 상태 초기화.
        store.start()
        XCTAssertEqual(store.maxLevel, 0, accuracy: 1e-9)
        XCTAssertEqual(store.peakObserved, 0, accuracy: 1e-9)
        XCTAssertEqual(store.transcript, "")
        XCTAssertFalse(store.hasFinished)
    }
}
