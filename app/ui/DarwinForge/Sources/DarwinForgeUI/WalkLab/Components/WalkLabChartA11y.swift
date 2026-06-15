import Foundation

/// **V274-4 (2026-05-24) WCAG 1.1.1 + 1.3.1 — WalkLab chart 접근성 helper (real-time)**.
///
/// SwiftUI Charts 의 `AXChartDescriptor` 노출에 필요한 공통 변환/요약 유틸. 각 chart
/// struct 의 `AXChartDescriptorRepresentable.makeChartDescriptor()` 가 호출.
///
/// **설계**:
/// - `(Date, Double)` history → seconds-from-now offset 으로 정규화 (VoiceOver 의 audio
///   chart playback 은 monotonic x-axis 가 자연스러움 — Date timestamp 보다 "Nsec 전"
///   이 사용자가 청취하기 쉬움).
/// - 한국어 summary text — sample 수 / 평균 / peak 등 핵심 통계.
/// - 모든 함수 nonisolated, side-effect 없음, 50 line 이내.
///
/// **V276-4 (2026-05-24) 일관성 명시 (V275-3 critic 5차 MINOR-2)**:
/// WalkLab a11y helper 는 **도메인별 2개 namespace** 로 의도적으로 분리되어 있다.
///
/// | namespace | 위치 | 사용 chart | 입력 schema |
/// |-----------|------|-----------|-------------|
/// | `WalkLabChartA11y` (이 file) | `Components/` | `GyroSparklineChart`, `SceneWalkSparklineChart` | `[(Date, Double)]` (real-time tick) |
/// | `WalkDataChartA11y` | `Learning/WalkDataCharts.swift` | `WalkDataIMUChart`, `WalkDataBalanceStripChart`, `WalkDataCorrectorDeltaChart` | `[WalkSessionSample]` (post-session record) |
///
/// 두 namespace 통합을 검토했으나 입력 schema 가 근본적으로 달라
/// (live tick `(Date, Double)` vs. recorded `WalkSessionSample`) 통합 시 generic
/// boilerplate 가 helper 자체 크기를 초과. 5개 chart 모두 `AXChartDescriptorRepresentable`
/// conformance + namespace summary helper 패턴은 **일관**.
enum WalkLabChartA11y {

    // MARK: - History → time offset 변환

    /// `(timestamp, value)` 리스트를 가장 마지막 sample 기준 seconds offset 으로 변환.
    /// 가장 최근 = 0.0, 더 오래된 sample = 음수 (예: -3.2 = 3.2초 전).
    static func timeOffsetPoints(_ history: [(Date, Double)]) -> [(x: Double, y: Double)] {
        guard let last = history.last?.0 else { return [] }
        return history.map { (sample) -> (Double, Double) in
            let offsetSec = sample.0.timeIntervalSince(last)
            return (offsetSec, sample.1)
        }
    }

    // MARK: - Summary 빌더 — chart 별 한국어 요약

    /// LiveGyroPanel sparkline summary.
    static func gyroSparklineSummary(
        rollHistory: [(Date, Double)],
        pitchHistory: [(Date, Double)]
    ) -> String {
        let rollPeak = rollHistory.map { abs($0.1) }.max() ?? 0
        let pitchPeak = pitchHistory.map { abs($0.1) }.max() ?? 0
        let count = max(rollHistory.count, pitchHistory.count)
        return String(
            format: "최근 5초 IMU 기울기 변화 — sample %d개, Roll peak %.1f도, Pitch peak %.1f도",
            count, rollPeak, pitchPeak
        )
    }

    /// SceneWalkGraphOverlay sparkline summary (roll 단일 series).
    static func sceneWalkSparklineSummary(
        rollHistory: [(Date, Double)],
        phaseLabel: String
    ) -> String {
        let peak = rollHistory.map { abs($0.1) }.max() ?? 0
        return String(
            format: "보행 phase %@ — 최근 10초 Roll 진동, sample %d개, peak %.1f도",
            phaseLabel, rollHistory.count, peak
        )
    }
}
