import ForgeCore
import Foundation

/// Mac-side 합성 IMU 생성기 — `WalkEngine` 의 `FootTargets` 스트림으로부터
/// 예상 gyro / accel 신호를 finite-difference + ZMP 근사로 합성.
///
/// 목적:
///   - v1.0 에서 forge-core IMU FFI 가 아직 없는 상태(별도 PR)에서
///     **엔지니어가 보행 제어 + 자세 추정 동작을 시각적으로 검증** 할 수 있게.
///   - 실제 robot 연결 없이 walk 파라미터 변화에 따른 센서 시그니처를 사전 분석.
///   - complementary filter 등 자세 추정 알고리즘의 수렴 동작을 데모.
///
/// 합성 모델 (rough but engineering-useful):
///   - **vertical accel a_z**: COM 의 2차 미분. COM 높이 ≈ -mean(left.z, right.z) + g.
///     (z 좌표 = 발 자체의 lift, 음수 방향 → COM 은 양 발 lift 의 평균만큼 들림 + g 상수 -9.81)
///   - **lateral accel a_y**: COM y 위치의 2차 미분. y 는 walk params 의 y_swap_amplitude
///     기반 좌우 swing.
///   - **forward accel a_x**: COM x 위치의 2차 미분. step phase 1/3 (lift) 진입 시 발 추진력.
///   - **gyro_x (roll rate)**: lateral accel 의 정규화 (좌우 흔들림 → roll). ROBOTIS-OP2
///     보행 패턴에서 roll 진폭 ~3° peak.
///   - **gyro_y (pitch rate)**: forward accel 의 정규화 (전후 흔들림 → pitch). 보행 시
///     ~2° peak.
///   - **gyro_z (yaw rate)**: walk command `a` (각 회전) 의 정규 미분 + 미세 노이즈.
///
/// 노이즈: 가산 백색 잡음 — `gyroNoiseSigma`, `accelNoiseSigma` 로 조절.
///
/// 이 모델은 정확한 물리 시뮬레이션이 아니며 **시각적·기능적 검증** 용도. 실 robot
/// IMU 가 v1.1 에 연결되면 본 generator 는 "synthetic mode" 토글로 남고 실측이 기본.
public struct SyntheticImuGenerator: Sendable {
    public var gyroNoiseSigma: Double   // rad/s
    public var accelNoiseSigma: Double  // m/s²
    public let gravity: Double          // m/s²

    /// 보행 시 roll 진폭 (라디안 기준 peak gyro rate 스케일).
    public var rollGain: Double
    /// pitch 진폭.
    public var pitchGain: Double
    /// y_swap → COM 좌우 진폭 (m).
    public var yAmplitude: Double
    /// step_length → COM 전후 진폭 (m).
    public var xAmplitude: Double

    public init(gyroNoiseSigma: Double = 0.02,
                accelNoiseSigma: Double = 0.05,
                gravity: Double = 9.81,
                rollGain: Double = 12.0,
                pitchGain: Double = 8.0,
                yAmplitude: Double = 0.025,
                xAmplitude: Double = 0.020) {
        self.gyroNoiseSigma = gyroNoiseSigma
        self.accelNoiseSigma = accelNoiseSigma
        self.gravity = gravity
        self.rollGain = rollGain
        self.pitchGain = pitchGain
        self.yAmplitude = yAmplitude
        self.xAmplitude = xAmplitude
    }

    /// 한 sample 생성.
    /// - Parameters:
    ///   - prev: 직전 FootTargets (없으면 이번이 첫 sample — 미분 0).
    ///   - curr: 이번 tick FootTargets.
    ///   - dtSeconds: 두 sample 사이의 시간(초). 0 미만이면 0.001 로 클램프.
    ///   - command: walk command (x, y, a) — 명령된 회전 → yaw rate.
    /// Walk 명령 (x, y, a). 기존 ForgeCore.WalkEngine.setCommand 와 매핑.
    public struct Command: Sendable, Equatable {
        public let x: Double  // m/cycle (forward)
        public let y: Double  // m/cycle (lateral)
        public let a: Double  // rad/cycle (yaw)
        public init(x: Double, y: Double, a: Double) {
            self.x = x; self.y = y; self.a = a
        }
        public static let zero = Command(x: 0, y: 0, a: 0)
    }

