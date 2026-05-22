import AppKit
import Foundation
import SwiftUI

// MARK: - HarnessInspectorView (Telemetry Inspector v1.0)
//
// 사용자가 텔레메트리 세션을 확인 / 내보내기 / 핀 고정 / 삭제할 수 있는 화면.
// Expert 탭 또는 Settings 에서 사용. 자세한 설계: docs/harness/telemetry-harness.md

public struct HarnessInspectorView: View {
    @StateObject private var model = HarnessInspectorModel()
    @State private var selectedSession: ArchivedSession?

    public init() {}

    public var body: some View {
        HSplitView {
            // 좌: 세션 목록
            sessionList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            // 우: 세션 상세 + 이벤트 미리보기
            if let sel = selectedSession {
                SessionDetailView(session: sel,
                                  onReveal: { Self.revealInFinder($0) },
                                  onExportZip: { Self.exportZip(of: $0) },
                                  onTogglePin: {
                                      model.togglePin(for: sel)
                                      reload()
                                  },
                                  onDelete: {
                                      model.delete(sel)
                                      selectedSession = nil
                                      reload()
                                  })
                    .frame(minWidth: 400)
            } else {
                CurrentSessionPanel()
                    .frame(minWidth: 400)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Harness.shared.bookmark("manual bookmark from inspector")
                    reload()
                } label: {
                    Label("북마크 추가", systemImage: "bookmark")
                }
                .help("현재 시점에 \"문제 발생\" 마커를 삽입합니다 (다음 새로고침 시 보임).")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { reload() } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear { reload() }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Harness 세션")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)
            Divider()

            // 현재 진행 중 세션.
            currentSessionRow

            Divider()

            // 과거 세션.
            if model.sessions.isEmpty {
                Text("아직 저장된 세션이 없어요.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(model.sessions, selection: $selectedSession) { session in
                    SessionRow(session: session)
                        .tag(session)
                }
                .listStyle(.sidebar)
            }

            HStack {
                Text("\(model.sessions.count) 세션")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("기록 활성", isOn: Binding(
                    get: { Harness.shared.isEnabled },
                    set: { Harness.shared.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .font(.caption)
            }
            .padding(.horizontal)
            // **v1.14.3 (2026-05-21)** — 외부 LLM 분석 도우미.
            // Claude Code / Codex 에 던질 때 즉시 사용 가능한 경로 / Finder 노출.
            HStack(spacing: 6) {
                Button {
                    Self.openHarnessRoot()
                } label: {
                    Label("Finder에서 로그 폴더", systemImage: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("~/Library/Application Support/DarwinForge/Harness/ 열기")

                Button {
                    Self.copyHarnessRootPath()
                } label: {
                    Label("경로 복사", systemImage: "doc.on.clipboard")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("외부 도구 / 터미널 / Claude Code 에 붙여넣기")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: - 외부 도우미 (v1.14.3)

    static func openHarnessRoot() {
        let root = TelemetryStore.rootDirectory()
        // 폴더가 없으면 우선 만들어서 열기 — 사용자가 첫 launch 후 즉시 호출해도 OK.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    static func copyHarnessRootPath() {
        let path = TelemetryStore.rootDirectory().path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private var currentSessionRow: some View {
        let sid = Harness.shared.sessionId
        let shortId = String(sid.prefix(8))
        return HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("진행 중: \(shortId)")
                    .font(.system(.caption, design: .monospaced))
                Text("시작: \(formatted(Harness.shared.sessionStarted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func reload() {
        model.reload()
    }

    // MARK: - Static helpers

    private static func revealInFinder(_ session: ArchivedSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.directory])
    }

    private static func exportZip(of session: ArchivedSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "harness-\(session.shortId)-\(session.dateStamp).zip"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try createZip(at: dest, from: session.directory)
            } catch {
                let alert = NSAlert()
                alert.messageText = "ZIP 내보내기 실패"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// `/usr/bin/zip` 으로 디렉토리 ZIP 생성. macOS 표준 도구 — 외부 dep 없음.
    private static func createZip(at dest: URL, from src: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.arguments = ["-r", "-q", dest.path, src.lastPathComponent]
        task.currentDirectoryURL = src.deletingLastPathComponent()
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(domain: "Harness", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "zip exit \(task.terminationStatus)"])
        }
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Models

@MainActor
final class HarnessInspectorModel: ObservableObject {
    @Published var sessions: [ArchivedSession] = []

    func reload() {
        let raw = TelemetryStore.archivedSessions()
        sessions = raw.map { dir, meta in ArchivedSession(directory: dir, meta: meta) }
    }

    func togglePin(for session: ArchivedSession) {
        var meta = session.meta
        meta.pinned.toggle()
        let url = session.directory.appendingPathComponent("meta.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(meta) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func delete(_ session: ArchivedSession) {
        try? FileManager.default.removeItem(at: session.directory)
    }
}

struct ArchivedSession: Identifiable, Hashable {
    let directory: URL
    let meta: TelemetrySessionMeta

    var id: String { meta.id }
    var shortId: String { String(meta.id.prefix(8)) }
    var dateStamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        if let d = ISO8601DateFormatter().date(from: meta.started) {
            return f.string(from: d)
        }
        return "unknown"
    }

    static func == (lhs: ArchivedSession, rhs: ArchivedSession) -> Bool {
        lhs.directory == rhs.directory
    }
    func hash(into h: inout Hasher) {
        h.combine(directory)
    }
}

// MARK: - Subviews

struct SessionRow: View {
    let session: ArchivedSession

    var body: some View {
        HStack(spacing: 8) {
            if session.meta.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.yellow).font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.shortId).font(.system(.caption, design: .monospaced))
                Text(briefDate(session.meta.started))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.meta.eventCount) ev").font(.caption2)
                Text(prettyBytes(session.meta.sizeBytes)).font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

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
            VStack(alignment: .leading, spacing: 8) {
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
                    VStack(alignment: .leading, spacing: 8) {
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
                    ProgressView("이벤트 로딩 중…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text("표시할 이벤트가 없어요 — 필터를 비우거나 다른 세션을 선택해 보세요.")
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
        HStack(spacing: 8) {
            if let a = analysis {
                Button {
                    envelopeSheetOpen = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("에러 둘러보기")
                        Text("\(a.errors.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.gray.opacity(0.15)))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(
                        a.errors.isEmpty ? Color.gray.opacity(0.08) : Color.orange.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .disabled(a.errors.isEmpty)
            }
            Button {
                withAnimation { summaryCollapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: summaryCollapsed ? "chevron.down" : "chevron.up")
                    Text(summaryCollapsed ? "요약 펼치기" : "요약 접기")
                }
                .font(.caption2)
            }
            .buttonStyle(.borderless)
            // **v1.14.0** Baseline 토글.
            Button {
                toggleBaseline()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCurrentBaseline ? "scope" : "scope")
                        .foregroundStyle(isCurrentBaseline ? .blue : .secondary)
                    Text(isCurrentBaseline ? "Baseline 해제" : "Baseline 으로 지정")
                }
                .font(.caption2)
            }
            .buttonStyle(.borderless)
            // **v1.14.0** JSON export.
            if let a = analysis {
                Button {
                    exportJSON(a)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                        Text("JSON")
                    }
                    .font(.caption2)
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
        // 이전: setBaseline 가 UserDefaults 만 갱신 → JSON Export 의 isBaseline 항상 false.
        if isCurrentBaseline {
            HarnessBaseline.setBaselineWithMetaSync(nil)
            baselineId = nil
        } else {
            HarnessBaseline.setBaselineWithMetaSync(session.meta.id)
            baselineId = session.meta.id
        }
        // 새 baseline 지정/해제 후 diff 재계산.
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

    /// **v1.14.1 (Debugger P1 / Critic P2-8 / Code-reviewer P2-3 fix, 2026-05-21)** —
    /// 세션 빠른 전환 시 stale diff write 차단. 세 가지 fix:
    /// 1. 진행 중 diff task 가 있으면 cancel (loadTask 패턴과 동일).
    /// 2. detached task 진입 전 sessionId / analysis 를 값으로 캡쳐 (self 참조 X).
    /// 3. MainActor.run 직전 token 재검증 — 세션 바뀌면 silent drop.
    @State private var diffTask: Task<Void, Never>? = nil

    private func recomputeDiffIfNeeded() {
        diffTask?.cancel()
        guard let currentAnalysis = analysis,
              let baseId = baselineId,
              baseId != session.meta.id else {
            diff = nil
            return
        }
        // 값 캡쳐 — self 의 mutable state 가 task 실행 도중 바뀌어도 안전.
        let capturedSessionId = session.meta.id
        let capturedAnalysis = currentAnalysis
        let task = Task.detached(priority: .utility) {
            let allSessions = TelemetryStore.archivedSessions()
            guard let baseSession = allSessions.first(where: { $0.meta.id == baseId }) else {
                if Task.isCancelled { return }
                await MainActor.run {
                    // 세션 바뀌었으면 무시. 같은 세션이면 diff 클리어.
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
                // **핵심 race guard** — 세션 전환 후 stale write 차단.
                guard self.session.meta.id == capturedSessionId else { return }
                self.diff = computed
            }
        }
        diffTask = task
    }

    private func jumpToTime(_ d: Date) {
        // 가장 가까운 (그 이후 첫) 이벤트 선택.
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
        let md = SessionMarkdownReport.render(meta: session.meta, analysis: a)
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
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2).foregroundStyle(.secondary)
                Text("위 표에서 이벤트를 선택하면 상세 payload + context 가 보입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEvent: TelemetryEvent? {
        guard let id = selectedEventID else { return nil }
        return events.first { $0.id == id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(spacing: 16) {
                MetaCell(label: "시작", value: briefDate(session.meta.started))
                MetaCell(label: "종료", value: session.meta.ended.map(briefDate) ?? "(비정상 종료)")
                MetaCell(label: "이벤트", value: "\(session.meta.eventCount)")
                MetaCell(label: "크기", value: prettyBytes(session.meta.sizeBytes))
            }
            HStack(spacing: 16) {
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

            Spacer()
            Text("\(filtered.count) / \(events.count)")
                .font(.caption)
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
                Text(ev.k.rawValue).font(.caption)
            }
            .width(min: 160, ideal: 200)

            TableColumn("Lv") { ev in
                Text(ev.lv.rawValue)
                    .font(.caption2)
                    .foregroundStyle(color(for: ev.lv))
            }
            .width(60)

            TableColumn("Actor") { ev in
                Text(ev.a.rawValue).font(.caption2)
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
            // **v1.14.0** — Insights 도 off-main 에서 계산.
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

struct CurrentSessionPanel: View {
    @State private var liveEvents: [TelemetryEvent] = []
    @State private var ticker: Timer?
    @State private var lastEventCount: UInt64 = 0
    @State private var lastSize: UInt64 = 0
    @State private var lastFlushAt: Date? = nil
    @State private var filter: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusHeader
            // **v1.14.0** — 진행 중 세션의 라이브 알림 배너.
            LiveAlertsBanner()
            Divider()
            HStack {
                TextField("kind 검색", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Button {
                    Harness.shared.bookmark("inspector live-tail bookmark")
                } label: {
                    Label("북마크 추가", systemImage: "bookmark.fill")
                }
                .buttonStyle(.borderless)
                .help("이 시점에 user.bookmark 이벤트 삽입")
                Spacer()
                Text("매 1초 새로고침").font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.title2).foregroundStyle(.secondary)
                    Text("아직 이벤트가 없거나 필터에 걸리지 않았어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered) {
                    TableColumn("시각") { ev in
                        Text(timeString(ev.tw)).font(.system(.caption, design: .monospaced))
                    }.width(min: 80, ideal: 100)
                    TableColumn("Seq") { ev in
                        Text("#\(ev.i)").font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }.width(60)
                    TableColumn("Kind") { ev in
                        HStack(spacing: 4) {
                            LevelBadge(level: ev.lv)
                            Text(ev.k.rawValue).font(.caption)
                        }
                    }.width(min: 200, ideal: 260)
                    TableColumn("Actor") { ev in
                        Text(ev.a.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }.width(60)
                    TableColumn("Payload") { ev in
                        Text(payloadOneLine(ev))
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1).truncationMode(.tail)
                            .help(payloadFull(ev))
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startTicker() }
        .onDisappear { stopTicker() }
    }

    private var statusHeader: some View {
        let sid = Harness.shared.sessionId
        let shortId = sid.isEmpty ? "(미시동)" : String(sid.prefix(8))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Harness.shared.recorder == nil ? .gray : .green)
                    .frame(width: 10, height: 10)
                Text("Live tail — 현재 세션")
                    .font(.headline)
                Spacer()
                Text(shortId)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack(spacing: 16) {
                MetaCell(label: "시작",
                         value: shortTime(Harness.shared.sessionStarted))
                MetaCell(label: "수집한 이벤트",
                         value: "\(lastEventCount)")
                MetaCell(label: "디스크 사용량",
                         value: prettyBytes(lastSize))
                MetaCell(label: "마지막 flush",
                         value: lastFlushAt.map(briefRelative) ?? "—")
            }
        }
    }

    private var filtered: [TelemetryEvent] {
        guard !filter.isEmpty else { return liveEvents }
        return liveEvents.filter { $0.k.rawValue.localizedCaseInsensitiveContains(filter) }
    }

    private func startTicker() {
        stopTicker()
        refresh()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refresh() {
        // **v1.12.2 (Codex P2 fix)** — file I/O 를 off-main 으로.
        // 종전: main actor 에서 매 1초 50 MB 까지 동기 read → UI 끊김.
        guard let dir = Harness.shared.sessionDir else { return }
        Task.detached(priority: .utility) {
            let events = dir.appendingPathComponent("events.jsonl")
            let metaURL = dir.appendingPathComponent("meta.json")
            // 사이클 141 (Swift 6 Sendable closure fix): var → let — Task closure 가 concurrently
            // execute 될 때 var capture 가 Swift 6 mode 에서 error. immutable let 으로 1회 계산.
            let (newEventCount, newSize): (UInt64, UInt64) = {
                if let data = try? Data(contentsOf: metaURL),
                   let m = try? JSONDecoder().decode(TelemetrySessionMeta.self, from: data) {
                    return (m.eventCount, m.sizeBytes)
                }
                return (0, 0)
            }()
            let newFlushAt: Date? = {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: events.path),
                   let mtime = attrs[.modificationDate] as? Date {
                    return mtime
                }
                return nil
            }()
            // **v1.14.1 (Critic P2-7 fix, 2026-05-21)** — maxLines 200 → 800.
            // 종전: bus storm (분당 수백 회 발생) 시 200 line 윈도우가 bus 에러만으로
            // 차서 LiveAlerts 가 봐야 할 heartbeat 가 밖으로 밀려나 RTT/IMU stale 알림
            // 누락. 800 line 으로 늘려 최소 60s heartbeat (60 회) + 추가 시그널 보장.
            let loaded = HarnessFileReader.loadEvents(from: events, maxLines: 800)
            // UI 표시는 최근 200 만 유지 — 메모리.
            let displayed = Array(loaded.suffix(200).reversed())
            await MainActor.run {
                self.lastEventCount = newEventCount
                self.lastSize = newSize
                self.lastFlushAt = newFlushAt
                self.liveEvents = displayed
                // LiveAlerts 는 800 전체 윈도우를 봐서 시간 정확도 우선.
                HarnessLiveAlerts.shared.evaluate(events: loaded)
            }
        }
    }

    private func timeString(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) {
            let out = DateFormatter()
            out.dateFormat = "HH:mm:ss.SSS"
            return out.string(from: d)
        }
        return iso
    }

    private func shortTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm:ss"
        return f.string(from: d)
    }

    private func briefRelative(_ d: Date) -> String {
        let dt = Date().timeIntervalSince(d)
        if dt < 1 { return "방금" }
        if dt < 60 { return String(format: "%.0f초 전", dt) }
        if dt < 3600 { return String(format: "%.0f분 전", dt / 60) }
        return String(format: "%.1f시간 전", dt / 3600)
    }

    private func payloadOneLine(_ ev: TelemetryEvent) -> String {
        let pairs = ev.d.raw.sorted { $0.key < $1.key }.prefix(4).map { k, v in
            "\(k)=\(briefValue(v))"
        }
        return pairs.joined(separator: " ")
    }

    private func payloadFull(_ ev: TelemetryEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ev.d.raw),
           let str = String(data: data, encoding: .utf8) { return str }
        return "(empty)"
    }

    private func briefValue(_ v: AnyCodable) -> String {
        switch v.value {
        case let s as String: return s.count > 24 ? "\(s.prefix(24))…" : s
        case let i as Int: return "\(i)"
        case let d as Double: return String(format: "%.2f", d)
        case let b as Bool: return b ? "true" : "false"
        default: return "…"
        }
    }
}

struct MetaCell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - File reader

enum HarnessFileReader {
    /// **v1.12.2 (Codex P2 fix)** — rotation 인지 로더.
    /// `events.jsonl` + 모든 `events.N.jsonl` 을 합쳐 시간순 (oldest → newest) 반환.
    /// Rotation 은 events.1.jsonl 이 가장 오래된 것 (먼저 회전된 파일), events.jsonl 가
    /// 현재 active. 회전 인덱스 오름차순 + 현재 파일 = 시간 정렬.
    static func loadSessionEvents(directory: URL, maxLines: Int = 5000) -> [TelemetryEvent] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        // events.N.jsonl 모두 수집 + 인덱스로 정렬 (오래된 것부터). 마지막 events.jsonl.
        var rotated: [(Int, URL)] = []
        var current: URL?
        for url in items {
            let name = url.lastPathComponent
            if name == "events.jsonl" {
                current = url
            } else if name.hasPrefix("events.") && name.hasSuffix(".jsonl") {
                // "events.3.jsonl" → 3
                let middle = name.dropFirst("events.".count).dropLast(".jsonl".count)
                if let idx = Int(middle) {
                    rotated.append((idx, url))
                }
            }
        }
        rotated.sort { $0.0 < $1.0 }
        var ordered = rotated.map { $0.1 }
        if let cur = current { ordered.append(cur) }
        if ordered.isEmpty { return [] }
        // 마지막 maxLines 만 — 큰 세션에서 메모리 보호.
        // 단순화: 각 파일 끝부터 거꾸로 모으다 maxLines 도달 시 중단.
        var collected: [TelemetryEvent] = []
        for url in ordered.reversed() {
            let take = max(0, maxLines - collected.count)
            if take == 0 { break }
            let from = loadEvents(from: url, maxLines: take)
            collected = from + collected     // prepend — 오래된 파일이 앞으로.
        }
        return collected
    }

    static func loadEvents(from url: URL, maxLines: Int = 5000) -> [TelemetryEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // 큰 파일은 마지막 maxLines 만 — 메모리 보호.
        let decoder = JSONDecoder()
        var events: [TelemetryEvent] = []
        events.reserveCapacity(min(maxLines, 1000))
        var start = data.startIndex
        let newline: UInt8 = 0x0A
        // 끝에서부터 newline 카운트해 시작 위치 정함.
        if data.count > 0 {
            var newlineCount = 0
            var cursor = data.endIndex
            while cursor > data.startIndex {
                cursor = data.index(before: cursor)
                if data[cursor] == newline {
                    newlineCount += 1
                    if newlineCount > maxLines {
                        start = data.index(after: cursor)
                        break
                    }
                }
            }
        }
        var lineStart = start
        for i in stride(from: lineStart, to: data.endIndex, by: 1) {
            if data[i] == newline {
                let line = data[lineStart..<i]
                lineStart = data.index(after: i)
                guard !line.isEmpty else { continue }
                if let ev = try? decoder.decode(TelemetryEvent.self, from: Data(line)) {
                    events.append(ev)
                }
            }
        }
        // 마지막 incomplete line (no trailing newline)
        if lineStart < data.endIndex {
            let line = data[lineStart..<data.endIndex]
            if let ev = try? decoder.decode(TelemetryEvent.self, from: Data(line)) {
                events.append(ev)
            }
        }
        return events
    }
}

// MARK: - Helpers

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
