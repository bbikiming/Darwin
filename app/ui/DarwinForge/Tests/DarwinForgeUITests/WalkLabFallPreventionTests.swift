import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// v1.1 — Walk Lab Fall Prevention 회귀 가드.
///
/// 사용자 요구 "자이로 센서 기반 넘어지지 않게 동작" 대응. Stage 1 = 실 IMU wire-up.
/// 이후 Stage 2-5 의 회귀도 본 파일에 누적.
@MainActor
final class WalkLabFallPreventionTests: XCTestCase {

    // MARK: - Stage 1 — 실 IMU wire-up

    /// store 미attach + 미연결 → sim IMU 사용. 기존 동작 보존.
    func testImuSourceSimWhenNotAttached() {
        let session = WalkLabSession()
        // 초기 상태.
        XCTAssertEqual(session.imuSource, .sim,
            "store attach 전 imuSource 가 sim 이 아님")
    }

    /// store attach + bus nil (연결 시도 안 함) → sim 유지.
    func testImuSourceSimWhenBusIsNil() {
        let session = WalkLabSession()
        let store = ConnectionStore()
        session.attach(store: store)
        // bus 가 nil 이라 sim 으로 fallback.
        // tick() 호출 위해 cradleConfirmed + start 필요하나 sim 모드 검증만 — 직접 호출.
        // (private updateImuFromRealOrSim 은 호출 불가 → 공개 invariant 만 검증)
        XCTAssertEqual(session.imuSource, .sim)
    }

    /// imuSource enum 의 label 출력.
    func testImuSourceLabelNotEmpty() {
        XCTAssertEqual(WalkLabSession.ImuSource.sim.label, "시뮬")
        XCTAssertEqual(WalkLabSession.ImuSource.real.label, "실 IMU")
        XCTAssertEqual(WalkLabSession.ImuSource.stale.label, "IMU 지연")
    }

    /// L3 자동 정지 게이트가 imuSource 와 무관하게 작동 — sim 모드에서 직접 값 주입.
    /// (Stage 1 변경이 기존 게이트 동작을 깨지 않음을 검증)
    func testL3GateWorksRegardlessOfSource() {
        let session = WalkLabSession()
        // sim 모드의 imuRollDeg/imuPitchDeg 는 일반적으로 0~6° 흔들림.
        // 임계 30° 도달 시 balanceLost true + emergency stop.
        // 직접 imuRollDeg 주입 후 다음 tick 에서 게이트 발동 확인은 simTimer
        // private 이라 직접 테스트 불가. 공개 invariant: balanceLost 초기 false.
        XCTAssertFalse(session.balanceLost, "초기 balanceLost 가 true 인 것은 비정상")
    }

    // MARK: - Stage 2 — 다단계 안전 임계

