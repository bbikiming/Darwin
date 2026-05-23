import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **사이클 259 (V259-1) — tick() pipeline 의 safety gate (L0/L3/L4) regression guard**.
///
/// 검증 대상 (검증 II critic 발견 6건):
/// - L3 tilt gate: 3 consecutive ≥50° → emergencyStopActive
/// - L3 tilt gate: safe tick 후 counter reset → 3 미만이면 emergency 미발화
/// - L4 thermal gate: maxMotorTemp ≥60°C → emergencyStopActive
/// - L0 voltage droop: store=nil 환경에서 counter reset 보장 (full fire 는 store 의존)
/// - cradleConfirmed auto-clear: bus disconnect 감지 시 강제 해제
/// - stop() history 12 cap: 13회 stop 후 history.count == 12
/// - emergencyStop ordering: emergencyStopActive=true BEFORE hardware call (race guard)
///
/// **testability hook 의존**:
/// - `_testForceTick(rollDeg:pitchDeg:)` — IMU 값 직접 set + tickRunSafetyPipeline 호출.
/// - `_testInspectL3HardGate()` — l3HardGateConsecutiveSamples inspector.
/// - `lastSeenBusConnected` (internal) — disconnect 감지 시뮬.
/// - `tickEnforceCradleOnDisconnect()` (internal) — phase 직접 호출.
///
/// **L0 full fire 미검증 사유**:
/// `tickRunSafetyPipeline()` 의 L0 gate 는 `voltageDroopConsecutiveSamples >= triggerCount`
/// AND `store?.lastTelemetry?.board?.voltageVolts != nil` 을 모두 요구. store=nil 환경
/// 에서 후자가 항상 nil → emergency 미발화. store/MockBus/MockTelemetry DI 후 별도 test
/// 로 커버 필요 (TODO).
@MainActor
final class SafetyPipelineTests: XCTestCase {

    // MARK: - L3 tilt gate (3 consecutive ≥50° → emergency)

    /// 3회 연속 50°+ tilt → emergencyStopActive
    func testL3TiltGateTriggersEmergencyAfter3Consecutive() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        // 첫 2회: ≥50° tilt — counter 증가, emergency 미발화.
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        XCTAssertFalse(session.emergencyStopActive,
                       "1회 55° — emergency 아직 미발화 (3 연속 필요)")
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        XCTAssertFalse(session.emergencyStopActive,
                       "2회 55° — emergency 아직 미발화")

