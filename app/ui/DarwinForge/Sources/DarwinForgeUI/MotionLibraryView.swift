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
                // 사이클 154 + 155 (사용자 권고 #4 + codex MINOR fix): ROBOTIS 공식 카탈로그 status 별 그룹.
                // 종전: 16개 모두 한 section → 사용자가 placeholder / 고위험 / safe 구분 어려움.
                // 신규: 3 subsection (canonical IDs in OfficialCatalogReference):
                // - 공식 raw (safe) — 실 합성 + 안전 (11 entries)
                // - Placeholder (caution) — walkReady hold, 낙상 복구 의도 (2 entries: 10/11)
                // - 고위험 / 실험용 — Right/Left Kick (실 합성) + Hand Standing (placeholder + highRisk) (3 entries: 12/13/17)
                // 사이클 155: ID 17 은 placeholder 이면서 highRisk → highRisk 우선 (안전 우선 표시).
                // [placeholder] prefix 가 이름에 있어 placeholder 정보도 동시 노출.
                if !officialSafeEntries.isEmpty {
                    Section("ROBOTIS 공식 — 공식 raw (\(officialSafeEntries.count))") {
                        ForEach(officialSafeEntries) { e in
                            sidebarRow(entry: e).tag(Selection.starter(e.id))
                        }
                    }
                }
                if !officialPlaceholderEntries.isEmpty {
                    Section("ROBOTIS 공식 — Placeholder (\(officialPlaceholderEntries.count))") {
                        ForEach(officialPlaceholderEntries) { e in
                            sidebarRow(entry: e).tag(Selection.starter(e.id))
                        }
                    }
                }
                if !officialHighRiskEntries.isEmpty {
                    Section("ROBOTIS 공식 — 고위험 / 실험용 (\(officialHighRiskEntries.count))") {
                        ForEach(officialHighRiskEntries) { e in
                            sidebarRow(entry: e).tag(Selection.starter(e.id))
                        }
                    }
                }
                // Sprint 11 reference (19)
                Section("커뮤니티 reference (\(referenceEntries.count))") {
                    ForEach(referenceEntries) { e in
                        sidebarRow(entry: e).tag(Selection.starter(e.id))
                    }
                }
                // Sprint 8 prebundled (5)
                Section("앱 합성 — 기본 시작 (\(prebundledEntries.count))") {
                    ForEach(prebundledEntries) { e in
                        sidebarRow(entry: e).tag(Selection.starter(e.id))
                    }
                }
                // 사용자 import
                if !imported.isEmpty {
                    Section("사용자 import (.mtn)") {
                        ForEach(imported) { m in
                            VStack(alignment: .leading) {
                                Text(m.name)
                                    .font(.system(size: DFFontSize.s13, weight: .semibold))
                                Text(m.sourcePath)
                                    .font(.system(size: DFFontSize.s10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(DFColor.textSecondary)
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
        HStack(spacing: DFSpace.sm) {
            Circle()
                .fill(entry.safetyColor)
                .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(entry.page.name)
                    .font(.system(size: DFFontSize.s13))
                    .lineLimit(1)
                Text("ID \(entry.page.id) · \(entry.page.steps.count) step")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    /// ROBOTIS 공식 카탈로그 항목 — OfficialCatalogReference 등록 ID 사용.
    /// 사이클 155 (codex MINOR #2 fix): 하드코딩 set 제거, single source of truth 참조.
    private var officialEntries: [StarterEntry] {
        Self.starterPages.filter { OfficialCatalogReference.allOfficialIDs.contains(Int($0.page.id)) }
    }

    /// 사이클 154 + 155: 공식 카탈로그 의 safety class 별 분리 (canonical IDs).
    /// safe — 실 합성 + 안전 분류 (11 entries: 1, 2, 3, 4, 9, 15, 23, 24, 27, 38, 54).
    private var officialSafeEntries: [StarterEntry] {
        officialEntries.filter { OfficialCatalogReference.safeIDs.contains(Int($0.page.id)) }
    }

    /// 사이클 154 + 155: placeholder caution — walkReady hold, 낙상 복구 의도 (2 entries: 10, 11).
    /// ID 17 (Hand Standing) 은 placeholder 이지만 highRisk → highRisk section 으로.
    private var officialPlaceholderEntries: [StarterEntry] {
        officialEntries.filter { OfficialCatalogReference.placeholderCautionIDs.contains(Int($0.page.id)) }
    }

    /// 사이클 154 + 155: 고위험 / 실험용 — 실 합성 Kicks + placeholder Hand Standing (3 entries: 12, 13, 17).
    /// 안전 우선 표시 — placeholder 라도 highRisk 면 사용자가 더 주의해야 하므로 highRisk section.
    private var officialHighRiskEntries: [StarterEntry] {
        officialEntries.filter { OfficialCatalogReference.allHighRiskIDs.contains(Int($0.page.id)) }
    }

    /// Sprint 11 ReferenceMotionLibrary 항목 (50..=83).
    private var referenceEntries: [StarterEntry] {
        Self.starterPages.filter { (50..<90).contains(Int($0.page.id)) }
    }

    /// Sprint 8 prebundled (위 두 범위 외 — 일반적으로 id < 50, 공식 ID 제외).
    /// 사이클 157 (codex cumulative review MINOR fix): 종전 하드코딩 set [1,2,3,4,...,54]
    /// 가 cycle 155 centralize 시 누락 → canonical reference 로 마이그레이션.
    private var prebundledEntries: [StarterEntry] {
        Self.starterPages.filter { entry in
            let id = Int(entry.page.id)
            return id < 50 && !OfficialCatalogReference.allOfficialIDs.contains(id)
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
    /// DFMotionSafetyColor 의미 팔레트 사용.
    /// 사이클 155 (codex MINOR #2 fix): OfficialCatalogReference 의 canonical ID set 참조 —
    /// 종전 하드코딩 [12,13,17] / [10,11] 제거 → drift 위험 차단.
    var safetyColor: Color {
        let pid = Int(page.id)
        // ROBOTIS 공식 16 카탈로그 — gui_motion.yaml 기준 safety class.
        if OfficialCatalogReference.allHighRiskIDs.contains(pid) {
            return DFMotionSafetyColor.dangerous
        }
        if OfficialCatalogReference.placeholderCautionIDs.contains(pid) {
            return DFMotionSafetyColor.unverified
        }
        // 50-55 walk progression — Verified (모두 walkReady anchor 검증됨)
        // 60+ ergonomic / greeting / social — Verified
        return DFMotionSafetyColor.verified
    }
}

/// starter motion (사용자 import 가 아닌 in-app 합성) 의 detail view.
struct StarterMotionDetailView: View {
    let entry: StarterEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm3) {
            HStack(spacing: DFSpace.sm) {
                Circle().fill(entry.safetyColor).frame(width: DFSize.iconXs, height: DFSize.iconXs)
                Text(entry.page.name)
                    .font(.system(size: DFFontSize.s22, weight: .semibold))
                Spacer()
                Text("ID \(entry.page.id)")
                    .font(.system(size: DFFontSize.s11, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
            }
            HStack(spacing: DFSpace.md) {
                Label("\(entry.page.steps.count) step", systemImage: "list.number")
                Label("\(totalMs) ms 총 재생", systemImage: "clock")
                if entry.page.`repeat` > 1 {
                    Label("\(entry.page.`repeat`) 회 반복", systemImage: "repeat")
                }
            }
            .font(.system(size: DFFontSize.s11))
            .foregroundStyle(DFColor.textSecondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    Text("Step timeline")
                        .font(.system(size: DFFontSize.s11, weight: .semibold))
                        .foregroundStyle(DFColor.textSecondary)
                    ForEach(Array(entry.page.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(spacing: DFSpace.sm) {
                            Text("\(idx)")
                                .font(.system(size: DFFontSize.s11, design: .monospaced))
                                .frame(width: 24)
                                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                            Text("play \(step.playMs)ms")
                                .font(.system(size: DFFontSize.s11, design: .monospaced))
                                .frame(width: 100, alignment: .leading)
                            if step.pauseMs > 0 {
                                Text("pause \(step.pauseMs)ms")
                                    .font(.system(size: DFFontSize.s11, design: .monospaced))
                                    .foregroundStyle(DFColor.textSecondary)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(DFSpace.sm)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            }

            Spacer()

            Text("💡 Motion Studio (⌘3) 에서 이 페이지를 선택하면 3D 뷰어로 재생 가능. 실 robot 송출은 `forge motion play` CLI.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.md)
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
        VStack(alignment: .leading, spacing: DFSpace.sm3) {
            Text(motion.name)
                .font(.system(size: DFFontSize.s22, weight: .semibold))
            Text(motion.sourcePath)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)

            Picker("View", selection: $showingMtn) {
                Text("JSON (forge-core 내부 표현)").tag(false)
                Text(".mtn (round-trip)").tag(true)
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(showingMtn ? motion.mtn : motion.json)
                    .font(.system(size: DFFontSize.s11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DFSpace.sm)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            }
        }
        .padding(DFSpace.md)
    }
}
