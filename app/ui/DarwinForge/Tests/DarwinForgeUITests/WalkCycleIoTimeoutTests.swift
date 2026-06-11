import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **Wave 2 — io-timeout 보행 상한 wiring (2026-06-11)** 회귀 가드.
///
/// 보행 핫루프(runContinuousWalk/runWalkCycle)가 시작 시 bus read timeout 을
/// `walkIoTimeoutMs` 로 낮추고, 정상/취소/하드스톱 등 *모든* 종료 경로에서 open 시
/// 구성값으로 원복하는지 검증. 락 보유 상한 축소가 보행 종료 후에도 잔존하면 평시
/// connect-time snapshot 견고성이 깨지므로 원복은 안전 불변식.
final class WalkCycleIoTimeoutTests: XCTestCase {

    private var lowerBodyJoints: Set<JointID> {
        Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
    }

    private func minimalStep() -> MotionStep {
        var pos = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        pos[Int(JointID.rHipYaw.rawValue)] = 1024
        pos[Int(JointID.lHipYaw.rawValue)] = 1024
        pos[Int(JointID.rKnee.rawValue)]   = 3072
        return MotionStep(positions: pos, pauseTime: 0, playTime: 1)
    }

    private func singleStepPage() -> MotionPage {
        MotionPage(id: 203, steps: [minimalStep()])
    }

    private func singleStepPlan() -> WalkMotionLibrary.ContinuousWalkPlan {
        let s = minimalStep()
        return WalkMotionLibrary.ContinuousWalkPlan(entry: [s], cycle: [s], exit: [s])
    }

    // MARK: - 시작 시 하향 / 종료 시 원복

    func testRunContinuousWalk_LowersIoTimeoutAtStart_RestoresAtEnd() async {
        let bus = MockBus()
        _ = await WalkLabSession.runContinuousWalk(
            bus: bus, plan: singleStepPlan(), maxDurationSec: 1,
            lowerBodyJoints: lowerBodyJoints)

        XCTAssertEqual(bus.ioTimeoutSettings.first, WalkLabSession.walkIoTimeoutMs,
                       "보행 시작 시 walkIoTimeoutMs 로 하향")
        XCTAssertEqual(bus.ioTimeoutSettings.last, bus.configuredIoTimeoutMs,
                       "보행 종료 시 구성값으로 원복")
        // 정확히 [하향, 원복] 2회 — 중간에 임의 timeout 변경 없음.
        XCTAssertEqual(bus.ioTimeoutSettings, [WalkLabSession.walkIoTimeoutMs, bus.configuredIoTimeoutMs])
    }

    func testRunWalkCycle_LowersIoTimeoutAtStart_RestoresAtEnd() async {
        let bus = MockBus()
        _ = await WalkLabSession.runWalkCycle(
            bus: bus, page: singleStepPage(), maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints, loop: false)

        XCTAssertEqual(bus.ioTimeoutSettings, [WalkLabSession.walkIoTimeoutMs, bus.configuredIoTimeoutMs],
                       "jog cycle 도 [하향, 원복] 2회")
    }

    // MARK: - 비정상 종료에서도 원복 (defer 보장)

    func testIoTimeout_RestoredEvenWhenWalkAbortsOnLivenessFailure() async {
        // 단일 하체 관절 프로브 + 상시 PING 실패 → livenessProbeFailureLimit 연속 실패로
        // 보행이 중단(.lowerBodyWriteFailure)되는 경로. defer 가 보장하므로 마지막 timeout
        // 설정은 여전히 구성값으로 원복돼야 한다.
        let bus = MockBus()
        bus.alwaysFailPing = true
        let result = await WalkLabSession.runContinuousWalk(
            bus: bus, plan: singleStepPlan(), maxDurationSec: 10,
            lowerBodyJoints: [.rKnee])

        XCTAssertEqual(result.reason, .lowerBodyWriteFailure, "테스트 전제 — 보행 중단 경로")
        XCTAssertEqual(bus.ioTimeoutSettings.first, WalkLabSession.walkIoTimeoutMs,
                       "중단 경로도 시작 시 하향")
        XCTAssertEqual(bus.ioTimeoutSettings.last, bus.configuredIoTimeoutMs,
                       "중단 경로에서도 defer 로 원복")
    }

    // MARK: - 하향이 실제 감소인지 (no-op 아님)

    func testWalkIoTimeout_IsStrictReductionFromConfigured() {
        // 설계 불변식: 보행 timeout < 구성 timeout 이어야 락 보유 상한 축소 효과가 있다.
        let bus = MockBus()
        XCTAssertLessThan(WalkLabSession.walkIoTimeoutMs, bus.configuredIoTimeoutMs,
                          "walkIoTimeoutMs 는 구성값보다 작아야 (락 보유 상한 축소)")
    }
}
