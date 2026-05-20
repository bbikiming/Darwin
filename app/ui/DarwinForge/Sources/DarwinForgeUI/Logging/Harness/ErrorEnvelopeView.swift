import Foundation
import SwiftUI

// MARK: - ErrorEnvelopeSheet (v1.13.0)
//
// 시트 wrapper. 위쪽에 close + 카운트, 본체는 ErrorEnvelopeView.

struct ErrorEnvelopeSheet: View {
    let envelopes: [ErrorEnvelope]
    let onJumpToEvent: (TelemetryEvent) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("에러 둘러보기")
                    .font(.headline)
                Text("\(envelopes.count) envelope")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { onClose() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            Divider()
            ErrorEnvelopeView(envelopes: envelopes, onJumpToEvent: onJumpToEvent)
                .padding()
        }
    }
}

// MARK: - ErrorEnvelopeView (v1.13.0)
//
// 에러 / 경고 이벤트 + 직전/직후 컨텍스트. Inspector 의 "에러 둘러보기" 시트.
// 사용자가 "이 에러 직전에 무엇을 눌렀나" 빠르게 확인.

struct ErrorEnvelopeView: View {
    let envelopes: [ErrorEnvelope]
    let onJumpToEvent: (TelemetryEvent) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if envelopes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(envelopes) { env in
                            EnvelopeRow(
                                envelope: env,
                                isExpanded: expanded.contains(env.id),
                                onToggle: { toggle(env.id) },
                                onJumpToEvent: onJumpToEvent
                            )
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("에러 둘러보기")
                .font(.caption.bold()).foregroundStyle(.secondary)
            Text("\(envelopes.count) envelope")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            if !envelopes.isEmpty {
                Button {
                    if expanded.count == envelopes.count {
                        expanded.removeAll()
                    } else {
                        expanded = Set(envelopes.map { $0.id })
                    }
                } label: {
                    Text(expanded.count == envelopes.count ? "모두 접기" : "모두 펼치기")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.title2).foregroundStyle(.green)
            Text("이 세션엔 error / warn 이벤트가 없어요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

// MARK: - Single envelope row

private struct EnvelopeRow: View {
    let envelope: ErrorEnvelope
    let isExpanded: Bool
    let onToggle: () -> Void
    let onJumpToEvent: (TelemetryEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 12)
                    LevelBadge(level: envelope.trigger.lv)
                    Text(envelope.trigger.k.rawValue)
                        .font(.system(.caption, design: .monospaced).bold())
                    Spacer()
                    Text(briefTime(envelope.trigger.tw))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("#\(envelope.trigger.i)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(triggerBg.opacity(0.10))
                )
            }
            .buttonStyle(.plain)

            // 한 줄 요약 — payload 핵심.
            if let summary = payloadSummary(envelope.trigger) {
                Text(summary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
                    .lineLimit(2)
            }

            if isExpanded {
                expandedBody
                    .padding(.leading, 28)
                    .padding(.top, 4)
            }
        }
    }

    private var triggerBg: Color {
        switch envelope.trigger.lv {
        case .error: return .red
        case .warn: return .orange
        default: return .gray
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("직전 \(envelope.preceding.count)건")
            ForEach(envelope.preceding) { ev in
                miniRow(ev)
            }
            sectionLabel("트리거")
            triggerDetail
            if !envelope.following.isEmpty {
                sectionLabel("직후 \(envelope.following.count)건")
                ForEach(envelope.following) { ev in
                    miniRow(ev)
                }
            }
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.caption2.bold())
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }

    private var triggerDetail: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let ctx = envelope.trigger.c {
                ctxLine(ctx)
            }
            if !envelope.trigger.d.raw.isEmpty {
                Text(payloadFull(envelope.trigger))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.08)))
                    .textSelection(.enabled)
            }
        }
    }

    private func miniRow(_ ev: TelemetryEvent) -> some View {
        Button {
            onJumpToEvent(ev)
        } label: {
            HStack(spacing: 6) {
                Text(briefTime(ev.tw))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 92, alignment: .leading)
                Text(ev.k.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                Text("(\(ev.lv.rawValue))")
                    .font(.caption2).foregroundStyle(levelColor(ev.lv))
                if let s = payloadShort(ev) {
                    Text(s)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.vertical, 1)
        }
        .buttonStyle(.plain)
    }

    private func ctxLine(_ c: TelemetryContext) -> some View {
        var parts: [String] = []
        if let cn = c.cn { parts.append("conn=\(cn.rawValue)") }
        if let ep = c.ep { parts.append("ep=\(ep)") }
        if let sc = c.sc { parts.append("sec=\(sc)") }
        if let bv = c.bv { parts.append(String(format: "batt=%.1fV", bv)) }
        if let rt = c.rt { parts.append(String(format: "rtt=%.1fms", rt)) }
        if c.im == true { parts.append("imu_stale") }
        return Text(parts.joined(separator: " · "))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Helpers

private func payloadShort(_ ev: TelemetryEvent) -> String? {
    let pairs = ev.d.raw.sorted { $0.key < $1.key }.prefix(2)
    guard !pairs.isEmpty else { return nil }
    return pairs.map { "\($0.key)=\(shortVal($0.value))" }.joined(separator: " ")
}

private func payloadSummary(_ ev: TelemetryEvent) -> String? {
    payloadShort(ev)
}

private func payloadFull(_ ev: TelemetryEvent) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let d = try? enc.encode(ev.d.raw), let s = String(data: d, encoding: .utf8) { return s }
    return "(empty)"
}

private func shortVal(_ v: AnyCodable) -> String {
    switch v.value {
    case let s as String: return s.count > 18 ? "\"\(s.prefix(18))…\"" : "\"\(s)\""
    case let i as Int: return "\(i)"
    case let d as Double: return String(format: "%.2f", d)
    case let b as Bool: return b ? "true" : "false"
    default: return "…"
    }
}

private func briefTime(_ iso: String) -> String {
    guard let d = SessionAnalyzer.parseIso(iso) else { return iso }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: d)
}

private func levelColor(_ lv: TelemetryLevel) -> Color {
    switch lv {
    case .trace: return .secondary
    case .info: return .primary
    case .notice: return .blue
    case .warn: return .orange
    case .error: return .red
    }
}
