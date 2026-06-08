import XCTest
@testable import DarwinForgeUI

/// `SwitchRobotLinkSession` 의 안전 게이트 검증 — 실제 SSH 없이 결정적으로 통과하는
/// 경로(공개키 없음, 안전 미확인)만 검증한다. 네트워크 의존 단계는 통합/수동 테스트 영역.
@MainActor
final class SwitchRobotLinkSessionTests: XCTestCase {

    private func makeSession(
        robotRun: @escaping (String) async -> (ok: Bool, output: String)? = { _ in nil }
    ) -> SwitchRobotLinkSession {
        SwitchRobotLinkSession(
            switchHost: "192.168.0.25", switchUser: "yuseok",
            macRobotHost: "192.168.123.1", macRobotUser: "robotis",
            robotRun: robotRun)
    }

    func testInstallOnRobotFailsWithoutPublicKey() async {
        let session = makeSession()
        let ok = await session.runInstallOnRobot()
        XCTAssertFalse(ok)
        XCTAssertEqual(session.outcome(.installOnRobot).phase, .failed)
        XCTAssertTrue(session.outcome(.installOnRobot).message.contains("공개키"))
    }

    func testStartWalkLabBlockedUntilSafetyConfirmed() async {
        let session = makeSession()
        XCTAssertFalse(session.safetyConfirmed)
        let ok = await session.runStartWalkLab()
        XCTAssertFalse(ok)
        XCTAssertEqual(session.outcome(.startWalkLab).phase, .failed)
        XCTAssertTrue(session.outcome(.startWalkLab).message.contains("안전"))
    }

    func testStepsStartIdle() {
        let session = makeSession()
        for step in SwitchRobotLinkSession.StepID.allCases {
            XCTAssertEqual(session.outcome(step).phase, .idle, "\(step) 초기 idle")
        }
        XCTAssertNil(session.runningStep)
    }

    func testMacRobotHostExposed() {
        let session = makeSession()
        XCTAssertEqual(session.macRobotHost, "192.168.123.1")
    }

    // MARK: - 원클릭 카메라+조종 데모 (2026-06-08)

    func testDemoSuiteOutcomeStartsEmpty() {
        let session = makeSession()
        XCTAssertFalse(session.isRunningDemoSuite)
        XCTAssertEqual(session.demoSuiteOutcome.summary, "")
        XCTAssertNil(session.demoSuiteOutcome.currentStage)
        for stage in SwitchRobotLinkSession.DemoSuiteStage.allCases {
            XCTAssertEqual(session.demoSuiteOutcome.phase(stage), .idle, "\(stage) 초기 idle")
            XCTAssertEqual(session.demoSuiteOutcome.message(stage), "")
        }
        XCTAssertFalse(session.demoSuiteOutcome.allGreen, "초기엔 allGreen=false")
    }

    /// 안전 미확인 + 로봇 채널 미주입(closure 가 nil 반환) 이면 preflight 에서
    /// 즉시 hard-fail — 후속 스테이지(start/agent/tunnel/verify)는 시도조차 하지 않는다.
    func testDemoSuitePreflightFailsFastWithoutSafetyAndRobotChannel() async {
        let session = makeSession()  // robotRun 기본값: 항상 nil(채널 미연결)
        XCTAssertFalse(session.safetyConfirmed)
        let ok = await session.runDemoSuite()
        XCTAssertFalse(ok)
        XCTAssertEqual(session.demoSuiteOutcome.phase(.preflight), .failed,
                       "preflight 단계가 실패로 마감되어야 함")
        for later in [SwitchRobotLinkSession.DemoSuiteStage.startRobotDemo,
                      .enableAgent, .cameraTunnel, .verify] {
            XCTAssertEqual(session.demoSuiteOutcome.phase(later), .idle,
                           "\(later) 는 preflight 실패 시 시도되지 않아야 함")
        }
        let msg = session.demoSuiteOutcome.message(.preflight)
        XCTAssertTrue(msg.contains("안전") || msg.contains("로봇"),
                      "실패 메시지에 안전/로봇 채널 안내가 있어야 함")
        XCTAssertFalse(session.isRunningDemoSuite, "isRunningDemoSuite 는 종료 후 false")
    }

    func testDemoSuiteAllGreenRequiresAllFiveStages() {
        var out = SwitchRobotLinkSession.DemoSuiteOutcome()
        XCTAssertFalse(out.allGreen)
        for stage in SwitchRobotLinkSession.DemoSuiteStage.allCases {
            out.stages[stage] = .success
        }
        XCTAssertTrue(out.allGreen, "5스테이지 모두 success 면 allGreen=true")
        out.stages[.verify] = .failed
        XCTAssertFalse(out.allGreen, "verify 하나라도 빠지면 allGreen=false")
    }

