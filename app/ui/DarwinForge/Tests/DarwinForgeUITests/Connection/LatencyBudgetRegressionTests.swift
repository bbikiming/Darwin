import XCTest
@testable import DarwinForgeUI

/// 고정 지연 loopback transport — 실 SSH/네트워크 없이 채널 드레인·마크 경로 검증.
private actor LoopbackTransport: OnboardLineTransport {
    let delayMs: UInt64
    private(set) var sentCount = 0
    private(set) var stopCount = 0
    init(delayMs: UInt64) { self.delayMs = delayMs }

    func send(_ command: OnboardCommand) async throws -> OnboardAck {
        if delayMs > 0 { try? await Task.sleep(nanoseconds: delayMs * 1_000_000) }
        sentCount += 1
        // 로봇 ts 회신(클럭 오프셋 경로 자극) — Mac epoch 근처 임의값.
        let robotTs = Int64(Date().timeIntervalSince1970 * 1000) + 3
        return OnboardAck(cmdId: command.cmdId, robotTsMs: robotTs, exitCode: 0)
    }
    func sendStopFireAndForget(_ line: String) async { stopCount += 1 }
    func shutdown() async {}

    func snapshot() -> (sent: Int, stop: Int) { (sentCount, stopCount) }
}

/// E-STOP 버스트 발사 기록용 mock.
private actor MockEstopSender: EstopBurstSender {
    private(set) var fires: [(token: String, ts: Int64)] = []
    func fireBurst(token: String, unixMillis: Int64) async {
        fires.append((token, unixMillis))
    }
    func count() -> Int { fires.count }
    func lastToken() -> String? { fires.last?.token }
}

/// **W1 §6 — 레이턴시 버짓 회귀 게이트** + 채널 드레인/E-STOP 통합.
///
/// 네트워크 변동을 배제한 코드-경로 버짓만 검증(임계 2배 마진). 실 무선 RTT 합격선은
/// 실기 벤치(사용자 보고)에서 측정한다.
final class LatencyBudgetRegressionTests: XCTestCase {

    /// input→channelSent 코드-경로 p95 상한(ms). 2× 마진(설계 §6).
    private let inputToSentBudgetMs: Double = 60

    override func setUp() {
        super.setUp()
        PilotLatencyTracer.shared.reset()
        PilotLatencyTracer.shared.setEnabled(true)
    }

    override func tearDown() {
        PilotLatencyTracer.shared.setEnabled(false)
        PilotLatencyTracer.shared.reset()
        super.tearDown()
    }

    func testInputToSent_p95_withinBudget_under300Events() async {
        let transport = LoopbackTransport(delayMs: 5)
        let channel = OnboardCommandChannel(transport: transport, estop: nil, token: "T")

        for seq in 0..<300 {
            let s = UInt32(seq)
            PilotLatencyTracer.shared.mark(.inputSampled, seq: s)
            await channel.send(OnboardCommand(
                line: "c\(seq) 1 28 0 0 600 40",
                cmdId: "c\(seq)",
                policy: .latestWins(key: "tuning"),
                traceSeq: s
            ))
        }

        // 드레인 완료 대기(coalescing 으로 일부만 실제 송출됨).
        await waitForDrain(channel)

        let stats = PilotLatencyTracer.shared.inputToSentStats()
        XCTAssertGreaterThan(stats.count, 0, "적어도 일부 명령은 송출돼 마크돼야")
        XCTAssertLessThanOrEqual(stats.p95Ms, inputToSentBudgetMs,
            "input→channelSent p95 \(stats.p95Ms)ms 가 버짓 \(inputToSentBudgetMs)ms 초과")
    }

    func testLatestWins_coalescesUnderLoad_fewerSendsThanEnqueues() async {
        let transport = LoopbackTransport(delayMs: 3)
        let channel = OnboardCommandChannel(transport: transport, estop: nil, token: "T")
        for seq in 0..<100 {
            await channel.send(OnboardCommand(
                line: "c\(seq) 1 \(seq) 0 0 600 40",
                cmdId: "c\(seq)",
                policy: .latestWins(key: "tuning")
            ))
        }
        await waitForDrain(channel)
        let snap = await transport.snapshot()
        // 코얼레싱이 stale 명령을 제거 → 송출 수 < 100(전부 송출되지 않음).
        XCTAssertGreaterThan(snap.sent, 0)
        XCTAssertLessThan(snap.sent, 100, "latest-wins 코얼레싱으로 송출 수가 enqueue 수보다 적어야")
    }

    func testEmergencyStop_firesBurstAndSshStop_andRecordsAlwaysOnMark() async {
        let transport = LoopbackTransport(delayMs: 0)
        let estop = MockEstopSender()
        let channel = OnboardCommandChannel(transport: transport, estop: estop, token: "TOK9")

        await channel.sendEmergencyStopNow(stopLine: "estop 0 0 0 0 600 40", traceSeq: 77)

        // fire-and-forget(detached) — 완료를 짧게 대기.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let fires = await estop.count()
        let lastToken = await estop.lastToken()
        XCTAssertGreaterThanOrEqual(fires, 1, "E-STOP 버스트가 발사돼야")
        XCTAssertEqual(lastToken, "TOK9")
        let snap = await transport.snapshot()
        XCTAssertGreaterThanOrEqual(snap.stop, 1, "SSH stop 도 병행 발사돼야")
        // E-STOP request→sent 는 항상 기록(안전 회귀 감시).
        XCTAssertGreaterThanOrEqual(PilotLatencyTracer.shared.estopToSentStats().count, 1)
    }

    // 큐가 빌 때까지 폴링(드레인 완료) — 최대 ~5s.
    private func waitForDrain(_ channel: OnboardCommandChannel) async {
        for _ in 0..<500 {
            if await channel.pendingCount() == 0 {
                try? await Task.sleep(nanoseconds: 20_000_000)   // 마지막 in-flight 여유.
                if await channel.pendingCount() == 0 { return }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
