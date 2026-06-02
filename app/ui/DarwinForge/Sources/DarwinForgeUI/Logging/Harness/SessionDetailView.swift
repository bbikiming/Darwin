import AppKit
import Foundation
import SwiftUI

// MARK: - File-private helpers (duplicated per-file to avoid module-level name clashes)

private func briefDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) {
        let out = DateFormatter()
        out.dateFormat = "MM/dd HH:mm:ss"
        return out.string(from: d)
    }
    return String(iso.prefix(19))
}

private func briefTime(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: iso) {
        let out = DateFormatter()
        out.dateFormat = "HH:mm:ss.SSS"
        return out.string(from: d)
    }
    return String(iso.suffix(12).prefix(8))
}

private func prettyBytes(_ n: UInt64) -> String {
    if n < 1024 { return "\(n) B" }
    let kb = Double(n) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    let mb = kb / 1024
    return String(format: "%.2f MB", mb)
}

// MARK: - SessionDetailView
//
// **V289-1** — HarnessInspectorView 분할 (2026-05-25)
//
// 비유: 이 파일은 "수사관의 사건 파일함". 이미 종결된 세션(사건)의
// 이벤트·분석·베이스라인 diff 를 열람·내보내는 뷰.
//
// 기술: 과거 `ArchivedSession` 을 받아 이벤트 테이블 / SessionSummaryView /
// InsightsListView / BaselineDiffView 를 구성. 라이브 tail 은 `CurrentSessionPanel`
// 담당. 의존성 cycle 없음 — parent (HarnessInspectorView) 가 세션 선택 후 주입.

