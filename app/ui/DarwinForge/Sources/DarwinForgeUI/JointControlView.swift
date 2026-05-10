import ForgeCore
import SwiftUI

/// 관절별 슬라이더 + 실시간 상태. 클램프된 한계 표시.
public struct JointControlView: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var selected: JointID = .headPan

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // ── 좌측 — body part별 관절 그룹.
            List(selection: Binding(get: { selected }, set: { if let n = $0 { selected = n } })) {
                ForEach(JointID.BodyPart.allCases, id: \.self) { part in
                    Section(part.rawValue) {
                        ForEach(JointID.allCases.filter { $0.bodyPart == part }, id: \.self) { j in
                            HStack {
                                Text(j.name).font(.system(.callout, design: .monospaced))
                                Spacer()
                                Text("ID \(j.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(j)
                        }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 250)
            .listStyle(.sidebar)

            Divider()

            // ── 우측 — 선택된 관절의 슬라이더 + 상태.
            JointDetailView(joint: selected)
        }
    }
}

/// 한 관절의 슬라이더 + 상태 갱신.
struct JointDetailView: View {
    @EnvironmentObject var store: ConnectionStore
    let joint: JointID

    @State private var goalPosition: Double = 2048
    @State private var isAdjusting: Bool = false
    @State private var lastError: String?

    /// 보수적 한계: 1024..3072. forge-core JointLimits::default()와 동일.
    private let positionRange: ClosedRange<Double> = 1024...3072

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(joint.name)
                .font(.title2.monospaced())

            stateGrid

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Goal Position (raw)")
                    .font(.headline)
                HStack {
                    Slider(value: $goalPosition, in: positionRange, step: 1) { editing in
                        isAdjusting = editing
                        if !editing { commitPosition() }
                    }
                    Text("\(Int(goalPosition))")
                        .frame(width: 60, alignment: .trailing)
                        .fontDesign(.monospaced)
                }
                Text("Range: \(Int(positionRange.lowerBound))..\(Int(positionRange.upperBound))  ·  Center: 2048 (0°)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Torque ON") {
                    runJointAction { try store.bus?.setTorque(joint, enable: true) }
                }
                Button("Torque OFF") {
                    runJointAction { try store.bus?.setTorque(joint, enable: false) }
                }
                Button("Refresh") {
                    store.refreshJointState(joint)
                }
                Spacer()
                Button {
                    runJointAction { try store.bus?.emergencyStop() }
                } label: {
                    Label("E-Stop ALL", systemImage: "exclamationmark.octagon.fill")
                }
                .tint(.red)
            }

            if let err = lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            Spacer()
        }
        .padding()
        .onChange(of: joint) { _, _ in
            store.refreshJointState(joint)
            syncSlider()
        }
        .onAppear {
            store.refreshJointState(joint)
            syncSlider()
        }
    }

    @ViewBuilder
    private var stateGrid: some View {
        if let s = store.jointStates[joint] {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("Goal").foregroundStyle(.secondary)
                    Text("\(s.goalPosition)").fontDesign(.monospaced)
                    Text("Present").foregroundStyle(.secondary)
                    Text("\(s.presentPosition)").fontDesign(.monospaced)
                }
                GridRow {
                    Text("Speed").foregroundStyle(.secondary)
                    Text("\(s.presentSpeed)").fontDesign(.monospaced)
                    Text("Load").foregroundStyle(.secondary)
                    Text("\(s.presentLoad)").fontDesign(.monospaced)
                }
                GridRow {
                    Text("Voltage").foregroundStyle(.secondary)
                    Text(String(format: "%.1f V", s.voltageVolts)).fontDesign(.monospaced)
                    Text("Temperature").foregroundStyle(.secondary)
                    Text("\(s.presentTemperature) °C").fontDesign(.monospaced)
                        .foregroundStyle(s.presentTemperature >= 60 ? .red : .primary)
                }
                GridRow {
                    Text("Torque").foregroundStyle(.secondary)
                    Image(systemName: s.torqueEnabled ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(s.torqueEnabled ? .green : .secondary)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text("(no state — connect & refresh)").foregroundStyle(.secondary)
        }
    }

    private func syncSlider() {
        if let s = store.jointStates[joint] {
            goalPosition = Double(s.goalPosition)
        } else {
            goalPosition = 2048
        }
    }

    private func commitPosition() {
        runJointAction {
            _ = try store.bus?.setPosition(joint, raw: UInt16(goalPosition))
            store.refreshJointState(joint)
        }
    }

    private func runJointAction(_ action: () throws -> Void) {
        guard store.bus != nil else {
            lastError = "Not connected"
            return
        }
        do {
            try action()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
