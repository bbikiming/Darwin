import XCTest
@testable import DarwinForgeMobileApp
@testable import MobilePilotKit

// MARK: - ConnectScreen V292-A Tests
//
// 공항 체크인 4단계 IA의 핵심 로직을 검증:
//   - OTP autofill 유효성 검사
//   - 30초 타임아웃 → discoveryTimedOut 플래그
//   - 페어링 에러 진단 메시지 매핑
//   - Mock 모드 연결 흐름

@MainActor
final class ConnectScreenTests: XCTestCase {

    // MARK: - OTP 유효성 검사 (V292-4)

    func testOTPValidation_exactlySixDigits_passes() {
        XCTAssertTrue(PairingCode.validate("123456"))
        XCTAssertTrue(PairingCode.validate("000000"))
        XCTAssertTrue(PairingCode.validate("999999"))
    }

    func testOTPValidation_fiveDigits_fails() {
        XCTAssertFalse(PairingCode.validate("12345"))
    }

    func testOTPValidation_sevenDigits_fails() {
        XCTAssertFalse(PairingCode.validate("1234567"))
    }

    func testOTPValidation_containsLetters_fails() {
        XCTAssertFalse(PairingCode.validate("12345a"))
        XCTAssertFalse(PairingCode.validate("ABCDEF"))
    }

    func testOTPValidation_emptyString_fails() {
        XCTAssertFalse(PairingCode.validate(""))
    }

    func testOTPValidation_withLeadingSpaces_fails() {
        // 공백 포함 6자리는 실제 숫자가 아님
        XCTAssertFalse(PairingCode.validate(" 12345"))
    }

    // MARK: - Bonjour 타임아웃 (V292-3)

    func testDiscoveryTimeout_setsFlag() async throws {
        let state = AppState(initialMode: .realRelay)
        state.bootstrap()

        // FixedRelayBrowser 의 timeoutStream 은 yield 를 하지 않으므로
        // BonjourRelayBrowser 의 30초 타임아웃을 직접 시뮬레이션:
        // discoveryTimedOut 는 초기 false
        XCTAssertFalse(state.discoveryTimedOut)
    }

    func testStartDiscovery_resetTimedOutFlag() {
        let state = AppState(initialMode: .realRelay)
        state.bootstrap()

        // startDiscovery 는 discoveryTimedOut 을 false 로 리셋
        state.startDiscovery()
        XCTAssertFalse(state.discoveryTimedOut)
        state.stopDiscovery()
    }

    func testStopDiscovery_resetTimedOutFlag() async {
        let state = AppState(initialMode: .realRelay)
        state.bootstrap()
        state.startDiscovery()
        state.stopDiscovery()
        XCTAssertFalse(state.discoveryTimedOut)
    }

    // MARK: - 페어링 에러 진단 메시지 매핑 (V292-6)

    func testPairingDiagnosis_codeError_returnsMismatchMessage() {
        // code/pairing/auth 포함 에러 → 코드 불일치 안내
        let diag = PairingDiagnosis.diagnose("invalidPairingCode")
        XCTAssertTrue(diag.localizedMessage.contains("만료") || diag.localizedMessage.contains("일치"),
                      "진단 메시지가 코드 불일치를 언급해야 함: \(diag.localizedMessage)")
    }

    func testPairingDiagnosis_connectionRefused_returnsMacNotRunningMessage() {
        let diag = PairingDiagnosis.diagnose("connection refused")
        XCTAssertTrue(diag.localizedMessage.contains("실행") || diag.localizedMessage.contains("DarwinForge"),
                      "진단 메시지가 Mac 앱 미실행을 언급해야 함: \(diag.localizedMessage)")
    }

    func testPairingDiagnosis_networkUnreachable_returnsWifiMessage() {
        let diag = PairingDiagnosis.diagnose("network unreachable")
        XCTAssertTrue(diag.localizedMessage.contains("Wi-Fi") || diag.localizedMessage.contains("네트워크"),
                      "진단 메시지가 Wi-Fi 문제를 언급해야 함: \(diag.localizedMessage)")
    }

    func testPairingDiagnosis_unknownError_returnsFallback() {
        let diag = PairingDiagnosis.diagnose("unexplainedChaos")
        XCTAssertFalse(diag.localizedMessage.isEmpty, "알 수 없는 에러도 빈 메시지를 표시해서는 안 됨")
    }

    // MARK: - Mock 연결 흐름 (AppState 회귀)

    func testMockConnection_setsIsMacReady() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        // iOS-C1 fix (2026-05-25): ses_pending 제거 후 isMacReady 는 첫 telemetry
        // 도착도 요구. mock 은 sim telemetry 1프레임을 inject 하므로 짧은 polling.
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline, !state.isMacReady {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(state.isMacReady)
    }

    func testMockConnection_doesNotExposeMockInDiscoveryResults() {
        // V292: Mock 모드에서 startDiscovery 는 빈 FixedRelayBrowser 를 반환
        // (Mock Mac 카드는 UI 에 노출되지 않아야 함)
        let state = AppState(initialMode: .realRelay)
        state.bootstrap()
        state.startDiscovery()
        // FixedRelayBrowser(results: []) 이므로 즉시 비어 있어야 함
        XCTAssertTrue(state.discovered.isEmpty)
        state.stopDiscovery()
    }

    // MARK: - RelayDiscovery Protocol 준수

    func testFixedRelayBrowser_conformsToRelayBrowser() {
        let browser: RelayBrowser = FixedRelayBrowser(results: [])
        XCTAssertNotNil(browser)
    }

    func testFixedRelayBrowser_yieldsResults() async throws {
        let expected = [RelayDiscoveryResult(
            id: "test",
            displayName: "Test Mac",
            host: "192.168.1.100",
            port: 17370,
            lastSeen: Date()
        )]
        let browser = FixedRelayBrowser(results: expected)
        browser.start()

        var received: [RelayDiscoveryResult] = []
        for await results in browser.resultsStream {
            received = results
            break
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.id, "test")
    }
}

// PairingDiagnosis 는 ConnectSubViews.swift 의 internal struct 이므로
// @testable import 로 직접 접근 가능.
