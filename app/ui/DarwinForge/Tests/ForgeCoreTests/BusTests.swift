import XCTest
@testable import ForgeCore

// MARK: - JointID Extended Tests

/// JointID 확장 검증 — name, bodyPart, Codable, Hashable, rawValue 경계.
///
/// 비유: 오케스트라 단원 명부 감사(audit) — 각 단원이 올바른 파트(신체 부위)에
/// 등록되고 고유 ID 를 가지는지 전수 확인.
final class JointIDExtendedTests: XCTestCase {

    // MARK: - name 프로퍼티

    func testArmJointNamesMatchSpec() {
        XCTAssertEqual(JointID.rShoulderPitch.name, "R_SHOULDER_PITCH")
        XCTAssertEqual(JointID.lShoulderPitch.name, "L_SHOULDER_PITCH")
        XCTAssertEqual(JointID.rShoulderRoll.name,  "R_SHOULDER_ROLL")
        XCTAssertEqual(JointID.lShoulderRoll.name,  "L_SHOULDER_ROLL")
        XCTAssertEqual(JointID.rElbow.name,         "R_ELBOW")
        XCTAssertEqual(JointID.lElbow.name,         "L_ELBOW")
    }

    func testLegJointNamesMatchSpec() {
        XCTAssertEqual(JointID.rHipYaw.name,       "R_HIP_YAW")
        XCTAssertEqual(JointID.lHipYaw.name,       "L_HIP_YAW")
        XCTAssertEqual(JointID.rHipRoll.name,      "R_HIP_ROLL")
        XCTAssertEqual(JointID.lHipRoll.name,      "L_HIP_ROLL")
        XCTAssertEqual(JointID.rHipPitch.name,     "R_HIP_PITCH")
        XCTAssertEqual(JointID.lHipPitch.name,     "L_HIP_PITCH")
        XCTAssertEqual(JointID.rKnee.name,         "R_KNEE")
        XCTAssertEqual(JointID.lKnee.name,         "L_KNEE")
        XCTAssertEqual(JointID.rAnklePitch.name,   "R_ANKLE_PITCH")
        XCTAssertEqual(JointID.lAnklePitch.name,   "L_ANKLE_PITCH")
        XCTAssertEqual(JointID.rAnkleRoll.name,    "R_ANKLE_ROLL")
        XCTAssertEqual(JointID.lAnkleRoll.name,    "L_ANKLE_ROLL")
    }

    func testHeadJointNamesMatchSpec() {
        XCTAssertEqual(JointID.headPan.name,  "HEAD_PAN")
        XCTAssertEqual(JointID.headTilt.name, "HEAD_TILT")
    }

    func testAllJointNamesAreNonEmpty() {
        // 어느 관절도 빈 이름을 가져선 안 됨
        for joint in JointID.allCases {
            XCTAssertFalse(joint.name.isEmpty,
                           "\(joint) name 은 빈 문자열이어선 안 됨")
        }
    }

    func testAllJointNamesAreUnique() {
        let names = JointID.allCases.map(\.name)
        let unique = Set(names)
        XCTAssertEqual(names.count, unique.count,
                       "모든 관절 name 은 고유해야 함 — 중복 발견")
    }

    // MARK: - bodyPart 분류 (완전)

    func testRightArmContainsExactlyThreeJoints() {
        let joints = JointID.allCases.filter { $0.bodyPart == .rightArm }
        XCTAssertEqual(joints.count, 3)
        XCTAssertTrue(joints.contains(.rShoulderPitch))
        XCTAssertTrue(joints.contains(.rShoulderRoll))
        XCTAssertTrue(joints.contains(.rElbow))
    }

    func testLeftArmContainsExactlyThreeJoints() {
        let joints = JointID.allCases.filter { $0.bodyPart == .leftArm }
        XCTAssertEqual(joints.count, 3)
        XCTAssertTrue(joints.contains(.lShoulderPitch))
        XCTAssertTrue(joints.contains(.lShoulderRoll))
        XCTAssertTrue(joints.contains(.lElbow))
    }

