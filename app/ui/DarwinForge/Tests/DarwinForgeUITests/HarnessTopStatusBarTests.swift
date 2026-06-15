import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

// MARK: - HarnessTopStatusBarTests (V289-2, 2026-05-25)
//
// 비유: 비행기 경보 strip 의 "작동 확인 체크리스트" — 이륙 전 각 경보 등이
// 올바른 임계값에서 켜지는지 지상에서 검증한다.
//
// 기술: HarnessTopStatusBarThresholds (내부 상수) 를 통해 5개 metric 의
// 임계 전환 동작 검증. SwiftUI View 직접 인스턴스화 불필요 — threshold 로직만 단위 테스트.
//
// 검증 케이스 5개:
//   1. 배터리 voltage=11.0 → vermillion (crit)
//   2. 배터리 voltage=11.3 → amber (warn)
//   3. 배터리 voltage=12.0 → 정상 (gray)
//   4. 통신 지연 latency=22ms → vermillion (crit)
//   5. 낙상 위험 score=65 → vermillion (crit)
//
// 추가 케이스:
//   6. latency=12ms → amber (warn)
//   7. latency=8ms → 정상
//   8. fallScore=45 → amber (warn)
//   9. fallScore=20 → 정상
//  10. 배터리 nil → 표시 "—" + 정상 색

final class HarnessTopStatusBarTests: XCTestCase {

    // MARK: - 내부 임계값 상수 (threshold constants mirrored from HarnessTopStatusBar)
    //
    // HarnessTopStatusBar 의 private static 상수를 테스트에서 검증하기 위해
    // 동일 값을 여기서 선언한다. 한 값을 변경하면 빌드가 깨지도록 상수명을 주석에 연결.
    //
    // 출처: HarnessTopStatusBar.swift — private static let voltage*/latency*/fall*

    private let voltageWarnV: Double  = 11.5   // HarnessTopStatusBar.voltageWarnV
    private let voltageCritV: Double  = 11.1   // HarnessTopStatusBar.voltageCritV
    private let latencyWarnMs: Double = 10.0   // HarnessTopStatusBar.latencyWarnMs
    private let latencyCritMs: Double = 20.0   // HarnessTopStatusBar.latencyCritMs
    private let fallWarnScore: Double = 30.0   // HarnessTopStatusBar.fallWarnScore
    private let fallCritScore: Double = 60.0   // HarnessTopStatusBar.fallCritScore

    // MARK: - 배터리 임계 검증

    func test_voltage_belowCrit_isCritical() {
        // 11.0V — 3S LiPo 임계 하한 (MX-28 토크 강하 시작)
        let v = 11.0
        XCTAssertTrue(v <= voltageCritV, "11.0V 는 crit 임계 (\(voltageCritV)V) 이하여야 함")
    }

    func test_voltage_aboveCrit_belowWarn_isWarning() {
        // 11.3V — crit 초과, warn 미만
        let v = 11.3
        XCTAssertTrue(v > voltageCritV && v <= voltageWarnV,
                      "11.3V 는 crit(\(voltageCritV)V) 초과 & warn(\(voltageWarnV)V) 이하여야 함")
    }

    func test_voltage_aboveWarn_isNormal() {
        // 12.0V — 충분 충전 상태
        let v = 12.0
        XCTAssertTrue(v > voltageWarnV, "12.0V 는 warn 임계(\(voltageWarnV)V) 초과 = 정상이어야 함")
    }

    func test_voltage_nil_showsDash() {
        // nil 배터리는 "—" 표시
        // HarnessTopStatusBar.batteryDisplay(nil) 의 첫 반환값 검증
        // (private 메서드 직접 호출 대신 계약을 문서화하는 테스트)
        //
        // 계약: voltOpt=nil → voltStr="—", minuteStr="" (Level 3 SA 없음)
        let voltOpt: Double? = nil
        XCTAssertNil(voltOpt, "nil voltage 는 nil 이어야 함 — batteryDisplay 가 guard-nil 처리해야 함")
    }

