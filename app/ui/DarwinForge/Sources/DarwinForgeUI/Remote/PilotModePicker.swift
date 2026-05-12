import SwiftUI

/// 조종 모드.
public enum PilotMode: String, CaseIterable, Sendable {
    case manual = "수동"
    case ballFollow = "공 추적"
}

/// Manual / Ball-Follow 모드 전환 picker.
/// matchedGeometryEffect 슬라이드 인디케이터.
public struct PilotModePicker: View {
    @Binding var mode: PilotMode
    @Namespace private var ns

    public init(mode: Binding<PilotMode>) {
        self._mode = mode
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(PilotMode.allCases, id: \.self) { m in
                modeTab(m)
            }
        }
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .frame(height: 38)
    }

    @ViewBuilder
    private func modeTab(_ m: PilotMode) -> some View {
        if m == .ballFollow {
            Button { mode = m } label: { tabLabel(m) }
                .buttonStyle(.plain)
                .comingSoon(
                    stage: "v1.1",
                    title: "Ball-Follow 모드",
                    why: "Head PID 추적 + 카메라 연결이 필요합니다.",
                    when: "v1.1 활성 — head 추적, v1.5 — 카메라+walk",
                    alternative: "수동 모드로 조종하세요"
                )
                .frame(maxWidth: .infinity)
        } else {
            Button { withAnimation(PilotAnim.modePicker) { mode = m } } label: {
                tabLabel(m)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private func tabLabel(_ m: PilotMode) -> some View {
        ZStack {
            if mode == m {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PilotColor.armed.opacity(0.25))
                    .matchedGeometryEffect(id: "picker_indicator", in: ns)
                    .padding(3)
            }
            HStack(spacing: 5) {
                Image(systemName: m == .manual ? "gamecontroller.fill" : "target")
                    .font(.system(size: 11))
                Text(m.rawValue)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(mode == m ? PilotColor.armed : .white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
