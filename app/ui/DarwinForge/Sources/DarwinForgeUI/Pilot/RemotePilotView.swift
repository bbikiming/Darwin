import ForgeCore
import SwiftUI

/// Remote Pilot 메인 화면 — ⌘8.
///
/// 레이아웃 (Apple HIG + 반응형):
/// - `wide` (≥1280): 좌 380px 컨트롤 + 우 fill (카메라/3D/HUD)
/// - `regular` (820..1280): 좌 340px + 우 fill
/// - `compact` (<820): 세로 단일 컬럼, 3D 뷰 우선
///
/// 모든 좌측 컨트롤은 ScrollView 로 감싸 작은 윈도우에서도 잘리지 않음.
/// 모든 카드는 `DFPanel` 표준 — Studio/Teach 등 기존 view 와 일관성.
public struct RemotePilotView: View {
    @EnvironmentObject private var store: ConnectionStore
    @StateObject private var gate = PilotSafetyGate()
    @StateObject private var channel = TeleopChannel()

    @State private var mode: PilotMode = .manual
    @State private var speedFraction: Double = 0.5
    @State private var meshFallback: Bool = false

    @Environment(\.dfResponsiveSize) private var responsive

    private let flags: PilotFeatureFlags = .active

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < ResponsiveBreakpoints.compact
            let leftWidth: CGFloat = geo.size.width < 1100 ? 340 : (geo.size.width < 1400 ? 380 : 420)

            ZStack(alignment: .top) {
                Group {
                    if isCompact {
                        compactLayout
                    } else {
                        wideLayout(leftWidth: leftWidth)
                    }
                }
                .padding(DFSpace.md)

                if store.bus == nil {
                    simBanner
                        .padding(.top, DFSpace.sm)
                }
            }
            .overlay(toastOverlay, alignment: .bottom)
        }
        .background(DFColor.canvas)
        .onAppear { channel.attach(store: store, gate: gate) }
        .onReceive(store.$bus.dropFirst()) { _ in
            // 연결/끊김 시 ARM 자동 해제 — 안전.
            channel.disarm()
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func wideLayout(leftWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: DFSpace.md) {
            leftPanel
                .frame(width: leftWidth)

            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        // 좁은 윈도우 — 세로 단일 컬럼. 우선순위: 3D + HUD → ARM → Action Bar → 나머지.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                headerBlock
                robot3DPanel
                    .frame(height: 280)
                hudPanel
                PilotArmSlider(channel: channel, gate: gate)
                PilotActionBar(channel: channel, gate: gate, flags: flags)
                PilotModePicker(mode: $mode, flags: flags)
                PilotSpeedGauge(speedFraction: $speedFraction)
                PilotDpad(channel: channel, gate: gate, flags: flags)
                cameraPanel
            }
        }
    }

    private var leftPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                headerBlock
                PilotArmSlider(channel: channel, gate: gate)
                PilotActionBar(channel: channel, gate: gate, flags: flags)
                PilotModePicker(mode: $mode, flags: flags)
                PilotSpeedGauge(speedFraction: $speedFraction)
                PilotDpad(channel: channel, gate: gate, flags: flags)
            }
            .padding(.bottom, DFSpace.md)
        }
        .frame(maxHeight: .infinity)
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            cameraPanel
                .frame(height: cameraHeight)
            robot3DPanel
                .frame(maxHeight: .infinity)
            hudPanel
        }
    }

    private var cameraHeight: CGFloat {
        switch responsive {
        case .compact: return 200
        case .regular: return 240
        case .wide:    return 280
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(DFColor.accent)
                Text("원격 조종")
                    .font(DFFont.title)
            }
            HStack(spacing: 6) {
                Text("Sprint 15 v1.0")
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(DFColor.accent.opacity(0.12)))
                Text("Action Bar 7 페이지 활성")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 3D 로봇 뷰

    private var robot3DPanel: some View {
        DFPanel(
            "3D 시뮬레이션",
            subtitle: simStatusText,
            icon: "cube.transparent",
            tint: DFColor.success,
            trailing: {
                if let slot = channel.playingSlot, let meta = MotionCatalog.find(slot: slot) {
                    DFChip(meta.displayNameKo, icon: meta.icon, style: .success)
                } else if gate.armed {
                    DFChip("ARM", icon: "lock.open.fill", style: .success)
                } else {
                    DFChip("잠금", icon: "lock.fill", style: .neutral)
                }
            }
        ) {
            ZStack(alignment: .bottomLeading) {
                RobotScene3D(
                    pose: livePose,
                    footTrace: [],
                    highlight: nil,
                    showAxes: true,
                    onMeshFallback: { fallback in meshFallback = fallback }
                )
                .background(
                    LinearGradient(
                        colors: [DFColor.canvas.opacity(0.6), DFColor.canvas],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))

                if meshFallback {
                    meshFallbackBanner
                        .padding(DFSpace.sm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 220)
        }
    }

    /// 현재 화면에 그릴 자세 — 진행 중이면 target, ARM 만 됐으면 walkReady, 아니면 idle.
    private var livePose: RobotPose {
        if let slot = channel.playingSlot,
           let poseID = MotionCatalog.find(slot: slot)?.v1TargetPoseID,
           let pose = PoseLibrary.get(poseID)?.pose {
            return pose
        }
        if gate.armed { return .walkReady }
        return .idle
    }

    private var simStatusText: String {
        if let slot = channel.playingSlot, let meta = MotionCatalog.find(slot: slot) {
            return "재생 중 — \(Int(channel.progress * 100))%  ·  \(meta.rawName)"
        } else if gate.armed {
            return "ARM 완료 — 동작 버튼 대기"
        } else {
            return "DISARM — 우측 슬라이더를 끌어 ARM"
        }
    }

    private var meshFallbackBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: 0) {
                Text("기본 모델 로드 실패")
                    .font(DFFont.bodyEmph)
                Text("단순 형상으로 표시 중 — 빌드의 .stl 메쉬 확인")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .strokeBorder(DFColor.warning.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Camera panel (placeholder v1.0)

    private var cameraPanel: some View {
        PilotCameraView(flags: flags)
    }

    // MARK: - HUD panel

    private var hudPanel: some View {
        PilotHudStrip(store: store, channel: channel, gate: gate, flags: flags)
    }

    // MARK: - Overlays

    private var simBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
            Text("시뮬 모드 — 실 로봇 연결 안 됨. 동작 버튼은 시각 미리보기만.")
                .font(DFFont.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(DFColor.warning)
        .background(.regularMaterial)
        .background(DFColor.warning.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DFColor.warning.opacity(0.35), lineWidth: 0.5))
    }

    @ViewBuilder
    private var toastOverlay: some View {
        VStack(spacing: 6) {
            if let err = channel.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DFColor.warning)
                    Text(err)
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(DFColor.warning)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial)
                .background(DFColor.warning.opacity(0.10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DFColor.warning.opacity(0.45), lineWidth: 0.5))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("pilot.error")
            }
            if let msg = channel.lastToast {
                Text(msg)
                    .font(DFFont.bodyEmph)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(DFColor.accent.opacity(0.35), lineWidth: 0.5))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("pilot.toast")
            }
        }
        .padding(.bottom, DFSpace.lg)
    }
}
