import Foundation
import ForgeCore

/// v1.1 Stage 3 — IMU 시계열 기반 선제 fall 예측.
///
/// `WalkLabSession.tick()` 가 매 50ms 마다 호출. 5Hz IMU polling (200ms 간격) 의
/// ring buffer 와 결합해 `~0.3-0.5s 후 30° 도달` 을 예측 → emergency 가 도달
/// **전에** 발동. 기존 L3 (30°) 보다 0.3-0.5s 빨라짐.
///
/// # 알고리즘
///
/// 1. **`tilt_max`** = `max(|roll|, |pitch|)` (deg). 현재 안전 상태 기준.
/// 2. **`tilt_rate`** = `(tilt_max_now - tilt_max_oldest) / dt_sec` (deg/s).
///    Ring buffer 의 첫 sample 과 마지막 sample 비교. dt < 0.05s 면 신뢰도 ↓.
/// 3. **`gyro_var`** = recent gyro_x, gyro_y 의 분산 (dps²). 비정상 흔들림 검출.
/// 4. **`predicted_eta_ms`** = `(30 - tilt_max_now) / tilt_rate * 1000` —
///    tilt_rate > 5 deg/s 일 때만 의미. 그 외 nil.
/// 5. **`score`** (0..100) = tilt 60점 + rate 30점 + variance 10점 합.
/// 6. **`recommend_emergency`** =
///    - `score >= 80` (강한 fall 임박) **또는**
///    - `etaMs.map { $0 < 400 } ?? false` (0.4s 내 30° 도달 예측)
///
/// # 임계 근거 (정량)
///
/// - **rate 60 deg/s**: 5Hz IMU 의 max 의미 (각 sample 간 12°+ 변화 = 보행 cycle
///   자연 흔들림 ±4° 의 3 배). 정상 보행에서 도달 어려움 → false positive 낮음.
/// - **gyro_var 1000 (dps²)**: 정상 보행 gyro 변동 (~5 dps²) 의 200 배. 외란 검출.
/// - **0.4s lookahead**: ROBOTIS-OP2 의 emergency 송출 latency (USB ~20ms + torque
///   OFF ~10ms + walkReady 보간 시작 ~30ms = ~60ms) + 안전 마진 (340ms) = 0.4s.
public struct FallPredictor {

    /// Ring buffer 최대 크기 — 5Hz × 1초 = 5 sample. 500ms 윈도우는 자동 truncate.
    public static let maxBufferSize: Int = 5

    /// 예측 emergency 트리거 score 임계.
    public static let emergencyScoreThreshold: Double = 80

    /// 예측 emergency 트리거 ETA 임계 (ms).
    public static let emergencyEtaMsThreshold: Double = 400

    /// 한 시점의 IMU 샘플.
    public struct Sample: Equatable, Sendable {
        public let timestamp: Date
        public let rollDeg: Double
        public let pitchDeg: Double
        public let gyroXDps: Double
        public let gyroYDps: Double

        public init(timestamp: Date, rollDeg: Double, pitchDeg: Double,
                    gyroXDps: Double, gyroYDps: Double) {
            self.timestamp = timestamp
            self.rollDeg = rollDeg
            self.pitchDeg = pitchDeg
            self.gyroXDps = gyroXDps
            self.gyroYDps = gyroYDps
        }

        /// `max(|roll|, |pitch|)` — fall 위험 척도.
        public var tiltMax: Double { max(abs(rollDeg), abs(pitchDeg)) }
    }

    /// 예측 결과.
    public struct Prediction: Equatable, Sendable {
        /// 0..100. 100 = imminent fall.
        public let score: Double
        /// 30° 도달까지 예측 시간 (ms). rate 가 작으면 nil.
        public let etaMs: Double?
        /// emergency stop 발동 권장 여부 (autoFallPrevention=true 시 즉시 emergency).
        public let recommendEmergency: Bool

        public static let zero = Prediction(score: 0, etaMs: nil, recommendEmergency: false)
    }

    /// Ring buffer 의 sample 들로부터 예측 산정.
    ///
    /// - 빈 buffer / 1 sample → score 단순 tilt 기반 only, rate=variance=0.
    /// - 2+ sample → rate, variance 모두 계산.
    /// - NaN / 무한대 sample 은 skip.
    public static func predict(samples: [Sample], now: Date = .init()) -> Prediction {
        // 1. NaN / 무한대 sample 거름.
        let valid = samples.filter { s in
            s.rollDeg.isFinite && s.pitchDeg.isFinite
                && s.gyroXDps.isFinite && s.gyroYDps.isFinite
        }
        guard let latest = valid.last else { return .zero }

        let tiltNow = latest.tiltMax

        // 2. tilt rate — 첫·마지막 sample 비교 (충분한 dt 보장).
        var tiltRate: Double = 0
        var dtSec: Double = 0
        if let first = valid.first, valid.count >= 2 {
            dtSec = latest.timestamp.timeIntervalSince(first.timestamp)
            if dtSec >= 0.05 {
                tiltRate = (tiltNow - first.tiltMax) / dtSec
            }
        }

        // 3. gyro variance — 최근 sample 평균 vs 각 sample 의 차이 제곱 평균.
        let gyroVar: Double
        if valid.count >= 2 {
            let mx = valid.map(\.gyroXDps).reduce(0, +) / Double(valid.count)
            let my = valid.map(\.gyroYDps).reduce(0, +) / Double(valid.count)
            let varX = valid.map { pow($0.gyroXDps - mx, 2) }.reduce(0, +) / Double(valid.count)
            let varY = valid.map { pow($0.gyroYDps - my, 2) }.reduce(0, +) / Double(valid.count)
            gyroVar = varX + varY
        } else {
            gyroVar = 0
        }

        // 4. ETA — tilt_rate > 5 deg/s 일 때만 의미. 음수 (회복 중) 면 nil.
        let etaMs: Double?
        if tiltRate > 5.0, tiltNow < 30 {
            let remainDeg = 30.0 - tiltNow
            let etaSec = remainDeg / tiltRate
            etaMs = etaSec * 1000.0
        } else {
            etaMs = nil
        }

        // 5. Score 계산 (0..100).
        // - tilt 기여 60점 max: tiltNow / 30 * 60.
        // - rate 기여 30점 max: clamp(tiltRate / 60 * 30, 0, 30).
        // - variance 기여 10점 max: clamp(gyroVar / 1000 * 10, 0, 10).
        let tiltContrib = min(60, max(0, tiltNow / 30.0 * 60.0))
        let rateContrib = min(30, max(0, tiltRate / 60.0 * 30.0))
        let varContrib  = min(10, max(0, gyroVar / 1000.0 * 10.0))
        let score = tiltContrib + rateContrib + varContrib

        // 6. Emergency 권장.
        let recommend = (score >= emergencyScoreThreshold)
            || (etaMs.map { $0 < emergencyEtaMsThreshold } ?? false)

        return Prediction(score: score, etaMs: etaMs, recommendEmergency: recommend)
    }

    /// 새 sample 추가 후 maxBufferSize 안에 자르기 — `WalkLabSession` 에서
    /// ring buffer 유지 helper.
    public static func append(_ sample: Sample, to buffer: inout [Sample]) {
        buffer.append(sample)
        // 1초 윈도우 (5 sample) 초과 시 oldest drop. 시간 기반 truncate (1.1s) 도 적용.
        let now = sample.timestamp
        buffer.removeAll { now.timeIntervalSince($0.timestamp) > 1.1 }
        if buffer.count > maxBufferSize {
            buffer.removeFirst(buffer.count - maxBufferSize)
        }
    }
}