    func testHeadContainsExactlyTwoJoints() {
        let joints = JointID.allCases.filter { $0.bodyPart == .head }
        XCTAssertEqual(joints.count, 2)
        XCTAssertTrue(joints.contains(.headPan))
        XCTAssertTrue(joints.contains(.headTilt))
    }

    func testBodyPartAllCasesMatchExpectedGroups() {
        let parts = JointID.BodyPart.allCases
        XCTAssertTrue(parts.contains(.rightArm))
        XCTAssertTrue(parts.contains(.leftArm))
        XCTAssertTrue(parts.contains(.rightLeg))
        XCTAssertTrue(parts.contains(.leftLeg))
        XCTAssertTrue(parts.contains(.head))
        XCTAssertEqual(parts.count, 5)
    }

    // MARK: - rawValue 경계 및 init

    func testInitFromInvalidRawValueReturnsNil() {
        XCTAssertNil(JointID(rawValue: 0),   "rawValue 0 은 정의되지 않음")
        XCTAssertNil(JointID(rawValue: 21),  "rawValue 21 은 정의되지 않음")
        XCTAssertNil(JointID(rawValue: 255), "rawValue 255 는 정의되지 않음")
    }

    func testRawValueBoundaryJointsInitCorrectly() {
        XCTAssertEqual(JointID(rawValue: 1),  .rShoulderPitch, "최소 유효 rawValue=1")
        XCTAssertEqual(JointID(rawValue: 20), .headTilt,       "최대 유효 rawValue=20")
    }

    // MARK: - Codable 라운드트립

    func testCodableRoundTripForAllJoints() throws {
        for joint in JointID.allCases {
            let data    = try JSONEncoder().encode(joint)
            let decoded = try JSONDecoder().decode(JointID.self, from: data)
            XCTAssertEqual(decoded, joint, "\(joint) Codable 라운드트립 실패")
        }
    }

    // MARK: - Hashable / Set 연산

    func testHashableSetDeduplication() {
        var s = Set<JointID>()
        s.insert(.headPan)
        s.insert(.headPan)   // 중복
        s.insert(.headTilt)
        XCTAssertEqual(s.count, 2, "중복 JointID 는 Set 에서 1 개")
    }

    func testHashableSetMembership() {
        let s: Set<JointID> = [.rKnee, .lKnee, .headPan]
        XCTAssertTrue(s.contains(.rKnee))
        XCTAssertFalse(s.contains(.rElbow))
    }

    // MARK: - BodyPart Codable

    func testBodyPartCodableRoundTrip() throws {
        for part in JointID.BodyPart.allCases {
            let data    = try JSONEncoder().encode(part)
            let decoded = try JSONDecoder().decode(JointID.BodyPart.self, from: data)
            XCTAssertEqual(decoded, part)
        }
    }
}

// MARK: - JointState Tests

/// JointState — 한 관절의 실시간 스냅샷 검증.
///
/// 비유: 자동차 계기판 읽기 — 연료(전압), 온도, RPM(speed) 등 센서값이
/// 올바른 물리 단위로 변환되는지 확인.
final class JointStateTests: XCTestCase {

    // MARK: - 전압 변환 (voltageVolts = raw / 10)

    func testVoltageVoltsFromRaw120Is12Volts() {
        let state = makeJointState(voltageRaw: 120)
        XCTAssertEqual(state.voltageVolts, 12.0, accuracy: 1e-9)
    }

    func testVoltageVoltsFromRaw0IsZero() {
        let state = makeJointState(voltageRaw: 0)
        XCTAssertEqual(state.voltageVolts, 0.0, accuracy: 1e-9)
    }

