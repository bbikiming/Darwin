import Foundation
import SwiftUI

// MARK: - SessionSummaryView (v1.13.0)
//
// 세션 detail 상단에 표시되는 통계 카드 + 타임라인 strip + 에러 환경 헤드라인.
// SessionAnalysis (pure) 의 결과를 시각화.

struct SessionSummaryView: View {
    let analysis: SessionAnalysis
    /// 타임라인 칸 클릭 시 — 해당 시각으로 점프 (상위 detail view 가 처리).
    let onJumpToTime: (Date) -> Void
    /// 사용자가 ZIP / Markdown 내보내기를 트리거.
    let onExportMarkdown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            highlightCards
            timelineStrip
            namespaceLegend
        }
    }

    // MARK: - Highlight cards

    private var highlightCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                StatCard(
                    title: "기간",
                    value: analysis.summary.durationLabel() ?? "—",
                    icon: "clock", tint: .blue
                )
                StatCard(
                    title: "이벤트",
                    value: "\(analysis.summary.totalEvents)",
                    icon: "doc.text", tint: .secondary
                )
                StatCard(
                    title: "연결 성공",
                    value: "\(analysis.summary.connectSuccesses) / \(analysis.summary.connectAttempts)",
                    subtitle: failureSubtitle,
                    icon: "antenna.radiowaves.left.and.right",
                    tint: connectTint
                )
                StatCard(
                    title: "평균 RTT",
                    value: rttDisplay,
                    subtitle: rttP95Display,
                    icon: "stopwatch", tint: rttTint
                )
                StatCard(
                    title: "배터리",
                    value: batteryDisplay,
                    subtitle: batteryRange,
                    icon: "battery.100", tint: batteryTint
                )
                StatCard(
                    title: "에러 / 경고",
                    value: "\(analysis.summary.errorCount) / \(analysis.summary.warnCount)",
                    subtitle: errorSubtitle,
                    icon: "exclamationmark.triangle",
                    tint: analysis.summary.errorCount > 0 ? .red :
                          (analysis.summary.warnCount > 0 ? .orange : .green)
                )
                StatCard(
                    title: "WalkLab",
                    value: "\(analysis.summary.walkLabStarts) start",
                    subtitle: walkLabSubtitle,
                    icon: "figure.walk",
                    tint: analysis.summary.walkLabEmergencyStops > 0 ? .red : .secondary
                )
                StatCard(
                    title: "자세 저장",
                    value: "\(analysis.summary.teachSnapshots)",
                    subtitle: "라이브러리 \(analysis.summary.poseLibrarySaves)",
                    icon: "bookmark", tint: .indigo
                )
                if analysis.dropped > 0 {
                    StatCard(
                        title: "Drop",
                        value: "\(analysis.dropped)",
                        subtitle: "이벤트 버퍼 초과",
                        icon: "tray.full", tint: .orange
                    )
                }
                Button {
                    onExportMarkdown()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.richtext")
                        Text("Markdown 리포트")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("이 세션을 마크다운으로 — Claude / 동료 공유용")
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Timeline strip

    private var timelineStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Timeline")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if let first = analysis.summary.firstEventAt,
                   let last = analysis.summary.lastEventAt {
                    Text("\(briefTime(first))  →  \(briefTime(last))")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if analysis.timeline.isEmpty {
                Text("타임라인 그릴 데이터 부족.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(height: 40)
            } else {
                GeometryReader { geo in
                    let width = max(0, geo.size.width)
                    let columnWidth = width / CGFloat(analysis.timeline.count)
                    HStack(spacing: 0) {
                        ForEach(analysis.timeline) { bin in
                            TimelineColumn(bin: bin,
                                            maxCount: maxTimelineCount,
                                            width: columnWidth)
                                .onTapGesture {
                                    onJumpToTime(Date(timeIntervalSince1970: bin.start))
                                }
                                .help(tooltipFor(bin))
                        }
                    }
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Namespace legend

    private var namespaceLegend: some View {
        let top = Array(analysis.summary.namespaceCounts.prefix(8))
        return HStack(spacing: 6) {
            ForEach(top) { ns in
                HStack(spacing: 3) {
                    Circle().fill(colorFor(namespace: ns.namespace))
                        .frame(width: 7, height: 7)
                    Text(ns.namespace)
                        .font(.system(.caption2, design: .monospaced))
                    Text("\(ns.count)").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.08)))
            }
            Spacer()
        }
    }

    // MARK: - Computed helpers

    private var maxTimelineCount: Int {
        analysis.timeline.map { $0.totalCount }.max() ?? 1
    }

    private var rttDisplay: String {
        guard let s = analysis.summary.rttMs else { return "—" }
        return String(format: "%.1f ms", s.mean)
    }

    private var rttP95Display: String? {
        guard let s = analysis.summary.rttMs else { return nil }
        return String(format: "p95 %.0f ms", s.p95)
    }

    private var rttTint: Color {
        guard let s = analysis.summary.rttMs else { return .secondary }
        if s.p95 > 100 { return .red }
        if s.p95 > 50 { return .orange }
        return .green
    }

    private var batteryDisplay: String {
        guard let s = analysis.summary.batteryV else { return "—" }
        return String(format: "%.1f V", s.mean)
    }

    private var batteryRange: String? {
        guard let s = analysis.summary.batteryV else { return nil }
        return String(format: "min %.1f / max %.1f", s.min, s.max)
    }

    private var batteryTint: Color {
        guard let s = analysis.summary.batteryV else { return .secondary }
        if s.min < 9.5 { return .red }
        if s.min < 10.5 { return .orange }
        return .green
    }

    private var failureSubtitle: String? {
        let f = analysis.summary.connectFailures
        return f > 0 ? "실패 \(f)" : nil
    }

    private var connectTint: Color {
        let a = analysis.summary.connectAttempts
        let s = analysis.summary.connectSuccesses
        if a == 0 { return .secondary }
        if Double(s) / Double(max(1, a)) < 0.5 { return .red }
        return .green
    }

    private var errorSubtitle: String? {
        let b = analysis.summary.busReadFailures + analysis.summary.busWriteFailures
        let e = analysis.summary.eStops
        var parts: [String] = []
        if b > 0 { parts.append("bus \(b)") }
        if e > 0 { parts.append("e-stop \(e)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var walkLabSubtitle: String? {
        var parts: [String] = []
        if analysis.summary.walkLabEmergencyStops > 0 {
            parts.append("emerg \(analysis.summary.walkLabEmergencyStops)")
        }
        if analysis.summary.walkLabStartBlocks > 0 {
            parts.append("blocked \(analysis.summary.walkLabStartBlocks)")
        }
        return parts.isEmpty ? "stop \(analysis.summary.walkLabStops)" : parts.joined(separator: " · ")
    }

    private func tooltipFor(_ bin: TimelineBin) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let s = f.string(from: Date(timeIntervalSince1970: bin.start))
        let e = f.string(from: Date(timeIntervalSince1970: bin.end))
        let top = bin.counts.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return "\(s)–\(e)\n총 \(bin.totalCount)\n\(top)"
    }

    private func briefTime(_ iso: String) -> String {
        guard let d = SessionAnalyzer.parseIso(iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint).font(.caption2)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .rounded).bold())
                .foregroundStyle(tint)
            if let sub = subtitle {
                Text(sub).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 110, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.18), lineWidth: 0.8)
        )
    }
}

