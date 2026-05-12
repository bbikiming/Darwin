import SwiftUI

/// 현재 운영 모드 표시 — 시뮬 / 실기 / 오프라인.
///
/// 근거: Unitree LED steady-on 패턴 + Differentiate Without Color
/// (색+아이콘+텍스트 3중 인코딩) — 색약 안전.
public struct ModeBadge: View {
    @ObservedObject public var dispatcher: IntentDispatcher

    public init(dispatcher: IntentDispatcher) {
        self.dispatcher = dispatcher
    }

    public var body: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s13, weight: .semibold))
            Text(label)
                .font(DFFont.bodyEmph)
        }
        .padding(.horizontal, DFSpace.sm + 2)
        .padding(.vertical, DFSpace.xs + 2)
        .background(
            Capsule().fill(color.opacity(DFOpacity.o18))
        )
        .overlay(
            Capsule().stroke(color, lineWidth: 1.2)
        )
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("현재 모드: \(label)")
        .accessibilityHint(hint)
    }

    private var label: String {
        switch dispatcher.mode {
        case .simulation: return KoreanUX.Mode.simulation
        case .hardware: return KoreanUX.Mode.hardware
        case .offline: return KoreanUX.Mode.offline
        }
    }

    private var icon: String {
        switch dispatcher.mode {
        case .simulation: return "cube.transparent"
        case .hardware: return "antenna.radiowaves.left.and.right"
        case .offline: return "wifi.slash"
        }
    }

    private var color: Color {
        switch dispatcher.mode {
        case .simulation: return DFColor.success
        case .hardware: return DFColor.accent
        case .offline: return .secondary
        }
    }

    private var hint: String {
        switch dispatcher.mode {
        case .simulation: return KoreanUX.Mode.simulationDescription
        case .hardware: return KoreanUX.Mode.hardwareDescription
        case .offline: return KoreanUX.Mode.offlineDescription
        }
    }
}