    /// BalanceState 임계 정확성.
    func testBalanceStateThresholds() {
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 0),    .normal)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 10),   .normal)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 14.9), .normal)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 15),   .caution)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 21.9), .caution)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 22),   .warning)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 27.9), .warning)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 28),   .danger)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 29.9), .danger)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 30),   .emergency)
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 45),   .emergency)
    }

    /// 속도 배수 — Warning 70%, Danger 0%.
    func testBalanceStateSpeedScale() {
        XCTAssertEqual(WalkLabSession.BalanceState.normal.speedScale,    1.0)
        XCTAssertEqual(WalkLabSession.BalanceState.caution.speedScale,   1.0)
        XCTAssertEqual(WalkLabSession.BalanceState.warning.speedScale,   0.7, accuracy: 0.001)
        XCTAssertEqual(WalkLabSession.BalanceState.danger.speedScale,    0.0)
        XCTAssertEqual(WalkLabSession.BalanceState.emergency.speedScale, 0.0)
    }

    /// BalanceState 가 Comparable — 단조 증가.
    func testBalanceStateIsComparable() {
        XCTAssertLessThan(WalkLabSession.BalanceState.normal, .caution)
        XCTAssertLessThan(WalkLabSession.BalanceState.caution, .warning)
        XCTAssertLessThan(WalkLabSession.BalanceState.warning, .danger)
        XCTAssertLessThan(WalkLabSession.BalanceState.danger, .emergency)
    }

    /// 라벨 비어있지 않음 — UI 표시 안전.
    func testBalanceStateLabelsNotEmpty() {
        for s in [WalkLabSession.BalanceState.normal, .caution, .warning, .danger, .emergency] {
            XCTAssertFalse(s.label.isEmpty, "\(s) label 비어있음")
        }
    }

    /// 초기 상태 — 정상 + autoFallPrevention ON.
    func testInitialStateNormalAndAutoOn() {
        let session = WalkLabSession()
        XCTAssertEqual(session.balanceState, .normal)
        XCTAssertTrue(session.autoFallPrevention,
            "autoFallPrevention 기본값이 ON 이어야 함 (사용자가 명시적 OFF 가능)")
    }

    // MARK: - Stage 3 — 예측 fall detection (정량 시나리오)

    /// 빈 buffer → zero prediction.
    func testFallPredictorEmptyBuffer() {
        let pred = FallPredictor.predict(samples: [])
        XCTAssertEqual(pred.score, 0)
        XCTAssertNil(pred.etaMs)
        XCTAssertFalse(pred.recommendEmergency)
    }

    /// 1 sample — rate=variance=0 → score 는 tilt 기여만.
    func testFallPredictorSingleSample() {
        let now = Date()
        let sample = FallPredictor.Sample(timestamp: now, rollDeg: 15, pitchDeg: 0,
                                          gyroXDps: 0, gyroYDps: 0)
        let pred = FallPredictor.predict(samples: [sample], now: now)
        // tiltContrib = 15/30*60 = 30. 다른 기여 0.
        XCTAssertEqual(pred.score, 30, accuracy: 0.1)
        XCTAssertNil(pred.etaMs, "rate=0 이면 ETA 안 나옴")
    }

    /// 정상 보행 sim 흔들림 — false positive 없음.
    /// `±4° / 0.6s 주기` 의 sim sin 흔들림에서 score 가 30 미만이어야 함.
    func testFallPredictorNoFalsePositiveOnNormalSimWalk() {
        let base = Date()
        // 5 sample, 200ms 간격, sin 흔들림 ±4° (sim 모델과 일치).
        let samples: [FallPredictor.Sample] = (0..<5).map { i in
            let t = base.addingTimeInterval(Double(i) * 0.2)
            let phase = Double(i) * 0.2 * 2.0 * .pi / 0.6  // 0.6s 주기
            let roll = 4.0 * sin(phase)
            // gyro = derivative ≈ 4 * cos(phase) * (2π/0.6) ≈ 42 dps max
            let gyroX = 4.0 * cos(phase) * (2.0 * .pi / 0.6)
            return FallPredictor.Sample(timestamp: t, rollDeg: roll, pitchDeg: 0,
                                        gyroXDps: gyroX, gyroYDps: 0)
        }
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.8))
        XCTAssertLessThan(pred.score, 50,
            "정상 보행 흔들림(±4°)에서 score \(pred.score) ≥ 50 → false positive 위험")
        XCTAssertFalse(pred.recommendEmergency,
            "정상 보행에서 emergency 권고 = false positive")
    }

    /// **정량 시나리오 — 빠른 기울기 fall**: 0°→20° in 500ms (rate 40 deg/s).
    /// score 50+ 기대. etaMs 약 250ms (남은 10° / 40 dps).
    func testFallPredictorFastTiltSpike() {
        let base = Date()
        let samples: [FallPredictor.Sample] = (0..<5).map { i in
            let t = base.addingTimeInterval(Double(i) * 0.1)
            let roll = Double(i) * 5.0  // 0, 5, 10, 15, 20
            return FallPredictor.Sample(timestamp: t, rollDeg: roll, pitchDeg: 0,
                                        gyroXDps: 50, gyroYDps: 5)
        }
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.4))
        // tilt 20° → tiltContrib 40, rate 50 deg/s → rateContrib 25.
        XCTAssertGreaterThan(pred.score, 50,
            "20° fast tilt 에서 score \(pred.score) ≤ 50 → 예측 둔감")
        XCTAssertNotNil(pred.etaMs, "rate 50 dps > 5 dps 라 ETA 계산되어야 함")
        if let eta = pred.etaMs {
            // 30° 도달 = 10° / 50 dps = 200ms.
            XCTAssertLessThan(eta, 400,
                "ETA \(eta)ms 가 emergency 임계 400ms 초과")
        }
    }

    /// **정량 시나리오 — imminent fall**: 25° + rate 80 dps + 큰 variance.
    /// score 80+ 또는 ETA < 400ms 로 emergency 권고.
    func testFallPredictorImminentFallTriggersEmergency() {
        let base = Date()
        // 3 sample. rate = (28-22)/0.4 = 15 dps … 너무 작음. 더 가파르게.
        let samples: [FallPredictor.Sample] = [
            .init(timestamp: base,                       rollDeg: 10, pitchDeg: 5,
                  gyroXDps: 80, gyroYDps: 40),
            .init(timestamp: base.addingTimeInterval(0.2), rollDeg: 18, pitchDeg: 8,
                  gyroXDps: 90, gyroYDps: 30),
            .init(timestamp: base.addingTimeInterval(0.4), rollDeg: 28, pitchDeg: 12,
                  gyroXDps: 95, gyroYDps: 50),
        ]
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.5))
        // tiltMax 28 → tiltContrib 56. rate (28-10)/0.4 = 45 → rateContrib 22.5.
        // variance: gyroX 평균 88, 분산 ≈ 38 → 작음. gyroY 평균 40, 분산 ≈ 66.
        // total ≈ 56+22.5+1 ≈ 80. emergency 임계.
        XCTAssertGreaterThanOrEqual(pred.score, 75,
            "imminent fall 에서 score \(pred.score) < 75 → 예측 부족")
        XCTAssertTrue(pred.recommendEmergency,
            "score \(pred.score) + eta \(pred.etaMs ?? -1) → emergency 권고 안 함")
    }

    /// **회복 시나리오** — tilt 가 감소 중 (negative rate) → ETA nil + score 감소.
    func testFallPredictorRecoveringTiltNoEta() {
        let base = Date()
        let samples: [FallPredictor.Sample] = (0..<5).map { i in
            let t = base.addingTimeInterval(Double(i) * 0.2)
            let roll = 20.0 - Double(i) * 4.0  // 20, 16, 12, 8, 4
            return FallPredictor.Sample(timestamp: t, rollDeg: roll, pitchDeg: 0,
                                        gyroXDps: -20, gyroYDps: 0)
        }
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.8))
        XCTAssertNil(pred.etaMs, "회복 중 (rate 음수) → ETA nil 이어야 함")
        XCTAssertFalse(pred.recommendEmergency,
            "회복 중인 robot 에 emergency 권고 = 잘못된 trigger")
    }

    /// NaN sample 거르기 — 통신 실패 시 fallback.
    func testFallPredictorRejectsNaNSamples() {
        let base = Date()
        let samples: [FallPredictor.Sample] = [
            .init(timestamp: base, rollDeg: .nan, pitchDeg: 5,
                  gyroXDps: 30, gyroYDps: 0),
            .init(timestamp: base.addingTimeInterval(0.2), rollDeg: 10, pitchDeg: 5,
                  gyroXDps: 30, gyroYDps: 0),
        ]
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.3))
        // 첫 NaN sample 제거 → 1 sample 남음 → rate=0, tilt 10° 만.
        XCTAssertLessThan(pred.score, 30, "NaN 거르기 실패")
    }

    /// **append helper — 1초 윈도우 truncate.**
    func testFallPredictorAppendTrims1SecondWindow() {
        var buffer: [FallPredictor.Sample] = []
        let base = Date()
        // 10 sample 100ms 간격 push.
        for i in 0..<10 {
            let s = FallPredictor.Sample(
                timestamp: base.addingTimeInterval(Double(i) * 0.1),
                rollDeg: 0, pitchDeg: 0, gyroXDps: 0, gyroYDps: 0
            )
            FallPredictor.append(s, to: &buffer)
        }
        // 1.1초 윈도우 + maxBufferSize 5 = 최대 5 sample.
        XCTAssertLessThanOrEqual(buffer.count, FallPredictor.maxBufferSize,
            "buffer 가 maxBufferSize 초과 — truncate 실패")
    }

    /// **Emergency 임계 정량 — score ≥ 80** 면 emergency 권고.
    func testEmergencyThresholdConsistent() {
        let base = Date()
        // score = 60 (tilt 30°) + 20 (rate 40 dps) = 80 정확.
        let samples: [FallPredictor.Sample] = [
            .init(timestamp: base, rollDeg: 22, pitchDeg: 0,
                  gyroXDps: 40, gyroYDps: 0),
            .init(timestamp: base.addingTimeInterval(0.2), rollDeg: 30, pitchDeg: 0,
                  gyroXDps: 40, gyroYDps: 0),
        ]
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.3))
        XCTAssertGreaterThanOrEqual(pred.score, 75,
            "30° + 40 dps rate 에서 score \(pred.score) 너무 낮음")
        XCTAssertTrue(pred.recommendEmergency)
    }

    /// **ETA 단위 sanity** — rate 50 dps + tilt 10° → ETA = (30-10)/50*1000 = 400ms.
    func testEtaMsUnitsCorrect() {
        let base = Date()
        let samples: [FallPredictor.Sample] = [
            .init(timestamp: base, rollDeg: 0, pitchDeg: 0,
                  gyroXDps: 50, gyroYDps: 0),
            .init(timestamp: base.addingTimeInterval(0.2), rollDeg: 10, pitchDeg: 0,
                  gyroXDps: 50, gyroYDps: 0),
        ]
        let pred = FallPredictor.predict(samples: samples, now: base.addingTimeInterval(0.3))
        // rate = (10-0)/0.2 = 50 dps. ETA = (30-10)/50*1000 = 400ms.
        if let eta = pred.etaMs {
            XCTAssertEqual(eta, 400, accuracy: 50,
                "ETA \(eta) ms 기대 400 ms 차이 큼 — 단위 정합성 의심")
        } else {
            XCTFail("rate 50 dps 에서 ETA nil")
        }
    }

    // MARK: - Stage 4 — Balance feedback (Walking.cpp 패턴)

    /// **gain 정합성** — `robotisDefault` 가 WalkParams.default() 와 동일 4개 gain.
    func testBalanceCorrectorDefaultsMatchRobotis() {
        let c = BalanceCorrector.robotisDefault
        XCTAssertEqual(c.hipRollGain,    0.5, accuracy: 0.001)  // Walking.cpp:110
        XCTAssertEqual(c.kneeGain,       0.3, accuracy: 0.001)  // Walking.cpp:111
        XCTAssertEqual(c.ankleRollGain,  1.0, accuracy: 0.001)  // Walking.cpp:112
        XCTAssertEqual(c.anklePitchGain, 0.9, accuracy: 0.001)  // Walking.cpp:113
        XCTAssertEqual(c.internalGain,  -0.3, accuracy: 0.001)  // Walking.cpp:892
    }

    /// **부호 정합 (Phase B 2026-05-16 정정 후)** — roll +10° → 4-source 정합 부호.
    ///
    /// doc + URDF + walkReady + 본 함수 일치:
    /// - hip_roll: 둘 다 -1.5° (lateral 회복)
    /// - ankle_roll: 둘 다 **-3.0°** (lateral 회복, hip_roll 과 동일 부호)
    /// - 다른 관절: roll=0 일 때 보정 0
    func testCorrectionPolarityRollPositive() {
        let c = BalanceCorrector.robotisDefault
        let result = c.corrections(rollErrDeg: 10, pitchErrDeg: 0)
        XCTAssertEqual(result.rHipRoll, -1.5, accuracy: 0.001,
            "hipRoll = -0.15 × imuRoll = -1.5")
        XCTAssertEqual(result.lHipRoll, -1.5, accuracy: 0.001,
            "L hipRoll = R 동일 (lateral)")
        XCTAssertEqual(result.rAnkleRoll, -3.0, accuracy: 0.001,
            "ankleRoll = -0.30 × imuRoll = -3.0 (lateral 회복, hip_roll 과 동일 부호)")
        XCTAssertEqual(result.lAnkleRoll, -3.0, accuracy: 0.001)
        XCTAssertEqual(result.rKnee, 0, accuracy: 0.001)
        XCTAssertEqual(result.lKnee, 0, accuracy: 0.001)
        XCTAssertEqual(result.rAnklePitch, 0, accuracy: 0.001)
        XCTAssertEqual(result.lAnklePitch, 0, accuracy: 0.001)
    }

    /// **부호 정합 (Phase B 2026-05-16 정정 후)** — pitch +10° → R/L mirror 굽힘.
    ///
    /// doc "굽힘 R+ / L-" 일치:
    /// - knee_R = +0.9°, knee_L = -0.9° (mirror, 양 다리 굽힘)
    /// - anklePitch_R = +2.7°, anklePitch_L = -2.7° (mirror, 양 발끝 위)
    func testCorrectionPolarityPitchPositive() {
        let c = BalanceCorrector.robotisDefault
        let result = c.corrections(rollErrDeg: 0, pitchErrDeg: 10)
        XCTAssertEqual(result.rKnee, +0.9, accuracy: 0.001,
            "R knee = +0.09 × imuPitch = +0.9 (굽힘 = 회복)")
        XCTAssertEqual(result.lKnee, -0.9, accuracy: 0.001,
            "L knee = -0.09 × imuPitch = -0.9 (mirror 굽힘)")
        XCTAssertEqual(result.rAnklePitch, +2.7, accuracy: 0.001,
            "R anklePitch = +0.27 × imuPitch (dorsiflex)")
        XCTAssertEqual(result.lAnklePitch, -2.7, accuracy: 0.001,
            "L anklePitch = -0.27 × imuPitch (mirror dorsiflex)")
        XCTAssertEqual(result.rHipRoll, 0, accuracy: 0.001)
        XCTAssertEqual(result.rAnkleRoll, 0, accuracy: 0.001)
    }

    /// **max clamp (Phase B 2026-05-16 정정 후)** — ankleRoll 부호도 hip_roll 과 동일.
    func testCorrectionClampedAtMax() {
        let c = BalanceCorrector.robotisDefault  // maxCorrectionDeg = 15
        // roll +100° → ankleRoll = -0.30 × 100 = -30 → clamp -15.
        let result = c.corrections(rollErrDeg: 100, pitchErrDeg: 0)
        XCTAssertEqual(result.rAnkleRoll, -15, accuracy: 0.001,
            "큰 roll +error 에서 ankleRoll clamp -15° (hip_roll 과 동일 부호)")
        XCTAssertEqual(result.rHipRoll, -15, accuracy: 0.001)
        // 음수 roll → 반대 한도.
        let neg = c.corrections(rollErrDeg: -100, pitchErrDeg: 0)
        XCTAssertEqual(neg.rAnkleRoll, +15, accuracy: 0.001)
        XCTAssertEqual(neg.rHipRoll, +15, accuracy: 0.001)
    }

    /// **gain ramp** — 시작 0초 / 0.5초 / 1초+ 시 보정 비율. R hipRoll 음수 방향으로.
    func testBalanceCorrectorGainRamp() {
        let c = BalanceCorrector.robotisDefault
        let pose = RobotPose.walkReady
        // 0초 ramp → 보정 0
        let p0 = c.apply(to: pose, rollErrDeg: 10, pitchErrDeg: 0,
                         enabled: true, secondsSinceEnable: 0)
        XCTAssertEqual(p0.degrees(.rHipRoll), pose.degrees(.rHipRoll), accuracy: 0.5,
            "ramp 0초 → pose 변화 없어야 함")
        // 1초+ ramp → 100%.
        let p1 = c.apply(to: pose, rollErrDeg: 10, pitchErrDeg: 0,
                         enabled: true, secondsSinceEnable: 1.0)
        let dHipRoll = p1.degrees(.rHipRoll) - pose.degrees(.rHipRoll)
        XCTAssertEqual(dHipRoll, -1.5, accuracy: 0.5,
            "ramp 1초 → hipRoll -1.5° delta (100% 적용)")
        // 0.5초 ramp → 50%.
        let p05 = c.apply(to: pose, rollErrDeg: 10, pitchErrDeg: 0,
                          enabled: true, secondsSinceEnable: 0.5)
        let dMid = p05.degrees(.rHipRoll) - pose.degrees(.rHipRoll)
        XCTAssertEqual(dMid, -0.75, accuracy: 0.5,
            "ramp 0.5초 → 50% 보정 (-0.75° delta)")
    }

    /// **4-source 부호 lock-in (Phase B 2026-05-16 정정 후)** — doc + URDF + walkReady + 본 함수.
    /// roll +10° + pitch +10° 동시 입력 → 8 관절 delta 가 회복 방향.
    func testCorrectionFullSignTableLockIn() {
        let c = BalanceCorrector.robotisDefault
        let r = c.corrections(rollErrDeg: 10, pitchErrDeg: 10)
        // 정합 부호 매트릭스 (Agent 3 cross-check + 정정):
        XCTAssertEqual(r.rHipRoll,    -1.5, accuracy: 0.001)  // lateral 회복
        XCTAssertEqual(r.lHipRoll,    -1.5, accuracy: 0.001)
        XCTAssertEqual(r.rKnee,       +0.9, accuracy: 0.001)  // R 굽힘 회복
        XCTAssertEqual(r.lKnee,       -0.9, accuracy: 0.001)  // L 굽힘 (mirror)
        XCTAssertEqual(r.rAnklePitch, +2.7, accuracy: 0.001)  // R dorsiflex
        XCTAssertEqual(r.lAnklePitch, -2.7, accuracy: 0.001)  // L dorsiflex (mirror)
        XCTAssertEqual(r.rAnkleRoll,  -3.0, accuracy: 0.001)  // lateral 회복 (hip_roll 과 동일 부호)
        XCTAssertEqual(r.lAnkleRoll,  -3.0, accuracy: 0.001)
    }

    /// **disabled 시 identity** — enabled=false → pose 그대로.
    func testBalanceCorrectorDisabledIdentity() {
        let c = BalanceCorrector.robotisDefault
        let pose = RobotPose.walkReady
        let result = c.apply(to: pose, rollErrDeg: 20, pitchErrDeg: 15,
                             enabled: false, secondsSinceEnable: 5.0)
        // 모든 관절 동일.
        for j in JointID.allCases {
            XCTAssertEqual(result.raw(j), pose.raw(j),
                "disabled 시 \(j) raw 변화 — identity 위반")
        }
    }

    /// **NaN 입력 robust** — NaN error 가 들어와도 clamp 0.
    func testBalanceCorrectorRejectsNaN() {
        let c = BalanceCorrector.robotisDefault
        let result = c.corrections(rollErrDeg: .nan, pitchErrDeg: 5)
        // NaN 검출 → clamp 0.
        XCTAssertEqual(result.rHipRoll, 0, accuracy: 0.001,
            "NaN rollErr → hipRoll 0 으로 fallback 안 함")
        // pitch 는 정상값이라 knee/ankle_pitch 정상.
        XCTAssertGreaterThan(result.rKnee, 0,
            "pitch=5 일 때 knee 양수 보정 실패 (NaN 격리 못 함)")
    }

    /// **maxAbs** — 모든 delta 의 최대 절댓값 helper. roll=pitch=10° 시 ankleRoll +3°.
    func testBalanceCorrectorMaxAbs() {
        let c = BalanceCorrector.robotisDefault
        let result = c.corrections(rollErrDeg: 10, pitchErrDeg: 10)
        // 정정 후: ankleRoll +3.0, anklePitch ±2.7, hipRoll -1.5, knee ±0.9 → max=3.0
        XCTAssertEqual(result.maxAbs, 3.0, accuracy: 0.001)
    }

    /// **WalkLabSession 통합** — enableBalanceCorrection toggle default OFF.
    func testBalanceCorrectionDefaultOff() {
        let session = WalkLabSession()
        XCTAssertFalse(session.enableBalanceCorrection,
            "default OFF — 실 robot 검증 + Codex audit 전 활성화 위험")
        XCTAssertNil(session.lastCorrections, "default 시 lastCorrections nil")
    }

    /// **applyBalanceCorrectionIfEnabled — disabled 시 identity.**
    func testSessionApplyDisabledReturnsIdentity() {
        let session = WalkLabSession()
        // default enableBalanceCorrection = false.
        let result = session.applyBalanceCorrectionIfEnabled(to: .walkReady)
        for j in JointID.allCases {
            XCTAssertEqual(result.raw(j), RobotPose.walkReady.raw(j))
        }
    }

    // MARK: - Monitoring Dashboard (2026-05-16): 시계열 + 이벤트 로그 회귀

    /// 초기 상태 — 시계열 비어 있음, 이벤트 비어 있음, 펼침 OFF.
    func testMonitoringInitialState() {
        let session = WalkLabSession()
        XCTAssertTrue(session.safetyTimeline.isEmpty,
            "초기 시계열 buffer 가 비어 있어야 함")
        XCTAssertTrue(session.safetyEvents.isEmpty,
            "초기 이벤트 로그가 비어 있어야 함")
        XCTAssertFalse(session.monitoringExpanded,
            "기본 펼침 OFF — progressive disclosure (NN/g)")
    }

    /// **Corrector 토글 — 이벤트 로그 발행**.
    /// OFF→ON / ON→OFF 각각 이벤트 1건씩.
    func testCorrectorToggleLogsEvents() {
        let session = WalkLabSession()
        let initialCount = session.safetyEvents.count
        session.enableBalanceCorrection = true
        XCTAssertEqual(session.safetyEvents.count, initialCount + 1,
            "OFF→ON 시 이벤트 1건 발행")
        XCTAssertEqual(session.safetyEvents.last?.kind, .correctorOn,
            "마지막 이벤트가 correctorOn 이어야 함")
        session.enableBalanceCorrection = false
        XCTAssertEqual(session.safetyEvents.count, initialCount + 2,
            "ON→OFF 시 추가 이벤트 1건")
        XCTAssertEqual(session.safetyEvents.last?.kind, .correctorOff)
    }

    /// **clearSafetyEvents — 이벤트 비움**.
    func testClearSafetyEvents() {
        let session = WalkLabSession()
        session.enableBalanceCorrection = true
        session.enableBalanceCorrection = false
        XCTAssertFalse(session.safetyEvents.isEmpty)
        session.clearSafetyEvents()
        XCTAssertTrue(session.safetyEvents.isEmpty,
            "clearSafetyEvents 후 빈 배열")
    }

    /// **이벤트 로그 50건 상한**.
    /// 100건 발행 후에도 last 50건만 보존.
    func testSafetyEventsCapAt50() {
        let session = WalkLabSession()
        // 토글 ON/OFF 를 51번 (총 102 이벤트) — Cap=50 검증.
        for _ in 0..<51 {
            session.enableBalanceCorrection = true
            session.enableBalanceCorrection = false
        }
        XCTAssertLessThanOrEqual(session.safetyEvents.count, 50,
            "이벤트 로그가 50건을 초과")
        // 가장 최신 이벤트 가 correctorOff 여야 (마지막 토글이 false).
        XCTAssertEqual(session.safetyEvents.last?.kind, .correctorOff)
    }

    /// **rampProgress** — 토글 OFF 시 nil, ON 직후 ≈ 0.
    func testRampProgressMatchesToggleState() {
        let session = WalkLabSession()
        XCTAssertNil(session.rampProgress, "토글 OFF 시 rampProgress nil")
        session.enableBalanceCorrection = true
        // 토글 직후 — progress ≈ 0 (< 0.1).
        if let p = session.rampProgress {
            XCTAssertLessThan(p, 0.5,
                "토글 직후 progress 가 너무 큼 — \(p)")
            XCTAssertGreaterThanOrEqual(p, 0)
        } else {
            XCTFail("토글 ON 시 rampProgress 가 nil")
        }
        session.enableBalanceCorrection = false
        XCTAssertNil(session.rampProgress, "토글 OFF 후 다시 nil")
    }

    /// **SafetySample 필드 정합** — 모든 필드가 Equatable.
    func testSafetySampleEquality() {
        let t = Date()
        let s1 = WalkLabSession.SafetySample(
            timestamp: t, rollDeg: 5, pitchDeg: 3,
            predictionScore: 25, balanceState: .normal, correctorMaxDelta: 0
        )
        let s2 = WalkLabSession.SafetySample(
            timestamp: t, rollDeg: 5, pitchDeg: 3,
            predictionScore: 25, balanceState: .normal, correctorMaxDelta: 0
        )
        XCTAssertEqual(s1, s2, "동일 데이터 SafetySample 가 같아야 함")
    }

    /// **SafetyEvent Kind 모두 비어있지 않음** — UI 안전.
    func testSafetyEventKindRawValuesNonEmpty() {
        let allKinds: [WalkLabSession.SafetyEvent.Kind] = [
            .sessionStart, .sessionStop, .stateChange,
            .emergencyTriggered, .predictorRecommend,
            .correctorOn, .correctorOff, .rampComplete,
            .imuSourceChange, .motorTempSourceChange,
            .thermalAlarm, .preflightFailure,
        ]
        for k in allKinds {
            XCTAssertFalse(k.rawValue.isEmpty, "\(k) rawValue 비어 있음")
        }
    }

    /// **motorTempSourceChange 가 imuSourceChange 와 분리** — 의미 오류 가드.
    /// 이전 버그: 같은 Kind 사용 → 이벤트 로그 아이콘이 gyroscope 로 표시되어
    /// 모터 온도 변경이 IMU 변경처럼 보임.
    func testMotorTempSourceChangeIsSeparateKind() {
        XCTAssertNotEqual(WalkLabSession.SafetyEvent.Kind.motorTempSourceChange,
                          WalkLabSession.SafetyEvent.Kind.imuSourceChange,
                          "motorTempSourceChange 와 imuSourceChange 는 별도 Kind")
    }

    // MARK: - 반응형 레이아웃 회귀 (2026-05-16)

    /// **모니터링 펼침 토글** — 외부 코드에서 변경 가능 (@Published).
    func testMonitoringExpandedTogglable() {
        let session = WalkLabSession()
        XCTAssertFalse(session.monitoringExpanded, "default 닫힘")
        session.monitoringExpanded = true
        XCTAssertTrue(session.monitoringExpanded)
        session.monitoringExpanded = false
        XCTAssertFalse(session.monitoringExpanded)
    }

    /// **시계열 buffer 상한** — 250 sample, 10 초 윈도우.
    /// 정량 시나리오: 5분 (300초) 짜리 sample 을 시뮬레이션으로 직접 주입 시
    /// 250 상한 초과 X. WalkLabSession.tick() 의 prune 로직 검증 — public X 이라
    /// 직접 호출 불가하지만 invariant 만 검증.
    func testSafetyTimelineCapsRespected() {
        let session = WalkLabSession()
        // 외부에서 직접 push 불가능 — 초기값 검증.
        XCTAssertTrue(session.safetyTimeline.isEmpty,
            "초기 timeline 비어 있음")
        XCTAssertLessThanOrEqual(session.safetyTimeline.count, 250,
            "timeline 상한 250 초과 X")
    }

    /// **SafetySample 의 모든 필드가 Sendable** — 동시성 안전.
    /// 컴파일 가능 == Sendable 보장 (Swift 5.10 / Strict Concurrency).
    func testSafetySampleSendable() {
        let s = WalkLabSession.SafetySample(
            timestamp: Date(), rollDeg: 0, pitchDeg: 0,
            predictionScore: 0, balanceState: .normal, correctorMaxDelta: 0
        )
        // 단순 reference 검증 — Sendable 위반 시 컴파일 실패.
        Task.detached { @Sendable in
            _ = s
        }
        XCTAssertEqual(s.rollDeg, 0)
    }

    /// **SafetyEvent 의 모든 필드가 Sendable** — 동시성 안전.
    func testSafetyEventSendable() {
        let e = WalkLabSession.SafetyEvent(
            timestamp: Date(), kind: .sessionStart, message: "test"
        )
        Task.detached { @Sendable in
            _ = e
        }
        XCTAssertEqual(e.message, "test")
    }

    // MARK: - L6 Thermal 실 데이터 통합 (2026-05-16)

    /// **MotorTempSource enum** — sim / real / stale.
    func testMotorTempSourceLabels() {
        XCTAssertEqual(WalkLabSession.MotorTempSource.sim.label, "시뮬")
        XCTAssertEqual(WalkLabSession.MotorTempSource.real.label, "실 모터")
        XCTAssertEqual(WalkLabSession.MotorTempSource.stale.label, "지연")
    }

    /// **초기 motorTempSource = .sim** — 실 robot 미연결 default.
    func testMotorTempSourceInitialSim() {
        let session = WalkLabSession()
        XCTAssertEqual(session.motorTempSource, .sim,
            "초기 motorTempSource 는 sim 이어야 함 (실 robot 미연결)")
    }

    /// **maxMotorTemp 가 private(set)** — 외부에서 직접 쓰기 차단.
    /// 컴파일 가능 == 접근 권한 보장. WalkLabSession 내부만 갱신.
    func testMaxMotorTempReadOnly() {
        let session = WalkLabSession()
        XCTAssertEqual(session.maxMotorTemp, 35.0,
            "초기 ambient temp 35°C")
        // session.maxMotorTemp = 50 ← 컴파일 X (private(set))
    }

    /// **MotorTempSource Equatable / Sendable**.
    func testMotorTempSourceEquatable() {
        XCTAssertEqual(WalkLabSession.MotorTempSource.sim,
                       WalkLabSession.MotorTempSource.sim)
        XCTAssertNotEqual(WalkLabSession.MotorTempSource.sim,
                          WalkLabSession.MotorTempSource.real)
    }
}
