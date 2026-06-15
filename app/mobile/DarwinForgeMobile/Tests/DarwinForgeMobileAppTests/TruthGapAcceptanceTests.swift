import XCTest
@testable import DarwinForgeMobileApp
@testable import MobilePilotKit

/// iOS-M1 (truth-gap report, 2026-05-25): acceptance tests for the
/// "iOS shows connected vs Mac shows waiting" mismatch class of bugs.
///
/// Goal: pin the iOS surface to authoritative handshake (real sessionId)
/// instead of optimistic UI flips.
@MainActor
final class TruthGapAcceptanceTests: XCTestCase {

    /// QR 스캔/수동 IP 입력처럼 실제 Mac endpoint 로 연결하는 경로는
    /// 현재 앱 모드가 Mock 이더라도 반드시 Real Relay 클라이언트를 써야 한다.
    func testRealEndpointRequiresRealRelayMode() {
        let endpoint = RelayEndpoint(host: "192.168.0.60",
                                     port: 17370,
                                     pairingCode: "123456")

        XCTAssertEqual(AppState.desiredConnectionMode(for: endpoint), .realRelay,
                       "실제 IP/port endpoint 는 MockRelayClient 로 연결하면 Mac 앱이 계속 대기 중으로 남는다")
    }

    /// 리뷰/데모용 Mock endpoint 만 Mock 모드를 유지한다.
    func testMockEndpointKeepsMockReviewMode() {
        let endpoint = RelayEndpoint(host: "mock",
                                     port: 0,
                                     pairingCode: "000000")

        XCTAssertEqual(AppState.desiredConnectionMode(for: endpoint), .mockReview)
    }

    /// host 문자열에 mock 이 포함되어도 실제 port 를 가진 endpoint 는 Real Relay 여야 한다.
    func testMockNamedNetworkHostStillRequiresRealRelayMode() {
        let endpoint = RelayEndpoint(host: "mock.local",
                                     port: 17370,
                                     pairingCode: "123456")

        XCTAssertEqual(AppState.desiredConnectionMode(for: endpoint), .realRelay)
    }

    /// Source of truth: after `connectMockReview()`, the published
    /// `currentSessionId` must be the **mock relay's actual sessionId**
    /// (`ses_MOCK01`), NOT the legacy `ses_pending` placeholder.
    func testConnectExposesRealSessionIdAfterWelcome() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()

        try await waitFor(seconds: 0.2) {
            state.currentSessionId != nil
        }
        let sid = state.currentSessionId
        XCTAssertNotNil(sid, "transport stream 이 sessionId 를 yield 해야 한다")
        XCTAssertNotEqual(sid, "ses_pending",
                          "ses_pending placeholder 가 published 되어선 안 된다 (iOS-C1)")
        XCTAssertTrue(sid?.hasPrefix("ses_") ?? false,
                      "MockRelay 의 sessionId prefix 는 ses_ 이어야 한다")
    }

    /// `isMacReady` 는 transport `.connected` + 첫 telemetry 둘 다 도착해야
    /// true. handshake 만 통과한 상태는 `isMacHandshaking` 으로 분리.
    func testHandshakeCompleteOnlyAfterTelemetry() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()

        try await waitFor(seconds: 0.3) {
            state.telemetry != nil
        }
        XCTAssertTrue(state.isMacReady, "transport+telemetry 모두 OK 면 isMacReady")
        XCTAssertFalse(state.isMacHandshaking,
                       "telemetry 도착 후엔 더 이상 handshaking 으로 표시되지 않음")
        XCTAssertNotNil(state.lastTelemetryAgeMs,
                        "lastTelemetryAgeMs 가 노출돼야 한다 (iOS-C2)")
    }

    /// disconnect 후 `currentSessionId` 가 nil 로 정리되고 `isMacReady` 해제.
    func testDisconnectClearsSessionAndReadiness() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        try await waitFor(seconds: 0.3) { state.telemetry != nil }
        XCTAssertNotNil(state.currentSessionId)

        await state.disconnect(reason: "test")
        try await waitFor(seconds: 0.3) {
            state.currentSessionId == nil
        }
        XCTAssertNil(state.currentSessionId,
                     "disconnect 후 sessionId 는 nil 이어야 한다")
        XCTAssertFalse(state.isMacReady,
                       "disconnect 후 isMacReady 는 false")
        XCTAssertNil(state.telemetry,
                     "disconnect 시 telemetry 도 클리어")
    }

    /// connectionMode 전환 시 기존 transport/session state 가 전부 클리어돼야
    /// stale ses_pending 같은 잔존 상태가 안 보인다.
    func testModeSwitchClearsState() async throws {
        let state = AppState(initialMode: .mockReview)
        state.bootstrap()
        await state.connectMockReview()
        try await waitFor(seconds: 0.3) { state.currentSessionId != nil }

        await state.setConnectionMode(.realRelay)
        XCTAssertEqual(state.connectionMode, .realRelay)
        XCTAssertFalse(state.isMockMode)
        // setConnectionMode 가 disconnect 를 호출하지만 transport stream 갱신은
        // 비동기 — 짧은 polling 으로 currentSessionId == nil 확인.
        try await waitFor(seconds: 0.3) { state.currentSessionId == nil }
        XCTAssertNil(state.currentSessionId,
                     "모드 전환 직후 이전 sessionId 가 잔존하면 안 된다")
    }

    // MARK: - Helpers

    /// Poll-with-timeout helper — async stream race 를 피하기 위해 사용.
    private func waitFor(seconds: TimeInterval,
                         interval: TimeInterval = 0.02,
                         _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
