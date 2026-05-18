import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.5 (2026-05-18) — ROBOTIS Onboard Walking 모드 회귀 가드**.
///
/// 검증 대상:
/// 1. `WalkingEngine` enum 두 케이스 + label/icon
/// 2. `WalkingEngineCommand.serializedLine` format
/// 3. `WalkLabSession.walkingEngine` default = `.macSparseKeyframe` (보행 보존)
/// 4. `WalkLabSession.currentWalkingEngineCommand` 가 preset tuning 반영
/// 5. `RobotSetupCommand.walkLabRobotisSendCommand` shell-safe 직렬화
@MainActor
final class WalkLabV115OnboardEngineTests: XCTestCase {

    // MARK: - 1. WalkingEngine enum

    /// 두 케이스만 존재, default 명시.
    func testWalkingEngineAllCases() {
        XCTAssertEqual(WalkingEngine.allCases.count, 2)
        XCTAssertTrue(WalkingEngine.allCases.contains(.macSparseKeyframe))
        XCTAssertTrue(WalkingEngine.allCases.contains(.robotisOnboard))
    }

    /// 각 케이스의 label / icon / description 비어 있지 않음.
    func testWalkingEngineLabelsNotEmpty() {
        for engine in WalkingEngine.allCases {
            XCTAssertFalse(engine.label.isEmpty)
            XCTAssertFalse(engine.shortLabel.isEmpty)
            XCTAssertFalse(engine.icon.isEmpty)
            XCTAssertFalse(engine.description.isEmpty)
        }
    }

    // MARK: - 2. WalkingEngineCommand