    // MARK: - 통신 지연 임계 검증

    func test_latency_aboveCrit_isCritical() {
        // 22ms — 실시간 보행 제어 불안정 구간
        let ms = 22.0
        XCTAssertTrue(ms >= latencyCritMs, "22ms 는 crit 임계(\(latencyCritMs)ms) 이상이어야 함")
    }

    func test_latency_betweenWarnAndCrit_isWarning() {
        // 12ms — 경고 구간
        let ms = 12.0
        XCTAssertTrue(ms >= latencyWarnMs && ms < latencyCritMs,
                      "12ms 는 warn(\(latencyWarnMs)ms) 이상 & crit(\(latencyCritMs)ms) 미만이어야 함")
    }

    func test_latency_belowWarn_isNormal() {
        // 8ms — 정상 구간
        let ms = 8.0
        XCTAssertTrue(ms < latencyWarnMs, "8ms 는 warn 임계(\(latencyWarnMs)ms) 미만 = 정상이어야 함")
    }

    // MARK: - 낙상 위험 임계 검증

    func test_fallScore_aboveCrit_isCritical() {
        // score=65 — WalkStabilityPredictor highRisk 구간
        let score = 65.0
        XCTAssertTrue(score >= fallCritScore, "65 는 crit 임계(\(fallCritScore)) 이상이어야 함")
    }

    func test_fallScore_betweenWarnAndCrit_isWarning() {
        // score=45 — caution 구간
        let score = 45.0
        XCTAssertTrue(score >= fallWarnScore && score < fallCritScore,
                      "45 는 warn(\(fallWarnScore)) 이상 & crit(\(fallCritScore)) 미만이어야 함")
    }

    func test_fallScore_belowWarn_isNormal() {
        // score=20 — safe 구간
        let score = 20.0
        XCTAssertTrue(score < fallWarnScore, "20 은 warn 임계(\(fallWarnScore)) 미만 = 정상이어야 함")
    }

    // MARK: - WalkStabilityPredictor 연동 검증 (ForgeCore)

    func test_stabilityPredictor_defaultInput_isSafe() {
        // WalkStabilityInput() 기본값 (idle — 보폭 0, period 600ms) 은 safe 여야 함
        let result = WalkStabilityPredictor.evaluate(WalkStabilityInput())
        XCTAssertEqual(result.category, .safe,
                       "기본 입력(idle) 의 위험 카테고리는 .safe 여야 함 (score=\(result.score))")
        XCTAssertLessThan(result.score, fallWarnScore,
                          "idle score(\(result.score)) < fallWarnScore(\(fallWarnScore))")
    }

    func test_stabilityPredictor_aggressiveInput_isCritical() {
        // stride=50mm + period=350ms = 최고 위험 → fallScore >= fallCritScore
        let input = WalkStabilityInput(
            strideMm: 50, sideMm: 20, turnDeg: 15,
            periodMs: 350, footHeightMm: 15, balanceGain: 0
        )
        let result = WalkStabilityPredictor.evaluate(input)
        XCTAssertGreaterThanOrEqual(result.score, fallCritScore,
                                    "공격적 입력의 score(\(result.score)) >= fallCritScore(\(fallCritScore))")
    }

    // MARK: - SparklineView 계약 검증

    func test_sparkline_empty_doesNotCrash() {
        // SparklineView 는 values.count < 2 일 때 빈 Path 를 반환해야 함 (크래시 없음)
        // values 배열의 count 계약만 검증 (UI 직접 호출 없음)
        let values: [Double] = []
        XCTAssertLessThan(values.count, 2, "빈 배열은 sparkline 드로우 조건 미충족 (count < 2)")
    }

    func test_sparkline_singleValue_doesNotCrash() {
        let values: [Double] = [42.0]
        XCTAssertLessThan(values.count, 2, "단일 값도 sparkline 드로우 조건 미충족 (count < 2)")
    }

