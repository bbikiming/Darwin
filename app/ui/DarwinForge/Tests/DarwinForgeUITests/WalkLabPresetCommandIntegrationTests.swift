import XCTest
@testable import DarwinForgeUI

/// 사이클 176 — preset → tuning → command 전체 chain 통합 검증.
///
/// WalkLabPreset 8 case 각각에 대해 currentWalkingEngineCommand 호출 시 직렬화 line 의
/// 의미적 정확성 확인. cycle 162 의 10 필드 schema 가 모든 preset 에 일관.
@MainActor
final class WalkLabPresetCommandIntegrationTests: XCTestCase {

    /// **유기 검증 #1**: 8 preset 모두 currentWalkingEngineCommand 호출 시 10 필드 직렬화.
    func testAllPresetsProduceTenFieldCommand() {
        for preset in WalkLabPreset.allCases {
            let s = WalkLabSession()
            s.current = preset
            let cmd = s.currentWalkingEngineCommand(enabled: true)
            let fields = cmd.serializedLine.split(separator: " ")
            XCTAssertEqual(fields.count, 10,
                           "preset=\(preset) 의 serializedLine 10 필드: \(cmd.serializedLine)")
        }
    }

    /// **유기 검증 #2**: idle preset → enabled=false (다른 필드 무관).
    func testIdlePresetCommandDisabled() {
        let s = WalkLabSession()
        s.current = .idle
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertFalse(cmd.enabled,
                       "idle preset 은 enabled=true 호출해도 cmd.enabled=false (current=.idle guard)")
        XCTAssertTrue(cmd.serializedLine.hasPrefix("0 "),
                      "직렬화 첫 필드 0 (disabled)")
    }

    /// **유기 검증 #3**: walk preset (march/idle 제외) 의 default xMm/aDeg > 0.
    /// march 는 의도된 stationary (제자리 걸음 — stride 0, sway 만), idle 도 정지.
    func testWalkPresetsHaveStrideOrTurnExceptStationary() {
        let movingPresets: [WalkLabPreset] = [.slowWalk, .normalWalk, .fastWalk,
                                               .jog, .turnLeft, .turnRight]
        for preset in movingPresets {
            let s = WalkLabSession()
            s.current = preset
            let cmd = s.currentWalkingEngineCommand(enabled: true)
            // turn 은 xMm 작거나 0, aDeg 큼. 다른 walk 는 xMm > 0.
            let hasMotion = cmd.xMm > 0 || abs(cmd.aDeg) > 0 || abs(cmd.yMm) > 0
            XCTAssertTrue(hasMotion,
                          "preset=\(preset) 가 motion 없음 (x=\(cmd.xMm), y=\(cmd.yMm), a=\(cmd.aDeg))")
        }
        // march 는 의도된 stationary — 별도 검증.
        let sMarch = WalkLabSession()
        sMarch.current = .march
        let cmdMarch = sMarch.currentWalkingEngineCommand(enabled: true)
        XCTAssertEqual(cmdMarch.xMm, 0, accuracy: 0.01, "march = 제자리 (stride 0)")
        XCTAssertEqual(cmdMarch.aDeg, 0, accuracy: 0.01)
        XCTAssertTrue(cmdMarch.enabled, "march 는 enabled (period 만 보냄)")
    }

    /// **유기 검증 #4**: balanceGain / Enable / IntensityLevel 모든 preset 에 일관 적용.
    func testBalanceSettingsPropagateToAllPresets() {
        for preset in WalkLabPreset.allCases {
            let s = WalkLabSession()
            s.current = preset
            s.balanceGain = 2.0
            s.enableBalanceCorrection = true
            s.correctorIntensityLevel = 3
            let cmd = s.currentWalkingEngineCommand(enabled: true)
            XCTAssertEqual(cmd.balanceGain, 2.0, accuracy: 0.01,
                           "preset=\(preset) balanceGain")
            XCTAssertTrue(cmd.balanceEnable,
                          "preset=\(preset) balanceEnable")
            XCTAssertEqual(cmd.correctorIntensityLevel, 3,
                           "preset=\(preset) correctorIntensityLevel")
        }
    }

