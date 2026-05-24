import SwiftUI
import Charts
import Accessibility

/// **V274-4 (2026-05-24) WCAG 1.1.1 + 1.3.1 — WalkData detail charts + a11y**.
///
/// WalkDataView 의 3개 chart (imuChart / balanceStateStrip / correctorDeltaChart) 를
/// 별도 struct 로 추출하여 각각 `AXChartDescriptorRepresentable` conformance 부여.
/// 종전엔 inline Chart 라 VoiceOver 가 "chart" 만 announce 하고 데이터 탐색 불가.
///
/// **WCAG 위반 (V271-2 audit P1)**: Charts 가 chart 구조 (axis / series / data point)
/// 를 노출하지 않음 → 시각 장애 사용자가 보행 분석 데이터 접근 불가.
///
/// **fix**: AXChartDescriptor 로 한국어 title / summary / x-axis (시간) / y-axis (도)
/// / data series 노출. VoiceOver audio chart playback 가능.
///
/// 모든 chart 는 기존 시각적 표현 그대로 유지 (additive — color / scale / mark 변경 X).

// MARK: - IMU Roll / Pitch chart

struct WalkDataIMUChart: View {
    let samples: [WalkSessionSample]

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("t", s.t / 1000.0), y: .value("Roll", s.imuRollDeg))
                    .foregroundStyle(by: .value("Series", "Roll"))
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("t", s.t / 1000.0), y: .value("Pitch", s.imuPitchDeg))
                    .foregroundStyle(by: .value("Series", "Pitch"))
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o25))
        }
        .chartForegroundStyleScale(["Roll": DFColor.info, "Pitch": DFColor.accent])
        .chartXAxisLabel("시간 (s)")
        .chartYAxisLabel("각도 (°)")
        .frame(height: 200)
        .accessibilityChartDescriptor(self)
    }
}

extension WalkDataIMUChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let tValues = samples.map { $0.t / 1000.0 }
        let xMin = tValues.min() ?? 0
        let xMax = tValues.max() ?? 1
        let allDeg = samples.flatMap { [$0.imuRollDeg, $0.imuPitchDeg] }
        let yPeak = max(45.0, (allDeg.map(abs).max() ?? 0) + 5.0)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "시간 (초)",
            range: xMin...xMax,
            gridlinePositions: WalkDataChartA11y.evenGridlines(min: xMin, max: xMax, count: 5)
        ) { value in String(format: "%.1f초", value) }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "각도 (도)",
            range: -yPeak...yPeak,
            gridlinePositions: [-30, -15, 0, 15, 30]
        ) { value in "\(Int(value))도" }
        let rollSeries = AXDataSeriesDescriptor(
            name: "Roll (좌우 기울기)",
            isContinuous: true,
            dataPoints: samples.map {
                AXDataPoint(x: $0.t / 1000.0, y: $0.imuRollDeg)
            }
        )
        let pitchSeries = AXDataSeriesDescriptor(
            name: "Pitch (앞뒤 기울기)",
            isContinuous: true,
            dataPoints: samples.map {
                AXDataPoint(x: $0.t / 1000.0, y: $0.imuPitchDeg)
            }
        )
        return AXChartDescriptor(
            title: "IMU Roll / Pitch 시계열",
            summary: WalkDataChartA11y.imuSummary(samples: samples),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [rollSeries, pitchSeries]
        )
    }
}

// MARK: - Balance state strip chart

struct WalkDataBalanceStripChart: View {
    let samples: [WalkSessionSample]
    let stateColor: (String) -> Color

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                BarMark(
                    x: .value("t", s.t / 1000.0),
                    y: .value("state", 1)
                )
                .foregroundStyle(stateColor(s.balanceState))
            }
        }
        .chartYAxis(.hidden)
        .chartXAxisLabel("시간 (s)")
        .frame(height: 40)
        .accessibilityChartDescriptor(self)
    }
}

extension WalkDataBalanceStripChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let tValues = samples.map { $0.t / 1000.0 }
        let xMin = tValues.min() ?? 0
        let xMax = tValues.max() ?? 1
        let xAxis = AXNumericDataAxisDescriptor(
            title: "시간 (초)",
            range: xMin...xMax,
            gridlinePositions: WalkDataChartA11y.evenGridlines(min: xMin, max: xMax, count: 5)
        ) { value in String(format: "%.1f초", value) }
        // y-axis = balance state ordinal (normal=0, caution=1, warning=2, danger=3, emergency=4).
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Balance 상태",
            range: 0.0...4.0,
            gridlinePositions: [0, 1, 2, 3, 4]
        ) { value in WalkDataChartA11y.stateLabelKo(ordinal: Int(value)) }
        let series = AXDataSeriesDescriptor(
            name: "Balance 상태 시퀀스",
            isContinuous: false,
            dataPoints: samples.map { s in
                let ord = WalkDataChartA11y.stateOrdinal(s.balanceState)
                let label = WalkDataChartA11y.stateLabelKo(ordinal: ord)
                return AXDataPoint(
                    x: s.t / 1000.0,
                    y: Double(ord),
                    additionalValues: [],
                    label: label
                )
            }
        )
        return AXChartDescriptor(
            title: "Balance State 시간 strip",
            summary: WalkDataChartA11y.balanceStripSummary(samples: samples),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

// MARK: - Corrector delta chart (R/L hip_roll)

struct WalkDataCorrectorDeltaChart: View {
    let samples: [WalkSessionSample]

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                LineMark(
                    x: .value("t", s.t / 1000.0),
                    y: .value("R hipRoll", s.correctorDeltas.first ?? 0)
                )
                .foregroundStyle(by: .value("Series", "R hipRoll"))
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                LineMark(
                    x: .value("t", s.t / 1000.0),
                    y: .value("L hipRoll", s.correctorDeltas.dropFirst().first ?? 0)
                )
                .foregroundStyle(by: .value("Series", "L hipRoll"))
            }
            RuleMark(y: .value("zero", 0))
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o25))
        }
        .chartForegroundStyleScale(["R hipRoll": DFColor.forge, "L hipRoll": DFColor.success])
        .chartXAxisLabel("시간 (s)")
        .chartYAxisLabel("delta (°)")
        .frame(height: 150)
        .accessibilityChartDescriptor(self)
    }
}

extension WalkDataCorrectorDeltaChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let tValues = samples.map { $0.t / 1000.0 }
        let xMin = tValues.min() ?? 0
        let xMax = tValues.max() ?? 1
        let rDeltas = samples.map { $0.correctorDeltas.first ?? 0 }
        let lDeltas = samples.map { $0.correctorDeltas.dropFirst().first ?? 0 }
        let allDelta = rDeltas + lDeltas
        let yPeak = max(5.0, (allDelta.map(abs).max() ?? 0) + 1.0)
        let xAxis = AXNumericDataAxisDescriptor(
            title: "시간 (초)",
            range: xMin...xMax,
            gridlinePositions: WalkDataChartA11y.evenGridlines(min: xMin, max: xMax, count: 5)
        ) { value in String(format: "%.1f초", value) }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Delta (도)",
            range: -yPeak...yPeak,
            gridlinePositions: [-yPeak, -yPeak / 2, 0, yPeak / 2, yPeak]
        ) { value in String(format: "%+.1f도", value) }
        let rSeries = AXDataSeriesDescriptor(
            name: "오른쪽 hip_roll 보정",
            isContinuous: true,
            dataPoints: zip(tValues, rDeltas).map { AXDataPoint(x: $0.0, y: $0.1) }
        )
        let lSeries = AXDataSeriesDescriptor(
            name: "왼쪽 hip_roll 보정",
            isContinuous: true,
            dataPoints: zip(tValues, lDeltas).map { AXDataPoint(x: $0.0, y: $0.1) }
        )
        return AXChartDescriptor(
            title: "Corrector delta — R/L hip_roll",
            summary: WalkDataChartA11y.correctorSummary(
                samples: samples, rPeak: rDeltas.map(abs).max() ?? 0,
                lPeak: lDeltas.map(abs).max() ?? 0
            ),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [rSeries, lSeries]
        )
    }
}

// MARK: - Helper
//
// **V276-4 (2026-05-24) 일관성 명시 (V275-3 critic 5차 MINOR-2)**:
// `WalkLabChartA11y` (real-time, `(Date, Double)` schema) 와 본 namespace 는
// 의도적 도메인 분리. 통합 시 generic boilerplate 가 helper 자체 크기 초과 (input
// schema 가 근본적으로 다름: live tick vs. recorded `WalkSessionSample`).
// 5개 chart 모두 `AXChartDescriptorRepresentable` conformance + namespace summary
// helper 패턴은 일관. 자세한 매핑 표는 `WalkLabChartA11y.swift` 의 docstring 참고.

enum WalkDataChartA11y {
    static func evenGridlines(min: Double, max: Double, count: Int) -> [Double] {
        guard count > 1, max > min else { return [min, max] }
        let step = (max - min) / Double(count - 1)
        return (0..<count).map { min + Double($0) * step }
    }

    static func stateOrdinal(_ s: String) -> Int {
        switch s {
        case "normal":    return 0
        case "caution":   return 1
        case "warning":   return 2
        case "danger":    return 3
        case "emergency": return 4
        default:          return 0
        }
    }

    static func stateLabelKo(ordinal: Int) -> String {
        switch ordinal {
        case 0: return "정상"
        case 1: return "주의"
        case 2: return "경고"
        case 3: return "위험"
        case 4: return "비상"
        default: return "정상"
        }
    }

    static func imuSummary(samples: [WalkSessionSample]) -> String {
        let rollPeak = samples.map { abs($0.imuRollDeg) }.max() ?? 0
        let pitchPeak = samples.map { abs($0.imuPitchDeg) }.max() ?? 0
        let dur = (samples.last?.t ?? 0) / 1000.0
        return String(
            format: "보행 세션 IMU 시계열 — sample %d개, %.1f초, Roll peak %.1f도, Pitch peak %.1f도",
            samples.count, dur, rollPeak, pitchPeak
        )
    }

    static func balanceStripSummary(samples: [WalkSessionSample]) -> String {
        var counts: [Int: Int] = [:]
        for s in samples {
            let ord = stateOrdinal(s.balanceState)
            counts[ord, default: 0] += 1
        }
        let total = max(1, samples.count)
        let normalPct = Int(Double(counts[0] ?? 0) / Double(total) * 100)
        let dangerPct = Int(Double((counts[3] ?? 0) + (counts[4] ?? 0)) / Double(total) * 100)
        return String(
            format: "Balance 상태 시간 strip — sample %d개, 정상 %d%%, 위험 이상 %d%%",
            samples.count, normalPct, dangerPct
        )
    }

    static func correctorSummary(samples: [WalkSessionSample], rPeak: Double, lPeak: Double) -> String {
        return String(
            format: "Corrector 보정 출력 — sample %d개, R peak %.1f도, L peak %.1f도",
            samples.count, rPeak, lPeak
        )
    }
}
