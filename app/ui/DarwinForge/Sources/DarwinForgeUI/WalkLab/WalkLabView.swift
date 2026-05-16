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
        .background(DFColor.canvas)
        .onAppear { session.attach(store: store) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DFSpace.none) {
            header

            Toggle(isOn: $session.cradleConfirmed) {
                Label("정비 스탠드에 거치됨", systemImage: "checkmark.shield")
                    .font(.system(size: DFFontSize.s13))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm2)
            .background(DFColor.card)

            Divider()

            ScrollView {
                VStack(spacing: DFSpace.xs2) {
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
                        .padding(.vertical, DFSpace.sm)

                    Toggle("고급 — 슬라이더 조정", isOn: $session.advanced)
                        .font(.system(size: DFFontSize.s12))
                        .padding(.horizontal, DFSpace.sm)

                    if session.advanced {
                        AdvancedSlidersPanel(session: session)
                            .padding(.top, DFSpace.xs)
                    }
                }
                .padding(DFSpace.sm3)
            }

            Divider()

            sessionHistory
        }
        .background(DFColor.card.opacity(DFOpacity.o50))
    }

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "figure.walk")
                .font(.system(size: DFFontSize.s18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                Text("Walk Lab")
                    .font(.system(size: DFFontSize.s16, weight: .semibold))
                Text("걷기 테스트 + 보완")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm3)
    }

    // 고급 슬라이더 패널은 AdvancedSlidersPanel 로 분리 (Components/AdvancedSlidersPanel.swift).
    // 옛 sliderRow 헬퍼는 SafetyBandedSlider 로 대체.

    private var sessionHistory: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("세션 기록")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.sm)
            if session.history.isEmpty {
                Text("(아직 없음)")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                    .padding(.horizontal, DFSpace.md)
                    .padding(.bottom, DFSpace.sm3)
            } else {
                ScrollView {
                    ForEach(session.history) { rec in
                        HStack(spacing: DFSpace.sm) {
                            Image(systemName: rec.preset.icon)
                                .font(.system(size: DFFontSize.s10))
                                .foregroundStyle(rec.preset.safety.tintColor)
                            Text(rec.summary)
                                .font(.system(size: DFFontSize.s11, design: .monospaced))
                            Spacer()
                        }
                        .padding(.horizontal, DFSpace.md)
                        .padding(.vertical, DFSpace.micro2)
                    }
                }
                .frame(maxHeight: 120)
                .padding(.bottom, DFSpace.sm)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: DFSpace.sm3) {
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

            HStack(spacing: DFSpace.sm3) {
                // Hero: 3D 모델 — **Phase G11 (2026-05-15)**: pose 가 보행 cycle 마다 갱신.
                // 실 로봇 송출 중: `runContinuousWalk` 의 onPose 가 매 step 마다 visualPose publish.
                // sim mode: 50ms tick 이 phase 따라 합성 pose publish.
                // footTrace 는 좌측 발 자취 (2D 캔버스와 동일 source).
                RobotScene3D(
                    pose: session.visualPose,
                    footTrace: session.footTrail.map { $0.left }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.sm)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
                )

                // 사이드 패널: 2D 발자취 (top-down) + IMU 게이지 2개.
                VStack(spacing: DFSpace.sm2) {
                    FootTrailCanvas(trail: session.footTrail,
                                    leftFoot: session.leftFoot,
                                    rightFoot: session.rightFoot)
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                        .overlay(
                            RoundedRectangle(cornerRadius: DFRadius.xs2)
                                .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
                        )
                    // **Stage 1 (v1.1 fall prevention)**: 실 IMU 출처 라벨 표시.
                    HStack(spacing: 4) {
                        Circle()
                            .fill(imuSourceColor)
                            .frame(width: 6, height: 6)
                        Text("IMU 출처: \(session.imuSource.label)")
                            .font(.system(size: DFFontSize.s10, design: .monospaced))
                            .foregroundStyle(DFColor.textSecondary)
                        Spacer()
                    }
                    IMUGauge(axis: "Roll", degrees: session.imuRollDeg, dangerThreshold: 30)
                    IMUGauge(axis: "Pitch", degrees: session.imuPitchDeg, dangerThreshold: 30)
                }
                .frame(width: 240)
            }

            footTargetsCard

            actionBar
        }
        .padding(DFSpace.md)
    }

    /// 시뮬 vs 실 송출 경계 안내. 프리셋/고급 슬라이더 모두 실 송출 page 합성에 반영.
    private var simOnlyNotice: some View {
        let walking = session.isRobotWalking
        let connected = store.bus != nil
        let title: String = {
            if walking { return "🤖 보행 cycle 송출 중 — 실 로봇 동작" }
            if connected && session.cradleConfirmed {
                return "프리셋 보행 = 실 송출 활성 · 슬라이더 = 실시간 반영"
            }
            return "프리셋 보행 = 실 송출 (연결 + cradle 후) · 슬라이더 = page 재합성"
        }()
        let detail = "프리셋(제자리·천천히·보통·빠르게·공 접근 킥·좌/우회전)은 ROBOTIS walking 기반 step 시퀀스를 모터에 직접 송출합니다. 고급 슬라이더(보폭/측면/회전/주기/발 들기/균형)는 진행 중인 실 보행 page를 debounce 후 재합성합니다."
        let tint: Color = walking ? DFColor.success : DFColor.info
        return HStack(spacing: DFSpace.sm) {
            Image(systemName: walking ? "figure.walk.motion" : "info.circle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: DFSpace.micro) {
                Text(title)
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                Text(detail)
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, DFSpace.sm2)
        .padding(.vertical, DFSpace.xs2)
        .background(tint.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs2)
                .stroke(tint.opacity(DFOpacity.o30), lineWidth: DFSize.borderStrong)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    private func banner(systemImage: String, message: String, tint: Color) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: DFFontSize.s14, weight: .semibold))
            Text(message)
                .font(.system(size: DFFontSize.s13, weight: .medium))
            Spacer()
            Button("닫기") {
                session.balanceLost = false
                session.thermalAlarm = false
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, DFSpace.sm3)
        .padding(.vertical, DFSpace.sm)
        .background(tint.opacity(DFOpacity.o18))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private var footTargetsCard: some View {
        HStack(spacing: DFSpace.md - 2) {
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("Phase").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(session.phaseLabel)
                    .font(.system(size: DFFontSize.s13, weight: .semibold, design: .monospaced))
            }
            Divider().frame(height: DFSpace.xl)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("L (x,y,z)").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(fmt3(session.leftFoot))
                    .font(.system(size: DFFontSize.s12, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("R (x,y,z)").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(fmt3(session.rightFoot))
                    .font(.system(size: DFFontSize.s12, design: .monospaced))
            }
            Divider().frame(height: DFSpace.xl)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("Temp").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(String(format: "%.1f°C", session.maxMotorTemp))
                    .font(.system(size: DFFontSize.s12, design: .monospaced))
                    .foregroundStyle(tempColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: DFSpace.micro2) {
                Text("Elapsed").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text("\(session.elapsedMs) ms")
                    .font(.system(size: DFFontSize.s12, design: .monospaced))
            }
        }
        .padding(DFSpace.sm2)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    /// 모터 온도 색상 — DFLoadColor 5단계 매핑 (45/50/60°C 임계값).
    private var tempColor: Color {
        let t = session.maxMotorTemp
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFLoadColor.high }
        if t >= 45 { return DFColor.warning }
        return DFColor.textSecondary
    }

    /// **Stage 1 (v1.1 fall prevention)**: IMU 출처별 색.
    /// sim = 회색 (참고용), real = 녹색 (정상), stale = 주황 (경고).
    private var imuSourceColor: Color {
        switch session.imuSource {
        case .sim:   return DFColor.textSecondary
        case .real:  return .green
        case .stale: return DFColor.warning
        }
    }

    private var actionBar: some View {
        VStack(spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.sm2) {
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
                .tint(DFColor.danger)

                Divider().frame(height: DFSpace.md2 - DFSpace.xs)

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
                    .font(DFFont.caption)
                    .foregroundStyle(session.cradleConfirmed ? DFColor.success : DFColor.warning)
            }

            if let evt = session.lastRobotEvent {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: DFFontSize.s10))
                    Text(evt).font(.system(size: DFFontSize.s11, design: .monospaced))
                    Spacer()
                }
                .foregroundStyle(DFColor.textSecondary)
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
        let dotColor: Color = connected ? DFColor.success : DFColor.textSecondary
        return HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: DFSize.indicatorXxs, height: DFSize.indicatorXxs)
            Text(label).font(.system(size: DFFontSize.s10))
        }
        .padding(.horizontal, DFSpace.xs2).padding(.vertical, DFSpace.micro2)
        .background(Capsule().fill(dotColor.opacity(DFOpacity.subtle)))
    }

    // MARK: - Risk confirm sheet

    private var riskConfirmSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md - 2) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DFFontSize.s22, weight: .semibold))
                    .foregroundStyle(DFColor.danger)
                Text("위험한 보행 모드")
                    .font(.system(size: DFFontSize.s20, weight: .bold))
            }
            if let warning = pendingHighRiskPreset?.warning {
                Text(warning)
                    .font(.system(size: DFFontSize.s13))
                    .foregroundStyle(DFColor.textSecondary)
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
                .tint(DFColor.danger)
            }
        }
        .padding(DFSpace.md2)
        .frame(width: DFLayout.modalMedium.w - 100)
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
