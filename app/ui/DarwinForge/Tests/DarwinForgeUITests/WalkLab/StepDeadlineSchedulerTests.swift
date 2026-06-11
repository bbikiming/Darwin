import XCTest
@testable import DarwinForgeUI

/// **J4 (bus D0)** — deadline 기반 step 케이던스 정확성.
///
/// 실시간 sleep 없이 순수 함수로 드리프트 제거를 증명한다.
final class StepDeadlineSchedulerTests: XCTestCase {
    private let base = ContinuousClock.now

    func testFirstStep_schedulesNowPlusStep() {
        let target = StepDeadlineScheduler.next(previous: nil, now: base, stepMs: 80)
        XCTAssertEqual(base.duration(to: target).inMilliseconds, 80, accuracy: 0.001)
    }

    func testOnTime_keepsExactCadence() {
        // now == previous → 다음은 정확히 previous + step (드리프트 0).
        let previous = base
        let target = StepDeadlineScheduler.next(previous: previous, now: base, stepMs: 80)
        XCTAssertEqual(previous.duration(to: target).inMilliseconds, 80, accuracy: 0.001)
    }

    func testWriteOverran_clampsToNowNoPast() {
        // 처리가 간격을 초과(now = previous + 130ms, step 80) → 과거(previous+80)로
        // 보내지 않고 즉시 now 반환(음수 sleep·폭주 방지).
        let previous = base
        let now = base.advanced(by: .milliseconds(130))
        let target = StepDeadlineScheduler.next(previous: previous, now: now, stepMs: 80)
        XCTAssertEqual(now.duration(to: target).inMilliseconds, 0, accuracy: 0.001)
    }

    func testEarlyWake_compensatesWriteTime() {
        // step 처리에 30ms 걸려 now = previous + 30. 고정 sleep 이면 다음 발화가
        // now+80 = previous+110 로 밀리지만, deadline 은 previous+80 을 유지.
        let previous = base
        let now = base.advanced(by: .milliseconds(30))
        let target = StepDeadlineScheduler.next(previous: previous, now: now, stepMs: 80)
        XCTAssertEqual(previous.duration(to: target).inMilliseconds, 80, accuracy: 0.001)
        XCTAssertEqual(now.duration(to: target).inMilliseconds, 50, accuracy: 0.001)
    }

    func testNoDriftAcrossManySteps() {
        // 매 step 처리가 25ms 걸려도 N step 후 누적 드리프트가 없어야 한다.
        var deadline: ContinuousClock.Instant? = nil
        var now = base
        for _ in 0..<50 {
            let target = StepDeadlineScheduler.next(previous: deadline, now: now, stepMs: 80)
            deadline = target
            // 다음 루프의 now = 이번 wake(target) + 25ms 처리.
            now = target.advanced(by: .milliseconds(25))
        }
        // 50 step × 80ms = 4000ms. 처리시간 보상 덕에 정확히 일치(±오차 없음).
        XCTAssertEqual(base.duration(to: deadline!).inMilliseconds, 4000, accuracy: 0.001)
    }

    func testNegativeStepMsClampedToZero() {
        let target = StepDeadlineScheduler.next(previous: nil, now: base, stepMs: -10)
        XCTAssertEqual(base.duration(to: target).inMilliseconds, 0, accuracy: 0.001)
    }

    func testDurationInMillisecondsSignPreserved() {
        XCTAssertEqual(Duration.milliseconds(-12).inMilliseconds, -12, accuracy: 0.001)
        XCTAssertEqual(Duration.microseconds(1500).inMilliseconds, 1.5, accuracy: 0.001)
    }
}
