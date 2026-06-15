/// **UDP 텔레메트리 푸시 수신기 단위 테스트 (2026-06-03)**.
///
/// 실 UDP socket 을 열지 않고 Mock + lifecycle + 콜백 경로를 검증한다(`TelloStateListenerTests`
/// 패턴 미러 — CI/sandbox 안전). 실 수신기는 init 비용 0(lazy bind)임도 보장.
/// 파서 자체(범위/거부 케이스)는 `OnboardTelemetryTests` 가 이미 커버 — 여기선 transport 계층만.
import Foundation
import Network
import XCTest

@testable import DarwinForgeUI

final class OnboardTelemetryUDPReceiverTests: XCTestCase {

    // contract §A.2 예시 줄 (OnboardTelemetryTests 와 동일).
    private let validLine = "TEL 1748736000123 511 530 498 512 489 760 122 1 0"

    // MARK: - Mock

    /// Test-only Mock — `simulate(raw:)` 로 datagram 수신을 흉내내 onSample 발화 검증.
    /// UDP socket 미사용. `@unchecked Sendable`: 테스트 단일 thread, state 는 test queue 격리.
    final class MockOnboardTelemetryUDPReceiver: OnboardTelemetryUDPReceiverProtocol, @unchecked Sendable {
        var onSample: (@Sendable (OnboardTelemetry) -> Void)?

        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var simulatedCount = 0
        private(set) var isStarted = false

        func start() throws {
            startCount += 1
            isStarted = true
        }

        func stop() {
            stopCount += 1
            isStarted = false
        }

        /// raw datagram 흉내 — 실 수신기와 동일하게 `OnboardTelemetry.parse` 통과 시에만 발화.
        func simulate(raw: String) {
            simulatedCount += 1
            guard isStarted else { return }
            guard let sample = OnboardTelemetry.parse(raw) else { return }
            onSample?(sample)
        }

        /// 이미 parsed 된 샘플을 직접 발화 — pure callback path.
        func simulate(_ sample: OnboardTelemetry) {
            simulatedCount += 1
            guard isStarted else { return }
            onSample?(sample)
        }
    }

    // MARK: - Mock 행위

    func testMockFiresCallbackOnSimulate() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        var received: [OnboardTelemetry] = []
        receiver.onSample = { received.append($0) }

        try? receiver.start()
        receiver.simulate(raw: validLine)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.tsMs, 1_748_736_000_123)
        XCTAssertEqual(received.first?.gyroX, 511)
        XCTAssertEqual(received.first?.voltageDeciVolts, 122)
        XCTAssertTrue(received.first?.walking == true)
    }

    func testMockSilentBeforeStart() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        var received: [OnboardTelemetry] = []
        receiver.onSample = { received.append($0) }

        // start() 미호출 → callback 미발화 (lifecycle 안전).
        receiver.simulate(raw: validLine)
        XCTAssertTrue(received.isEmpty, "start() 전에는 콜백 미발화")
    }

    func testMockParseFailureIsSilent() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        var received: [OnboardTelemetry] = []
        receiver.onSample = { received.append($0) }
        try? receiver.start()

        // 깨진 datagram → parse nil → 콜백 미발화, 단 simulate 카운트는 증가(listen 계속).
        receiver.simulate(raw: "garbage not telemetry")
        XCTAssertTrue(received.isEmpty, "parse 실패 시 콜백 안 불려야 함 — 다음 datagram 대기")
        XCTAssertEqual(receiver.simulatedCount, 1)
    }

    func testMockMultipleSamplesOrdering() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        var tsList: [Int64] = []
        receiver.onSample = { tsList.append($0.tsMs) }

        try? receiver.start()
        for ts in [Int64(1000), 1200, 1400, 1600] {
            receiver.simulate(raw: "TEL \(ts) 512 512 512 512 512 512 0 0 0")
        }
        XCTAssertEqual(tsList, [1000, 1200, 1400, 1600], "수신 순서 보존")
    }

    func testMockSimulateWithPrebuiltSample() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        var last: OnboardTelemetry?
        receiver.onSample = { last = $0 }
        try? receiver.start()

        let prebuilt = OnboardTelemetry(
            tsMs: 5000, gyroX: 1, gyroY: 2, gyroZ: 3,
            accelX: 4, accelY: 5, accelZ: 6,
            voltageDeciVolts: 118, walking: true, fallen: -1)
        receiver.simulate(prebuilt)

        XCTAssertEqual(last?.tsMs, 5000)
        XCTAssertEqual(last?.voltageDeciVolts, 118)
        XCTAssertEqual(last?.fallen, -1)
    }

    // MARK: - Lifecycle

    func testMockLifecycleCounts() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        XCTAssertEqual(receiver.startCount, 0)
        XCTAssertFalse(receiver.isStarted)

        try? receiver.start()
        XCTAssertEqual(receiver.startCount, 1)
        XCTAssertTrue(receiver.isStarted)

        receiver.stop()
        XCTAssertEqual(receiver.stopCount, 1)
        XCTAssertFalse(receiver.isStarted)
    }

    func testMockStopIdempotent() {
        let receiver = MockOnboardTelemetryUDPReceiver()
        try? receiver.start()
        receiver.stop()
        receiver.stop()
        receiver.stop()
        XCTAssertEqual(receiver.stopCount, 3, "stop() 반복 안전 — count 만 증가")
    }

    // MARK: - 실 수신기 init / port 상수

    func testRealReceiverInitDoesNotOpenSocket() {
        // init 시 socket 미개방 보장 — start() 전까지 cost 0 (CI/sandbox port 충돌 회피).
        let receiver = OnboardTelemetryUDPReceiver()
        XCTAssertNotNil(receiver)
        receiver.stop()   // start 안 했으므로 no-op.
    }

    func testRealReceiverInitWithCustomPort() {
        let custom: NWEndpoint.Port = 18371
        let receiver = OnboardTelemetryUDPReceiver(port: custom)
        XCTAssertNotNil(receiver)
        receiver.stop()
    }

    func testRealReceiverDefaultPortMatchesConstant() {
        // 계약값 — 로봇 sendto 대상과 일치해야 함.
        XCTAssertEqual(OnboardTelemetryUDPReceiver.defaultPort.rawValue, 17371)
        XCTAssertEqual(OnboardTelemetryUDPReceiver.defaultPort.rawValue,
                       DFConnectionConstants.telemetryUDPPort)
    }

    func testRealReceiverOnSampleAssignableBeforeStart() {
        let receiver = OnboardTelemetryUDPReceiver()
        var fired = false
        receiver.onSample = { _ in fired = true }
        XCTAssertFalse(fired, "start 전 자연 미발화")
        receiver.stop()
    }

    // MARK: - 통합: 콜백 → @MainActor hop (ConnectionStore.ingest 배선과 동형)

    @MainActor
    func testCallbackCanHopToMainActor() async {
        // 실 wiring 은 onSample(background) → Task { @MainActor in ingest } 형태.
        // 여기선 동형 경로가 MainActor 에서 샘플을 수집하는지 검증(소켓 없이).
        let receiver = MockOnboardTelemetryUDPReceiver()
        var mainActorTs: Int64?
        receiver.onSample = { sample in
            Task { @MainActor in mainActorTs = sample.tsMs }
        }
        try? receiver.start()
        receiver.simulate(raw: validLine)

        try? await Task.sleep(nanoseconds: 200_000_000)   // MainActor hop 완료 대기.
        XCTAssertEqual(mainActorTs, 1_748_736_000_123, "콜백이 MainActor 까지 샘플 전파")
    }
}
