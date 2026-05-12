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

            List(selection: Binding(
                get: { selectedPageIdx },
                set: { if let v = $0 { selectedPageIdx = v; selectedStep = 0; applySelectedStepToPose() } }
            )) {
                ForEach(Array(motion.pages.enumerated()), id: \.offset) { idx, page in
                    HStack {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(DFColor.accent)
                        VStack(alignment: .leading, spacing: DFSpace.micro2) {
                            Text(page.name.isEmpty ? "동작 \(page.id)" : page.name)
                                .font(DFFont.body)
                            Text("\(page.steps.count)단계 · \(formatSeconds(page.totalDurationMs))")
                                .font(DFFont.caption)
                                .foregroundStyle(DFColor.textSecondary)
                        }
                    }
                    .tag(idx)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 220)
        .background(DFColor.elev2)
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
                pageMetaBadge
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
            onPlay: { startPlayback() },
            onAddStep: { addStepFromCurrentPose() },
            onCapture: { captureFromTelemetry() }
        )
    }

    private func stepDetailRow(page: MotionPage) -> some View {
        let step = (selectedStep < page.steps.count) ? page.steps[selectedStep] : nil
        return HStack(spacing: DFSpace.md) {
            Text("\(selectedStep + 1) / \(page.steps.count)단계")
                .font(DFFont.bodyEmph)
            if let step {
                HStack(spacing: DFSpace.xs) {
                    Text("이동 시간").foregroundStyle(DFColor.textSecondary)
                    Text("\(step.playMs)ms").fontDesign(.monospaced)
                }
                HStack(spacing: DFSpace.xs) {
                    Text("멈춤 시간").foregroundStyle(DFColor.textSecondary)
                    Text("\(step.pauseMs)ms").fontDesign(.monospaced)
                }
            }
            Spacer()
            Button(role: .destructive) {
                removeSelectedStep()
            } label: {
                Label("이 단계 삭제", systemImage: "trash")
            }
            .controlSize(.small)
            .disabled((currentPage?.steps.count ?? 0) <= 1)
            .help("동작에는 최소 한 단계가 있어야 해요")
        }
        .font(DFFont.caption)
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
        page.steps[selectedStep] = MotionStep.from(
            pose: stagedPose,
            playMs: oldStep.playMs,
            pauseMs: oldStep.pauseMs
        )
        motion.pages[selectedPageIdx] = page
    }

    private func addStepFromCurrentPose() {
        guard var page = currentPage else { return }
        let step = MotionStep.from(pose: stagedPose, playMs: 256, pauseMs: 0)
        page.steps.append(step)
        motion.pages[selectedPageIdx] = page
        selectedStep = page.steps.count - 1
    }

    private func removeSelectedStep() {
        guard var page = currentPage, page.steps.count > 1 else { return }
        page.steps.remove(at: selectedStep)
        if selectedStep >= page.steps.count { selectedStep = page.steps.count - 1 }
        motion.pages[selectedPageIdx] = page
        applySelectedStepToPose()
    }

    private func addPage() {
        let nextId = (motion.pages.map { $0.id }.max() ?? 0) + 1
        let newPage = MotionPage(id: nextId, name: "새 동작 \(nextId)",
                                 steps: [.from(pose: .walkReady, playMs: 256, pauseMs: 0)])
        motion.pages.append(newPage)
        selectedPageIdx = motion.pages.count - 1
        selectedStep = 0
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
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
                    .rElbow:         Kinematics.raw(fromDegrees: 90)
                ]), playMs: 500, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
                    .rElbow:         Kinematics.raw(fromDegrees: 30),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 30)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
                    .rElbow:         Kinematics.raw(fromDegrees: 90),
                    .rShoulderRoll:  Kinematics.raw(fromDegrees: 0)
                ]), playMs: 250, pauseMs: 0),
                .from(pose: .walkReady.with([
                    .rShoulderPitch: Kinematics.raw(fromDegrees: -120),
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

        return [idle, tPose, bow, wave, sit] + extras
             + officialCatalog
             + walkTest + ergonomic + greetings + social
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
