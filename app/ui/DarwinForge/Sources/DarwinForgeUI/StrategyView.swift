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
        VStack(alignment: .leading, spacing: 16) {
            Text("Strategy FSM").font(.title)
            Text("forge-core::strategy의 결정성 전이를 step 단위로 시뮬레이션. 실 카메라/모터 명령 X.")
                .font(.callout).foregroundStyle(.secondary)

            currentStateBadge

            GroupBox("Inputs") {
                VStack(alignment: .leading) {
                    sliderRow("Ball pixel_count", value: $ballPixelCount, range: 0...3000, format: "%.0f")
                    sliderRow("Since kick (ms)", value: $sinceKickMs, range: 0...3000, format: "%.0f")
                    Toggle("Abort", isOn: $abort)
                }
            }

            HStack {
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

            Spacer()
        }
        .padding()
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(label).frame(width: 160, alignment: .leading)
            Slider(value: value, in: range)
            StepperField(
                value: value,
                in: range,
                step: max((range.upperBound - range.lowerBound) / 100, 0.01),
                format: { String(format: format, $0) },
                width: 56
            )
            .frame(width: 78, alignment: .trailing)
        }
    }

    private var currentStateBadge: some View {
        HStack {
            Image(systemName: stateIcon)
                .font(.title)
                .foregroundStyle(stateColor)
            VStack(alignment: .leading) {
                Text(state.label).font(.title3)
                Text("Current state").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private var stateColor: Color {
        switch state {
        case .idle:            return .gray
        case .lookingForBall:  return .blue
        case .approachingBall: return .orange
        case .kicking:         return .red
        case .cooldown:        return .purple
        }
    }

    @ViewBuilder
    private var historyView: some View {
        if !history.isEmpty {
            GroupBox("Trace") {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(history.enumerated()), id: \.offset) { idx, s in
                            VStack(spacing: 2) {
                                Text("\(idx + 1)").font(.caption2).foregroundStyle(.secondary)
                                Text(s.label).font(.caption).fontDesign(.monospaced)
                            }
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            if idx + 1 < history.count {
                                Image(systemName: "chevron.right").font(.caption2)
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
