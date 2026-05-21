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

    public init(bridge: WalkLabRCBridge) {
        self.bridge = bridge
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            stickBars
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
        return HStack(spacing: 3) {
            Image(systemName: source?.icon ?? "circle.dashed")
                .font(.caption2)
            Text(source?.label ?? "대기")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((source != nil ? DFColor.success : DFColor.textSecondary).opacity(0.18))
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

    // MARK: - Status row

    private var statusRow: some View {
        Group {
            if let msg = bridge.safetyMessage {
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
