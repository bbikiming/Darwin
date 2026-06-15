/// 사이클 238 — SafeMotion 안전 검증 로직 regression guard.
import XCTest
@testable import ForgeCore

/// SafeMotion 유닛 테스트 — 전압·부하·한계·거리 검증 로직의 경계값 회귀 보호.
///
/// # 비유
///
/// 비행 전 체크리스트와 같다. 연료(전압) 확인, 적재 무게(부하) 확인,
/// 비행 경로(관절 한계) 확인, 이동 거리(step) 확인을 순서대로 거치며
/// 하나라도 실패하면 이륙을 거부한다.
final class SafeMotionTests: XCTestCase {

    private let center = RobotPose.center

    // MARK: - normalizeLoadRaw (Dynamixel 11-bit signed)

    /// raw=0: 부하 없음 → 0.
    func testNormalizeLoadRaw_zero() {
        XCTAssertEqual(SafeMotion.normalizeLoadRaw(0), 0)
    }

    /// raw=512: 양 방향 절반 부하 → +512.
    func testNormalizeLoadRaw_positiveHalf() {
        XCTAssertEqual(SafeMotion.normalizeLoadRaw(512), 512)
    }

    /// raw=1023: 양 방향 최대 부하 → +1023.
    func testNormalizeLoadRaw_positiveMax() {
        XCTAssertEqual(SafeMotion.normalizeLoadRaw(1023), 1023)
    }

    /// raw=1024: 방향 비트만 set, 절대값 0 → 0.
    func testNormalizeLoadRaw_directionBitOnly() {
        // 1024 = 0x400 → direction bit set, abs10 = 0
        XCTAssertEqual(SafeMotion.normalizeLoadRaw(1024), 0)
    }

    /// raw=1536: 음 방향 절반 부하 → -512.
    func testNormalizeLoadRaw_negativeHalf() {
        // 1536 = 1024 + 512
        XCTAssertEqual(SafeMotion.normalizeLoadRaw(1536), -512)
    }

    /// raw=2047: 음 방향 최대 부하 → -1023.
    func testNormalizeLoadRaw_negativeMax() {
        // 2047 = 1024 + 1023
        XCTAssertEqual(SafeMotion.normalizeLoadRaw(2047), -1023)
    }

    // MARK: - loadPercent

    /// raw=0 → 0%.
    func testLoadPercent_zero() {
        XCTAssertEqual(SafeMotion.loadPercent(0), 0, accuracy: 0.01)
    }

    /// raw=1023 → 약 100% (1023/10.23).
    func testLoadPercent_positiveMax() {
        let pct = SafeMotion.loadPercent(1023)
        XCTAssertEqual(pct, 100.0, accuracy: 0.1)
    }

    /// 음수 raw → 동일 비율 (절대값 사용).
    func testLoadPercent_negativeRaw() {
        // raw=1536 → normalizeLoadRaw = -512, abs=512
        let pct = SafeMotion.loadPercent(1536)
        let expected = Double(512) / 10.23
        XCTAssertEqual(pct, expected, accuracy: 0.01)
    }

    // MARK: - loadColor

