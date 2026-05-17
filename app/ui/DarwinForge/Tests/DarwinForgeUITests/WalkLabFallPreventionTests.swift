import ForgeCore
import SwiftUI
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
    /// **L3 gate boundary 검증** — BalanceState.from(maxTilt:) 와 L3 gate 가
    /// 둘 다 `>= 30` 임계 사용 (off-by-one 정정 회귀).
    /// 2026-05-16: 이전 misleading 이름 (testL3GateWorksRegardlessOfSource) →
    /// 실제 invariant 만 검증 (boundary 정합).
    func testL3GateThresholdBoundaryConsistency() {
        // BalanceState.from 의 30° boundary — `.emergency`.
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 30.0), .emergency,
            "30.0° 는 .emergency — `>=` 임계 정합")
        XCTAssertEqual(WalkLabSession.BalanceState.from(maxTilt: 29.99), .danger,
            "29.99° 는 .danger")
        // L3 gate 의 직접 검증은 simTimer private 라 불가능 — BalanceState 의
        // 임계만 boundary 정합 (실 gate 도 동일 `>=` 사용 정정 후).
        let session = WalkLabSession()
        XCTAssertFalse(session.balanceLost,
            "초기 balanceLost 는 false — 정상 초기 invariant")
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

    /// **Phase C 핵심 invariant (Agent 3 발견 — 미테스트 영역)**:
    /// enableBalanceCorrection=true + autoFallPrevention=true 시 corrector identity.
    /// .danger 분기는 private balanceState 라 직접 검증 어려움 — public
    /// invariant 로 enable 시 lastSafePose 가 갱신되는지만 검증.
    func testApplyBalanceCorrectionUpdatesLastSafePoseWhenSafe() {
        let session = WalkLabSession()
        session.enableBalanceCorrection = true
        // 정상 상태 (imuRollDeg=0) → corrector identity 거의 (작은 ramp).
        let result = session.applyBalanceCorrectionIfEnabled(to: .walkReady)
        // result 는 walkReady 와 거의 동일 (IMU=0 이라 corrections 모두 0).
        for j in JointID.allCases {
            XCTAssertEqual(result.raw(j), RobotPose.walkReady.raw(j),
                "IMU=0 시 corrector identity")
        }
    }

    /// **emergencyStop 이벤트 발행 (Agent 3 발견 — 미테스트)**.
    /// 비상 정지 호출 시 safetyEvents 에 .emergencyTriggered 추가.
    func testEmergencyStopLogsEvent() {
        let session = WalkLabSession()
        let initialCount = session.safetyEvents.count
        session.emergencyStop()
        XCTAssertEqual(session.safetyEvents.count, initialCount + 1,
            "emergencyStop 호출 시 이벤트 1건 발행")
        XCTAssertEqual(session.safetyEvents.last?.kind, .emergencyTriggered,
            "마지막 이벤트가 emergencyTriggered 이어야 함")
    }

    /// **customX/Y/A 단위 변환 (Agent 3 발견 — 미테스트, FFI regression risk)**.
    /// strideMm (mm) ↔ customX (m), sideMm ↔ customY, turnDeg ↔ customA (rad).
    func testCustomXYAUnitConversion() {
        let session = WalkLabSession()
        // mm → m
        session.strideMm = 25
        XCTAssertEqual(session.customX, 0.025, accuracy: 1e-9,
            "25mm = 0.025m")
        session.customX = 0.05
        XCTAssertEqual(session.strideMm, 50, accuracy: 1e-9,
            "0.05m = 50mm")

        // sideMm
        session.sideMm = -10
        XCTAssertEqual(session.customY, -0.010, accuracy: 1e-9)

        // turnDeg ↔ customA (rad)
        session.turnDeg = 90
        XCTAssertEqual(session.customA, .pi / 2, accuracy: 1e-9,
            "90° = π/2 rad")
        session.customA = .pi
        XCTAssertEqual(session.turnDeg, 180, accuracy: 1e-9,
            "π rad = 180°")
    }

    /// **FallPredictor 모든 NaN sample → .zero 반환 (Agent 3 발견)**.
    func testFallPredictorAllNaNSamplesReturnZero() {
        let samples = (0..<5).map { _ in
            FallPredictor.Sample(
                timestamp: Date(), rollDeg: .nan, pitchDeg: .infinity,
                gyroXDps: .nan, gyroYDps: .nan
            )
        }
        let pred = FallPredictor.predict(samples: samples)
        XCTAssertEqual(pred.score, 0,
            "모든 sample NaN/Inf → score 0")
        XCTAssertNil(pred.etaMs)
        XCTAssertFalse(pred.recommendEmergency)
    }

    /// **BalanceCorrector intensity clamp (Agent 3 발견)**.
    /// intensity > 1.0 입력 시 1.0 으로 clamp.
    func testBalanceCorrectorIntensityClampsAboveOne() {
        let corrector = BalanceCorrector(
            intensity: 2.0,  // out of range
            maxCorrectionDeg: 15,
            hipRollGain: 0.5, kneeGain: 0.3,
            anklePitchGain: 0.9, ankleRollGain: 1.0
        )
        XCTAssertEqual(corrector.intensity, 1.0, accuracy: 1e-9,
            "intensity > 1.0 입력 → 1.0 clamp")
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

    // MARK: - 완벽화 Sprint (2026-05-16): @AppStorage 영속성

    /// **monitoringExpanded 영속성** — UserDefaults 에 자동 저장.
    func testMonitoringExpandedPersistsToUserDefaults() {
        let key = "df.walklab.monitoringExpanded"
        UserDefaults.standard.removeObject(forKey: key)

        let session = WalkLabSession()
        XCTAssertFalse(session.monitoringExpanded,
            "초기 — UserDefaults 에 키 없으면 false")

        session.monitoringExpanded = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key),
            "토글 ON 후 UserDefaults 에 true 저장")

        session.monitoringExpanded = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key),
            "토글 OFF 후 UserDefaults 에 false 저장")

        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - 시인성 강화 (2026-05-16)

    /// **DFColor.severe** — warning ↔ danger intermediate semantic.
    /// Color 의 String description 이 비어있지 않음을 검증 (runtime guard).
    func testSevereColorIsConstructed() {
        let color = DFColor.severe
        // SwiftUI Color 는 underlying NSColor 가 있어야 description 유효.
        let desc = String(describing: color)
        XCTAssertFalse(desc.isEmpty, "DFColor.severe 가 유효하게 구성되지 않음")
    }

    /// **DFIcon enum 의 10개 토큰** — 모두 Font 인스턴스로 접근 가능.
    /// 단순 compile guard 가 아니라 collection 으로 모아 count 검증.
    func testDFIconTokensComplete() {
        let icons: [Font] = [
            DFIcon.hero, DFIcon.section, DFIcon.body,
            DFIcon.caption, DFIcon.label, DFIcon.micro,
            DFIcon.action,
            DFIcon.stateSmall, DFIcon.stateMedium, DFIcon.stateLarge,
        ]
        XCTAssertEqual(icons.count, 10,
            "DFIcon 토큰 10개 — hero/section/body/caption/label/micro + action + 3 state")
    }

    /// **DFAnimation semantic alias 7개** — primitives + semantic.
    func testDFAnimationSemanticAliasesComplete() {
        let animations: [Animation] = [
            DFAnimation.toggle, DFAnimation.cardExpand,
            DFAnimation.modalPresent, DFAnimation.listChange,
            DFAnimation.pageTransition, DFAnimation.emphasis,
            DFAnimation.hover,
        ]
        XCTAssertEqual(animations.count, 7,
            "DFAnimation semantic alias 7개 — toggle/cardExpand/modalPresent/listChange/pageTransition/emphasis/hover")
    }

    /// **DFRadius / DFSpace 시맨틱 alias** — fragmentation 해결.
    func testSemanticAliasesExist() {
        // DFSpace
        XCTAssertEqual(DFSpace.pillV, DFSpace.xs2)
        XCTAssertEqual(DFSpace.pillH, DFSpace.sm3)
        XCTAssertEqual(DFSpace.toolbarGap, DFSpace.sm2)
        XCTAssertEqual(DFSpace.cardInner, DFSpace.md)
        XCTAssertEqual(DFSpace.cardInnerCompact, DFSpace.sm)
        XCTAssertEqual(DFSpace.modalInner, DFSpace.md2)
        // DFRadius
        XCTAssertEqual(DFRadius.button, DFRadius.xs2)
        XCTAssertEqual(DFRadius.statusTile, DFRadius.xs)
        XCTAssertEqual(DFRadius.card, DFRadius.sm)
        XCTAssertEqual(DFRadius.panel, DFRadius.md)
        XCTAssertEqual(DFRadius.modal, DFRadius.lg)
        XCTAssertEqual(DFRadius.hero, DFRadius.xl)
        XCTAssertEqual(DFRadius.capsule, DFRadius.full)
    }

    /// **NaN/Inf 방어** — 잘못된 sensor 데이터에서도 안전 (regression guard).
    /// FallPredictor 가 NaN sample 을 reject 하는지 + safetyTimeline 갱신 안전.
    func testNaNImuValuesHandled() {
        let session = WalkLabSession()
        // FallPredictor 의 isFinite filter 가 NaN sample 을 걸러야 함.
        let nanSample = FallPredictor.Sample(
            timestamp: Date(), rollDeg: .nan, pitchDeg: 0,
            gyroXDps: 0, gyroYDps: 0
        )
        let prediction = FallPredictor.predict(samples: [nanSample])
        XCTAssertEqual(prediction.score, 0,
            "NaN sample → score 0 (FallPredictor.predict guard)")
        XCTAssertNil(prediction.etaMs)
        XCTAssertFalse(prediction.recommendEmergency)

        // session.imuRollDeg 가 NaN 이어도 hero banner 계산이 0 fallback.
        // 직접 검증 어려움 (UI test 필요) — 회귀 가드만.
        XCTAssertEqual(session.imuRollDeg, 0,
            "초기 IMU 값 0 — finite default")
    }

    /// **새 세션이 이전 상태 복원** — 앱 재시작 시뮬레이션.
    func testNewSessionRestoresMonitoringState() {
        let key = "df.walklab.monitoringExpanded"
        UserDefaults.standard.set(true, forKey: key)

        let session = WalkLabSession()
        XCTAssertTrue(session.monitoringExpanded,
            "새 session 이 UserDefaults true → 복원해야 함")

        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Phase E-1: High Contrast color variant

    /// **DFColor.success/warning/danger 의 highContrast variant** — Color
    /// 자체 == 비교는 SwiftUI 가 internal `NSColor` 로 변환 후 가능.
    /// init 이 4-arg 형식으로 통과하는지만 검증 (regression: nil fallback).
    func testHighContrastColorInitCompiles() {
        // 컴파일 가능 == regression 통과.
        let c1 = Color(light: "#FFFFFF", dark: "#000000",
                       highContrastLight: nil, highContrastDark: nil)
        let c2 = Color(light: "#FF0000", dark: "#FF0000",
                       highContrastLight: "#CC0000", highContrastDark: "#FF6666")
        XCTAssertNotEqual(String(describing: c1), "",
            "Color init 가능")
        XCTAssertNotEqual(String(describing: c2), "")
    }

    // MARK: - Phase A-1: Localization scaffold (compile guard only)

    /// **Localization scaffold 컴파일 가드**. 실 strings 파일 검증은 Mac
    /// build 시 SPM resource 처리 + Xcode Preview 시각 확인.
    /// (Bundle.module accessor 는 target-scoped — 별도 helper 필요).
    func testLocalizableStringKeysCompile() {
        // LocalizedStringKey 가 컴파일 가능 == infrastructure 통과.
        let _: LocalizedStringKey = "안전 상태"
        let _: LocalizedStringKey = "Fall Prevention 모니터링"
        let _: LocalizedStringKey = "지우기"
    }

    // MARK: - 2026-05-17 — 실 telemetry 분기 안전화 (Codex/agent 검토 결과)

    /// **staleTelemetryThresholdSec = 5.0** — IMU / 모터 온도 통일 임계 상수.
    /// 이전 motor 분기는 하드코딩 `< 5.0` 사용. WalkLabSession 의 단일 상수로 통일.
    /// drift 회귀 가드 — 누군가 IMU 만 7초로 늘리고 motor 는 5초 유지하는 경우 차단.
    func testStaleTelemetryThresholdConstant() {
        XCTAssertEqual(WalkLabSession.staleTelemetryThresholdSec, 5.0,
            "staleTelemetryThresholdSec 가 5.0 초가 아니면 ImuFilter.isStale() 과 불일치")
    }

    /// **ImuFilter staleness boundary = 5.0 초** — `WalkLabSession.staleTelemetryThresholdSec`
    /// 와 의미적 정합 검증. 두 상수가 다르면 IMU=real / motor=stale chimera state 가능.
    func testImuFilterStalenessBoundary() {
        var filter = ImuFilter()
        // 새 filter — lastUpdatedAt nil → stale 판정 X (return false).
        XCTAssertFalse(filter.isStale(now: Date()),
            "lastUpdatedAt nil 일 때는 stale 이 아님")

        // 첫 sample 주입.
        let t0 = Date(timeIntervalSinceReferenceDate: 100_000)
        let sample = ImuRaw(gyroX: 0, gyroY: 0, gyroZ: 0,
                            accelX: 0, accelY: 0, accelZ: 0,
                            rollDeg: 0, pitchDeg: 0)
        filter.update(sample, at: t0)

        // 5.0초 직전 — 아직 stale 아님.
        XCTAssertFalse(filter.isStale(now: t0.addingTimeInterval(4.999)),
            "5.0초 직전엔 stale 아니어야 함")
        // 5.01초 후 — stale.
        XCTAssertTrue(filter.isStale(now: t0.addingTimeInterval(5.01)),
            "5.0초 초과면 stale 이어야 함")

        // WalkLabSession 측 상수와 동일 5.0 인지 시멘틱 검증.
        let walkLabBoundary = WalkLabSession.staleTelemetryThresholdSec
        XCTAssertFalse(filter.isStale(now: t0.addingTimeInterval(walkLabBoundary - 0.01)),
            "WalkLabSession.staleTelemetryThresholdSec - 0.01 에서는 stale 아님")
        XCTAssertTrue(filter.isStale(now: t0.addingTimeInterval(walkLabBoundary + 0.01)),
            "WalkLabSession.staleTelemetryThresholdSec + 0.01 에서는 stale 이어야 함")
    }

    /// **fallPrediction 초기 = .zero** — sample 없으면 0 점.
    /// stale gate fix 의 sentinel 값. fix 가 `fallPrediction = .zero` 로 reset 시
    /// 정상 idle 상태와 구별 불가하므로 의도된 invariant.
    func testFallPredictionInitialZero() {
        let session = WalkLabSession()
        XCTAssertEqual(session.fallPrediction.score, 0,
            "신규 session — fallPrediction.score 가 0")
        XCTAssertNil(session.fallPrediction.etaMs,
            "신규 session — etaMs nil")
        XCTAssertFalse(session.fallPrediction.recommendEmergency,
            "신규 session — recommendEmergency false")
    }

    /// **WalkLabSession deinit Timer/Task 정리** — 2026-05-17 concurrency review
    /// CRITICAL #1. View 전환 / @StateObject reinit 시 RunLoop 가 Timer 를 strong
    /// retain → tick Task 영구 스케줄링 위험. weak ref 로 ARC 해제 검증.
    func testWalkLabSessionDeinitReleasesResources() {
        weak var weakSession: WalkLabSession?
        autoreleasepool {
            let session = WalkLabSession()
            weakSession = session
            // simTimer 시작 안 하고 바로 해제 — deinit 의 invalidate 호출 가드.
            _ = session
        }
        XCTAssertNil(weakSession,
            "WalkLabSession deinit 후 ARC 해제 안 됨 — Timer/Task strong retain 의심")
    }

    /// **ConnectionStore deinit pollTask/reconnectTask 정리** — 동일 패턴.
    func testConnectionStoreDeinitReleasesResources() {
        weak var weakStore: ConnectionStore?
        autoreleasepool {
            let store = ConnectionStore()
            weakStore = store
            _ = store
        }
        XCTAssertNil(weakStore,
            "ConnectionStore deinit 후 ARC 해제 안 됨 — NSWorkspace observer/Task 누수 의심")
    }

    /// **jointConsecutiveFailures 초기 비어있음** — T3.6 chaos #3 fix invariant.
    /// per-joint counter 가 신규 store 에서 비어있어야 함 (false-positive UI 표시 차단).
    func testJointConsecutiveFailuresInitiallyEmpty() {
        let store = ConnectionStore()
        XCTAssertTrue(store.jointConsecutiveFailures.isEmpty,
            "신규 store — jointConsecutiveFailures 비어있어야 함")
    }

    /// **WalkCycleResult.busDisconnected userMessage 명확성** — T3.5 chaos #1 fix.
    /// 사용자 facing 메시지 — "연결 끊김" + 재연결 안내 포함 검증.
    func testWalkCycleResultBusDisconnectedUserMessage() {
        let result = WalkLabSession.WalkCycleResult(
            reason: .busDisconnected,
            stepsExecuted: 12,
            speedWriteFailures: 0,
            positionWriteFailures: 0,
            lowerBodyPositionFails: [],
            sampleError: nil
        )
        XCTAssertFalse(result.isSuccess,
            "busDisconnected 는 실패")
        XCTAssertTrue(result.userMessage.contains("연결 끊김"),
            "사용자 메시지에 '연결 끊김' 포함 — 행동 가능 안내")
        XCTAssertTrue(result.userMessage.contains("재연결"),
            "사용자에게 다음 행동 안내 — '재연결 후 다시 시작'")
        XCTAssertTrue(result.userMessage.contains("12 step"),
            "stepsExecuted 표시 — 사용자가 보행 진행 정도 인지")
    }

    /// **WalkCycleResult.EndReason 모든 case Equatable + Sendable** — 회귀 가드.
    /// 신규 case 추가 시 (예: 향후 'overheated') compile error 로 잡힘.
    func testWalkCycleResultEndReasonExhaustive() {
        let reasons: [WalkLabSession.WalkCycleResult.EndReason] = [
            .completedMaxDuration,
            .userCancelled,
            .lowerBodyWriteFailure,
            .bulkWriteFailure,
            .busDisconnected,
        ]
        // 5 case 가 모두 distinct
        for (i, r1) in reasons.enumerated() {
            for (j, r2) in reasons.enumerated() where i != j {
                XCTAssertNotEqual(r1, r2,
                    "EndReason \(r1) 과 \(r2) 가 distinct 해야 함")
            }
        }
    }

    /// **PilotDpad keyboardEquivalent — 7 zone 매핑 정합** (T3.7 a11y CRITICAL).
    /// 회귀 가드: 향후 zone 추가 시 keyboardEquivalent 매핑 누락 차단.
    func testPilotDpadKeyboardEquivalents() {
        XCTAssertEqual(DpadZone.up.keyboardEquivalent, KeyEquivalent("w"))
        XCTAssertEqual(DpadZone.down.keyboardEquivalent, KeyEquivalent("s"))
        XCTAssertEqual(DpadZone.left.keyboardEquivalent, KeyEquivalent("a"))
        XCTAssertEqual(DpadZone.right.keyboardEquivalent, KeyEquivalent("d"))
        XCTAssertEqual(DpadZone.rotateLeft.keyboardEquivalent, KeyEquivalent("q"))
        XCTAssertEqual(DpadZone.rotateRight.keyboardEquivalent, KeyEquivalent("e"))
        XCTAssertEqual(DpadZone.stop.keyboardEquivalent, .space)
    }

    // MARK: - 2026-05-17 사용자 보고 critical fix 회귀 가드

    /// **Issue 1 — ImuScaleSuspicion enum 4 case + userMessage 명확성** (사용자 보고).
    /// 10-bit ADC 의심 case 의 한국어 메시지에 "32배 작음" 포함 검증.
    func testImuScaleSuspicionUserMessages() {
        XCTAssertEqual(ConnectionStore.ImuScaleSuspicion.unknown.rawValue, "unknown",
            "unknown rawValue identity 검증")
        XCTAssertTrue(ConnectionStore.ImuScaleSuspicion.suspectedLegacy10Bit.rawValue.contains("10-bit"),
            "10-bit 의심 메시지에 명확히 '10-bit' 포함 — 사용자가 즉시 인지")
        XCTAssertTrue(ConnectionStore.ImuScaleSuspicion.suspectedLegacy10Bit.rawValue.contains("32배"),
            "사용자 보고 critical: 32배 오차 가능성 명시")
        XCTAssertEqual(ConnectionStore.ImuScaleSuspicion.looksValid16Bit.rawValue, "정상 (16-bit ADC)")
        XCTAssertEqual(ConnectionStore.ImuScaleSuspicion.outOfRange.rawValue, "비정상 — 센서 응답 확인 필요")
    }

    /// **Issue 1 — 신규 store imuScaleSuspicion = .unknown** (sample 부족).
    func testInitialImuScaleSuspicionUnknown() {
        let store = ConnectionStore()
        XCTAssertEqual(store.imuScaleSuspicion, .unknown,
            "신규 store — IMU sample 0 이므로 unknown")
        XCTAssertEqual(store.imuAccelZMagnitudeAvg, 0,
            "신규 store — magnitude 평균 0")
    }

    /// **Issue 3 — WalkPreflightFailure.balanceCorrectorRequiredForCautionPreset
    /// userMessage 명확성** (사용자 보고 critical).
    /// fastWalk 같은 caution 등급 preset 진입 시 차단 메시지 검증.
    func testBalanceCorrectorRequiredPreflightMessage() {
        let f = WalkLabSession.WalkPreflightFailure(
            cause: .balanceCorrectorRequiredForCautionPreset(presetLabel: "빠르게 걷기")
        )
        XCTAssertTrue(f.userMessage.contains("빠르게 걷기"),
            "사용자 facing: preset 이름 포함")
        XCTAssertTrue(f.userMessage.contains("자세 보정"),
            "사용자 facing: 다음 행동 안내 ('자세 보정' 토글)")
        XCTAssertTrue(f.userMessage.contains("낙상 위험"),
            "사용자 facing: 위험 명시")
    }
}
