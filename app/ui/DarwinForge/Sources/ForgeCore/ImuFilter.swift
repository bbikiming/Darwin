import Foundation

/// Mac-side complementary filter — Sprint 18 Phase E (Codex 잔여 4 minimal viable).
///
/// `forge-core/walk/imu.rs` 의 ComplementaryFilter 와 동일 알고리즘을 Swift 로 포팅.
/// Mac 측 polling 빈도 (5Hz) 에서 gyro 적분 + accelerometer 보정으로 정적 tilt 보다
/// 짧은 시간 동작 추적 가능.
///
/// **한계 (Codex 권고)**:
///   - 5Hz 폴링 (dt=0.2s) 에서 tau=0.5s 면 alpha ≈ 0.71. 약 2.5 cycle 만에 settling.
///   - 진정한 동적 자세 추적은 robot-side 100Hz loop (v1.6 sprint) 가 필요.
///   - 본 Swift filter 는 "정적 tilt 보다 약간 개선" 수준.
public struct ImuFilter: Sendable, Equatable {
    /// 필터링된 roll 각도 (°).
    public private(set) var rollDeg: Double
    /// 필터링된 pitch 각도 (°).
    public private(set) var pitchDeg: Double
    /// 마지막 update 시각 — dt 계산 + stale 판정용.
    public private(set) var lastUpdatedAt: Date?
    /// 누적 sample 수.
    public private(set) var sampleCount: Int

    /// tau (초) — gyro 가중치 시간 상수. 클수록 gyro 의존, 작을수록 accel 의존.
    public let tau: Double

    public init(tau: Double = 0.5,
                rollDeg: Double = 0,
                pitchDeg: Double = 0) {
        self.tau = max(0.05, tau)
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
        self.lastUpdatedAt = nil
        self.sampleCount = 0
    }

    /// 새 IMU sample 으로 update — dt 는 호출 시각 기반 자동 계산.
    /// gyro: gyro_x_dps (roll axis), gyro_y_dps (pitch axis).
    /// accel: accel_x_g, accel_y_g, accel_z_g — atan2 로 정적 tilt 추정.
    public mutating func update(_ sample: ImuRaw, at now: Date = .init()) {
        let dt: Double
        if let last = lastUpdatedAt {
            dt = max(0.001, min(1.0, now.timeIntervalSince(last)))
        } else {
            // 첫 sample — accel-only 정적 추정으로 초기화.
            rollDeg = Double(sample.rollDeg)
            pitchDeg = Double(sample.pitchDeg)
            lastUpdatedAt = now
            sampleCount = 1
            return
        }

        // alpha = tau / (tau + dt). dt 0.2s, tau 0.5s 면 alpha ≈ 0.714.
        let alpha = tau / (tau + dt)

        // gyro 적분 — roll axis ≈ gyro X, pitch axis ≈ gyro Y (정확한 매핑은 mounting 에 따라 다름).
        // ROBOTIS-OP2 의 일반적 mounting: roll ← gyro_x, pitch ← gyro_y.
        let gyroRollDps = sample.gyroXDps
        let gyroPitchDps = sample.gyroYDps

        let rollGyroIntegrated = rollDeg + gyroRollDps * dt
        let pitchGyroIntegrated = pitchDeg + gyroPitchDps * dt

        // accel 정적 추정.
        let rollAccel = Double(sample.rollDeg)
        let pitchAccel = Double(sample.pitchDeg)

        // complementary 결합.
        rollDeg = alpha * rollGyroIntegrated + (1 - alpha) * rollAccel
        pitchDeg = alpha * pitchGyroIntegrated + (1 - alpha) * pitchAccel
        lastUpdatedAt = now
        sampleCount += 1
    }

    /// 5초 이상 update 안 됐으면 stale.
    public func isStale(now: Date = .init()) -> Bool {
        guard let last = lastUpdatedAt else { return false }
        return now.timeIntervalSince(last) > 5.0
    }

    /// reset — 모드 전환 시.
    public mutating func reset() {
        rollDeg = 0
        pitchDeg = 0
        lastUpdatedAt = nil
        sampleCount = 0
    }
}
