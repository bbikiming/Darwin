import SwiftUI

/// **v1.17.0 (2026-05-21) Phase 4 — Tello 조종 HUD**.
///
/// WalkLabRCBridge 의 reactive 상태를 시각화. 사용자가:
/// - Tello 연결 상태 즉시 인지 (lastIntent timestamp + source 라벨)
/// - 4 채널 stick 값 시각 (4 horizontal bars)
/// - emergency 버튼으로 즉시 정지 + 모든 채널 차단
/// - bridge 활성/비활성 토글 + scale slider
///
/// # 비유
///
/// 비행기 cockpit HUD — 속도/고도/방향 4 채널 dial. 본 HUD 도 stride/side/turn 3 + sourceChip.
@MainActor
public struct TelloPilotHud: View {
    @Bindable public var bridge: WalkLabRCBridge

    /// **사이클 73 — 코덱스 HIGH-2 fix**: listener lifecycle owner (옵셔널).
    /// nil = HUD 가 status banner 표시 안 함 (legacy / preview). 정상 wiring 시
    /// `WalkLabView` 가 RootView 의 owner reference 를 전달.
    /// @Bindable 사용 — owner.isActive / messagesReceived 변경에 view reactive.
    public var listenerOwner: TelloStateListenerOwner?

    /// **사이클 73**: stalled 판정 threshold — 활성 후 N초 무수신 시 경고.
    /// 기본 5초. preview / test 에서 임의 값 주입 가능.
    public let stalledThresholdSec: TimeInterval

    /// **사이클 73**: HUD render 시 stalled 판정을 위한 "now" tick.
    /// `TimelineView(.periodic)` 가 1초 간격으로 갱신 → 활성인데 무수신인 상태가
    /// 자동으로 stalled 전환됨. nil tick = 정적 (test / preview).
    @State private var nowTick: Date = Date()

