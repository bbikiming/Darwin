import ForgeCore
import SwiftUI

/// 카메라 미리보기 — ROBOTIS 공식 camera tutorial / demo 의 snapshot endpoint 를 폴링.
public struct PilotCameraView: View {
    let flags: PilotFeatureFlags
    let endpoint: PilotCameraEndpoint
    /// 공 자동 추적 데모 라이프사이클 — HUD overlay 에 모드 상태 표시.
    let demoStatus: PilotDemoStatus
    /// LIVE 상태에서 사용자가 "공 추적 시작/중지" 누를 때 부모에게 요청 — RemotePilotView 가 mode 변경.
    let onRequestMode: ((PilotMode) -> Void)?
    /// Mac 측 head tracking (Sprint 18 Phase D5). 토글 ON 시 detection 마다 head 송출.
    @ObservedObject var headTracker: PilotHeadTracker
    /// HSV preset binding — Phase E. 사용자가 HSV tuning sheet 에서 수정.
    @Binding var hsvPreset: VisionHsvPreset
    /// RemoteShell — HSV tuning sheet 의 로봇 read/write 용.
    @ObservedObject var remoteShell: RemoteShell
    /// 2026-05-16: 종전 `MjpegSnapshotClient` (250ms snapshot 폴링, ~4fps) →
    /// `MjpegStreamingClient` (multipart/x-mixed-replace 실시간 스트림, ~30fps).
    /// 두 클래스 API 동일 — image / phase / framesReceived / detection 등 — 호출처
    /// (PilotCameraView 본문) 코드 변경 0.
    @StateObject private var client = MjpegStreamingClient()
    @State private var showSetupSheet: Bool = false
    @State private var showHeadTrackerSheet: Bool = false
    @State private var showImuSheet: Bool = false
    @State private var showHsvSheet: Bool = false
    /// store 환경 객체 — IMU sheet 에 store 전달용.
    @EnvironmentObject private var store: ConnectionStore

    public init(flags: PilotFeatureFlags,
                endpoint: PilotCameraEndpoint = PilotCameraEndpoint(host: DFConnectionConstants.robotEthernetIP),
                demoStatus: PilotDemoStatus = .idle,
                headTracker: PilotHeadTracker,
                hsvPreset: Binding<VisionHsvPreset>,
                remoteShell: RemoteShell,
                onRequestMode: ((PilotMode) -> Void)? = nil) {
        self.flags = flags
        self.endpoint = endpoint
        self.demoStatus = demoStatus
        self.headTracker = headTracker
        self._hsvPreset = hsvPreset
        self.remoteShell = remoteShell
        self.onRequestMode = onRequestMode
    }

    public var body: some View {
        DFPanel(
            "카메라 (AR HUD)",
            subtitle: panelSubtitle,
            icon: flags.camera ? "video.fill" : "video.slash",
            tint: panelTint,
            trailing: {
                HStack(spacing: DFSpace.xs) {
                    expertMenu
                    DFChip(
                        trailingChipText,
                        icon: trailingChipIcon,
                        style: trailingChipStyle
                    )
                }
            }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .fill(LinearGradient(
                        colors: [DFColor.elev2, DFColor.canvas],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: 0.5)
                    )

                if flags.camera {
                    cameraLiveLayer
                    cameraHudOverlay
                } else {
                    cameraPlaceholderOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 160)
        }
        .onAppear {
            // 2026-05-16: 자동 연결 제거 — 사용자 명시 요청 ("카메라 연결 버튼 누를 때만").
            // client 는 idle 로 유지. hsvPreset 만 동기.
            // 사용자가 cameraWaitingOverlay 의 "카메라 연결" 버튼 클릭 시 configureClient.
            client.hsvPreset = hsvPreset
        }
        .onDisappear { client.stop(resetImage: false) }
        // 2026-05-16: flag / endpoint 변경 시 자동 재연결 제거 — 사용자 명시 시작만.
        // flags.camera OFF 변경 시는 즉시 정지 (안전).
        .onChange(of: flags.camera) { _, newValue in
            if !newValue { client.stop() }
        }
        .onChange(of: endpoint) { _, _ in
            // endpoint 변경 = 진행 중 폴링 무효화. 단 자동 재시작 X — 사용자 재연결 버튼.
            if case .live = client.phase { client.stop() }
        }
        .onChange(of: hsvPreset) { _, newValue in client.hsvPreset = newValue }
        .onChange(of: client.lastDetection) { _, newValue in
            // Phase D5 — 새 detection 마다 head tracker 처리.
            // demo 가 활성이면 자동 skip (HeadTracker 내부 안전 체크).
            headTracker.process(detection: newValue,
                                demoActive: demoStatus == .ballFollowActive)
        }
        .sheet(isPresented: $showSetupSheet) { setupSheet }
        .sheet(isPresented: $showHeadTrackerSheet) {
            PilotHeadTrackerSettingsSheet(tracker: headTracker,
                                          onClose: { showHeadTrackerSheet = false })
        }
        .sheet(isPresented: $showImuSheet) {
            PilotImuRawDiagnosticsSheet(store: store,
                                        onClose: { showImuSheet = false })
        }
        .sheet(isPresented: $showHsvSheet) {
            PilotHsvTuningSheet(preset: $hsvPreset,
                                remoteShell: remoteShell,
                                onClose: { showHsvSheet = false })
        }
    }

