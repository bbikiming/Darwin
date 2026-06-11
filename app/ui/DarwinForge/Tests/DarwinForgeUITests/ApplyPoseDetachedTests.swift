import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **Wave 2 — L6 applyPoseSmoothly MainActor 탈출 (2026-06-11)** 계약 가드.
///
/// bus read(컨텍스트) + step write 를 Task.detached 로 빼 MainActor 정지를 없애되,
/// (a) write 가 실제 bus 에 도달하고 result 반환 전에 모두 완료(await)되며,
/// (b) per-joint 실패 분기(하체 실패 → .writeFailed)가 detached 경로에서도 보존되는지
/// 검증. 동작 보존이 핵심 — 스레드만 바뀌고 실패 의미는 불변.
@MainActor
final class ApplyPoseDetachedTests: XCTestCase {

    func testApplyPose_DetachedWrites_ReachBusAndCompleteBeforeResult() async {
        let bus = MockBus()
        let store = ConnectionStore()
        store.bus = bus

        let result = await store.applyPoseSmoothly(.center, profile: .smooth)

        // detached write 가 await 됐으므로 result 시점에 write 가 이미 기록돼 있어야 한다.
        XCTAssertFalse(bus.positionWrites.isEmpty,
                       "detached write 가 result 반환 전에 완료 — bus 에 position write 도달")
        if case .completed = result {
            // 모든 write 성공 → completed (정상 경로).
        } else {
            XCTFail("MockBus 전체 성공 → .completed 기대, 실제: \(result)")
        }
    }

    func testApplyPose_DetachedLowerBodyFailure_StillWriteFailed() async {
        // 하체 관절 실패가 detached write 결과 집계를 거쳐도 .writeFailed (balance hard-fail).
        let bus = SingleJointFailMockBus(failJoint: .lKnee)
        let store = ConnectionStore()
        store.bus = bus

        let result = await store.applyPoseSmoothly(.center, profile: .smooth)

        guard case .writeFailed = result else {
            XCTFail("하체(lKnee) 실패 → .writeFailed 기대, 실제: \(result)")
            return
        }
    }
}