// MARK: - Timeline column

private struct TimelineColumn: View {
    let bin: TimelineBin
    let maxCount: Int
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            // 배경 — peak level 색.
            Rectangle()
                .fill(peakColor.opacity(bin.totalCount == 0 ? 0.04 : 0.12))
            // namespace stacked bar.
            VStack(spacing: 0) {
                Spacer()
                ForEach(stackOrder, id: \.self) { ns in
                    if let n = bin.counts[ns], n > 0 {
                        Rectangle()
                            .fill(colorFor(namespace: ns))
                            .frame(height: heightFor(count: n))
                    }
                }
            }
        }
        .frame(width: max(1, width), height: 44)
    }

    private var stackOrder: [String] {
        // 안정 순서를 위해 알파벳 정렬.
        bin.counts.keys.sorted()
    }

    private var peakColor: Color {
        switch bin.peakLevel {
        case .trace: return .clear
        case .info: return .blue
        case .notice: return .indigo
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func heightFor(count: Int) -> CGFloat {
        guard maxCount > 0 else { return 0 }
        let frac = CGFloat(count) / CGFloat(maxCount)
        return min(40, max(1, frac * 40))
    }
}

// MARK: - Namespace palette

func colorFor(namespace: String) -> Color {
    // 결정론적 색상 — namespace 별 같은 색 유지.
    switch namespace {
    case "connection": return .green
    case "bus":        return .red
    case "imu":        return .orange
    case "ui":         return .blue
    case "user":       return .blue
    case "motion":     return .indigo
    case "walklab":    return .purple
    case "pose":       return .teal
    case "pilot":      return .cyan
    case "teach":      return .mint
    case "claude":     return .pink
    case "heartbeat":  return .gray.opacity(0.7)
    case "harness":    return .yellow
    case "error":      return .red
    case "app":        return .secondary
    default:           return Color(hue: hashHue(namespace), saturation: 0.55, brightness: 0.78)
    }
}

private func hashHue(_ s: String) -> Double {
    var h: UInt32 = 5381
    for byte in s.utf8 { h = (h &* 33) &+ UInt32(byte) }
    return Double(h % 360) / 360.0
}
