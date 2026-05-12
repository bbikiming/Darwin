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
    @EnvironmentObject private var store: ConnectionStore
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
        .onAppear { session.attach(store: store) }
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
                        AdvancedSlidersPanel(session: session)
                            .padding(.top, 4)
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

    // 고급 슬라이더 패널은 AdvancedSlidersPanel 로 분리 (Components/AdvancedSlidersPanel.swift).
    // 옛 sliderRow 헬퍼는 SafetyBandedSlider 로 대체.

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
            simOnlyNotice

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
            if session.advanced && session.stabilityScore.category == .critical {
                banner(systemImage: "xmark.octagon.fill",
                       message: "낙상 위험 점수 \(Int(session.stabilityScore.score))/100 — 시작 차단. 슬라이더 값을 줄이거나 안전 한도 해제를 끄세요.",
                       tint: .red)
            }

            HStack(spacing: 12) {
                // Hero: 3D 모델 — pose 는 walkReady, footTrace 는 좌측 발 자취.
                // 구 WalkLab.swift 의 RobotScene3D wiring 패턴 재사용.
                RobotScene3D(
                    pose: .walkReady,
                    footTrace: session.footTrail.map { $0.left }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DFColor.textSecondary.opacity(0.20), lineWidth: 0.5)
                )

                // 사이드 패널: 2D 발자취 (top-down) + IMU 게이지 2개.
                VStack(spacing: 10) {
                    FootTrailCanvas(trail: session.footTrail,
                                    leftFoot: session.leftFoot,
                                    rightFoot: session.rightFoot)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(DFColor.textSecondary.opacity(0.20), lineWidth: 0.5)
                        )
                    IMUGauge(axis: "Roll", degrees: session.imuRollDeg, dangerThreshold: 30)
                    IMUGauge(axis: "Pitch", degrees: session.imuPitchDeg, dangerThreshold: 30)
                }
                .frame(width: 240)
            }

            footTargetsCard

            actionBar
        }
        .padding(16)
    }

    /// 시뮬 vs 실 송출 경계 안내. 슬라이더는 sim, 자세 전환은 실 로봇 송출.
    private var simOnlyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("자세 전환 = 실 송출 · 보행 모션 = 시뮬")
                    .font(.system(size: 12, weight: .semibold))
                Text("프리셋 시작/정지·“walk_ready 송출” 은 실 로봇에 자세 전송 (연결 + cradle 확인 시). 슬라이더 보폭/측면/회전 명령은 walk::engine 의 실 IK 완성 전까지 sim only (BLOCKER C3) — 발 자취·IMU·온도는 시뮬 모델.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            Divider().frame(height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Temp").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f°C", session.maxMotorTemp))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tempColor)
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

    private var tempColor: Color {
        let t = session.maxMotorTemp
        if t >= 60 { return .red }
        if t >= 50 { return .orange }
        if t >= 45 { return .yellow }
        return .secondary
    }

    private var actionBar: some View {
        VStack(spacing: 6) {
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

                Divider().frame(height: 20)

                Button {
                    Task { await store.applyPoseSmoothly(.walkReady) }
                } label: {
                    Label("walk_ready 송출", systemImage: "figure.walk.motion")
                }
                .disabled(store.bus == nil || !session.cradleConfirmed)
                .help("실 로봇을 walkReady 자세로 보냄 (정비 스탠드 거치 + 연결 필수)")

                Spacer()

                connectionPill

                Text(session.cradleConfirmed
                     ? "정비 스탠드 거치 ✓"
                     : "↑ 사이드바에서 스탠드 거치를 먼저 확인하세요")
                    .font(.caption)
                    .foregroundStyle(session.cradleConfirmed ? .green : .orange)
            }

            if let evt = session.lastRobotEvent {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                    Text(evt).font(.caption.monospacedDigit())
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 로봇 연결 상태 pill — bus 유무 + endpoint 짧은 표시.
    private var connectionPill: some View {
        let connected = store.bus != nil
        let label: String = {
            if !connected { return "로봇 미연결" }
            if let ep = store.activeEndpoint {
                return "연결됨 — \(ep.displayName)"
            }
            return "연결됨"
        }()
        return HStack(spacing: 4) {
            Circle()
                .fill(connected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(label).font(.caption2)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill((connected ? Color.green : Color.gray).opacity(0.12)))
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
        // Advanced 모드 + critical 점수 → 사용자가 슬라이더로 직접 만든 위험 조합. 차단.
        if session.advanced && session.stabilityScore.category == .critical {
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
