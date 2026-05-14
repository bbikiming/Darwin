import ForgeCore
import SwiftUI

/// 전략 FSM 시뮬레이션. 사용자가 가짜 입력으로 전이를 step.
public struct StrategyView: View {
    @State private var state: StrategyState = .idle
    @State private var ballPixelCount: Double = 0
    @State private var sinceKickMs: Double = 0
    @State private var abort: Bool = false
    @State private var history: [StrategyState] = []

    public init() {}

    public var body: some View {
        DFPageScaffold(
            "Strategy FSM",
            subtitle: "forge-core::strategy 결정성 전이 시뮬 (실 카메라/모터 명령 X)",
            icon: "flowchart.fill",
            tint: DFColor.accent
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    currentStateBadge

                    DFPanel("Inputs", icon: "slider.horizontal.3") {
                        VStack(alignment: .leading, spacing: DFSpace.sm) {
                            sliderRow("Ball pixel_count", value: $ballPixelCount, range: 0...3000, format: "%.0f")
                            sliderRow("Since kick (ms)", value: $sinceKickMs, range: 0...3000, format: "%.0f")
                            Toggle("Abort", isOn: $abort)
                                .font(.system(size: DFFontSize.s12))
                        }
                    }

                    HStack(spacing: DFSpace.sm) {
                        Button("Step") { advance() }
                            .buttonStyle(.glassNeon(tint: DFColor.accent))
                        Button("Reset") {
                            state = .idle
                            history = []
                        }
                        Spacer()
                        Button("Auto run 6 steps") { autoRun() }
                    }

                    historyView

                    Spacer(minLength: DFSpace.md)
                }
                .padding(DFSpace.md)
            }
        }
        .dfDensity(.compact)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: DFSpace.sm) {
            Text(label)
                .font(.system(size: DFFontSize.s12))
                .frame(width: 160, alignment: .leading)
            Slider(value: value, in: range)
            StepperField(
                value: value,
                in: range,
                step: max((range.upperBound - range.lowerBound) / 100, 0.01),
                format: { String(format: format, $0) },
                fieldWidth: 50
            )
            .frame(width: 110, alignment: .trailing)
        }
    }

    private var currentStateBadge: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: stateIcon)
                .font(.system(size: DFFontSize.s22, weight: .semibold))
                .foregroundStyle(stateColor)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(state.label)
                    .font(.system(size: DFFontSize.s20, weight: .semibold))
                Text("Current state")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
    }

    private var stateIcon: String {
        switch state {
        case .idle:            return "pause.circle.fill"
        case .lookingForBall:  return "magnifyingglass"
        case .approachingBall: return "figure.walk"
        case .kicking:         return "soccerball"
        case .cooldown:        return "hourglass"
        }
    }

    /// 상태별 색상 — 의미 매핑: idle=비활성, look=정보, approach=진행, kick=위험경고, cooldown=주의.
    private var stateColor: Color {
        switch state {
        case .idle:            return DFColor.textSecondary
        case .lookingForBall:  return DFColor.info
        case .approachingBall: return DFColor.forge
        case .kicking:         return DFColor.danger
        case .cooldown:        return DFColor.torque
        }
    }

    @ViewBuilder
    private var historyView: some View {
        if !history.isEmpty {
            DFPanel("Trace", icon: "list.bullet.indent") {
                ScrollView(.horizontal) {
                    HStack(spacing: DFSpace.xs2) {
                        ForEach(Array(history.enumerated()), id: \.offset) { idx, s in
                            VStack(spacing: DFSpace.micro2) {
                                Text("\(idx + 1)")
                                    .font(.system(size: DFFontSize.s10))
                                    .foregroundStyle(DFColor.textSecondary)
                                Text(s.label)
                                    .font(.system(size: DFFontSize.s11, design: .monospaced))
                            }
                            .padding(DFSpace.xs2)
                            .background(DFColor.elev2)
                            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                            if idx + 1 < history.count {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: DFFontSize.s10))
                                    .foregroundStyle(DFColor.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func advance() {
        let next = Strategy.step(
            from: state,
            ballPixelCount: UInt32(ballPixelCount),
            sinceKickMs: UInt32(sinceKickMs),
            abort: abort
        )
        history.append(state)
        state = next
    }

    private func autoRun() {
        for _ in 0..<6 { advance() }
    }
}
