import SwiftUI
import MobilePilotKit

public struct StatusRailView: View {
    let model: StatusRailModel
    let onEStop: () -> Void

    public init(model: StatusRailModel, onEStop: @escaping () -> Void) {
        self.model = model
        self.onEStop = onEStop
    }

    public var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StatusChip(label: model.macLabel,
                               variant: macVariant,
                               accessibilityID: "pilot.status.mac")
                    StatusChip(label: model.robotLabel,
                               variant: robotVariant,
                               accessibilityID: "pilot.status.robot")
                    StatusChip(label: model.armLabel,
                               variant: armVariant,
                               accessibilityID: "pilot.status.arm")
                    StatusChip(label: "지연",
                               variant: model.latencyWarning ? .warning : .neutral,
                               value: model.latencyLabel,
                               accessibilityID: "pilot.status.latency")
                }
                .padding(.horizontal, 4)
            }
            EmergencyStopButton(onTap: onEStop)
        }
        .accessibilityIdentifier("pilot.status.rail")
    }

    private var macVariant: StatusChip.Variant {
        switch model.transport {
        case .connected: return .connected
        case .connecting, .handshaking, .idle: return .searching
        case .disconnected: return .danger
        }
    }

    private var robotVariant: StatusChip.Variant {
        guard let t = model.telemetry else { return .neutral }
        switch t.robot {
        case .connected: return .connected
        case .sim: return .neutral
        case .stale, .busBusy: return .warning
        case .disconnected: return .neutral
        case .estopped: return .danger
        }
    }

    private var armVariant: StatusChip.Variant {
        switch model.pilotState {
        case .armedReady, .commandActive: return .connected
        case .arming: return .searching
        case .estopped, .staleStop: return .danger
        default: return .neutral
        }
    }
}