    // MARK: - 조종 모드 선택 (2026-06-08 재설계)

    func testLaunchModeStageCompositions() {
        // 빠른 조종: 카메라 터널 빼고 4단계만
        let quick = SwitchRobotLinkSession.LaunchMode.quickPilot.stages
        XCTAssertEqual(quick, [.preflight, .startRobotDemo, .enableAgent, .verify])
        XCTAssertFalse(quick.contains(.cameraTunnel),
                       "빠른 조종은 카메라 터널 단계가 없어야 함")
        // 카메라+조종: 5단계 전체
        let full = SwitchRobotLinkSession.LaunchMode.cameraAndControl.stages
        XCTAssertEqual(full.count, 5)
        XCTAssertTrue(full.contains(.cameraTunnel))
        // 진단: 모터 단계 일체 없음(preflight + verify만)
        let diag = SwitchRobotLinkSession.LaunchMode.diagnostics.stages
        XCTAssertEqual(diag, [.preflight, .verify])
        XCTAssertFalse(diag.contains(.startRobotDemo),
                       "진단 모드는 demo 부팅을 절대 시도하지 않아야 함")
        XCTAssertFalse(diag.contains(.cameraTunnel))
    }

    func testLaunchModeRiskFlags() {
        // 모터 ON 모드 — 안전 토글 필수
        XCTAssertTrue(SwitchRobotLinkSession.LaunchMode.quickPilot.movesRobot)
        XCTAssertTrue(SwitchRobotLinkSession.LaunchMode.cameraAndControl.movesRobot)
        // 진단 — 모터 OFF, 안전 토글 면제
        XCTAssertFalse(SwitchRobotLinkSession.LaunchMode.diagnostics.movesRobot)
    }

    /// 모터 모드는 안전 토글 없으면 preflight 에서 즉시 hard-fail.
    func testQuickPilotBlockedWithoutSafety() async {
        let session = makeSession()
        XCTAssertFalse(session.safetyConfirmed)
        let ok = await session.runLaunch(.quickPilot)
        XCTAssertFalse(ok)
        XCTAssertEqual(session.demoSuiteOutcome.phase(.preflight), .failed)
        XCTAssertTrue(session.demoSuiteOutcome.message(.preflight).contains("안전"),
                      "안전 토글 누락 메시지 노출")
        // 후속 모터 단계는 절대 시도되지 않음
        XCTAssertEqual(session.demoSuiteOutcome.phase(.startRobotDemo), .idle)
        XCTAssertEqual(session.demoSuiteOutcome.phase(.enableAgent), .idle)
    }

    /// 진단 모드는 안전 토글 없어도 preflight 안전 검사를 통과해야 한다(모터 OFF).
    /// preflight 의 다른 단계(로봇 SSH, Switch, IP)는 mock 환경에서 실패하므로
    /// 정확히 "안전 토글" 메시지가 없는지를 확인.
    func testDiagnosticsDoesNotRequireSafetyToggle() async {
        let session = makeSession()
        XCTAssertFalse(session.safetyConfirmed)
        _ = await session.runLaunch(.diagnostics)
        // mock 환경상 preflight 는 실패하지만, 그 사유에 "안전" 이 포함돼선 안 됨.
        let msg = session.demoSuiteOutcome.message(.preflight)
        XCTAssertFalse(msg.contains("안전"),
                       "진단 모드는 안전 토글을 요구하지 않아야 함 (실제 메시지: \(msg))")
    }

    func testLastLaunchModeRemembered() async {
        let session = makeSession()
        XCTAssertNil(session.lastLaunchMode)
        _ = await session.runLaunch(.diagnostics)
        XCTAssertEqual(session.lastLaunchMode, .diagnostics,
                       "마지막 실행 모드가 UI 강조용으로 기억돼야 함")
        _ = await session.runLaunch(.quickPilot)
        XCTAssertEqual(session.lastLaunchMode, .quickPilot)
    }

    /// `runDemoSuite()` 하위호환 — 카메라+조종 모드로 위임돼야 함.
    func testRunDemoSuiteBackCompatRoutesToCameraAndControl() async {
        let session = makeSession()
        _ = await session.runDemoSuite()
        XCTAssertEqual(session.lastLaunchMode, .cameraAndControl)
    }
}
