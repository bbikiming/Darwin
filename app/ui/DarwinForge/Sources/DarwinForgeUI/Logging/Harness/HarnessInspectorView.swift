import AppKit
import Foundation
import SwiftUI

// MARK: - HarnessInspectorView (Telemetry Inspector v1.0)
//
// **V289-1** — HarnessInspectorView 분할 (2026-05-25)
//
// 비유: 이 파일은 "공항 터미널의 안내 데스크". 방문자(사용자)를
// 적절한 게이트(CurrentSessionPanel / SessionDetailView)로 안내하는
// 진입점이자 사이드바 세션 목록을 관리하는 셸 뷰.
//
// 기술: HSplitView 셸 + 세션 목록 사이드바 + 탭 라우팅 담당.
// 과거 세션 상세 분석 → `SessionDetailView.swift`
// 라이브 tail → `CurrentSessionPanel.swift`
// 파일 reader / 헬퍼 함수 → `HarnessFileReader.swift` (동 디렉토리)
//
// `HarnessIntrospection` protocol 으로 표면화했으나 본 view 는 단일 진입점
// (Expert 탭) 이라 `@Environment(\.harness)` 주입보다 internal 우회
// (`Harness._internalShared`) 가 더 단순/안전.

public struct HarnessInspectorView: View {
    @StateObject private var model = HarnessInspectorModel()
    @State private var selectedSession: ArchivedSession?
    // V289-5: E-Stop 단축키용 IntentDispatcher 참조.
    @EnvironmentObject private var dispatcher: IntentDispatcher

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HarnessTopStatusBar()
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
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // **V289-5** — ⌘B 북마크 단축키 바인딩.
                Button {
                    Harness._internalShared.bookmark("manual bookmark from inspector")
                    reload()
                } label: {
                    Label("북마크 추가", systemImage: "bookmark")
                }
                .help("현재 시점에 \"문제 발생\" 마커를 삽입합니다 (다음 새로고침 시 보임).")
                .keyboardShortcut(HarnessShortcuts.bookmark)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { reload() } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }
        }
        // **V289-7 critic MAJOR-2 fix** — ⌘. E-Stop scope 명확화.
        // 본 binding 은 Harness 탭 mount 시에만 활성. 전 화면 global 은 RootView 의 ⌘⇧.
        // 운영자는 어느 탭이든 ⌘⇧. 또는 사이드바 E-Stop 버튼으로 확실히 발동 가능.
        .background(
            Button("") {
                Task { _ = await dispatcher.fireEmergencyStop() }
            }
            .keyboardShortcut(HarnessShortcuts.eStop)
            .opacity(0)
            .accessibilityLabel("비상 정지 (⌘. · Harness 탭 한정 · 전 화면 ⌘⇧.)")
            .allowsHitTesting(false)
        )
        .onAppear { reload() }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Text("Harness 세션")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, DFSpace.sm)
            Divider()

            // 현재 진행 중 세션.
            currentSessionRow

            Divider()

            // 과거 세션.
            if model.sessions.isEmpty {
                Text(HarnessFormat.EmptyState.noSessions)
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
                    .font(DFFont.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("기록 활성", isOn: Binding(
                    get: { Harness._internalShared.isEnabled },
                    set: { Harness._internalShared.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .font(DFFont.caption)
            }
            .padding(.horizontal)
            // **v1.14.3 (2026-05-21)** — 외부 LLM 분석 도우미.
            HStack(spacing: DFSpace.xs2) {
                Button {
                    Self.openHarnessRoot()
                } label: {
                    Label("Finder에서 로그 폴더", systemImage: "folder")
                        .font(DFFont.label)
                }
                .buttonStyle(.borderless)
                .help("~/Library/Application Support/DarwinForge/Harness/ 열기")

                Button {
                    Self.copyHarnessRootPath()
                } label: {
                    Label("경로 복사", systemImage: "doc.on.clipboard")
                        .font(DFFont.label)
                }
                .buttonStyle(.borderless)
                .help("외부 도구 / 터미널 / Claude Code 에 붙여넣기")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, DFSpace.sm)
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
        let sid = Harness._internalShared.sessionId
        let shortId = String(sid.prefix(8))
        return HStack(spacing: DFSpace.sm) {
            // **V289-7 critic MINOR-1 fix** — ISA-101 색 정책 통일.
            // 녹색 dot 는 "동작 중" 인지 충돌. 활성 indicator 는 명도 + 형태로 표현.
            Circle()
                .fill(Color.primary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("진행 중: \(shortId)")
                    .font(.system(.caption, design: .monospaced))
                Text("시작: \(formatted(Harness._internalShared.sessionStarted))")
                    .font(DFFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, DFSpace.xs2)
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
        HStack(spacing: DFSpace.sm) {
            if session.meta.pinned {
                Image(systemName: "pin.fill").foregroundStyle(.yellow).font(DFFont.caption)
            }
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(session.shortId).font(.system(.caption, design: .monospaced))
                Text(briefDate(session.meta.started))
                    .font(DFFont.label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: DFSpace.micro2) {
                Text("\(session.meta.eventCount) ev").font(DFFont.label)
                Text(prettyBytes(session.meta.sizeBytes)).font(DFFont.label)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DFSpace.micro2)
    }
}

// MARK: - Shared helper views

struct MetaCell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro) {
            Text(label).font(DFFont.label).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - File reader

enum HarnessFileReader {
    /// **v1.12.2 (Codex P2 fix)** — rotation 인지 로더.
    /// `events.jsonl` + 모든 `events.N.jsonl` 을 합쳐 시간순 (oldest → newest) 반환.
    static func loadSessionEvents(directory: URL, maxLines: Int = 5000) -> [TelemetryEvent] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var rotated: [(Int, URL)] = []
        var current: URL?
        for url in items {
            let name = url.lastPathComponent
            if name == "events.jsonl" {
                current = url
            } else if name.hasPrefix("events.") && name.hasSuffix(".jsonl") {
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
        var collected: [TelemetryEvent] = []
        for url in ordered.reversed() {
            let take = max(0, maxLines - collected.count)
            if take == 0 { break }
            let from = loadEvents(from: url, maxLines: take)
            collected = from + collected
        }
        return collected
    }

    static func loadEvents(from url: URL, maxLines: Int = 5000) -> [TelemetryEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var events: [TelemetryEvent] = []
        events.reserveCapacity(min(maxLines, 1000))
        var start = data.startIndex
        let newline: UInt8 = 0x0A
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
