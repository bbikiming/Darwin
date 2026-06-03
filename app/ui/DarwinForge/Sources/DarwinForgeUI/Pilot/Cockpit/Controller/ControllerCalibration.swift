import Foundation

// MARK: - AxisCalibration

/// 단일 축의 캘리브레이션 데이터 — 저가 패드의 하드웨어 편차를 보정한다.
///
/// QGroundControl / Betaflight 캘리브레이션 마법사 패턴을 채택:
/// min/max/center 실측 → `normalize(_:)` 로 [-1, 1] 정규화.
public struct AxisCalibration: Codable, Equatable, Sendable {
    /// 하드웨어 최솟값 (스틱 끝까지 당겼을 때 raw 값).
    public var min:      Double
    /// 하드웨어 최댓값 (스틱 끝까지 밀었을 때 raw 값).
    public var max:      Double
    /// 중립 위치 raw 값 (스틱 놓았을 때).
    public var center:   Double
    /// 중립 주변 deadband — 이 범위 내 raw 는 0 처리. (raw 단위)
    public var deadband: Double

    public init(
        min: Double,
        max: Double,
        center: Double,
        deadband: Double
    ) {
        self.min      = min
        self.max      = max
        self.center   = center
        self.deadband = deadband
    }

    // MARK: - normalize(_:)

    /// raw 하드웨어 값 → 정규화된 [-1, 1].
    ///
    /// # 처리 순서
    /// 1. `|raw - center| ≤ deadband` → 0 (데드밴드)
    /// 2. `raw > center` → `(raw - center) / (max - center)` clamp [0, 1]
    /// 3. `raw < center` → `(raw - center) / (center - min)` clamp [-1, 0]
    /// 4. 최종 [-1, 1] clamp
    public func normalize(_ raw: Double) -> Double {
        // 1. deadband 적용
        if abs(raw - center) <= deadband { return 0.0 }

        if raw > center {
            // 2. 양의 방향
            let range = self.max - center
            guard range > 0 else { return 1.0 }
            let v = (raw - center) / range
            return v < 1.0 ? v : 1.0
        } else {
            // 3. 음의 방향
            let range = center - self.min
            guard range > 0 else { return -1.0 }
            let v = (raw - center) / range
            return v > -1.0 ? v : -1.0
        }
    }
}

// MARK: - CalibrationCapture

/// 캘리브레이션 마법사 중 샘플 누적 상태 — 순수 값 타입.
///
/// 사용자가 각 축을 최대/최소로 움직이는 동안 `recording(sample:)` 을 반복 호출하고,
/// 완료 시 `finished(center:deadband:)` 로 `AxisCalibration` 을 확정한다.
public struct CalibrationCapture: Sendable, Equatable {
    /// 누적된 최솟값.
    public let recordedMin: Double
    /// 누적된 최댓값.
    public let recordedMax: Double

    public init(recordedMin: Double = .infinity, recordedMax: Double = -.infinity) {
        self.recordedMin = recordedMin
        self.recordedMax = recordedMax
    }

    // MARK: - 초기 상태

    /// 누적 전 초기 상태.
    public static let initial = CalibrationCapture()

    // MARK: - recording(sample:)

    /// 새 샘플을 포함한 **새 CalibrationCapture** 반환 (mutation 없음).
    public func recording(sample: Double) -> CalibrationCapture {
        let newMin = recordedMin < sample ? recordedMin : sample
        let newMax = recordedMax > sample ? recordedMax : sample
        return CalibrationCapture(recordedMin: newMin, recordedMax: newMax)
    }

    // MARK: - finished(center:deadband:)

    /// 누적 완료 후 `AxisCalibration` 확정.
    ///
    /// 유효한 min/max 누적이 없으면 min=−1, max=1 으로 폴백.
    public func finished(center: Double, deadband: Double) -> AxisCalibration {
        let finalMin = recordedMin.isFinite  ? recordedMin : -1.0
        let finalMax = recordedMax.isFinite  ? recordedMax :  1.0
        return AxisCalibration(
            min: finalMin,
            max: finalMax,
            center: center,
            deadband: deadband
        )
    }
}
