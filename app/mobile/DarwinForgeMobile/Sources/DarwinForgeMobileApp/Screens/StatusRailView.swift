import SwiftUI
import MobilePilotKit

// V297-6 (PM Story S3.1): onRecover 추가 — estopped 시 복구 버튼 표시.
public struct StatusRailView: View {
    let model: StatusRailModel
    let isMockMode: Bool
    let onEStop: () -> Void
    let onRecover: () -> Void

    public init(model: StatusRailModel,
                isMockMode: Bool = false,
                onEStop: @escaping () -> Void,
                onRecover: @escaping () -> Void = {}) {
        self.model = model
        self.isMockMode = isMockMode
        self.onEStop = onEStop
        self.onRecover = onRecover
    }

    // estopped 상태 판단 — pilotState 또는 telemetry.uiState 기준.
    private var isEstopped: Bool {
        if case .estopped = model.pilotState { return true }
        if model.telemetry?.uiState == .estopped { return true }
        return false
    }

    public var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // iOS-I3 fix (truth-gap report, 2026-05-25): mockReview 모드면
                    // status rail 첫 자리에 명시 chip — 사용자가 실 robot 으로 제어
                    // 가능한 줄로 오해하지 않게.
                    if isMockMode {
                        StatusChip(label: "Mock 모드",
                                   variant: .warning,
                                   accessibilityID: "pilot.status.mock")
                    }
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
            // V297-6 (PM Story S3.1): estopped → 녹색 복구 버튼, 아니면 빨간 긴급 정지.
            EmergencyStopButton(
                mode: isEstopped ? .recover : .estop,
                onTap: isEstopped ? onRecover : onEStop
            )
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
