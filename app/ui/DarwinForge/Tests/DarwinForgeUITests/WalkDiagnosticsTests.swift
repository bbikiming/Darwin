import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 전문가 콘솔 — 보행 진단 단위 테스트.
final class WalkDiagnosticsTests: XCTestCase {

    // MARK: - SignalStatistics

    func testSignalStatisticsEmpty() {
        let s = SignalStatistics(values: [])
        XCTAssertEqual(s.count, 0)
        XCTAssertEqual(s.mean, 0)
        XCTAssertEqual(s.stdDev, 0)
    }

    func testSignalStatisticsConstantHasZeroStdDev() {
        let s = SignalStatistics(values: [3.0, 3.0, 3.0, 3.0])
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.mean, 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.stdDev, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s.min, 3.0)
        XCTAssertEqual(s.max, 3.0)
        XCTAssertEqual(s.peakToPeak, 0.0)
    }

    func testSignalStatisticsKnownMean() {
        // {1,2,3,4,5}: mean=3, σ=√2.
        let s = SignalStatistics(values: [1, 2, 3, 4, 5])
        XCTAssertEqual(s.mean, 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.stdDev, 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(s.min, 1)
        XCTAssertEqual(s.max, 5)
        XCTAssertEqual(s.peakToPeak, 4)
    }

    func testSignalStatisticsRms() {
        // {3, 4}: RMS = √((9+16)/2) = √12.5 ≈ 3.5355.
        let s = SignalStatistics(values: [3, 4])
        XCTAssertEqual(s.rms, 12.5.squareRoot(), accuracy: 1e-9)
    }

    // MARK: - TimeSeriesBuffer

    func testTimeSeriesBufferEvictsOnCapacity() {
        let buf = TimeSeriesBuffer(capacity: 3)
        buf.append(t: 0.0, v: 1)
        buf.append(t: 0.1, v: 2)
        buf.append(t: 0.2, v: 3)
        buf.append(t: 0.3, v: 4)
        XCTAssertEqual(buf.samples.count, 3)
        XCTAssertEqual(buf.samples.first?.v, 2)
        XCTAssertEqual(buf.samples.last?.v, 4)
    }

    func testTimeSeriesBufferIdsAreMonotonic() {
        let buf = TimeSeriesBuffer(capacity: 100)
        for i in 0..<10 { buf.append(t: Double(i) * 0.01, v: Double(i)) }
        let ids = buf.samples.map(\.id)
        XCTAssertEqual(ids, Array(0..<10))
    }

    func testTimeSeriesBufferClearResetsId() {
        let buf = TimeSeriesBuffer(capacity: 100)
        buf.append(t: 0, v: 1)
        buf.append(t: 0.01, v: 2)
        buf.clear()
        XCTAssertTrue(buf.samples.isEmpty)
        buf.append(t: 0, v: 100)
        XCTAssertEqual(buf.samples.first?.id, 0)
    }

    // MARK: - Units

    func testGyroUnitConversion() {
        XCTAssertEqual(GyroUnit.radPerSec.convert(1.0), 1.0)
        XCTAssertEqual(GyroUnit.degPerSec.convert(.pi), 180.0, accuracy: 1e-9)
    }

    func testAccelUnitConversion() {
        XCTAssertEqual(AccelUnit.mPerSec2.convert(9.80665), 9.80665)
        XCTAssertEqual(AccelUnit.g.convert(9.80665), 1.0, accuracy: 1e-9)
    }

    func testAngleUnitConversion() {
        XCTAssertEqual(AngleUnit.degrees.convert(.pi), 180.0, accuracy: 1e-9)
        XCTAssertEqual(AngleUnit.radians.convert(.pi), .pi)
    }

    // MARK: - SyntheticImuGenerator

    func testSyntheticImuAccelAtRestHasGravity() {
        let gen = SyntheticImuGenerator(gyroNoiseSigma: 0, accelNoiseSigma: 0)
        let foot = FootTargetsFixture.zero
        let imu = gen.sample(
            prev: foot, curr: foot, dtSeconds: 0.01,
            command: .zero
        )
        // 정지 — accel.z ≈ g (9.81), gyro 모두 ≈ 0.
        XCTAssertEqual(imu.accel.z, 9.81, accuracy: 0.01)
        XCTAssertEqual(imu.gyro.x, 0, accuracy: 1e-6)
        XCTAssertEqual(imu.gyro.y, 0, accuracy: 1e-6)
    }

    func testSyntheticImuYawFollowsCommandA() {
        let gen = SyntheticImuGenerator(gyroNoiseSigma: 0, accelNoiseSigma: 0)
        let foot = FootTargetsFixture.zero
        let imu = gen.sample(
            prev: foot, curr: foot, dtSeconds: 0.01,
            command: .init(x: 0, y: 0, a: 0.10)
        )
        // gyro.z = command.a * 2.0 (generator 의 모델).
        XCTAssertEqual(imu.gyro.z, 0.20, accuracy: 1e-6)
    }

    // MARK: - ComplementaryFilter (Swift mirror of Rust)

    func testComplementaryFilterAtRestConvergesToZero() {
        var f = ComplementaryFilterSwift()
        for _ in 0..<200 {
            f.update(.zero, dtSeconds: 0.01)
        }
        // 정지 — 가속도만 -g, 자이로 0 → roll/pitch 모두 ~0.
        XCTAssertLessThan(abs(f.rollRad),  0.01)
        XCTAssertLessThan(abs(f.pitchRad), 0.01)
    }

    func testComplementaryFilterResetClearsState() {
        var f = ComplementaryFilterSwift()
        f.update(ImuSampleSwift(gyro: SIMD3(0.5, 0.3, 0), accel: SIMD3(0, 0, 9.81)),
                 dtSeconds: 0.01)
        XCTAssertNotEqual(f.rollRad, 0)
        f.reset()
        XCTAssertEqual(f.rollRad, 0)
        XCTAssertEqual(f.pitchRad, 0)
    }
}

/// FootTargets 픽스처 — public 생성자가 없어 한 자세 모킹.
private enum FootTargetsFixture {
    /// 두 발 모두 원점 — 정지 상태 시뮬.
    static var zero: FootTargets {
        // FootTargets 는 public 생성자가 없고 ffi init 만 있어 직접 생성 불가.
        // 대신 WalkEngine 의 초기 tick (idle phase) 사용.
        var engine = WalkEngine()
        engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
        return engine.tick(dtMs: 0)
    }
}