    /// 0% → normal (초록).
    func testLoadColor_zero() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 0), .normal)
    }

    /// 29% → normal (30 미만).
    func testLoadColor_justBelowModerate() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 29), .normal)
    }

    /// 30% → moderate (경계값).
    func testLoadColor_moderateBoundary() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 30), .moderate)
    }

    /// 59% → moderate (60 미만).
    func testLoadColor_justBelowHigh() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 59), .moderate)
    }

    /// 60% → high (경계값).
    func testLoadColor_highBoundary() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 60), .high)
    }

    /// 79% → high (80 미만).
    func testLoadColor_justBelowCritical() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 79), .high)
    }

    /// 80% → critical (경계값).
    func testLoadColor_criticalBoundary() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 80), .critical)
    }

    /// 95% → critical.
    func testLoadColor_criticalHigh() {
        XCTAssertEqual(SafeMotion.loadColor(loadPct: 95), .critical)
    }

    // MARK: - SafetyVerdict.allowsProceed

    /// .safe → true (진행 가능).
    func testVerdict_safeAllowsProceed() {
        XCTAssertTrue(SafeMotion.SafetyVerdict.safe.allowsProceed)
    }

    /// .requireSplit → true (분할 진행 가능).
    func testVerdict_requireSplitAllowsProceed() {
        XCTAssertTrue(SafeMotion.SafetyVerdict.requireSplit(maxDeltaDeg: 90).allowsProceed)
    }

    /// .rejectVoltage → false (진행 불가).
    func testVerdict_rejectVoltageBlocksProceed() {
        XCTAssertFalse(SafeMotion.SafetyVerdict.rejectVoltage(currentV: 7.0).allowsProceed)
    }

    /// .rejectLoad → false (진행 불가).
    func testVerdict_rejectLoadBlocksProceed() {
        let verdict = SafeMotion.SafetyVerdict.rejectLoad(joint: .rKnee, loadPct: 96)
        XCTAssertFalse(verdict.allowsProceed)
    }

    /// .rejectLimit → false (진행 불가).
    func testVerdict_rejectLimitBlocksProceed() {
        let verdict = SafeMotion.SafetyVerdict.rejectLimit(
            joint: .headTilt, requestedDeg: 100, limitDeg: -45...45
        )
        XCTAssertFalse(verdict.allowsProceed)
    }

    /// 모든 verdict의 message는 비어 있지 않다.
    func testVerdict_allMessagesNonEmpty() {
        let verdicts: [SafeMotion.SafetyVerdict] = [
            .safe,
            .requireSplit(maxDeltaDeg: 70),
            .rejectVoltage(currentV: 7.0),
            .rejectLoad(joint: .rKnee, loadPct: 96),
            .rejectLimit(joint: .headTilt, requestedDeg: 100, limitDeg: -45...45),
        ]
        for verdict in verdicts {
            XCTAssertFalse(verdict.message.isEmpty, "\(verdict) message should not be empty")
        }
    }

    // MARK: - verify()

    /// center → center, 정상 전압, 부하 없음 → .safe.
    func testVerify_centerToCenter_safe() {
        let result = SafeMotion.verify(
            from: center, to: center,
            voltageVolts: 12.0,
            loads: [:]
        )
        XCTAssertEqual(result, .safe)
    }

    /// 낮은 전압 (7.0V < 8.5V critical) → .rejectVoltage.
    func testVerify_lowVoltage_rejects() {
        let result = SafeMotion.verify(
            from: center, to: center,
            voltageVolts: 7.0,
            loads: [:]
        )
        if case .rejectVoltage(let v) = result {
            XCTAssertEqual(v, 7.0, accuracy: 0.01)
        } else {
            XCTFail("Expected rejectVoltage, got \(result)")
        }
    }

    /// nil 전압 → 전압 체크 skip (reject 하지 않음).
    func testVerify_nilVoltage_skipsCheck() {
        let result = SafeMotion.verify(
            from: center, to: center,
            voltageVolts: nil,
            loads: [:]
        )
        if case .rejectVoltage = result {
            XCTFail("nil voltage should skip check, got rejectVoltage")
        }
        XCTAssertEqual(result, .safe)
    }

    /// voltage=0 → guard `v > 0` 에 의해 skip.
    func testVerify_zeroVoltage_skipsCheck() {
        let result = SafeMotion.verify(
            from: center, to: center,
            voltageVolts: 0,
            loads: [:]
        )
        if case .rejectVoltage = result {
            XCTFail("voltage=0 should skip check, got rejectVoltage")
        }
        XCTAssertEqual(result, .safe)
    }

    /// critical 부하 (raw near 1023) → .rejectLoad.
    func testVerify_criticalLoad_rejects() {
        // raw=1023 → loadPercent ~ 100% >= 95% critical
        let loads: [JointID: Int] = [.rKnee: 1023]
        let result = SafeMotion.verify(
            from: center, to: center,
            voltageVolts: 12.0,
            loads: loads
        )
        if case .rejectLoad(let joint, let pct) = result {
            XCTAssertEqual(joint, .rKnee)
            XCTAssertGreaterThanOrEqual(pct, SafeMotion.LoadLevel.critical)
        } else {
            XCTFail("Expected rejectLoad, got \(result)")
        }
    }

    /// 빈 loads 맵 → 부하 체크 skip.
    func testVerify_emptyLoads_skipsCheck() {
        let result = SafeMotion.verify(
            from: center, to: center,
            voltageVolts: 12.0,
            loads: [:]
        )
        if case .rejectLoad = result {
            XCTFail("Empty loads should skip load check")
        }
        XCTAssertEqual(result, .safe)
    }

    /// 큰 위치 변경 (>60 deg) → .requireSplit.
    func testVerify_largePositionChange_requiresSplit() {
        // 2048 → 2048+800: delta = 800 * (180/2048) ≈ 70.3°
        let target = RobotPose(positions: [.rShoulderPitch: 2048 + 800])
        let result = SafeMotion.verify(
            from: center, to: target,
            voltageVolts: 12.0,
            loads: [:]
        )
        if case .requireSplit(let maxDeg) = result {
            XCTAssertGreaterThan(maxDeg, SafeMotion.maxStepDegrees)
        } else {
            XCTFail("Expected requireSplit, got \(result)")
        }
    }

    /// 작은 위치 변경 (<=60 deg) → .safe.
    func testVerify_smallPositionChange_safe() {
        // 2048 → 2048+200: delta = 200 * (180/2048) ≈ 17.6°
        let target = RobotPose(positions: [.rShoulderPitch: 2048 + 200])
        let result = SafeMotion.verify(
            from: center, to: target,
            voltageVolts: 12.0,
            loads: [:]
        )
        XCTAssertEqual(result, .safe)
    }

    // MARK: - Constants

    /// LoadLevel 임계값 검증.
    func testConstants_loadLevels() {
        XCTAssertEqual(SafeMotion.LoadLevel.normal, 30)
        XCTAssertEqual(SafeMotion.LoadLevel.moderate, 60)
        XCTAssertEqual(SafeMotion.LoadLevel.high, 80)
        XCTAssertEqual(SafeMotion.LoadLevel.critical, 95)
    }

    /// VoltageLevel 임계값 검증.
    func testConstants_voltageLevels() {
        XCTAssertEqual(SafeMotion.VoltageLevel.healthy, 11.1, accuracy: 0.001)
        XCTAssertEqual(SafeMotion.VoltageLevel.warning, 9.5, accuracy: 0.001)
        XCTAssertEqual(SafeMotion.VoltageLevel.critical, 8.5, accuracy: 0.001)
    }

    /// maxStepDegrees = 60.
    func testConstants_maxStepDegrees() {
        XCTAssertEqual(SafeMotion.maxStepDegrees, 60)
    }
}
