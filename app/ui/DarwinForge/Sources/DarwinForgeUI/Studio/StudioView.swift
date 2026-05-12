import ForgeCore
import SwiftUI

/// 메인 스튜디오 — 3D viewer + body map + pose inspector + 텔레메트리.
///
/// 좌측: BodyMap (관절 빠른 선택, 시각 상태)
/// 중앙: RobotScene3D (실시간 3D 미러)
/// 우측: PoseInspector (16 슬라이더)
/// 하단: TelemetrySparklines (배터리, 평균 온도, 선택 관절)
public struct StudioView: View {
    @EnvironmentObject var store: ConnectionStore

    @State private var pose: RobotPose = .walkReady
    @State private var selectedJoint: JointID? = .headPan
    @State private var liveApply: Bool = false
    @State private var lastError: String?
    @State private var showLiveApplyConfirm: Bool = false
    @State private var hasAcceptedLiveApply: Bool = false

    /// P0-B: 마지막으로 hardware에 발행된 자세. diff 계산에 사용해 *변경된 관절만* 발행.
    /// nil이면 첫 발행 — 16관절 모두 발행 (초기 동기화).
    /// 근거: AUDIT §1 — 슬라이더 한 번 움직임에 16개 모두 발행은 패킷 15개 낭비.
    @State private var lastAppliedPose: RobotPose?

    /// P0-F: STL mesh 로드 실패 시 RobotScene3D가 알려준다.
    @State private var meshFallback: Bool = false

    /// 3D 뷰포트 카메라 컨트롤러 — ViewCube/Home 버튼이 transitionTo 호출.
    @StateObject private var camera = CameraController()

    /// 우측 자세 편집기 열림 여부.
    @State private var inspectorOpen: Bool = true
    /// 우측 자세 편집기 너비 (드래그로 조절).
    @State private var inspectorWidth: CGFloat = 340
    /// 가장 우측 토크 부하 신호등 패널 열림 여부.
    @State private var torqueSidebarOpen: Bool = true