    /// **유기 검증 #5**: stop command 도 10 필드 + default balance.
    func testStopCommandSchema() {
        let stop = WalkingEngineCommand.stop
        let fields = stop.serializedLine.split(separator: " ")
        XCTAssertEqual(fields.count, 10)
        XCTAssertEqual(stop.balanceGain, 1.0)
        XCTAssertFalse(stop.balanceEnable)
        XCTAssertEqual(stop.correctorIntensityLevel, 2)
        // 첫 필드 = 0 (disabled), 7번째 = 13.00 (hipPitchOffset default).
        XCTAssertEqual(stop.serializedLine, "0 0.00 0.00 0.00 0 0 13.00 1.00 0 2")
    }

    /// **유기 검증 #6**: serializedLine 의 모든 필드 floating/integer format 정확.
    /// 옛 daemon sscanf 가 정확히 parse 가능한 format 유지.
    func testSerializedLineFormatStability() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: -5.0, aDeg: 10.0,
            periodMs: 600, footHeightMm: 40,
            hipPitchOffsetDeg: 13.0,
            balanceGain: 1.5, balanceEnable: true,
            correctorIntensityLevel: 3
        )
        let expected = "1 28.00 -5.00 10.00 600 40 13.00 1.50 1 3"
        XCTAssertEqual(cmd.serializedLine, expected,
                       "format: %d %.2f %.2f %.2f %.0f %.0f %.2f %.2f %d %d")
    }

    /// **유기 검증 #7**: enabled 가 cmd.enabled 와 동기 — 사용자 명시 true + idle 가드.
    func testEnabledParameterRespectsIdleGuard() {
        let s = WalkLabSession()
        s.current = .march
        let cmdMarch = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertTrue(cmdMarch.enabled, "march preset + enabled=true → cmd.enabled=true")

        s.current = .idle
        let cmdIdle = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertFalse(cmdIdle.enabled, "idle + enabled=true → cmd.enabled=false (guard)")

        s.current = .march
        let cmdDisabled = s.currentWalkingEngineCommand(enabled: false)
        XCTAssertFalse(cmdDisabled.enabled, "march + enabled=false → cmd.enabled=false")
    }

    /// **유기 검증 #8**: tuning 변경 시 cmd 즉시 반영 (사용자 slider 조정 chain).
    /// 단, advanced=true 일 때만 — basic mode 는 preset default 만 사용.
    func testTuningSliderChangePropagatesToCommandInAdvancedMode() {
        let s = WalkLabSession()
        s.current = .normalWalk
        s.advanced = true   // ✓ 사용자가 slider 활성 — preset 무관 적용.
        s.strideMm = 28     // preset default 와 동일 시작.
        let beforeCmd = s.currentWalkingEngineCommand(enabled: true)

        s.strideMm = 35.0
        let afterCmd = s.currentWalkingEngineCommand(enabled: true)

        XCTAssertNotEqual(beforeCmd.xMm, afterCmd.xMm,
                          "advanced mode + strideMm 변경 → cmd.xMm 변경")
        XCTAssertEqual(afterCmd.xMm, 35.0, accuracy: 0.01)
    }

    /// **유기 검증 #9**: basic mode (advanced=false) 는 preset default 사용 — slider 무시.
    func testBasicModeUsesPresetDefaults() {
        let s = WalkLabSession()
        s.current = .normalWalk
        s.advanced = false  // ✗ slider 비활성.
        s.strideMm = 99.0   // 무시되어야 함.
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        // normalWalk default stride = 28.
        XCTAssertEqual(cmd.xMm, 28.0, accuracy: 0.01,
                       "basic mode: preset default 사용, slider 무시")
    }
}
