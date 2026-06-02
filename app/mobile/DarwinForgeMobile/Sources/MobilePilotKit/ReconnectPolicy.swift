import Foundation

/// 자동 재연결의 backoff 지연을 계산하는 순수 정책.
///
/// # 비유
///
/// 전화가 통화 중일 때 무작정 0.1초마다 다시 거는 게 아니라, 점점 간격을 늘리되
/// 사람마다 거는 타이밍을 살짝 다르게(jitter) 해서 교환대가 한꺼번에 몰리지 않게 하는 것.
///
/// # 설계
///
/// - **무한 시도**: 상한 없음. 멈춤 조건(사용자 명시 disconnect / 오프라인 / 성공)은
///   호출자(`AppState`)가 판단한다. 로봇 텔레옵에서는 "포그라운드 + 온라인" 동안
///   계속 재연결하는 것이 기대 동작.
/// - **Equal jitter (AWS Architecture Blog 권장)**: `delay = half + rand·half`.
///   full jitter와 달리 최소 `capped/2`를 보장해, 1회차에도 너무 짧지 않게(순간 블립
///   회복용) 하면서도 thundering herd를 방지한다.
/// - **순수 함수**: 난수를 `randomUnit`(0...1)으로 주입받아 결정론적 단위 테스트 가능.
///
/// # 지연 곡선 (기본값, randomUnit=1.0 기준 최대치)
///
/// | attempt | capped(ms) | delay 범위(ms) |
/// |--------:|-----------:|----------------|
/// | 1       | 300        | 150 – 300      |
/// | 2       | 600        | 300 – 600      |
/// | 3       | 1200       | 600 – 1200     |
/// | 4       | 2400       | 1200 – 2400    |
/// | 5       | 4800 → 5000 cap | 2500 – 5000 |
/// | 6+      | 5000 cap   | 2500 – 5000    |
public struct ReconnectPolicy: Sendable, Equatable {

    /// 1회차 기준 지연(ms).
    public let baseDelayMs: Int
    /// 지연 상한(ms). 이 값 이상으로는 늘어나지 않는다.
    public let maxDelayMs: Int
    /// 회차마다 곱해지는 배수.
    public let multiplier: Double

    public init(baseDelayMs: Int = 300,
                maxDelayMs: Int = 5_000,
                multiplier: Double = 2.0) {
        // 방어적 클램프 — 음수/0 입력이 와도 안전한 양수 보장.
        self.baseDelayMs = max(1, baseDelayMs)
        self.maxDelayMs = max(max(1, baseDelayMs), maxDelayMs)
        self.multiplier = max(1.0, multiplier)
    }

    /// `attempt`(1부터)에 대한 backoff 지연(ms).
    ///
    /// - Parameters:
    ///   - attempt: 1 이상. 0 이하가 들어오면 1로 취급.
    ///   - randomUnit: 0...1 사이 난수. 호출자가 `Double.random(in: 0...1)` 주입.
    ///     테스트는 0/0.5/1 등 고정값으로 경계 검증.
    /// - Returns: equal-jitter 적용 지연(ms). 항상 `[capped/2, capped]` 범위.
    public func delayMs(attempt: Int, randomUnit: Double) -> Int {
        let safeAttempt = max(1, attempt)
        // pow overflow 방지: 지수를 32로 클램프(2^32 × 300ms는 이미 cap을 한참 초과).
        let exponent = Double(min(safeAttempt - 1, 32))
        let rawMs = Double(baseDelayMs) * pow(multiplier, exponent)
        let cappedMs = min(rawMs, Double(maxDelayMs))
        let half = cappedMs / 2.0
        let clampedRandom = min(max(randomUnit, 0.0), 1.0)
        let delay = half + clampedRandom * half
        return Int(delay.rounded())
    }

    /// 편의: 시스템 난수로 지연 계산.
    public func delayMs(attempt: Int) -> Int {
        delayMs(attempt: attempt, randomUnit: Double.random(in: 0...1))
    }

    /// 표준 기본 정책.
    public static let standard = ReconnectPolicy()
}
