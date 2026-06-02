import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **V288-2 (2026-05-24) — RobotPort migration TDD**.
///
/// # 비유
///
/// 전기 콘센트 검사관. 모든 전자기기가 직접 발전소 배선에 닿는 대신
/// 표준 콘센트 (RobotPort) 를 경유해야 안전 차단기 (dxlPower gate) 를 통과하는지
/// 검증. bus.setPosition 직접 접촉 = 감전 위험.
///
/// # 검증 대상
///
/// `WalkLabSession+WalkCycleEngine.swift` 의 `runContinuousWalk` /
/// `runWalkCycle` — `robotPort` 파라미터 경유 시:
///   - `MockRobotAdapter.writeCount` 증가 (robotPort 경유 확인)
///   - `simulatedDxlPower=false` 시 e-stop 카운트 증가
///   - `simulatedDxlPower=false` 시 result.positionWriteFailures 증가 (gate 차단 기록)
///
/// # TDD 순서
///
/// RED → (V288-2 구현) → GREEN
final class WalkLabSessionWalkCycleEngineRobotPortMigrationTests: XCTestCase {

    // MARK: - Helpers

    private var lowerBodyJoints: Set<JointID> {
        Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
    }

    /// 최소 duration step — playTime=1 (8ms), pauseTime=0.
    ///
    /// **주의 (sibling `WalkLabSessionWalkCycleEngineTests` 참고)**: `.walkReady` 자세는
    /// `previous == .walkReady` 와 동일 → `changedJoints` 가 빈 배열 → write 미발생.
    /// 마치 콘센트를 옮기지 않으면 검사관이 통과 여부를 확인할 수 없는 것과 같다.
    /// robotPort 경유 write 를 검증하려면 walkReady 와 다른 하체 관절 값이 필요하다.
    /// (rHipYaw/lHipYaw/rKnee 3개 → lowerBodyDistinctFailureThreshold 도 확정 충족)
    private func minimalStep() -> MotionStep {
        var pos = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        pos[Int(JointID.rHipYaw.rawValue)] = 1024
        pos[Int(JointID.lHipYaw.rawValue)] = 1024
        pos[Int(JointID.rKnee.rawValue)]   = 3072
        return MotionStep(positions: pos, pauseTime: 0, playTime: 1)
    }

    private func singleStepPage() -> MotionPage {
        MotionPage(id: 201, steps: [minimalStep()])
    }

    private func singleStepPlan() -> WalkMotionLibrary.ContinuousWalkPlan {
        let s = minimalStep()
        return WalkMotionLibrary.ContinuousWalkPlan(entry: [s], cycle: [s], exit: [s])
    }

    // MARK: - runWalkCycle: robotPort 경유 write 확인

    /// dxlPower ON 상태에서 robotPort.writeJointPosition 이 호출된다.
    ///
    /// "robotPort 파라미터를 넘기면, bus.setPosition 대신 port 의 write 가 기록된다."
    func testRunWalkCycle_WithRobotPort_WritesViaPort() async {
        let bus = MockBus()
        let port = MockRobotAdapter()
        port.simulatedDxlPower = true
        let page = singleStepPage()

        _ = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false,
            robotPort: port
        )

        XCTAssertGreaterThan(port.writeCount, 0,
            "robotPort.writeJointPosition 이 최소 1회 이상 호출돼야 함")
    }

    /// dxlPower OFF 시 writeJointPosition throw → positionWriteFailures 증가.
    ///
    /// "전원이 꺼진 상태에서 joint write 를 시도하면 실패로 기록되고 e-stop 이 호출된다."
    func testRunWalkCycle_DxlPowerOff_RecordsFailureAndCallsEmergencyStop() async {
        let bus = MockBus()
        let port = MockRobotAdapter()
        port.simulatedDxlPower = false   // gate 차단
        let page = singleStepPage()

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false,
            robotPort: port
        )

        XCTAssertGreaterThan(result.positionWriteFailures, 0,
            "dxlPower OFF 시 positionWriteFailures 가 증가해야 함")
        XCTAssertGreaterThan(port.emergencyStopCount, 0,
            "dxlPower OFF throw → emergencyStop 체인 호출돼야 함")
    }

    // MARK: - runContinuousWalk: robotPort 경유 write 확인

    /// dxlPower ON 상태에서 robotPort.writeJointPosition 이 호출된다.
    func testRunContinuousWalk_WithRobotPort_WritesViaPort() async {
        let bus = MockBus()
        let port = MockRobotAdapter()
        port.simulatedDxlPower = true
        let plan = singleStepPlan()

        // maxDurationSec: 0 은 "취소될 때까지 무한 반복" (freeform 경로 의도).
        // 테스트는 1초 시간 제한으로 cycleLoop 를 종료시킨다 (production semantics 불변).
        _ = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 1,
            lowerBodyJoints: lowerBodyJoints,
            robotPort: port
        )

        XCTAssertGreaterThan(port.writeCount, 0,
            "runContinuousWalk: robotPort.writeJointPosition 최소 1회 이상 호출")
    }

    /// dxlPower OFF 시 positionWriteFailures 증가 + emergencyStop 호출.
    func testRunContinuousWalk_DxlPowerOff_RecordsFailureAndCallsEmergencyStop() async {
        let bus = MockBus()
        let port = MockRobotAdapter()
        port.simulatedDxlPower = false
        let plan = singleStepPlan()

        // maxDurationSec: 1 시간 제한 — dxlPower OFF 시 하체 write 실패가
        // lowerBodyWriteFailure 로 조기 종료되지만, 안전망으로 시간 제한도 둔다.
        let result = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 1,
            lowerBodyJoints: lowerBodyJoints,
            robotPort: port
        )

        XCTAssertGreaterThan(result.positionWriteFailures, 0,
            "runContinuousWalk: dxlPower OFF → positionWriteFailures 증가")
        XCTAssertGreaterThan(port.emergencyStopCount, 0,
            "runContinuousWalk: dxlPower OFF → emergencyStop 체인 호출")
    }
}
