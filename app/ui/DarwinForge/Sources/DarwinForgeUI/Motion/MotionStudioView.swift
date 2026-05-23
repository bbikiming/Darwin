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
    /// 사이클 258 (W4.3.5) — AI 빌더 입력 (aiBuilderText / aiBuilderToast) 은
    /// `MotionStudioSidebar` 의 view-local @State 로 이동. 사이드바 전용이므로
    /// owner 가 보유할 필요 없음.
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
                    MotionStudioSidebar(
                        doc: doc,
                        onAddPage: { addPage() },
                        onImportMotionPanel: { importMotionPanel() },
                        onApplySelectedStepToPose: { applySelectedStepToPose() },
                        onDuplicatePage: { duplicatePage(at: $0) },
                        onExportPage: { exportPage(at: $0) },
                        onSaveDocAs: { saveDocAs() },
                        onRenamePage: { renamePage(at: $0, to: $1) },
                        onDeletePage: { deletePage(at: $0) }
                    )
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
                    MotionStudioInspector(
                        pose: $stagedPose,
                        selected: $inspectorJoint,
                        isOpen: $rightOpen,
                        states: store.lastTelemetry?.joints ?? store.jointStates,
                        liveApply: sendToHardware,
                        onPoseEdit: { newPose in
                            stagedPose = newPose
                            saveCurrentStepFromPose()
                            if sendToHardware { Task { await applyToHardware(newPose) } }
                        },
                        onApplyToHardware: { p in Task { await applyToHardware(p) } }
                    )
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

    /// 사이클 257 (W4.3.4): Synth import 위임 + pose refresh + lastError 매핑.
    /// 데이터 변환 / mutation 은 `MotionImportActions`, view-state (pose / lastError) 는 잔류.
    private func importSynthPages(_ pages: [MotionPage]) {
        let result = MotionImportActions.importSynthPages(pages, in: doc)
        switch result {
        case .success(let payload):
            // payload == nil 이면 빈 배열 입력 (no-op) — pose refresh 불필요.
            guard payload != nil else { return }
            applySelectedStepToPose()
        case .failure(let err):
            // 사이클 187: overflow 시 사용자 알림. motion 무변화.
            lastError = SynthMotionExporter.koreanMessage(for: err)
        }
    }

    /// 사이클 257 (W4.3.4): Teach 자세 import 위임 + pose refresh + toast + telemetry.
    /// 데이터 변환 / mutation 은 `MotionImportActions`, side-effect (toast / telemetry) 는 잔류.
    private func importPoseAsMotionPage(_ pose: RobotPose) {
        let result = MotionImportActions.importPoseAsMotionPage(pose, in: doc)
        switch result {
        case .success(let payload):
            applySelectedStepToPose()
            transferToast = "✅ Motion 페이지 추가됨"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                transferToast = nil
            }
            // 사이클 203 (cycle 199 critic missing #3): Teach → Motion transfer telemetry.
            // motionPageCreated 패턴 일관 (cycle 191 audit 의 recommended) — 신규 페이지
            // ID + source 만 (pose 좌표 X — PII 회피).
            harness.record(
                .motionPageCreated, level: .info, actor: .user,
                data: ["new_id": AnyCodable(Int(payload.firstAddedId)),
                       "source": AnyCodable("teach_transfer")]
            )
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
    //
    // 사이클 258 (W4.3.5) — AI 빌더 패널 / runAIBuilder 는 `MotionStudioSidebar`
    // 로 이동. 사이드바 전용 위젯이므로 owner 책임 분리.

    // MARK: - Sidebar (pages)
    //
    // 사이클 258 (W4.3.5) — sidebar / CategoryGroup / groupedPagesByCategory /
    // pageListRow / pageContextMenu / renameSheet 모두 `MotionStudioSidebar`
    // 로 이동. View 가 1251 줄 god view 였던 문제 해소.
    // formatSeconds 도 sidebar 내부 helper 로 이동 (compact picker 는 미사용).

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
            MotionStudioCanvas(
                pose: stagedPose,
                highlightJoint: inspectorJoint,
                camera: camera,
                sourceMode: currentSourceMode,
                currentPage: currentPage
            )

            Divider()

            MotionStudioTimeline(
                doc: doc,
                player: player,
                sendToHardware: $sendToHardware,
                currentPage: currentPage,
                hasBus: store.bus != nil,
                canUndo: canUndo,
                canRedo: canRedo,
                onPlay: { startPlayback() },
                onAddStep: { addStepFromCurrentPose() },
                onCapture: { captureFromTelemetry() },
                onRunOnRobot: { runCurrentPageOnRobot() },
                onSave: { saveDocAs() },
                onUndo: { undo() },
                onRedo: { redo() },
                onApplySelectedStepToPose: { applySelectedStepToPose() },
                onCopySelectedStep: { copySelectedStep() },
                onPasteStep: { pasteStep() },
                onSplitSelectedStep: { splitSelectedStep() },
                onRemoveSelectedStep: { removeSelectedStep() }
            )
            .padding(DFSpace.md)
            .background(DFColor.card)
        }
    }

    /// 3D 뷰포트의 데이터 출처 — 4가지 상태로 사용자가 자기 행동의 효과를 정확히 인지.
    ///
    /// **사이클 259 (W4.3.6)**: enum 정의는 `MotionStudioCanvas.SourceMode` 로
    /// 이동. owner 는 다중 의존성 (sendToHardware / store.bus / player.mode) 을
    /// 종합해 enum 값만 계산해 전달.
    ///
    /// **Codex pass 1 [P2]**: 이전엔 정지/일시정지 + sendToHardware ON 케이스가
    /// `.editing` 으로 떨어져 "로봇은 움직이지 않아요" 라고 거짓말함. 실제로는 인스펙터
    /// 슬라이더가 매번 `applyToHardware` 를 호출하여 로봇이 움직임. 새 `.liveEditing`
    /// 케이스로 명시.
    private var currentSourceMode: MotionStudioCanvas.SourceMode {
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

    // 사이클 259 (W4.3.6) — `timelineSection` / `transportRow` 는
    // `MotionStudioTimeline` 으로 이동. centerColumn 에서 직접 호출.

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

    // 사이클 259 (W4.3.6) — `stepDetailRow` / `keyframeStepperField` /
    // `keyframeIconButton` / `updateSelectedStepTiming` 는 `MotionStudioTimeline`
    // 으로 이동 (키프레임 편집 cluster 와 결속된 view-private helper).

    // MARK: - Right (inspector)
    //
    // 사이클 258 (W4.3.5) — rightColumn 컴퓨티드 프로퍼티는 `MotionStudioInspector`
    // 로 이동. closed handle 만 view 잔류 (sidebar 접힘 토글 UI).

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

    /// 사이클 256 (W4.3.3): 자세 → 현재 step mutation 위임.
    /// stagedPose 만 view-state, mutation 로직은 `MotionPageActions`.
    private func saveCurrentStepFromPose() {
        MotionPageActions.saveCurrentStepFromPose(stagedPose, in: doc)
    }

    /// 사이클 256 (W4.3.3): 자세 → 새 step append 위임.
    private func addStepFromCurrentPose() {
        MotionPageActions.addStepFromPose(stagedPose, in: doc)
    }

    /// 사이클 256 (W4.3.3): 선택 step 삭제 + pose refresh.
    /// applySelectedStepToPose 는 view-state (stagedPose) 갱신이므로 호출 사이트 책임.
    private func removeSelectedStep() {
        MotionPageActions.removeSelectedStep(in: doc)
        applySelectedStepToPose()
    }

    /// 사이클 256 (W4.3.3): 새 페이지 추가 + telemetry emit.
    /// MotionPageActions 가 nextId 반환 → 동일한 telemetry payload 보장.
    private func addPage() {
        let beforeCount = doc.motion.pages.count
        let nextId = MotionPageActions.addPage(in: doc)
        // 새 페이지 name 은 "새 동작 \(nextId)" — MotionPageActions 와 동일 패턴.
        let newPageName = "새 동작 \(nextId)"
        // v1.12.2 telemetry — 페이지 생성 (name redacted).
        harness.record(
            .motionPageCreated, level: .info, actor: .user,
            data: ["page_id": AnyCodable(nextId),
                   "name_hash": AnyCodable(Harness.shortHash(newPageName)),
                   "total_pages": AnyCodable(beforeCount + 1)]
        )
    }

    // MARK: - Page management (duplicate / rename / delete / export)

    /// 사이클 256 (W4.3.3): 페이지 복제 + pose refresh.
    private func duplicatePage(at idx: Int) {
        MotionPageActions.duplicatePage(at: idx, in: doc)
        applySelectedStepToPose()
    }

    /// 사이클 256 (W4.3.3): 페이지 삭제 + pose refresh + telemetry emit.
    private func deletePage(at idx: Int) {
        guard let removed = MotionPageActions.deletePage(at: idx, in: doc) else { return }
        applySelectedStepToPose()
        // v1.12.2 telemetry — 페이지 삭제 (name redacted).
        harness.record(
            .motionPageDeleted, level: .info, actor: .user,
            data: ["page_id": AnyCodable(removed.id),
                   "name_hash": AnyCodable(Harness.shortHash(removed.name)),
                   "remaining_pages": AnyCodable(doc.motion.pages.count)]
        )
    }

    /// 사이클 256 (W4.3.3): 페이지 rename + telemetry emit.
    private func renamePage(at idx: Int, to newName: String) {
        guard let result = MotionPageActions.renamePage(at: idx, to: newName, in: doc) else { return }
        // v1.12.2 telemetry — 페이지 이름 변경 (names redacted to hashes).
        harness.record(
            .motionPageRenamed, level: .info, actor: .user,
            data: ["page_id": AnyCodable(result.pageId),
                   "from_hash": AnyCodable(Harness.shortHash(result.oldName)),
                   "to_hash": AnyCodable(Harness.shortHash(result.newName)),
                   "to_len": AnyCodable(result.newName.count)]
        )
    }

    /// 사이클 256 (W4.3.3): 단일 페이지 .json export (NSSavePanel + write).
    /// 데이터 변환은 MotionPageActions, file dialog 만 view 잔류.
    private func exportPage(at idx: Int) {
        guard idx >= 0, idx < doc.motion.pages.count else { return }
        let page = doc.motion.pages[idx]
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "\(page.name.isEmpty ? "motion-\(page.id)" : page.name).json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try MotionPageActions.exportPageJSON(at: idx, in: doc)
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "내보내기 실패: \(error.localizedDescription)"
        }
    }

    /// 사이클 256 (W4.3.3): 전체 motion doc → JSON 저장 (NSSavePanel + write).
    /// 성공 시 isDirty = false (clean 상태).
    private func saveDocAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "motion-doc.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let json = try MotionPageActions.documentJSON(of: doc)
            try json.write(to: url, atomically: true, encoding: .utf8)
            doc.isDirty = false   // 저장 완료 → clean 상태.
        } catch {
            lastError = "저장 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Undo / Redo

    /// 사이클 256 (W4.3.3): undo + pose refresh.
    private func undo() {
        guard MotionPageActions.undo(in: doc) else { return }
        applySelectedStepToPose()
    }

    /// 사이클 256 (W4.3.3): redo + pose refresh.
    private func redo() {
        guard MotionPageActions.redo(in: doc) else { return }
        applySelectedStepToPose()
    }

    var canUndo: Bool { !doc.undoStack.isEmpty }
    var canRedo: Bool { !doc.redoStack.isEmpty }

    // MARK: - Copy / Paste / Split (키프레임)

    /// 사이클 256 (W4.3.3): copy 위임.
    private func copySelectedStep() {
        MotionPageActions.copySelectedStep(in: doc)
    }

    /// 사이클 256 (W4.3.3): paste + pose refresh.
    private func pasteStep() {
        MotionPageActions.pasteStep(in: doc)
        applySelectedStepToPose()
    }

    /// 사이클 256 (W4.3.3): split + pose refresh.
    private func splitSelectedStep() {
        MotionPageActions.splitSelectedStep(in: doc)
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

    /// 사이클 257 (W4.3.4): .mtn 파일 import 위임 + pose refresh + lastError 매핑.
    /// NSOpenPanel + 파일 read 는 view 잔류 (UI 책임), 데이터 변환은 `MotionImportActions`.
    private func importMotionPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let mtn = try String(contentsOf: url, encoding: .utf8)
                try MotionImportActions.importMotionFromMTN(mtn, in: doc)
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
    //
    // 사이클 258 (W4.3.5) — RenameTarget 은 MotionStudioSidebar 로 이동
    // (사이드바 전용 sheet item).
}

// 사이클 259 (W4.3.6) — Array safe subscript 는 stepDetailRow 전용
// helper 였으므로 `MotionStudioTimeline` 으로 동반 이동 (fileprivate).

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
