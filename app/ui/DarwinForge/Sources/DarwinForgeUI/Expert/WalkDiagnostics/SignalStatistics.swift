import Foundation

/// 시계열 sliding-window 통계 — min / max / mean / σ / RMS / peak-to-peak.
///
/// 엔지니어 콘솔의 좌측 numeric 패널에서 채널별 실시간 표시.
public struct SignalStatistics: Sendable, Equatable {
    public let count: Int
    public let min: Double
    public let max: Double
    public let mean: Double
    public let stdDev: Double
    public let rms: Double
    public var peakToPeak: Double { max - min }

    public init(values: [Double]) {
        guard !values.isEmpty else {
            self = .empty; return
        }
        count = values.count
        var mn = values[0], mx = values[0], sum = 0.0, sumSq = 0.0
        for v in values {
            if v < mn { mn = v }
            if v > mx { mx = v }
            sum += v
            sumSq += v * v
        }
        let n = Double(values.count)
        self.min = mn
        self.max = mx
        self.mean = sum / n
        let variance = Swift.max(0.0, sumSq / n - (sum / n) * (sum / n))
        self.stdDev = variance.squareRoot()
        self.rms = (sumSq / n).squareRoot()
    }

    private init(count: Int, min: Double, max: Double, mean: Double, stdDev: Double, rms: Double) {
        self.count = count
        self.min = min
        self.max = max
        self.mean = mean
        self.stdDev = stdDev
        self.rms = rms
    }

    public static let empty = SignalStatistics(
        count: 0, min: 0, max: 0, mean: 0, stdDev: 0, rms: 0
    )
}

/// 시계열 한 채널 — 시간 t (초) + 값 v.
public struct TimeSample: Sendable, Equatable, Identifiable {
    public let id: Int           // 모노톤 증가 — Chart 의 stable identity.
    public let t: Double         // 초.
    public let v: Double
    public init(id: Int, t: Double, v: Double) {
        self.id = id; self.t = t; self.v = v
    }
}

/// 다채널 시계열 ring buffer.
/// 64-bit Sample idx 로 dedup, fixed capacity (default 1000 samples ≈ 10초 @ 100Hz).
public final class TimeSeriesBuffer: @unchecked Sendable {
    public let capacity: Int
    public private(set) var samples: [TimeSample] = []
    private var nextId: Int = 0

    public init(capacity: Int = 1000) {
        self.capacity = Swift.max(1, capacity)
        self.samples.reserveCapacity(self.capacity)
    }

    public func append(t: Double, v: Double) {
        samples.append(TimeSample(id: nextId, t: t, v: v))
        nextId &+= 1
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func clear() {
        samples.removeAll(keepingCapacity: true)
        nextId = 0
    }

    /// 마지막 N 개 sample (없으면 전체).
    public func tail(_ n: Int) -> [TimeSample] {
        guard samples.count > n else { return samples }
        return Array(samples.suffix(n))
    }

    /// 현재 통계.
    public var stats: SignalStatistics {
        SignalStatistics(values: samples.map(\.v))
    }
}
