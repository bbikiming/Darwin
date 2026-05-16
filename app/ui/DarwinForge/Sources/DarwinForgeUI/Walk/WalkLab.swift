import ForgeCore
import SwiftUI

/// Webots 스타일 워크 시각화 — 3D 미러 + 좌측 발 trail + phase + 명령 슬라이더.
/// `로봇에 보내기` 토글이 켜지면 매 tick 다리 6 joint 명령을 실 로봇에 전송.
public struct WalkLab: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var x: Double = 0.0
    @State private var y: Double = 0.0
    @State private var a: Double = 0.0
    @State private var enabled: Bool = false
    @State private var trace: [SIMD3<Double>] = []
    @State private var rightTrace: [SIMD3<Double>] = []
    @State private var lastSample: FootTargets?
    @State private var engine = WalkEngine()
    @State private var timer: Timer?
    /// `로봇에 보내기` — 현재 walk pose를 매 tick 실기에 적용.
    @State private var sendToHardware: Bool = false
    @State private var torqueSidebarOpen: Bool = true
    @StateObject private var camera = CameraController()

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 920
            if isCompact {
                // 좁은 화면 — control panel을 ScrollView에 + 시각화는 위에 고정 비율.
                VStack(spacing: DFSpace.none) {
                    ZStack(alignment: .topTrailing) {
                        RobotScene3D(pose: .walkReady, footTrace: trace,
                                     showAxes: true, cameraController: camera)
                            .background(LinearGradient(
                                colors: [DFColor.canvas.opacity(DFOpacity.dim), DFColor.canvas],
                                startPoint: .top, endPoint: .bottom))
                        phaseBadge.padding(DFSpace.md)
                        ViewportControls(camera: camera)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topTrailing)
                    }
                    .frame(height: max(220, geo.size.height * 0.4))
                    Divider()
                    ScrollView { controlPanel.frame(maxWidth: .infinity) }
                        .frame(maxHeight: .infinity)
                }
                .onDisappear { stop() }
            } else {
                HStack(spacing: DFSpace.none) {
                    controlPanel
                    Divider()
                    ZStack(alignment: .topTrailing) {
                        RobotScene3D(pose: .walkReady, footTrace: trace,
                                     showAxes: true, cameraController: camera)
                            .background(LinearGradient(
                                colors: [DFColor.canvas.opacity(DFOpacity.dim), DFColor.canvas],
                                startPoint: .top, endPoint: .bottom))
                        phaseBadge.padding(DFSpace.md)
                        ViewportControls(camera: camera)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topTrailing)
                    }
                    Divider()
                    TorqueLoadSidebar(isOpen: $torqueSidebarOpen)
                }
                .onDisappear { stop() }
            }
        }
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            Text("걷기 실험실")
                .font(DFFont.title)
            Text("걸음 폭과 회전을 바꿔 발이 어떻게 움직이는지 미리 봐요. 아래 토글을 켜면 실제 로봇에도 적용됩니다.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)

            Toggle(isOn: $sendToHardware) {
                Label(sendToHardware ? "로봇에 적용 중" : "로봇에 적용",
                      systemImage: sendToHardware ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(sendToHardware ? DFColor.warning : DFColor.textSecondary)
            }
            .toggleStyle(.switch)
            .disabled(store.bus == nil)
            .help(store.bus == nil
                  ? "로봇 연결 후 사용 가능"
                  : "켜면 매 50ms마다 다리 6관절 명령이 실 로봇에 전송됩니다 — 안전한 환경에서만 사용")

            GroupBox("걸음 설정") {
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    sliderRow("앞뒤 한 걸음", value: $x, range: -0.04...0.04, step: 0.005, format: "%+.0f mm",
                              displayMultiplier: 1000)
                    sliderRow("옆 한 걸음", value: $y, range: -0.03...0.03, step: 0.005, format: "%+.0f mm",
                              displayMultiplier: 1000)
                    sliderRow("회전 한 걸음", value: $a, range: -0.3...0.3, step: 0.01, format: "%+.0f°",
                              displayMultiplier: 180.0 / Double.pi)
                    Toggle("걷기 시작", isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            enabled = newValue
                            engine.setCommand(x: x, y: y, a: a, enabled: newValue)
                            if newValue { start() } else { stop() }
                        }
                    ))
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("앞으로 빠르게") {
                    x = 0.04; y = 0; a = 0
                    enabled = true
                    engine.setCommand(x: x, y: y, a: a, enabled: true)
                    start()
                }
                Button("제자리 돌기") {
                    x = 0; y = 0; a = 0.25
                    enabled = true
                    engine.setCommand(x: x, y: y, a: a, enabled: true)
                    start()
                }
                Button("멈춤") {
                    enabled = false
                    engine.setCommand(x: 0, y: 0, a: 0, enabled: false)
                    stop()
                }
                .tint(.red)
            }
            .controlSize(.small)
            .buttonStyle(.glassNeon(tint: DFColor.textPrimary, prominent: false))

            Spacer()

            traceTable
        }
        .padding(DFSpace.md)
        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
        .background(DFColor.elev2)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, format: String, displayMultiplier: Double = 1) -> some View {
        HStack {
            Text(label)
                .font(DFFont.caption)
                .frame(width: 130, alignment: .leading)
                .foregroundStyle(DFColor.textSecondary)
            Slider(value: value, in: range, step: step) { editing in
                if !editing {
                    engine.setCommand(x: x, y: y, a: a, enabled: enabled)
                }
            }
            .tint(DFColor.accent)
            StepperField(
                value: value,
                in: range,
                step: step,
                bigStep: step * 10,
                format: { String(format: format, $0 * displayMultiplier) },
                fieldWidth: 50,
                onCommit: { _ in engine.setCommand(x: x, y: y, a: a, enabled: enabled) }
            )
            .frame(width: 110, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        if let s = lastSample {
            HStack(spacing: DFSpace.sm) {
                Image(systemName: phaseIcon(s.phase))
                    .foregroundStyle(phaseTint(s.phase))
                VStack(alignment: .leading, spacing: DFSpace.none) {
                    Text(phaseKoreanLabel(s.phase)).font(DFFont.bodyEmph)
                    Text(String(format: "%.1f초 경과", s.elapsedMs / 1000.0))
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

    private func phaseKoreanLabel(_ p: WalkPhase) -> String {
        switch p {
        case .phase0: return "쉼 (양발 디딤)"
        case .phase1: return "오른발 들기"
        case .phase2: return "양발 디딤"
        case .phase3: return "왼발 들기"
        }
    }
    private func phaseIcon(_ p: WalkPhase) -> String {
        switch p {
        case .phase0: return "pause.circle"
        case .phase1: return "arrow.up.circle"
        case .phase2: return "arrow.left.and.right.circle"
        case .phase3: return "arrow.up.circle.fill"
        }
    }
    private func phaseTint(_ p: WalkPhase) -> Color {
        switch p {
        case .phase0: return DFColor.textSecondary
        case .phase1: return DFColor.accent
        case .phase2: return DFColor.warning
        case .phase3: return DFColor.success
        }
    }

    // MARK: - Trace table

    private var traceTable: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("최근 발 위치 (m)")
                .font(DFFont.bodyEmph)
            HStack {
                Text("순서").frame(width: 40, alignment: .leading)
                Text("왼발 (앞,옆,위)").frame(width: 130, alignment: .leading)
                Text("오른발 (앞,옆,위)").frame(width: 130, alignment: .leading)
            }
            .font(DFFont.caption)
            .foregroundStyle(DFColor.textSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DFSpace.micro) {
                    ForEach(Array(trace.suffix(8).reversed().enumerated()), id: \.offset) { idx, lf in
                        let rf = rightTrace.suffix(8).reversed()
                            .enumerated().first { $0.offset == idx }?.element ?? SIMD3()
                        HStack {
                            Text("\(idx + 1)").frame(width: 40, alignment: .leading)
                            Text(fmt(lf)).frame(width: 130, alignment: .leading)
                            Text(fmt(rf)).frame(width: 130, alignment: .leading)
                        }
                        .font(DFFont.caption.monospaced())
                    }
                }
            }
            .glassScroll(accent: DFColor.info, fadeHeight: 10, edgeColor: DFColor.card)
            .frame(maxHeight: 180)
            .glass(radius: DFRadius.sm, intensity: 0.7)
        }
    }

    private func fmt(_ v: SIMD3<Double>) -> String {
        String(format: "%+.3f, %+.3f, %+.3f", v.x, v.y, v.z)
    }

    // MARK: - Loop

    private func start() {
        timer?.invalidate()
        trace.removeAll()
        rightTrace.removeAll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                let sample = engine.tick(dtMs: 50)
                lastSample = sample
                trace.append(sample.leftXYZ)
                rightTrace.append(sample.rightXYZ)
                if trace.count > 80 { trace.removeFirst(trace.count - 80) }
                if rightTrace.count > 80 { rightTrace.removeFirst(rightTrace.count - 80) }

                // 실기 적용 — sendToHardware ON 일 때만 다리 joint 명령 전송.
                // 시뮬레이션 sample 기반 IK는 별도 phase로 추가; 일단 walkReady 자세
                // 위에 phase에 따른 hip pitch 흔들림만 직접 send.
                if sendToHardware, let bus = store.bus {
                    let pose = walkPoseFromSample(sample)
                    // 다리 6 관절만 — 안전 위해 팔/머리는 건드리지 않음.
                    let legJoints: [JointID] = [
                        .rHipYaw, .lHipYaw, .rHipRoll, .lHipRoll,
                        .rHipPitch, .lHipPitch, .rKnee, .lKnee,
                        .rAnklePitch, .lAnklePitch, .rAnkleRoll, .lAnkleRoll
                    ]
                    for j in legJoints {
                        let raw = UInt16(clamping: pose.raw(j))
                        _ = try? bus.setPosition(j, raw: raw)
                    }
                }
            }
        }
    }

    /// 시뮬레이션 phase로부터 다리 joint raw 위치 산출 — 단순 IK (직선 다리 + hip pitch 흔들림).
    private func walkPoseFromSample(_ s: FootTargets) -> RobotPose {
        // walkReady 기반에 phase에 따라 hip pitch와 knee를 가볍게 흔든다.
        let phaseT = s.elapsedMs / 1000.0
        let swing = sin(phaseT * 2.0 * .pi) * 0.15  // ±0.15 rad ~ ±8.6°
        var p = RobotPose.walkReady.positions
        let lHipPitchBase = p[.lHipPitch] ?? 1896
        let rHipPitchBase = p[.rHipPitch] ?? 2200
        p[.lHipPitch] = lHipPitchBase + Int(swing * 2048.0 / .pi)
        p[.rHipPitch] = rHipPitchBase - Int(swing * 2048.0 / .pi)
        return RobotPose(positions: p)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