    private let inspectorMinWidth: CGFloat = 260
    private let inspectorMaxWidth: CGFloat = 520

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()
            mainSplit
            Divider()
            telemetryStrip
        }
        .alert(
            "로봇에 보내기 전에 한 번만 확인해주세요",
            isPresented: $showLiveApplyConfirm,
            actions: {
                Button("취소", role: .cancel) {
                    // P0-C: 사용자 미동의 시 toggle 즉시 false. 슬라이더가 발사되지 않게 보장.
                    liveApply = false
                }
                Button("켤게요", role: .destructive) {
                    // P0-C: 동의 *이후*에만 liveApply=true. confirm race 차단.
                    hasAcceptedLiveApply = true
                    liveApply = true
                }
            },
            message: {
                Text("이 토글이 켜지면 슬라이더를 움직일 때마다 실제 로봇이 즉시 따라 움직여요. 주변에 사람이나 물건이 없는지 확인하고, 손으로 받칠 준비가 되면 켜주세요.")
            }
        )
        .alert(
            "로봇에 보내는 중 문제가 생겼어요",
            isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } }),
            actions: { Button("닫기") { lastError = nil } },
            message: { Text(lastError ?? "") }
        )
        // 티칭 모드 → Studio 자세 전달 받음.
        .onReceive(NotificationCenter.default.publisher(for: .dfTransferPoseToStudio)) { note in
            if let p = note.object as? RobotPose {
                pose = p
                lastAppliedPose = p
            }
        }
        // 안전 이벤트 alert — 자세 변경 거부 / 부하 위험 자동 차단.
        .alert(
            "안전 시스템 경고",
            isPresented: Binding(
                get: { store.lastSafetyEvent != nil },
                set: { if !$0 { store.clearSafetyEvent() } }
            ),
            actions: { Button("확인") { store.clearSafetyEvent() } },
            message: { Text(store.lastSafetyEvent ?? "") }
        )
    }

    // MARK: - Top toolbar

    /// 모터 속도 프로파일 picker — Studio 헤더에 표시.
    /// 5단계 (즉시/빠르게/부드럽게/천천히/매우천천히).
    private var motorSpeedPicker: some View {
        Menu {
            ForEach(MotorSpeedProfile.allCases) { p in
                Button {
                    store.motorSpeedProfile = p
                } label: {
                    HStack {
                        Image(systemName: p.icon)
                        VStack(alignment: .leading) {
                            Text(p.koreanLabel)
                            Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        if store.motorSpeedProfile == p {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.motorSpeedProfile.icon)
                    .font(.system(size: 11))
                Text(store.motorSpeedProfile.koreanLabel)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs)
            .background(DFColor.accent.opacity(0.10))
            .foregroundStyle(DFColor.accent)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DFColor.accent.opacity(0.25), lineWidth: DFSize.borderHairline))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("자세 변경 시 모터 이동 속도 — 다수 관절 동시 이동 시 무리 방지")
    }

    private var topToolbar: some View {
        HStack(spacing: DFSpace.md) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.3.group.fill")
                    .foregroundStyle(DFColor.forge)
                Text("스튜디오")
                    .font(DFFont.bodyEmph)
            }

            Spacer()

            // 모터 속도 프로파일 — 자세 변경 시 보간 시간 결정.
            motorSpeedPicker

            ConnectionInlineControls()

            // P0-C: confirm race 차단 — 사용자 동의 *이전에* liveApply를 true로 set하지 않는다.
            // 동의 흐름: toggle off→on → showLiveApplyConfirm=true (liveApply는 그대로 false) →
            //            alert "켤게요" → liveApply=true.
            Toggle(isOn: Binding(
                get: { liveApply },
                set: { newValue in
                    if newValue && !hasAcceptedLiveApply {
                        // 동의 받기 전 — toggle은 시각적으로 off로 유지. alert만 띄움.
                        showLiveApplyConfirm = true
                    } else {
                        liveApply = newValue
                    }
                }
            )) {
                Label("실시간 로봇 반영", systemImage: "bolt.horizontal.circle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(store.bus == nil)
            .help(store.bus == nil
                  ? "USB 연결 후 사용 가능해요"
                  : "켜면 슬라이더를 움직이는 즉시 로봇이 따라 움직여요")

            Button {
                Task { await loadPoseFromRobot() }
            } label: {
                Label("현재 자세 불러오기", systemImage: "square.and.arrow.down.fill")
            }
            .controlSize(.small)
            .disabled(store.bus == nil)
            .help("로봇의 현재 관절 위치를 읽어 화면에 반영합니다 (편집의 시작점)")

            Button {
                Task { await applyToHardware(pose) }
            } label: {
                Label("로봇에 한번에 보내기", systemImage: "play.fill")
            }
            .controlSize(.small)
            .disabled(store.bus == nil)
            .help("지금 화면의 자세를 한 번에 로봇에 보냅니다")
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
        .background(.regularMaterial)
    }

    /// 로봇의 현재 관절 위치(present_position)를 모두 read → pose 에 반영.
    /// 다른 메뉴 (티칭 / 모션) 에서 잡은 자세를 Studio 에서 다듬기 위한 시작점.
    private func loadPoseFromRobot() async {
        guard let bus = store.bus else { return }
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            if let s = try? bus.readState(j) {
                dict[j] = Int(s.presentPosition)
            }
        }
        if !dict.isEmpty {
            pose = RobotPose(positions: dict)
            lastAppliedPose = pose  // diff-write baseline 갱신
        }
    }

    // MARK: - Main split

    private var mainSplit: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 1080
            // 닫혔을 때 좌우 너비를 더 줄임 — 컴팩트에서도 inspector가 너무 넓지 않게.
            let effectiveMaxWidth = min(inspectorMaxWidth, geo.size.width * 0.55)
            HStack(spacing: 0) {
                if !isCompact {
                    leftPanel
                    Divider()
                }
                centerPanel(isCompact: isCompact)

                if inspectorOpen {
                    InspectorSplitter(
                        width: $inspectorWidth,
                        minWidth: inspectorMinWidth,
                        maxWidth: effectiveMaxWidth
                    )
                    inspectorPanel(isCompact: isCompact)
                        .frame(width: inspectorWidth)
                } else {
                    // 닫혔을 때 — 다시 열 수 있는 작은 핸들.
                    inspectorClosedHandle
                }

                // 가장 우측 — 모터 부하 신호등 (열기/닫기).
                Divider()
                TorqueLoadSidebar(isOpen: $torqueSidebarOpen)
            }
        }
    }

    /// 닫혔을 때 우측 가장자리에 보이는 작은 핸들 — 클릭하면 다시 열림.
    private var inspectorClosedHandle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { inspectorOpen = true }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                Text("자세\n편집")
                    .font(DFFont.caption.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Image(systemName: "chevron.left")
                    .font(.system(size: 11))
            }
            .foregroundStyle(DFColor.textPrimary)
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .padding(.vertical, DFSpace.md)
            .background(DFColor.elev2)
            .overlay(
                Rectangle().fill(DFColor.textSecondary.opacity(0.20)).frame(width: 0.5),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
        .help("자세 편집기 열기")
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.bus == nil {
                onboardingPanel
            } else {
                bodyMapPanel
            }
        }
        .frame(width: 220)
        .background(DFColor.elev2)
    }

    @ViewBuilder
    private func centerPanel(isCompact: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RobotScene3D(pose: pose,
                         footTrace: [],
                         highlight: selectedJoint,
                         showAxes: true,
                         onMeshFallback: { fallback in meshFallback = fallback },
                         cameraController: camera)
                .background(LinearGradient(
                    colors: [DFColor.canvas.opacity(0.6), DFColor.canvas],
                    startPoint: .top, endPoint: .bottom))

            viewportBadges
                .padding(DFSpace.md)

            // 공통 ViewportControls — Studio/TeachMode/WalkLab/MotionStudio 모두 동일 UI.
            ViewportControls(camera: camera)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)

            // 컴팩트일 때 onboarding/bodyMap이 가려지므로 좌측 상단에 미니 카드.
            if isCompact && store.bus == nil {
                compactOnboardingHint
                    .padding(DFSpace.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // P0-F: STL mesh 로드 실패 시 좌하단 노란 banner.
            if meshFallback {
                meshFallbackBanner
                    .padding(DFSpace.md)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
            }
        }
        .frame(minWidth: 360)
    }

    /// P0-F: STL 메쉬 로드에 실패해 primitive fallback rig을 쓸 때 표시.
    private var meshFallbackBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: 0) {
                Text("기본 모델 로드 실패")
                    .font(DFFont.bodyEmph)
                Text("단순 형상으로 표시 중 — 빌드의 .stl 메쉬를 확인해 주세요")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .strokeBorder(DFColor.warning.opacity(0.6), lineWidth: 1)
        )
    }

    private func inspectorPanel(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            // 헤더 — 닫기 버튼.
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(DFColor.accent)
                Text("자세 편집기")
                    .font(DFFont.bodyEmph)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { inspectorOpen = false }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DFColor.textSecondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("자세 편집기 닫기")
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm)
            .background(DFColor.elev2)
            Divider()

            PoseInspector(
                pose: $pose,
                selected: $selectedJoint,
                states: store.lastTelemetry?.joints ?? store.jointStates,
                liveApply: liveApply,
                onApplyToHardware: { p in Task { await applyToHardware(p) } }
            )
        }
    }

    private var compactOnboardingHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("USB 연결이 필요해요", systemImage: "cable.connector")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.accent)
            Text("위쪽 \"자동 연결\" 또는 ⌘⇧C")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.sm)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Body map panel (USB 연결 시)

    private var bodyMapPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("관절 위치 한눈에")
                .font(DFFont.bodyEmph)
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.sm)
                .padding(.bottom, DFSpace.xs)
            Text("점을 클릭해 관절을 선택해요")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, DFSpace.md)

            BodyMap2D(pose: pose,
                      states: store.lastTelemetry?.joints ?? store.jointStates,
                      selected: $selectedJoint)
                .withSilhouette()
                .padding(DFSpace.md)
            Spacer()
            if let j = selectedJoint {
                selectedJointSummary(j)
                    .padding(DFSpace.md)
            }
        }
    }

    // MARK: - Onboarding panel (USB 미연결 시 첫 진입)

    private var onboardingPanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("처음이시죠?")
                    .font(DFFont.title)
                Text("3단계만 따라하면 시작할 수 있어요")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.top, DFSpace.md)

            Divider().padding(.horizontal, DFSpace.md)

            onboardingStep(
                num: "1",
                title: "USB 케이블 연결",
                detail: "로봇과 Mac을 USB로 연결한 다음 로봇 전원을 켜주세요.",
                icon: "cable.connector"
            )
            onboardingStep(
                num: "2",
                title: "자동 연결 누르기",
                detail: "위쪽 \"자동 연결\" 버튼 또는 ⌘⇧C 단축키를 사용하세요.",
                icon: "wand.and.stars"
            )
            onboardingStep(
                num: "3",
                title: "슬라이더로 움직이기",
                detail: "오른쪽 자세 편집기에서 관절을 움직이거나, 위쪽 \"로봇에 한번에 보내기\" 버튼을 눌러 적용해요.",
                icon: "slider.horizontal.below.square.filled.and.square"
            )

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Label("⌘K로 명령 팔레트", systemImage: "command")
                    .font(DFFont.caption)
                Label("⌘⇧. 긴급정지", systemImage: "exclamationmark.octagon")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
            }
            .padding(DFSpace.md)
            .background(DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .padding(.horizontal, DFSpace.md)
            .padding(.bottom, DFSpace.md)
        }
    }

    private func onboardingStep(num: String, title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            ZStack {
                Circle()
                    .fill(DFColor.accent.opacity(0.18))
                    .frame(width: 28, height: 28)
                Text(num)
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.accent)
                    Text(title)
                        .font(DFFont.bodyEmph)
                }
                Text(detail)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DFSpace.md)
    }

    // MARK: - Selected joint summary

    private func selectedJointSummary(_ j: JointID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(j.koreanLabel)
                .font(DFFont.bodyEmph)
            Text("\(j.name) (ID \(j.rawValue))")
                .font(DFFont.caption.monospaced())
                .foregroundStyle(DFColor.textSecondary)
            HStack {
                Text("자세").foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text("\(Int(pose.degrees(j)))°")
                    .fontDesign(.monospaced)
            }
            .font(DFFont.caption)
            if let s = store.jointStates[j] {
                HStack {
                    Text("실측").foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    Text("\(Int(Kinematics.degrees(fromRaw: Int(s.presentPosition))))°")
                        .fontDesign(.monospaced)
                }.font(DFFont.caption)
                HStack {
                    Text("온도").foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    Text("\(s.presentTemperature)°C")
                        .foregroundStyle(s.presentTemperature >= 60 ? DFColor.danger : DFColor.textPrimary)
                        .fontDesign(.monospaced)
                }.font(DFFont.caption)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Viewport badges

    private var viewportBadges: some View {
        HStack(spacing: DFSpace.sm) {
            badge("관절 20개", icon: "cube.transparent")
            if liveApply {
                badge("로봇 실시간 반영 중", icon: "dot.radiowaves.left.and.right",
                      tint: DFColor.warning)
            }
        }
    }

    private func badge(_ text: String, icon: String, tint: Color = DFColor.accent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(text).font(DFFont.caption)
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .foregroundStyle(tint)
    }

    // MARK: - Telemetry strip

    private var telemetryStrip: some View {
        // 좁은 화면에서 카드가 잘리지 않도록 가로 스크롤 + lineLimit.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DFSpace.md) {
                TelemetrySparkline(
                    samples: store.voltageHistory,
                    range: 8.0...13.0,
                    label: "배터리",
                    unit: " V",
                    color: DFColor.success,
                    warnThreshold: 9.5
                )
                .frame(width: 220)

                TelemetrySparkline(
                    samples: store.avgTempHistory,
                    range: 20...80,
                    label: "평균 온도",
                    unit: "°C",
                    color: DFColor.info,
                    warnThreshold: 55
                )
                .frame(width: 220)

                if let j = selectedJoint {
                    let series = jointPositionSeries(j)
                    TelemetrySparkline(
                        samples: series,
                        range: 0...4095,
                        label: "\(j.koreanLabel) 실측 위치",
                        unit: "",
                        color: DFColor.accent
                    )
                    .frame(width: 260)
                }
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm)
        }
        .background(DFColor.elev2)
    }

    private func jointPositionSeries(_ j: JointID) -> [Double] {
        // 가장 최근 텔레메트리에서 단발 — 시계열은 추후 보존 시 확장.
        guard let s = store.jointStates[j] else { return [] }
        let v = Double(s.presentPosition)
        return [v, v]  // sparkline는 최소 2개 필요.
    }

    // MARK: - Hardware apply

    /// P0-B: diff 기반 hardware 발행.
    ///
    /// `RobotPose.changedJoints(from: lastAppliedPose)` 가 변경된 관절만 반환 →
    /// 그 중에서만 setPosition. 첫 호출(또는 reset 후)에는 nil 비교 → 16개 모두 발행해
    /// 동기화 baseline을 잡는다.
    ///
    /// 근거: AUDIT §1 — 슬라이더 1개 움직임에 16 패킷은 패킷 15개·~750ms 낭비.
    /// 한 패킷 ~50ms RTT @ 1 Mbaud. (완전 해결은 P1-A Sync_Write FFI에서.)
    /// 자세 적용 — Dynamixel moving_speed 자체 보간 사용 (프로파일 따라 0.5~5초).
    /// 변경된 관절만 추려서 트래픽 절약 + 모터가 자체적으로 부드럽게 이동.
    private func applyToHardware(_ pose: RobotPose) async {
        guard let bus = store.bus else { return }
        let changed = pose.changedJoints(from: lastAppliedPose)
        if changed.isEmpty { return }

        let speed = store.motorSpeedProfile.rawSpeedValue
        // 변경 관절만 추린 sub-pose 로 보간 호출.
        let subPositions = Dictionary(uniqueKeysWithValues:
            changed.map { ($0, pose.raw($0)) }
        )
        do {
            // 1. moving_speed 설정 (변경 관절만).
            for j in changed {
                try bus.setMovingSpeed(j, speed: speed)
            }
            // 2. goal position 전송 — 모터가 자체 보간 이동.
            for j in changed {
                let raw = UInt16(clamping: pose.raw(j))
                _ = try bus.setPosition(j, raw: raw)
            }
            lastAppliedPose = pose
            // 3. instant 가 아니면 예상 도착 시간 대기 (UI feedback).
            if store.motorSpeedProfile != .instant {
                try? await Task.sleep(
                    nanoseconds: UInt64(store.motorSpeedProfile.durationSeconds * 1_000_000_000)
                )
            }
            _ = subPositions  // 사용 안 함 — 트래픽 최소화는 위에서.
        } catch {
            store.handleBusError(error)
            lastError = error.localizedDescription
        }
    }

    // MARK: - External commands (called by RootView via CommandPalette)

    public func mutate(action: CommandAction) {
        switch action {
        case .applyPose(let p):
            pose = p
            if liveApply { Task { await applyToHardware(p) } }
        case .mirrorPose:
            pose = pose.mirrored()
            if liveApply { Task { await applyToHardware(pose) } }
        case .resetPose:
            pose = .walkReady
            if liveApply { Task { await applyToHardware(pose) } }
        case .fillFromTelemetry:
            var dict: [JointID: Int] = [:]
            for j in JointID.allCases {
                if let s = store.jointStates[j] {
                    dict[j] = Int(s.presentPosition)
                }
            }
            if !dict.isEmpty { pose = pose.with(dict) }
        default:
            break
        }
    }

    public var currentPose: RobotPose { pose }
}

