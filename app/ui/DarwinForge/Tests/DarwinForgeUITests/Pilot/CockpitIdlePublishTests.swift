import XCTest
import Combine
@testable import DarwinForgeUI

/// **Wave 3 — J1 @Published 변화-가드 (2026-06-11)** 회귀 가드.
///
/// 유휴(스틱 중립·로봇 정지) 상태에서 integrate() 가 @Published 를 무조건 재대입하지
/// 않아 1698줄 뷰트리의 30Hz 재렌더가 멈추는지 검증. 종전 peakHoldUntil 미리셋 버그로
/// peak 가 0 도달 후에도 매 틱 발행되던 회귀도 함께 가드.
@MainActor
final class CockpitIdlePublishTests: XCTestCase {

    /// 틱 사이 dt>0 보장용 짧은 sleep.
    private func tick(_ s: CockpitState, times: Int) async {
        for _ in 0..<times {
            s._testIntegrateTick()
            try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
        }
    }

    func testIdle_NoObjectWillChangePublished() async {
        let s = CockpitState()
        // 입력 없음(중립) — 유휴. 충분히 틱을 돌려 모든 값이 상수로 수렴시킨다.
        await tick(s, times: 8)

        // 이제 수렴 상태 — 추가 틱은 어떤 @Published 도 바꾸지 않아야 한다.
        var emissions = 0
        let cancellable = s.objectWillChange.sink { _ in emissions += 1 }
        await tick(s, times: 5)
        cancellable.cancel()

        XCTAssertEqual(emissions, 0,
                       "유휴 수렴 후 integrate() 틱은 @Published 발행 0 (30Hz 재렌더 중단)")
    }
}