    func testVoltageVoltsFromRaw255Is25Point5Volts() {
        let state = makeJointState(voltageRaw: 255)
        XCTAssertEqual(state.voltageVolts, 25.5, accuracy: 1e-9)
    }

    func testVoltageVoltsFrom90RawIs9Volts() {
        // 90 raw = 9.0V — 방전 경고 임계값 근처
        let state = makeJointState(voltageRaw: 90)
        XCTAssertEqual(state.voltageVolts, 9.0, accuracy: 1e-9)
    }

    // MARK: - 구조체 필드 저장 무결성

    func testAllFieldsStoredCorrectly() {
        let state = JointState(
            id: .rKnee,
            torqueEnabled: true,
            goalPosition: 1500,
            presentPosition: 1520,
            presentSpeed: 100,
            presentLoad: 200,
            presentVoltageRaw: 115,
            presentTemperature: 40
        )

        XCTAssertEqual(state.id,                 .rKnee)
        XCTAssertTrue(state.torqueEnabled)
        XCTAssertEqual(state.goalPosition,       1500)
        XCTAssertEqual(state.presentPosition,    1520)
        XCTAssertEqual(state.presentSpeed,       100)
        XCTAssertEqual(state.presentLoad,        200)
        XCTAssertEqual(state.presentVoltageRaw,  115)
        XCTAssertEqual(state.presentTemperature, 40)
    }

    func testTorqueDisabledStoredCorrectly() {
        let state = makeJointState(torqueEnabled: false)
        XCTAssertFalse(state.torqueEnabled)
    }

    func testPositionAtBoundaryValues() {
        let state = JointState(
            id: .headTilt,
            torqueEnabled: false,
            goalPosition: 0,
            presentPosition: 4095,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 100,
            presentTemperature: 30
        )
        XCTAssertEqual(state.goalPosition, 0)
        XCTAssertEqual(state.presentPosition, 4095)
    }

    // MARK: - Equatable

    func testEqualStatesAreEqual() {
        let a = makeJointState(voltageRaw: 120)
        let b = makeJointState(voltageRaw: 120)
        XCTAssertEqual(a, b)
    }