    public func sample(
        prev: FootTargets?,
        curr: FootTargets,
        dtSeconds: Double,
        command: Command
    ) -> ImuSampleSwift {
        let dt = max(0.001, dtSeconds)

        // COM 위치 추정: 발 lift 가 -z 방향. COM 높이 = -mean(left.z, right.z) (lift 시 ↑).
        let comZ = -(curr.leftXYZ.z + curr.rightXYZ.z) * 0.5
        let comY = (curr.leftXYZ.y + curr.rightXYZ.y) * 0.5
        let comX = (curr.leftXYZ.x + curr.rightXYZ.x) * 0.5

        let prevComZ = prev.map { -($0.leftXYZ.z + $0.rightXYZ.z) * 0.5 } ?? comZ
        let prevComY = prev.map { ($0.leftXYZ.y + $0.rightXYZ.y) * 0.5 } ?? comY
        let prevComX = prev.map { ($0.leftXYZ.x + $0.rightXYZ.x) * 0.5 } ?? comX

        // 1차 미분 (속도). 2차는 dt 2 회분이 필요해 sliding state 가 별도 필요 →
        // 본 generator 는 stateless 로 두고 호출자가 차분으로 가속도 산출.
        // 여기서는 finite-diff 단순화: a ≈ (Δv) / Δt 가 안 보이므로
        // accel ≈ (Δposition / dt²) 의 거친 추정만 제공.
        let aZ = (comZ - prevComZ) / (dt * dt) * 0.3  // scaled
        let aY = (comY - prevComY) / (dt * dt) * 0.3
        let aX = (comX - prevComX) / (dt * dt) * 0.3

        // gyro: COM 흔들림의 1차 도함수.
        let gyroX = ((curr.rightXYZ.z - curr.leftXYZ.z)
                     - (prev?.rightXYZ.z ?? curr.rightXYZ.z) + (prev?.leftXYZ.z ?? curr.leftXYZ.z))
                    / dt * rollGain
        let gyroY = ((curr.rightXYZ.x - curr.leftXYZ.x)
                     - (prev?.rightXYZ.x ?? curr.rightXYZ.x) + (prev?.leftXYZ.x ?? curr.leftXYZ.x))
                    / dt * pitchGain
        let gyroZ = command.a * 2.0  // 명령된 회전 → yaw rate

        let n = Self.gaussianNoise.bind  // captures
        return ImuSampleSwift(
            gyro: SIMD3(
                gyroX + n(gyroNoiseSigma),
                gyroY + n(gyroNoiseSigma),
                gyroZ + n(gyroNoiseSigma)
            ),
            accel: SIMD3(
                aX + n(accelNoiseSigma),
                aY + n(accelNoiseSigma),
                aZ + gravity + n(accelNoiseSigma)  // 정적일 때 +g
            )
        )
    }

    /// 가우시안 노이즈 (Box-Muller). main thread 안전.
    private struct GaussianNoise: Sendable {
        var bind: (@Sendable (Double) -> Double) {
            { sigma in
                guard sigma > 0 else { return 0 }
                let u1 = max(.leastNonzeroMagnitude, Double.random(in: 0..<1))
                let u2 = Double.random(in: 0..<1)
                let mag = (-2.0 * log(u1)).squareRoot()
                return mag * cos(2.0 * .pi * u2) * sigma
            }
        }
    }
    private static let gaussianNoise = GaussianNoise()
}

/// Mac-side 의 IMU sample — forge-core 의 `ImuSample` 미러 (FFI 추가 전 placeholder).
public struct ImuSampleSwift: Sendable, Equatable {
    public let gyro: SIMD3<Double>    // rad/s
    public let accel: SIMD3<Double>   // m/s²

    public init(gyro: SIMD3<Double>, accel: SIMD3<Double>) {
        self.gyro = gyro
        self.accel = accel
    }

    public static let zero = ImuSampleSwift(gyro: .zero, accel: SIMD3(0, 0, 9.81))
}

/// Mac-side complementary filter — forge-core `ComplementaryFilter` 미러 (FFI 추가 전).
public struct ComplementaryFilterSwift: Sendable {
    public var gyroWeight: Double  // α, 보통 0.98
    public private(set) var rollRad: Double
    public private(set) var pitchRad: Double

    public init(gyroWeight: Double = 0.98, roll: Double = 0, pitch: Double = 0) {
        self.gyroWeight = gyroWeight
        self.rollRad = roll
        self.pitchRad = pitch
    }

    /// 한 sample 처리. Rust 측 `imu.rs` 와 동일 수식.
    public mutating func update(_ s: ImuSampleSwift, dtSeconds: Double) {
        let dt = max(0.001, dtSeconds)
        let ax = s.accel.x, ay = s.accel.y, az = s.accel.z
        let accRoll = atan2(ay, az)
        let accPitch = atan2(-ax, (ay * ay + az * az).squareRoot())

        let gyroRoll  = rollRad  + s.gyro.x * dt
        let gyroPitch = pitchRad + s.gyro.y * dt

        let w = gyroWeight
        rollRad  = w * gyroRoll  + (1.0 - w) * accRoll
        pitchRad = w * gyroPitch + (1.0 - w) * accPitch
    }

    public mutating func reset() {
        rollRad = 0
        pitchRad = 0
    }

    public var rollDeg: Double  { rollRad  * 180.0 / .pi }
    public var pitchDeg: Double { pitchRad * 180.0 / .pi }
}
