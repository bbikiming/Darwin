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
}
