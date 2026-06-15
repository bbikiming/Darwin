import XCTest
@testable import DarwinForgeUI

// MARK: - HarnessKoreanLabelsTests (V290-A, 2026-05-25)
//
// Nielsen #6 "Recognition over Recall" — 약어 한글 풀네임 병기 검증.
// SensorLabel.displayName 과 EventKindLabel.displayName 매핑의 정확성을 보장.

final class HarnessKoreanLabelsTests: XCTestCase {

    // MARK: - SensorLabel.displayName

    func test_imu_displayName() {
        XCTAssertEqual(SensorLabel.imu.displayName, "IMU (관성 측정)")
    }

    func test_dxl_displayName() {
        XCTAssertEqual(SensorLabel.dxl.displayName, "DXL (다이나믹셀 모터)")
    }

    func test_dxlPower_displayName() {
        XCTAssertEqual(SensorLabel.dxlPower.displayName, "모터 전원 (dxlPower)")
    }

    func test_zmp_displayName() {
        XCTAssertEqual(SensorLabel.zmp.displayName, "ZMP (영점 모멘트)")
    }

    func test_cop_displayName() {
        XCTAssertEqual(SensorLabel.cop.displayName, "CoP (압력 중심)")
    }

    func test_fsr_displayName() {
        XCTAssertEqual(SensorLabel.fsr.displayName, "FSR (발바닥 압력 센서)")
    }

    func test_eStop_displayName() {
        XCTAssertEqual(SensorLabel.eStop.displayName, "비상 정지 (E-Stop)")
    }

    func test_heartbeat_displayName() {
        XCTAssertEqual(SensorLabel.heartbeat.displayName, "심박 신호 (heartbeat)")
    }

    func test_bus_displayName() {
        XCTAssertEqual(SensorLabel.bus.displayName, "통신 버스 (bus)")
    }

    func test_gyro_displayName() {
        XCTAssertEqual(SensorLabel.gyro.displayName, "자이로 (각속도)")
    }

    func test_accel_displayName() {
        XCTAssertEqual(SensorLabel.accel.displayName, "가속도")
    }

    func test_roll_displayName() {
        XCTAssertEqual(SensorLabel.roll.displayName, "roll (좌우 기울기)")
    }

    func test_pitch_displayName() {
        XCTAssertEqual(SensorLabel.pitch.displayName, "pitch (앞뒤 기울기)")
    }

    func test_yaw_displayName() {
        XCTAssertEqual(SensorLabel.yaw.displayName, "yaw (좌우 회전)")
    }

    func test_rtt_displayName() {
        XCTAssertEqual(SensorLabel.rtt.displayName, "RTT (왕복 지연)")
    }

    func test_preflight_displayName() {
        XCTAssertEqual(SensorLabel.preflight.displayName, "출발 전 점검 (preflight)")
    }

    // MARK: - SensorLabel.shortLabel

    func test_eStop_shortLabel() {
        XCTAssertEqual(SensorLabel.eStop.shortLabel, "비상 정지")
    }

    func test_dxlPower_shortLabel() {
        XCTAssertEqual(SensorLabel.dxlPower.shortLabel, "모터 전원")
    }

    func test_rtt_shortLabel() {
        XCTAssertEqual(SensorLabel.rtt.shortLabel, "RTT 지연")
    }

    func test_imu_shortLabel() {
        XCTAssertEqual(SensorLabel.imu.shortLabel, "IMU 관성")
    }

    // MARK: - SensorLabel.tooltip (비어있지 않음 검증)

    func test_allSensorLabels_haveNonEmptyTooltip() {
        let allCases: [SensorLabel] = [
            .imu, .dxl, .dxlPower, .zmp, .cop, .fsr,
            .eStop, .heartbeat, .bus, .gyro, .accel,
            .roll, .pitch, .yaw, .rtt, .preflight
        ]
        for label in allCases {
            XCTAssertFalse(label.tooltip.isEmpty, "tooltip should not be empty for \(label)")
        }
    }

    // MARK: - EventKindLabel.displayName

    func test_walklab_displayName() {
        XCTAssertEqual(EventKindLabel.walklab.displayName, "WalkLab (보행 실험)")
    }

    func test_motion_displayName() {
        XCTAssertEqual(EventKindLabel.motion.displayName, "Motion (모션)")
    }

    func test_pilot_displayName() {
        XCTAssertEqual(EventKindLabel.pilot.displayName, "Pilot (조종)")
    }

    func test_teach_displayName() {
        XCTAssertEqual(EventKindLabel.teach.displayName, "Teach (티칭)")
    }

    func test_conversation_displayName() {
        XCTAssertEqual(EventKindLabel.conversation.displayName, "대화 (conversation)")
    }

    func test_claude_displayName() {
        XCTAssertEqual(EventKindLabel.claude.displayName, "Claude (AI)")
    }

    // MARK: - EventKindLabel.from(kindRawValue:)

    func test_from_walklab_prefix() {
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "walklab.start"), .walklab)
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "walklab.emergency_stop"), .walklab)
    }

    func test_from_motion_prefix() {
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "motion.play"), .motion)
    }

    func test_from_pilot_prefix() {
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "pilot.command"), .pilot)
    }

    func test_from_teach_prefix() {
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "teach.snapshot"), .teach)
    }

    func test_from_conversation_prefix() {
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "conversation.turn"), .conversation)
    }

    func test_from_claude_prefix() {
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "claude.intent_dispatched"), .claude)
    }

    func test_from_unknown_returns_nil() {
        XCTAssertNil(EventKindLabel.from(kindRawValue: "heartbeat.tick"))
        XCTAssertNil(EventKindLabel.from(kindRawValue: "bus.write_fail"))
        XCTAssertNil(EventKindLabel.from(kindRawValue: "connection.failure"))
        XCTAssertNil(EventKindLabel.from(kindRawValue: ""))
    }

    func test_from_caseInsensitive_walklab() {
        // rawValue 는 소문자로 오지만 대소문자 혼합도 안전하게 처리.
        XCTAssertEqual(EventKindLabel.from(kindRawValue: "WalkLab.start"), .walklab)
    }
}
