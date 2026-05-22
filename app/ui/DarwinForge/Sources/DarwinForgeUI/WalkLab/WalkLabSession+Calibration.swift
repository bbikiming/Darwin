import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 90: god object Phase 1C 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` (4431 line) 의 Static Tilt Calibration method (~74 line) 를 본
/// extension 으로 이동. stored property `calibrationCaptures` 는 Swift extension 제약으로
/// 본체 잔존 — method 만 이동.
///
/// # 비유
///
/// 큰 진료실의 "자세 측정실" 도구만 별도 부속실로 이전. 측정 차트 (state) 는 본 진료실
/// 벽에 잔존, 측정 절차 (method) 만 이전. 측정자는 진료실의 차트에 internal access 로 기입.
///
/// # 분할 정책
///
/// - **stored property 본체 잔존** (Swift 제약): `calibrationCaptures`.
/// - 본 cycle 에서 `public private(set)` → `public internal(set)` 으로 access 격상 —
///   extension 의 write 허용 + 외부 API 는 read-only 유지.
/// - **`walkCycleTask` 의존**: `private` → `internal` 격상 — extension 의 보행 중 거부
///   guard 가 nil 여부 검사 필요. 외부 module 은 여전히 not visible.
/// - method 3개 이동: `runStaticTiltCalibration(axis:durationSec:sampleIntervalMs:)` /
///   `currentCalibrationDiagnosis()` / `resetCalibrationCaptures()`.
///
/// # 회귀
///
/// 1233 tests 회귀 0 — 외부 API 변경 0 (read 시 동일, write 는 module 내부만).
extension WalkLabSession {

    /// 단일 자세의 IMU 캡처. 사용자가 robot 을 손으로 자세 잡고 호출.
    /// **주의**: 보행 중 (`walkCycleTask != nil`) 호출 시 보행 데이터와 간섭 가능 — 거부.
    /// - Parameters:
    ///   - axis: 캡처 자세 (직립 / 앞·뒤·오·왼 30°)
    ///   - durationSec: 캡처 시간 (기본 5초)
    ///   - sampleIntervalMs: sample 간격 (기본 50ms = 20Hz)
    /// - Returns: 캡처 결과 (samples + summary). nil 이면 보행 중 거부.
    @discardableResult
    public func runStaticTiltCalibration(
        axis: StaticTiltCalibration.Axis,
        durationSec: Double = 5.0,
        sampleIntervalMs: Double = 50.0
    ) async -> StaticTiltCalibration.Capture? {
        guard walkCycleTask == nil else {
            lastRobotEvent = "캘리브레이션 거부: 보행 중에는 자세 캡처 불가 (정지 후 재시도)"
            return nil
        }
        let startDate = Date()
        let iso = ISO8601DateFormatter().string(from: startDate)
        let imuSrcLabel: String = {
            switch imuSource {
            case .real: return "real"
            case .sim:  return "sim"
            case .stale:return "stale"
            }
        }()

        var samples: [StaticTiltCalibration.Sample] = []
        let durationMs = max(100.0, durationSec * 1000.0)
        let intervalMs = max(10.0, sampleIntervalMs)
        let nanosPerSample = UInt64(intervalMs * 1_000_000)
        var elapsedMs: Double = 0

        while elapsedMs <= durationMs {
            // tick() 가 imuRollDeg / imuPitchDeg 를 갱신 — 그 값 직접 read.
            samples.append(StaticTiltCalibration.Sample(
                rollDeg: imuRollDeg,
                pitchDeg: imuPitchDeg,
                tMs: elapsedMs
            ))
            try? await Task.sleep(nanoseconds: nanosPerSample)
            elapsedMs += intervalMs
            // Task cancellation 존중.
            if Task.isCancelled { break }
        }

        let capture = StaticTiltCalibration.Capture(
            axis: axis,
            startTimeIso: iso,
            durationSec: Date().timeIntervalSince(startDate),
            samples: samples,
            imuSource: imuSrcLabel
        )
        // 같은 axis 의 이전 캡처는 교체 (가장 최근만 보관) — 진단 시 by-axis grouping 의 .last 사용.
        calibrationCaptures.removeAll { $0.axis == axis }
        calibrationCaptures.append(capture)
        lastRobotEvent = "✅ 캘리브레이션 [\(axis.label)] 캡처 완료 — \(samples.count) samples, meanPitch=\(String(format: "%.1f", capture.summary.meanPitch))°, meanRoll=\(String(format: "%.1f", capture.summary.meanRoll))°"
        return capture
    }

    /// 현재까지 캡처된 5축 데이터로 부호 컨벤션 진단.
    public func currentCalibrationDiagnosis() -> StaticTiltCalibration.Diagnosis {
        StaticTiltCalibration.diagnose(captures: calibrationCaptures)
    }

    /// 모든 캘리브레이션 캡처 초기화.
    public func resetCalibrationCaptures() {
        calibrationCaptures = []
    }
}
