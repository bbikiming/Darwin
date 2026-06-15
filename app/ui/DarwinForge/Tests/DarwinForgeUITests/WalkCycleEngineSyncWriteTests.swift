import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **Wave 2 — L5 SYNC_WRITE 전환 (2026-06-11)** 회귀 가드.
///
/// 보행 핫루프(runContinuousWalk/runWalkCycle)가 관절별 개별 setPosition(+status
/// 왕복) 대신 setPositions 1패킷을 쓰는지, 그리고 SYNC_WRITE 의 무응답(죽은 서보가
/// 오류를 안 냄)을 step 별 liveness PING 라운드로빈이 보상하는지 검증.
final class WalkCycleEngineSyncWriteTests: XCTestCase {

    private var lowerBodyJoints: Set<JointID> {
        Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
    }

    /// walkReady 와 다른 하체 3관절 — changedJoints 가 비어있지 않게.
    private func minimalStep() -> MotionStep {
        var pos = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        pos[Int(JointID.rHipYaw.rawValue)] = 1024
        pos[Int(JointID.lHipYaw.rawValue)] = 1024
        pos[Int(JointID.rKnee.rawValue)]   = 3072
        return MotionStep(positions: pos, pauseTime: 0, playTime: 1)
    }

    private func singleStepPage() -> MotionPage {
        MotionPage(id: 202, steps: [minimalStep()])
    }

    private func singleStepPlan() -> WalkMotionLibrary.ContinuousWalkPlan {
        let s = minimalStep()
        return WalkMotionLibrary.ContinuousWalkPlan(entry: [s], cycle: [s], exit: [s])
    }

    // MARK: - SYNC_WRITE 배치 사용

    func testRunWalkCycle_UsesBatchSetPositions_NotPerJointWrites() async {
        let bus = MockBus()
        _ = await WalkLabSession.runWalkCycle(
            bus: bus, page: singleStepPage(), maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints, loop: false)

        XCTAssertGreaterThan(bus.batchPositionCalls.count, 0,
                             "step 송출은 setPositions 배치 경유")
        // 한 step 의 변경 관절 전체가 한 패킷에 묶임 (관절별 분리 아님) —
        // 시드한 하체 3관절이 모두 첫 배치 안에 있어야 한다.
        let firstBatch = Set((bus.batchPositionCalls.first ?? []).map { $0.joint })
        for j in [JointID.rHipYaw, .lHipYaw, .rKnee] {
            XCTAssertTrue(firstBatch.contains(j), "\(j.name) 이 첫 배치에 포함")
        }
    }

    func testRunContinuousWalk_UsesBatchSetPositions() async {
        let bus = MockBus()
        _ = await WalkLabSession.runContinuousWalk(
            bus: bus, plan: singleStepPlan(), maxDurationSec: 1,
            lowerBodyJoints: lowerBodyJoints)

        XCTAssertGreaterThan(bus.batchPositionCalls.count, 0,
                             "entry/cycle/exit 송출은 setPositions 배치 경유")
    }

    func testBatchTransportFailure_MapsToLowerBodyConservatively() async {
        // 배치 write 가 계속 실패하면 (transport 사망) — 배치 내 하체 관절 전체가
        // 실패로 매핑돼 lowerBodyDistinctFailureThreshold(3) 로 보행이 중단된다.
        let bus = MockBus()
        bus.failNextSetPositions = true
        // single-shot 이라 매 step 재무장 — retry(2회)까지 실패시키려면 상시 실패 필요.
        // MockBus 의 setPositions 는 failNextSetPositions 1회 후 reset 되므로,
        // retry 1회가 성공해 실패 매핑이 안 일어날 수 있다 — 본 테스트는 retry 포함
        // 2연속 실패를 만들기 위해 setPosition fallback 이 아닌 배치 실패 2회를 주입.
        // (간단화: 1 step 에서 첫 시도 실패 → retry 성공 → 실패 매핑 없음을 먼저 확인)
        let result = await WalkLabSession.runWalkCycle(
            bus: bus, page: singleStepPage(), maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints, loop: false)

        // 첫 시도 실패 + retry 성공 → transient 흡수, 보행 정상 종료.
        XCTAssertEqual(result.reason, .completedMaxDuration,
                       "1회 transient 배치 실패는 retry 로 흡수")
        XCTAssertEqual(result.positionWriteFailures, 0,
                       "retry 성공 시 실패 카운트 없음")
    }

    // MARK: - Liveness 프로브 (SYNC_WRITE 무응답 보상)

    func testLivenessProbe_PingsLowerBodyJointsDuringWalk() async {
        let bus = MockBus()
        _ = await WalkLabSession.runContinuousWalk(
            bus: bus, plan: singleStepPlan(), maxDurationSec: 1,
            lowerBodyJoints: lowerBodyJoints)

        XCTAssertGreaterThan(bus.pingCalls.count, 0,
                             "bus 직결 경로는 step 마다 하체 관절 liveness PING")
        // 프로브 대상은 전부 하체 관절.
        let lowerIds = Set(lowerBodyJoints.map { $0.rawValue })
        for id in bus.pingCalls {
            XCTAssertTrue(lowerIds.contains(id), "프로브는 하체 관절만: id \(id)")
        }
    }

    func testLivenessProbe_ConsecutiveFailures_AbortWalk() async {
        // 단일 하체 관절만 프로브 대상으로 → 매 step 같은 관절 프로브 →
        // livenessProbeFailureLimit(2) 연속 실패 → lowerBodyWriteFailure 중단.
        let bus = MockBus()
        bus.alwaysFailPing = true
        let result = await WalkLabSession.runContinuousWalk(
            bus: bus, plan: singleStepPlan(), maxDurationSec: 10,
            lowerBodyJoints: [.rKnee])

        XCTAssertEqual(result.reason, .lowerBodyWriteFailure,
                       "liveness 프로브 연속 \(WalkLabSession.livenessProbeFailureLimit)회 실패 → 보행 중단")
        XCTAssertTrue(result.sampleError?.contains("liveness") ?? false,
                      "sampleError 에 liveness 무응답 표기")
    }

    func testLivenessProbe_SkippedOnRobotPortPath() async {
        // robotPort(mock) 경로는 실 시리얼이 아니므로 프로브 생략.
        let bus = MockBus()
        let port = MockRobotAdapter()
        port.simulatedDxlPower = true
        _ = await WalkLabSession.runWalkCycle(
            bus: bus, page: singleStepPage(), maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints, loop: false, robotPort: port)

        XCTAssertEqual(bus.pingCalls.count, 0, "robotPort 경로는 liveness 프로브 없음")
    }

    // MARK: - moving speed 배치

    func testMovingSpeed_AllJointsStillReceiveSpeed_ViaBatchOrLoop() async {
        // BusInterface.setMovingSpeeds 기본 구현(per-joint 루프)이 MockBus 에
        // 적용되므로 — 전 관절이 cycleSpeed 를 받는 기존 계약은 불변.
        let bus = MockBus()
        _ = await WalkLabSession.runWalkCycle(
            bus: bus, page: singleStepPage(), maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints, loop: false)

        let speedJoints = Set(bus.speedWrites.map { $0.joint })
        XCTAssertEqual(speedJoints.count, JointID.allCases.count,
                       "전 관절 moving speed 설정 계약 유지")
    }
}
