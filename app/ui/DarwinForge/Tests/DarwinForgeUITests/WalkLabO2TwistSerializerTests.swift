import XCTest
@testable import DarwinForgeUI

/// **Wave O2 (2026-06-12, walklab-onboard-teleop-upgrade) — 프로토콜 v2 twist serializer**.
///
/// 검증 대상: `WalkingEngineCommand.serializedLineV2` 가 REP-103 SI 밀리단위 정수 라인을
/// 만들고, 진폭→twist 역변환(vx=2·X/T)이 로봇의 정변환(X≈vx·T/2)과 **왕복 정합**하는지.
/// 로봇 측 동형 변환은 `firmware-patches/walklab-brokerage/tests/test_transport.cpp`
/// (`test_parse_v2_twist`)가 검증 — 양끝 단위 테스트가 변환식을 고정한다.
final class WalkLabO2TwistSerializerTests: XCTestCase {

    // MARK: - 형식

    /// V2 라인 = "V2" + 12 필드 (총 13 토큰).
    func testV2LineTokenCount() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: 0, aDeg: 0,
            periodMs: 600, footHeightMm: 40, hipPitchOffsetDeg: 13.0)
        let line = cmd.serializedLineV2(seq: 7, tTxMs: 1000)
        let tokens = line.split(separator: " ")
        XCTAssertEqual(tokens.count, 13, "V2 + 12 필드: \(line)")
        XCTAssertEqual(String(tokens[0]), "V2", "접두 V2")
        XCTAssertEqual(String(tokens[1]), "7", "seq")
        XCTAssertEqual(String(tokens[2]), "1000", "t_tx_ms")
    }

    /// 전 필드 정수 (부동소수 파싱 배제) — '.' 미포함.
    func testV2AllIntegerFields() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: -5.0, aDeg: 5.0,
            periodMs: 600, footHeightMm: 40, hipPitchOffsetDeg: 13.0)
        let line = cmd.serializedLineV2(seq: 1, tTxMs: 0)
        XCTAssertFalse(line.contains("."), "V2 는 정수 전용: \(line)")
    }

    // MARK: - 변환식 (진폭 → twist)

    /// vx = 2·X/T.  X=28mm, T=0.6s → vx = 93.33 → 93 mm/s.
    func testV2ForwardVelocity() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28.0, yMm: 0, aDeg: 0,
            periodMs: 600, footHeightMm: 40, hipPitchOffsetDeg: 13.0)
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        XCTAssertEqual(String(tokens[4]), "93", "vx_mms = round(2·28/0.6) = 93")
        XCTAssertEqual(String(tokens[5]), "0", "vy_mms = 0")
        XCTAssertEqual(String(tokens[6]), "0", "wz_mrad_s = 0")
    }

    /// 왕복 정합: vx → 로봇 정변환 X≈vx·T/2 가 원 진폭에 근사(반올림 오차 ≤1mm).
    func testV2RoundTripForward() {
        let xMm = 28.0, period = 600.0
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: xMm, yMm: 0, aDeg: 0,
            periodMs: period, footHeightMm: 40)
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        let vx = Double(tokens[4])!
        let T = period / 1000.0
        let xBack = vx * T / 2.0            // 로봇 정변환 (k_x=1)
        XCTAssertEqual(xBack, xMm, accuracy: 1.0, "왕복 X 오차 ≤1mm")
    }

    /// 요 변환: A=5°, T=0.6 → wz = 2·(5·π/180)/0.6·1000 ≈ 291 mrad/s. 왕복 ≤0.5°.
    func testV2YawRoundTrip() {
        let aDeg = 5.0, period = 600.0
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 0, yMm: 0, aDeg: aDeg,
            periodMs: period, footHeightMm: 40)
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        let wz = Double(tokens[6])!
        XCTAssertEqual(wz, 291, accuracy: 1.0, "wz_mrad_s ≈ 291")
        let T = period / 1000.0
        let aBack = (wz / 1000.0) * T / 2.0 * (180.0 / Double.pi)
        XCTAssertEqual(aBack, aDeg, accuracy: 0.5, "왕복 A 오차 ≤0.5°")
    }

    // MARK: - flags 합성

    /// flags = ENABLED 만 (balance off, balltrack off) → 1.
    func testV2FlagsEnabledOnly() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 10, yMm: 0, aDeg: 0,
            periodMs: 600, footHeightMm: 40,
            balanceEnable: false, ballTrackingEnabled: false)
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        XCTAssertEqual(String(tokens[3]), "1", "flags = ENABLED(1)")
    }

    /// flags = ENABLED|BALANCE_ENABLE = 3.
    func testV2FlagsBalanceEnable() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 10, yMm: 0, aDeg: 0,
            periodMs: 600, footHeightMm: 40,
            balanceEnable: true, ballTrackingEnabled: false)
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        XCTAssertEqual(String(tokens[3]), "3", "flags = ENABLED|BALANCE_ENABLE = 3")
    }

    /// 볼 트래킹 ON → BALLTRACK 비트 + (head 0 무력화는 v1 과 동일하게 init 에서 처리).
    func testV2FlagsBallTrack() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 0, yMm: 0, aDeg: 0,
            periodMs: 600, footHeightMm: 40, ballTrackingEnabled: true)
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        let flags = Int(tokens[3])!
        XCTAssertEqual(flags & WalkingEngineCommand.V2Flag.ballTrack,
                       WalkingEngineCommand.V2Flag.ballTrack, "BALLTRACK 비트 set")
    }

    // MARK: - 안전 (정지)

    /// 정지 명령 — period 0 → 분모 0 안전 처리(속도 0), flags 0.
    func testV2StopZeroVelocities() {
        let line = WalkingEngineCommand.stop.serializedLineV2(seq: 9, tTxMs: 0)
        let tokens = line.split(separator: " ")
        XCTAssertEqual(String(tokens[3]), "0", "정지 flags = 0 (disabled)")
        XCTAssertEqual(String(tokens[4]), "0", "정지 vx 0 (period 0 분모 안전)")
        XCTAssertEqual(String(tokens[5]), "0", "정지 vy 0")
        XCTAssertEqual(String(tokens[6]), "0", "정지 wz 0")
        XCTAssertFalse(line.contains("inf"), "분모 0 가 inf 로 새지 않음")
        XCTAssertFalse(line.contains("nan"), "NaN 없음")
    }

    /// hip/head centidegree 인코딩. hip 13.0° → 1300, pan 20.0 → 2000.
    func testV2CentidegreeEncoding() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 0, yMm: 0, aDeg: 0,
            periodMs: 600, footHeightMm: 40, hipPitchOffsetDeg: 13.0,
            headPanDeg: 20.0, headTiltDeg: -10.0)
        // 토큰: 0=V2 1=seq 2=t_tx 3=flags 4=vx 5=vy 6=wz 7=period 8=foot 9=hip_cdeg
        //       10=blevel 11=pan_cdeg 12=tilt_cdeg
        let tokens = cmd.serializedLineV2(seq: 1, tTxMs: 0).split(separator: " ")
        XCTAssertEqual(String(tokens[7]), "600", "period_ms")
        XCTAssertEqual(String(tokens[8]), "40", "foot_mm")
        XCTAssertEqual(String(tokens[9]), "1300", "hip_cdeg = 13.0·100")
        XCTAssertEqual(String(tokens[10]), "2", "blevel default")
        XCTAssertEqual(String(tokens[11]), "2000", "pan_cdeg = 20.0·100")
        XCTAssertEqual(String(tokens[12]), "-1000", "tilt_cdeg = -10.0·100")
    }

    /// shell 안전 — V2 라인도 메타문자 없음(정수·공백·V·하이픈만).
    func testV2NoShellMetacharacters() {
        let cmd = WalkingEngineCommand(
            enabled: true, xMm: 28, yMm: -5, aDeg: -25,
            periodMs: 700, footHeightMm: 40)
        let line = cmd.serializedLineV2(seq: 1, tTxMs: 0)
        for c in line {
            XCTAssertFalse("`$;&|\"'\\<>(){}".contains(c),
                "shell metacharacter \(c): \(line)")
        }
    }
}
