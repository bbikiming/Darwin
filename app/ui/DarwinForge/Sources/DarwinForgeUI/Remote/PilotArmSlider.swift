import SwiftUI

/// ARM 슬라이더 — 80% 드래그 완료 시 arm() 호출.
/// 미완성 시 spring으로 원위치. ARM 완료 후 잠금 아이콘 변경.
public struct PilotArmSlider: View {
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate

    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    private let trackWidth: CGFloat = 280
    private let thumbSize: CGFloat = 48
    private var threshold: CGFloat { (trackWidth - thumbSize) * 0.80 }

    public init(channel: TeleopChannel, gate: PilotSafetyGate) {
        self.channel = channel
        self.gate = gate
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            // Track
            RoundedRectangle(cornerRadius: 12)
                .fill(gate.armed
                    ? PilotColor.armed.opacity(0.25)
                    : Color.white.opacity(0.06))
                .frame(width: trackWidth, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            gate.armed ? PilotColor.armed.opacity(0.6) : Color.white.opacity(0.15),
                            lineWidth: 1
                        )
                )

            // Fill progress
            if !gate.armed {
                RoundedRectangle(cornerRadius: 12)
                    .fill(PilotColor.armed.opacity(0.18))
                    .frame(width: max(0, dragOffset + thumbSize), height: 52)
            }

            // Track label
            if !gate.armed && !isDragging {
                Text("→  ARM 슬라이드")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: trackWidth)
            } else if gate.armed {
                Text("✓  준비 완료")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(PilotColor.armed)
                    .frame(width: trackWidth)
            }

            // Thumb
            if !gate.armed {
                Circle()
                    .fill(PilotColor.armed)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: PilotColor.armed.opacity(0.6), radius: 6)
                    .offset(x: max(0, min(dragOffset, trackWidth - thumbSize)))
                    .animation(isDragging ? nil : PilotAnim.sliderReturn, value: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                dragOffset = max(0, min(value.translation.width, trackWidth - thumbSize))
                            }
                            .onEnded { _ in
                                isDragging = false
                                if dragOffset >= threshold {
                                    dragOffset = trackWidth - thumbSize
                                    Task { @MainActor in
                                        await channel.arm()
                                        gate.armed = true
                                    }
                                } else {
                                    dragOffset = 0
                                }
                            }
                    )
            } else {
                // ARM 완료 상태 — lock.open.fill 아이콘
                Circle()
                    .fill(PilotColor.armed)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: trackWidth - thumbSize)
                    .onTapGesture {
                        Task { @MainActor in
                            await channel.disarm()
                            gate.armed = false
                            dragOffset = 0
                        }
                    }
            }
        }
        .frame(width: trackWidth, height: 52)
    }
}
