import ForgeCore
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

    @State private var motion: MotionDoc = MotionStudioView.starterDoc()
    @State private var selectedPageIdx: Int = 0
    @State private var selectedStep: Int = 0
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

    // MARK: - Edit workflow state

    /// 마지막 저장 이후 변경 있음 — 저장 버튼 활성화 + 닫기 시 경고용.
    @State private var isDirty: Bool = false
    /// 이름 변경 sheet 의 대상 페이지 idx + 임시 이름. nil = sheet 닫힘.
    @State private var renamingPageIdx: Int? = nil
    @State private var renameDraft: String = ""
    /// 삭제 확인 alert 의 대상 페이지 idx.
    @State private var deletingPageIdx: Int? = nil
    /// "로봇에 실행" 진행 중 — 버튼 disabled + 진행 표시.
    @State private var executingOnRobot: Bool = false
    /// 호버한 페이지 idx — `⋯` 메뉴 버튼 표시용.
    @State private var hoveredPageIdx: Int? = nil

    // MARK: - Undo / Redo / clipboard

    /// 변경 history — 모든 mutation 직전 `pushUndoSnapshot()` 이 motion 을 push.
    /// 50 개 제한 — 너무 깊으면 메모리 폭발.
    @State private var undoStack: [MotionDoc] = []
    @State private var redoStack: [MotionDoc] = []
    /// 키프레임 복사 — selected step 의 byte-exact copy.
    @State private var copiedStep: MotionStep? = nil
    /// 최대 undo depth.
    private let maxUndoDepth: Int = 50

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
        .alert(
            "동작 처리 중 문제가 생겼어요",
            isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } }),
            actions: { Button("닫기") { lastError = nil } },
            message: { Text(lastError ?? "") }
        )
        .onAppear {
            applySelectedStepToPose()
        }
        .onChange(of: player.pose) { _, newPose in
            stagedPose = newPose
            if sendToHardware {
                Task { await applyToHardware(newPose) }
            }
        }
        // Hidden keyboard shortcuts — TextField focus 시 macOS 가 first responder 처리,
        // 그 외에는 우리의 키프레임 동작. ⌘C/V 같은 표준 단축키 자연 우선순위.
        .background(motionEditShortcuts)
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
                .disabled(copiedStep == nil)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { aiBuilderToast = nil }
            return
        }
        do {
            let pageName = desc.count > 18 ? String(desc.prefix(18)) + "…" : desc
            var page = try MotionBuilder.build(name: pageName, steps: specs)
            // ID 재할당 — 기존 페이지와 충돌 회피.
            let nextId = (motion.pages.map { $0.id }.max() ?? 0) + 1
            page = MotionPage(id: nextId, name: page.name, steps: page.steps)
            motion = MotionDoc(pages: motion.pages + [page])
            selectedPageIdx = motion.pages.count - 1
            selectedStep = 0
            applySelectedStepToPose()
            aiBuilderText = ""
            aiBuilderToast = "✅ \(specs.count) 스텝 추가"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { aiBuilderToast = nil }
        } catch {
            aiBuilderToast = "❌ \(error.localizedDescription)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { aiBuilderToast = nil }
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
                Text("동작 목록 (\(motion.pages.count))")
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
                get: { selectedPageIdx },
                set: { if let v = $0 { selectedPageIdx = v; selectedStep = 0; applySelectedStepToPose() } }
            )) {
                ForEach(grouped, id: \.category) { group in
                    Section {
                        ForEach(group.entries, id: \.idx) { entry in
                            if entry.idx < motion.pages.count {
                                pageListRow(idx: entry.idx, page: motion.pages[entry.idx])
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
            get: { renamingPageIdx.map { RenameTarget(idx: $0) } },
            set: { renamingPageIdx = $0?.idx }
        )) { target in
            renameSheet(target: target)
        }
        // Delete 확인 alert — 실수 방지.
        .alert("이 동작을 삭제할까요?",
               isPresented: Binding(
                get: { deletingPageIdx != nil },
                set: { if !$0 { deletingPageIdx = nil } }
               ),
               presenting: deletingPageIdx
        ) { idx in
            Button("취소", role: .cancel) { deletingPageIdx = nil }
            Button("삭제", role: .destructive) {
                deletePage(at: idx)
                deletingPageIdx = nil
            }
        } message: { idx in
            if idx < motion.pages.count {
                Text("\"\(motion.pages[idx].name)\" 을(를) 영구 삭제합니다.\n저장하지 않으면 동작 doc 만 비워지고 파일에는 영향 없음.")
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
        for (idx, page) in motion.pages.enumerated() {
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
            if hoveredPageIdx == idx {
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
            hoveredPageIdx = hovering ? idx : (hoveredPageIdx == idx ? nil : hoveredPageIdx)
        }
    }

    /// 페이지 context menu — 우클릭 + ⋯ 버튼 양쪽에서 사용.
    @ViewBuilder
    private func pageContextMenu(at idx: Int) -> some View {
        Button {
            renameDraft = motion.pages[safe: idx]?.name ?? ""
            renamingPageIdx = idx
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
            deletingPageIdx = idx
        } label: {
            Label("삭제…", systemImage: "trash")
        }
        .disabled(motion.pages.count <= 1)
    }

    /// 이름 변경 sheet.
    private func renameSheet(target: RenameTarget) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            Text("동작 이름 변경")
                .font(DFFont.title)
            TextField("동작 이름", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(DFFont.body)
                .onSubmit {
                    renamePage(at: target.idx, to: renameDraft)
                    renamingPageIdx = nil
                }
            HStack {
                Spacer()
                Button("취소") { renamingPageIdx = nil }
                Button("저장") {
                    renamePage(at: target.idx, to: renameDraft)
                    renamingPageIdx = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
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
            Picker("동작", selection: $selectedPageIdx) {
                ForEach(Array(motion.pages.enumerated()), id: \.offset) { idx, page in
                    Text(page.name.isEmpty ? "동작 \(page.id)" : page.name).tag(idx)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedPageIdx) { _, _ in
                selectedStep = 0
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
                        get: { selectedStep },
                        set: { selectedStep = $0; applySelectedStepToPose() }
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
            isDirty: isDirty,
            executingOnRobot: executingOnRobot,
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
        executingOnRobot = true
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
            executingOnRobot = false
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
                Text("\(selectedStep + 1) / \(stepCount)")
                    .font(DFFont.bodyEmph.monospacedDigit())
            }

            Divider().frame(height: DFSize.iconMd2)

            // 이동 시간 (playMs) — stepper 인라인 편집.
            keyframeStepperField(
                label: "이동",
                valueMs: page.steps[safe: selectedStep]?.playMs ?? 0,
                range: 0...4096,    // .mtn raw 한계 (255 × 8ms = ~2040ms 권장, 여유로 4096).
                stepMs: 8,           // .mtn raw 단위 (1 raw = 8ms).
                tint: DFColor.accent
            ) { newMs in
                updateSelectedStepTiming(playMs: newMs, pauseMs: nil)
            }

            // 멈춤 시간 (pauseMs) — stepper 인라인 편집.
            keyframeStepperField(
                label: "정지",
                valueMs: page.steps[safe: selectedStep]?.pauseMs ?? 0,
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
                    help: copiedStep == nil
                        ? "먼저 키프레임을 복사하세요"
                        : "복사한 키프레임 붙여넣기 (⌘V)",
                    tint: DFColor.accent,
                    enabled: copiedStep != nil,
                    action: { pasteStep() }
                )
                keyframeIconButton(
                    icon: "scissors",
                    help: "키프레임 쪼개기 (⌘K) — 중간 자세로 두 단계 분할",
                    tint: DFColor.forge,
                    enabled: (page.steps[safe: selectedStep]?.playMs ?? 0) >= 16,
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
        guard selectedPageIdx >= 0, selectedPageIdx < motion.pages.count else { return }
        let stepCount = motion.pages[selectedPageIdx].steps.count
        guard selectedStep >= 0, selectedStep < stepCount else { return }
        var step = motion.pages[selectedPageIdx].steps[selectedStep]
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
        motion.pages[selectedPageIdx].steps[selectedStep] = step
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
        guard selectedPageIdx >= 0, selectedPageIdx < motion.pages.count else { return nil }
        return motion.pages[selectedPageIdx]
    }

    private func startPlayback() {
        guard let page = currentPage else { return }
        player.load(page, from: stagedPose)
        player.play()
    }

    private func applySelectedStepToPose() {
        guard let page = currentPage,
              selectedStep < page.steps.count else { return }
        stagedPose = page.steps[selectedStep].toPose()
    }

    private func saveCurrentStepFromPose() {
        guard var page = currentPage,
              selectedStep < page.steps.count else { return }
        let oldStep = page.steps[selectedStep]
        // 자세만 변경 — pose 의 byte-level 비교로 무의미 변경 skip (undo 폭주 방지).
        let newStep = MotionStep.from(
            pose: stagedPose,
            playMs: oldStep.playMs,
            pauseMs: oldStep.pauseMs
        )
        guard newStep != oldStep else { return }
        pushUndoSnapshot()
        page.steps[selectedStep] = newStep
        motion.pages[selectedPageIdx] = page
        markDirty()
    }

    private func addStepFromCurrentPose() {
        guard var page = currentPage else { return }
        pushUndoSnapshot()
        let step = MotionStep.from(pose: stagedPose, playMs: 256, pauseMs: 0)
        page.steps.append(step)
        motion.pages[selectedPageIdx] = page
        selectedStep = page.steps.count - 1
        markDirty()
    }

    private func removeSelectedStep() {
        guard var page = currentPage, page.steps.count > 1 else { return }
        pushUndoSnapshot()
        page.steps.remove(at: selectedStep)
        if selectedStep >= page.steps.count { selectedStep = page.steps.count - 1 }
        motion.pages[selectedPageIdx] = page
        applySelectedStepToPose()
        markDirty()
    }

    private func addPage() {
        pushUndoSnapshot()
        let nextId = (motion.pages.map { $0.id }.max() ?? 0) + 1
        let newPage = MotionPage(id: nextId, name: "새 동작 \(nextId)",
                                 steps: [.from(pose: .walkReady, playMs: 256, pauseMs: 0)])
        motion.pages.append(newPage)
        selectedPageIdx = motion.pages.count - 1
        selectedStep = 0
        markDirty()
        // v1.12.2 telemetry — 페이지 생성 (name redacted).
        Harness.shared.record(
            .motionPageCreated, level: .info, actor: .user,
            data: ["page_id": AnyCodable(nextId),
                   "name_hash": AnyCodable(Harness.shortHash(newPage.name)),
                   "total_pages": AnyCodable(motion.pages.count)]
        )
    }

    // MARK: - Page management (duplicate / rename / delete / export)

    /// 페이지 복제 — 같은 step 시퀀스, 새 ID, "<name> 복사본" suffix.
    private func duplicatePage(at idx: Int) {
        guard idx >= 0, idx < motion.pages.count else { return }
        pushUndoSnapshot()
        let src = motion.pages[idx]
        let nextId = (motion.pages.map { $0.id }.max() ?? 0) + 1
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
        motion.pages.insert(copy, at: idx + 1)
        selectedPageIdx = idx + 1
        selectedStep = 0
        markDirty()
        applySelectedStepToPose()
    }

    /// 페이지 삭제 — 1 개 미만으로 줄지 않도록 보호.
    private func deletePage(at idx: Int) {
        guard motion.pages.count > 1, idx >= 0, idx < motion.pages.count else { return }
        let removed = motion.pages[idx]
        pushUndoSnapshot()
        motion.pages.remove(at: idx)
        selectedPageIdx = max(0, min(selectedPageIdx, motion.pages.count - 1))
        selectedStep = 0
        markDirty()
        applySelectedStepToPose()
        // v1.12.2 telemetry — 페이지 삭제 (name redacted).
        Harness.shared.record(
            .motionPageDeleted, level: .info, actor: .user,
            data: ["page_id": AnyCodable(removed.id),
                   "name_hash": AnyCodable(Harness.shortHash(removed.name)),
                   "remaining_pages": AnyCodable(motion.pages.count)]
        )
    }

    /// 페이지 이름 변경.
    private func renamePage(at idx: Int, to newName: String) {
        guard idx >= 0, idx < motion.pages.count else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, motion.pages[idx].name != trimmed else { return }
        let oldName = motion.pages[idx].name
        let pageId = motion.pages[idx].id
        pushUndoSnapshot()
        motion.pages[idx].name = trimmed
        markDirty()
        // v1.12.2 telemetry — 페이지 이름 변경 (names redacted to hashes).
        Harness.shared.record(
            .motionPageRenamed, level: .info, actor: .user,
            data: ["page_id": AnyCodable(pageId),
                   "from_hash": AnyCodable(Harness.shortHash(oldName)),
                   "to_hash": AnyCodable(Harness.shortHash(trimmed)),
                   "to_len": AnyCodable(trimmed.count)]
        )
    }

    /// 단일 페이지 .json 으로 내보내기 (NSSavePanel).
    private func exportPage(at idx: Int) {
        guard idx >= 0, idx < motion.pages.count else { return }
        let page = motion.pages[idx]
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "\(page.name.isEmpty ? "motion-\(page.id)" : page.name).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let single = MotionDoc(version: motion.version,
                                    robotGeneration: motion.robotGeneration,
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
            let json = try motion.toJSON(prettyPrinted: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false   // 저장 완료 → clean 상태.
        } catch {
            lastError = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// motion doc 변경 시 dirty flag set — UI 의 저장 버튼 활성화.
    private func markDirty() { isDirty = true }

    // MARK: - Undo / Redo

    /// 모든 mutation 함수 시작에 호출 — 현재 motion 을 undo stack 에 push.
    /// 50 개 초과 시 가장 오래된 항목 drop. redo stack 은 invalidate (새 분기).
    private func pushUndoSnapshot() {
        undoStack.append(motion)
        if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// ⌘Z — 마지막 변경 되돌리기. 변경 없으면 noop.
    private func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(motion)
        motion = prev
        // 인덱스 안전 보정 — pages / steps 가 줄어들 수 있음.
        selectedPageIdx = min(selectedPageIdx, max(0, motion.pages.count - 1))
        if selectedPageIdx >= 0, selectedPageIdx < motion.pages.count {
            selectedStep = min(selectedStep, max(0, motion.pages[selectedPageIdx].steps.count - 1))
        } else {
            selectedStep = 0
        }
        applySelectedStepToPose()
        isDirty = true
    }

    /// ⌘⇧Z — 되돌린 변경을 다시 앞으로.
    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(motion)
        motion = next
        selectedPageIdx = min(selectedPageIdx, max(0, motion.pages.count - 1))
        if selectedPageIdx >= 0, selectedPageIdx < motion.pages.count {
            selectedStep = min(selectedStep, max(0, motion.pages[selectedPageIdx].steps.count - 1))
        } else {
            selectedStep = 0
        }
        applySelectedStepToPose()
        isDirty = true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Copy / Paste / Split (키프레임)

    /// ⌘C — 현재 선택 step 을 클립보드 (in-memory `copiedStep`) 로.
    /// 다른 동작에 paste 가능. 시스템 클립보드 (NSPasteboard) 와는 별개 —
    /// 사용자가 TextField focus 시 ⌘C 는 텍스트 복사가 우선이라 충돌 없음.
    private func copySelectedStep() {
        guard let page = currentPage,
              selectedStep >= 0, selectedStep < page.steps.count else { return }
        copiedStep = page.steps[selectedStep]
    }

    /// ⌘V — 복사된 step 을 현재 위치 *다음에* 삽입. 자동으로 새 step 선택.
    private func pasteStep() {
        guard let step = copiedStep,
              var page = currentPage else { return }
        pushUndoSnapshot()
        let insertAt = min(page.steps.count, max(0, selectedStep + 1))
        page.steps.insert(step, at: insertAt)
        motion.pages[selectedPageIdx] = page
        selectedStep = insertAt
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
              selectedStep >= 0, selectedStep < page.steps.count else { return }
        let original = page.steps[selectedStep]
        // playMs 가 16ms 미만이면 분할 무의미 (8ms × 2 단위).
        guard original.playMs >= 16 else { return }
        pushUndoSnapshot()

        // 이전 자세 — selectedStep > 0 면 이전 step 의 toPose(), 아니면 walkReady.
        let prevPose: RobotPose = selectedStep > 0
            ? page.steps[selectedStep - 1].toPose()
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

        page.steps[selectedStep] = firstHalf
        page.steps.insert(secondHalf, at: selectedStep + 1)
        motion.pages[selectedPageIdx] = page

        // 후반부 (원본 자세) 자동 선택.
        selectedStep += 1
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
                let doc = try MotionDoc.from(json: json)
                self.motion = doc
                self.selectedPageIdx = 0
                self.selectedStep = 0
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

extension MotionStudioView {

    // MARK: - Starter document

    private static func starterDoc() -> MotionDoc {
        return MotionDoc(pages: starterPages())
    }

    /// P0-H: prebundled motion library — 첫 실행 시 사용자가 *바로 실행해 볼* 5 페이지.
    ///
    /// 출처: ROBOTIS RoboPlus Action 기본 모션 (인사/sit/stand/wave 등)을 단순화한 안전판.
    /// 모든 페이지는 walk_ready로 시작해 walk_ready로 종료 → 연속 재생 안전.
    /// `static` 으로 외부 노출해 테스트에서도 검증 가능.
    public static func starterPages() -> [MotionPage] {
        // ── 1. 기본 자세 — 워크랩과 동일 walkReady (ROBOTIS standing posture).
        //    "여기서 시작" 의미. 다른 페이지에서 비상시 복귀할 안전 자세이기도 함.
        // ID 정책: ROBOTIS 공식 1-54 (실 slot 일치), prebundled 200+,
        // ReferenceMotionLibrary 110+ (walk_test=110-115, ergonomic=120-125,
        // greeting=130-134, social=140-143). 모든 ID unique.
        let idle = MotionPage(
            id: 200, name: "기본 자세",
            steps: [.from(pose: .walkReady, playMs: 800, pauseMs: 200)]
        )

        // ── 2. T-자세 — 진단/캘리브레이션 표준.
        let tPose = MotionPage(
            id: 201, name: "T 자세 (진단)",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: .tPose,     playMs: 800, pauseMs: 400),
                .from(pose: .walkReady, playMs: 800, pauseMs: 0)
            ]
        )

        // ── 3. 인사 — 머리 끄덕임으로 부드럽게 표현.
        let bow = MotionPage(
            id: 202, name: "인사",
            steps: [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .headTilt: Kinematics.raw(fromDegrees: 25)
                ]), playMs: 600, pauseMs: 200),
                .from(pose: .walkReady.with([
                    .headTilt: Kinematics.raw(fromDegrees: -10)
                ]), playMs: 600, pauseMs: 0),
                .from(pose: .walkReady, playMs: 400, pauseMs: 0)
            ]
        )

        // ── 4. 손 흔들기 — 우측 팔만, 어깨 충돌 한계 안에서.
        let wave = MotionPage(
            id: 203, name: "손 흔들기",
            steps: [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 90)
                ]), playMs: 500, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 30),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 30)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 90),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 0)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: +120),
                    .rElbow:         Kinematics.raw(fromDegrees: 30),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 30)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady, playMs: 500, pauseMs: 0)
            ]
        )

        // ── 5. 앉기 — walkReady deep squat 에서 추가 굽힘 (CRITIC P2 #3 + PR #8 부호 fix 통합).
        //
        // 종전 버그 (CRITIC 두 건 결합):
        //  1. lKnee +90° 로 좌·우 같은 부호 — ROBOTIS convention 위반 (mirror axis).
        //     PR #8 (negative-joint-mirror-fix) 에서 lKnee 절대 -90° 로 부호 fix 됐고,
        //     본 PR 의 delta -37° 패턴이 walkReady (-53°) 와 합쳐져 동일 결과 (-90°).
        //  2. 절대 -45°/+90° 사용 → walkReady (-36°/+53°/+30°) 에서 절대값으로 보간 시
        //     중간 frame 에서 hip 은 walkReady 보다 -4° 더 굽고 knee 는 walkReady 보다
        //     +18° 더 굽은 비대칭 자세 통과 → hotfix v3 "뒤로 넘어짐" fault mode 와 동일.
        //  3. ankle pitch 가 walkReady 의 +30° 그대로 → knee +90° 굽힘 후 발이 +15° 들림
        //     (foot 절대각 = -45+90-30 = +15°) → CoM 뒤로 → 뒤로 넘어짐.
        //
        // Fix — walkReady-relative delta + 좌·우 mirror + ankle CoM 보정:
        //   hip: +(-9°) 추가 굽힘 / knee: +(+37°) 추가 굽힘 / ankle: +(+15°) 발끝 보정.
        //   foot 절대각 = -45 + 90 - 45 = 0° (수평) — CoM 발 위에 정확히 정렬.
        let sitDeltas: [JointID: Double] = [
            .rHipPitch:   -9,    .lHipPitch:   +9,    // mirror pair
            .rKnee:       +37,   .lKnee:       -37,   // mirror pair (PR #8 의 -90° 와 동일 결과)
            .rAnklePitch: +15,   .lAnklePitch: -15    // CoM 보정 — foot 수평 유지
        ]
        let sit = MotionPage(
            id: 204, name: "앉기",
            steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: Self.deltaFromWalkReady(sitDeltas), playMs: 800, pauseMs: 200),
                .from(pose: .walkReady, playMs: 800, pauseMs: 0)
            ]
        )

        // ── 6+. PoseLibrary 활용 추가 starter 페이지들.
        //     각 페이지: walk_ready → key pose → (좌우 oscillate 추가) → walk_ready.
        let extras = libraryStarterPages()

        // ── 7. 외부 reference (research/community + motions/external) 기반 추가 페이지.
        //     ReferenceMotionLibrary 가 분류별로 분리 — 보행 점진 테스트, ergonomic 케어,
        //     인사·작별, HROS5 소셜 패턴. 라이선스·출처 주석은 해당 파일 참고.
        //     ID 충돌 회피: existing 1..5 + 10..32 = ~32 까지 사용 → 새 페이지는 50+.
        // ID 110+ — ROBOTIS 공식 (1-54) 와 충돌 회피. walk_test 의 startId 110 은
        // motions/test/walk-progression-v1.bin 의 실 slot 110-115 와 일치.
        let walkTest = ReferenceMotionLibrary.walkProgressionPages(startId: 110)
        let ergonomic = ReferenceMotionLibrary.ergonomicPages(startId: 120)
        let greetings = ReferenceMotionLibrary.greetingPages(startId: 130)
        let social = ReferenceMotionLibrary.socialPages(startId: 140)

        // ROBOTIS 공식 motion_4096.bin 의 16 카탈로그 (gui_motion.yaml 기준).
        // ID 1..=54 — ROBOTIS slot 과 일치. 50+ ReferenceMotionLibrary 와 충돌
        // 없음 (공식 ID 1, 2, 3, 4, 9, 10, 11, 12, 13, 15, 17, 23, 24, 27, 38, 54).
        // 실 ROBOTIS raw 송출은 `forge motion play --slot N --bin <path>` 사용.
        let officialCatalog = OfficialCatalogReference.allPages(startId: 1)

        // 2026-05-17 신규 mixamo 스타일 33개 — ID 150-182 (UInt8 안전 범위).
        // 기존: official 1-54, walkProgression 110-115, ergonomic 120-125,
        //       greeting 130-134, social 140-143, basic 200-204, library 220-244.
        // 150-182 충돌 없음. 250+ 시작 시 UInt8 overflow trap.
        let mixamoExtras = mixamoStyleStarterPages(startId: 150)

        // v1.11.2 (2026-05-18): CI Swift 5.9 type-checker timeout 회피 — generic
        // `+` 5단계 concatenation 을 단계별 variable 로 분리. 로컬 5.10 은 inference
        // 가능하지만 CI 옛 toolchain 은 표현식 복잡도 초과 → error.
        let starters: [MotionPage] = [idle, tPose, bow, wave, sit]
        let withExtras = starters + extras
        let withOfficial = withExtras + officialCatalog
        let withWalk = withOfficial + walkTest + ergonomic + greetings + social
        return withWalk + mixamoExtras
    }

    /// `walkReady` 의 현재 raw 값에서 각 관절에 delta(°) 를 더한 새 pose.
    /// `ReferenceMotionLibrary.deltaPose` 와 같은 패턴 — walkReady 가 미래에 갱신돼도 delta 의미 보존.
    /// CRITIC P2 #3 권고로 도입.
    fileprivate static func deltaFromWalkReady(_ deltas: [JointID: Double]) -> RobotPose {
        var dict = RobotPose.walkReady.positions
        for (joint, delta) in deltas {
            let base = RobotPose.walkReady.degrees(joint)
            dict[joint] = Kinematics.raw(fromDegrees: base + delta)
        }
        return RobotPose(positions: dict)
    }

    /// PoseLibrary 기반 starter 동작 생성 — 단일 자세 페이지 + 오실레이션 페이지.
    /// 새 사용자 onboarding 및 모션 예제 제공.
    private static func libraryStarterPages() -> [MotionPage] {
        func single(_ id: UInt8, _ name: String, _ poseId: String,
                    playMs: Int = 800, pauseMs: Int = 200) -> MotionPage {
            guard let p = PoseLibrary.get(poseId) else { return MotionPage(id: id, name: name, steps: []) }
            return MotionPage(id: id, name: name, steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: p.pose, playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ])
        }
        func oscillate(_ id: UInt8, _ name: String,
                       _ a: String, _ b: String, times: Int = 3,
                       stepMs: Int = 250) -> MotionPage {
            guard let pa = PoseLibrary.get(a), let pb = PoseLibrary.get(b) else {
                return MotionPage(id: id, name: name, steps: [])
            }
            var steps: [MotionStep] = [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: pa.pose, playMs: 400, pauseMs: 0)
            ]
            for _ in 0..<times {
                steps.append(.from(pose: pb.pose, playMs: stepMs, pauseMs: 0))
                steps.append(.from(pose: pa.pose, playMs: stepMs, pauseMs: 0))
            }
            steps.append(.from(pose: .walkReady, playMs: 500, pauseMs: 200))
            return MotionPage(id: id, name: name, steps: steps)
        }

        var pages: [MotionPage] = []
        // ID 220+ — ROBOTIS 공식 1-54 + ReferenceMotionLibrary 110-143 +
        // prebundled 200-204 와 충돌 없음.
        var id: UInt8 = 220

        // 인사 — 깊은 인사
        pages.append(single(id, "깊은 인사", "bow_60", playMs: 1000, pauseMs: 400)); id += 1
        // 손 흔들기 — 좌우 oscillate
        pages.append(oscillate(id, "손 흔들기 (3회)", "wave_right", "wave_right_b", times: 3)); id += 1
        // 박수
        pages.append(oscillate(id, "박수 (4회)", "clap_apart", "clap_ready", times: 4, stepMs: 200)); id += 1
        // 만세
        pages.append(single(id, "만세 / 환호", "hands_up", playMs: 700, pauseMs: 500)); id += 1
        // 경례
        pages.append(single(id, "경례", "salute", playMs: 800, pauseMs: 400)); id += 1
        // 악수
        pages.append(single(id, "악수", "handshake", playMs: 700, pauseMs: 500)); id += 1
        // 가리키기 — 정면
        pages.append(single(id, "정면 가리키기", "point_forward")); id += 1
        // 가리키기 — 오른쪽
        pages.append(single(id, "오른쪽 가리키기", "point_right")); id += 1
        // 기도 / 합장
        pages.append(single(id, "합장 자세", "pray", playMs: 900, pauseMs: 600)); id += 1
        // 펀치 — 오른손
        pages.append(single(id, "오른손 펀치", "punch_right", playMs: 400, pauseMs: 100)); id += 1
        // 펀치 좌우 콤보
        pages.append(oscillate(id, "원투 콤보", "punch_left", "punch_right", times: 2, stepMs: 350)); id += 1
        // 복싱 자세
        pages.append(single(id, "복싱 가드", "fighting_stance", playMs: 500, pauseMs: 600)); id += 1
        // 스쿼트 한 번
        pages.append(oscillate(id, "스쿼트 (3회)", "squat_up", "squat_down", times: 3, stepMs: 600)); id += 1
        // 의자에 앉기
        pages.append(single(id, "의자에 앉기", "sit_chair", playMs: 1200, pauseMs: 800)); id += 1
        // 스트레칭 — 양팔
        pages.append(single(id, "양팔 스트레칭", "stretch_arms", playMs: 1000, pauseMs: 800)); id += 1
        // 좌우 보기
        pages.append(oscillate(id, "두리번거리기", "look_left", "look_right", times: 2, stepMs: 600)); id += 1
        // 위 아래 보기
        pages.append(oscillate(id, "고개 끄덕임", "look_up", "look_down", times: 2, stepMs: 400)); id += 1
        // 감정 — 환호
        pages.append(single(id, "환호 표현", "cheer", playMs: 900, pauseMs: 500)); id += 1
        // 감정 — 좌절
        pages.append(single(id, "좌절 표현", "despair", playMs: 1000, pauseMs: 600)); id += 1
        // 감정 — 생각
        pages.append(single(id, "생각하는 자세", "think", playMs: 1000, pauseMs: 800)); id += 1
        // 댄스 A↔B 교대
        pages.append(oscillate(id, "댄스 좌우", "dance_a", "dance_b", times: 3, stepMs: 350)); id += 1
        // 강남 스타일
        pages.append(oscillate(id, "강남 스타일 (말춤)", "gangnam_horse", "walk_ready", times: 4, stepMs: 300)); id += 1
        // 로봇 댄스
        pages.append(oscillate(id, "로봇 댄스", "robot_dance_a", "robot_dance_b", times: 3, stepMs: 400)); id += 1
        // 축구 — 발차기 콤보
        let kickSteps: [MotionStep] = [
            .from(pose: PoseLibrary.get("walk_ready")!.pose, playMs: 300, pauseMs: 0),
            .from(pose: PoseLibrary.get("soccer_kick_right_back")!.pose, playMs: 600, pauseMs: 200),
            .from(pose: PoseLibrary.get("soccer_kick_right_swing")!.pose, playMs: 400, pauseMs: 200),
            .from(pose: PoseLibrary.get("walk_ready")!.pose, playMs: 600, pauseMs: 100)
        ]
        pages.append(MotionPage(id: id, name: "축구 — 오른발 차기", steps: kickSteps)); id += 1
        // 골키퍼 세이브
        pages.append(single(id, "골키퍼 세이브 (우)", "goalkeeper_save_right", playMs: 600, pauseMs: 300)); id += 1
        // 스로인
        pages.append(single(id, "스로인 자세", "throw_in_ready", playMs: 800, pauseMs: 500)); id += 1
        // 요가 — 나무 자세
        pages.append(single(id, "요가 — 나무 자세", "tree_pose", playMs: 1500, pauseMs: 2000)); id += 1
        // 요가 — 전사 자세
        pages.append(single(id, "요가 — 전사 자세", "warrior_pose", playMs: 1500, pauseMs: 2000)); id += 1
        // 요가 — 산 자세
        pages.append(single(id, "요가 — 산 자세", "mountain_pose", playMs: 1200, pauseMs: 1500)); id += 1

        // 2026-05-17 신규 mixamo 스타일 motion 33개 추가 시도 — 후속 commit 에서
        // 진단 후 별도 추가 예정. 본 commit 은 카테고리 그룹핑 UI 만.

        return pages
    }

    /// 2026-05-17 신규: mixamo 스타일 motion 30+ 추가.
    /// libraryStarterPages 와 별도 helper — 진단 용이성 (격리 가능).
    /// 같은 single/oscillate 헬퍼 사용 (guard let nil-safe).
    fileprivate static func mixamoStyleStarterPages(startId: UInt8) -> [MotionPage] {
        func single(_ id: UInt8, _ name: String, _ poseId: String,
                    playMs: Int = 800, pauseMs: Int = 200) -> MotionPage {
            guard let p = PoseLibrary.get(poseId) else {
                // ID 가 PoseLibrary 에 없으면 walk_ready hold 로 fallback — 안전.
                return MotionPage(id: id, name: name, steps: [
                    .from(pose: .walkReady, playMs: 500, pauseMs: 200)
                ])
            }
            return MotionPage(id: id, name: name, steps: [
                .from(pose: .walkReady, playMs: 300, pauseMs: 0),
                .from(pose: p.pose, playMs: playMs, pauseMs: pauseMs),
                .from(pose: .walkReady, playMs: 500, pauseMs: 200)
            ])
        }
        func oscillate(_ id: UInt8, _ name: String,
                       _ a: String, _ b: String, times: Int = 3,
                       stepMs: Int = 250) -> MotionPage {
            guard let pa = PoseLibrary.get(a), let pb = PoseLibrary.get(b) else {
                return MotionPage(id: id, name: name, steps: [
                    .from(pose: .walkReady, playMs: 500, pauseMs: 200)
                ])
            }
            var steps: [MotionStep] = [
                .from(pose: .walkReady, playMs: 200, pauseMs: 0),
                .from(pose: pa.pose, playMs: 400, pauseMs: 0)
            ]
            for _ in 0..<times {
                steps.append(.from(pose: pb.pose, playMs: stepMs, pauseMs: 0))
                steps.append(.from(pose: pa.pose, playMs: stepMs, pauseMs: 0))
            }
            steps.append(.from(pose: .walkReady, playMs: 500, pauseMs: 200))
            return MotionPage(id: id, name: name, steps: steps)
        }

        var pages: [MotionPage] = []
        var id = startId

        // === 인사 변형 (5) ===
        pages.append(single(id, "정중한 인사 (느리게)", "bow_60", playMs: 1500, pauseMs: 800)); id += 1
        pages.append(single(id, "가벼운 인사 (목례)", "nod_target", playMs: 500, pauseMs: 300)); id += 1
        pages.append(single(id, "양손 흔들기", "hands_up", playMs: 600, pauseMs: 200)); id += 1
        pages.append(oscillate(id, "인사 + 박수 환영", "bow_60", "clap_apart", times: 2, stepMs: 400)); id += 1
        pages.append(oscillate(id, "양쪽 손 흔들기 콤보", "wave_left", "wave_right", times: 4, stepMs: 350)); id += 1

        // === 격투 변형 (6) ===
        pages.append(oscillate(id, "잽 — 빠른 펀치 (4회)", "punch_left", "punch_right", times: 4, stepMs: 200)); id += 1
        pages.append(oscillate(id, "원투 콤보 + 가드", "punch_right", "fighting_stance", times: 3, stepMs: 300)); id += 1
        pages.append(oscillate(id, "발차기 좌우 콤보", "kick_forward_right", "kick_forward_left", times: 2, stepMs: 500)); id += 1
        pages.append(single(id, "백 킥 (오른발)", "kick_back_right", playMs: 600, pauseMs: 300)); id += 1
        pages.append(single(id, "복싱 가드 hold", "fighting_stance", playMs: 800, pauseMs: 1000)); id += 1
        pages.append(oscillate(id, "방어 자세 (낮은 가드)", "squat_down", "fighting_stance", times: 2, stepMs: 400)); id += 1

        // === 댄스 변형 (5) ===
        pages.append(oscillate(id, "강남 스타일 (말춤 8회)", "gangnam_horse", "walk_ready", times: 8, stepMs: 280)); id += 1
        pages.append(oscillate(id, "로봇 댄스 (긴 버전)", "robot_dance_a", "robot_dance_b", times: 6, stepMs: 350)); id += 1
        pages.append(oscillate(id, "댄스 피니시 시퀀스", "dance_a", "hands_up", times: 3, stepMs: 350)); id += 1
        pages.append(oscillate(id, "박수 + 가리키기 댄스", "clap_apart", "point_forward", times: 3, stepMs: 300)); id += 1
        pages.append(oscillate(id, "좌우 스텝 댄스", "wave_left", "wave_right", times: 6, stepMs: 250)); id += 1

        // === 감정 / 표현 (6) ===
        pages.append(single(id, "환호 + 만세 콤보", "hands_up", playMs: 600, pauseMs: 800)); id += 1
        pages.append(single(id, "놀람 표현", "surprise", playMs: 500, pauseMs: 400)); id += 1
        pages.append(single(id, "부끄러움 표현", "shy", playMs: 800, pauseMs: 600)); id += 1
        pages.append(oscillate(id, "생각 → 유레카 표현", "think", "hands_up", times: 2, stepMs: 500)); id += 1
        pages.append(oscillate(id, "좌절 시퀀스 (slow)", "despair", "look_down", times: 2, stepMs: 800)); id += 1
        pages.append(oscillate(id, "둘러보기 (orientation)", "look_left", "look_right", times: 3, stepMs: 500)); id += 1

        // === 운동 / 일상 (8) ===
        pages.append(oscillate(id, "스쿼트 (5회)", "squat_up", "squat_down", times: 5, stepMs: 600)); id += 1
        pages.append(single(id, "양팔 위로 스트레칭 hold", "hands_up", playMs: 1000, pauseMs: 1500)); id += 1
        pages.append(single(id, "양팔 옆으로 스트레칭", "stretch_arms", playMs: 1200, pauseMs: 1500)); id += 1
        pages.append(single(id, "의자에 앉기 → 일어서기", "sit_chair", playMs: 1200, pauseMs: 1000)); id += 1
        pages.append(single(id, "런지 (오른쪽)", "lunge_right", playMs: 800, pauseMs: 800)); id += 1
        pages.append(oscillate(id, "방향 가리키기 시퀀스", "point_left", "point_right", times: 2, stepMs: 500)); id += 1
        pages.append(oscillate(id, "응원 (박수 + 환호)", "clap_apart", "cheer", times: 2, stepMs: 400)); id += 1
        pages.append(oscillate(id, "감사 인사 (합장 + 절)", "pray", "bow_60", times: 2, stepMs: 600)); id += 1

        // === 요가 / 밸런스 hold (3) ===
        // 2026-05-17 fix: pauseMs ≤ 2000 (MotionStep.play_time UInt8 = 255 × 8ms = 2040ms 한도).
        pages.append(single(id, "요가 — 나무 자세 hold", "tree_pose", playMs: 1500, pauseMs: 2000)); id += 1
        pages.append(single(id, "요가 — 전사 자세 hold", "warrior_pose", playMs: 1500, pauseMs: 2000)); id += 1
        pages.append(single(id, "요가 — 산 자세 hold", "mountain_pose", playMs: 1200, pauseMs: 2000)); id += 1

        return pages
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
