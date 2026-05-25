import SwiftUI
import MobilePilotKit

/// Deadman-style walk pad. Press-and-hold to send a preset; release to stop.
public struct WalkPad: View {
    let disabled: Bool
    let onPressBegan: (WalkPreset) -> Void
    let onReleased: () -> Void

    @State private var activePreset: WalkPreset?

    public init(disabled: Bool,
                onPressBegan: @escaping (WalkPreset) -> Void,
                onReleased: @escaping () -> Void) {
        self.disabled = disabled
        self.onPressBegan = onPressBegan
        self.onReleased = onReleased
    }

    public var body: some View {
        VStack(spacing: 12) {
            zone(preset: .slowForward, symbol: "arrow.up", label: "전진", id: "pilot.walk.forward")
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                zone(preset: .turnLeft, symbol: "arrow.turn.up.left",
                     label: "좌회전", id: "pilot.walk.turnLeft")
                centerStop
                zone(preset: .turnRight, symbol: "arrow.turn.up.right",
                     label: "우회전", id: "pilot.walk.turnRight")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pilot.walk.pad")
    }

    private var centerStop: some View {
        Button {
            activePreset = nil
            onReleased()
        } label: {
            VStack {
                Image(systemName: "stop.fill")
                Text("정지").font(.caption.weight(.semibold))
            }
            .frame(width: 72, height: 72)
            .foregroundStyle(.white)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pilot.walk.stop")
        .accessibilityLabel("보행 정지")
    }

    private func zone(preset: WalkPreset, symbol: String, label: String, id: String) -> some View {
        let isActive = activePreset == preset
        return ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(isActive ? Color.blue.opacity(0.5) : Color.dfSecondaryBackground)
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title2)
                Text(label).font(.body.weight(.semibold))
            }
            .foregroundStyle(isActive ? .white : .primary)
        }
        .frame(minWidth: 72, minHeight: 96)
        .contentShape(Rectangle())
        .opacity(disabled ? 0.4 : 1)
        .gesture(
            LongPressGesture(minimumDuration: 0.001)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { state in
                    guard !disabled else { return }
                    switch state {
                    case .first(true):
                        if activePreset != preset {
                            activePreset = preset
                            onPressBegan(preset)
                        }
                    case .second(_, _):
                        if activePreset != preset {
                            activePreset = preset
                            onPressBegan(preset)
                        }
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    activePreset = nil
                    onReleased()
                }
        )
        .accessibilityIdentifier(id)
        .accessibilityLabel("\(label) — 누르는 동안 활성, 떼면 정지")
    }
}