struct SessionDetailView: View {
    let session: ArchivedSession
    let onReveal: (ArchivedSession) -> Void
    let onExportZip: (ArchivedSession) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var events: [TelemetryEvent] = []
    @State private var filter: String = ""
    @State private var levelFilter: TelemetryLevel? = nil
    @State private var actorFilter: TelemetryActor? = nil
    @State private var isLoading: Bool = false
    @State private var selectedEventID: TelemetryEvent.ID? = nil
    // **고도화 v1.13.0** — 분석 결과 (summary + timeline + errors).
    @State private var analysis: SessionAnalysis? = nil
    @State private var envelopeSheetOpen: Bool = false
    @State private var summaryCollapsed: Bool = false
    // **v1.14.0** — insights / baseline diff.
    @State private var insights: [Insight] = []
    @State private var diff: SessionDiff? = nil
    @State private var baselineId: String? = HarnessBaseline.currentBaselineId()

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                header
                if let a = analysis, !summaryCollapsed {
                    SessionSummaryView(
                        analysis: a,
                        onJumpToTime: { jumpToTime($0) },
                        onExportMarkdown: { exportMarkdown(a) }
                    )
                }
                // **v1.14.0** — Insights 카드 + Baseline diff.
                if !insights.isEmpty || diff != nil {
                    VStack(alignment: .leading, spacing: DFSpace.sm) {
                        if !insights.isEmpty {
                            InsightsListView(
                                insights: insights,
                                onJumpToEvent: { seq in jumpToSeq(seq) }
                            )
                        }
                        if let d = diff {
                            BaselineDiffView(diff: d)
                        }
                    }
                }
                analysisToolbar
                controls
                Divider()
                if isLoading {
                    ProgressView("이벤트 로딩 중")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text(HarnessFormat.EmptyState.noEvents(filter: filter))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    eventTable
                }
            }
            .padding()
            .frame(minHeight: 200)

            detailPane
                .frame(minHeight: 180)
        }
        .onAppear { loadEvents() }
        // 사이클 141 (Swift 6 deprecated fix): 1-param onChange → 0-param closure (macOS 14+).
        .onChange(of: session) { loadEvents() }
        .sheet(isPresented: $envelopeSheetOpen) {
            if let a = analysis {
                ErrorEnvelopeSheet(
                    envelopes: a.errors,
                    onJumpToEvent: { ev in
                        selectedEventID = ev.id
                        envelopeSheetOpen = false
                    },
                    onClose: { envelopeSheetOpen = false }
                )
                .frame(minWidth: 620, minHeight: 480)
            }
        }
    }

    private var analysisToolbar: some View {
        HStack(spacing: DFSpace.sm) {
            if let a = analysis {
                Button {
                    envelopeSheetOpen = true
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("에러 둘러보기")
                        Text("\(a.errors.count)")
                            .font(DFFont.label)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DFSpace.xs2).padding(.vertical, DFSpace.micro)
                            .background(Capsule().fill(Color.gray.opacity(0.15)))
                    }
                    .padding(.horizontal, DFSpace.sm).padding(.vertical, DFSpace.xs2)
                    .background(RoundedRectangle(cornerRadius: DFRadius.button).fill(
                        a.errors.isEmpty ? Color.gray.opacity(0.08) : Color.orange.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .disabled(a.errors.isEmpty)
            }
            Button {
                withAnimation { summaryCollapsed.toggle() }
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: summaryCollapsed ? "chevron.down" : "chevron.up")
                    Text(summaryCollapsed ? "요약 펼치기" : "요약 접기")
                }
                .font(DFFont.label)
            }
            .buttonStyle(.borderless)
            // **v1.14.0** Baseline 토글.
            Button {
                toggleBaseline()
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: isCurrentBaseline ? "scope" : "scope")
                        .foregroundStyle(isCurrentBaseline ? .blue : .secondary)
                    Text(isCurrentBaseline ? "Baseline 해제" : "Baseline 으로 지정")
                }
                .font(DFFont.label)
            }
            .buttonStyle(.borderless)
            // **v1.14.0** JSON export.
            if let a = analysis {
                Button {
                    exportJSON(a)
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "curlybraces")
                        Text("JSON")
                    }
                    .font(DFFont.label)
                }
                .buttonStyle(.borderless)
                .help("AI / 외부 도구 친화 JSON 리포트")
            }
            Spacer()
        }
    }

    private var isCurrentBaseline: Bool {
        baselineId == session.meta.id
    }

    private func toggleBaseline() {
        // **v1.14.1 (Critic P1-1 fix)** — UserDefaults + 모든 세션의 meta.json 동기화.
        if isCurrentBaseline {
            HarnessBaseline.setBaselineWithMetaSync(nil)
            baselineId = nil
        } else {
            HarnessBaseline.setBaselineWithMetaSync(session.meta.id)
            baselineId = session.meta.id
        }
        recomputeDiffIfNeeded()
    }

    private func jumpToSeq(_ seq: UInt64) {
        if let target = events.first(where: { $0.i == seq }) {
            selectedEventID = target.id
        }
    }

    private func exportJSON(_ a: SessionAnalysis) {
        let json = SessionJSONRenderer.renderString(
            meta: session.meta, analysis: a,
            events: events, insights: insights, diff: diff
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "harness-\(session.shortId)-\(session.dateStamp).json"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            // **v1.14.1 (Code-reviewer P1-3 / Security P2-2 fix)** — silent failure 차단.
            do {
                try json.write(to: dest, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "JSON 내보내기 실패"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// **v1.14.1** — 세션 빠른 전환 시 stale diff write 차단. 세 가지 fix:
    /// 1. 진행 중 diff task 가 있으면 cancel.
    /// 2. detached task 진입 전 sessionId / analysis 를 값으로 캡쳐.
    /// 3. MainActor.run 직전 token 재검증.
    @State private var diffTask: Task<Void, Never>? = nil

    private func recomputeDiffIfNeeded() {
        diffTask?.cancel()
        guard let currentAnalysis = analysis,
              let baseId = baselineId,
              baseId != session.meta.id else {
            diff = nil
            return
        }
        let capturedSessionId = session.meta.id
        let capturedAnalysis = currentAnalysis
        let task = Task.detached(priority: .utility) {
            let allSessions = TelemetryStore.archivedSessions()
            guard let baseSession = allSessions.first(where: { $0.meta.id == baseId }) else {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.session.meta.id == capturedSessionId else { return }
                    self.diff = nil
                }
                return
            }
            let baseEvents = HarnessFileReader.loadSessionEvents(
                directory: baseSession.dir, maxLines: 5000
            )
            if Task.isCancelled { return }
            let baseAnalysis = SessionAnalyzer.analyze(events: baseEvents)
            if Task.isCancelled { return }
            let computed = HarnessBaseline.compare(
                baseline: (id: baseId, analysis: baseAnalysis),
                current: (id: capturedSessionId, analysis: capturedAnalysis)
            )
            await MainActor.run {
                guard self.session.meta.id == capturedSessionId else { return }
                self.diff = computed
            }
        }
        diffTask = task
    }

    private func jumpToTime(_ d: Date) {
        let target = d.timeIntervalSince1970
        let candidate = events.first { ev in
            guard let dt = SessionAnalyzer.parseIso(ev.tw) else { return false }
            return dt.timeIntervalSince1970 >= target
        }
        if let c = candidate {
            selectedEventID = c.id
        }
    }

    private func exportMarkdown(_ a: SessionAnalysis) {
        let md = SessionMarkdownReport.render(meta: session.meta, analysis: a, events: events)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "harness-\(session.shortId)-\(session.dateStamp).md"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            // **v1.14.1 (Code-reviewer P1-3 fix)** — silent failure 차단.
            do {
                try md.write(to: dest, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Markdown 내보내기 실패"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let sel = selectedEvent {
            HarnessEventDetailView(
                event: sel,
                neighbors: events,
                onSelectNeighbor: { ev in selectedEventID = ev.id }
            )
        } else if events.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: DFSpace.xs2) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2).foregroundStyle(.secondary)
                Text("이벤트를 선택하면 상세 payload + context 표시")
                    .font(DFFont.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEvent: TelemetryEvent? {
        guard let id = selectedEventID else { return nil }
        return events.first { $0.id == id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack {
                Text(session.shortId)
                    .font(.system(.title2, design: .monospaced))
                    .textSelection(.enabled)
                if session.meta.pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.yellow)
                }
                Spacer()
                Menu {
                    Button { onReveal(session) } label: { Label("Finder에서 보기", systemImage: "folder") }
                    Button { onExportZip(session) } label: { Label("ZIP으로 내보내기", systemImage: "doc.zipper") }
                    Divider()
                    Button { onTogglePin() } label: {
                        Label(session.meta.pinned ? "핀 해제" : "핀 고정", systemImage: "pin")
                    }
                    Divider()
                    Button(role: .destructive) { onDelete() } label: {
                        Label("세션 삭제", systemImage: "trash")
                    }
                } label: {
                    Label("동작", systemImage: "ellipsis.circle")
                }
            }
            HStack(spacing: DFSpace.md) {
                MetaCell(label: "시작", value: briefDate(session.meta.started))
                MetaCell(label: "종료", value: session.meta.ended.map(briefDate) ?? "(비정상 종료)")
                MetaCell(label: "이벤트", value: "\(session.meta.eventCount)")
                MetaCell(label: "크기", value: prettyBytes(session.meta.sizeBytes))
            }
            HStack(spacing: DFSpace.md) {
                MetaCell(label: "버전", value: "\(session.meta.appVersion) (\(session.meta.appBuild))")
                MetaCell(label: "연결 횟수", value: "\(session.meta.connectCount)")
                MetaCell(label: "에러 수", value: "\(session.meta.errorCount)")
                if session.meta.droppedCount > 0 {
                    MetaCell(label: "drop", value: "\(session.meta.droppedCount)")
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            TextField("kind 검색 (예: connection, walklab, teach)", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("Level", selection: $levelFilter) {
                Text("전체").tag(TelemetryLevel?.none)
                ForEach(TelemetryLevel.allCases, id: \.self) { lv in
                    Text(lv.rawValue).tag(TelemetryLevel?.some(lv))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 130)

            Picker("Actor", selection: $actorFilter) {
                Text("전체").tag(TelemetryActor?.none)
                ForEach(TelemetryActor.allCases, id: \.self) { a in
                    Text(a.rawValue).tag(TelemetryActor?.some(a))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 130)

            Button {
                filter = ""
                levelFilter = nil
                actorFilter = nil
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("필터 초기화")
            .accessibilityLabel("필터 초기화")

            Spacer()
            Text("\(filtered.count) / \(events.count)")
                .font(DFFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eventTable: some View {
        Table(filtered, selection: $selectedEventID) {
            TableColumn("시각") { ev in
                Text(briefTime(ev.tw)).font(.system(.caption, design: .monospaced))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Seq") { ev in
                Text("#\(ev.i)").font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(60)

            TableColumn("Kind") { ev in
                HStack(spacing: DFSpace.xs) {
                    Text(ev.k.rawValue).font(DFFont.caption)
                    if let korLabel = EventKindLabel.from(kindRawValue: ev.k.rawValue) {
                        Text(korLabel.displayName)
                            .font(DFFont.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Lv") { ev in
                Text(ev.lv.rawValue)
                    .font(DFFont.label)
                    .foregroundStyle(color(for: ev.lv))
            }
            .width(60)

            TableColumn("Actor") { ev in
                Text(ev.a.rawValue).font(DFFont.label)
            }
            .width(60)

            TableColumn("Data") { ev in
                Text(payloadSummary(ev))
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(payloadFull(ev))
            }
        }
    }

    private var filtered: [TelemetryEvent] {
        events.filter { ev in
            if let lv = levelFilter, ev.lv != lv { return false }
            if let a = actorFilter, ev.a != a { return false }
            if !filter.isEmpty {
                if !ev.k.rawValue.localizedCaseInsensitiveContains(filter) { return false }
            }
            return true
        }
    }

    @State private var loadTask: Task<Void, Never>?

    private func loadEvents() {
        // **v1.12.2 (Codex P2 fix)** — 진행 중 load 가 있으면 cancel.
        loadTask?.cancel()
        isLoading = true
        analysis = nil
        insights = []
        diff = nil
        let sessionDir = session.directory
        let token = session.id
        let task = Task.detached(priority: .userInitiated) {
            let loaded = HarnessFileReader.loadSessionEvents(directory: sessionDir, maxLines: 5000)
            if Task.isCancelled { return }
            let computed = SessionAnalyzer.analyze(events: loaded)
            let computedInsights = HarnessInsights.compute(analysis: computed, events: loaded)
            if Task.isCancelled { return }
            await MainActor.run {
                guard self.session.id == token else { return }
                self.events = loaded
                self.analysis = computed
                self.insights = computedInsights
                self.isLoading = false
                self.recomputeDiffIfNeeded()
            }
        }
        loadTask = task
    }

    private func color(for lv: TelemetryLevel) -> Color {
        switch lv {
        case .trace: return .secondary
        case .info: return .primary
        case .notice: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func payloadSummary(_ ev: TelemetryEvent) -> String {
        guard !ev.d.raw.isEmpty else { return "" }
        let pairs = ev.d.raw.sorted(by: { $0.key < $1.key }).prefix(3).map { k, v in
            "\(k)=\(shortString(v))"
        }
        return pairs.joined(separator: " ")
    }

    private func payloadFull(_ ev: TelemetryEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ev.d.raw),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "(empty)"
    }

    private func shortString(_ v: AnyCodable) -> String {
        switch v.value {
        case let s as String: return "\"\(s.prefix(20))\""
        case let i as Int: return "\(i)"
        case let d as Double: return String(format: "%.2f", d)
        case let b as Bool: return b ? "true" : "false"
        default: return "…"
        }
    }
}