    public init(bridge: WalkLabRCBridge,
                listenerOwner: TelloStateListenerOwner? = nil,
                stalledThresholdSec: TimeInterval = 5.0) {
        self.bridge = bridge
        self.listenerOwner = listenerOwner
        self.stalledThresholdSec = stalledThresholdSec
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            stickBars
            telloStateRow
            listenerStatusBanner
            statusRow
            controlsRow
        }
        .padding(12)
        .frame(width: 280)
        .background(DFColor.canvas.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DFColor.accent.opacity(0.35), lineWidth: 1)
        )
        // 1초 주기로 nowTick 갱신 → health() stalled 판정 자동 refresh.
        // listenerOwner nil 이면 banner 자체 skip — overhead 무.
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if listenerOwner != nil { nowTick = Date() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: bridge.enabled ? "gamecontroller.fill" : "gamecontroller")
                .foregroundStyle(bridge.enabled ? DFColor.accent : DFColor.textSecondary)
            Text("Tello Pilot")
                .font(.callout.weight(.semibold))
            Spacer()
            sourceChip
        }
    }

    private var sourceChip: some View {
        let source = bridge.lastIntent?.source
        let isActive = bridge.isActive
        let age = bridge.lastInputAge
        return HStack(spacing: 3) {
            if isActive {
                Circle()
                    .fill(DFColor.success)
                    .frame(width: 6, height: 6)
            }
            Image(systemName: source?.icon ?? "circle.dashed")
                .font(.caption2)
            Text(source?.label ?? "대기")
                .font(.caption.weight(.medium))
            // **v1.20.36 사이클 46** — lastInputAge 표시 (n초 전).
            if let age = age, age > 1.5 {
                Text("·\(Int(age))s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((source != nil ? DFColor.success : DFColor.textSecondary).opacity(isActive ? 0.28 : 0.18))
        .foregroundStyle(source != nil ? DFColor.success : DFColor.textSecondary)
        .clipShape(Capsule())
    }

    // MARK: - Stick bars

    private var stickBars: some View {
        VStack(spacing: 6) {
            stickBar(label: "FB (보폭)", value: currentCmd?.strideMm ?? 0, range: -40...40, color: DFColor.accent)
            stickBar(label: "LR (측면)", value: currentCmd?.sideMm ?? 0, range: -25...25, color: DFColor.info)
            stickBar(label: "YAW (회전)", value: currentCmd?.turnDeg ?? 0, range: -20...20, color: DFColor.warning)
        }
    }

    private var currentCmd: WalkingCommand? {
        if case .move(let cmd) = bridge.lastIntent?.kind {
            return cmd
        }
        return nil
    }

    private func stickBar(label: String, value: Double, range: ClosedRange<Double>, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 70, alignment: .leading)
            GeometryReader { geo in
                let mid = geo.size.width / 2
                let barWidth = min(mid, abs(value) / range.upperBound * mid)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.15))
                        .frame(height: 8)
                        .clipShape(Capsule())
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.35))
                        .frame(width: 1, height: 12)
                        .position(x: mid, y: geo.size.height / 2)
                    Rectangle()
                        .fill(color)
                        .frame(width: barWidth, height: 8)
                        .clipShape(Capsule())
                        .position(
                            x: value >= 0 ? mid + barWidth / 2 : mid - barWidth / 2,
                            y: geo.size.height / 2
                        )
                }
            }
            .frame(height: 14)
            Text(String(format: "%+.0f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(value == 0 ? DFColor.textSecondary : color)
                .frame(width: 32, alignment: .trailing)
        }
    }

    // MARK: - Tello state (battery / altitude / temp)

    @ViewBuilder
    private var telloStateRow: some View {
        if let s = bridge.lastTelloState {
            HStack(spacing: 8) {
                batteryChip(s)
                altitudeChip(s)
                tempChip(s)
                Spacer(minLength: 0)
                Text(stateAgeLabel(s))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(DFColor.textSecondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text("Tello state 미수신 (UDP 8890)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 2)
        }
    }

    private func batteryChip(_ s: TelloStateMessage) -> some View {
        let color: Color = {
            switch s.batteryLevel {
            case .good:    return DFColor.success
            case .medium:  return DFColor.warning
            case .low:     return DFColor.danger
            }
        }()
        return HStack(spacing: 2) {
            Image(systemName: batteryIcon(s.batteryPct))
                .font(.caption2)
            Text("\(s.batteryPct)%")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(color)
    }

    private func batteryIcon(_ pct: Int) -> String {
        if pct >= 75 { return "battery.100" }
        if pct >= 50 { return "battery.75" }
        if pct >= 25 { return "battery.50" }
        if pct >= 10 { return "battery.25" }
        return "battery.0"
    }

    private func altitudeChip(_ s: TelloStateMessage) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up.to.line.compact")
                .font(.caption2)
            Text("\(Int(s.heightCm))cm")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(DFColor.textSecondary)
    }

    private func tempChip(_ s: TelloStateMessage) -> some View {
        let avgTemp = (s.templ + s.temph) / 2
        let color: Color = avgTemp >= 80 ? DFColor.danger : DFColor.textSecondary
        return HStack(spacing: 2) {
            Image(systemName: "thermometer.medium")
                .font(.caption2)
            Text("\(Int(avgTemp))°C")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(color)
    }

    private func stateAgeLabel(_ s: TelloStateMessage) -> String {
        let age = Date().timeIntervalSince(s.receivedAt)
        if age < 1 { return "방금" }
        if age < 60 { return String(format: "%.0fs", age) }
        return String(format: "%.0fm", age / 60)
    }

    // MARK: - Listener status banner (사이클 73 — 코덱스 HIGH-2 fix)

    /// **사이클 73**: silent fail visibility — owner.health() 분류에 따라 banner.
    /// - `.healthy`: 표시 안 함 (정상 운영 시 noise 최소화).
    /// - `.inactive`: "Tello 활성화" 토글 버튼 (사용자 명시 클릭 → start()).
    /// - `.startFailed`: 권한 거부 안내 + "다시 시도" 버튼.
    /// - `.stalled`: Wi-Fi / Info.plist 점검 안내 (활성인데 5초+ 무수신).
    @ViewBuilder
    private var listenerStatusBanner: some View {
        if let owner = listenerOwner {
            let h = owner.health(stalledThreshold: stalledThresholdSec, now: nowTick)
            switch h {
            case .healthy:
                EmptyView()
            case .inactive:
                inactiveBanner(owner: owner)
            case .startFailed:
                startFailedBanner(owner: owner)
            case .stalled(let elapsedSec):
                stalledBanner(elapsedSec: elapsedSec)
            }
        }
    }

    private func inactiveBanner(owner: TelloStateListenerOwner) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
            Text("Tello state listener 비활성")
                .font(.caption)
                .foregroundStyle(DFColor.textSecondary)
            Spacer()
            Button("Tello 활성화") {
                owner.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(DFColor.accent)
            .help("UDP 8890 listener 시작 — 첫 호출 시 macOS 가 로컬 네트워크 권한 요청")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(DFColor.textSecondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func startFailedBanner(owner: TelloStateListenerOwner) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("🔌 Tello state listener 비활성")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DFColor.danger)
                Spacer()
                Button("다시 시도") {
                    owner.start()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(DFColor.warning)
            }
            Text("시스템 환경설정 > 개인정보 > 로컬 네트워크 확인")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(DFColor.danger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func stalledBanner(elapsedSec: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("⚠️ Tello state 미수신")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DFColor.warning)
                Text(String(format: "(%.0f초+)", elapsedSec))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DFColor.warning.opacity(0.8))
                Spacer()
            }
            Text("Wi-Fi 연결 / Info.plist (NSLocalNetworkUsage) 확인")
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(DFColor.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Status row

    private var statusRow: some View {
        Group {
            // **v1.20.19 사이클 25** — emergency 상태 시 recovery 버튼 (KeyboardPilotPanel 와 동일).
            if let session = bridge.session, session.emergencyStopActive {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.caption2)
                        .foregroundStyle(DFColor.danger)
                    Text("긴급 정지 — recovery 필요")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DFColor.danger)
                    Spacer()
                    Button("Recover") {
                        bridge.handleRecovery(from: .ui)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(DFColor.warning)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(DFColor.danger.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let msg = bridge.safetyMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(DFColor.warning)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(DFColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(DFColor.warning.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let intent = bridge.lastIntent {
                Text(intentLabel(intent))
                    .font(.caption)
                    .foregroundStyle(DFColor.textSecondary)
            } else {
                Text("아직 입력 없음")
                    .font(.caption)
                    .foregroundStyle(DFColor.textSecondary.opacity(0.6))
            }
        }
    }

    private func intentLabel(_ intent: PilotIntent) -> String {
        switch intent.kind {
        case .move: return "✓ 이동 명령 적용"
        case .stop: return "⏸ 정지"
        case .emergency: return "🛑 긴급 정지"
        case .motion(let id): return "🎬 모션 \(id)"
        }
    }

    // MARK: - Controls row

    private var controlsRow: some View {
        VStack(spacing: 4) {
            // **v1.20.15 사이클 21** — 현재 settings 표시 (감도 + smoothing).
            // **v1.20.23 사이클 29**: preset 전환 카운터 chip 추가 (KeyboardPanel 와 일관성).
            HStack(spacing: 6) {
                settingChip(icon: "speedometer",
                            label: String(format: "감도 %.1fx", currentSensitivity))
                settingChip(icon: "waveform.path",
                            label: String(format: "smooth %.1f", bridge.smoothingFactor))
                if bridge.presetChangeMirror > 0 {
                    settingChip(icon: "arrow.triangle.2.circlepath",
                                label: "\(bridge.presetChangeMirror)")
                }
                // **v1.20.30 사이클 36** — live comfortLevel chip (0..1 사용자 활동 강도).
                let comfort = bridge.accumulator.summarize().comfortLevel
                if comfort > 0 {
                    settingChip(icon: "figure.walk.motion",
                                label: String(format: "%.0f%%", comfort * 100))
                }
                // **v1.20.45 사이클 59** — input → engine median latency (옵셔널 tracker 활성 시).
                // critic 지적 응답 — "game character" 정량 기준. nil tracker 면 chip 미표시.
                if let stats = bridge.latencyTracker?.statistics(for: .endToEnd),
                   stats.count > 0 {
                    settingChip(icon: "timer",
                                label: String(format: "L: %.0fms", stats.median * 1000))
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Toggle("활성", isOn: $bridge.enabled)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .font(.caption)
                Spacer()
                Button(role: .destructive) {
                    bridge.handleEmergency(from: .ui)
                } label: {
                    Label("긴급정지", systemImage: "exclamationmark.octagon.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    /// **v1.20.15 사이클 21** — 현재 sensitivity = bridge.scale.fb / default.fb.
    /// default = 0.4. 1.0x = default. 0.5x = slow. 2.0x = fast.
    private var currentSensitivity: Double {
        bridge.scale.fb / TelloRCMapper.Scale.default.fb
    }

    private func settingChip(icon: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2.monospacedDigit())
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(DFColor.textSecondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(DFColor.textSecondary)
    }
}