    /// 카메라 패널 trailing menu — expert sheet 진입 3개 통합.
    @ViewBuilder
    private var expertMenu: some View {
        if flags.headTracking || flags.imuTelemetry || flags.hsvTuning {
            Menu {
                if flags.headTracking {
                    Button {
                        Harness.shared.record(.pilotCameraSheetOpened, level: .trace, actor: .user,
                                              data: ["sheet": "head_tracker"])
                        showHeadTrackerSheet = true
                    } label: {
                        Label("head 추적 PD 조정", systemImage: "slider.horizontal.below.rectangle")
                    }
                }
                if flags.imuTelemetry {
                    Button {
                        Harness.shared.record(.pilotCameraSheetOpened, level: .trace, actor: .user,
                                              data: ["sheet": "imu"])
                        showImuSheet = true
                    } label: {
                        Label("IMU 진단 + scale 검증", systemImage: "gyroscope")
                    }
                }
                if flags.hsvTuning {
                    Button {
                        Harness.shared.record(.pilotCameraSheetOpened, level: .trace, actor: .user,
                                              data: ["sheet": "hsv"])
                        showHsvSheet = true
                    } label: {
                        Label("HSV 튜닝 + 로봇 동기", systemImage: "eyedropper.halffull")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
            }
            .menuStyle(.borderlessButton)
            .help("Expert 도구 — head PD / IMU 검증 / HSV 튜닝")
        }
    }

    private var panelSubtitle: String {
        guard flags.camera else {
            return "공식 camera_tutorial / demo 필요"
        }
        switch client.phase {
        case .idle:
            return "\(endpoint.displayName) 대기"
        case .connecting:
            return "\(endpoint.displayName) 연결 중"
        case .live:
            return "\(endpoint.displayName) · \(client.framesReceived) frames"
        case .failed(let reason):
            return "\(endpoint.displayName) · \(reason.shortLabel)"
        }
    }

    private var panelTint: Color {
        guard flags.camera else { return PilotColor.comingSoon }
        if case .failed = client.phase { return DFColor.warning }
        if case .live = client.phase { return DFColor.success }
        return DFColor.accent
    }

    /// trailing chip — 카메라 상태를 한 단어로. portClosed 는 행동 유도 위해 별도 라벨.
    private var trailingChipText: String {
        guard flags.camera else { return "셋업 필요" }
        if case .live = client.phase { return "LIVE" }
        if case .failed(let reason) = client.phase { return reason.shortLabel }
        return "연결"
    }

    private var trailingChipIcon: String {
        guard flags.camera else { return "wrench.and.screwdriver.fill" }
        if case .live = client.phase { return "dot.radiowaves.left.and.right" }
        if case .failed = client.phase { return "exclamationmark.triangle.fill" }
        return "antenna.radiowaves.left.and.right"
    }

    private var trailingChipStyle: DFChip.Style {
        guard flags.camera else { return .warning }
        if case .live = client.phase { return .success }
        if case .failed = client.phase { return .warning }
        return .neutral
    }

    /// 현재 phase 가 failed 일 때, 사용자에게 보여줄 친화적 메시지.
    private var failureReason: CameraFailureReason? {
        if case .failed(let reason) = client.phase { return reason }
        return nil
    }

    // MARK: - 카메라 HUD: 모드 뱃지 (현재 ROBOTIS demo 라이프사이클 표시)

    private var modeBadgeText: String? {
        switch demoStatus {
        case .ballFollowActive: return "공 추적 ON"
        case .launching:        return "데모 시작중"
        case .stopping:         return "데모 종료중"
        case .failure:          return "데모 실패"
        case .manualActive, .idle: return nil
        }
    }

    private var modeBadgeIcon: String {
        switch demoStatus {
        case .ballFollowActive: return "target"
        case .launching, .stopping: return "arrow.triangle.2.circlepath"
        case .failure: return "exclamationmark.triangle.fill"
        case .manualActive, .idle: return "circle"
        }
    }

    private var modeBadgeColor: Color {
        switch demoStatus {
        case .ballFollowActive: return DFColor.success
        case .launching, .stopping: return DFColor.warning
        case .failure: return DFColor.danger
        case .manualActive, .idle: return .white
        }
    }

    // MARK: - Phase D5: head tracking toggle (좌하단)

    /// head tracking 활성 토글 — LIVE + flags.headTracking + demo OFF 일 때만 표시.
    /// 누르면 PilotHeadTracker.enabled 토글 + skip 사유 노출.
    private var headTrackingToggle: AnyView? {
        guard flags.headTracking, flags.camera else { return nil }
        guard case .live = client.phase else { return nil }
        // demo 활성 중에는 표시하지 않음 — 충돌 방지.
        if demoStatus == .ballFollowActive || demoStatus == .launching { return nil }

        let on = headTracker.enabled
        let view = Button {
            Harness.shared.record(.pilotCameraHeadTrackingToggle, level: .trace, actor: .user,
                                  data: ["enabled": AnyCodable(!on)])
            headTracker.setEnabled(!on, demoActive: false)
        } label: {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: on ? "eye.fill" : "eye.slash.fill")
                Text(on ? "head 추적 ON" : "head 추적")
                    .font(.system(size: DFFontSize.s10, weight: .bold))
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs2)
            .foregroundStyle(.white)
            .background(on ? DFColor.success.opacity(0.85) : Color.black.opacity(0.55))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(headTracker.lastSkipReason ?? (on ? "공 위치 따라 head pan/tilt 자동" : "Mac PID head tracking 활성"))
        .accessibilityIdentifier("pilot.camera.head-tracking-toggle")
        return AnyView(view)
    }

    // MARK: - Phase D2: multi-color blob overlay

    /// MultiColorVision 결과를 카메라 frame 위에 색깔별 작은 원으로 표시.
    /// 주황 공은 BallVision overlay 와 약간 위치가 다를 수 있음 (forge-core HSV vs Mac HSV).
    @ViewBuilder
    private func multiColorOverlay(in size: CGSize) -> some View {
        ForEach(client.multiColorDetections) { det in
            let px = CGFloat(det.centroidNormalized.x) * size.width
            let py = CGFloat(det.centroidNormalized.y) * size.height
            let radius = max(6, det.approximateRadiusNormalized * min(size.width, size.height))
            let color = Color(det.tag.displayColor)

            ZStack {
                Circle()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .frame(width: radius * 2, height: radius * 2)

                Text(det.tag.label)
                    .font(.system(size: DFFontSize.s8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(color.opacity(0.75))
                    .clipShape(Capsule())
                    .offset(y: -radius - 6)
            }
            .position(x: px, y: py)
            .allowsHitTesting(false)
            .accessibilityIdentifier("pilot.camera.multi-blob-\(det.tag.rawValue)")
        }
    }

    // MARK: - Phase C2: ball detection overlay

    /// 검출된 공 위치를 카메라 frame 위에 원으로 표시.
    /// `BallVision.detect` 가 매 frame 마다 결과 갱신 — 결과 없으면 빈 view.
    @ViewBuilder
    private func ballDetectionOverlay(in size: CGSize) -> some View {
        if let det = client.lastDetection, det.isDetected {
            let px = CGFloat(det.centroidNormalized.x) * size.width
            let py = CGFloat(det.centroidNormalized.y) * size.height
            let radius = max(8, det.approximateRadiusNormalized * min(size.width, size.height))

            ZStack {
                // 외곽 원 — 주황색 (ROBOTIS ball default).
                Circle()
                    .stroke(DFColor.warning, lineWidth: 2)
                    .frame(width: radius * 2, height: radius * 2)
                    .shadow(color: .black.opacity(0.4), radius: 2)

                // 십자선 — centroid 강조.
                Path { path in
                    let r: CGFloat = 6
                    path.move(to: CGPoint(x: -r, y: 0))
                    path.addLine(to: CGPoint(x: r, y: 0))
                    path.move(to: CGPoint(x: 0, y: -r))
                    path.addLine(to: CGPoint(x: 0, y: r))
                }
                .stroke(DFColor.warning, lineWidth: 1.5)
                .frame(width: 12, height: 12)

                // 라벨 — px count 표시 (디버그 + 사용자가 검출 강도 확인).
                Text("ball · \(det.pixelCount)px")
                    .font(.system(size: DFFontSize.s9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .offset(y: radius + 10)
            }
            .position(x: px, y: py)
            .allowsHitTesting(false)
            .accessibilityIdentifier("pilot.camera.ball-blob")
        }
    }

    /// 우하단 단축 토글 — LIVE + closure 주입된 경우 표시.
    /// idle/manualActive → "공 추적 시작" / ballFollowActive → "공 추적 중지" / launching·stopping → 비활성 spinner.
    private var trackingShortcutButton: AnyView? {
        guard onRequestMode != nil, flags.camera else { return nil }
        guard case .live = client.phase else { return nil }

        let (label, icon, target, busy): (String, String, PilotMode?, Bool) = {
            switch demoStatus {
            case .idle, .manualActive, .failure:
                return ("공 추적 시작", "target", .ballFollow, false)
            case .ballFollowActive:
                return ("공 추적 중지", "stop.circle.fill", .manual, false)
            case .launching:
                return ("시작 중", "arrow.triangle.2.circlepath", nil, true)
            case .stopping:
                return ("종료 중", "arrow.triangle.2.circlepath", nil, true)
            }
        }()

        let bg: Color = target == .ballFollow ? DFColor.success.opacity(0.85)
            : (target == .manual ? DFColor.warning.opacity(0.85) : Color.black.opacity(0.55))

        let button = Button {
            if let target { onRequestMode?(target) }
        } label: {
            HStack(spacing: DFSpace.xs) {
                if busy {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: icon)
                }
                Text(label)
                    .font(.system(size: DFFontSize.s10, weight: .bold))
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs2)
            .foregroundStyle(.white)
            .background(bg)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy || target == nil)
        .accessibilityIdentifier("pilot.camera.tracking-toggle")

        return AnyView(button)
    }

    @ViewBuilder
    private var cameraLiveLayer: some View {
        if let image = client.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        } else {
            cameraWaitingOverlay
        }
    }

    @ViewBuilder
    private var cameraWaitingOverlay: some View {
        VStack(spacing: DFSpace.sm) {
            switch client.phase {
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DFFontSize.s32))
                    .foregroundStyle(DFColor.warning)
                Text(failureTitleText(for: reason))
                    .font(DFFont.bodyEmph)
                Text(reason.detailMessage)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DFSpace.md)
                setupActionsRow(reason: reason)
            case .idle:
                // 2026-05-16: 자동 연결 제거 — 사용자 명시 시작.
                Image(systemName: "video.fill")
                    .font(.system(size: DFFontSize.s32))
                    .foregroundStyle(DFColor.textSecondary)
                Text("카메라 연결 대기")
                    .font(DFFont.bodyEmph)
                Text("\(endpoint.displayName) 으로 연결을 시도하려면 아래 버튼을 누르세요")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DFSpace.md)
                Button {
                    Harness.shared.record(.pilotCameraConnect, level: .info, actor: .user,
                                          data: ["endpoint_hash": AnyCodable(Harness.shortHash(endpoint.displayName))])
                    configureClient()
                } label: {
                    Label("카메라 연결", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(DFColor.accent)
                .padding(.top, DFSpace.xs)
            default:
                ProgressView()
                    .controlSize(.small)
                    .tint(DFColor.accent)
                Text("카메라 연결 중")
                    .font(DFFont.bodyEmph)
                Text("로봇에서 공식 camera_tutorial 또는 demo가 8080 포트를 열어야 해요.")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DFSpace.md)
                setupActionsRow(reason: nil)
            }
        }
    }

