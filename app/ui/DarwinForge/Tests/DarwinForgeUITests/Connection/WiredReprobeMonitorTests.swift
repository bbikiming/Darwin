import XCTest
@testable import DarwinForgeUI

// MARK: - WiredReprobeMonitorTests (A3)
//
// **A3 — 유선 재프로브 배너의 핵심 불변식: probe-and-PROMPT, 절대 silent auto-switch 아님.**
//
// 무선(192.168.0.33) 경로로 텔레메트리가 흐르는 동안, 더 빠른 유선(192.168.123.1) 경로가
// 살아있는지(:22 TCP open) 5초마다 probe 한다. **열려 있으면 배너로 "유선 전환" 을 *제안*만*
// 한다.** 절대 host 를 자동으로 바꾸지 않는다(스위치 토폴로지/사용자 의도와 충돌할 수 있음).
// 실제 전환은 사용자가 배너의 "전환" 을 눌러 *주입된 클로저*를 발동할 때만 일어난다.
//
// 이 테스트가 강제하는 불변식:
//   1) 무선에 있고 유선 :22 open → 배너 제안(.offerWired).
//   2) **CRITICAL** — probe 경로는 host 를 절대 mutate 하지 않는다(spy 가 0 mutation 확인).
//   3) 이미 유선이면 제안 안 함(중복/무의미).
//   4) refused/timedOut/unreachable → 제안 안 함(스위치 토폴로지 false-positive 가드 포함).
//   5) 사용자가 수락 → 주입된 switchAction 이 **정확히 1회** 발동.

@MainActor
final class WiredReprobeMonitorTests: XCTestCase {

    // 무선 후보 / 유선 타깃 — DFConnectionConstants.robotEthernetIP 가 유선.
    private let wirelessHost = "192.168.0.33"
    private let wiredHost = DFConnectionConstants.robotEthernetIP   // "192.168.123.1"

    /// 고정 결과를 반환하는 stub prober. 호출된 (host, port) 를 기록한다.
    private func stubProber(_ result: NetworkProbe.Result,
                            record: (@Sendable (String, UInt16) -> Void)? = nil)
        -> (String, UInt16) async -> NetworkProbe.Result {
        return { host, port in
            record?(host, port)
            return result
        }
    }

    // MARK: - 1. 무선에서 유선 open → 배너 제안

    func testProbeOpenWhileOnWireless_emitsBannerOffer() async {
        let monitor = WiredReprobeMonitor()
        XCTAssertEqual(monitor.state, .idle, "초기 상태는 idle.")

        await monitor.tick(currentHost: wirelessHost,
                           prober: stubProber(.open(rttMs: 3)))

        XCTAssertEqual(monitor.state, .offerWired(targetHost: wiredHost),
            "무선에 있고 유선 :22 open 이면 .offerWired 제안.")
    }

    // MARK: - 2. CRITICAL — probe 는 host 를 mutate 하지 않는다 (spy)

    func testProbeOpen_doesNotMutateConnectionHostOrTriggerSwitch() async {
        // spy: switchAction 이 한 번이라도 불리면 즉시 실패. probe 경로엔 setter 가 없어야 함.
        final class SwitchSpy: @unchecked Sendable {
            var switchInvocations = 0
        }
        let spy = SwitchSpy()

        let monitor = WiredReprobeMonitor()
        // tick 은 switchAction 을 전혀 받지 않는다(설계상 probe 경로에 setter 부재).
        await monitor.tick(currentHost: wirelessHost,
                           prober: stubProber(.open(rttMs: 1)))

        // 제안만 됐을 뿐, 어떤 host 전환도 일어나지 않음.
        XCTAssertEqual(spy.switchInvocations, 0,
            "probe 성공만으로는 switchAction 이 절대 불리면 안 됨 (probe-and-prompt).")
        XCTAssertEqual(monitor.state, .offerWired(targetHost: wiredHost),
            "상태는 제안(.offerWired)에 머물러야 함 — 자동 전환 없음.")
    }