// MARK: - InspectorSplitter

/// 자세 편집기 너비를 드래그로 조절하는 세로 핸들.
/// hover 시 좌우 화살표 cursor + 시각 강조.
struct InspectorSplitter: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isHovering: Bool = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            // hit-test 영역 (눈에 안 보이는 8px 두께).
            Rectangle()
                .fill(Color.clear)
                .frame(width: 8)
                .contentShape(Rectangle())

            // 시각 라인 (1px).
            Rectangle()
                .fill(isHovering ? DFColor.accent : DFColor.textSecondary.opacity(0.20))
                .frame(width: isHovering ? 2 : 1)
        }
        .frame(width: 8)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }
                    // 핸들이 좌측으로 이동하면 inspector가 넓어짐.
                    let delta = -value.translation.width
                    let newWidth = (dragStartWidth ?? width) + delta
                    width = max(minWidth, min(maxWidth, newWidth))
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }
}

/// USB / 네트워크 / Bonjour 자동 검색을 모두 지원하는 인라인 연결 컨트롤.
struct ConnectionInlineControls: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject private var bonjour = BonjourBrowser()

    enum Mode: String, CaseIterable, Identifiable {
        case usb, network
        var id: String { rawValue }
        var label: String {
            switch self { case .usb: return "USB"; case .network: return "네트워크" }
        }
    }
    @State private var mode: Mode = .usb

    var body: some View {
        HStack(spacing: 8) {
            // 종류 선택.
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            .controlSize(.small)
            .disabled(isConnected)

            switch mode {
            case .usb:    usbControls
            case .network: networkControls
            }

            connectButton
        }
        .onAppear {
            if store.availablePorts.isEmpty { store.refreshPorts() }
        }
        .onChange(of: mode) { _, new in
            if new == .network { bonjour.start() }
            else { bonjour.stop() }
        }
    }

    // MARK: - USB

    @ViewBuilder
    private var usbControls: some View {
        Picker("", selection: Binding(
            get: { store.selectedPort ?? "" },
            set: { store.selectedPort = $0.isEmpty ? nil : $0 }
        )) {
            if store.availablePorts.isEmpty {
                Text("(USB 없음)").tag("")
            } else {
                ForEach(store.availablePorts, id: \.self) { p in
                    Text(URL(fileURLWithPath: p).lastPathComponent).tag(p)
                }
            }
        }
        .frame(width: 200)
        .controlSize(.small)
        .disabled(isConnected)

        Button {
            store.refreshPorts()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .controlSize(.small)
        .help("USB 포트 새로고침")
        .disabled(isConnected)
    }

    // MARK: - Network

    @ViewBuilder
    private var networkControls: some View {
        TextField("호스트", text: $store.networkHost,
                  prompt: Text("10.0.0.42 또는 op2.local"))
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .controlSize(.small)
            .disabled(isConnected)

        Text(":")
            .foregroundStyle(DFColor.textSecondary)

        TextField("", value: $store.networkPort, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .controlSize(.small)
            .disabled(isConnected)

        // Bonjour 자동 검색 메뉴.
        Menu {
            if bonjour.discovered.isEmpty {
                Text(bonjour.isBrowsing ? "검색 중…" : "발견된 로봇 없음")
                    .foregroundStyle(DFColor.textSecondary)
            } else {
                ForEach(bonjour.discovered) { svc in
                    Button("\(svc.serviceName) — \(svc.host):\(svc.port)") {
                        store.networkHost = svc.host
                        store.networkPort = svc.port
                    }
                }
            }
            Divider()
            Button {
                bonjour.stop(); bonjour.start()
            } label: {
                Label("다시 검색", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: bonjour.discovered.isEmpty ? "antenna.radiowaves.left.and.right.slash"
                                                          : "antenna.radiowaves.left.and.right")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32)
        .controlSize(.small)
        .help(bonjour.discovered.isEmpty
              ? "Bonjour 자동 검색 (같은 네트워크의 forge serve)"
              : "\(bonjour.discovered.count)개 로봇 발견됨 — 클릭으로 선택")
        .disabled(isConnected)
    }

    // MARK: - Connect / Disconnect

    @ViewBuilder
    private var connectButton: some View {
        if isConnected {
            Button {
                store.disconnect()
            } label: {
                Label("끊기", systemImage: "xmark.circle")
            }
            .controlSize(.small)
        } else {
            Button {
                switch mode {
                case .usb:    store.autoConnect()
                case .network: store.connectNetwork()
                }
            } label: {
                Label(connectLabel, systemImage: connectIcon)
            }
            .controlSize(.small)
            .buttonStyle(.glassNeon(tint: DFColor.forge))
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var connectLabel: String {
        switch mode {
        case .usb:    return "자동 연결"
        case .network: return "TCP 연결"
        }
    }

    private var connectIcon: String {
        switch mode {
        case .usb:    return "cable.connector"
        case .network: return "network"
        }
    }

    private var isConnected: Bool {
        if case .connected = store.status { return true } else { return false }
    }
}
