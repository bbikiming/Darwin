import ForgeCore
import SwiftUI

/// 사이클 258 (Wave 4.3.5) — `MotionStudioView` 사이드바 분리.
///
/// **목적**: MotionStudioView 1251 줄 god view 분할.
/// 사이드바 (페이지 목록 + AI 빌더 + 컨텍스트 메뉴 + rename/delete sheet)
/// 책임을 독립 View 로 격리.
///
/// **책임**:
/// - AI 모션 빌더 패널 입력 + 빌드 트리거
/// - 페이지 목록 (카테고리 그룹) 렌더 + 선택 binding
/// - 호버 시 ⋯ 메뉴 표출 + 컨텍스트 메뉴 (rename / 복제 / export / delete)
/// - rename sheet + delete alert 제공
///
/// **소유권**:
/// - `doc` 은 `@Bindable` 로 양방향 — MotionStudioView 가 owner.
/// - `aiBuilderText` / `aiBuilderToast` 는 view-local @State (사이드바 전용).
/// - 모든 action (addPage / importMotionPanel / applySelectedStepToPose 등)
///   은 closure 로 주입 — view 가 콜백을 통해 owner 로 위임.
@MainActor
struct MotionStudioSidebar: View {
    @Bindable var doc: MotionDocumentStore

    /// AI 빌더 view-local state (사이드바 전용이므로 owner 로 끌어올릴 필요 없음).
    @State private var aiBuilderText: String = ""
    @State private var aiBuilderToast: String?

    /// V280-D — Synth Palette (3-pane 고급 AI 합성기) sheet 표시 토글.
    /// 기존 heuristic AI 빌더 (자연어 한 줄 → 페이지) 외에, 카탈로그 페이지를
    /// 합성·검증·내보내기 까지 제공하는 `SynthPaletteView` 의 명시적 진입점.
    ///
    /// **Discoverability (Nielsen H6 "Recognition rather than recall")**:
    /// V278-3 audit P0 — Synth 모듈이 orphan 상태였음 (사용자가 존재를 모름).
    /// 본 sheet 진입 button 으로 recall → recognition 전환.
    ///
    /// Sheet 내부의 `SynthInspectorPanel` 의 "Motion 스튜디오 로 보내기" 가
    /// `dfImportSynthPagesToMotionStudio` notification 으로 결과를 owner 에 전달.
    /// 따라서 본 사이드바는 view-state 만 보유 (additive only — Synth 모듈 0 변경).
    @State private var showSynthPalette: Bool = false

    // MARK: - Action callbacks (owner 위임)

    let onAddPage: () -> Void
    let onImportMotionPanel: () -> Void
    let onApplySelectedStepToPose: () -> Void
    let onDuplicatePage: (Int) -> Void
    let onExportPage: (Int) -> Void
    let onSaveDocAs: () -> Void
    let onRenamePage: (Int, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.none) {
            aiBuilderPanel
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.sm)

            Divider().padding(.vertical, DFSpace.xs2)