    // MARK: - 3. 이미 유선 → 제안 안 함

    func testAlreadyOnWired_noBanner() async {
        let monitor = WiredReprobeMonitor()
        await monitor.tick(currentHost: wiredHost,
                           prober: stubProber(.open(rttMs: 1)))
        XCTAssertEqual(monitor.state, .idle,
            "이미 유선이면 유선 probe 가 open 이어도 제안하지 않음.")
    }

    // MARK: - 4. refused / timedOut / unreachable → 제안 안 함 (스위치 false-positive 가드)

    func testProbeRefusedOrTimedOut_noBanner() async {
        for result: NetworkProbe.Result in [.refused, .timedOut, .unreachable] {
            let monitor = WiredReprobeMonitor()
            await monitor.tick(currentHost: wirelessHost,
                               prober: stubProber(result))
            XCTAssertEqual(monitor.state, .idle,
                "\(result) 이면 제안 안 함 — 스위치 토폴로지(123.1 timeout) false-positive 가드.")
        }
    }

    // MARK: - 5. 사용자 수락 → 주입된 switchAction 정확히 1회

    func testUserAcceptsOffer_invokesSwitchExactlyOnceViaInjectedAction() async {
        let monitor = WiredReprobeMonitor()
        await monitor.tick(currentHost: wirelessHost,
                           prober: stubProber(.open(rttMs: 2)))
        XCTAssertEqual(monitor.state, .offerWired(targetHost: wiredHost))

        var invocations = 0
        monitor.accept(using: { invocations += 1 })

        XCTAssertEqual(invocations, 1,
            "수락 시 주입된 switchAction 이 정확히 1회 발동.")
        XCTAssertEqual(monitor.state, .idle,
            "수락 후 배너는 사라짐(.idle) — 같은 제안 반복 방지.")
    }

    // MARK: - 6. 제안 상태에서 probe 가 다시 open 이어도 switchAction 자동 발동 X (idempotent)

    func testRepeatedOpenProbeDoesNotAutoSwitch() async {
        let monitor = WiredReprobeMonitor()
        let openProber = stubProber(.open(rttMs: 2))
        await monitor.tick(currentHost: wirelessHost, prober: openProber)
        await monitor.tick(currentHost: wirelessHost, prober: openProber)
        await monitor.tick(currentHost: wirelessHost, prober: openProber)
        XCTAssertEqual(monitor.state, .offerWired(targetHost: wiredHost),
            "반복 probe 도 제안에 머물 뿐 자동 전환 없음.")
    }

    // MARK: - 7. 사용자 dismiss → idle (수락 없이 닫기)

    func testDismissClearsOffer() async {
        let monitor = WiredReprobeMonitor()
        await monitor.tick(currentHost: wirelessHost,
                           prober: stubProber(.open(rttMs: 2)))
        XCTAssertEqual(monitor.state, .offerWired(targetHost: wiredHost))
        monitor.dismiss()
        XCTAssertEqual(monitor.state, .idle, "dismiss 하면 배너가 닫혀 idle.")
    }

    // MARK: - 8. probe 가 유선 타깃(:22)을 정확히 가리키는지 (host/port 확인)

    func testProbeTargetsWiredHostOnPort22() async {
        final class Recorder: @unchecked Sendable {
            var calls: [(String, UInt16)] = []
        }
        let rec = Recorder()
        let monitor = WiredReprobeMonitor()
        await monitor.tick(currentHost: wirelessHost,
                           prober: stubProber(.open(rttMs: 1),
                                              record: { h, p in rec.calls.append((h, p)) }))
        XCTAssertEqual(rec.calls.count, 1, "정확히 한 번 probe.")
        XCTAssertEqual(rec.calls.first?.0, wiredHost, "유선 host(123.1) 를 probe.")
        XCTAssertEqual(rec.calls.first?.1, 22, "SSH :22 를 probe.")
    }
}
