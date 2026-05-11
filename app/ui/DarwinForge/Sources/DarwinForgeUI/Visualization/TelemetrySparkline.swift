import SwiftUI

/// 가벼운 라인 차트 — `Charts` framework 없이 Path만으로 그림.
/// 최근 N개 sample을 받아 정규화 후 그린다.
public struct TelemetrySparkline: View {
    public let samples: [Double]
    public let range: ClosedRange<Double>
    public let label: String
    public let unit: String
    public let color: Color

    /// 임계값 — 넘으면 라인 색 변경.
    public let warnThreshold: Double?

    public init(samples: [Double],
                range: ClosedRange<Double>,
                label: String,
                unit: String = "",
                color: Color = DFColor.accent,
                warnThreshold: Double? = nil) {
        self.samples = samples
        self.range = range
        self.label = label
        self.unit = unit
        self.color = color
        self.warnThreshold = warnThreshold
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if let last = samples.last {
                    Text(formatValue(last))
                        .font(DFFont.bodyEmph.monospaced())
                        .foregroundStyle(currentColor)
                }
            }
            chart
                .frame(height: 28)
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs + 2)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous))
    }

    private var currentColor: Color {
        guard let last = samples.last, let warn = warnThreshold else { return color }
        return last >= warn ? DFColor.warning : color
    }

    private var chart: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .leading) {
                // 기준선
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h - 1))
                    p.addLine(to: CGPoint(x: w, y: h - 1))
                }
                .stroke(DFColor.textSecondary.opacity(0.15), lineWidth: 0.5)

                if samples.count >= 2 {
                    line(in: CGSize(width: w, height: h))
                        .stroke(currentColor,
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    fillArea(in: CGSize(width: w, height: h))
                        .fill(LinearGradient(
                            colors: [currentColor.opacity(0.30), currentColor.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom)
                        )
                }
            }
        }
    }

    private func normY(_ v: Double, in h: CGFloat) -> CGFloat {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let t = (v - range.lowerBound) / span
        return h - CGFloat(t.clamped(to: 0...1)) * h
    }

    private func line(in size: CGSize) -> Path {
        Path { p in
            for (i, v) in samples.enumerated() {
                let x = CGFloat(i) / CGFloat(samples.count - 1) * size.width
                let y = normY(v, in: size.height)
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func fillArea(in size: CGSize) -> Path {
        Path { p in
            for (i, v) in samples.enumerated() {
                let x = CGFloat(i) / CGFloat(samples.count - 1) * size.width
                let y = normY(v, in: size.height)
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.addLine(to: CGPoint(x: 0, y: size.height))
            p.closeSubpath()
        }
    }

    private func formatValue(_ v: Double) -> String {
        let rounded = (v * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(v))\(unit)" : "\(rounded)\(unit)"
    }
}
