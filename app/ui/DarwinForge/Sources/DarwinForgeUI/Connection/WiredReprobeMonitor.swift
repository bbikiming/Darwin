import Foundation

/// **A3 (2026-06-14)** — 유선 재프로브 모니터: *probe-and-prompt*, 절대 silent auto-switch 아님.
///
/// # 무엇을 하나
///
/// 무선(192.168.0.33) 경로로 온보드 텔레메트리가 흐르는 동안, 더 빠른 유선(192.168.123.1, ~166x)
/// 경로가 살아있는지(:22 TCP open) 주기적으로 확인한다. 열려 있으면 **배너로 "유선 전환" 을
/// 제안만** 한다 — host 를 자동으로 바꾸지 않는다.
///
/// # 왜 제안만 하나 (불변식)
///
/// 비유: 내비가 "더 빠른 길이 있어요. 바꿀까요?" 라고 *물어볼* 뿐, 운전대를 빼앗아 멋대로
/// 핸들을 꺾지 않는 것과 같다. 자동 전환은 스위치(Switch) 토폴로지·사용자 의도와 충돌할 수
/// 있어 위험하다. 그래서:
///   - 이 타입은 **어떤 host setter / ConnectionStore mutation 도 보유하지 않는다.**
///   - `tick(...)` probe 경로는 오직 `state` 만 갱신한다(부수효과 0).
///   - 실제 전환은 사용자가 배너를 눌러 `accept(using:)` 에 *주입된 클로저*를 발동할 때만.
///
/// # False-positive 가드
///
/// 스위치 토폴로지에서 123.1 은 timeout 으로 떨어진다(MEMORY: 123.1=timeout). probe 결과가
/// `.open` 이 *아닌* 모든 경우(refused/timedOut/unreachable)는 제안하지 않으므로, 유선이 실제로
/// 살아있지 않은 토폴로지에서 헛제안이 나오지 않는다.
@MainActor
public final class WiredReprobeMonitor: ObservableObject {

    /// 무선(현재) 후보 host. 이 host 일 때만 유선 probe 를 시도한다.
    public static let wirelessCandidate = "192.168.0.33"
    /// 유선(권장) 타깃 host — DFConnectionConstants 의 표준 eth IP.
    public static let wiredTarget = DFConnectionConstants.robotEthernetIP
    /// 유선 reachability 판정에 쓰는 포트(SSH).
    public static let probePort: UInt16 = DFConnectionConstants.sshPort

    /// 배너 상태. `idle` = 표시 안 함. `offerWired` = "유선 전환" 배너 표시.
    public enum State: Equatable {
        case idle
        case offerWired(targetHost: String)
    }

    @Published public private(set) var state: State = .idle

    public init() {}

    /// 한 번의 재프로브 사이클. **probe 경로는 host 를 절대 mutate 하지 않는다** — `state` 만 갱신.
    ///
    /// - Parameters:
    ///   - currentHost: 현재 텔레메트리가 흐르는 host. `wirelessCandidate` 일 때만 probe.
    ///   - prober: `(host, port) -> Result`. 기본값은 실 TCP probe. 테스트는 stub 주입.
    ///
    /// 로직:
    ///   1) 이미 유선(또는 무선 후보가 아님)이면 → 제안 안 함(idle 유지, 진행 중 제안은 보존하지
    ///      않고 idle 로 — host 가 무선이 아니게 되면 무의미한 제안이므로 닫는다).
    ///   2) 무선 후보일 때만 유선 `:22` 를 probe → `.open` 이면 `.offerWired`, 그 외 idle.
    ///
    /// `internal` 접근 — probe 경로는 module 내부(브리지 tick + 테스트)에서만 호출한다. 기본
    /// 인자 `prober` 가 internal `NetworkProbe.tcpProbe` 어댑터라, public 이면 접근수준 위반.
    func tick(currentHost: String,
              prober: (String, UInt16) async -> NetworkProbe.Result
                 = NetworkProbe.tcpProbe(host:port:)) async {
        // 무선 후보가 아니면(이미 유선이거나 다른 host) 제안할 이유 없음.
        guard currentHost == Self.wirelessCandidate else {
            if state != .idle { state = .idle }
            return
        }
        let result = await prober(Self.wiredTarget, Self.probePort)
        switch result {
        case .open:
            // 유선이 살아있음 — 제안. (auto-switch 아님: state 만 바꿈.)
            let offer = State.offerWired(targetHost: Self.wiredTarget)
            if state != offer { state = offer }
        case .refused, .timedOut, .unreachable:
            // 유선 미가용(스위치 토폴로지 포함) — 제안 철회.
            if state != .idle { state = .idle }
        }
    }

    /// 사용자가 배너의 "전환" 을 눌렀을 때 — **주입된** 전환 동작을 발동하고 배너를 닫는다.
    /// 이 타입은 전환 로직(host setter / 모드 스위처)을 보유하지 않는다(소유권 분리).
    public func accept(using switchAction: () -> Void) {
        switchAction()
        state = .idle
    }

    /// 사용자가 배너를 닫음(수락 없이) — idle 로.
    public func dismiss() {
        state = .idle
    }
}

// MARK: - tcpProbe 기본값 adapter
//
// `NetworkProbe.tcpProbe(host:port:)` 는 timeout 기본인자가 있어 `(String, UInt16) async -> Result`
// 클로저 타입과 직접 일치하지 않는다. 명시적 어댑터로 기본 timeout(1.0s)을 고정해 시그니처를 맞춘다.
extension NetworkProbe {
    static func tcpProbe(host: String, port: UInt16) async -> Result {
        await tcpProbe(host: host, port: port, timeout: 1.0)
    }
}
