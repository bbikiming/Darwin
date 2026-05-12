import ForgeCore
import SwiftUI

/// **동작 라이브러리** — Expert > 동작 라이브러리.
///
/// Motion Studio (⌘3) 와 동일한 starter 모션을 카테고리로 분류해 보여주고,
/// 추가로 사용자가 `.mtn` 파일을 import 가능. ROBOTIS 공식 16 카탈로그 +
/// Sprint 11 ReferenceMotionLibrary 19 페이지 + Sprint 8 prebundled 5 페이지 +
/// 사용자 import = **모든 모션 한 화면**.
public struct MotionLibraryView: View {
    @State private var imported: [LoadedMotion] = []
    @State private var lastError: String?
    @State private var selection: Selection?

    public init() {}

    /// 사이드바 항목 식별자 — starter vs imported.
    enum Selection: Hashable {
        case starter(UUID)
        case imported(UUID)
    }

    /// starter 모션 — Motion Studio 와 동일 26 + 16 = 42 페이지.
    private static let starterPages: [StarterEntry] = {
        // Sprint 8 prebundled (5) + Sprint 11 ReferenceMotionLibrary (19) +
        // Sprint 16 OfficialCatalogReference (16) — 한 곳에서 모으기.
        let all = MotionStudioView.starterPages()
        return all.map { StarterEntry(page: $0) }
    }()

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // ROBOTIS 공식 카탈로그 (16)
                Section("ROBOTIS 공식 데모 (16)") {
                    ForEach(officialEntries) { e in
                        sidebarRow(entry: e).tag(Selection.starter(e.id))
                    }
                }
                // Sprint 11 reference (19)
                Section("커뮤니티 reference (19)") {
                    ForEach(referenceEntries) { e in
                        sidebarRow(entry: e).tag(Selection.starter(e.id))
                    }
                }
                // Sprint 8 prebundled (5)
                Section("기본 시작 (5)") {
                    ForEach(prebundledEntries) { e in
                        sidebarRow(entry: e).tag(Selection.starter(e.id))
                    }
                }
                // 사용자 import
                if !imported.isEmpty {
                    Section("사용자 import (.mtn)") {
                        ForEach(imported) { m in
                            VStack(alignment: .leading) {
                                Text(m.name).font(.headline)
                                Text(m.sourcePath)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Selection.imported(m.id))
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        importMotion()
                    } label: {
                        Label("Import .mtn", systemImage: "tray.and.arrow.down")
                    }
                }
            }
            .frame(minWidth: 280)
        } detail: {
            if let sel = selection {
                switch sel {
                case .starter(let id):
                    if let e = Self.starterPages.first(where: { $0.id == id }) {
                        StarterMotionDetailView(entry: e)
                    } else {
                        ContentUnavailableView("Selection invalid", systemImage: "exclamationmark.triangle")
                    }
                case .imported(let id):
                    if let m = imported.first(where: { $0.id == id }) {
                        MotionDetailView(motion: m)
                    } else {
                        ContentUnavailableView("Selection invalid", systemImage: "exclamationmark.triangle")
                    }
                }
            } else {
                ContentUnavailableView(
                    "동작을 선택하세요",
                    systemImage: "play.rectangle",
                    description: Text("좌측에서 starter 모션을 선택하거나 `.mtn` 파일을 import.")
                )
            }
        }
        .alert(
            "Import failed",
            isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } }),
            actions: { Button("OK") { lastError = nil } },
            message: { Text(lastError ?? "") }
        )
    }

    // MARK: - Sidebar rows

    private func sidebarRow(entry: StarterEntry) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.safetyColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.page.name)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                Text("ID \(entry.page.id) · \(entry.page.steps.count) step")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// ROBOTIS 공식 카탈로그 항목 (ID 1..=54 — OfficialCatalogReference 등록 ID).
    private var officialEntries: [StarterEntry] {
        let officialIDs: Set<Int> = [1, 2, 3, 4, 9, 10, 11, 12, 13, 15, 17, 23, 24, 27, 38, 54]
        return Self.starterPages.filter { officialIDs.contains(Int($0.page.id)) }
    }

    /// Sprint 11 ReferenceMotionLibrary 항목 (50..=83).
    private var referenceEntries: [StarterEntry] {
        Self.starterPages.filter { (50..<90).contains(Int($0.page.id)) }
    }

    /// Sprint 8 prebundled (위 두 범위 외 — 일반적으로 id < 50, 공식 ID 제외).
    private var prebundledEntries: [StarterEntry] {
        let officialIDs: Set<Int> = [1, 2, 3, 4, 9, 10, 11, 12, 13, 15, 17, 23, 24, 27, 38, 54]
        return Self.starterPages.filter { entry in
            let id = Int(entry.page.id)
            return id < 50 && !officialIDs.contains(id)
        }
    }

    private func importMotion() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let mtn = try String(contentsOf: url, encoding: .utf8)
                let json = try Motion.mtnToJSON(mtn, generation: "op2")
                let loaded = LoadedMotion(name: url.lastPathComponent, sourcePath: url.path,
                                          mtn: mtn, json: json)
                imported.append(loaded)
                selection = .imported(loaded.id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

/// starter MotionPage 의 sidebar 표시용 wrapper (UUID + 안전 색상 + 카테고리 라벨).
struct StarterEntry: Identifiable {
    let id = UUID()
    let page: MotionPage

    /// 페이지 ID 범위 + 이름 기반 안전 분류 (시각적 색 indicator).
    var safetyColor: Color {
        let pid = Int(page.id)
        // ROBOTIS 공식 16 카탈로그 — gui_motion.yaml 기준 safety class.
        let highRisk: Set<Int> = [12, 13, 17]      // Right/Left Kick, Hand Standing
        let caution: Set<Int> = [10, 11]           // Get Up Front / Back
        if highRisk.contains(pid) { return .red }
        if caution.contains(pid) { return .orange }
        // 50-55 walk progression — Safe (모두 walkReady anchor 검증됨)
        // 60+ ergonomic / greeting / social — Safe
        return .green
    }
}

/// starter motion (사용자 import 가 아닌 in-app 합성) 의 detail view.
struct StarterMotionDetailView: View {
    let entry: StarterEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(entry.safetyColor).frame(width: 12, height: 12)
                Text(entry.page.name).font(.title2)
                Spacer()
                Text("ID \(entry.page.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Label("\(entry.page.steps.count) step", systemImage: "list.number")
                Label("\(totalMs) ms 총 재생", systemImage: "clock")
                if entry.page.`repeat` > 1 {
                    Label("\(entry.page.`repeat`) 회 반복", systemImage: "repeat")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step timeline").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(Array(entry.page.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(spacing: 8) {
                            Text("\(idx)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 24)
                                .foregroundStyle(.tertiary)
                            Text("play \(step.playMs)ms")
                                .font(.caption.monospacedDigit())
                                .frame(width: 100, alignment: .leading)
                            if step.pauseMs > 0 {
                                Text("pause \(step.pauseMs)ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(8)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            Text("💡 Motion Studio (⌘3) 에서 이 페이지를 선택하면 3D 뷰어로 재생 가능. 실 robot 송출은 `forge motion play` CLI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var totalMs: Int {
        entry.page.steps.reduce(0) { $0 + $1.playMs + $1.pauseMs }
    }
}

struct LoadedMotion: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let sourcePath: String
    let mtn: String
    let json: String
}

struct MotionDetailView: View {
    let motion: LoadedMotion

    @State private var showingMtn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(motion.name).font(.title2)
            Text(motion.sourcePath).font(.caption).foregroundStyle(.secondary)

            Picker("View", selection: $showingMtn) {
                Text("JSON (forge-core 내부 표현)").tag(false)
                Text(".mtn (round-trip)").tag(true)
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(showingMtn ? motion.mtn : motion.json)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
    }
}
