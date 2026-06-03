import Foundation
import SwiftUI

/// SSH 온보드 경로에서 로봇의 `/tmp/df-walklab-telemetry`를 주기적으로 읽어
/// 최신 `OnboardTelemetry`와 staleness를 노출하는 폴러.
///
/// 비유: 로봇이 우편함(`/tmp/df-walklab-telemetry`)에 0.2초마다 새 엽서를 넣는다.
/// 이 폴러는 0.2초마다 우편함을 열어 가장 최근 엽서 한 장을 꺼내 읽는다. 엽서가
/// 1.5초 넘게 갱신 안 되면(`isStale`) "지연" 상태로 본다 — UI가 LAN의 stale-green을
/// 보여주지 않도록.
///
/// 수명주기(lifecycle)는 W3(`ConnectionStore`)가 소유한다: 온보드 엔진 + brokering이
/// 켜질 때 `start`, 끊기거나 disable/e-stop disarm 시 `stop`. 이 폴러 자체는 SSH 채널
/// (`RemoteShell`)만 안다.
@MainActor
public final class OnboardTelemetryPoller: ObservableObject {

    /// 가장 최근에 성공적으로 파싱된 샘플. 아직 없으면 nil.
    @Published public private(set) var latest: OnboardTelemetry?

    /// 마지막으로 robot ts_ms 가 **전진한** 시각. staleness 판정 기준.
    /// (SSH cat 성공 시각이 아님 — frozen demo 가 같은 파일을 반복 cat 돼도 갱신 안 됨.)
    @Published public private(set) var lastReceivedAt: Date?

    /// 연속 실패(빈 응답/파싱 실패/에러) 횟수. 성공 시 0으로 리셋.
    @Published public private(set) var consecutiveFailures: Int = 0

    // MARK: - Config

    private let remoteShell: RemoteShell
    private let intervalMs: Int
    /// 로봇에서 텔레메트리 한 줄을 읽는 SSH 명령.
    /// 기본값은 contract §D.4 `RobotSetupCommand.walkLabReadTelemetry`와 동일한 문자열.
    /// (W3가 그 심볼을 선언하기 전에도 본 워크스트림이 독립적으로 컴파일되도록 문자열을
    /// 주입 가능하게 둠 — 통합 시 W3가 동일 상수를 넘긴다.)
    private let pollCommand: String

    /// 신선도 임계값(초). 이보다 오래된 샘플은 stale.
    private let staleThreshold: TimeInterval = 1.5

    // MARK: - State

    private var pollTask: Task<Void, Never>?
    private var onSample: (@MainActor (OnboardTelemetry) -> Void)?
    /// 마지막으로 freshness anchor 를 갱신한 robot ts_ms — frozen demo 감지용.
    /// 종전: 매 cat 성공마다 anchor 갱신 → 죽은 demo 의 같은 파일을 반복 cat 해도 "라이브"
    /// 거짓 표시. ts_ms 가 전진했을 때만 anchor 를 옮겨 frozen 을 stale 로 판정.
    private var lastFreshTsMs: Int64?

    // 기본 200ms(5Hz): 로봇이 §A.1 에서 200ms 주기로 telemetry 를 쓰므로 그에 정합.
    // 종전 500ms 는 5Hz 송신을 2Hz 로 언더샘플 → 최대 ~500ms 묵은 값. 유선(123.1, ~1ms RTT)
    // 에서 폴-대기 지연 절반↓. 무선 경로면 RTT 가 자연 스로틀이라 과폴링 위험 없음.
    public init(remoteShell: RemoteShell,
                intervalMs: Int = 200,
                pollCommand: String = "cat /tmp/df-walklab-telemetry 2>/dev/null") {
        self.remoteShell = remoteShell
        self.intervalMs = max(50, intervalMs)
        self.pollCommand = pollCommand
    }

    // MARK: - Lifecycle

    /// 폴링 시작. 매 interval 마다 SSH로 텔레메트리 줄을 읽어 파싱하고, 성공 시
    /// `latest`/`lastReceivedAt`를 publish 하고 `onSample`을 호출한다.
    /// Idempotent — 이미 실행 중이면 no-op (두 번 호출해도 콜백 갱신만).
    public func start(onSample: @escaping @MainActor (OnboardTelemetry) -> Void) {
        self.onSample = onSample
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 폴링 중지. 진행 중인 loop를 취소한다. published 값은 보존(마지막 상태 유지).
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        onSample = nil
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Staleness

    /// 마지막 신선한 샘플이 `staleThreshold`(기본 1.5초)보다 오래됐으면 true.
    /// 한 번도 못 받았으면(`lastReceivedAt == nil`) stale로 본다.
    public var isStale: Bool {
        isStale(now: Date())
    }

    /// 테스트 주입용 — 주어진 기준 시각으로 staleness 판정.
    public func isStale(now: Date) -> Bool {
        guard let last = lastReceivedAt else { return true }
        return now.timeIntervalSince(last) > staleThreshold
    }

    // MARK: - Loop

    private func runLoop() async {
        let nanos = UInt64(intervalMs) * 1_000_000
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: nanos)
        }
    }

    /// 한 번 폴링 — SSH 읽기 → 파싱 → publish. 실패는 조용히 카운트만 올린다.
    /// (테스트에서 단일 사이클을 검증할 수 있게 internal 노출.)
    func pollOnce() async {
        // codex MEDIUM fix: 텔레메트리 read 도 짧은 타임아웃(4s) — WiFi stall 시 폴 subprocess 가
        // 30s 동안 매달려 ControlMaster lifecycle/리소스를 점유하는 것을 방지(5Hz 폴이라 누적 위험).
        let exchange = await remoteShell.send(pollCommand, timeoutSeconds: 4)
        guard let line = exchange?.result,
              let sample = OnboardTelemetry.parse(line) else {
            consecutiveFailures += 1
            return
        }
        applySample(sample, at: Date())
        onSample?(sample)
    }

    /// 파싱된 샘플 1개를 상태에 반영 (SSH 분리 — 테스트 주입 가능).
    /// **false-positive fix (2026-06-02)**: SSH cat 성공이 아니라 robot ts_ms 가 전진했을
    /// 때만 freshness anchor(`lastReceivedAt`)를 옮긴다. demo 가 죽어 같은 파일이 남아도
    /// ts_ms 가 고정 → threshold 후 isStale=true → UI 가 "지연"으로 강등(라이브 거짓 제거).
    func applySample(_ sample: OnboardTelemetry, at now: Date) {
        consecutiveFailures = 0
        latest = sample   // 최신 값은 항상 노출 (UI 표시는 최신값 사용).
        // **false-positive fix (2026-06-02, codex HIGH)**: 첫 샘플 하나로는 live 확정 X
        // (죽은 demo 가 남긴 파일도 첫 cat 은 성공). ts_ms 가 실제로 **전진**한 걸 본 뒤에만
        // freshness anchor(lastReceivedAt)를 set → frozen-from-start 는 절대 live 가 안 됨.
        if let last = lastFreshTsMs {
            if sample.tsMs != last {          // ts 전진 확인 → live.
                lastFreshTsMs = sample.tsMs
                lastReceivedAt = now
            }
            // 같은 ts → frozen, anchor 유지.
        } else {
            lastFreshTsMs = sample.tsMs       // 첫 샘플 — 기준점만, 아직 live 아님.
        }
    }
}
