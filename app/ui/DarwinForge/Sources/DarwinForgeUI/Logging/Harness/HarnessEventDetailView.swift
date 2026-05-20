import AppKit
import Foundation
import SwiftUI

// MARK: - HarnessEventDetailView (v1.12.1, 2026-05-20)
//
// Inspector 의 event row 를 선택하면 펼쳐지는 상세 패널.
// - 시각 / 순번 / 세션 / kind / level / actor 헤더
// - context 블록 (연결 / endpoint / section / battery / RTT / IMU stale)
// - payload — JSON pretty-print + 복사 버튼
// - 시간 축 navigator (이 이벤트 ± 5 개)

/// 선택된 이벤트 한 개에 대한 상세 뷰. 자체 ScrollView — Inspector 의 split 우측 하단에 사용.
struct HarnessEventDetailView: View {
    let event: TelemetryEvent
    /// 같은 세션의 이벤트 시간순 리스트 — 이전/다음 nav 에 사용.
    let neighbors: [TelemetryEvent]
    /// 클릭 시 selection 갱신.
    let onSelectNeighbor: (TelemetryEvent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerBlock
                Divider()
                contextBlock
                Divider()
                payloadBlock
                Divider()
                timelineBlock
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LevelBadge(level: event.lv)
                Text(event.k.rawValue)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    copy(eventJSON)
                } label: {
                    Label("이벤트 복사", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("이 이벤트 1줄 JSON 을 클립보드로")
            }

            HStack(spacing: 16) {
                MetaCell(label: "Seq",
                         value: "#\(event.i)")
                MetaCell(label: "Wall clock",
                         value: longTime(event.tw))
                MetaCell(label: "Monotonic",
                         value: monotonicHuman(event.tm))
                MetaCell(label: "Actor",
                         value: event.a.rawValue)
            }

            HStack(spacing: 16) {
                MetaCell(label: "Session",
                         value: String(event.s.prefix(8)))
                MetaCell(label: "Schema",
                         value: "v\(event.v)")
                MetaCell(label: "Namespace",
                         value: event.k.namespace)
            }
        }
    }

    // MARK: - Context

    @ViewBuilder
    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context (스냅샷)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if let c = event.c {
                HStack(spacing: 12) {
                    ContextPill(icon: "antenna.radiowaves.left.and.right",
                                label: "연결",
                                value: c.cn.map { $0.rawValue } ?? "—",
                                tint: connectionTint(c.cn))
                    ContextPill(icon: "cable.connector",
                                label: "Endpoint",
                                value: c.ep ?? "—",
                                tint: .secondary)
                    ContextPill(icon: "sidebar.left",
                                label: "Section",
                                value: c.sc ?? "—",
                                tint: .secondary)
                }
                HStack(spacing: 12) {
                    ContextPill(icon: "battery.100",
                                label: "전압",
                                value: c.bv.map { String(format: "%.1f V", $0) } ?? "—",
                                tint: voltageTint(c.bv))
                    ContextPill(icon: "stopwatch",
                                label: "RTT",
                                value: c.rt.map { String(format: "%.1f ms", $0) } ?? "—",
                                tint: rttTint(c.rt))
                    ContextPill(icon: "rotate.3d",
                                label: "IMU",
                                value: c.im == true ? "stale" : (c.im == false ? "ok" : "—"),
                                tint: c.im == true ? .orange : .secondary)
                }
            } else {
                Text("이 이벤트는 context 스냅샷이 없어요 (앱 시작 직후 등).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Payload

    @ViewBuilder
    private var payloadBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Payload")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("\(event.d.raw.count) 필드")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    copy(payloadJSON)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("payload JSON 복사")
            }
            if event.d.raw.isEmpty {
                Text("(빈 payload)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(payloadJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
                }
            }
        }
    }

    // MARK: - Timeline navigator

    @ViewBuilder
    private var timelineBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("이 시점 주변")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(window) { ev in
                Button {
                    onSelectNeighbor(ev)
                } label: {
                    HStack(spacing: 8) {
                        if ev.id == event.id {
                            Image(systemName: "arrowtriangle.right.fill")
                                .foregroundStyle(.blue)
                                .font(.caption2)
                        } else {
                            Image(systemName: "circle.dotted")
                                .foregroundStyle(.tertiary)
                                .font(.caption2)
                        }
                        Text(briefTime(ev.tw))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
                        Text(ev.k.rawValue)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(ev.lv.rawValue)
                            .font(.caption2)
                            .foregroundStyle(level(ev.lv))
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(ev.id == event.id ? Color.blue.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private var window: [TelemetryEvent] {
        // 현재 이벤트 ± 5 개.
        guard let idx = neighbors.firstIndex(of: event) else { return [event] }
        let lo = max(0, idx - 5)
        let hi = min(neighbors.count, idx + 6)
        return Array(neighbors[lo..<hi])
    }

    private var eventJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(event), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "(encode failed)"
    }

    private var payloadJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(event.d.raw), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "(empty)"
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func level(_ lv: TelemetryLevel) -> Color {
        switch lv {
        case .trace: return .secondary
        case .info: return .primary
        case .notice: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func connectionTint(_ s: TelemetryContext.ConnectionState?) -> Color {
        switch s {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        case .error: return .red
        case nil: return .secondary
        }
    }

    private func voltageTint(_ v: Double?) -> Color {
        guard let v = v else { return .secondary }
        if v < 9.5 { return .red }
        if v < 10.5 { return .orange }
        return .green
    }

    private func rttTint(_ r: Double?) -> Color {
        guard let r = r else { return .secondary }
        if r > 50 { return .orange }
        if r > 100 { return .red }
        return .secondary
    }

    private func longTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return out.string(from: d)
        }
        return iso
    }

    private func monotonicHuman(_ ns: UInt64) -> String {
        let seconds = Double(ns) / 1_000_000_000.0
        if seconds < 60 { return String(format: "%.3f s", seconds) }
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%dm %.2fs", m, s)
    }

    private func briefTime(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "HH:mm:ss.SSS"
            return out.string(from: d)
        }
        return iso
    }
}

// MARK: - Small reusable bits

struct LevelBadge: View {
    let level: TelemetryLevel
    var body: some View {
        Text(level.rawValue.uppercased())
            .font(.system(.caption2, design: .monospaced).bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
    }
    private var color: Color {
        switch level {
        case .trace: return .gray
        case .info: return .blue
        case .notice: return .indigo
        case .warn: return .orange
        case .error: return .red
        }
    }
}

struct ContextPill: View {
    let icon: String
    let label: String
    let value: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(tint).font(.caption2)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.caption2).foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.08)))
    }
}

// MARK: - Namespace counter summary

struct HarnessNamespaceSummary: View {
    let events: [TelemetryEvent]

    var body: some View {
        let buckets = bucketed
        if buckets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Namespace 분포 (총 \(events.count) 개)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                FlowingHStack(spacing: 6) {
                    ForEach(buckets, id: \.0) { ns, count in
                        HStack(spacing: 3) {
                            Text(ns).font(.system(.caption2, design: .monospaced))
                            Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.10)))
                    }
                }
            }
        }
    }

    private var bucketed: [(String, Int)] {
        var dict: [String: Int] = [:]
        for ev in events {
            dict[ev.k.namespace, default: 0] += 1
        }
        return dict.sorted { $0.value > $1.value }
    }
}

/// 매우 단순한 flowing HStack (LazyVGrid 없이도 동작).
struct FlowingHStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }
    var body: some View {
        // LazyVGrid 로 자동 wrap.
        let columns = [GridItem(.adaptive(minimum: 100), spacing: spacing)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            content()
        }
    }
}
