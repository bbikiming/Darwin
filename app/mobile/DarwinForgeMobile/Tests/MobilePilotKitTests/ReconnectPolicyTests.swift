import XCTest
@testable import MobilePilotKit

final class ReconnectPolicyTests: XCTestCase {

    private let policy = ReconnectPolicy(baseDelayMs: 300, maxDelayMs: 5_000, multiplier: 2.0)

    // MARK: - Equal jitter bounds

    func test_attempt1_equalJitter_bounds() {
        XCTAssertEqual(policy.delayMs(attempt: 1, randomUnit: 0.0), 150)
        XCTAssertEqual(policy.delayMs(attempt: 1, randomUnit: 1.0), 300)
        XCTAssertEqual(policy.delayMs(attempt: 1, randomUnit: 0.5), 225)
    }

    // MARK: - Exponential growth

    func test_exponentialGrowth_atMaxJitter() {
        XCTAssertEqual(policy.delayMs(attempt: 2, randomUnit: 1.0), 600)
        XCTAssertEqual(policy.delayMs(attempt: 3, randomUnit: 1.0), 1200)
        XCTAssertEqual(policy.delayMs(attempt: 4, randomUnit: 1.0), 2400)
        XCTAssertEqual(policy.delayMs(attempt: 5, randomUnit: 1.0), 4800)
    }

    // MARK: - Cap

    func test_capReached_atMaxJitter() {
        // attempt 6: 300 * 2^5 = 9600 → cap 5000.
        XCTAssertEqual(policy.delayMs(attempt: 6, randomUnit: 1.0), 5000)
        XCTAssertEqual(policy.delayMs(attempt: 100, randomUnit: 1.0), 5000)
    }

    func test_capHalfFloor_atMinJitter() {
        // 큰 attempt + randomUnit 0 → cap/2 = 2500 (최소 바닥).
        XCTAssertEqual(policy.delayMs(attempt: 100, randomUnit: 0.0), 2500)
    }

    func test_delayAlwaysWithinHalfToFullCap() {
        for attempt in 1...50 {
            for r in stride(from: 0.0, through: 1.0, by: 0.1) {
                let d = policy.delayMs(attempt: attempt, randomUnit: r)
                let exp = Double(policy.baseDelayMs) * pow(policy.multiplier, Double(min(attempt - 1, 32)))
                let capped = min(exp, Double(policy.maxDelayMs))
                XCTAssertGreaterThanOrEqual(Double(d), capped / 2.0 - 1)
                XCTAssertLessThanOrEqual(Double(d), capped + 1)
            }
        }
    }

    // MARK: - Input hardening

    func test_randomUnit_isClamped() {
        XCTAssertEqual(policy.delayMs(attempt: 1, randomUnit: -5),
                       policy.delayMs(attempt: 1, randomUnit: 0))
        XCTAssertEqual(policy.delayMs(attempt: 1, randomUnit: 99),
                       policy.delayMs(attempt: 1, randomUnit: 1))
    }

    func test_attemptZeroOrNegative_treatedAsOne() {
        XCTAssertEqual(policy.delayMs(attempt: 0, randomUnit: 1),
                       policy.delayMs(attempt: 1, randomUnit: 1))
        XCTAssertEqual(policy.delayMs(attempt: -3, randomUnit: 1),
                       policy.delayMs(attempt: 1, randomUnit: 1))
    }

    func test_defensiveInit_clampsInvalidParams() {
        let p = ReconnectPolicy(baseDelayMs: -10, maxDelayMs: -5, multiplier: 0.1)
        XCTAssertGreaterThan(p.baseDelayMs, 0)
        XCTAssertGreaterThanOrEqual(p.maxDelayMs, p.baseDelayMs)
        XCTAssertGreaterThanOrEqual(p.multiplier, 1.0)
    }

    func test_standardPolicy_defaults() {
        let p = ReconnectPolicy.standard
        XCTAssertEqual(p.baseDelayMs, 300)
        XCTAssertEqual(p.maxDelayMs, 5_000)
        XCTAssertEqual(p.multiplier, 2.0)
    }
}
