import SwiftUI

/// drag-to-arm 슬라이더 — 80% 끌면 ARM 시퀀스 실행 (PRD §5.2).
///
/// HIG: 최소 터치 영역 44pt, 명확한 잠금/해제 시각, ESC 단축키 DISARM.
public struct PilotArmSlider: View {
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate

    @State private var offset: CGFloat = 0

    private let thumbSize: CGFloat = 44     // Apple HIG min target.
    private let trackHeight: CGFloat = 56
    private let armThreshold: CGFloat = 0.80

    public init(channel: TeleopChannel, gate: PilotSafetyGate) {
        self.channel = channel
        self.gate = gate
    }

    public var body: some View {
        DFPanel(
            "안전 잠금",
            subtitle: gate.armed ? "잠금 해제됨 — 동작 가능" : "잠금 — 우측으로 끌어 ARM",
            icon: gate.armed ? "lock.open.fill" : "lock.fill",
            tint: gate.armed ? PilotColor.armLocked : PilotColor.armUnlocked,
            trailing: {
                if gate.armed {
                    DFButton(.ghost, size: .small) {
                        channel.disarm()
                    } label: {
                        HStack(spacing: DFSpace.xs) {
                            Image(systemName: "lock.fill")
                            Text("DISARM")
                            DFKeyboardHint("esc")
                        }
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                GeometryReader { geo in
                    sliderTrack(maxWidth: geo.size.width)
                }
                .frame(height: trackHeight)

                stageLabel
            }
        }
    }

    @ViewBuilder
    private func sliderTrack(maxWidth: CGFloat) -> some View {
        let maxOffset = max(0, maxWidth - thumbSize)
        ZStack(alignment: .leading) {
            // 트랙 배경.
            Capsule()
                .fill(
                    LinearGradient(
                        colors: gate.armed
                            ? [PilotColor.armLocked.opacity(DFOpacity.disabled), PilotColor.armLocked.opacity(DFOpacity.o18)]
                            : [PilotColor.armUnlocked.opacity(DFOpacity.strong), PilotColor.armLocked.opacity(DFOpacity.o15)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .overlay(
                    Capsule().stroke(
                        gate.armed ? PilotColor.armLocked.opacity(0.55) : PilotColor.armUnlocked.opacity(DFOpacity.disabled),
                        lineWidth: 1
                    )
                )

            // 진행 채움.
            if !gate.armed {
                Capsule()
                    .fill(PilotColor.armLocked.opacity(DFOpacity.o30))
                    .frame(width: max(thumbSize, offset + thumbSize))
            }

            // 안내 텍스트 — armed 가 아닐 때 트랙 중앙.
            if !gate.armed {
                HStack {
                    Spacer()
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: DFFontSize.s14, weight: .bold))
                        Text("끌어서 ARM")
                            .font(DFFont.bodyEmph)
                    }
                    .foregroundStyle(.white.opacity(DFOpacity.o85))
                    Spacer().frame(width: thumbSize + 8)
                }
                .opacity(offset > 4 ? 0 : 1)
                .animation(PilotAnim.stateChange, value: offset)
            }

            // thumb — Apple HIG 44pt min.
            thumb
                .offset(x: gate.armed ? maxOffset : offset)
                .gesture(dragGesture(maxOffset: maxOffset))
                .accessibilityIdentifier("pilot.arm.thumb")
        }
    }

    private var thumb: some View {
        ZStack {
            Circle()
                .fill(gate.armed ? PilotColor.armLocked : PilotColor.armUnlocked)
                .shadow(
                    color: (gate.armed ? PilotColor.armLocked : PilotColor.armUnlocked).opacity(0.55),
                    radius: 6, y: 2
                )
            Image(systemName: gate.armed ? "lock.open.fill" : "lock.fill")
                .font(.system(size: DFFontSize.s18, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: thumbSize, height: thumbSize)
    }

    private func dragGesture(maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !gate.armed else { return }
                offset = max(0, min(maxOffset, value.translation.width))
            }
            .onEnded { _ in
                guard !gate.armed else { return }
                guard maxOffset > 0 else { offset = 0; return }
                let frac = offset / maxOffset
                if frac >= armThreshold {
                    withAnimation(PilotAnim.lockPop) { offset = maxOffset }
                    Task { await channel.arm() }
                } else {
                    withAnimation(PilotAnim.stateChange) { offset = 0 }
                }
            }
    }

    @ViewBuilder
    private var stageLabel: some View {
        let stage = channel.armStage
        let (text, showProgress): (String, Bool) = {
            switch stage {
            case .idle:              return (gate.armed ? "준비됨 — 동작 버튼 활성" : "안전 잠금", false)
            case .enablingPower:     return ("[1/3] Dynamixel 전원 ON…", true)
            case .rampingTorque:     return ("[2/3] 관절 토크 ON…", true)
            case .reachingWalkready: return ("[3/3] 보행 자세로 전환 중…", true)
            case .ready:             return ("준비 완료", false)
            case .disarming:         return ("잠금 중…", true)
            }
        }()
        HStack(spacing: DFSpace.xs2) {
            if showProgress {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: gate.armed ? "checkmark.circle.fill" : "shield.fill")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(gate.armed ? DFColor.success : DFColor.textSecondary)
            }
            Text(text)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .frame(minHeight: 14)
    }
}
