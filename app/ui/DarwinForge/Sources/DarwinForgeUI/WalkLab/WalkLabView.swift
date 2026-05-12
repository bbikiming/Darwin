import ForgeCore
import SwiftUI

/// Walk Lab — 8개 보행 프리셋 + 발 자취 + IMU 게이지 + 자동 정지 + 세션 기록.
///
/// RootView 의 `Section.walk` 케이스에서 이 view 로 교체:
/// ```swift
/// case .walk: WalkLabView()
/// ```
///
/// 안전 게이트:
/// - L0: ESC / ⌘⇧. emergency stop (이미 RootView 전역)
/// - L1: cradle confirm 체크박스
/// - L2: preset safety class (Caution=노랑, HighRisk=빨강)
/// - L3: live IMU |roll/pitch| > 30° → 자동 stop
/// - L4: 모터 max 온도 60°C 도달 → 자동 stop
public struct WalkLabView: View {
    @StateObject private var session = WalkLabSession()
    @State private var showingRiskConfirm: Bool = false
    @State private var pendingHighRiskPreset: WalkLabPreset?

    public init() {}

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingRiskConfirm) {
            riskConfirmSheet
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Toggle(isOn: $session.cradleConfirmed) {
                Label("정비 스탠드에 거치됨", systemImage: "checkmark.shield")
                    .font(.system(size: 13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(WalkLabPreset.allCases) { preset in
                        PresetButton(
                            preset: preset,
                            isActive: session.current == preset,
                            isEnabled: session.cradleConfirmed
                        ) {
                            tap(preset)
                        }
                    }

                    Divider()
                        .padding(.vertical, 8)

                    Toggle("고급 — 슬라이더 조정", isOn: $session.advanced)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)

                    if session.advanced {
                        advancedSliders
                    }
                }
                .padding(12)
            }

            Divider()

            sessionHistory
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Walk Lab")
                    .font(.system(size: 16, weight: .semibold))
                Text("걷기 테스트 + 보완")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var advancedSliders: some View {
        VStack(spacing: 8) {
            sliderRow("보폭 x", value: $session.customX, range: -0.05...0.05, format: "%+.3f m")
            sliderRow("좌우 y", value: $session.customY, range: -0.03...0.03, format: "%+.3f m")
            sliderRow("회전 a", value: $session.customA, range: -0.3...0.3, format: "%+.2f rad")
            sliderRow("주기", value: $session.customPeriodMs, range: 400...800, format: "%.0f ms")
        }
        .padding(.horizontal, 8)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var sessionHistory: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("세션 기록")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            if session.history.isEmpty {
                Text("(아직 없음)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    ForEach(session.history) { rec in
                        HStack(spacing: 8) {
                            Image(systemName: rec.preset.icon)
                                .font(.caption2)
                                .foregroundStyle(rec.preset.safety.tintColor)
                            Text(rec.summary)
                                .font(.caption.monospacedDigit())
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                }
                .frame(maxHeight: 120)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 12) {
            if session.balanceLost {
                banner(systemImage: "exclamationmark.triangle.fill",
                       message: "균형 잃음 감지 — 자동 정지됨",
                       tint: .red)
            }
            if session.thermalAlarm {
                banner(systemImage: "thermometer.sun.fill",
                       message: "모터 60°C 도달 — 자동 정지 + LiPo 분리 권고",
                       tint: .red)
            }

            HStack(spacing: 12) {
                FootTrailCanvas(trail: session.footTrail,
                                leftFoot: session.leftFoot,
                                rightFoot: session.rightFoot)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 8) {
                    IMUGauge(axis: "Roll", degrees: session.imuRollDeg, dangerThreshold: 30)
                    IMUGauge(axis: "Pitch", degrees: session.imuPitchDeg, dangerThreshold: 30)
                }
                .frame(width: 160)
            }

            footTargetsCard

            actionBar
        }
        .padding(16)
    }

    private func banner(systemImage: String, message: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button("닫기") {
                session.balanceLost = false
                session.thermalAlarm = false
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.18))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footTargetsCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Phase").font(.caption).foregroundStyle(.secondary)
                Text(session.phaseLabel)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            Divider().frame(height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("L (x,y,z)").font(.caption).foregroundStyle(.secondary)
                Text(fmt3(session.leftFoot))
                    .font(.system(size: 12, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("R (x,y,z)").font(.caption).foregroundStyle(.secondary)
                Text(fmt3(session.rightFoot))
                    .font(.system(size: 12, design: .monospaced))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Elapsed").font(.caption).foregroundStyle(.secondary)
                Text("\(session.elapsedMs) ms")
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                tap(.idle)
            } label: {
                Label("정지", systemImage: "pause.circle")
            }

            Button {
                session.emergencyStop()
            } label: {
                Label("비상 정지", systemImage: "exclamationmark.octagon.fill")
            }
            .keyboardShortcut(.escape)
            .tint(.red)

            Spacer()

            Text(session.cradleConfirmed
                 ? "정비 스탠드 거치 ✓"
                 : "↑ 사이드바에서 스탠드 거치를 먼저 확인하세요")
                .font(.caption)
                .foregroundStyle(session.cradleConfirmed ? .green : .orange)
        }
    }

    // MARK: - Risk confirm sheet

    private var riskConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text("위험한 보행 모드")
                    .font(.title3.bold())
            }
            if let warning = pendingHighRiskPreset?.warning {
                Text(warning)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Toggle("위험을 인지하고 진행합니다", isOn: $session.riskAcknowledged)
                .toggleStyle(.checkbox)

            HStack {
                Button("취소") {
                    pendingHighRiskPreset = nil
                    showingRiskConfirm = false
                }
                Spacer()
                Button("위험 감수하고 실행") {
                    if let p = pendingHighRiskPreset {
                        session.start(p)
                    }
                    pendingHighRiskPreset = nil
                    showingRiskConfirm = false
                }
                .disabled(!session.riskAcknowledged)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Actions

    private func tap(_ preset: WalkLabPreset) {
        guard session.cradleConfirmed || preset == .idle else { return }
        if preset == .idle {
            session.stop()
            return
        }
        if preset.requiresRiskConfirmation && !session.riskAcknowledged {
            pendingHighRiskPreset = preset
            showingRiskConfirm = true
            return
        }
        session.start(preset)
    }

    private func fmt3(_ v: SIMD3<Double>) -> String {
        String(format: "%+.3f %+.3f %+.3f", v.x, v.y, v.z)
    }
}
