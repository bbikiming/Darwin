import ForgeCore
import os
import SwiftUI

/// RoboPlus Motion 대체 — 페이지 / step 키프레임 타임라인 에디터.
///
/// Layout:
/// - 좌측: 페이지 목록 + 임포트 / 새 페이지
/// - 중앙: 3D 미러 + 타임라인 + 재생 바
/// - 우측: 선택 step 자세 인스펙터
public struct MotionStudioView: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject private var player = MotionPlayer()
    @StateObject private var camera = CameraController()

    /// 사이클 250 (Wave 4.3.2) — document 라이프사이클 state 12개를 `MotionDocumentStore`
    /// 로 추출. MotionStudioView 의 view-only state 와 명확히 분리.
    /// motion / selectedPageIdx / selectedStep / isDirty / renamingPageIdx /
    /// renameDraft / deletingPageIdx / executingOnRobot / hoveredPageIdx /
    /// undoStack / redoStack / copiedStep + maxUndoDepth.
    ///
    /// **사이클 251 (P0 critic fix)**: `@Observable` 매크로 migration 으로
    /// `@StateObject` → `@State` 변경. `@StateObject` 는 `ObservableObject`
    /// 전용이며, `@Observable` 타입은 `@State` (또는 binding 필요 시
    /// `@Bindable`) 로 보유해야 함.
    @State private var doc = MotionDocumentStore()

    @State private var lastError: String?
    @State private var sendToHardware: Bool = false
    @State private var stagedPose: RobotPose = .walkReady
    @State private var inspectorJoint: JointID? = .headPan
    /// 사용자가 가운데 splitter 드래그로 조절 — 우측 inspector width.
    @State private var rightWidth: CGFloat = 360
    @State private var rightOpen: Bool = true
    /// AI 빌더 입력 텍스트.
    @State private var aiBuilderText: String = ""
    @State private var aiBuilderToast: String?
    @State private var torqueSidebarOpen: Bool = true
    /// 사이클 193 — Teach → Motion transfer 토스트.
    @State private var transferToast: String?

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 1080
            let isVeryCompact = geo.size.width < 820
            let maxRight = min(620, geo.size.width * 0.55)
            HStack(spacing: DFSpace.none) {
                if !isCompact {
                    sidebar
                    Divider()
                }
                VStack(spacing: DFSpace.none) {
                    if isCompact {
                        compactPagePicker
                            .padding(.horizontal, DFSpace.md)
                            .padding(.vertical, DFSpace.xs2)
                            .background(DFColor.elev2)
                        Divider()
                    }
                    centerColumn
                }
                if rightOpen && !isVeryCompact {
                    MotionInspectorSplitter(
                        width: $rightWidth,
                        minWidth: 280,
                        maxWidth: maxRight
                    )
                    rightColumn
                        .frame(width: rightWidth)
                } else if !isVeryCompact {
                    motionInspectorClosedHandle
                }
                Divider()
                TorqueLoadSidebar(isOpen: $torqueSidebarOpen)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = transferToast {
                Text(toast)
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DFSpace.md)
                    .padding(.vertical, DFSpace.xs)
                    .background(DFColor.success.opacity(0.92))
                    .clipShape(Capsule())
                    .padding(.bottom, DFSpace.lg)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: transferToast)
        .alert(
            "동작 처리 중 문제가 생겼어요",
            isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } }),
            // **사이클 133 (audit #24, P2)**: role: .cancel 추가 — Esc 키 dismiss + VoiceOver
            // 접근성 개선. "닫기" 단어 자체는 Apple HIG 준수 (informational alert dismiss).
            actions: { Button("닫기", role: .cancel) { lastError = nil } },
            message: { Text(lastError ?? "") }
        )
        .onAppear {
            // 사이클 197 (cycle 190 audit P2 #6): cross-menu 재진입 시 navigation telemetry.
            harness.record(.uiViewAppeared, level: .trace, actor: .user,
                                  data: ["view": AnyCodable("motion_studio")])
            applySelectedStepToPose()
        }
        .onChange(of: player.pose) { _, newPose in
            stagedPose = newPose
            if sendToHardware {
                Task { await applyToHardware(newPose) }
            }
        }
        // 사이클 180 (P0 #3.2 fix, cycle 177 audit): Synth → MotionStudio import.
        // SynthInspectorPanel 의 "Motion 스튜디오 로 보내기" 버튼 이 본 notification 발화.
        .onReceive(NotificationCenter.default.publisher(for: .dfImportSynthPagesToMotionStudio)) { note in
            if let pages = note.object as? [MotionPage] {
                importSynthPages(pages)
            }
        }
        // 사이클 193 (P0 #2): Teach → MotionStudio 자세 전달.
        // TeachModeView 스냅샷 행의 "Motion에 보내기" 버튼이 본 notification 발화.
        .onReceive(NotificationCenter.default.publisher(for: .dfTransferPoseToMotion)) { note in
            if let pose = note.object as? RobotPose {
                importPoseAsMotionPage(pose)
            }
        }
        // Hidden keyboard shortcuts — TextField focus 시 macOS 가 first responder 처리,
        // 그 외에는 우리의 키프레임 동작. ⌘C/V 같은 표준 단축키 자연 우선순위.
        .background(motionEditShortcuts)
    }

    /// 사이클 180 + 187 (codex MAJOR fix): Synth 합성 결과 페이지 일괄 import.
    ///
    /// SynthMotionExporter.reassignPageIds 가 overflow 안전 보장 (UInt8 max=255).
    /// overflow 시 lastError alert 으로 사용자에게 안내, motion 상태 변경 X.
    /// 종전 (cycle 180): UInt8(clamping:) 로 silent 255 clamp → duplicate ID 위험.
    private func importSynthPages(_ pages: [MotionPage]) {
        guard !pages.isEmpty else { return }
        let existingMaxId = doc.motion.pages.map { Int($0.id) }.max() ?? 0
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: existingMaxId,
            importPages: pages
        )
        switch result {
        case .success(let reassigned):
            pushUndoSnapshot()
            doc.motion = MotionDoc(
                version: doc.motion.version,
                robotGeneration: doc.motion.robotGeneration,
                pages: doc.motion.pages + reassigned
            )
            // 첫 신규 페이지 선택 — 사용자 가 즉시 확인.
            doc.selectedPageIdx = doc.motion.pages.count - reassigned.count
            doc.selectedStep = 0
            applySelectedStepToPose()
            doc.isDirty = true
        case .failure(let err):
            // 사이클 187: overflow 시 사용자 알림. motion 무변화.
            lastError = SynthMotionExporter.koreanMessage(for: err)
        }
    }

    /// 사이클 193 — Teach 스냅샷 자세를 단일 step MotionPage 로 import.
    ///
    /// SynthMotionExporter.reassignPageIds 로 overflow-safe ID 부여.
    private func importPoseAsMotionPage(_ pose: RobotPose) {
        let existingMaxId = doc.motion.pages.map { Int($0.id) }.max() ?? 0
        let step = MotionStep.from(pose: pose, playMs: 256, pauseMs: 0)
        let draft = MotionPage(id: 1, name: "티칭 자세 \(existingMaxId + 1)", steps: [step])
        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: existingMaxId,
            importPages: [draft]
        )
        switch result {
        case .success(let reassigned):
            pushUndoSnapshot()
            doc.motion = MotionDoc(
                version: doc.motion.version,
                robotGeneration: doc.motion.robotGeneration,
                pages: doc.motion.pages + reassigned
            )
            doc.selectedPageIdx = doc.motion.pages.count - 1
            doc.selectedStep = 0
            applySelectedStepToPose()
            doc.isDirty = true
            transferToast = "✅ Motion 페이지 추가됨"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                transferToast = nil
            }
            // 사이클 203 (cycle 199 critic missing #3): Teach → Motion transfer telemetry.
            // motionPageCreated 패턴 일관 (cycle 191 audit 의 recommended) — 신규 페이지
            // ID + source 만 (pose 좌표 X — PII 회피).
            if let newId = reassigned.first?.id {
                harness.record(
                    .motionPageCreated, level: .info, actor: .user,
                    data: ["new_id": AnyCodable(Int(newId)),
                           "source": AnyCodable("teach_transfer")]
                )
            }
        case .failure(let err):
            lastError = SynthMotionExporter.koreanMessage(for: err)
        }
    }

    /// MotionStudio 전용 키프레임 단축키. opacity 0 + 0×0 frame 으로 hidden.
    @ViewBuilder
    private var motionEditShortcuts: some View {
        ZStack {
            Button("Undo") { undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canUndo)
            Button("Redo") { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canRedo)
            Button("Copy keyframe") { copySelectedStep() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste keyframe") { pasteStep() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(doc.copiedStep == nil)
            Button("Split keyframe") { splitSelectedStep() }
                .keyboardShortcut("k", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
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
        }
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
            applySelectedStepToPose()
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

    // MARK: - Sidebar (pages)

    private var sidebar: some View {
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
                    addPage()
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("빈 동작 새로 만들기")

                Button {
                    importMotionPanel()
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("로보플러스 .mtn 동작 파일 가져오기")
            }
            .padding(.horizontal, DFSpace.md)

            Divider().padding(.vertical, DFSpace.xs)

            // 2026-05-17 카테고리 그룹핑 — Section 으로 묶음 (사용자 가독성).
            // MotionStudioCategory.categorize(_:) 가 id/name 기반 자동 분류.
            let grouped = groupedPagesByCategory()
            List(selection: Binding(
                get: { doc.selectedPageIdx },
                set: { if let v = $0 { doc.selectedPageIdx = v; doc.selectedStep = 0; applySelectedStepToPose() } }
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
            get: { doc.renamingPageIdx.map { RenameTarget(idx: $0) } },
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
                deletePage(at: idx)
                doc.deletingPageIdx = nil
            }
        } message: { idx in
            if idx < doc.motion.pages.count {
                Text("\"\(doc.motion.pages[idx].name)\" 을(를) 영구 삭제합니다.\n저장하지 않으면 동작 doc 만 비워지고 파일에는 영향 없음.")
            } else {
                Text("이 동작을 삭제합니다.")
            }
        }
    }

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
            doc.renameDraft = doc.motion.pages[safe: idx]?.name ?? ""
            doc.renamingPageIdx = idx
        } label: {
            Label("이름 변경…", systemImage: "pencil")
        }
        Button {
            duplicatePage(at: idx)
        } label: {
            Label("복제", systemImage: "doc.on.doc")
        }
        Divider()
        Button {
            exportPage(at: idx)
        } label: {
            Label("이 동작 내보내기…", systemImage: "square.and.arrow.up")
        }
        Button {
            saveDocAs()
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
    private func renameSheet(target: RenameTarget) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            Text("동작 이름 변경")
                .font(DFFont.title)
            // 사이클 251 (P0 critic fix): `@Observable` migration 후 `$doc.X` 직접
            // projection 불가 — `Binding(get:set:)` 으로 명시적 binding 생성.
            // 파일 내 다른 store-property bindings (line 346, 375 등) 와 동일 패턴.
            TextField("동작 이름",
                      text: Binding(
                        get: { doc.renameDraft },
                        set: { doc.renameDraft = $0 }
                      ))
                .textFieldStyle(.roundedBorder)
                .font(DFFont.body)
                .onSubmit {
                    renamePage(at: target.idx, to: doc.renameDraft)
                    doc.renamingPageIdx = nil
                }
            HStack {
                Spacer()
                Button("취소") { doc.renamingPageIdx = nil }
                Button("저장") {
                    renamePage(at: target.idx, to: doc.renameDraft)
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

    private func formatSeconds(_ ms: Int) -> String {
        let s = Double(ms) / 1000.0
        if s < 1 { return "\(ms)ms" }
        return String(format: "%.1f초", s)
    }

    /// 컴팩트 모드 — sidebar 대신 헤더의 picker로 페이지 선택.
    private var compactPagePicker: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(DFColor.accent)
            // 사이클 251 (P0 critic fix): `@Observable` migration 후 `$doc.X` 직접
            // projection 불가 — `Binding(get:set:)` 으로 picker selection 생성.
            Picker("동작",
                   selection: Binding(
                    get: { doc.selectedPageIdx },
                    set: { doc.selectedPageIdx = $0 }
                   )) {
                ForEach(Array(doc.motion.pages.enumerated()), id: \.offset) { idx, page in
                    Text(page.name.isEmpty ? "동작 \(page.id)" : page.name).tag(idx)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: doc.selectedPageIdx) { _, _ in
                doc.selectedStep = 0
                applySelectedStepToPose()
            }
            Spacer()
            Button {
                addPage()
            } label: { Image(systemName: "plus.circle") }
            .buttonStyle(.plain).help("새 동작")
            Button {
                importMotionPanel()
            } label: { Image(systemName: "tray.and.arrow.down") }
            .buttonStyle(.plain).help("동작 가져오기")
        }
    }

    // MARK: - Center (3D + timeline)

    private var centerColumn: some View {
        VStack(spacing: DFSpace.none) {
            ZStack(alignment: .topLeading) {
                RobotScene3D(pose: stagedPose,
                             footTrace: [],
                             highlight: inspectorJoint,
                             showAxes: true,
                             cameraController: camera)
                // 3D 가 무엇을 보여주는지 명확히 — 사용자가 편집/재생/송출을 한눈에 구분.
                HStack(spacing: DFSpace.xs) {
                    sourceModeBadge
                    pageMetaBadge
                }
                .padding(DFSpace.md)
                ViewportControls(camera: camera)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topTrailing)
            }
            .background(LinearGradient(colors: [DFColor.canvas.opacity(DFOpacity.dim), DFColor.canvas],
                                        startPoint: .top, endPoint: .bottom))

            Divider()

            timelineSection
                .padding(DFSpace.md)
                .background(DFColor.card)
        }
    }

    /// 3D 뷰포트의 데이터 출처 — 4가지 상태로 사용자가 자기 행동의 효과를 정확히 인지.
    ///
    /// **Codex pass 1 [P2]**: 이전엔 정지/일시정지 + sendToHardware ON 케이스가
    /// `.editing` 으로 떨어져 "로봇은 움직이지 않아요" 라고 거짓말함. 실제로는 인스펙터
    /// 슬라이더가 매번 `applyToHardware` 를 호출하여 로봇이 움직임. 새 `.liveEditing`
    /// 케이스로 명시.
    private enum SourceMode {
        case editing       // 정지/일시정지 + 송출 OFF (또는 버스 nil) — 진정한 화면-only.
        case liveEditing   // 정지/일시정지 + 송출 ON + 버스 있음 — 슬라이더 한 번에 모터 1번.
        case previewing    // 재생 + 송출 OFF (또는 버스 nil) — 화면에서만 재생.
        case broadcasting  // 재생 + 송출 ON + 버스 있음 — 모션 전체가 로봇으로 송출.

        var title: String {
            switch self {
            case .editing:      return "편집 미리보기"
            case .liveEditing:  return "실시간 편집 송출"
            case .previewing:   return "재생 미리보기"
            case .broadcasting: return "로봇으로 송출 중"
            }
        }
        var icon: String {
            switch self {
            case .editing:      return "pencil.tip"
            case .liveEditing:  return "slider.horizontal.below.rectangle"
            case .previewing:   return "play.tv"
            case .broadcasting: return "antenna.radiowaves.left.and.right"
            }
        }
        var help: String {
            switch self {
            case .editing:
                return "선택한 단계의 자세를 화면에만 보여줍니다. 로봇은 움직이지 않아요."
            case .liveEditing:
                // **Codex pass 3 [P2]**: MotionStudioView 의 PoseInspector binding setter
                // (line ~836) 가 매 변경마다 stagedPose 갱신 + `if sendToHardware`
                // 즉시 송출 — PoseInspector 내부의 commit-only logic 을 우회한다.
                // 따라서 드래그 중 매 frame 송출이 일어남. 사실대로 안내.
                return "슬라이더가 움직이는 동안 매 변경이 곧바로 로봇으로 송출됩니다. 모터 부하가 클 수 있으니 큰 변경 전에는 ‘로봇에 보내기’ 토글을 끄세요."
            case .previewing:
                return "모션을 화면에서만 재생합니다. 로봇은 움직이지 않아요."
            case .broadcasting:
                return "재생 중인 모션이 실 로봇으로 송출되고 있습니다."
            }
        }
    }

    private var currentSourceMode: SourceMode {
        // sendToHardware 토글이 켜져 있더라도 bus == nil 이면 송출은 silent no-op
        // (applyToHardware:guard let bus = store.bus else { return }) — UI 도 그에 맞춰
        // "송출 중" 으로 가짜 안내하지 않음.
        let live = sendToHardware && store.bus != nil
        let playing = (player.mode == .playing)
        if playing && live  { return .broadcasting }
        if playing          { return .previewing }
        if live             { return .liveEditing }
        return .editing
    }

    private var sourceModeBadge: some View {
        let mode = currentSourceMode
        let tint: Color = {
            switch mode {
            case .editing:      return DFColor.textSecondary
            case .liveEditing:  return DFColor.warning  // 송출은 맞지만 부분적 — 주황.
            case .previewing:   return DFColor.info
            case .broadcasting: return DFColor.danger   // 전체 모션 송출 — 빨강.
            }
        }()
        return HStack(spacing: DFSpace.xs) {
            Image(systemName: mode.icon)
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(tint)
            Text(mode.title)
                .font(.system(size: DFFontSize.s10, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 0.8))
        .help(mode.help)
    }

    private var pageMetaBadge: some View {
        Group {
            if let page = currentPage {
                HStack(spacing: DFSpace.sm) {
                    Image(systemName: "doc.text").foregroundStyle(DFColor.accent)
                    VStack(alignment: .leading, spacing: DFSpace.none) {
                        Text(page.name.isEmpty ? "동작 \(page.id)" : page.name)
                            .font(DFFont.bodyEmph)
                        Text(metaLine(for: page))
                            .font(DFFont.caption.monospaced())
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
                .padding(.horizontal, DFSpace.md)
                .padding(.vertical, DFSpace.sm)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            }
        }
    }

    private func metaLine(for page: MotionPage) -> String {
        var parts: [String] = []
        parts.append("\(page.steps.count)단계")
        if page.nextPage != 0 { parts.append("다음: 동작 \(page.nextPage)") }
        if page.exitPage != 0 { parts.append("종료: 동작 \(page.exitPage)") }
        return parts.joined(separator: " · ")
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            transportRow

            if let page = currentPage {
                TimelineCanvas(
                    page: page,
                    selectedStep: Binding(
                        get: { doc.selectedStep },
                        set: { doc.selectedStep = $0; applySelectedStepToPose() }
                    ),
                    elapsedMs: player.elapsedMs,
                    onSeek: { player.seek(toMs: $0) }
                )

                stepDetailRow(page: page)
            } else {
                ContentUnavailableView(
                    "동작을 선택하세요",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("왼쪽 목록에서 동작을 고르거나, ➕ 버튼으로 새로 만들거나, ⬇️ 로 .mtn 파일을 가져올 수 있어요.")
                )
            }
        }
    }

    /// 영상 편집 도구 (Premiere / FCP / After Effects) 스타일의 transport bar.
    /// 분리된 컴포넌트로 — `Motion/TransportBar.swift`.
    private var transportRow: some View {
        TransportBar(
            player: player,
            totalDurationMs: Double(currentPage?.totalDurationMs ?? 0),
            stepCount: currentPage?.steps.count ?? 0,
            hasBus: store.bus != nil,
            sendToHardware: $sendToHardware,
            isDirty: doc.isDirty,
            executingOnRobot: doc.executingOnRobot,
            canUndo: canUndo,
            canRedo: canRedo,
            onPlay: { startPlayback() },
            onAddStep: { addStepFromCurrentPose() },
            onCapture: { captureFromTelemetry() },
            onRunOnRobot: { runCurrentPageOnRobot() },
            onSave: { saveDocAs() },
            onUndo: { undo() },
            onRedo: { redo() }
        )
    }

    /// "로봇에 실행" — 현재 페이지를 1배속으로 재생 + sendToHardware 일시 활성 + 끝나면 복귀.
    /// LIVE 토글과 다름: 명시적 "한 번 실행" semantic, 진행 중 버튼 disabled + 상태 표시.
    private func runCurrentPageOnRobot() {
        guard store.bus != nil, let page = currentPage else { return }
        let priorSend = sendToHardware
        doc.executingOnRobot = true
        sendToHardware = true     // 재생 중 player.pose 변경 → applyToHardware 자동 전송.
        player.load(page, from: .walkReady)
        player.playbackRate = 1.0  // 실 송출은 1배속 고정 — 모터 안전.
        player.isLooping = false   // 한 번만.
        player.play()

        // 종료 polling — player.mode == .stop 으로 전환 시 정리.
        Task { @MainActor in
            while player.mode == .playing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // 정리 — sendToHardware 원복 + executingOnRobot off.
            sendToHardware = priorSend
            doc.executingOnRobot = false
        }
    }

    private func stepDetailRow(page: MotionPage) -> some View {
        // 현재 step idx 가 안전한 범위인지.
        let stepCount = page.steps.count
        return HStack(spacing: DFSpace.md) {
            // 키프레임 위치 label.
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: DFFontSize.s11))
                    .foregroundStyle(DFColor.forge)
                Text("\(doc.selectedStep + 1) / \(stepCount)")
                    .font(DFFont.bodyEmph.monospacedDigit())
            }

            Divider().frame(height: DFSize.iconMd2)

            // 이동 시간 (playMs) — stepper 인라인 편집.
            keyframeStepperField(
                label: "이동",
                valueMs: page.steps[safe: doc.selectedStep]?.playMs ?? 0,
                range: 0...4096,    // .mtn raw 한계 (255 × 8ms = ~2040ms 권장, 여유로 4096).
                stepMs: 8,           // .mtn raw 단위 (1 raw = 8ms).
                tint: DFColor.accent
            ) { newMs in
                updateSelectedStepTiming(playMs: newMs, pauseMs: nil)
            }

            // 멈춤 시간 (pauseMs) — stepper 인라인 편집.
            keyframeStepperField(
                label: "정지",
                valueMs: page.steps[safe: doc.selectedStep]?.pauseMs ?? 0,
                range: 0...2040,
                stepMs: 8,
                tint: DFColor.textSecondary
            ) { newMs in
                updateSelectedStepTiming(playMs: nil, pauseMs: newMs)
            }

            Spacer()

            // 키프레임 편집 클러스터 — Copy / Paste / Split (단축키 ⌘C / ⌘V / ⌘K).
            HStack(spacing: DFSpace.micro2) {
                keyframeIconButton(
                    icon: "doc.on.doc",
                    help: "키프레임 복사 (⌘C)",
                    tint: DFColor.accent,
                    enabled: true,
                    action: { copySelectedStep() }
                )
                keyframeIconButton(
                    icon: "doc.on.clipboard",
                    help: doc.copiedStep == nil
                        ? "먼저 키프레임을 복사하세요"
                        : "복사한 키프레임 붙여넣기 (⌘V)",
                    tint: DFColor.accent,
                    enabled: doc.copiedStep != nil,
                    action: { pasteStep() }
                )
                keyframeIconButton(
                    icon: "scissors",
                    help: "키프레임 쪼개기 (⌘K) — 중간 자세로 두 단계 분할",
                    tint: DFColor.forge,
                    enabled: (page.steps[safe: doc.selectedStep]?.playMs ?? 0) >= 16,
                    action: { splitSelectedStep() }
                )
            }

            Divider().frame(height: DFSize.iconMd2)

            Button(role: .destructive) {
                removeSelectedStep()
            } label: {
                Label("이 단계 삭제", systemImage: "trash")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
            }
            .controlSize(.small)
            .disabled(stepCount <= 1)
            .help("동작에는 최소 한 단계가 있어야 해요")
        }
        .font(DFFont.caption)
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(DFColor.elev2.opacity(DFOpacity.dim))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    /// 키프레임 편집 아이콘 버튼 — Copy / Paste / Split 공통 스타일.
    private func keyframeIconButton(
        icon: String,
        help: String,
        tint: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s11, weight: .semibold))
                .foregroundStyle(enabled ? tint : DFColor.textSecondary.opacity(DFOpacity.disabled))
                .frame(width: DFSize.iconMd, height: DFSize.iconMd)
                .background(enabled ? tint.opacity(DFOpacity.subtle) : DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(
                            enabled ? tint.opacity(DFOpacity.strong) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                            lineWidth: DFSize.borderHairline
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// 키프레임 시간 stepper — 라벨 + 값 (mono) + Stepper +/-. 변경 시 onChange 콜.
    private func keyframeStepperField(
        label: String,
        valueMs: Int,
        range: ClosedRange<Int>,
        stepMs: Int,
        tint: Color,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: DFSpace.xs) {
            Text(label)
                .font(.system(size: DFFontSize.s11))
                .foregroundStyle(DFColor.textSecondary)
            Text("\(valueMs)ms")
                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(minWidth: 56, alignment: .trailing)
                .monospacedDigit()
            Stepper("",
                    value: Binding(
                        get: { valueMs },
                        set: { onChange(max(range.lowerBound, min(range.upperBound, $0))) }
                    ),
                    in: range,
                    step: stepMs)
                .labelsHidden()
                .controlSize(.mini)
        }
        .padding(.horizontal, DFSpace.xs2)
        .padding(.vertical, DFSpace.xs)
        .background(DFColor.canvas.opacity(DFOpacity.dim))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs)
                .stroke(tint.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
    }

    /// 선택된 step 의 playMs / pauseMs 갱신. nil 인 인자는 변경 안 함.
    private func updateSelectedStepTiming(playMs: Int?, pauseMs: Int?) {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return }
        let stepCount = doc.motion.pages[doc.selectedPageIdx].steps.count
        guard doc.selectedStep >= 0, doc.selectedStep < stepCount else { return }
        var step = doc.motion.pages[doc.selectedPageIdx].steps[doc.selectedStep]
        let oldStep = step
        if let newPlay = playMs {
            // playMs / pauseMs 모두 raw (×8 ms) 로 저장 — 8 단위 quantize.
            let quantized = max(0, (newPlay / 8) * 8)
            step.playTime = UInt8(clamping: quantized / 8)
        }
        if let newPause = pauseMs {
            let quantized = max(0, (newPause / 8) * 8)
            step.pauseTime = UInt8(clamping: quantized / 8)
        }
        guard step != oldStep else { return }   // 무의미한 변경 skip (undo 폭주 방지).
        pushUndoSnapshot()
        doc.motion.pages[doc.selectedPageIdx].steps[doc.selectedStep] = step
        markDirty()
        // Player 에 변경 반영 — 재생 중이면 다음 tick 부터 적용.
        if let page = currentPage {
            let wasPlaying = player.mode == .playing
            let elapsed = player.elapsedMs
            player.page = page
            player.seek(toMs: elapsed)
            if wasPlaying { player.play() }
        }
    }

    // MARK: - Right (inspector)

    private var rightColumn: some View {
        VStack(spacing: DFSpace.none) {
            HStack {
                Text("자세 편집기").font(DFFont.bodyEmph)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { rightOpen = false }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DFColor.textSecondary)
                .help("자세 편집기 닫기")
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm)
            .background(DFColor.elev2)
            Divider()

            PoseInspector(
                pose: Binding(
                    get: { stagedPose },
                    set: { newPose in
                        stagedPose = newPose
                        saveCurrentStepFromPose()
                        if sendToHardware { Task { await applyToHardware(newPose) } }
                    }
                ),
                selected: $inspectorJoint,
                states: store.lastTelemetry?.joints ?? store.jointStates,
                liveApply: sendToHardware,
                onApplyToHardware: { p in Task { await applyToHardware(p) } }
            )
        }
    }

    private var motionInspectorClosedHandle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { rightOpen = true }
        } label: {
            VStack(spacing: DFSpace.xs2) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: DFFontSize.s14, weight: .semibold))
                Text("자세\n편집기")
                    .font(.system(size: DFFontSize.s9))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(DFColor.textSecondary)
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .background(DFColor.elev2)
        }
        .buttonStyle(.plain)
        .help("자세 편집기 열기")
    }

    // MARK: - Actions

    private var currentPage: MotionPage? {
        guard doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count else { return nil }
        return doc.motion.pages[doc.selectedPageIdx]
    }

    private func startPlayback() {
        guard let page = currentPage else { return }
        player.load(page, from: stagedPose)
        player.play()
    }

    private func applySelectedStepToPose() {
        guard let page = currentPage,
              doc.selectedStep < page.steps.count else { return }
        stagedPose = page.steps[doc.selectedStep].toPose()
    }

    private func saveCurrentStepFromPose() {
        guard var page = currentPage,
              doc.selectedStep < page.steps.count else { return }
        let oldStep = page.steps[doc.selectedStep]
        // 자세만 변경 — pose 의 byte-level 비교로 무의미 변경 skip (undo 폭주 방지).
        let newStep = MotionStep.from(
            pose: stagedPose,
            playMs: oldStep.playMs,
            pauseMs: oldStep.pauseMs
        )
        guard newStep != oldStep else { return }
        pushUndoSnapshot()
        page.steps[doc.selectedStep] = newStep
        doc.motion.pages[doc.selectedPageIdx] = page
        markDirty()
    }

    private func addStepFromCurrentPose() {
        guard var page = currentPage else { return }
        pushUndoSnapshot()
        let step = MotionStep.from(pose: stagedPose, playMs: 256, pauseMs: 0)
        page.steps.append(step)
        doc.motion.pages[doc.selectedPageIdx] = page
        doc.selectedStep = page.steps.count - 1
        markDirty()
    }

    private func removeSelectedStep() {
        guard var page = currentPage, page.steps.count > 1 else { return }
        pushUndoSnapshot()
        page.steps.remove(at: doc.selectedStep)
        if doc.selectedStep >= page.steps.count { doc.selectedStep = page.steps.count - 1 }
        doc.motion.pages[doc.selectedPageIdx] = page
        applySelectedStepToPose()
        markDirty()
    }

    private func addPage() {
        pushUndoSnapshot()
        let nextId = (doc.motion.pages.map { $0.id }.max() ?? 0) + 1
        let newPage = MotionPage(id: nextId, name: "새 동작 \(nextId)",
                                 steps: [.from(pose: .walkReady, playMs: 256, pauseMs: 0)])
        doc.motion.pages.append(newPage)
        doc.selectedPageIdx = doc.motion.pages.count - 1
        doc.selectedStep = 0
        markDirty()
        // v1.12.2 telemetry — 페이지 생성 (name redacted).
        harness.record(
            .motionPageCreated, level: .info, actor: .user,
            data: ["page_id": AnyCodable(nextId),
                   "name_hash": AnyCodable(Harness.shortHash(newPage.name)),
                   "total_pages": AnyCodable(doc.motion.pages.count)]
        )
    }

    // MARK: - Page management (duplicate / rename / delete / export)

    /// 페이지 복제 — 같은 step 시퀀스, 새 ID, "<name> 복사본" suffix.
    private func duplicatePage(at idx: Int) {
        guard idx >= 0, idx < doc.motion.pages.count else { return }
        pushUndoSnapshot()
        let src = doc.motion.pages[idx]
        let nextId = (doc.motion.pages.map { $0.id }.max() ?? 0) + 1
        let copyName = src.name.isEmpty ? "동작 \(src.id) 복사본" : "\(src.name) 복사본"
        let copy = MotionPage(
            id: nextId,
            name: copyName,
            compliance: src.compliance,
            nextPage: 0,        // 복제본은 next/exit 체인 끊음 — 안전.
            exitPage: 0,
            repeat: src.repeat,
            speed: src.speed,
            accel: src.accel,
            steps: src.steps
        )
        // 원본 바로 다음 자리에 삽입.
        doc.motion.pages.insert(copy, at: idx + 1)
        doc.selectedPageIdx = idx + 1
        doc.selectedStep = 0
        markDirty()
        applySelectedStepToPose()
    }

    /// 페이지 삭제 — 1 개 미만으로 줄지 않도록 보호.
    private func deletePage(at idx: Int) {
        guard doc.motion.pages.count > 1, idx >= 0, idx < doc.motion.pages.count else { return }
        let removed = doc.motion.pages[idx]
        pushUndoSnapshot()
        doc.motion.pages.remove(at: idx)
        doc.selectedPageIdx = max(0, min(doc.selectedPageIdx, doc.motion.pages.count - 1))
        doc.selectedStep = 0
        markDirty()
        applySelectedStepToPose()
        // v1.12.2 telemetry — 페이지 삭제 (name redacted).
        harness.record(
            .motionPageDeleted, level: .info, actor: .user,
            data: ["page_id": AnyCodable(removed.id),
                   "name_hash": AnyCodable(Harness.shortHash(removed.name)),
                   "remaining_pages": AnyCodable(doc.motion.pages.count)]
        )
    }

    /// 페이지 이름 변경.
    private func renamePage(at idx: Int, to newName: String) {
        guard idx >= 0, idx < doc.motion.pages.count else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, doc.motion.pages[idx].name != trimmed else { return }
        let oldName = doc.motion.pages[idx].name
        let pageId = doc.motion.pages[idx].id
        pushUndoSnapshot()
        doc.motion.pages[idx].name = trimmed
        markDirty()
        // v1.12.2 telemetry — 페이지 이름 변경 (names redacted to hashes).
        harness.record(
            .motionPageRenamed, level: .info, actor: .user,
            data: ["page_id": AnyCodable(pageId),
                   "from_hash": AnyCodable(Harness.shortHash(oldName)),
                   "to_hash": AnyCodable(Harness.shortHash(trimmed)),
                   "to_len": AnyCodable(trimmed.count)]
        )
    }

    /// 단일 페이지 .json 으로 내보내기 (NSSavePanel).
    private func exportPage(at idx: Int) {
        guard idx >= 0, idx < doc.motion.pages.count else { return }
        let page = doc.motion.pages[idx]
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "\(page.name.isEmpty ? "motion-\(page.id)" : page.name).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let single = MotionDoc(version: doc.motion.version,
                                    robotGeneration: doc.motion.robotGeneration,
                                    pages: [page])
            let json = try single.toJSON(prettyPrinted: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "내보내기 실패: \(error.localizedDescription)"
        }
    }

    /// 전체 motion doc 을 .json 으로 저장 (NSSavePanel) — "다른 이름으로 저장".
    private func saveDocAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "motion-doc.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try doc.motion.toJSON(prettyPrinted: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
            doc.isDirty = false   // 저장 완료 → clean 상태.
        } catch {
            lastError = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// motion doc 변경 시 dirty flag set — UI 의 저장 버튼 활성화.
    private func markDirty() { doc.isDirty = true }

    // MARK: - Undo / Redo

    /// 모든 mutation 함수 시작에 호출 — 현재 motion 을 undo stack 에 push.
    /// 50 개 초과 시 가장 오래된 항목 drop. redo stack 은 invalidate (새 분기).
    private func pushUndoSnapshot() {
        doc.undoStack.append(doc.motion)
        if doc.undoStack.count > doc.maxUndoDepth { doc.undoStack.removeFirst() }
        doc.redoStack.removeAll()
    }

    /// ⌘Z — 마지막 변경 되돌리기. 변경 없으면 noop.
    private func undo() {
        guard let prev = doc.undoStack.popLast() else { return }
        doc.redoStack.append(doc.motion)
        doc.motion = prev
        // 인덱스 안전 보정 — pages / steps 가 줄어들 수 있음.
        doc.selectedPageIdx = min(doc.selectedPageIdx, max(0, doc.motion.pages.count - 1))
        if doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count {
            doc.selectedStep = min(doc.selectedStep, max(0, doc.motion.pages[doc.selectedPageIdx].steps.count - 1))
        } else {
            doc.selectedStep = 0
        }
        applySelectedStepToPose()
        doc.isDirty = true
    }

    /// ⌘⇧Z — 되돌린 변경을 다시 앞으로.
    private func redo() {
        guard let next = doc.redoStack.popLast() else { return }
        doc.undoStack.append(doc.motion)
        doc.motion = next
        doc.selectedPageIdx = min(doc.selectedPageIdx, max(0, doc.motion.pages.count - 1))
        if doc.selectedPageIdx >= 0, doc.selectedPageIdx < doc.motion.pages.count {
            doc.selectedStep = min(doc.selectedStep, max(0, doc.motion.pages[doc.selectedPageIdx].steps.count - 1))
        } else {
            doc.selectedStep = 0
        }
        applySelectedStepToPose()
        doc.isDirty = true
    }

    var canUndo: Bool { !doc.undoStack.isEmpty }
    var canRedo: Bool { !doc.redoStack.isEmpty }

    // MARK: - Copy / Paste / Split (키프레임)

    /// ⌘C — 현재 선택 step 을 클립보드 (in-memory `copiedStep`) 로.
    /// 다른 동작에 paste 가능. 시스템 클립보드 (NSPasteboard) 와는 별개 —
    /// 사용자가 TextField focus 시 ⌘C 는 텍스트 복사가 우선이라 충돌 없음.
    private func copySelectedStep() {
        guard let page = currentPage,
              doc.selectedStep >= 0, doc.selectedStep < page.steps.count else { return }
        doc.copiedStep = page.steps[doc.selectedStep]
    }

    /// ⌘V — 복사된 step 을 현재 위치 *다음에* 삽입. 자동으로 새 step 선택.
    private func pasteStep() {
        guard let step = doc.copiedStep,
              var page = currentPage else { return }
        pushUndoSnapshot()
        let insertAt = min(page.steps.count, max(0, doc.selectedStep + 1))
        page.steps.insert(step, at: insertAt)
        doc.motion.pages[doc.selectedPageIdx] = page
        doc.selectedStep = insertAt
        markDirty()
        applySelectedStepToPose()
    }

    /// ⌘K — 현재 선택 step 을 두 개로 분할.
    ///
    /// 동작:
    ///   1. 이전 step (또는 walkReady) → 현재 step 의 자세를 0.5 lerp 한 *중간 자세*.
    ///   2. playMs 의 절반을 첫 step 에 부여, 중간 자세 step 으로 변환.
    ///   3. 남은 절반 playMs + 원래 자세 + 원래 pauseMs 를 두 번째 step 으로.
    ///   4. 후반부 (원래 자세) 자동 선택 — split 후에도 사용자 의도 유지.
    private func splitSelectedStep() {
        guard var page = currentPage,
              doc.selectedStep >= 0, doc.selectedStep < page.steps.count else { return }
        let original = page.steps[doc.selectedStep]
        // playMs 가 16ms 미만이면 분할 무의미 (8ms × 2 단위).
        guard original.playMs >= 16 else { return }
        pushUndoSnapshot()

        // 이전 자세 — selectedStep > 0 면 이전 step 의 toPose(), 아니면 walkReady.
        let prevPose: RobotPose = doc.selectedStep > 0
            ? page.steps[doc.selectedStep - 1].toPose()
            : .walkReady
        let curPose = original.toPose()
        let midPose = prevPose.lerp(to: curPose, t: 0.5)

        // 8ms quantize. playMs/2 → /16 × 8 단위 (.mtn raw quantize).
        let halfPlay = (original.playMs / 16) * 8
        let remainPlay = original.playMs - halfPlay

        let firstHalf = MotionStep.from(pose: midPose,
                                         playMs: halfPlay,
                                         pauseMs: 0)
        var secondHalf = original
        secondHalf.playTime = UInt8(clamping: remainPlay / 8)
        // pauseTime 은 원래 step 의 것 유지.

        page.steps[doc.selectedStep] = firstHalf
        page.steps.insert(secondHalf, at: doc.selectedStep + 1)
        doc.motion.pages[doc.selectedPageIdx] = page

        // 후반부 (원본 자세) 자동 선택.
        doc.selectedStep += 1
        markDirty()
        applySelectedStepToPose()
    }

    private func captureFromTelemetry() {
        guard let bus = store.bus else { return }
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            if let s = try? bus.readState(j) { dict[j] = Int(s.presentPosition) }
        }
        if !dict.isEmpty { stagedPose = stagedPose.with(dict) }
        saveCurrentStepFromPose()
    }

    private func importMotionPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let mtn = try String(contentsOf: url, encoding: .utf8)
                let json = try Motion.mtnToJSON(mtn, generation: "op2")
                // 사이클 250 (W4.3.2): 로컬 변수명 `doc` 가 store property 와 충돌하지
                // 않도록 `imported` 로 rename.
                let imported = try MotionDoc.from(json: json)
                self.doc.motion = imported
                self.doc.selectedPageIdx = 0
                self.doc.selectedStep = 0
                applySelectedStepToPose()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func applyToHardware(_ pose: RobotPose) async {
        guard let bus = store.bus else { return }
        for j in JointID.allCases {
            do {
                _ = try bus.setPosition(j, raw: UInt16(clamping: pose.raw(j)))
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    // MARK: - Helpers

    /// Rename sheet 의 Identifiable 래퍼 — SwiftUI sheet(item:) 요구.
    fileprivate struct RenameTarget: Identifiable {
        let idx: Int
        var id: Int { idx }
    }
}

/// Array safe subscript — out-of-range index 시 nil (페이지 idx 안전 접근).
fileprivate extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// MotionStudio 우측 자세 편집기 width를 드래그로 조절하는 splitter.
struct MotionInspectorSplitter: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isHovering: Bool = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(width: 8).contentShape(Rectangle())
            Rectangle()
                .fill(isHovering ? DFColor.accent : DFColor.textSecondary.opacity(DFOpacity.o20))
                .frame(width: isHovering ? 2 : 1)
        }
        .frame(width: 8)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil { dragStartWidth = width }
                    let delta = -value.translation.width
                    let newWidth = (dragStartWidth ?? width) + delta
                    width = max(minWidth, min(maxWidth, newWidth))
                }
                .onEnded { _ in dragStartWidth = nil }
        )
    }
}
