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

    /// 명령 serialize format: `enabled x y a period foot`.
    func testCommandSerializedLineFormat() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: 0.0, aDeg: 0.0,
            periodMs: 600, footHeightMm: 40
        )
        XCTAssertEqual(cmd.serializedLine, "1 28.00 0.00 0.00 600 40")
    }

    /// 정지 명령 — enabled=0.
    func testCommandStopFormat() {
        XCTAssertEqual(WalkingEngineCommand.stop.serializedLine, "0 0.00 0.00 0.00 0 0")
    }

    /// 음수 turn / side 처리.
    func testCommandNegativeValues() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 18.0, yMm: -5.0, aDeg: -25.0,
            periodMs: 700, footHeightMm: 40
        )
        XCTAssertEqual(cmd.serializedLine, "1 18.00 -5.00 -25.00 700 40")
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
