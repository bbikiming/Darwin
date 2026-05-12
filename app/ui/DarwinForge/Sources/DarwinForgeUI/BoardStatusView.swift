import ForgeCore
import SwiftUI

/// CM-730/740 보드 상태. 연결 후 자동 폴링 (1 Hz).
public struct BoardStatusView: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var snapshot: BoardSnapshot?
    @State private var timer: Timer?
    @State private var lastError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            Text("Board Status")
                .font(.title)
                .padding(.bottom, 4)

            if let snap = snapshot {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Controller").foregroundStyle(.secondary)
                        Text(snap.controllerLabel).fontDesign(.monospaced)
                    }
                    GridRow {
                        Text("Firmware Version").foregroundStyle(.secondary)
                        Text("\(snap.version)").fontDesign(.monospaced)
                    }
                    GridRow {
                        Text("Battery").foregroundStyle(.secondary)
                        HStack {
                            Text(String(format: "%.1f V", snap.voltageVolts))
                                .fontDesign(.monospaced)
                            voltageBadge(snap.voltageVolts)
                        }
                    }
                    GridRow {
                        Text("Button bits").foregroundStyle(.secondary)
                        Text(String(format: "0x%02X", snap.button)).fontDesign(.monospaced)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView("Reading board…")
            }

            if let err = lastError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            Spacer()
        }
        .padding()
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: store.status) { _, _ in pollOnce() }
    }

    private func startPolling() {
        pollOnce()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in pollOnce() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func pollOnce() {
        guard let bus = store.bus else { snapshot = nil; return }
        do {
            self.snapshot = try bus.boardSnapshot()
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func voltageBadge(_ v: Double) -> some View {
        if v >= 11.1 {
            Label("Healthy", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if v >= 9.5 {
            Label("Low", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Label("Critical", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
