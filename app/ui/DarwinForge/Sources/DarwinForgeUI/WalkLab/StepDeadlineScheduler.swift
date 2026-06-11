import Foundation

/// 보행 step 케이던스의 deadline 기반 스케줄러 — **J4** (cockpit-latency-hardening §5.6).
///
/// 비유: 매 정시 출발하는 버스. 승객이 늦게 타도(=write·MainActor 홉) 다음 버스는
/// "직전 출발 + 배차간격" 의 절대 시각에 떠난다. 고정 `sleep(stepMs)` 는 "탑승 끝난
/// 시점부터 배차간격" 이라 매번 탑승 시간만큼 누적 지연(드리프트)되지만, deadline
/// 방식은 그 시간을 자동 보상한다.
///
/// 순수 함수라 실시간 sleep 없이 단위 테스트로 정확성을 증명할 수 있다.
enum StepDeadlineScheduler {
    /// 다음 step 발화(=sleep 종료) 목표 시각.
    ///
    /// - Parameters:
    ///   - previous: 직전에 계산된 목표 시각. 첫 step 은 `nil`.
    ///   - now: 현재 시각.
    ///   - stepMs: step 간격 하한(phase floor 80ms 포함된 실효 간격).
    /// - Returns: `max(previous + stepMs, now)`.
    ///   늦었으면(처리가 간격을 초과) 즉시 `now` — **과거 시각으로 보내지 않아** 음수
    ///   sleep·폭주를 막는다. 이르면 정확히 `previous + stepMs` 로 케이던스를 유지한다.
    static func next(
        previous: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        stepMs: Int
    ) -> ContinuousClock.Instant {
        let interval = Duration.milliseconds(max(0, stepMs))
        guard let previous else { return now.advanced(by: interval) }
        let scheduled = previous.advanced(by: interval)
        return scheduled < now ? now : scheduled
    }
}

extension Duration {
    /// 밀리초(소수 포함). 음수 Duration 도 부호 보존.
    var inMilliseconds: Double {
        let c = components
        return Double(c.seconds) * 1_000.0
            + Double(c.attoseconds) / 1_000_000_000_000_000.0
    }
}
