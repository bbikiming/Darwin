import ForgeCore
import SwiftUI

/// 워크 엔진 시뮬레이션 패널 (실 모터 명령 X).
public struct WalkSimView: View {
    @State private var x: Double = 0.0
    @State private var y: Double = 0.0
    @State private var a: Double = 0.0
    @State private var enabled: Bool = false
    @State private var trace: [FootTargets] = []
    @State private var engine = WalkEngine()
    @State private var timer: Timer?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Walk Simulation").font(.title)
            Text("실 모터 명령은 발행하지 않습니다 — Mac에서 forge-core::walk의 발 궤적만 시각화.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("Walk Command") {
                VStack(alignment: .leading) {
                    sliderRow("x (m/cycle)", value: $x, range: -0.05...0.05)
                    sliderRow("y (m/cycle)", value: $y, range: -0.03...0.03)
                    sliderRow("a (rad/cycle)", value: $a, range: -0.3...0.3)
                    Toggle("Enabled", isOn: $enabled)
                        .onChange(of: enabled) { _, on in
                            engine.setCommand(x: x, y: y, a: a, enabled: on)
                            if on {
                                start()
                            } else {
                                stop()
                            }
                        }
                }
            }

            phaseBadge

            traceTable

            Spacer()
        }
        .padding()
        .onChange(of: x) { _, _ in pushCommand() }
        .onChange(of: y) { _, _ in pushCommand() }
        .onChange(of: a) { _, _ in pushCommand() }
        .onDisappear { stop() }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 130, alignment: .leading)
            Slider(value: value, in: range)
            StepperField(
                value: value,
                in: range,
                step: 0.01,
                bigStep: 0.1,
                format: { String(format: "%+.3f", $0) },
                width: 56
            )
            .frame(width: 78, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        if let last = trace.last {
            HStack {
                Label(last.phase.label, systemImage: "figure.walk")
                Spacer()
                Text(String(format: "elapsed %.0f ms", last.elapsedMs))
                    .fontDesign(.monospaced)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private struct TraceRow: Identifiable {
        let id: Int
        let foot: FootTargets
    }

    @ViewBuilder
    private var traceTable: some View {
        let rows: [TraceRow] = Array(trace.suffix(12).reversed().enumerated())
            .map { TraceRow(id: $0.offset, foot: $0.element) }
        Table(rows) {
            TableColumn("Phase") { Text($0.foot.phase.label).font(.system(.caption, design: .monospaced)) }
                .width(min: 80, ideal: 100)
            TableColumn("L (x,y,z)") { Text(fmt($0.foot.leftXYZ)).font(.system(.caption, design: .monospaced)) }
            TableColumn("R (x,y,z)") { Text(fmt($0.foot.rightXYZ)).font(.system(.caption, design: .monospaced)) }
        }
        .frame(minHeight: 160)
    }

    private func fmt(_ v: SIMD3<Double>) -> String {
        String(format: "%+.3f, %+.3f, %+.3f", v.x, v.y, v.z)
    }

    private func pushCommand() {
        engine.setCommand(x: x, y: y, a: a, enabled: enabled)
    }

    private func start() {
        timer?.invalidate()
        trace.removeAll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                trace.append(engine.tick(dtMs: 50))
                if trace.count > 200 { trace.removeFirst(trace.count - 200) }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