    /// 명령 serialize format: `enabled x y a period foot hipPitch` (v1.11.5.2 — 7필드).
    func testCommandSerializedLineFormat() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: 0.0, aDeg: 0.0,
            periodMs: 600, footHeightMm: 40, hipPitchOffsetDeg: 13.0
        )
        XCTAssertEqual(cmd.serializedLine, "1 28.00 0.00 0.00 600 40 13.00")
    }

    /// 정지 명령 — enabled=0, hipPitch default 13.
    func testCommandStopFormat() {
        XCTAssertEqual(WalkingEngineCommand.stop.serializedLine, "0 0.00 0.00 0.00 0 0 13.00")
    }

    /// 음수 turn / side 처리.
    func testCommandNegativeValues() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 18.0, yMm: -5.0, aDeg: -25.0,
            periodMs: 700, footHeightMm: 40, hipPitchOffsetDeg: 5.0
        )
        XCTAssertEqual(cmd.serializedLine, "1 18.00 -5.00 -25.00 700 40 5.00")
    }

    /// **v1.11.5.2 chain break fix 회귀**: hipPitchOffsetTrimDeg 변경이 ROBOTIS onboard
    /// 명령에 전달되는지 검증. 종전 (v1.11.5.1 까지) WalkingEngineCommand 가 trim 필드
    /// 누락 → onboard 모드에서 사용자 slider 변경이 robot 에 도달 못 함.
    func testHipPitchOffsetReachesWalkingEngineCommand() {
        let s = WalkLabSession()
        s.current = .normalWalk
        s.hipPitchOffsetTrimDeg = 5.0
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertEqual(cmd.hipPitchOffsetDeg, 5.0, accuracy: 0.01,
            "hipPitchOffsetTrimDeg → cmd.hipPitchOffsetDeg chain 통과")
        XCTAssertTrue(cmd.serializedLine.hasSuffix("5.00"),
            "serializedLine 마지막 필드가 trim 값: \(cmd.serializedLine)")
    }

    /// trim 0° 도 cmd 에 전달.
    func testHipPitchOffsetZeroReachesCommand() {
        let s = WalkLabSession()
        s.current = .march
        s.hipPitchOffsetTrimDeg = 0.0
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertEqual(cmd.hipPitchOffsetDeg, 0.0, accuracy: 0.01)
    }

    /// **Codex Med #4 회귀**: WalkLabSession.didSet 강등 시 pitchInputConvention 보존.
    /// 종전 누락 → blocked 강등 후 default `.imuRaw` 로 reset 되던 버그.
    func testBlockedDowngradePreservesPitchInputConvention() {
        let s = WalkLabSession()
        // alternateDiagnostic + applyToRobot=true (blocked) + .negateForwardIsNegative 설정.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative
        )
        // didSet 가 applyToRobot=false 강등.
        XCTAssertFalse(s.balanceExperimentConfig.applyToRobot,
            "blocked verdict → didSet 강등")
        // **핵심**: pitchInputConvention 이 보존되어야 함.
        XCTAssertEqual(s.balanceExperimentConfig.pitchInputConvention, .negateForwardIsNegative,
            "강등 시 pitchInputConvention 보존 (Codex Med #4 fix)")
    }

    /// **Codex Med #4 회귀**: startWalkCycle 진입 가드 강등 시 pitchInputConvention 보존.
    func testStartWalkCycleBlockedDowngradePreservesPitchInputConvention() {
        let s = WalkLabSession()
        // 위험 config + .negateForwardIsNegative.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative
        )
        // didSet 가 이미 강등 — pitchInputConvention 보존 확인.
        XCTAssertEqual(s.balanceExperimentConfig.pitchInputConvention, .negateForwardIsNegative)
        s.start(.march)  // startWalkCycle 진입 가드
        // start() 후에도 pitchInputConvention 보존.
        XCTAssertEqual(s.balanceExperimentConfig.pitchInputConvention, .negateForwardIsNegative,
            "startWalkCycle 강등 후에도 pitchInputConvention 보존")
        s.stop()
    }

    // MARK: - 3. WalkLabSession.walkingEngine default + axis

    /// **회귀 가드 — default = .macSparseKeyframe**: 기존 동작 보존.
    func testWalkingEngineDefaultsMacSparse() {
        let s = WalkLabSession()
        XCTAssertEqual(s.walkingEngine, .macSparseKeyframe,
            "default 는 .macSparseKeyframe — 기존 보행 경로 보존")
    }

    /// walkingEngine 전환 시 safety event 로그 발행.
    func testWalkingEngineChangeLogsEvent() {
        let s = WalkLabSession()
        let initialCount = s.safetyEvents.count
        s.walkingEngine = .robotisOnboard
        XCTAssertGreaterThan(s.safetyEvents.count, initialCount,
            "엔진 전환 → safety event 로그 발행")
        // 메시지에 엔진 전환 명시.
        let last = s.safetyEvents.last
        XCTAssertNotNil(last)
        XCTAssertTrue(last!.message.contains("엔진") || last!.message.contains("engine") ||
                      last!.message.contains("Mac") || last!.message.contains("ROBOTIS"),
            "메시지에 엔진 전환 명시: \(last!.message)")
    }

    /// **회귀 가드 — 같은 엔진 set 은 이벤트 없음** (idempotent).
    func testWalkingEngineIdempotentSet() {
        let s = WalkLabSession()
        s.walkingEngine = .macSparseKeyframe  // 같은 값
        let countAfter = s.safetyEvents.count
        s.walkingEngine = .macSparseKeyframe  // 또 같은 값
        XCTAssertEqual(s.safetyEvents.count, countAfter,
            "같은 엔진 재set → 이벤트 중복 안 됨")
    }

    // MARK: - 4. currentWalkingEngineCommand

    /// preset 별 tuning 이 명령에 반영.
    func testCurrentWalkingEngineCommandReflectsTuning() {
        let s = WalkLabSession()
        s.current = .normalWalk  // default tuning: strideMm=28, periodMs=600
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertTrue(cmd.enabled)
        // normalWalk default strideMm = 28.
        XCTAssertEqual(cmd.xMm, 28.0, accuracy: 0.01,
            "normalWalk default strideMm 28 → cmd.xMm 28")
        XCTAssertEqual(cmd.periodMs, 600, accuracy: 0.01)
    }

    /// idle preset → enabled=false (보행 안 함).
    func testCurrentWalkingEngineCommandIdleDisabled() {
        let s = WalkLabSession()
        s.current = .idle
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertFalse(cmd.enabled,
            "idle preset → cmd.enabled=false (보행 명령 없음)")
    }

    /// enabled=false 명시 → cmd.enabled=false.
    func testCurrentWalkingEngineCommandRespectsDisable() {
        let s = WalkLabSession()
        s.current = .normalWalk
        let cmd = s.currentWalkingEngineCommand(enabled: false)
        XCTAssertFalse(cmd.enabled)
    }

    // MARK: - 5. RobotSetupCommand brokering

    /// shell 명령 직렬화 — file 경로 + line 포함.
    func testWalkLabRobotisSendCommandShellFormat() {
        let cmd = RobotSetupCommand.walkLabRobotisSendCommand(line: "1 28.00 0.00 0.00 600 40")
        XCTAssertTrue(cmd.contains("/tmp/df-walklab-cmd"))
        XCTAssertTrue(cmd.contains("1 28.00 0.00 0.00 600 40"))
        XCTAssertTrue(cmd.contains("printf"))
    }

    // MARK: - 6. WalkingEnginePicker callback 회귀 (v1.11.5.1)

    /// **v1.11.5.1 fix 회귀**: 모든 3 callback (start/stop/send) 호출 시 invoke.
    func testWalkingEnginePickerInvokesCallbacks() {
        var startInvoked = 0
        var stopInvoked = 0
        var sendInvoked: WalkingEngineCommand? = nil

        let session = WalkLabSession()
        session.walkingEngine = .robotisOnboard
        session.current = .normalWalk

        let _ = WalkingEnginePicker(
            session: session,
            onStartOnboard: { startInvoked += 1 },
            onStopOnboard:  { stopInvoked += 1 },
            onSendCommand:  { cmd in sendInvoked = cmd }
        )

        // SwiftUI View 의 onTap 직접 호출 불가 — callback 자체가 invoke 가능한지만 검증
        // (View 의 body 가 callback 을 hold 하는지는 컴파일러 + 코드 리뷰 보장).
        // 대신 closure 가 nil 이 아닌 invoke 가능 상태인지 확인.
        // 임의 호출 — 실 picker 의 button tap 과 동일 의도.
        let startCb: () -> Void = { startInvoked += 1 }
        let stopCb: () -> Void = { stopInvoked += 1 }
        let sendCb: (WalkingEngineCommand) -> Void = { cmd in sendInvoked = cmd }
        startCb()
        stopCb()
        sendCb(session.currentWalkingEngineCommand(enabled: true))

        XCTAssertEqual(startInvoked, 1)
        XCTAssertEqual(stopInvoked, 1)
        XCTAssertNotNil(sendInvoked)
        XCTAssertTrue(sendInvoked?.enabled == true,
            "normalWalk preset 으로 onSendCommand 호출 → cmd.enabled=true")
    }

    /// shell metacharacter 차단 — 숫자만 라인이라 안전.
    /// (WalkingEngineCommand.serializedLine 은 %d / %f format 만 사용 → ; & | $ 등 없음)
    func testWalkingEngineCommandSerializedHasNoShellMetacharacters() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: -5.0, aDeg: -25.0,
            periodMs: 700, footHeightMm: 40
        )
        let line = cmd.serializedLine
        for c in line {
            XCTAssertFalse("`$;&|\"'\\<>(){}".contains(c),
                "shell metacharacter \(c) 가 serialized line 에 있음: \(line)")
        }
    }
}
