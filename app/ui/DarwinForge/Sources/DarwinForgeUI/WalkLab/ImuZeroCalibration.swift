import Foundation

/// **A (2026-05-31) — 정지 상태 IMU 영점 캘리브레이션**.
///
/// # 문제 배경
///
/// 실로봇 로그(5/30)에서 보행 pitch 가 첫 틱부터 -18~-24° 로 일정하게 기울어 있었다.
/// 이게 (a) 실제 자세 기울기인지 (b) IMU 영점 오차인지 분리하려면, 로봇을 walkReady 로
/// **가만히 세운 정지 상태의 IMU pitch/roll 기준값**이 필요하다. 본 모델이 그 기준값을
/// 캡처·영속한다.
///
/// # 비유
///
/// 디지털 저울에 아무것도 안 올렸을 때 "0" 으로 맞추는 영점(tare) 버튼과 같다. 한 번
/// 기준을 잡아두면 이후 측정값에서 그 기준을 빼 실제 변화량만 본다.
///
/// # 적용 범위 (중요)
///
/// **이 단계(A·E)에서는 캡처·저장·로깅만 한다. 보정기/안전 게이트에는 아직 적용하지 않는다.**
/// 실측 데이터로 검증한 뒤(B·D 단계) 오프셋 차감을 control 경로에 반영한다.
public struct ImuZeroCalibration: Codable, Equatable, Sendable {
    /// 정지 시 측정된 pitch 기준값(deg).
    public let pitchZeroDeg: Double
    /// 정지 시 측정된 roll 기준값(deg).
    public let rollZeroDeg: Double
    /// 캡처 시각 (ISO8601).
    public let capturedAtISO: String
    /// 평균에 사용된 샘플 수.
    public let sampleCount: Int
    /// 캡처 출처 — "auto_stillness" (정지 자동) | "manual" (사용자 버튼).
    public let source: String

    public init(pitchZeroDeg: Double,
                rollZeroDeg: Double,
                capturedAtISO: String,
                sampleCount: Int,
                source: String) {
        self.pitchZeroDeg = pitchZeroDeg
        self.rollZeroDeg = rollZeroDeg
        self.capturedAtISO = capturedAtISO
        self.sampleCount = sampleCount
        self.source = source
    }
}

/// 영점 캘리브레이션 영속화 store 추상화 — production(UserDefaults) + test(InMemory).
public protocol ImuZeroCalibrationStore: Sendable {
    func load() -> ImuZeroCalibration?
    func save(_ calibration: ImuZeroCalibration)
}

/// In-memory 구현 — 테스트/preview 용.
public final class InMemoryImuZeroCalibrationStore: ImuZeroCalibrationStore, @unchecked Sendable {
    private var value: ImuZeroCalibration?
    private let lock = NSLock()
    public init() {}
    public func load() -> ImuZeroCalibration? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    public func save(_ calibration: ImuZeroCalibration) {
        lock.lock(); defer { lock.unlock() }
        value = calibration
    }
}

/// UserDefaults 기반 구현 — launch 간 영속. 단일 JSON blob 으로 저장(schema 변경에 강인).
public final class UserDefaultsImuZeroCalibrationStore: ImuZeroCalibrationStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "calib.imuZero.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ImuZeroCalibration? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ImuZeroCalibration.self, from: data)
    }

    public func save(_ calibration: ImuZeroCalibration) {
        guard let data = try? JSONEncoder().encode(calibration) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