            HStack {
                Text("동작 목록 (\(doc.motion.pages.count))")
                    .font(DFFont.bodyEmph)
                Spacer()
                Button {
                    onAddPage()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("빈 동작 새로 만들기")
                .accessibilityLabel("빈 동작 새로 만들기")

                Button {
                    onImportMotionPanel()
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("로보플러스 .mtn 동작 파일 가져오기")
                .accessibilityLabel("로보플러스 .mtn 동작 파일 가져오기")
            }
            .padding(.horizontal, DFSpace.md)

            Divider().padding(.vertical, DFSpace.xs)

            // 2026-05-17 카테고리 그룹핑 — Section 으로 묶음 (사용자 가독성).
            // MotionStudioCategory.categorize(_:) 가 id/name 기반 자동 분류.
            let grouped = groupedPagesByCategory()
            List(selection: Binding(
                get: { doc.selectedPageIdx },
                set: { if let v = $0 { doc.selectedPageIdx = v; doc.selectedStep = 0; onApplySelectedStepToPose() } }
            )) {
                ForEach(grouped, id: \.category) { group in
                    Section {
                        ForEach(group.entries, id: \.idx) { entry in
                            if entry.idx < doc.motion.pages.count {
                                pageListRow(idx: entry.idx, page: doc.motion.pages[entry.idx])
                                    .tag(entry.idx)
                                    .contextMenu { pageContextMenu(at: entry.idx) }
                            }
                        }
                    } header: {
                        HStack(spacing: DFSpace.xs) {
                            Image(systemName: group.category.icon)
                                .foregroundStyle(DFColor.accent)
                            Text("\(group.category.label) (\(group.entries.count))")
                                .font(DFFont.caption)
                                .foregroundStyle(DFColor.textSecondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 240)
        .background(DFColor.elev2)
        // Rename sheet — inline TextField + 확인 / 취소.
        .sheet(item: Binding(
            get: { doc.renamingPageIdx.map { SidebarRenameTarget(idx: $0) } },
            set: { doc.renamingPageIdx = $0?.idx }
        )) { target in
            renameSheet(target: target)
        }
        // Delete 확인 alert — 실수 방지.
        .alert("이 동작을 삭제할까요?",
               isPresented: Binding(
                get: { doc.deletingPageIdx != nil },
                set: { if !$0 { doc.deletingPageIdx = nil } }
               ),
               presenting: doc.deletingPageIdx
        ) { idx in
            Button("취소", role: .cancel) { doc.deletingPageIdx = nil }
            Button("삭제", role: .destructive) {
                // MotionStudioView 의 deletePage 호출 경로와 동일하게 위임.
                // 본 View 는 단순히 alert UI 만 제공 — 실제 mutation 은 owner 책임.
                // doc.deletingPageIdx → MotionStudioView 의 onDeletePage 처리는
                // V258 에서는 alert action 안에서 직접 deletePage 위임이 필요.
                // 하지만 onDeletePage 도 callback 으로 주입해야 깔끔하므로 추가.
                onDeletePageInternal(idx: idx)
                doc.deletingPageIdx = nil
            }
        } message: { idx in
            if idx < doc.motion.pages.count {
                Text("\"\(doc.motion.pages[idx].name)\" 을(를) 영구 삭제합니다.\n저장하지 않으면 동작 doc 만 비워지고 파일에는 영향 없음.")
            } else {
                Text("이 동작을 삭제합니다.")
            }
        }
        // V280-D — Synth Palette sheet.
        // SynthPaletteView 자체는 standalone — 결과는 notification 으로
        // owner (MotionStudioView) 가 수신 → importSynthPages 처리.
        // 본 sidebar 는 sheet host 역할만 (additive only).
        .sheet(isPresented: $showSynthPalette) {
            synthPaletteSheet
        }
    }

    /// V280-D — Synth Palette sheet wrapper.
    /// 한국어 close button + frame 강제 (macOS sheet 기본 크기 너무 작음).
    private var synthPaletteSheet: some View {
        VStack(spacing: DFSpace.none) {
            HStack {
                Text("AI 모션 빌더 (고급)")
                    .font(DFFont.title)
                Spacer()
                Button("닫기") { showSynthPalette = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("AI 모션 빌더 닫기")
            }
            .padding(.horizontal, DFSpace.lg)
            .padding(.vertical, DFSpace.sm)
            .background(DFColor.elev2)

            Divider()

            SynthPaletteView()
        }
        .frame(minWidth: 1180, minHeight: 680)
    }

    // MARK: - Delete callback (owner 위임)

    /// 삭제 확인 alert action — owner 가 deletePage 로직 + telemetry 책임.
    let onDeletePage: (Int) -> Void

    /// alert 내부에서 호출 — 의미는 onDeletePage 와 동일하나, 별도 메서드로 빼서
    /// closure capture 의 명확성 (memberwise init 가독성) 확보.
    private func onDeletePageInternal(idx: Int) {
        onDeletePage(idx)
    }

    // MARK: - AI Motion Builder

    /// 사이드바 상단의 AI 모션 빌더 패널 — 자연어 → 모션 페이지 즉시 생성.
    /// MotionBuilder.parseHeuristic 사용 (Claude CLI 없이도 동작).
    private var aiBuilderPanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(DFColor.forge)
                Text("AI 모션 빌더")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
                    .textCase(.uppercase)
            }
            TextField("예: 손 흔들고 박수 치기",
                      text: $aiBuilderText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: DFFontSize.s11))
                .lineLimit(1...3)
                .onSubmit { runAIBuilder() }
            HStack(spacing: DFSpace.xs) {
                Button {
                    runAIBuilder()
                } label: {
                    Label("빌드", systemImage: "wand.and.stars")
                        .font(.system(size: DFFontSize.s10, weight: .semibold))
                        .padding(.horizontal, DFSpace.sm).padding(.vertical, 3)
                        .background(DFColor.forge)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(aiBuilderText.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
                if let toast = aiBuilderToast {
                    Text(toast)
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.success)
                        .lineLimit(1)
                }
            }

            // V280-D — 고급 AI 모션 합성기 진입점 (orphan 해소).
            // 위쪽 한 줄 heuristic 빌더 외에, 카탈로그 합성·검증 UI 노출.
            advancedSynthEntryButton
        }
    }

    /// V280-D — "AI 모션 빌더 (고급)" 진입점.
    /// IBM Carbon IA: 핵심 도구는 prominent navigation 위치에 노출.
    /// Don Norman "Discoverability": 가능 action 을 visible 하게 만든다.
    ///
    /// 라벨 한국어 microcopy 는 V279-3 Voice & Tone (Info 톤) 준수:
    /// - "고급" 으로 위쪽 빌더와 차별화 (정보 hierarchy 명시).
    /// - help / accessibility 텍스트 로 기능 요약 제공.
    private var advancedSynthEntryButton: some View {
        Button {
            showSynthPalette = true
        } label: {
            Label("AI 모션 빌더 (고급)", systemImage: "sparkles")
                .font(.system(size: DFFontSize.s11, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(DFColor.forge)
        .help("카탈로그 페이지를 합성·검증 후 Motion 페이지로 내보냅니다")
        .accessibilityLabel("AI 모션 빌더 고급 열기")
        .accessibilityHint("3-pane 합성기 — 라이브러리·캔버스·인스펙터")
        .padding(.top, DFSpace.xs)
    }

    private func runAIBuilder() {
        let desc = aiBuilderText.trimmingCharacters(in: .whitespaces)
        guard !desc.isEmpty else { return }
        let specs = MotionBuilder.parseHeuristic(desc)
        guard !specs.isEmpty else {
            aiBuilderToast = "❌ 매칭 자세 없음"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                aiBuilderToast = nil
            }
            return
        }
        do {
            let pageName = desc.count > 18 ? String(desc.prefix(18)) + "…" : desc
            var page = try MotionBuilder.build(name: pageName, steps: specs)
            // ID 재할당 — 기존 페이지와 충돌 회피.
            let nextId = (doc.motion.pages.map { $0.id }.max() ?? 0) + 1
            page = MotionPage(id: nextId, name: page.name, steps: page.steps)
            doc.motion = MotionDoc(pages: doc.motion.pages + [page])
            doc.selectedPageIdx = doc.motion.pages.count - 1
            doc.selectedStep = 0
            onApplySelectedStepToPose()
            aiBuilderText = ""
            aiBuilderToast = "✅ \(specs.count) 스텝 추가"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                aiBuilderToast = nil
            }
        } catch {
            aiBuilderToast = "❌ \(error.localizedDescription)"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                aiBuilderToast = nil
            }
        }
    }

    // MARK: - Category grouping

    /// 2026-05-17 카테고리 그룹핑 — 페이지를 카테고리별로 묶고 정렬 순서 적용.
    /// `MotionStudioCategory.sortOrder` 로 카테고리 자체 순서 결정 (기본 → 공식 → ...).
    /// 각 카테고리 안에서는 원래 idx 순서 유지 (사용자 입력/페이지 ID 순서 보존).
    private struct CategoryGroup: Hashable {
        let category: MotionStudioCategory
        let entries: [Entry]
        struct Entry: Hashable, Identifiable {
            let idx: Int
            let pageId: UInt8
            let pageName: String
            // page 자체는 Hashable 가능 — id+name 으로 충분 (정렬 / list 진단용).
            var id: Int { idx }
            // List 가 row 렌더링 시 실제 MotionPage 가 필요한 경우 ForEach 안에서
            // motion.pages[idx] 로 다시 가져옴.
        }
        func hash(into hasher: inout Hasher) { hasher.combine(category) }
        static func == (a: CategoryGroup, b: CategoryGroup) -> Bool {
            a.category == b.category && a.entries.count == b.entries.count
        }
    }

    private func groupedPagesByCategory() -> [CategoryGroup] {
        var buckets: [MotionStudioCategory: [CategoryGroup.Entry]] = [:]
        for (idx, page) in doc.motion.pages.enumerated() {
            let cat = MotionStudioCategory.categorize(page)
            buckets[cat, default: []].append(.init(idx: idx, pageId: page.id, pageName: page.name))
        }
        return buckets
            .map { CategoryGroup(category: $0.key, entries: $0.value) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    // MARK: - Page list row + context menu

    /// 페이지 list row — 호버 시 우측에 ⋯ 메뉴 버튼 노출.
    private func pageListRow(idx: Int, page: MotionPage) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "play.rectangle")
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(page.name.isEmpty ? "동작 \(page.id)" : page.name)
                    .font(DFFont.body)
                    .lineLimit(1)
                Text("\(page.steps.count)단계 · \(formatSeconds(page.totalDurationMs))")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            if doc.hoveredPageIdx == idx {
                Menu {
                    pageContextMenu(at: idx)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(DFColor.textSecondary)
                        .frame(width: DFSize.iconMd2, height: DFSize.iconMd2)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: DFSize.iconMd2)
                .help("이 동작 메뉴 (이름 / 복제 / 삭제 / 내보내기)")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            doc.hoveredPageIdx = hovering ? idx : (doc.hoveredPageIdx == idx ? nil : doc.hoveredPageIdx)
        }
    }

    /// 페이지 context menu — 우클릭 + ⋯ 버튼 양쪽에서 사용.
    @ViewBuilder
    private func pageContextMenu(at idx: Int) -> some View {
        Button {
            doc.renameDraft = doc.motion.pages[safeSidebar: idx]?.name ?? ""
            doc.renamingPageIdx = idx
        } label: {
            Label("이름 변경…", systemImage: "pencil")
        }
        Button {
            onDuplicatePage(idx)
        } label: {
            Label("복제", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            onExportPage(idx)
        } label: {
            Label("이 동작 내보내기…", systemImage: "square.and.arrow.up")
        }
        Button {
            onSaveDocAs()
        } label: {
            Label("전체 동작 doc 저장…", systemImage: "tray.and.arrow.up.fill")
        }
        Divider()
        Button(role: .destructive) {
            doc.deletingPageIdx = idx
        } label: {
            Label("삭제…", systemImage: "trash")
        }
        .disabled(doc.motion.pages.count <= 1)
    }

    /// 이름 변경 sheet.
    private func renameSheet(target: SidebarRenameTarget) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            Text("동작 이름 변경")
                .font(DFFont.title)
            TextField("동작 이름",
                      text: Binding(
                        get: { doc.renameDraft },
                        set: { doc.renameDraft = $0 }
                      ))
                .textFieldStyle(.roundedBorder)
                .font(DFFont.body)
                .onSubmit {
                    onRenamePage(target.idx, doc.renameDraft)
                    doc.renamingPageIdx = nil
                }
            HStack {
                Spacer()
                Button("취소") { doc.renamingPageIdx = nil }
                Button("저장") {
                    onRenamePage(target.idx, doc.renameDraft)
                    doc.renamingPageIdx = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(doc.renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DFSpace.lg)
        .frame(width: 360)
    }

    // MARK: - Helpers

    private func formatSeconds(_ ms: Int) -> String {
        let s = Double(ms) / 1000.0
        if s < 1 { return "\(ms)ms" }
        return String(format: "%.1f초", s)
    }
}

/// Rename sheet 의 Identifiable 래퍼 — SwiftUI `sheet(item:)` 요구.
/// 사이드바 내부 전용이므로 fileprivate.
fileprivate struct SidebarRenameTarget: Identifiable {
    let idx: Int
    var id: Int { idx }
}

/// Array safe subscript — out-of-range index 시 nil.
/// 사이드바 전용 — `pageContextMenu` 의 `pages[safeSidebar: idx]` 접근에 사용.
/// MotionStudioView 의 `safe:` 와 같지만, 충돌 회피를 위해 다른 label.
fileprivate extension Array {
    subscript(safeSidebar index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
