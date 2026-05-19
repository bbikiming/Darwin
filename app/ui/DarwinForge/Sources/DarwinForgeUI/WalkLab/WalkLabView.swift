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
    // **v1.11.14 (2026-05-19)**: RootView hoisted session — WalkDataView 의 실험 승인이
    // 동일 인스턴스를 변경하도록 EnvironmentObject 로 변경. 종전 @StateObject 시
    // WalkDataView 가 별도 session 인스턴스를 못 봐 applyExperimentChange 의 부작용
    // 단절. 라이프사이클은 RootView 가 관리.
    @EnvironmentObject private var session: WalkLabSession
    @State private var showingRiskConfirm: Bool = false
    @State private var pendingHighRiskPreset: WalkLabPreset?

    /// **v1.11 (2026-05-17 사용자 요청)**: Fall Prevention 패널 너비 — 사용자 drag
    /// 으로 조절 + 다음 실행 시 복원. UserDefaults key `df.walklab.fallPanelWidth`.
    /// 기본 380pt, range 280..720.
    @AppStorage("df.walklab.fallPanelWidth") private var fallPanelWidth: Double = 380
    /// Drag 시작 시점의 너비 — translation 누적 계산용.
    @State private var fallPanelDragStartWidth: Double? = nil
    /// Drag handle hover 상태 — 시각 highlight 용.
    @State private var fallPanelHandleHovering: Bool = false

    public init() {}

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        // **v1.11.6 (2026-05-18)** — invisible onboard brokering bridge.
        // session.walkingEngine == .robotisOnboard + autoOnboardBrokering=true 시
        // preset/tuning 변경 300ms debounce 후 자동 SSH send.
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: DFSpace.xs) {
                // v1.11.16.1: onboard 모드일 때만 health indicator 표시.
                OnboardHealthIndicator()
                WalkLabOnboardBridge(session: session)
            }
            .padding(DFSpace.sm)
        }
        // **v1.11.14.7 (2026-05-19)** — 활성 실험 floating banner.
        // session.activeExperimentId != nil 시 자동 표시. Rollback/수락 버튼 노출.
        // 종전: 자동 rollback (failRollback) 만, 사용자 명시 rollback 불가.
        .overlay(alignment: .bottomTrailing) {
            ActiveExperimentBanner()
                .padding(DFSpace.md)
        }
        .sheet(isPresented: $showingRiskConfirm) {
            riskConfirmSheet
        }
        .background(DFColor.canvas)
        .onAppear { session.attach(store: store) }
        // **2026-05-16**: 메뉴바 "보기 → Fall Prevention 모니터링" (⌘⇧M) 수신.
        .onReceive(NotificationCenter.default.publisher(for: .dfToggleMonitoring)) { _ in
            withAnimation(DFAnimation.toggle) {
                session.monitoringExpanded.toggle()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DFSpace.none) {
            header

            Toggle(isOn: $session.cradleConfirmed) {
                Label("정비 스탠드에 거치됨", systemImage: "checkmark.shield")
                    .font(DFFont.body)
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
                        .font(DFFont.bodySmall)
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
                .font(DFFont.sectionLarge)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                Text("Walk Lab")
                    .font(DFFont.sectionMedium)
                Text("걷기 테스트 + 보완")
                    .font(DFFont.label)
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
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                    .padding(.horizontal, DFSpace.md)
                    .padding(.bottom, DFSpace.sm3)
            } else {
                ScrollView {
                    ForEach(session.history) { rec in
                        HStack(spacing: DFSpace.sm) {
                            Image(systemName: rec.preset.icon)
                                .font(DFFont.label)
                                .foregroundStyle(rec.preset.safety.tintColor)
                            Text(rec.summary)
                                .font(DFFont.monoCaption)
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
        // 2026-05-16 layout: 좌측 세로 dashboard + 세로 toggle stripe + 우측 main.
        // - 펼침: 모니터링 column (사용자 drag, 기본 380pt) + 우측 main 동시 시각
        // - 접힘: 세로 stripe (36pt) 만 — 좌측 edge 에서 클릭 시 펼침
        // - 세로 toggle 만 사용 (가로 monitoringToggleBar 제거) — macOS Mail sidebar
        //   collapse 패턴 정합
        // **v1.11 (2026-05-17 사용자 요청)**: 명시 drag handle — `fallPanelDragHandle`
        // 으로 사용자가 좌우 마우스 drag 으로 너비 조절. AppStorage 자동 복원.
        HStack(alignment: .top, spacing: DFSpace.none) {
            if session.monitoringExpanded {
                monitoringSidebar
                fallPanelDragHandle
            } else {
                collapsedMonitoringStripe
            }
            mainDetailContent
        }
    }

    /// **v1.11 (2026-05-17 사용자 요청) — Fall Prevention 패널 drag handle**.
    ///
    /// 6pt 너비 hit area + 1pt visible line (hover 시 3pt + accent). 좌우 drag 으로
    /// `fallPanelWidth` 업데이트 (clamp 280..720). `NSCursor.resizeLeftRight` 자동.
    /// 사용자 마지막 너비는 `@AppStorage` 가 다음 실행 때 자동 복원.
    private var fallPanelDragHandle: some View {
        let isActive = fallPanelHandleHovering || fallPanelDragStartWidth != nil
        return ZStack {
            // Hit area (cursor + drag) — 투명 6pt.
            Color.clear
                .contentShape(Rectangle())
            // Visible line — 1pt 또는 3pt (hover/drag 시).
            Rectangle()
                .fill(isActive ? DFColor.accent : DFColor.textSecondary.opacity(DFOpacity.o20))
                .frame(width: isActive ? 3 : 1)
                .animation(DFAnimation.fast, value: isActive)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            fallPanelHandleHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if fallPanelDragStartWidth == nil {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if fallPanelDragStartWidth == nil {
                        fallPanelDragStartWidth = fallPanelWidth
                    }
                    let newWidth = (fallPanelDragStartWidth ?? fallPanelWidth)
                                 + Double(value.translation.width)
                    fallPanelWidth = max(280, min(720, newWidth))
                }
                .onEnded { _ in
                    fallPanelDragStartWidth = nil
                    if !fallPanelHandleHovering {
                        NSCursor.pop()
                    }
                }
        )
        .help("좌우 drag — Fall Prevention 패널 너비 조절")
        .accessibilityLabel("패널 너비 조절")
        .accessibilityHint("좌우 드래그하여 너비를 조절합니다")
    }

    /// 좌측 세로 모니터링 dashboard column — `monitoringExpanded` 시만 표시.
    /// 헤더에 닫기 버튼 (chevron.left) + 본문 `FallPreventionMonitor` ScrollView.
    /// **v1.11 (2026-05-17 사용자 요청)**: 명시 drag handle (`fallPanelDragHandle`)
    /// 로 너비 조절. 기본 380pt, range 280..720pt. `@AppStorage` 가 사용자 마지막
    /// 너비를 다음 실행 시 자동 복원.
    private var monitoringSidebar: some View {
        VStack(spacing: 0) {
            // **macOS-native header** — Inspector style. material background.
            HStack(spacing: DFSpace.sm) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DFColor.accent.gradient)
                Text("Fall Prevention")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DFColor.textPrimary)
                Spacer()
                Button {
                    withAnimation(DFAnimation.fast) {
                        session.monitoringExpanded = false
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DFColor.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("모니터링 패널 접기 (⌘⇧M)")
                .accessibilityLabel("모니터링 패널 접기")
            }
            .padding(.horizontal, DFSpace.sm2)
            .padding(.vertical, DFSpace.sm)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                FallPreventionMonitor(session: session)
                    .padding(DFSpace.sm)
            }
            .scrollIndicators(.automatic)
        }
        // **v1.11 (2026-05-17)**: AppStorage 가 관리하는 사용자 drag 너비 적용.
        // `fallPanelDragHandle` 이 옆에서 lifecycle 관리.
        .frame(width: CGFloat(fallPanelWidth))
        .background(.regularMaterial)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    /// **v1.11 모니터링 패널 너비 한계** (사용자 drag resize).
    /// 실제 적용은 `fallPanelWidth` (@AppStorage) + drag handle 이 clamp.
    private var monitorMinWidth: CGFloat { 280 }
    private var monitorIdealWidth: CGFloat { 380 }
    private var monitorMaxWidth: CGFloat { 720 }

    /// 접힘 상태의 좌측 edge 세로 stripe — 펼치기 버튼 + 라벨.
    /// macOS Mail / Notes 의 sidebar collapse 패턴 정합.
    private var collapsedMonitoringStripe: some View {
        VStack(spacing: DFSpace.sm) {
            Button {
                withAnimation(DFAnimation.fast) {
                    session.monitoringExpanded = true
                }
            } label: {
                VStack(spacing: DFSpace.xs2) {
                    Image(systemName: "chevron.right")
                        .font(DFFont.sectionBody)
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(DFFont.sectionBody)
                    Text("모니터링")
                        .font(DFFont.micro)
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                        .frame(width: 12, height: 60)
                }
                .foregroundStyle(DFColor.accent)
                .padding(.vertical, DFSpace.md)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("Fall Prevention 모니터링 펼치기 (⌘⇧M)")
            .accessibilityLabel("Fall Prevention 모니터링 펼치기")
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Spacer()
        }
        .frame(width: 36)
        .frame(maxHeight: .infinity)
        .background(DFColor.elev2)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DFColor.textSecondary.opacity(DFOpacity.subtle))
                .frame(width: DFSize.borderHairline)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var mainDetailContent: some View {
        ScrollView {
            VStack(spacing: DFSpace.sm3) {
                // **v1.11.17 (2026-05-19)**: 워크랩 진입 즉시 자이로 실시간 패널.
                // 사용자가 보행 시작 전 (preset 선택 전) 부터 IMU 상태 확인 가능.
                // 보행 중 panel 우측의 FallPreventionMonitor 와 별개 — 항상 표시.
                LiveGyroPanel()

                simOnlyNotice

                if session.balanceLost {
                    banner(systemImage: "exclamationmark.triangle.fill",
                           message: "균형 잃음 감지 — 자동 정지됨",
                           tint: DFColor.danger)
                }
                if session.thermalAlarm {
                    banner(systemImage: "thermometer.sun.fill",
                           message: "모터 60°C 도달 — 자동 정지됨. 배터리를 분리해 주세요",
                           tint: DFColor.danger)
                }
                if session.advanced && session.stabilityScore.category == .critical {
                    // 2026-05-17 UX audit: 이중부정 "해제를 끄세요" → "다시 잠그세요" 직관화.
                    // 토스트 길이 단축 (96자 → 핵심만).
                    banner(systemImage: "xmark.octagon.fill",
                           message: "위험도 \(Int(session.stabilityScore.score))/100 — 시작 차단됨. 슬라이더를 줄이거나 '안전 한도 해제'를 다시 잠그세요.",
                           tint: DFColor.danger)
                }

                // 2026-05-16: 가로 monitoringToggleBar 제거 — 좌측 세로 stripe 로 통합.
                // 토글은 `collapsedMonitoringStripe` 또는 `monitoringSidebar` 헤더의
                // chevron 버튼에서 수행.

                // **v1.11 (2026-05-17 사용자 요청) — 반응형 hero row**:
                // 3D scene 카메라가 frame width 적응으로 zoom in (InteractiveSceneView
                // .setFrameSize), 사이드 패널 240→280 으로 확장. scene 좌상단에 walking
                // phase/elapsed 오버레이로 빈 영역 정보화.
                HStack(spacing: DFSpace.sm3) {
                    // Hero: 3D 모델 — **Phase G11 (2026-05-15)**: pose 가 보행 cycle 마다 갱신.
                    // 실 로봇 송출 중: `runContinuousWalk` 의 onPose 가 매 step 마다 visualPose publish.
                    // sim mode: 50ms tick 이 phase 따라 합성 pose publish.
                    // footTrace 는 좌측 발 자취 (2D 캔버스와 동일 source).
                    RobotScene3D(
                        pose: session.visualPose,
                        footTrace: session.footTrail.map { $0.left },
                        // v1.11.18: 실시간 IMU 기반 robot 기울기 반영.
                        imuRollDeg: session.imuRollDeg,
                        imuPitchDeg: session.imuPitchDeg
                    )
                    .frame(minHeight: 360, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.card)
                            .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
                    )
                    .overlay(alignment: .topLeading) {
                        // v1.11: 빈 영역 시각 채움 — walking phase / elapsed / 보정 Δ.
                        sceneInfoOverlay
                            .padding(DFSpace.sm)
                    }
                    // v1.11.18 사용자 요청: 좌하단 자이로 mini + 우하단 walking 그래프.
                    .overlay(alignment: .bottomLeading) {
                        SceneGyroMiniOverlay()
                            .padding(DFSpace.sm)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        SceneWalkGraphOverlay()
                            .padding(DFSpace.sm)
                    }

                    // 사이드 패널: 2D 발자취 (top-down) + IMU 게이지 2개.
                    VStack(spacing: DFSpace.sm2) {
                        FootTrailCanvas(trail: session.footTrail,
                                        leftFoot: session.leftFoot,
                                        rightFoot: session.rightFoot)
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
                            .overlay(
                                RoundedRectangle(cornerRadius: DFRadius.button)
                                    .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
                            )
                        // **Stage 1 (v1.1 fall prevention)**: 실 IMU 출처 라벨 표시.
                        HStack(spacing: DFSpace.xs) {
                            Circle()
                                .fill(imuSourceColor)
                                .frame(width: DFSize.indicatorXxs,
                                       height: DFSize.indicatorXxs)
                            Text("IMU 출처: \(session.imuSource.label)")
                                .font(DFFont.monoLabel)
                                .foregroundStyle(DFColor.textSecondary)
                            Spacer()
                        }
                        // **Stage 2 (v1.1 fall prevention)**: 안전 상태 + 자동 보정 토글.
                        balanceStateCard
                        // **Stage 5 (v1.1 fall prevention)**: 예측 score + ETA.
                        FallPredictionCard(prediction: session.fallPrediction,
                                           imuSource: session.imuSource)
                        // **Stage 4 (v1.1 fall prevention)**: balance correction 토글 + delta 미리보기.
                        balanceCorrectionCard
                        IMUGauge(axis: "Roll", degrees: session.imuRollDeg, dangerThreshold: 50)
                        IMUGauge(axis: "Pitch", degrees: session.imuPitchDeg, dangerThreshold: 50)
                    }
                    // v1.11 재작업: 고정 280 → 가변 (좁은 화면 260, 와이드 모니터 340 까지).
                    // SwiftUI 가 hero scene 과 사이드 패널 사이 공간 분배 시 자연스러운 호흡.
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)
                }
                .frame(minHeight: 360)

                footTargetsCard

                actionBar
            }
            .padding(DFSpace.md)
        }
    }

    // 2026-05-16: 가로 `monitoringToggleBar` private var (~75 line) 제거 — 좌측
    // 세로 `collapsedMonitoringStripe` / `monitoringSidebar` 헤더 toggle 로 통합.
    // dead code (호출처 0).

    private var monitorBadgeColor: Color {
        switch session.balanceState {
        case .normal:    return DFColor.success
        case .caution:   return DFColor.warning
        case .warning:   return DFColor.severe
        case .danger, .emergency: return DFColor.danger
        }
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
                    .font(DFFont.sectionBody)
                Text(detail)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, DFSpace.sm2)
        .padding(.vertical, DFSpace.xs2)
        .background(tint.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(tint.opacity(DFOpacity.o30), lineWidth: DFSize.borderStrong)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
    }

    private func banner(systemImage: String, message: String, tint: Color) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: systemImage)
                .font(DFFont.sectionSmall)
            Text(message)
                .font(DFFont.bodyEmph)
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
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
    }

    /// **2026-05-16 검증**: 좁은 detail 폭 (480pt) 에서 HStack 컬럼 5개 + Spacer +
    /// 다이버 2개 = ~540pt content > 460pt available → 잠재 overflow.
    /// 해결: 컬럼 자체 `.lineLimit(1)` + monospace text 가 자동 truncate.
    /// 추가 보호: `.fixedSize(horizontal: false, vertical: true)` 명시 — wrap
    /// 회피 + Spacer 우측 정렬 보장.
    private var footTargetsCard: some View {
        HStack(spacing: DFSpace.md - 2) {
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("Phase").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(session.phaseLabel)
                    .font(DFFont.monoBody)
                    .lineLimit(1)
            }
            Divider().frame(height: DFSpace.xl)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("L (x,y,z)").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(fmt3(session.leftFoot))
                    .font(DFFont.mono)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("R (x,y,z)").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(fmt3(session.rightFoot))
                    .font(DFFont.mono)
                    .lineLimit(1)
            }
            Divider().frame(height: DFSpace.xl)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("Temp").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(String(format: "%.1f°C", session.maxMotorTemp))
                    .font(DFFont.mono)
                    .foregroundStyle(tempColor)
                    .lineLimit(1)
            }
            Spacer(minLength: DFSpace.xs)
            VStack(alignment: .trailing, spacing: DFSpace.micro2) {
                Text("Elapsed").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text("\(session.elapsedMs) ms")
                    .font(DFFont.mono)
                    .lineLimit(1)
            }
        }
        .padding(DFSpace.sm2)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
        .fixedSize(horizontal: false, vertical: true)
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
        case .real:  return DFColor.success
        case .stale: return DFColor.warning
        }
    }

    /// **v1.11 (2026-05-17 사용자 요청) — 3D scene 좌상단 floating chip**:
    /// 빈 영역 시각 채움 + 정보 가치 추가. **항상 표시** (idle 도 안내):
    /// - idle 시: 보행 대기 안내 + walk_ready 자세 표기
    /// - walking 시: preset / cycle phase progress / 보정 Δ
    private var sceneInfoOverlay: some View {
        let isWalking = session.current != .idle
        return VStack(alignment: .leading, spacing: 4) {
            // 1행: preset 또는 idle 안내
            HStack(spacing: 6) {
                Image(systemName: isWalking ? "figure.walk.motion" : "figure.stand")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isWalking ? DFColor.accent : DFColor.textSecondary)
                Text(isWalking ? session.current.label : "보행 대기 · walk_ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DFColor.textPrimary)
            }
            // 2행: walking 시 cycle phase, idle 시 안내 부제
            if isWalking,
               let elapsedMs = session.lastWalkCycleElapsedMs,
               let periodMs = session.lastWalkPeriodMs,
               periodMs > 0 {
                HStack(spacing: 6) {
                    Text(String(format: "%.0f/%.0fms", elapsedMs, periodMs))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DFColor.textSecondary.opacity(DFOpacity.o20))
                            Capsule().fill(DFColor.accent)
                                .frame(width: geo.size.width
                                       * CGFloat(min(1, elapsedMs / periodMs)))
                        }
                    }
                    .frame(width: 60, height: 3)
                }
            } else if !isWalking {
                Text("프리셋을 시작하면 cycle phase 표시")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.textSecondary)
            }
            // 3행: 보정 status — 항상 표시 (config mode 인지)
            HStack(spacing: 6) {
                let modeIcon: String = {
                    switch session.balanceExperimentConfig.algorithmMode {
                    case .off:             return "power.circle"
                    case .robotisPControl: return "shield.fill"
                    case .hybridBA:        return "brain"
                    case .observeOnly:     return "eye.fill"
                    }
                }()
                let modeColor: Color = {
                    switch session.balanceExperimentConfig.algorithmMode {
                    case .off:             return DFColor.textSecondary
                    case .robotisPControl: return DFColor.success
                    case .hybridBA:        return DFColor.warning
                    case .observeOnly:     return DFColor.info
                    }
                }()
                Image(systemName: modeIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(modeColor)
                if let delta = session.lastCorrections?.maxAbs, delta > 0.01 {
                    Text(String(format: "Δ%.1f° %@",
                                delta,
                                session.lastCorrectionApplied ? "적용" : "관찰"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text(session.balanceExperimentConfig.algorithmMode.label)
                        .font(.system(size: 10))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o15),
                        lineWidth: DFSize.borderHairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isWalking ? "보행 \(session.current.label) 진행 중" : "보행 대기")
    }

    /// **Stage 2 (v1.1 fall prevention)**: 안전 상태 카드 + 자동 보정 토글.
    /// 2026-05-16: design system 토큰화 완료 (raw 4/6/8/0.10/0.4/0.5 → DFSpace/DFOpacity/DFSize).
    private var balanceStateCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: balanceStateIcon)
                    .font(DFFont.bodySmall)
                    .foregroundStyle(balanceStateColor)
                Text("안전 상태: \(session.balanceState.label)")
                    .font(DFFont.captionEmph)
                    .foregroundStyle(balanceStateColor)
                    .lineLimit(1)
                Spacer()
            }
            if session.balanceState >= .warning {
                Text(balanceStateMessage)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("자동 균형 보정", isOn: $session.autoFallPrevention)
                .toggleStyle(.checkbox)
                .font(DFFont.label)
                .help("기울기 임계 도달 시 자동 감속/동결 — OFF 시 30° emergency 만 작동")
        }
        .padding(DFSpace.sm)
        .background(balanceStateColor.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(balanceStateColor.opacity(DFOpacity.o40),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("안전 상태 카드 — \(session.balanceState.label)")
    }

    private var balanceStateIcon: String {
        switch session.balanceState {
        case .normal:    return "checkmark.circle.fill"
        case .caution:   return "exclamationmark.circle"
        case .warning:   return "exclamationmark.triangle.fill"
        case .danger:    return "exclamationmark.octagon.fill"
        case .emergency: return "xmark.octagon.fill"
        }
    }

    private var balanceStateColor: Color {
        switch session.balanceState {
        case .normal:    return DFColor.success
        case .caution:   return DFColor.warning
        case .warning:   return DFColor.severe
        case .danger:    return DFColor.danger
        case .emergency: return DFColor.danger
        }
    }

    private var balanceStateMessage: String {
        switch session.balanceState {
        case .warning:   return "기울기 22°+ — 보행 속도 70% 자동 감속"
        case .danger:    return "기울기 28°+ — 자세 동결 (보행 일시 정지)"
        case .emergency: return "기울기 30°+ — 토크 OFF + walkReady 복귀"
        default:         return ""
        }
    }

    /// **Stage 4 (v1.1 fall prevention)**: balance correction 토글 + delta 미리보기.
    /// 2026-05-16: design system 토큰화 완료.
    private var balanceCorrectionCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "figure.balanced")
                    .font(DFFont.bodySmall)
                    .foregroundStyle(session.enableBalanceCorrection
                                     ? DFColor.success
                                     : DFColor.textSecondary)
                Toggle("자세 보정 (실험)", isOn: $session.enableBalanceCorrection)
                    .toggleStyle(.checkbox)
                    .font(DFFont.label)
                    .help(session.enableBalanceCorrection
                          ? "현재 ON — Walking.cpp sensoryFeedback 패턴 적용 중. 1초 ramp."
                          : "ROBOTIS Walking.cpp 패턴 corrector — 실 robot 검증 후 활성 권장")
                Spacer()
            }
            if session.enableBalanceCorrection {
                if let c = session.lastCorrections {
                    HStack(spacing: DFSpace.xs) {
                        Text(String(format: "hipRoll %+.1f°", c.rHipRoll))
                            .font(DFFont.monoLabel)
                        Text(String(format: "knee %+.1f°", c.rKnee))
                            .font(DFFont.monoLabel)
                    }
                    .foregroundStyle(DFColor.textSecondary)
                    HStack(spacing: DFSpace.xs) {
                        Text(String(format: "ankP %+.1f°", c.rAnklePitch))
                            .font(DFFont.monoLabel)
                        Text(String(format: "ankR %+.1f°", c.rAnkleRoll))
                            .font(DFFont.monoLabel)
                    }
                    .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text("ROBOTIS Walking.cpp::sensoryFeedback 패턴 (gain 0.5/0.3/1.0/0.9)")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                }
            } else {
                Text("기본 OFF — 실 robot 검증 + Codex audit 후 활성화 권장")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.textSecondary.opacity(DFOpacity.ghost))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o25),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.enableBalanceCorrection
            ? "자세 보정 ON — 최대 보정 \(String(format: "%.1f", session.lastCorrections?.maxAbs ?? 0))°"
            : "자세 보정 OFF")
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

                Spacer(minLength: DFSpace.xs)

                connectionPill
                    .layoutPriority(1)

                Text(session.cradleConfirmed
                     ? "정비 스탠드 거치 ✓"
                     : "↑ 사이드바에서 스탠드 거치를 먼저 확인하세요")
                    .font(DFFont.caption)
                    .foregroundStyle(session.cradleConfirmed ? DFColor.success : DFColor.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let evt = session.lastRobotEvent {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(DFFont.label)
                    Text(evt)
                        .font(DFFont.monoCaption)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
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
            Text(label).font(DFFont.label)
        }
        .padding(.horizontal, DFSpace.xs2).padding(.vertical, DFSpace.micro2)
        .background(Capsule().fill(dotColor.opacity(DFOpacity.subtle)))
    }

    // MARK: - Risk confirm sheet

    private var riskConfirmSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md - 2) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DFFont.modalHeader)
                    .foregroundStyle(DFColor.danger)
                Text("위험한 보행 모드")
                    .font(DFFont.modalHero)
            }
            if let warning = pendingHighRiskPreset?.warning {
                Text(warning)
                    .font(DFFont.body)
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