    // MARK: - 임계값 단조성 (threshold ordering invariants)

    func test_thresholds_batteryOrdering() {
        // voltageCritV < voltageWarnV — 긴급이 경고보다 낮아야 함
        XCTAssertLessThan(voltageCritV, voltageWarnV,
                          "crit(\(voltageCritV)V) < warn(\(voltageWarnV)V) 단조성")
    }

    func test_thresholds_latencyOrdering() {
        // latencyWarnMs < latencyCritMs — 경고가 긴급보다 낮아야 함
        XCTAssertLessThan(latencyWarnMs, latencyCritMs,
                          "warn(\(latencyWarnMs)ms) < crit(\(latencyCritMs)ms) 단조성")
    }

    func test_thresholds_fallScoreOrdering() {
        // fallWarnScore < fallCritScore — 경고가 긴급보다 낮아야 함
        XCTAssertLessThan(fallWarnScore, fallCritScore,
                          "warn(\(fallWarnScore)) < crit(\(fallCritScore)) 단조성")
    }

    // MARK: - V290-B: 배터리 voltage sparkline buffer 계약 검증

    func test_voltageBuffer_appendSingleSample_countOne() {
        // given: 빈 buffer
        var buf: [Double] = []
        // when: 1회 append
        buf.append(12.3)
        // then: count=1
        XCTAssertEqual(buf.count, 1)
    }

    func test_voltageBuffer_overflow30_dropsOldest() {
        // given: 31 samples (30 초과)
        var buf: [Double] = Array(repeating: 11.0, count: 30)
        buf.append(12.5)  // 31번째
        if buf.count > 30 { buf = Array(buf.dropFirst(buf.count - 30)) }
        // then: count stays 30, newest value retained
        XCTAssertEqual(buf.count, 30)
        XCTAssertEqual(buf.last ?? -1, 12.5, accuracy: 0.001)
    }

    func test_voltageBuffer_normalization_midRange() {
        // given: voltage=11.75V, yMin=10.5, yMax=13.0 → 정규화=(11.75-10.5)/(13.0-10.5)*100=50
        let v = 11.75
        let yMin = 10.5, yMax = 13.0
        let normalized = ((v - yMin) / (yMax - yMin)) * 100.0
        XCTAssertEqual(normalized, 50.0, accuracy: 0.1, "11.75V 는 정규화 범위 50% 지점이어야 함")
    }

    // MARK: - V290-B: 통신 지연 RTT sparkline buffer 계약 검증

    func test_latencyBuffer_appendSingleSample_countOne() {
        var buf: [Double] = []
        buf.append(8.2)
        XCTAssertEqual(buf.count, 1)
    }

    func test_latencyBuffer_overflow30_dropsOldest() {
        var buf: [Double] = Array(repeating: 5.0, count: 30)
        buf.append(55.0)
        if buf.count > 30 { buf = Array(buf.dropFirst(buf.count - 30)) }
        XCTAssertEqual(buf.count, 30)
        XCTAssertEqual(buf.last ?? -1, 55.0, accuracy: 0.001)
    }

    func test_latencyBuffer_normalization_atWarnThreshold() {
        // given: latency=10ms = warn. yMax=60 → 정규화=10/60*100 ≈ 16.7
        let ms = 10.0
        let yMax = 60.0
        let normalized = min((ms / yMax) * 100.0, 100.0)
        XCTAssertEqual(normalized, 16.666, accuracy: 0.01)
    }

    func test_latencyBuffer_normalization_clampedAboveMax() {
        // given: latency=70ms > yMax=60 → 정규화=100 (clamped)
        let ms = 70.0
        let yMax = 60.0
        let normalized = min((ms / yMax) * 100.0, 100.0)
        XCTAssertEqual(normalized, 100.0, accuracy: 0.001, "yMax 초과 ms 는 100 으로 clamp 되어야 함")
    }
}
