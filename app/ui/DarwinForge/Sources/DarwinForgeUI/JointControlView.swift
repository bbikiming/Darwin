import ForgeCore
import SwiftUI

/// 관절별 슬라이더 + 실시간 상태. 클램프된 한계 표시.
public struct JointControlView: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var selected: JointID = .headPan

    public init() {}

    public var body: some View {
        DFPageScaffold(
            "관절 제어",
            subtitle: "개별 관절 슬라이더 + 실시간 상태",
            icon: "slider.horizontal.below.rectangle",
            tint: DFColor.forge
        ) {
            HStack(spacing: DFSpace.none) {
                // 좌측 — body part별 관절 그룹.
                List(selection: Binding(get: { selected }, set: { if let n = $0 { selected = n } })) {
                    ForEach(JointID.BodyPart.allCases, id: \.self) { part in
                        Section(part.rawValue) {
                            ForEach(JointID.allCases.filter { $0.bodyPart == part }, id: \.self) { j in
                                HStack {
                                    Text(j.name).font(.system(size: DFFontSize.s13, design: .monospaced))
                                    Spacer()
                                    Text("ID \(j.rawValue)")
                                        .font(DFFont.caption)
                                        .foregroundStyle(DFColor.textSecondary)
                                }
                                .tag(j)
                            }
                        }
                    }
                }
                .frame(minWidth: 220, idealWidth: 250)
                .listStyle(.sidebar)

                Divider()

                // 우측 — 선택된 관절의 슬라이더 + 상태.
                JointDetailView(joint: selected)
            }
        }
        .dfDensity(.compact)
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
        VStack(alignment: .leading, spacing: DFSpace.md) {
            Text(joint.name)
                .font(.system(size: DFFontSize.s22, weight: .semibold, design: .monospaced))

            stateGrid

            Divider()

            DFSlider(
                "Goal Position",
                value: $goalPosition,
                in: positionRange, step: 1, unit: "raw",
                showRangeLabels: true,
                caption: "Center 2048 (0°)",
                onEditingChanged: { editing in
                    isAdjusting = editing
                    if !editing { commitPosition() }
                }
            )

            HStack(spacing: DFSpace.sm3) {
                Button("Torque ON") {
                    runJointAction("torque_on") { try store.bus?.setTorque(joint, enable: true) }
                }
                Button("Torque OFF") {
                    runJointAction("torque_off") { try store.bus?.setTorque(joint, enable: false) }
                }
                Button("Refresh") {
                    store.refreshJointState(joint)
                }
                Spacer()
                Button {
                    runJointAction("e_stop") { try store.bus?.emergencyStop() }
                } label: {
                    Label("E-Stop ALL", systemImage: "exclamationmark.octagon.fill")
                }
                .tint(DFColor.danger)
            }

            if let err = lastError {
                Text(err)
                    .foregroundStyle(DFColor.danger)
                    .font(DFFont.caption)
            }
            Spacer()
        }
        .padding(DFSpace.md)
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
            Grid(alignment: .leading, horizontalSpacing: DFSpace.lg, verticalSpacing: DFSpace.xs) {
                GridRow {
                    Text("Goal").foregroundStyle(DFColor.textSecondary)
                    Text("\(s.goalPosition)").fontDesign(.monospaced)
                    Text("Present").foregroundStyle(DFColor.textSecondary)
                    Text("\(s.presentPosition)").fontDesign(.monospaced)
                }
                GridRow {
                    Text("Speed").foregroundStyle(DFColor.textSecondary)
                    Text("\(s.presentSpeed)").fontDesign(.monospaced)
                    Text("Load").foregroundStyle(DFColor.textSecondary)
                    Text("\(s.presentLoad)").fontDesign(.monospaced)
                }
                GridRow {
                    Text("Voltage").foregroundStyle(DFColor.textSecondary)
                    Text(String(format: "%.1f V", s.voltageVolts)).fontDesign(.monospaced)
                    Text("Temperature").foregroundStyle(DFColor.textSecondary)
                    Text("\(s.presentTemperature) °C")
                        .fontDesign(.monospaced)
                        .foregroundStyle(s.presentTemperature >= 60 ? DFColor.danger : DFColor.textPrimary)
                }
                GridRow {
                    Text("Torque").foregroundStyle(DFColor.textSecondary)
                    Image(systemName: s.torqueEnabled ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(s.torqueEnabled ? DFColor.success : DFColor.textSecondary)
                }
            }
            .padding(DFSpace.sm)
            .background(DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
            )
        } else {
            Text("(no state — connect & refresh)")
                .foregroundStyle(DFColor.textSecondary)
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
        runJointAction("set_position") {
            _ = try store.bus?.setPosition(joint, raw: UInt16(goalPosition))
            store.refreshJointState(joint)
        }
    }

    private func runJointAction(_ actionName: String, _ action: () throws -> Void) {
        guard store.bus != nil else {
            lastError = "Not connected"
            return
        }
        Harness.shared.record(
            .jointActionRequested, level: .info, actor: .user,
            data: [
                "action": AnyCodable(actionName),
                "joint_id": AnyCodable(joint.rawValue),
                "joint_name": AnyCodable(joint.name)
            ]
        )
        do {
            try action()
            lastError = nil
        } catch {
            // UI 표시 — 로컬라이즈 된 메시지 (사용자 노출 OK).
            lastError = error.localizedDescription
            // 사이클 202 (codex critic MAJOR-1 cycle 199 fix): telemetry payload 에
            // raw `error.localizedDescription` 전송 X — 파일 경로 / 호스트명 / IP /
            // username 등 PII 노출 위험. cycle 182 shellErrorCase / cycle 187
            // DispatcherError.telemetryCase 패턴 일관 — type 만 + hash.
            Harness.shared.record(
                .jointActionFailed, level: .error, actor: .user,
                data: [
                    "action": AnyCodable(actionName),
                    "joint_id": AnyCodable(joint.rawValue),
                    "error_type": AnyCodable(String(describing: type(of: error))),
                    "error_hash": AnyCodable(Harness.shortHash(error.localizedDescription))
                ]
            )
        }
    }
}
