import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 107: god object Phase 7 분할 (Fall Prediction)**.
///
/// `WalkLabSession.swift` (2942 line) 의 `updateFallPrediction()` (~50 line) 만
/// 본 extension 으로 이동. (사이클 109 에서 `applyBalanceMitigation` 도 `+BalanceMitigation`
/// extension 으로 후속 분할 — `cancelWalkCycle` 도 internal 격상하여 호출.)
///
/// # 비유
///
/// 비행기 fly-by-wire 의 "추락 예측 컴퓨터" 모듈을 별도 부속실로 이전. 예측 데이터
/// (imuBuffer / lastBufferPushAt) 는 본 제어실에 잔존, 예측 알고리즘 (predict) 만
/// 이전. 예측자는 제어실 데이터에 internal access 로 read/write.
///
/// # 분할 정책
///
/// - **method 1개 이동**: `updateFallPrediction()`.
/// - stored property 본체 잔존 (Swift 제약):
///   - `imuBuffer` (private → internal)
///   - `lastBufferPushAt` (private → internal)
///   - `fallPrediction` (private(set) → internal(set))
/// - `imuRollDeg / imuPitchDeg / imuSource` 이미 internal 이상 — 격상 0.
/// - 호출 site `tick()` 의 `updateFallPrediction()` 호출은 본체 동일.
///
/// # 회귀
///
/// 1292 tests 회귀 0 — 외부 API 변경 0 (read 시 동일, write 는 module 내부만).
extension WalkLabSession {

    /// **Stage 3 (v1.1 fall prevention)**: IMU history buffer + FallPredictor 평가.
    ///
    /// 5Hz IMU polling 동기화 — `lastBufferPushAt` 기준 ≥ 150ms 경과 시에만 push.
    ///
    /// 본 cycle (107) 에서 본체 → extension 이동. tick() 의 호출 흐름 동일.
    internal func updateFallPrediction() {
        let now = Date()

        // 2026-05-17 stale gate (Codex/agent #6 권고): IMU 가 5초+ 지연 시 predictor 우회.
        // 위험 시나리오: real → stale 전환 시 imuRollDeg/Pitch 가 freeze 되며 buffer 에
        // mixed (real + frozen) sample 누적 → 일시적으로 false positive emergency trigger.
        // L3 30° hard gate 는 imuRollDeg/Pitch 자체로 작동 (mitigationForState 분기) —
        // 본 predictor 만 차단해도 안전 net 손실 없음. C4 balance corrector 와 동일 원칙.
        if imuSource == .stale {
            if fallPrediction != .zero { fallPrediction = .zero }
            if !imuBuffer.isEmpty {
                imuBuffer.removeAll(keepingCapacity: true)
                lastBufferPushAt = nil
            }
            return
        }

        // Polling jitter 허용 — 너무 잦은 push 회피.
        if let last = lastBufferPushAt, now.timeIntervalSince(last) < 0.15 {
            // 그대로 마지막 prediction 유지 (재계산 X — score 변동 줄임).
            return
        }

        // Gyro 추출 — 실 IMU 우선, sim 은 derivative 근사.
        var gyroX: Double = 0
        var gyroY: Double = 0
        if imuSource == .real, let s = store, let imu = s.lastTelemetry?.imu {
            gyroX = Double(imu.gyroXDps)
            gyroY = Double(imu.gyroYDps)
        } else if let prev = imuBuffer.last {
            let dt = now.timeIntervalSince(prev.timestamp)
            if dt > 0.001 {
                gyroX = (imuRollDeg - prev.rollDeg) / dt    // deg / sec
                gyroY = (imuPitchDeg - prev.pitchDeg) / dt
            }
        }

        let sample = FallPredictor.Sample(
            timestamp: now,
            rollDeg: imuRollDeg,
            pitchDeg: imuPitchDeg,
            gyroXDps: gyroX,
            gyroYDps: gyroY
        )
        FallPredictor.append(sample, to: &imuBuffer)
        lastBufferPushAt = now

        fallPrediction = FallPredictor.predict(samples: imuBuffer, now: now)
    }
}