    /// 실패 사유별로 사용자에게 가장 의미 있는 제목 — "응답 없음" 같은 모호한 문구 회피.
    private func failureTitleText(for reason: CameraFailureReason) -> String {
        switch reason {
        case .portClosed:       return "8080 포트 닫힘"
        case .hostUnreachable:  return "호스트 응답 없음"
        case .timeout:          return "응답 지연"
        case .httpStatus:       return "예상 못한 HTTP 응답"
        case .decodeFailed:     return "JPEG 디코딩 실패"
        case .invalidURL:       return "주소 형식 오류"
        case .other:            return "카메라 오류"
        }
    }

    @ViewBuilder
    private var cameraHudOverlay: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Path { path in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    path.move(to: CGPoint(x: center.x - 18, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + 18, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - 18))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + 18))
                }
                .stroke(DFColor.success.opacity(DFOpacity.o70), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Phase C2 — 주황 공 단일색 (forge-core FFI).
                ballDetectionOverlay(in: size)
                // Phase D2 — 빨강/노랑/파랑/주황 4색 multi-color (Mac HSV).
                multiColorOverlay(in: size)

                VStack {
                    HStack {
                        if case .live = client.phase {
                            Label("LIVE", systemImage: "circle.fill")
                                .font(.system(size: DFFontSize.s10, weight: .bold, design: .monospaced))
                                .foregroundStyle(DFColor.success)
                                .padding(.horizontal, DFSpace.xs2)
                                .padding(.vertical, DFSpace.micro2)
                                .background(.black.opacity(0.45))
                                .clipShape(Capsule())
                        }
                        if let modeBadge = modeBadgeText {
                            Label(modeBadge, systemImage: modeBadgeIcon)
                                .font(.system(size: DFFontSize.s10, weight: .bold, design: .monospaced))
                                .foregroundStyle(modeBadgeColor)
                                .padding(.horizontal, DFSpace.xs2)
                                .padding(.vertical, DFSpace.micro2)
                                .background(.black.opacity(0.45))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(endpoint.displayName)
                            .font(.system(size: DFFontSize.s10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, DFSpace.xs2)
                            .padding(.vertical, DFSpace.micro2)
                            .background(.black.opacity(0.45))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    // 좌하단: head 추적 토글 (Phase D5) + 우하단: 공 추적 단축.
                    HStack {
                        if let headToggle = headTrackingToggle {
                            headToggle
                        }
                        Spacer()
                        if let shortcut = trackingShortcutButton {
                            shortcut
                        }
                    }
                }
                .padding(DFSpace.xs2)
            }
            .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private var cameraPlaceholderOverlay: some View {
        VStack(spacing: DFSpace.sm2) {
            Image(systemName: "video.slash")
                .font(.system(size: DFFontSize.s32, weight: .light))
                .foregroundStyle(DFColor.textSecondary)
            Text("카메라 미연결")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.textSecondary)
            Text("v1.5 에서 활성 — 로봇 측 mjpg-streamer 셋업 필요")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o70))
                .multilineTextAlignment(.center)
                .padding(.horizontal, DFSpace.md)
            setupActionsRow(reason: nil)
        }
    }

    /// 셋업 가이드 / 브라우저 / 원격명령으로 가기 / 연결 마법사로 가기.
    /// reason 이 있으면 reason.suggestedActionLabel 에 맞는 단축 버튼이 추가됨.
    private func setupActionsRow(reason: CameraFailureReason?) -> some View {
        HStack(spacing: DFSpace.xs2) {
            DFButton(.secondary, size: .small) {
                showSetupSheet = true
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "doc.text")
                    Text("셋업 가이드")
                }
            }

            if let actionLabel = reason?.suggestedActionLabel {
                Button {
                    handleSuggestedAction(for: reason)
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: suggestedActionIcon(for: reason))
                        Text(actionLabel)
                    }
                    .font(DFFont.caption.weight(.semibold))
                    .padding(.horizontal, DFSpace.sm)
                    .padding(.vertical, DFSpace.xs2)
                    .background(DFColor.accent.opacity(DFOpacity.o15))
                    .foregroundStyle(DFColor.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pilot.camera.suggested-action")
            }

            if let url = endpoint.pageURL {
                Link(destination: url) {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "safari")
                        Text("브라우저")
                    }
                }
                .buttonStyle(.borderless)
                .font(DFFont.caption)
                .help(url.absoluteString)
            }
        }
    }

    private func suggestedActionIcon(for reason: CameraFailureReason?) -> String {
        switch reason {
        case .portClosed, .timeout, .decodeFailed: return "terminal"
        case .hostUnreachable:                     return "antenna.radiowaves.left.and.right"
        default:                                   return "arrow.right.circle"
        }
    }

    /// reason 별로 가장 적절한 다음 화면으로 이동.
    /// `dfSwitchSection` notification 으로 RootView 가 sidebar section 변경.
    private func handleSuggestedAction(for reason: CameraFailureReason?) {
        guard let reason else { return }
        switch reason {
        case .portClosed, .timeout, .decodeFailed:
            // 사용자가 로봇에서 카메라 데모를 시작해야 함 → 원격 명령 화면.
            NotificationCenter.default.post(name: .dfSwitchSection, object: "remote")
        case .hostUnreachable:
            // 호스트 자체가 응답 없음 → 연결 마법사 (자동 연결/IP 입력).
            NotificationCenter.default.post(name: .dfOpenConnectionWizard, object: nil)
        default:
            break
        }
    }

    @ViewBuilder
    private var setupSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack {
                Image(systemName: "doc.text.fill").foregroundStyle(DFColor.accent)
                Text("로봇 측 카메라 셋업").font(DFFont.title)
                Spacer()
                // 사이클 138 (audit #24 codex sweep)
                Button("닫기", role: .cancel) { showSetupSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            Text("ROBOTIS 공식 camera tutorial은 8080 포트에서 `/?action=snapshot` JPEG를 제공합니다.")
                .font(DFFont.body)
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                Label("원격 명령 → ROBOTIS → ‘카메라 데모 시작’ 한 번 클릭",
                      systemImage: "terminal")
                Label("공식 경로: `/darwin/Linux/project/tutorial/camera` 또는 `~/Framework/Linux/project/tutorial/camera`",
                      systemImage: "folder")
                Label("Mac 미리보기 URL: `http://\(endpoint.displayName)/?action=snapshot`",
                      systemImage: "link")
                Label("공식 자료 기준값: 320×240, Gain 255, Exposure 1000",
                      systemImage: "camera.metering.center.weighted")
            }
            .font(DFFont.body)
            .foregroundStyle(DFColor.textSecondary)

            HStack(spacing: DFSpace.sm) {
                DFButton(.primary, size: .medium) {
                    showSetupSheet = false
                    NotificationCenter.default.post(name: .dfSwitchSection, object: "remote")
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "terminal")
                        Text("원격 명령 화면 열기")
                    }
                }
                DFButton(.secondary, size: .medium) {
                    showSetupSheet = false
                    NotificationCenter.default.post(name: .dfOpenConnectionWizard, object: nil)
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("연결 마법사")
                    }
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(DFSpace.lg)
        .frame(width: 560, height: 360)
    }

    private func configureClient() {
        if flags.camera {
            client.start(endpoint: endpoint)
        } else {
            client.stop()
        }
    }
}
