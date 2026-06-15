import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 111: god object Phase 9 분할 (Safety Sampling)**.
///
/// `WalkLabSession.swift` (2861 line) 의 `recordSafetySampleAndEvents()` (~110 line)
/// 만 본 extension 으로 이동.
///
/// # 비유
///
/// 비행기 fly-by-wire 의 "안전 시계열 기록기" 모듈을 별도 부속실로 이전. 매 tick
/// 시계열 sample 기록 + 상태 전환 이벤트 발화 (balance / IMU / predictor / ramp).
///
/// # 분할 정책
///
/// - **method 1개 이동**: `recordSafetySampleAndEvents()`.
/// - 격상 (사이클 111):
///   - `safetyTimeline` (`private(set)` → `internal(set)`)
///   - `normalizedSafetyTimeline` (`private(set)` → `internal(set)`)
///   - `previousBalanceState` (private → internal)
///   - `previousImuSource` (private → internal)
///   - `previousMotorTempSource` (private → internal)
///   - `previousRecommendEmergency` (private → internal)
///   - `rampCompletedLogged` (private → internal)
/// - 호출 site `tick()` 동일. `logSafetyEvent` 는 이미 default internal.
///
/// # 회귀
///
/// 1299 tests 회귀 0 — 외부 API 변경 0 (모든 격상은 module-internal).
extension WalkLabSession {

    /// **Monitoring dashboard (2026-05-16)**: 매 tick 시계열 sample 기록 + 상태 전환
    /// 이벤트 감지. tick() 마지막에 호출.
    ///
    /// - sample: 매 tick 마다 1건 append, 10초 윈도우 + 250 sample 상한.
    /// - 이벤트:
    ///   - balanceState 변경 (rising/falling 모두) → `.stateChange`
    ///   - predictor recommendEmergency rising-edge → `.predictorRecommend`
    ///   - imuSource 변경 → `.imuSourceChange`
    ///   - ramp 0..1 완료 (rising-edge) → `.rampComplete`
    internal func recordSafetySampleAndEvents() {
        let now = Date()
        let maxDelta = lastCorrections?.maxAbs ?? 0
        let sample = SafetySample(
            timestamp: now,
            rollDeg: imuRollDeg,
            pitchDeg: imuPitchDeg,
            predictionScore: fallPrediction.score,
            balanceState: balanceState,
            correctorMaxDelta: maxDelta
        )
        // **2026-05-16 최적화 (Phase 2)**: 매 tick 의 3-step @Published 변경을
        // 단일 assignment 로 batch — publisher notification 3 → 1.
        // 이전: append + removeFirst (expired) + removeFirst (cap) = 3 mutations
        // 정정: local var 에서 작업 후 1회 assign — SwiftUI subscriber 부담 ↓.
        //
        // chronological 정렬 invariant 유지 — append always at end, prune from front.
        var newTimeline = safetyTimeline
        newTimeline.append(sample)
        let cutoff = now.addingTimeInterval(-Self.safetyTimelineMaxWindowSec)
        var firstValidIdx = 0
        while firstValidIdx < newTimeline.count,
              newTimeline[firstValidIdx].timestamp < cutoff {
            firstValidIdx += 1
        }
        if firstValidIdx > 0 {
            newTimeline.removeFirst(firstValidIdx)
        }
        if newTimeline.count > Self.safetyTimelineMaxSamples {
            newTimeline.removeFirst(newTimeline.count - Self.safetyTimelineMaxSamples)
        }
        safetyTimeline = newTimeline

        // **v1.14.8 (2026-05-21) perf #6** — normalized 캐시도 parallel batch.
        // raw 와 동일한 prune 정책 (시간 + cap). 새 sample 만 normalizeConvention
        // 1회 호출 → O(1) per tick (vs FallPreventionMonitor 의 O(N) per body redraw).
        let convention = balanceExperimentConfig.pitchInputConvention
        let mapped = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: sample.rollDeg,
            rawPitch: sample.pitchDeg,
            convention: convention
        )
        let normalized = NormalizedSafetySample(
            timestamp: sample.timestamp,
            rollDeg: mapped.roll,
            pitchDeg: mapped.pitch,
            predictionScore: sample.predictionScore
        )
        var newNormalized = normalizedSafetyTimeline
        newNormalized.append(normalized)
        if firstValidIdx > 0 && firstValidIdx <= newNormalized.count {
            newNormalized.removeFirst(firstValidIdx)
        }
        if newNormalized.count > Self.safetyTimelineMaxSamples {
            newNormalized.removeFirst(newNormalized.count - Self.safetyTimelineMaxSamples)
        }
        normalizedSafetyTimeline = newNormalized
        // **v1.14.8.1 (2026-05-21) — code-reviewer HIGH fix**: raw vs normalized 동기 invariant.
        // 두 배열은 동일 prune 정책 (시간/cap) + 동일 reset 지점 (start) 으로 항상 동일 길이
        // 유지. 미래 외부 mutation 시 mismatch 차단용 defensive assert. Release 빌드에선
        // no-op (assert) — perf 영향 없음.
        assert(safetyTimeline.count == normalizedSafetyTimeline.count,
               "safetyTimeline / normalizedSafetyTimeline 길이 동기 invariant 위반")

        // 이벤트 — balanceState 전환.
        if balanceState != previousBalanceState {
            logSafetyEvent(
                kind: .stateChange,
                message: "안전 상태: \(previousBalanceState.label) → \(balanceState.label)"
            )
            previousBalanceState = balanceState
        }

        // 이벤트 — predictor rising-edge.
        let recommend = fallPrediction.recommendEmergency
        if recommend, !previousRecommendEmergency {
            let etaStr = fallPrediction.etaMs.map { String(format: " (ETA %.0fms)", $0) } ?? ""
            logSafetyEvent(
                kind: .predictorRecommend,
                message: String(format: "예측 fall — score %.0f%@", fallPrediction.score, etaStr)
            )
        }
        previousRecommendEmergency = recommend

        // 이벤트 — IMU 출처 변경.
        if imuSource != previousImuSource {
            logSafetyEvent(
                kind: .imuSourceChange,
                message: "IMU 출처: \(previousImuSource.label) → \(imuSource.label)"
            )
            previousImuSource = imuSource
        }

        // 이벤트 — 모터 온도 출처 변경 (2026-05-16).
        if motorTempSource != previousMotorTempSource {
            logSafetyEvent(
                kind: .motorTempSourceChange,
                message: "모터 온도 출처: \(previousMotorTempSource.label) → \(motorTempSource.label)"
            )
            previousMotorTempSource = motorTempSource
        }

        // 이벤트 — ramp 완료 (rising-edge, OFF→ON 후 1초 도달 시 1회만).
        if enableBalanceCorrection,
           let progress = rampProgress,
           progress >= 1.0,
           !rampCompletedLogged {
            logSafetyEvent(kind: .rampComplete, message: "자세 보정 ramp 100% 도달 — 풀 적용")
            rampCompletedLogged = true
        }
    }
}
