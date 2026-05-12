import Charts
import SwiftUI

/// 멀티채널 strip chart — 엔지니어 콘솔용.
/// 각 채널 line + 자동 색상 매핑 + 모노스페이스 축 + Y 자동 / 수동 스케일.
public struct TimeSeriesStripChart: View {
    public struct Channel: Identifiable {
        public let id: String           // "gyro.x", "accel.z", etc.
        public let label: String
        public let color: Color
        public let samples: [TimeSample]
        public let visible: Bool
        public init(id: String, label: String, color: Color,
                    samples: [TimeSample], visible: Bool = true) {
            self.id = id; self.label = label; self.color = color
            self.samples = samples; self.visible = visible
        }
    }

    public let channels: [Channel]
    public let yDomain: ClosedRange<Double>?   // nil → auto.
    public let xDomain: ClosedRange<Double>?   // nil → auto.
    public let yUnit: String                    // "rad/s" / "m/s²" / "deg" / etc.
    public let title: String
    public let height: CGFloat

    public init(channels: [Channel],
                title: String,
                yUnit: String,
                yDomain: ClosedRange<Double>? = nil,
                xDomain: ClosedRange<Double>? = nil,
                height: CGFloat = 180) {
        self.channels = channels
        self.title = title
        self.yUnit = yUnit
        self.yDomain = yDomain
        self.xDomain = xDomain
        self.height = height
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            header
            chart
                .frame(height: height)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: DFRadius.sm)
                        .fill(DFColor.canvas.opacity(DFOpacity.o45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.sm)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: 0.5)
                )
        }
    }

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Text(title)
                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DFColor.textPrimary)
            Spacer(minLength: 6)
            ForEach(channels) { ch in
                if ch.visible {
                    HStack(spacing: DFSpace.xs) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(ch.color)
                            .frame(width: 12, height: 2)
                        Text(ch.label)
                            .font(.system(size: DFFontSize.s10, design: .monospaced))
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
            }
            Text("[\(yUnit)]")
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o70))
        }
    }

    private var chart: some View {
        Chart {
            ForEach(channels) { ch in
                if ch.visible {
                    ForEach(ch.samples) { s in
                        LineMark(
                            x: .value("t", s.t),
                            y: .value(ch.label, s.v)
                        )
                        .foregroundStyle(ch.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        .interpolationMethod(.linear)
                    }
                    .foregroundStyle(by: .value("ch", ch.id))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: channels.map(\.id),
            range: channels.map(\.color)
        )
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o15))
                AxisTick().foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.disabled))
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text(String(format: "%.1fs", t))
                            .font(.system(size: DFFontSize.s9, design: .monospaced))
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o15))
                AxisTick().foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.disabled))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(String(format: "%+.2f", v))
                            .font(.system(size: DFFontSize.s9, design: .monospaced))
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain ?? autoXDomain())
        .chartYScale(domain: yDomain ?? autoYDomain())
    }

    private func autoXDomain() -> ClosedRange<Double> {
        var lo = Double.infinity, hi = -Double.infinity
        for ch in channels where ch.visible {
            for s in ch.samples {
                if s.t < lo { lo = s.t }
                if s.t > hi { hi = s.t }
            }
        }
        if !lo.isFinite || !hi.isFinite || hi <= lo {
            return 0...1
        }
        // 마지막 sweep 가 살짝 오른쪽 마진 갖도록 + 1% 마진.
        let span = max(0.001, hi - lo)
        return lo...(hi + span * 0.02)
    }

    private func autoYDomain() -> ClosedRange<Double> {
        var lo = Double.infinity, hi = -Double.infinity
        for ch in channels where ch.visible {
            for s in ch.samples {
                if s.v < lo { lo = s.v }
                if s.v > hi { hi = s.v }
            }
        }
        if !lo.isFinite || !hi.isFinite {
            return -1...1
        }
        if hi == lo {
            return (lo - 0.5)...(hi + 0.5)
        }
        let pad = (hi - lo) * 0.10
        return (lo - pad)...(hi + pad)
    }
}