    func testDifferentPresentPositionNotEqual() {
        let a = makeJointState(goalPosition: 2048, presentPosition: 2048)
        let b = makeJointState(goalPosition: 2048, presentPosition: 2100)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentTorqueStateNotEqual() {
        let a = makeJointState(torqueEnabled: true)
        let b = makeJointState(torqueEnabled: false)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentTemperatureNotEqual() {
        let a = makeJointState(presentTemperature: 25)
        let b = makeJointState(presentTemperature: 70)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helper

    private func makeJointState(
        id: JointID = .headPan,
        torqueEnabled: Bool = true,
        goalPosition: UInt16 = 2048,
        presentPosition: UInt16 = 2048,
        presentSpeed: UInt16 = 0,
        presentLoad: UInt16 = 0,
        voltageRaw: UInt8 = 120,
        presentTemperature: UInt8 = 25
    ) -> JointState {
        JointState(
            id: id,
            torqueEnabled: torqueEnabled,
            goalPosition: goalPosition,
            presentPosition: presentPosition,
            presentSpeed: presentSpeed,
            presentLoad: presentLoad,
            presentVoltageRaw: voltageRaw,
            presentTemperature: presentTemperature
        )
    }
}

// MARK: - ImuRaw Tests

/// ImuRaw — CM-730 IMU ADC 10-bit 데이터의 단위 변환 검증.
///
/// 비유: 체중계가 내부적으로 mV 값을 kg 으로 변환하는 것처럼,
/// ADC 0..1023 raw 값이 물리 단위 (dps, g, degree) 로 정확히 변환되는지 확인.
final class ImuRawTests: XCTestCase {

    // MARK: - 상수

    func testAdcCenterIs512() {
        XCTAssertEqual(ImuRaw.adcCenter, 512.0, accuracy: 1e-9)
    }

    func testGyroDpsPerLsbIs2000Over512() {
        XCTAssertEqual(ImuRaw.gyroDpsPerLsb, 2000.0 / 512.0, accuracy: 1e-9)
    }

    func testAccelGPerLsbIs1Over256() {
        XCTAssertEqual(ImuRaw.accelGPerLsb, 1.0 / 256.0, accuracy: 1e-9)
    }

    // MARK: - centered 값 (raw - 512)

    func testCenteredValuesAtNeutralADCAllZero() {
        let imu = makeImu(gyroX: 512, gyroY: 512, gyroZ: 512,
                          accelX: 512, accelY: 512, accelZ: 512)
        XCTAssertEqual(imu.gyroXCentered,  0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.gyroYCentered,  0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.gyroZCentered,  0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.accelXCentered, 0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.accelYCentered, 0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.accelZCentered, 0.0, accuracy: 1e-9)
    }

    func testCenteredValueWithPositiveOffset() {
        // gyroX = 768 → 768 - 512 = 256
        let imu = makeImu(gyroX: 768)
        XCTAssertEqual(imu.gyroXCentered, 256.0, accuracy: 1e-9)
    }

    func testCenteredValueWithNegativeOffset() {
        // accelX = 256 → 256 - 512 = -256
        let imu = makeImu(accelX: 256)
        XCTAssertEqual(imu.accelXCentered, -256.0, accuracy: 1e-9)
    }

    func testGyroZCenteredCalculation() {
        // gyroZ = 100 → 100 - 512 = -412
        let imu = makeImu(gyroZ: 100)
        XCTAssertEqual(imu.gyroZCentered, -412.0, accuracy: 1e-9)
    }

    func testAccelYCenteredCalculation() {
        // accelY = 612 → 612 - 512 = 100
        let imu = makeImu(accelY: 612)
        XCTAssertEqual(imu.accelYCentered, 100.0, accuracy: 1e-9)
    }

    // MARK: - dps 변환

    func testGyroDpsAtNeutralAllZero() {
        let imu = makeImu(gyroX: 512, gyroY: 512, gyroZ: 512)
        XCTAssertEqual(imu.gyroXDps, 0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.gyroYDps, 0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.gyroZDps, 0.0, accuracy: 1e-9)
    }

    func testGyroDpsMaxPositiveScaling() {
        // gyroX = 1023 → (1023-512) * (2000/512) ≈ 1996 dps
        let imu = makeImu(gyroX: 1023)
        let expected = (1023.0 - 512.0) * (2000.0 / 512.0)
        XCTAssertEqual(imu.gyroXDps, expected, accuracy: 1e-6)
    }

    func testGyroDpsNegativeScaling() {
        // gyroY = 0 → (0-512) * (2000/512) ≈ -2000 dps
        let imu = makeImu(gyroY: 0)
        let expected = (0.0 - 512.0) * (2000.0 / 512.0)
        XCTAssertEqual(imu.gyroYDps, expected, accuracy: 1e-6)
    }

    // MARK: - g 변환

    func testAccelGAtNeutralAllZero() {
        let imu = makeImu(accelX: 512, accelY: 512, accelZ: 512)
        XCTAssertEqual(imu.accelXG, 0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.accelYG, 0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.accelZG, 0.0, accuracy: 1e-9)
    }

    func testAccelGFromRaw768IsPlus1G() {
        // accelZ = 768 → (768-512) * (1/256) = 1.0g
        let imu = makeImu(accelZ: 768)
        XCTAssertEqual(imu.accelZG, 1.0, accuracy: 1e-9)
    }

    func testAccelGFromRaw256IsMinus1G() {
        // accelX = 256 → (256-512) * (1/256) = -1.0g
        let imu = makeImu(accelX: 256)
        XCTAssertEqual(imu.accelXG, -1.0, accuracy: 1e-9)
    }

    func testAccelGYFromRaw384IsMinusHalfG() {
        // accelY = 384 → (384-512) * (1/256) = -128/256 = -0.5g
        let imu = makeImu(accelY: 384)
        XCTAssertEqual(imu.accelYG, -0.5, accuracy: 1e-9)
    }

    // MARK: - roll/pitch 저장

    func testRollPitchStoredAndRetrievedCorrectly() {
        let imu = makeImu(rollDeg: 12.5, pitchDeg: -7.3)
        XCTAssertEqual(imu.rollDeg,  12.5, accuracy: 1e-9)
        XCTAssertEqual(imu.pitchDeg, -7.3, accuracy: 1e-9)
    }

    func testZeroRollPitchStoredCorrectly() {
        let imu = makeImu(rollDeg: 0.0, pitchDeg: 0.0)
        XCTAssertEqual(imu.rollDeg,  0.0, accuracy: 1e-9)
        XCTAssertEqual(imu.pitchDeg, 0.0, accuracy: 1e-9)
    }

    func testExtremeTiltAngles() {
        let imu = makeImu(rollDeg: 90.0, pitchDeg: -90.0)
        XCTAssertEqual(imu.rollDeg,  90.0, accuracy: 1e-9)
        XCTAssertEqual(imu.pitchDeg, -90.0, accuracy: 1e-9)
    }

    // MARK: - Equatable

    func testEqualImuReadingsAreEqual() {
        let a = makeImu()
        let b = makeImu()
        XCTAssertEqual(a, b)
    }

    func testInequalityOnDifferentGyroX() {
        let a = makeImu(gyroX: 512)
        let b = makeImu(gyroX: 600)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityOnDifferentRollDeg() {
        let a = makeImu(rollDeg: 0.0)
        let b = makeImu(rollDeg: 5.0)
        XCTAssertNotEqual(a, b)
    }

    func testInequalityOnDifferentAccelZ() {
        let a = makeImu(accelZ: 768)
        let b = makeImu(accelZ: 512)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - raw 필드 저장

    func testRawFieldsStoredCorrectly() {
        let imu = ImuRaw(
            gyroX: 100, gyroY: 200, gyroZ: 300,
            accelX: 400, accelY: 500, accelZ: 600,
            rollDeg: 3.0, pitchDeg: -1.5
        )
        XCTAssertEqual(imu.gyroX,  100)
        XCTAssertEqual(imu.gyroY,  200)
        XCTAssertEqual(imu.gyroZ,  300)
        XCTAssertEqual(imu.accelX, 400)
        XCTAssertEqual(imu.accelY, 500)
        XCTAssertEqual(imu.accelZ, 600)
    }

    // MARK: - Helper

    private func makeImu(
        gyroX: UInt16  = 512, gyroY: UInt16  = 512, gyroZ: UInt16  = 512,
        accelX: UInt16 = 512, accelY: UInt16 = 512, accelZ: UInt16 = 768,
        rollDeg: Double = 0.0, pitchDeg: Double = 0.0
    ) -> ImuRaw {
        ImuRaw(gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
               accelX: accelX, accelY: accelY, accelZ: accelZ,
               rollDeg: rollDeg, pitchDeg: pitchDeg)
    }
}

// MARK: - BoardSnapshot Tests

/// BoardSnapshot — CM-730/CM-740 컨트롤러 보드 스냅샷 검증.
///
/// 비유: 자동차 블랙박스 요약 화면 — 모델(차종), 버전(연식), 전압(배터리),
/// 버튼 상태를 올바르게 표시하는지 확인.
final class BoardSnapshotTests: XCTestCase {

    // MARK: - 전압 변환

    func testVoltageVoltsFrom120RawIs12V() {
        let snap = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        XCTAssertEqual(snap.voltageVolts, 12.0, accuracy: 1e-9)
    }

    func testVoltageVoltsFrom0RawIsZero() {
        let snap = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 0, button: 0)
        XCTAssertEqual(snap.voltageVolts, 0.0, accuracy: 1e-9)
    }

    func testVoltageVoltsFrom255RawIs25Point5V() {
        let snap = BoardSnapshot(modelNumber: 730, version: 2, voltageRaw: 255, button: 0)
        XCTAssertEqual(snap.voltageVolts, 25.5, accuracy: 1e-9)
    }

    func testVoltageVoltsFrom90RawIs9V() {
        let snap = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 90, button: 0)
        XCTAssertEqual(snap.voltageVolts, 9.0, accuracy: 1e-9)
    }

    // MARK: - controllerLabel

    func testControllerLabelForCM730() {
        let snap = BoardSnapshot(modelNumber: 730, version: 1, voltageRaw: 120, button: 0)
        XCTAssertEqual(snap.controllerLabel, "CM-730 (1st gen / OP)")
    }

    func testControllerLabelForCM740() {
        let snap = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        XCTAssertEqual(snap.controllerLabel, "CM-740 (2nd gen / OP2)")
    }

    func testControllerLabelForUnknownModelNumber() {
        let snap = BoardSnapshot(modelNumber: 999, version: 1, voltageRaw: 120, button: 0)
        XCTAssertEqual(snap.controllerLabel, "Unknown (999)")
    }

    func testControllerLabelForModelZero() {
        let snap = BoardSnapshot(modelNumber: 0, version: 0, voltageRaw: 0, button: 0)
        XCTAssertEqual(snap.controllerLabel, "Unknown (0)")
    }

    func testControllerLabelForModel65535() {
        // UInt16.max — 알 수 없는 미래 모델
        let snap = BoardSnapshot(modelNumber: 65535, version: 0, voltageRaw: 0, button: 0)
        XCTAssertEqual(snap.controllerLabel, "Unknown (65535)")
    }

    // MARK: - 필드 저장 무결성

    func testAllFieldsStoredCorrectly() {
        let snap = BoardSnapshot(modelNumber: 740, version: 3, voltageRaw: 115, button: 2)
        XCTAssertEqual(snap.modelNumber, 740)
        XCTAssertEqual(snap.version,     3)
        XCTAssertEqual(snap.voltageRaw,  115)
        XCTAssertEqual(snap.button,      2)
    }

    func testButtonFieldStoredCorrectly() {
        let snap = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 1)
        XCTAssertEqual(snap.button, 1)
    }

    // MARK: - Equatable

    func testEqualSnapshotsAreEqual() {
        let a = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        let b = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        XCTAssertEqual(a, b)
    }

    func testDifferentModelNumberNotEqual() {
        let a = BoardSnapshot(modelNumber: 730, version: 1, voltageRaw: 120, button: 0)
        let b = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentVoltageNotEqual() {
        let a = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        let b = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 115, button: 0)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentButtonStateNotEqual() {
        let a = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        let b = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 1)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentVersionNotEqual() {
        let a = BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
        let b = BoardSnapshot(modelNumber: 740, version: 2, voltageRaw: 120, button: 0)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - FsrReading Tests

/// FsrReading — 발 압력 센서 (FSR) 스냅샷 검증.
///
/// 비유: 욕실 체중계 4 구역 + 무게중심 표시 — 각 셀 압력의 합과
/// 중심점 좌표가 올바르게 계산되는지 확인.
final class FsrReadingTests: XCTestCase {

    // MARK: - totalPressureRaw 계산

    func testTotalPressureRawSumsAllFourCells() {
        let fsr = FsrReading(
            id: 111,
            cellFrontLeft: 100, cellFrontRight: 200,
            cellRearRight: 300, cellRearLeft: 400,
            centerX: 0, centerY: 0
        )
        XCTAssertEqual(fsr.totalPressureRaw, 1000)
    }

    func testTotalPressureRawWhenAllCellsZero() {
        let fsr = makeFsr(fl: 0, fr: 0, rr: 0, rl: 0)
        XCTAssertEqual(fsr.totalPressureRaw, 0)
    }

    func testTotalPressureRawWhenAllCellsMax() {
        // UInt16.max * 4 — UInt32 범위 내 오버플로 없이 계산
        let fsr = makeFsr(fl: 65535, fr: 65535, rr: 65535, rl: 65535)
        XCTAssertEqual(fsr.totalPressureRaw, UInt32(65535) * 4)
    }

    func testTotalPressureRawForSymmetricLoad() {
        // 균등 하중 — 각 셀 256, 합 1024
        let fsr = makeFsr(fl: 256, fr: 256, rr: 256, rl: 256)
        XCTAssertEqual(fsr.totalPressureRaw, 1024)
    }

    func testTotalPressureRawSingleCellOnly() {
        let fsr = makeFsr(fl: 500, fr: 0, rr: 0, rl: 0)
        XCTAssertEqual(fsr.totalPressureRaw, 500)
    }

    // MARK: - ID 검증

    func testLeftFsrIdIs112() {
        let fsr = makeFsr(id: 112)
        XCTAssertEqual(fsr.id, 112, "왼발 FSR board ID = 112")
    }

    func testRightFsrIdIs111() {
        let fsr = makeFsr(id: 111)
        XCTAssertEqual(fsr.id, 111, "오른발 FSR board ID = 111")
    }

    // MARK: - centerX / centerY

    func testCenterXYStoredCorrectly() {
        let fsr = FsrReading(
            id: 111,
            cellFrontLeft: 0, cellFrontRight: 0,
            cellRearRight: 0, cellRearLeft: 0,
            centerX: -50, centerY: 30
        )
        XCTAssertEqual(fsr.centerX, -50)
        XCTAssertEqual(fsr.centerY, 30)
    }

    func testCenterXYBoundaryMinusAndPlus127() {
        // 스펙 범위 -127..127
        let fsr = FsrReading(
            id: 111,
            cellFrontLeft: 0, cellFrontRight: 0,
            cellRearRight: 0, cellRearLeft: 0,
            centerX: -127, centerY: 127
        )
        XCTAssertEqual(fsr.centerX, -127)
        XCTAssertEqual(fsr.centerY, 127)
    }

    func testZeroCenterXY() {
        let fsr = makeFsr(centerX: 0, centerY: 0)
        XCTAssertEqual(fsr.centerX, 0)
        XCTAssertEqual(fsr.centerY, 0)
    }

    // MARK: - Equatable

    func testEqualFsrReadingsAreEqual() {
        let a = makeFsr(fl: 100, fr: 200, rr: 300, rl: 400, centerX: 5, centerY: -10)
        let b = makeFsr(fl: 100, fr: 200, rr: 300, rl: 400, centerX: 5, centerY: -10)
        XCTAssertEqual(a, b)
    }

    func testDifferentFrontLeftCellNotEqual() {
        let a = makeFsr(fl: 100)
        let b = makeFsr(fl: 200)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentCenterXNotEqual() {
        let a = makeFsr(centerX: 0)
        let b = makeFsr(centerX: 50)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentCenterYNotEqual() {
        let a = makeFsr(centerY: 0)
        let b = makeFsr(centerY: -30)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentIdNotEqual() {
        let a = makeFsr(id: 111)
        let b = makeFsr(id: 112)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Helper

    private func makeFsr(
        id: UInt8 = 111,
        fl: UInt16 = 256, fr: UInt16 = 256,
        rr: UInt16 = 256, rl: UInt16 = 256,
        centerX: Int8 = 0, centerY: Int8 = 0
    ) -> FsrReading {
        FsrReading(
            id: id,
            cellFrontLeft: fl, cellFrontRight: fr,
            cellRearRight: rr, cellRearLeft: rl,
            centerX: centerX, centerY: centerY
        )
    }
}
