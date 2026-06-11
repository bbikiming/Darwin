import ForgeCore
import SwiftUI

/// 티칭 모드 — 손으로 잡은 로봇 자세를 실시간 캡처 + 저장.
public struct TeachModeView: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject private var capture = TeachCapture()
    @StateObject private var camera = CameraController()
    @State private var snapshotName: String = ""
    @State private var selectedSnapshot: TeachCapture.PoseSnapshot?
    @State private var showComparison: Bool = false
    @State private var torqueSidebarOpen: Bool = true
    @Environment(\.dfWindowWidth) private var winWidth

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init() {}

    public var body: some View {
        DFPageScaffold(
            "티칭 모드",
            subtitle: "토크 해제 → 손으로 자세 잡기 → 자동 캡처 → 저장",
            icon: "hand.point.up.braille.fill",
            tint: DFColor.info,
            trailing: { headerTrailing }
        ) {
            GeometryReader { geo in
                let isCompact = geo.size.width < 1000
                if isCompact {
                    ScrollView { compactLayout }
                } else {
                    regularLayout
                }
            }
        }
        .onAppear {
            // 사이클 197 (cycle 190 audit P2 #6): cross-menu 재진입 시 navigation telemetry.
            harness.record(.uiViewAppeared, level: .trace, actor: .user,
                                  data: ["view": AnyCodable("teach")])
            if store.bus != nil {
                capture.startCapture(store: store)
            }
        }
        .onDisappear { capture.stopCapture() }
        .onChange(of: store.bus == nil) { _, isNil in
            if isNil { capture.stopCapture() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerTrailing: some View {
        HStack(spacing: DFSpace.sm) {
            if capture.isCapturing {
                DFChip("LIVE \(String(format: "%.0f", capture.readMs))ms",
                       icon: "dot.radiowaves.left.and.right",
                       style: .success, mono: true)
            } else if store.bus == nil {
                DFChip("연결 필요", icon: "exclamationmark.triangle.fill", style: .warning)
            } else {
                DFChip("정지됨", icon: "pause.fill", style: .neutral)
            }
        }
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        HStack(spacing: DFSpace.none) {
            scenePane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            controlPane
                .frame(width: 380)
            Divider()
            TorqueLoadSidebar(isOpen: $torqueSidebarOpen)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: DFSpace.none) {
            scenePane.frame(height: 360)
            Divider()
            controlPane
        }
    }

    // MARK: - Scene (3D 모델)

    private var scenePane: some View {
        ZStack(alignment: .topLeading) {
            RobotScene3D(pose: capture.livePose,
                         footTrace: [],
                         showAxes: true,
                         cameraController: camera,
                         preset: .teach)
                .background(LinearGradient(
                    colors: [DFColor.canvas.opacity(DFOpacity.dim), DFColor.canvas],
                    startPoint: .top, endPoint: .bottom))
            sceneOverlay
                .padding(DFSpace.md)
            ViewportControls(camera: camera)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
        }
    }

    private var sceneOverlay: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            if let at = capture.lastUpdateAt {
                let elapsed = Int(-at.timeIntervalSinceNow * 1000)
                Label("마지막 \(elapsed)ms 전", systemImage: "clock.fill")
                    .font(.system(size: DFFontSize.s10, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
            }
            Text("3D 모델은 실시간 자세를 반영합니다")
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.regularMaterial)
                .clipShape(Capsule())
        }
    }

    // MARK: - Control pane

    private var controlPane: some View {
        ScrollView {
            VStack(spacing: DFSpace.md) {
                if store.bus == nil {
                    notConnectedPanel
                } else {
                    workflowPanel
                    torquePanel
                    snapshotsPanel
                }
            }
            .padding(DFSpace.md)
        }
        .glassScroll(accent: DFColor.success)
        .background(DFColor.canvas)
    }

    // MARK: - Workflow panel — 3 핵심 버튼

    private var workflowPanel: some View {
        DFPanel("워크플로우",
                subtitle: "1. 토크 해제 → 2. 손으로 자세 → 3. 저장",
                icon: "1.circle.fill", tint: DFColor.accent) {
            VStack(spacing: DFSpace.sm) {
                HStack(spacing: DFSpace.sm) {
                    DFButton(.danger, size: .medium,
                             action: { Task { await capture.disableAllTorque(store: store) } }) {
                        Label("토크 해제", systemImage: "lock.open.fill")
                    }
                    DFButton(.success, size: .medium,
                             action: { Task { await capture.enableAllTorque(store: store) } }) {
                        Label("토크 고정", systemImage: "lock.fill")
                    }
                }
                HStack(spacing: DFSpace.sm) {
                    if capture.isCapturing {
                        DFButton(.secondary, size: .medium,
                                 action: { capture.stopCapture() }) {
                            Label("캡처 중지", systemImage: "stop.fill")
                        }
                    } else {
                        DFButton(.primary, size: .medium,
                                 action: { capture.startCapture(store: store) }) {
                            Label("캡처 시작", systemImage: "play.fill")
                        }
                    }
                    DFButton(.ghost, size: .medium,
                             action: { capture.startCapture(store: store) }) {
                        Label("새로고침", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: - Torque panel — 20 관절 grid

    private var torquePanel: some View {
        DFPanel("관절별 토크",
                subtitle: "탭하면 그 관절만 토글",
                icon: "bolt.fill", tint: DFColor.torque) {
            VStack(spacing: DFSpace.xs2) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DFSpace.xs), count: 5),
                          spacing: DFSpace.xs) {
                    ForEach(JointID.allCases, id: \.self) { j in
                        torqueTile(j)
                    }
                }
                let onCount = JointID.allCases.filter { capture.torqueState[$0] == true }.count
                HStack {
                    Text("토크 ON \(onCount)/20")
                        .font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(onCount > 0 ? DFColor.torque : DFColor.textSecondary)
                    Spacer()
                    Text("● live")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(capture.isCapturing ? DFColor.success : DFColor.textSecondary.opacity(DFOpacity.o50))
                }
            }
        }
    }

    private func torqueTile(_ j: JointID) -> some View {
        let on = capture.torqueState[j] ?? false
        return Button {
            capture.toggleTorque(j, store: store)
        } label: {
            VStack(spacing: DFSpace.micro) {
                Text(shortJointName(j))
                    .font(.system(size: DFFontSize.s9, weight: .bold, design: .monospaced))
                    .foregroundStyle(on ? .white : DFColor.textSecondary)
                Text(String(format: "%.0f°", capture.livePose.degrees(j)))
                    .font(.system(size: DFFontSize.s8, design: .monospaced))
                    .foregroundStyle(on ? .white.opacity(0.8) : DFColor.textSecondary.opacity(DFOpacity.o70))
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(on ? DFColor.torque.opacity(DFOpacity.o85) : DFColor.elev2)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(j.koreanLabel) — ID \(j.rawValue) — \(on ? "토크 ON 클릭으로 해제" : "토크 OFF 클릭으로 ON")")
    }

    // MARK: - Snapshots panel

    private var snapshotsPanel: some View {
        DFPanel("자세 저장",
                subtitle: "\(capture.snapshots.count)개",
                icon: "camera.fill", tint: DFColor.forge,
                trailing: {
                    if !capture.snapshots.isEmpty {
                        Button { capture.clearSnapshots() } label: {
                            Image(systemName: "trash")
                                .font(.system(size: DFFontSize.s10))
                                .foregroundStyle(DFColor.danger)
                        }
                        .buttonStyle(.plain)
                        .help("모두 삭제")
                        .accessibilityLabel("스냅샷 모두 삭제")
                    }
                }) {
            VStack(spacing: DFSpace.sm) {
                HStack(spacing: DFSpace.xs2) {
                    TextField("자세 이름 (선택)", text: $snapshotName)
                        .textFieldStyle(.roundedBorder)
                        .font(DFFont.body)
                        .onSubmit { capture.snapshot(name: snapshotName); snapshotName = "" }
                    DFButton(.forge, size: .small,
                             action: {
                                 capture.snapshot(name: snapshotName)
                                 snapshotName = ""
                             }) {
                        Label("스냅샷", systemImage: "camera.fill")
                    }
                }

                if capture.snapshots.isEmpty {
                    VStack(spacing: DFSpace.xs) {
                        Text("저장된 자세 없음 — [스냅샷] 으로 현재 자세 캡처")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                        // 사이클 212: 이전 세션 스냅샷 메타데이터 복원 힌트.
                        if capture.persistedSnapshotCount > 0 {
                            Label("이전 세션에서 \(capture.persistedSnapshotCount)개의 스냅샷이 있었습니다 (재캡처 필요)",
                                  systemImage: "clock.arrow.circlepath")
                                .font(.system(size: DFFontSize.s10))
                                .foregroundStyle(DFColor.info)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: DFSpace.xs) {
                        ForEach(capture.snapshots) { s in
                            snapshotRow(s)
                        }
                    }
                }

                // 사이클 212: PoseDeltaCalculator UI wire-up (cycle 207 model).
                if capture.snapshots.count >= 2 {
                    Divider()
                    poseDeltaSection
                }
            }
        }
    }

    // MARK: - Pose Delta Comparison (사이클 212)

    @ViewBuilder
    private var poseDeltaSection: some View {
        let snaps = capture.snapshots
        if snaps.count >= 2 {
            let cmp = PoseDeltaCalculator.compare(
                baseline: snaps[1].pose,
                candidate: snaps[0].pose,
                baselineLabel: snaps[1].name,
                candidateLabel: snaps[0].name
            )
            DisclosureGroup("자세 비교 — \(snaps[0].name) vs \(snaps[1].name)") {
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    HStack {
                        Text("RMS Δ")
                            .font(DFFont.caption.bold())
                            .foregroundStyle(DFColor.textSecondary)
                        Text(String(format: "%.1f°", cmp.rmsDeg))
                            .font(.system(size: DFFontSize.s13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(cmp.rmsDeg > 10 ? DFColor.warning : DFColor.success)
                    }
                    if let peak = cmp.peakJoint {
                        HStack {
                            Text("최대 편차")
                                .font(DFFont.caption.bold())
                                .foregroundStyle(DFColor.textSecondary)
                            Text("\(peak.jointName) \(String(format: "%+.1f°", peak.deltaDeg))")
                                .font(.system(size: DFFontSize.s11, design: .monospaced))
                                .foregroundStyle(DFColor.accent)
                        }
                    }
                    // top 5 관절 delta bar
                    let sorted = cmp.perJointDeltas.sorted { $0.absDeltaDeg > $1.absDeltaDeg }.prefix(5)
                    ForEach(Array(sorted.enumerated()), id: \.offset) { _, d in
                        HStack(spacing: DFSpace.xs) {
                            Text(d.jointName)
                                .font(.system(size: DFFontSize.s9, design: .monospaced))
                                .frame(width: 70, alignment: .leading)
                            GeometryReader { geo in
                                let maxDeg = cmp.peakJoint?.absDeltaDeg ?? 1
                                let ratio = maxDeg > 0 ? d.absDeltaDeg / maxDeg : 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(d.deltaDeg > 0 ? DFColor.info : DFColor.warning)
                                    .frame(width: geo.size.width * ratio)
                            }
                            .frame(height: 8)
                            Text(String(format: "%+.1f°", d.deltaDeg))
                                .font(.system(size: DFFontSize.s9, design: .monospaced))
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, DFSpace.xs)
            }
            .font(DFFont.caption)
        }
    }

    private func snapshotRow(_ s: TeachCapture.PoseSnapshot) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "figure.stand")
                .foregroundStyle(DFColor.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                Text(s.name).font(DFFont.bodyEmph)
                Text(Self.timeFmt.string(from: s.capturedAt))
                    .font(.system(size: DFFontSize.s9, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            // 사용자 자세 라이브러리에 영구 저장.
            Button {
                UserPoseLibrary.shared.save(name: s.name, pose: s.pose)
                // v1.12.2 telemetry — 사용자 라이브러리 저장 (name redacted).
                harness.record(
                    .poseLibrarySaved, level: .notice, actor: .user,
                    data: ["name_hash": AnyCodable(Harness.shortHash(s.name)),
                           "name_len": AnyCodable(s.name.count),
                           "snapshot_id": AnyCodable(s.id.uuidString),
                           "joint_count": AnyCodable(s.pose.positions.count),
                           "library_size_after": AnyCodable(UserPoseLibrary.shared.entries.count)]
                )
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.forge)
            }
            .buttonStyle(.plain)
            .help("사용자 라이브러리에 영구 저장 — 다른 메뉴에서 활용")
            .accessibilityLabel("사용자 라이브러리에 저장")

            Button {
                NotificationCenter.default.post(
                    name: .dfTransferPoseToStudio, object: s.pose
                )
                NotificationCenter.default.post(
                    name: .dfSwitchSection, object: "studio"
                )
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.accent)
            }
            .buttonStyle(.plain)
            .help("Studio 에서 세부 편집 — 자동으로 스튜디오로 이동")
            .accessibilityLabel("Studio 에서 편집")

            // 사이클 193 (P0 #2): Teach → Motion Studio 자세 전달.
            // V279-2 (P1 discoverability fix): "→ Motion" label 노출 — 아이콘만으로는
            // 자세 snapshot 다음 단계 (Motion Studio 페이지 만들기) 가 안 보임. 사용자
            // mental model: snapshot 찍은 후 "이제 뭐?" 에 대한 명시 진입점.
            Button {
                NotificationCenter.default.post(
                    name: .dfTransferPoseToMotion, object: s.pose
                )
                NotificationCenter.default.post(
                    name: .dfSwitchSection, object: "motion"
                )
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "film.stack")
                        .font(.system(size: DFFontSize.s10))
                    Text("→ Motion")
                        .font(DFFont.micro)
                }
                .foregroundStyle(DFColor.forge)
            }
            .buttonStyle(.plain)
            .help("이 자세를 Motion Studio 의 새 페이지로 추가하고 자동 이동 — " +
                  "여러 자세를 시퀀스로 묶어 동작 동영상처럼 재생할 수 있어요.")
            .accessibilityLabel("Motion Studio 에 페이지로 보내기")

            Button {
                capture.applySnapshot(s, store: store)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.success)
            }
            .buttonStyle(.plain)
            .help("로봇에 적용 — 토크 ON 필요")
            .accessibilityLabel("로봇에 적용")

            Button {
                capture.deleteSnapshot(s)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.plain)
            .help("삭제")
            .accessibilityLabel("스냅샷 삭제")
        }
        .padding(6)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Not connected

    /// 미연결/보행 모드 게이트. 보행 모드면 관절편집 전환 CTA, 오프라인이면 기존 빠른 연결 안내.
    private var notConnectedPanel: some View {
        ConnectionModeBanner(
            offlineTitle: "로봇 연결 필요",
            offlineMessage: "티칭 모드는 실시간 통신이 필요합니다. 우측 상단 [⚡ 빠른 연결] 을 먼저 클릭하세요."
        )
    }

    // MARK: - Helpers

    private func shortJointName(_ j: JointID) -> String {
        switch j {
        case .rShoulderPitch: return "RSh.P"
        case .lShoulderPitch: return "LSh.P"
        case .rShoulderRoll:  return "RSh.R"
        case .lShoulderRoll:  return "LSh.R"
        case .rElbow:         return "RElb"
        case .lElbow:         return "LElb"
        case .rHipYaw:        return "RHip.Y"
        case .lHipYaw:        return "LHip.Y"
        case .rHipRoll:       return "RHip.R"
        case .lHipRoll:       return "LHip.R"
        case .rHipPitch:      return "RHip.P"
        case .lHipPitch:      return "LHip.P"
        case .rKnee:          return "RKnee"
        case .lKnee:          return "LKnee"
        case .rAnklePitch:    return "RAnk.P"
        case .lAnklePitch:    return "LAnk.P"
        case .rAnkleRoll:     return "RAnk.R"
        case .lAnkleRoll:     return "LAnk.R"
        case .headPan:        return "HPan"
        case .headTilt:       return "HTilt"
        }
    }
}
