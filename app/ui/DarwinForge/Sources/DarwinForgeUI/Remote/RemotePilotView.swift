import ForgeCore
import SwiftUI

/// Remote Pilot v1.0 메인 뷰.
/// 좌 360px: ARM 슬라이더 → Mode Picker → Speed Gauge + D-pad → Action Bar.
/// 우 fill: 3D 로봇 뷰 (sim) + HUD strip.
/// PRD §5 / Sprint 15.
public struct RemotePilotView: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject private var channel: TeleopChannel
    @StateObject private var gate = PilotSafetyGate()

    @State private var mode: PilotMode = .manual

    private let flags = PilotFeatureFlags.default

    public init() {
        // BusActor will be injected via onAppear from ConnectionStore.
        _channel = StateObject(wrappedValue: TeleopChannel(busActor: nil))
    }

    public var body: some View {
        ZStack {
            // E-Stop flash overlay
            if gate.flashRed {
                Color.red.opacity(0.25)
                    .ignoresSafeArea()
                    .animation(PilotAnim.estopFlash, value: gate.flashRed)
            }

            HStack(spacing: 0) {
                // Left column
                leftPanel
                    .frame(width: 360)

                Divider()
                    .background(Color.white.opacity(0.08))

                // Right column
                rightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DFColor.canvas)
        .onAppear {
            // Wire BusActor from store when view appears.
            // TeleopChannel is already initialized; update busActor here.
            // Note: no direct property setter available on @StateObject content —
            // the channel reads from store via emergencyStop delegate.
        }
        // Global keyboard shortcuts
        .background(keyboardShortcuts)
        // Sim mode banner when no bus
        .overlay(alignment: .top) {
            if store.bus == nil {
                simBanner
            }
        }
    }

    // MARK: - Left panel

    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section header
                Label("원격 조종", systemImage: "gamecontroller.fill")
                    .font(DFFont.subtitle)
                    .foregroundStyle(DFNeon.electric)
                    .padding(.top, 4)

                Divider().background(Color.white.opacity(0.08))

                // ARM slider
                VStack(alignment: .leading, spacing: 6) {
                    Text("ARM")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(1.5)
                    PilotArmSlider(channel: channel, gate: gate)
                }

                Divider().background(Color.white.opacity(0.08))

                // Mode picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("모드")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(1.5)
                    PilotModePicker(mode: $mode)
                }

                // Speed gauge + D-pad
                HStack(alignment: .top, spacing: 12) {
                    PilotSpeedGauge(channel: channel)
                        .frame(width: 90)
                    PilotDpad(channel: channel, flags: flags)
                        .frame(maxWidth: .infinity)
                }

                Divider().background(Color.white.opacity(0.08))

                // Action bar
                VStack(alignment: .leading, spacing: 6) {
                    Text("동작")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(1.5)
                    PilotActionBar(channel: channel, gate: gate)
                }

                Spacer(minLength: 20)
            }
            .padding(16)
        }
        .background(DFColor.card)
    }

    // MARK: - Right panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            // HUD strip
            PilotHudStrip(channel: channel, gate: gate)
                .environmentObject(store)

            Divider().background(Color.white.opacity(0.08))

            // 3D robot view (sim) — crossfade by mode
            ZStack {
                RobotScene3D(
                    pose: store.jointStates.isEmpty
                        ? RobotPose.idle
                        : RobotPose(positions: Dictionary(
                            uniqueKeysWithValues: store.jointStates.map {
                                ($0.key, Int($0.value.presentPosition))
                            }
                          ))
                )
                .opacity(mode == .manual ? 1.0 : 0.0)

                // Ball-Follow placeholder
                if mode == .ballFollow {
                    PilotCameraView()
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Toast messages
            if let toast = channel.toastMessage {
                toastBanner(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: channel.toastMessage)
    }

    // MARK: - Subviews

    private var simBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(PilotColor.caution)
            Text("시뮬 모드 — 실 로봇 연결 안 됨")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text("⌘⇧C 로 연결")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7))
        .overlay(
            Rectangle().frame(height: 0.5).foregroundStyle(PilotColor.caution.opacity(0.4)),
            alignment: .bottom
        )
    }

    private func toastBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
            .shadow(radius: 8)
            .padding(.bottom, 16)
    }

    // MARK: - Global keyboard shortcuts

    private var keyboardShortcuts: some View {
        ZStack {
            // Action bar 1..7
            ForEach(Array(actionBarMain.enumerated()), id: \.element) { i, slot in
                let key = KeyEquivalent(Character("\(i + 1)"))
                Button("Action \(i+1)") {
                    if let meta = MotionCatalog.find(slot: slot), gate.armed {
                        let gateResult = gate.allowMotion(meta, confirmRisk: false)
                        if case .allow = gateResult {
                            Task { @MainActor in
                                try? await channel.sendMotion(slot: slot, confirmRisk: false)
                            }
                        }
                    }
                }
                .keyboardShortcut(key, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
            }

            // D-pad keys (sim)
            Button("Fwd") { simulateDpad(.walk(x: 0.04, y: 0, a: 0)) }
                .keyboardShortcut("w", modifiers: []).opacity(0).frame(width: 0, height: 0)
            Button("Back") { simulateDpad(.walk(x: -0.04, y: 0, a: 0)) }
                .keyboardShortcut("s", modifiers: []).opacity(0).frame(width: 0, height: 0)
            Button("Left") { simulateDpad(.walk(x: 0, y: 0.03, a: 0)) }
                .keyboardShortcut("a", modifiers: []).opacity(0).frame(width: 0, height: 0)
            Button("Right") { simulateDpad(.walk(x: 0, y: -0.03, a: 0)) }
                .keyboardShortcut("d", modifiers: []).opacity(0).frame(width: 0, height: 0)
            Button("TurnL") { simulateDpad(.walk(x: 0, y: 0, a: 0.3)) }
                .keyboardShortcut("q", modifiers: []).opacity(0).frame(width: 0, height: 0)
            Button("TurnR") { simulateDpad(.walk(x: 0, y: 0, a: -0.3)) }
                .keyboardShortcut("e", modifiers: []).opacity(0).frame(width: 0, height: 0)
            Button("Stop") { channel.currentCmd = .stop }
                .keyboardShortcut(.space, modifiers: []).opacity(0).frame(width: 0, height: 0)

            // ESC: disarm
            Button("Disarm") {
                Task { @MainActor in
                    await channel.disarm()
                    gate.armed = false
                }
            }
            .keyboardShortcut(.escape, modifiers: []).opacity(0).frame(width: 0, height: 0)
        }
    }

    private func simulateDpad(_ cmd: TeleopCommandSwift) {
        guard !flags.dpadRealMotor else { return } // BLOCKER C3
        channel.currentCmd = cmd
    }
}
