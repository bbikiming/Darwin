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
        DFPageScaffold(
            "보드 상태",
            subtitle: "CM-730 / CM-740 컨트롤러 폴링 (1 Hz)",
            icon: "cpu.fill",
            tint: DFColor.forge
        ) {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                if let snap = snapshot {
                    Grid(alignment: .leading, horizontalSpacing: DFSpace.lg, verticalSpacing: DFSpace.sm) {
                        GridRow {
                            Text("Controller").foregroundStyle(DFColor.textSecondary)
                            Text(snap.controllerLabel).fontDesign(.monospaced)
                        }
                        GridRow {
                            Text("Firmware Version").foregroundStyle(DFColor.textSecondary)
                            Text("\(snap.version)").fontDesign(.monospaced)
                        }
                        GridRow {
                            Text("Battery").foregroundStyle(DFColor.textSecondary)
                            HStack(spacing: DFSpace.sm) {
                                Text(String(format: "%.1f V", snap.voltageVolts))
                                    .fontDesign(.monospaced)
                                voltageBadge(snap.voltageVolts)
                            }
                        }
                        GridRow {
                            Text("Button bits").foregroundStyle(DFColor.textSecondary)
                            Text(String(format: "0x%02X", snap.button)).fontDesign(.monospaced)
                        }
                    }
                    .padding(DFSpace.md)
                    .background(DFColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
                    )
                } else {
                    ProgressView("Reading board…")
                }

                if let err = lastError {
                    Text(err)
                        .foregroundStyle(DFColor.danger)
                        .font(DFFont.caption)
                }
                Spacer()
            }
            .padding(DFSpace.md)
        }
        .dfDensity(.regular)
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

    /// 전압 상태 배지 — 11.1V 이상 정상, 9.5V 이상 주의, 미만 위험.
    @ViewBuilder
    private func voltageBadge(_ v: Double) -> some View {
        if v >= 11.1 {
            DFStatusPill("정상", severity: .success, compact: true)
        } else if v >= 9.5 {
            DFStatusPill("부족", severity: .warning, compact: true)
        } else {
            DFStatusPill("위험", severity: .danger, compact: true)
        }
    }
}