        // 3회째: L3 hard gate 충족 → balanceLost=true + emergencyStop 자동 발화.
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        XCTAssertTrue(session.emergencyStopActive,
                      "L3: 3 consecutive ≥50° → emergencyStopActive (낙상 방지 gate)")
        // balanceLost 는 emergencyStop() → esResetDiagnosticFlags() 에서 false 로 reset됨.
        // lastEmergencyTrigger 로 L3 경로 확인.
        XCTAssertEqual(session.lastEmergencyTrigger, .balanceLostL3,
                       "L3 발화 후 lastEmergencyTrigger = .balanceLostL3")
    }

    /// 3회 연속 도달 전에 safe tick → counter reset → 이후 단일 55° 는 emergency 미발화
    func testL3TiltGateResetsCounterOnSafeTick() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        // 55° 2회 연속.
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        XCTAssertEqual(session._testInspectL3HardGate(), 2,
                       "2회 후 counter = 2")

        // 정상 tick — counter 0으로 reset.
        session._testForceTick(rollDeg: 0, pitchDeg: 0)
        XCTAssertEqual(session._testInspectL3HardGate(), 0,
                       "정상 tick 후 counter reset = 0")

        // 다시 1회 55° — counter = 1, emergency 미발화 (3 미달).
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        XCTAssertFalse(session.emergencyStopActive,
                       "reset 후 1회 55° → emergency 미발화 (3 연속 미달)")
        XCTAssertEqual(session._testInspectL3HardGate(), 1,
                       "reset 후 1회 → counter = 1")
    }

    /// L3 gate 는 pitch 기준으로도 동일하게 동작
    func testL3TiltGateTriggersOnPitchExceedance() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        session._testForceTick(rollDeg: 0, pitchDeg: 52)
        session._testForceTick(rollDeg: 0, pitchDeg: 52)
        session._testForceTick(rollDeg: 0, pitchDeg: 52)

        XCTAssertTrue(session.emergencyStopActive,
                      "L3: pitch 52° 3 연속 → emergencyStopActive")
    }

    // MARK: - L4 thermal gate (≥60°C → auto emergency)

    /// maxMotorTemp ≥60°C → 단일 tick 에서 emergencyStop 자동 발화
    func testL4ThermalGateTriggersEmergencyAt60C() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // maxMotorTemp 는 public internal(set) — 테스트에서 직접 set 가능.
        session.maxMotorTemp = 61.0

        session._testForceTick(rollDeg: 0, pitchDeg: 0)

        XCTAssertTrue(session.emergencyStopActive,
                      "L4: maxMotorTemp ≥60°C → emergencyStop(.thermalOverheat) 자동 발화")
        XCTAssertTrue(session.thermalAlarm,
                      "L4 발화 시 thermalAlarm=true")
        XCTAssertTrue(session.thermalCoolDownRequired,
                      "L4 발화 시 thermalCoolDownRequired=true (50°C 미만 대기)")
    }

    /// maxMotorTemp = 59.9°C → 임계 미달, emergency 미발화
    func testL4ThermalGateDoesNotFireBelow60C() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.maxMotorTemp = 59.9

        session._testForceTick(rollDeg: 0, pitchDeg: 0)

        XCTAssertFalse(session.emergencyStopActive,
                       "L4: maxMotorTemp 59.9°C — 60°C 미달, emergency 미발화")
        XCTAssertFalse(session.thermalAlarm,
                       "59.9°C — thermalAlarm 미발화")
    }

    // MARK: - L0 voltage droop (store=nil 환경 — counter reset 보장)

    /// store=nil 환경에서 updateVoltageDroopTracking 는 counter=0으로 reset
    ///
    /// L0 full fire (emergency 발화) 는 `store?.lastTelemetry?.board?.voltageVolts`
    /// 가 non-nil 이어야 하므로 store=nil 환경에서 검증 불가.
    /// TODO: MockBus + MockTelemetry DI 로 full fire 검증 (별도 task).
    func testL0VoltageTrackingResetWhenStoreNil() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // 카운터를 trigger count - 1 로 미리 채움.
        session.voltageDroopConsecutiveSamples = WalkLabSession.voltageDroopTriggerCount - 1

        // store=nil 환경에서 tick → updateVoltageDroopTracking 가 0으로 reset.
        session._testForceTick(rollDeg: 0, pitchDeg: 0)

        XCTAssertEqual(session.voltageDroopConsecutiveSamples, 0,
                       "store=nil → voltage droop counter reset (bus 없음 = 배터리 센서 없음)")
    }

    /// voltageDroopTriggerCount 상수는 5 — ROBOTIS-OP2 250ms 지속 기준 불변 계약
    func testL0VoltageTriggerCountConstantIs5() {
        XCTAssertEqual(WalkLabSession.voltageDroopTriggerCount, 5,
                       "voltage droop trigger count = 5 (50ms tick × 5 = 250ms 지속)")
    }

    // MARK: - L0 voltage droop full-fire (V264-1 — _testOverrideVoltageVolts inject)

    /// 5회 연속 임계 미달 voltage → emergencyStop(.voltageDroop) 자동 발화
    ///
    /// 임계: 9.5V. `_testOverrideVoltageVolts` 로 store 없이 8.0V 주입.
    func testL0VoltageGateFiresEmergencyAfter5ConsecutiveLowSamples() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        // 5회 연속 8.0V (9.5V 임계 미달) — voltageDroopTriggerCount=5 충족 시 발화.
        session._testOverrideVoltageVolts = 8.0
        for i in 1...WalkLabSession.voltageDroopTriggerCount {
            session._testForceTick(rollDeg: 0, pitchDeg: 0)
            if i < WalkLabSession.voltageDroopTriggerCount {
                XCTAssertFalse(session.emergencyStopActive,
                               "\(i)회 — \(WalkLabSession.voltageDroopTriggerCount)회 미달, emergency 미발화")
            }
        }
        XCTAssertTrue(session.emergencyStopActive,
                      "5회 연속 8.0V (< 9.5V) → emergencyStop(.voltageDroop) 발화")
        XCTAssertEqual(session.lastEmergencyTrigger, .voltageDroop,
                       "L0 gate 발화 후 lastEmergencyTrigger = .voltageDroop")
    }

    /// 정상 voltage 1회 삽입 시 counter reset → 이후 4회 low 는 emergency 미발화
    ///
    /// 비유: 5회 연속 저혈압이 위험 기준. 4회 후 한 번 정상 → 카운터 초기화.
    func testL0VoltageGateResetsCounterOnSingleSafeSample() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        // 4회 low voltage.
        session._testOverrideVoltageVolts = 8.0
        for _ in 1...4 {
            session._testForceTick(rollDeg: 0, pitchDeg: 0)
        }
        XCTAssertFalse(session.emergencyStopActive, "4회 — trigger 미달, emergency 아직 없음")

        // 1회 정상 voltage → counter reset.
        session._testOverrideVoltageVolts = 11.5
        session._testForceTick(rollDeg: 0, pitchDeg: 0)
        XCTAssertEqual(session.voltageDroopConsecutiveSamples, 0,
                       "정상 sample 1회 → counter = 0 (reset)")

        // reset 후 4회 low → emergency 미발화 (5 미달).
        session._testOverrideVoltageVolts = 8.0
        for _ in 1...4 {
            session._testForceTick(rollDeg: 0, pitchDeg: 0)
        }
        XCTAssertFalse(session.emergencyStopActive,
                       "reset 후 4회 low → 5 미달, emergency 미발화")
    }

    /// 정확히 9.5V (임계값) 에서는 counter 증가 없음 — boundary (≥ 9.5V = 정상)
    ///
    /// `updateVoltageDroopTracking` 의 `if v < 9.5` — 9.5V 는 안전 zone.
    func testL0VoltageGateBoundaryAtCriticalThreshold() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        // 정확히 9.5V — critical 미달 아님.
        session._testOverrideVoltageVolts = 9.5
        for _ in 1...WalkLabSession.voltageDroopTriggerCount {
            session._testForceTick(rollDeg: 0, pitchDeg: 0)
        }
        XCTAssertFalse(session.emergencyStopActive,
                       "9.5V (임계값) — v < 9.5 조건 불충족, counter 미증가, emergency 미발화")
        XCTAssertEqual(session.voltageDroopConsecutiveSamples, 0,
                       "9.5V — counter = 0 (정상 zone)")

        // 9.4V (임계값 0.1V 미달) — counter 증가.
        session._testOverrideVoltageVolts = 9.4
        for i in 1...WalkLabSession.voltageDroopTriggerCount {
            session._testForceTick(rollDeg: 0, pitchDeg: 0)
            if i < WalkLabSession.voltageDroopTriggerCount {
                XCTAssertEqual(session.voltageDroopConsecutiveSamples, i,
                               "9.4V \(i)회 → counter = \(i)")
            }
        }
        XCTAssertTrue(session.emergencyStopActive,
                      "9.4V 5회 연속 (< 9.5V) → emergency 발화")
    }

    // MARK: - cradleConfirmed auto-clear on bus disconnect

    /// bus disconnect 감지 (lastSeenBusConnected=true → store.bus=nil) 시
    /// cradleConfirmed 자동 해제
    func testCradleConfirmedClearedOnBusDisconnect() {
        let session = WalkLabSession()
        // 이전 tick 에서 bus 가 연결됐다고 인식하도록 설정.
        session.lastSeenBusConnected = true
        // cradleConfirmed 를 true 로 설정 (거치 확인된 상태).
        // didSet SafetyEvent 를 무시하고 확인용으로만 사용.
        session.cradleConfirmed = true

        // store=nil → currentlyConnected=false. lastSeenBusConnected=true → disconnect 감지.
        // tickEnforceCradleOnDisconnect 직접 호출 (tick() 전체 없이 phase 검증).
        session.tickEnforceCradleOnDisconnect()

        XCTAssertFalse(session.cradleConfirmed,
                       "bus disconnect 감지 시 cradleConfirmed 자동 해제 (재연결 후 재확인 필요)")
    }

    /// bus 연결 유지 중 cradleConfirmed 는 자동 해제되지 않음
    func testCradleConfirmedPreservedWhenBusStaysConnected() {
        let session = WalkLabSession()
        // lastSeenBusConnected=false, store=nil → currentlyConnected=false
        // lastSeenBusConnected false → disconnect branch 진입 안 함.
        session.lastSeenBusConnected = false
        session.cradleConfirmed = true

        session.tickEnforceCradleOnDisconnect()

        // 이전에도 연결 없었음 → disconnect 이벤트 아님 → cradleConfirmed 유지.
        XCTAssertTrue(session.cradleConfirmed,
                      "lastSeenBusConnected=false → disconnect 이벤트 없음, cradleConfirmed 유지")
    }

    // MARK: - stop() history 12 cap

    /// 13회 start+stop 후 history.count == 12 (FIFO eviction)
    func testStopAppendsHistoryAndCapsAt12() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        for _ in 0..<13 {
            session.start(.march)
            // startTime 을 nil 이 아닌 상태로 만들기 위해 stop 직전에 startTime 강제.
            // start() 는 sim 모드 (store=nil) 에서 startTime 을 갱신하지 않을 수 있음.
            // startTime 이 nil 이면 stopAppendHistoryRecord 가 skip → 직접 set.
            if session.startTime == nil {
                session.startTime = Date().addingTimeInterval(-1)
            }
            session.stop()
        }

        XCTAssertEqual(session.history.count, 12,
                       "stop history cap: 13회 stop 후 최대 12건 유지 (FIFO eviction)")
    }

    /// 12회 정확히 stop 하면 history.count == 12 (cap 초과 없음)
    func testStopHistoryExact12DoesNotEvict() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        for _ in 0..<12 {
            session.start(.march)
            if session.startTime == nil {
                session.startTime = Date().addingTimeInterval(-1)
            }
            session.stop()
        }

        XCTAssertEqual(session.history.count, 12,
                       "12회 stop → history.count == 12 (cap 미초과)")
    }

    // MARK: - emergencyStop ordering regression (race guard)

    /// emergencyStopActive=true 가 esCancelAllTasks / esExecuteHardwareEStop 보다 먼저 set
    ///
    /// v1.11.22.1 CRITICAL fix: exit-phase race guard — emergencyStopActive flag 먼저 set →
    /// walkCycleTask 의 exit phase 가 walkReady setPosition 시도 前 check 하여 skip.
    /// 이 순서가 역전되면 토크 OFF 이후 setPosition 이 실행되는 race 발생.
    ///
    /// 검증: emergencyStop() 호출 후 emergencyStopActive=true 임을 확인.
    /// (flag set 순서 자체는 production 코드에서 esRaiseEmergencyFlag 가 phase 3에 위치하여
    ///  esCancelAllTasks(phase 4) / esExecuteHardwareEStop(phase 5) 보다 먼저 실행됨을
    ///  WalkLabSession+Stop.swift 코드로 보장.)
    func testEmergencyStopSetsActiveFlagBeforeReturn() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        XCTAssertFalse(session.emergencyStopActive,
                       "초기 상태: emergencyStopActive=false")

        session.emergencyStop(trigger: .userClick)

        XCTAssertTrue(session.emergencyStopActive,
                      "emergencyStop() 완료 후 emergencyStopActive=true (race guard 보존)")
    }

    /// emergencyStop trigger payload 가 lastEmergencyTrigger 에 보존
    func testEmergencyStopPreservesTriggerPayload() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        session.emergencyStop(trigger: .balanceLostL3)

        XCTAssertEqual(session.lastEmergencyTrigger, .balanceLostL3,
                       "emergencyStop trigger payload → lastEmergencyTrigger 에 보존")
    }

    /// L3 gate 자동 발화 시 trigger = .balanceLostL3 로 기록
    func testL3GateEmergencyTriggerIsBalanceLostL3() {
        let session = WalkLabSession()
        session.cradleConfirmed = true

        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        session._testForceTick(rollDeg: 55, pitchDeg: 0)
        session._testForceTick(rollDeg: 55, pitchDeg: 0)

        XCTAssertEqual(session.lastEmergencyTrigger, .balanceLostL3,
                       "L3 gate 자동 emergency → trigger = .balanceLostL3")
    }

    /// L4 gate 자동 발화 시 trigger = .thermalOverheat 로 기록
    func testL4GateEmergencyTriggerIsThermalOverheat() {
        let session = WalkLabSession()
        session.cradleConfirmed = true
        session.maxMotorTemp = 62.0

        session._testForceTick(rollDeg: 0, pitchDeg: 0)

        XCTAssertEqual(session.lastEmergencyTrigger, .thermalOverheat,
                       "L4 gate 자동 emergency → trigger = .thermalOverheat")
    }
}
