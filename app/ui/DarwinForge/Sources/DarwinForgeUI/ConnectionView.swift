import ForgeCore
import SwiftUI

/// 사이드바 상단의 연결 패널. 포트 선택 + 연결/끊기 + 상태.
public struct ConnectionView: View {
    @EnvironmentObject var store: ConnectionStore

    public init() {}

    public var body: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Port", selection: Binding(
                        get: { store.selectedPort ?? "" },
                        set: { store.selectedPort = $0.isEmpty ? nil : $0 }
                    )) {
                        if store.availablePorts.isEmpty {
                            Text("(no USB serial)").tag("")
                        } else {
                            ForEach(store.availablePorts, id: \.self) { p in
                                Text(p).tag(p)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isConnected)

                    Button {
                        store.refreshPorts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("포트 목록 새로고침")
                }

                HStack(spacing: 8) {
                    if isConnected {
                        Button("Disconnect", role: .destructive) {
                            store.disconnect()
                        }
                        Button {
                            store.emergencyStop()
                        } label: {
                            Label("E-Stop", systemImage: "exclamationmark.octagon.fill")
                        }
                        .tint(.red)
                        .keyboardShortcut(".", modifiers: [.command, .shift])
                        .help("⌘⇧.  모든 관절 토크 OFF")
                    } else {
                        Button("Connect") {
                            store.connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled((store.selectedPort ?? "").isEmpty)
                    }
                }

                statusBadge
                    .font(.callout)
            }
            .padding(.vertical, 4)
        }
        .onAppear { store.refreshPorts() }
    }

    private var isConnected: Bool {
        if case .connected = store.status { return true } else { return false }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch store.status {
        case .disconnected:
            Label("Disconnected", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting(let p):
            Label("Connecting to \(p)…", systemImage: "ellipsis.circle")
                .foregroundStyle(.secondary)
        case .connected(let snap):
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                Text(snap.controllerLabel)
                    .font(.caption)
                Text(String(format: "Battery: %.1f V", snap.voltageVolts))
                    .font(.caption)
                    .foregroundStyle(snap.voltageVolts < 9.5 ? .red : .secondary)
            }
        case .error(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }
}
