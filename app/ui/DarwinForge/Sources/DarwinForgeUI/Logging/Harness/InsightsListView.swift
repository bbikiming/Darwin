import Foundation
import SwiftUI

// MARK: - InsightsListView (v1.14.0)
//
// Inspector 의 SessionDetailView 안에 표시되는 인사이트 카드 리스트.
// 각 row 클릭 시 첫 번째 eventRef 로 점프.

struct InsightsListView: View {
    let insights: [Insight]
    let onJumpToEvent: (UInt64) -> Void

    var body: some View {
        if insights.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text("Insights")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Text("\(insights.count)")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
                VStack(spacing: 4) {
                    ForEach(insights) { insight in
                        InsightCard(insight: insight, onJump: {
                            if let first = insight.eventRefs.first {
                                onJumpToEvent(first)
                            }
                        })
                    }
                }
            }
        }
    }
}

private struct InsightCard: View {
    let insight: Insight
    let onJump: () -> Void

    var body: some View {
        Button(action: onJump) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    SeverityBadge(severity: insight.severity)
                    Text(insight.title)
                        .font(.system(.caption, design: .default).bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    // **v1.14.1 (Code-reviewer P1-2 fix)** — force unwrap 제거.
                    if let firstRef = insight.eventRefs.first {
                        Text("#\(firstRef)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(insight.evidence)
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(DFIcon.micro).foregroundStyle(.tertiary)
                    Text(insight.recommendation)
                        .font(.caption2).foregroundStyle(.primary.opacity(0.8))
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(severityTint(insight.severity).opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(severityTint(insight.severity).opacity(0.30), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SeverityBadge: View {
    let severity: Insight.Severity
    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced).bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 3).fill(severityTint(severity)))
    }
    private var label: String {
        switch severity {
        case .info: return "INFO"
        case .notice: return "NOTE"
        case .warn: return "WARN"
        case .critical: return "CRIT"
        }
    }
}

private func severityTint(_ s: Insight.Severity) -> Color {
    switch s {
    case .info: return .blue
    case .notice: return .indigo
    case .warn: return .orange
    case .critical: return .red
    }
}

// MARK: - Baseline diff view

struct BaselineDiffView: View {
    let diff: SessionDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(verdictTint)
                Text("Baseline 비교")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Text("(baseline #\(diff.baselineId.prefix(8)))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                verdictBadge
            }
            // 지표 4개만 표시 — 가장 의미 있는 것.
            VStack(spacing: 3) {
                ForEach(displayMetrics, id: \.label) { m in
                    MetricRow(metric: m)
                }
                ForEach(displayCounts, id: \.label) { c in
                    CountRow(count: c)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(verdictTint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(verdictTint.opacity(0.30), lineWidth: 0.8)
        )
    }

    private var displayMetrics: [MetricDelta] {
        diff.metrics.filter {
            $0.label == "RTT p95 (ms)" || $0.label == "연결 성공률" || $0.label == "IMU stale ratio"
        }
    }
    private var displayCounts: [CountDelta] {
        diff.counts.filter {
            $0.label == "에러" || $0.label == "E-stop" || $0.label == "보행 차단"
        }
    }

    @ViewBuilder
    private var verdictBadge: some View {
        let (text, tint) = verdictLabel
        Text(text)
            .font(.system(.caption2, design: .monospaced).bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint))
    }

    private var verdictLabel: (String, Color) {
        switch diff.verdict {
        case .improvement: return ("개선 \(Int(diff.weightedScorePercent))%", .green)
        case .regression: return ("회귀 +\(Int(diff.weightedScorePercent))%", .red)
        case .similar: return ("유사", .secondary)
        }
    }
    private var verdictTint: Color {
        switch diff.verdict {
        case .improvement: return .green
        case .regression: return .red
        case .similar: return .secondary
        }
    }
}

private struct MetricRow: View {
    let metric: MetricDelta

    var body: some View {
        HStack(spacing: 6) {
            Text(metric.label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(format(metric.baseline)).font(.system(.caption2, design: .monospaced))
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Image(systemName: "arrow.right").font(DFFont.pill).foregroundStyle(.tertiary)
            Text(format(metric.current)).font(.system(.caption2, design: .monospaced))
                .frame(width: 60, alignment: .leading)
            if let pct = metric.deltaPercent {
                Text(deltaLabel(pct: pct, lowerIsBetter: metric.lowerIsBetter))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(deltaTint(pct: pct, lowerIsBetter: metric.lowerIsBetter))
            }
            Spacer()
        }
    }

    private func format(_ d: Double?) -> String {
        guard let v = d else { return "—" }
        return String(format: "%.1f", v)
    }
}

private struct CountRow: View {
    let count: CountDelta

    var body: some View {
        HStack(spacing: 6) {
            Text(count.label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text("\(count.baseline)").font(.system(.caption2, design: .monospaced))
                .frame(width: 60, alignment: .trailing).foregroundStyle(.tertiary)
            Image(systemName: "arrow.right").font(DFFont.pill).foregroundStyle(.tertiary)
            Text("\(count.current)").font(.system(.caption2, design: .monospaced))
                .frame(width: 60, alignment: .leading)
            Text(deltaLabelInt(delta: count.delta, lowerIsBetter: count.lowerIsBetter))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(deltaTintInt(delta: count.delta, lowerIsBetter: count.lowerIsBetter))
            Spacer()
        }
    }
}

private func deltaLabel(pct: Double, lowerIsBetter: Bool) -> String {
    let sign = pct > 0 ? "+" : ""
    return "\(sign)\(Int(pct))%"
}

private func deltaTint(pct: Double, lowerIsBetter: Bool) -> Color {
    if abs(pct) < 5 { return .secondary }
    let isWorse = lowerIsBetter ? pct > 0 : pct < 0
    return isWorse ? .red : .green
}

private func deltaLabelInt(delta: Int, lowerIsBetter: Bool) -> String {
    if delta == 0 { return "0" }
    return delta > 0 ? "+\(delta)" : "\(delta)"
}
private func deltaTintInt(delta: Int, lowerIsBetter: Bool) -> Color {
    if delta == 0 { return .secondary }
    let isWorse = lowerIsBetter ? delta > 0 : delta < 0
    return isWorse ? .red : .green
}

// MARK: - Live alerts banner

struct LiveAlertsBanner: View {
    @ObservedObject var alerts = HarnessLiveAlerts.shared

    var body: some View {
        if alerts.active.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("라이브 알림 \(alerts.active.count)")
                        .font(.caption.bold())
                    Spacer()
                    Toggle("토스트", isOn: Binding(
                        get: { alerts.toastEnabled },
                        set: { alerts.toastEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .font(.caption2)
                    .controlSize(.mini)
                }
                // **V289-5** — 각 알림 행에 severity + 메시지 결합 accessibilityLabel.
                ForEach(alerts.active) { alert in
                    HStack(spacing: 6) {
                        Circle().fill(tint(alert.severity)).frame(width: 6, height: 6)
                        Text(alert.title).font(.caption2).foregroundStyle(.primary)
                        Spacer()
                        Text(alert.detail).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(alert.severity.rawValue) — \(alert.title): \(alert.detail)")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.3), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("라이브 알림 \(alerts.active.count)건")
        }
    }

    private func tint(_ s: ActiveAlert.Severity) -> Color {
        switch s {
        case .info: return .blue
        case .notice: return .indigo
        case .warn: return .orange
        case .critical: return .red
        }
    }
}
