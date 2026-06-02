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
/// - L3: live IMU |roll/pitch| > 50° → 자동 stop
/// - L4: 모터 max 온도 60°C 도달 → 자동 stop
public struct WalkLabView: View {
    @EnvironmentObject private var store: ConnectionStore
    // **v1.11.14 (2026-05-19)**: RootView hoisted session — WalkDataView 의 실험 승인이
    // 동일 인스턴스를 변경하도록 EnvironmentObject 로 변경. 종전 @StateObject 시
    // WalkDataView 가 별도 session 인스턴스를 못 봐 applyExperimentChange 의 부작용
    // 단절. 라이프사이클은 RootView 가 관리.
    @Environment(WalkLabSession.self) private var session
    /// **사이클 73 (2026-05-22) 코덱스 HIGH-2 fix** — Tello listener owner reference.
    /// RootView 가 `.environment(telloStateOwner)` 로 전파. nil 가능 (bridge 미alloc).
    /// TelloPilotHud 가 status banner 표시 + "활성화" 토글 / "다시 시도" 버튼 분기.
    @Environment(TelloStateListenerOwner.self) private var telloStateOwner: TelloStateListenerOwner?
    /// **사이클 86 — PilotSettingsPanel 영속 store**: RootView 가
    /// `.environment(\.pilotPreferencesStore, ...)` 로 전파. PilotSettingsPanel 에 직접 주입.
    @Environment(\.pilotPreferencesStore) private var pilotPreferencesStore
    @State private var showingRiskConfirm: Bool = false
    @State private var pendingHighRiskPreset: WalkLabPreset?
    /// **v1.15.0 (2026-05-21) Phase 1**: trial library sheet 표시 토글.
    @State private var showingTrialLibrary: Bool = false
    /// **v1.20.2 (2026-05-22) 사이클 8**: 조종 panel (keyboard + Tello HUD) overlay 표시.
    /// 기본 off — 사용자가 명시 활성화 시 좌하단 overlay 노출.
    @State private var showingPilotOverlay: Bool = false

    /// **V272-1 (2026-05-24) UI/UX P0 fix**: 안전 정지 배너 dismiss 확인 dialog.
    /// 종전: "닫기" 버튼이 balanceLost/thermalAlarm 을 즉시 false 로 클리어 — 사용자
    /// 실수 클릭 한 번에 안전 가드 해제. HIG `confirmationDialog` 패턴 적용으로
    /// destructive 액션 (안전 플래그 해제) 의 의도 확인 단계 추가.
    @State private var showDismissBalanceLossConfirm: Bool = false

    /// **V280-A (2026-05-24) Progressive Disclosure**: 사이드 패널 "운용 (Run)" 그룹.
    /// FootTrailCanvas / IMU 출처 라벨 / balanceStateCard — 보행 중 항상 참조하는 핵심.
    /// 기본 OPEN (사용자가 한 번 닫으면 다음 세션까지 유지).
    /// Apple HIG "Progressive Disclosure" — 빈도 높은 정보는 default visible.
    @AppStorage("df.walklab.expandedRunGroup") private var expandedRunGroup: Bool = true

    /// **V280-A (2026-05-24)**: 사이드 패널 "진단 (Diagnostics)" 그룹.
    /// FallPredictionCard / balanceCorrectionCard / IMU Roll·Pitch — 분석 시 필요.
    /// 기본 CLOSED — IBM Carbon information architecture: secondary 정보는 on demand.
    @AppStorage("df.walklab.expandedDiagGroup") private var expandedDiagGroup: Bool = false

    /// **V280-A (2026-05-24)**: 3D Scene overlay 4 종 (Speedometer / GyroMini / WalkGraph /
    /// 차단 사유 banner) 표시 토글. 기본 OFF — Nielsen #8 "minimalist".
    /// scene 내부의 sceneInfoOverlay (좌상단 phase/preset) 는 항상 표시 (minimal HUD).
    @AppStorage("df.walklab.showSceneOverlays") private var showSceneOverlays: Bool = false

    /// **V280-A (2026-05-24)**: 보조 정보 (LiveGyroPanel + simOnlyNotice + footTargetsCard).
    /// 기본 CLOSED — Hick's Law: 핵심 의사결정 화면에서 부수 정보 분리.
    @AppStorage("df.walklab.expandedAuxInfo") private var expandedAuxInfo: Bool = false

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
        // **v1.20.2 (2026-05-22) 사이클 8** — Pilot overlay (Keyboard + Tello HUD).
        // 사용자가 sidebar header 의 🎮 버튼으로 toggle. 좌하단 floating panel.
        .overlay(alignment: .bottomLeading) {
            if showingPilotOverlay {
                pilotOverlay
                    .padding(DFSpace.md)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingRiskConfirm) {
            riskConfirmSheet
        }
        // **v1.15.0 (2026-05-21) Phase 1**: Trial 종료 시 라벨 sheet 자동 표시.
        // WalkLabSession.pendingLabelTrial 이 nil 이 아니면 sheet open.
        // 사용자가 별점 + tag + free text 입력 후 저장 또는 건너뛰기.
        .sheet(item: Binding(
            get: { session.pendingLabelTrial },
            set: { session.pendingLabelTrial = $0 }
        )) { trial in
            WalkTrialLabelSheet(
                trial: trial,
                onSave: { label in
                    WalkTrialStore.shared.updateLabel(id: trial.id, label: label)
                },
                onSkip: nil
            )
        }
        // **v1.15.0 (2026-05-21) Phase 1**: 저장된 trial 탐색 sheet.
        // **v1.16.0.1 (2026-05-21) Phase 2 C1 fix (code-reviewer CRITICAL)**:
        // SwiftUI sheet 는 parent 의 @Environment(WalkLabSession.self) 자동 inject 안 함.
        // TrialDetailView 가 applyRecommendation 시 session env 필요 → runtime trap 차단.
        .sheet(isPresented: $showingTrialLibrary) {
            NavigationStack {
                WalkTrialLibraryView()
                    .environment(session)  // C1 fix — sheet 에 session 명시 inject.
                    .frame(minWidth: 800, minHeight: 600)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            // 사이클 138 (audit #24 codex sweep)
                            Button("닫기", role: .cancel) { showingTrialLibrary = false }
                        }
                    }
            }
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
        // **v1.14.9 (2026-05-21) Fix #7**: @Observable session — local @Bindable re-bind 으로 $session.foo 활성화.
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: DFSpace.none) {
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
                        // v1.11.24 audit P0-2/P0-3 — 차단 사유 미리 평가해서 버튼 상태/사유 노출.
                        let blocking = presetBlockingReason(for: preset)
                        // v1.11.24 audit iter2-J — active 표시는 실 motor task 가 진행 중인 preset
                        // 우선 (activeRobotPreset). robot 미연결 (sim) 일 땐 fallback 으로 current.
                        let activePreset = session.activeRobotPreset ?? session.current
                        // **v1.14.6 (2026-05-21)** — 시뮬 모드 (bus 미연결) 에선 cradle 검사
                        // 강제 안 함 → 모든 preset 활성. 실 로봇 연결 시에만 cradle 강제.
                        let buttonEnabled = (store.bus == nil) || session.cradleConfirmed
                        PresetButton(
                            preset: preset,
                            isActive: activePreset == preset,
                            isEnabled: buttonEnabled,
                            blockingReason: blocking.reason,
                            onUnblock: blocking.unblock
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

                    // v1.11.25 audit log-B — operatorNote 입력 UI.
                    // 종전: WalkLabSession.operatorNote 변수만 존재, 입력 경로 없음 → header
                    // 에 항상 nil 기록. 본 TextField 가 next session start 시 header.operatorNoteAtStart
                    // 로 영구 저장. 사용자가 "표면 미끄러움 / 배터리 막 충전" 같은 맥락 메모.
                    operatorNoteField
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
            // **v1.20.2 (2026-05-22) 사이클 8**: Pilot overlay 토글 — keyboard + Tello HUD.
            Button(action: {
                withAnimation(DFAnimation.toggle) { showingPilotOverlay.toggle() }
            }) {
                Image(systemName: showingPilotOverlay ? "gamecontroller.fill" : "gamecontroller")
                    .font(DFFont.body)
                    .foregroundStyle(showingPilotOverlay ? DFColor.accent : DFColor.textPrimary)
            }
            .buttonStyle(.borderless)
            .help("키보드 / Tello 조종 panel 표시 (WASD/QE/Space)")
            .accessibilityLabel(showingPilotOverlay ? "파일럿 조종 패널 숨기기" : "파일럿 조종 패널 표시")
            // **v1.15.0 (2026-05-21) Phase 1**: trial library 진입점.
            // 저장된 모든 walk trial 검색/탐색/라벨링 sheet 표시.
            Button(action: { showingTrialLibrary = true }) {
                Image(systemName: "books.vertical.fill")
                    .font(DFFont.body)
            }
            .buttonStyle(.borderless)
            .help("저장된 보행 기록 보기 (Trial Library)")
            .accessibilityLabel("저장된 보행 기록 보기")
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm3)
    }

    // MARK: - Pilot overlay (Cycle 8)

    /// **v1.20.2 사이클 8** — keyboard + Tello HUD 좌하단 overlay.
    /// `session.pilotBridge` 가 nil 이면 안내 메시지 만 표시.
    @ViewBuilder
    private var pilotOverlay: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: 4) {
                Image(systemName: "gamecontroller.fill")
                    .font(.caption)
                    .foregroundStyle(DFColor.accent)
                Text("Pilot 조종")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(action: {
                    withAnimation(DFAnimation.toggle) { showingPilotOverlay = false }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("닫기")
                .accessibilityLabel("파일럿 오버레이 닫기")
            }
            if let bridge = session.pilotBridge {
                // **사이클 78**: Pilot HQ 통합 status row — 5 panel 위에 한 줄 요약.
                // (emergency / active source / event rate / bridge enabled) glanceable.
                PilotHQStatusRow(bridge: bridge, session: session)
                KeyboardPilotPanel()
                // **사이클 73**: owner reference 전달 — HUD 가 silent fail 시
                // banner 표시 + 사용자가 "Tello 활성화" / "다시 시도" 클릭 가능.
                TelloPilotHud(bridge: bridge, listenerOwner: telloStateOwner)
                // **v1.20.45 사이클 59-ui** — input → engine latency 시각화.
                // critic 지적 응답: 측정 + UI 노출까지가 "game character" 정량 기준 close-loop.
                PilotLatencyPanel(bridge: bridge)
                // **v1.22.0 (2026-05-22) Phase 5** — 음성 조종 panel.
                // 마이크 권한은 사용자 명시 토글 시점에만 요청 (자동 start 금지).
                VoicePilotPanel(bridge: bridge)
                // **v1.21.1 (2026-05-22)** — GamepadPilotAdapter UI wire-up.
                // PS4/Xbox 등 GCExtendedGamepad 호환 컨트롤러 즉시 사용 가능.
                GamepadPilotPanel(bridge: bridge)
                // 마우스 드래그 가상 조이스틱 — 외부 컨트롤러 없이도 즉시 조종 가능.
                // iOS RemotePilotScreen 과 동일 의미의 stick → WalkingCommand 매핑.
                VirtualJoystickPilotPanel(bridge: bridge)
                // **사이클 86 (2026-05-22)** — 4 차원 종합 감도 + smoothing 설정 panel.
                // 슬라이더 → bridge 즉시 preview, "저장" 클릭 → UserDefaults 영속.
                // KeyboardPilotPanel 의 1축 multiplier 와 직교 — 정밀 절대값 조정 채널.
                PilotSettingsPanel(bridge: bridge, store: pilotPreferencesStore)
            } else {
                Text("Pilot bridge 미연결 — RootView onAppear 가 wiring 못함")
                    .font(.caption2)
                    .foregroundStyle(DFColor.textSecondary)
                    .padding(8)
                    .background(DFColor.warning.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
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
        // **V281-1 (2026-05-24)**: 좌측 모니터링 column 3 view (expandedSidebar,
        // dragHandle, collapsedStripe) 와 패널 너비 state (@AppStorage + 2 @State)
        // 를 `WalkLabMonitoringColumn` sub-file 로 추출 (Fowler "Extract Class").
        HStack(alignment: .top, spacing: DFSpace.none) {
            WalkLabMonitoringColumn()
            mainDetailContent
        }
    }

    /// **V280-A (2026-05-24) — Progressive Disclosure 재설계**.
    ///
    /// 종전 (v1.11.17 ~ V278): 한 화면에 15 항목 (LiveGyroPanel + simOnlyNotice + 3 banner
    /// + RobotScene3D + 4 overlay + FootTrailCanvas + balanceStateCard + FallPredictionCard
    /// + balanceCorrectionCard + IMU×2 + footTargetsCard + actionBar) → 5±2 (Miller's Law)
    /// 3배 초과, 신규 사용자 첫 30초 압도감 유발 (V278-2 audit P0).
    ///
    /// 신규 분류 (Apple HIG "Progressive Disclosure" + IBM Carbon IA):
    /// - **Primary** (항상): Hero scene + sceneInfoOverlay (최소 HUD) + actionBar + 최우선 banner 1개
    /// - **Secondary**: 사이드 카드 2 그룹 (`runGroup` 기본 OPEN / `diagGroup` 기본 CLOSED)
    /// - **Tertiary** (advanced 토글): 4 scene overlay + 보조 정보 group (LiveGyroPanel +
    ///   simOnlyNotice + footTargetsCard)
    ///
    /// 결과: default 노출 항목 15 → 5 (heroRow + side group×2 + actionBar + banner). 5±2 적합.
    private var mainDetailContent: some View {
        // V284 재설계 (2026-05-24) — 사용자 피드백: 하단 영역 화면 밖 사라짐.
        //
        // # 책임 분할 (전체 사용 가능 세로 H):
        //   • banner    : 조건부 ~44px (없으면 0)
        //   • heroRow   : H - footerHeight - banner - padding (남는 공간 모두)
        //   • footer    : 고정 324px (auxInfoDisclosure + actionBar + 로그/알림)
        //
        // # 반응형:
        //   - 큰 화면 (H ≥ 924): heroRow 600+ / footer 324 / 잘 맞음
        //   - 일반 화면 (H = 800): heroRow 400 / footer 324 / 잘 맞음
        //   - 작은 화면 (H < 724): GeometryReader 가 minHeight 400 보장 → fallback ScrollView
        //
        // GeometryReader 로 전체화면 동작 + 작은 화면 자동 대응.
        GeometryReader { geo in
            let footerHeight: CGFloat = 324
            let availableHeroH = max(400, geo.size.height - footerHeight - 24)
            VStack(spacing: DFSpace.xs) {
                primaryBanner
                heroRow
                    .frame(height: availableHeroH)
                VStack(spacing: DFSpace.xs) {
                    auxInfoDisclosure
                    actionBar
                }
                .frame(height: footerHeight)
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs)
        }
    }

    /// **V280-A**: Primary banner 영역 — 활성 안전 신호 최우선 1개만 표시.
    /// 우선순위: thermalAlarm > balanceLost > advanced critical.
    /// 동시 다발 banner 가 화면을 점유하는 종전 패턴 차단 (Hick's Law).
    @ViewBuilder
    private var primaryBanner: some View {
        if session.thermalAlarm {
            banner(systemImage: "thermometer.sun.fill",
                   message: "모터 60°C 도달 — 자동 정지됨. 배터리를 분리해 주세요",
                   tint: DFColor.danger)
        } else if session.balanceLost {
            banner(systemImage: "exclamationmark.triangle.fill",
                   message: "균형 잃음 감지 — 자동 정지됨",
                   tint: DFColor.danger)
        } else if session.advanced && session.stabilityScore.category == .critical {
            // 2026-05-17 UX audit: 이중부정 "해제를 끄세요" → "다시 잠그세요" 직관화.
            banner(systemImage: "xmark.octagon.fill",
                   message: "위험도 \(Int(session.stabilityScore.score))/100 — 시작 차단됨. 슬라이더를 줄이거나 '안전 한도 해제'를 다시 잠그세요.",
                   tint: DFColor.danger)
        }
    }

    /// **V280-A**: Hero row — 3D scene (Primary) + 사이드 카드 그룹 2개 (Secondary).
    ///
    /// **V281-1 (2026-05-24)**: 1427 LOC god view 분리. 종전 inline heroScene +
    /// heroSidePanel 을 sub-file (`WalkLabSceneSection` / `WalkLabSidePanelSection`)
    /// 로 추출. behavior 0 변경 (Fowler "Extract Class").
    private var heroRow: some View {
        HStack(spacing: DFSpace.xs) {
            WalkLabSceneSection(
                showSceneOverlays: $showSceneOverlays,
                blockingReasons: uniqueBlockingReasons()
            )
            WalkLabSidePanelSection(
                expandedRunGroup: $expandedRunGroup,
                expandedDiagGroup: $expandedDiagGroup
            )
                // V284 (2026-05-24) — 사용자 요청 "3D 뷰 비율이 너무 작고 비효율적".
                // 종전 maxWidth 340 → 260 으로 축소. side panel 은 secondary, scene 이 primary.
                // 가로 절약분 = 3D scene 으로 흡수 (모델링 영역 +80px).
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
        }
        // V284 재설계 (2026-05-24) — 부모 mainDetailContent 의 GeometryReader 가 명시
        // height 부여 (availableHeroH = 화면 - footer 324 - padding). 본 frame 는
        // minHeight 만 유지하여 작은 화면 fallback 보장 (400px 미달 차단).
        .frame(minHeight: 400)
    }

    /// **V280-A**: Tertiary disclosure — LiveGyroPanel + simOnlyNotice + footTargetsCard.
    /// 기본 CLOSED. 신규 사용자 첫 30초 시야 정리 (Nielsen #8 minimalist).
    ///
    /// **V281-1 (2026-05-24)**: 본문은 `WalkLabAuxSection` sub-file 로 분리.
    private var auxInfoDisclosure: some View {
        WalkLabAuxSection(expandedAuxInfo: $expandedAuxInfo)
    }

    // 2026-05-16: 가로 `monitoringToggleBar` private var (~75 line) 제거 — 좌측
    // 세로 `collapsedMonitoringStripe` / `monitoringSidebar` 헤더 toggle 로 통합.
    // dead code (호출처 0).

    private func banner(systemImage: String, message: String, tint: Color) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: systemImage)
                .font(DFFont.sectionSmall)
            Text(message)
                .font(DFFont.bodyEmph)
            Spacer()
            // 사이클 138 (audit #24 codex sweep) — V272-1 (2026-05-24): 즉시 해제 →
            // confirmationDialog 게이트. 실수 클릭으로 안전 가드 해제 방지 (Nielsen
            // heuristic #5 error prevention).
            Button("닫기", role: .cancel) {
                showDismissBalanceLossConfirm = true
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, DFSpace.sm3)
        .padding(.vertical, DFSpace.sm)
        .background(tint.opacity(DFOpacity.o18))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
        .confirmationDialog(
            "안전 경고 해제",
            isPresented: $showDismissBalanceLossConfirm,
            titleVisibility: .visible
        ) {
            Button("해제하고 계속 진행", role: .destructive) {
                session.balanceLost = false
                session.thermalAlarm = false
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("자동 안전 정지가 활성됐습니다. 정말 해제하시겠습니까? 로봇 상태를 확인한 후 진행하세요.")
        }
    }

    // **V281-1 (2026-05-24)**: 다음 사항이 sub-file 로 추출 (Fowler "Extract Class"):
    // - `footTargetsCard`, `tempColor`, `fmt3` → `WalkLabAuxSection.swift`
    // - `imuSourceColor`, `balanceStateCard`, `balanceState{Icon,Color,Message}`,
    //   `balanceCorrectionCard` → `WalkLabSidePanelSection.swift`
    // - `sceneInfoOverlay`, `freshnessBadge`, `walkGuidanceBanner` → `WalkLabSceneSection.swift`
    // 본 view 는 banner / actionBar / lifecycle / sidebar 만 책임.

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
        // **v1.14.9 (2026-05-21) Fix #7**: @Observable session — local @Bindable.
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: DFSpace.md - 2) {
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
        // **v1.14.7 (2026-05-21)** — 시뮬 모드 (bus 미연결) 면 cradle 검사 skip.
        // 종전: cradle 미확인 시 tap() 첫 줄에서 return → 위험 동의 dialog 도 안 뜸.
        let needsCradle = (store.bus != nil)
        guard !needsCradle || session.cradleConfirmed || preset == .idle else { return }
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
        // v1.11.24 audit iter2-C — slider 동기화는 session.start() 가 preflight 통과 후 내부에서 수행.
        // 종전: tap() 가 직접 호출 → start() 가 차단되어도 slider 만 바뀌는 UX 불일치.
        session.start(preset)
    }

    /// v1.11.24 audit P0-2/P0-3 — 버튼 클릭 전에 미리 차단 사유 평가.
    /// 사용자가 클릭하기 전에 "왜 이 버튼이 비활성인지" UI 에 표시 (PresetButton.blockingReason).
    ///
    /// 반환:
    /// - `reason` nil = 차단 없음 (정상 활성)
    /// - `reason` 문자열 = 사용자에게 표시할 이유
    /// - `unblock` closure 가 있으면 inline action 으로 해소 시도 (예: 자세 보정 ON)
    ///
    /// 이 사전 평가는 `WalkLabSession.quickPreflight` 의 subset 이지만 UI 만 표시 — 실 차단은
    /// session 의 preflight 가 마지막에 한 번 더 검증.
    ///
    /// **V281-1 (2026-05-24)**: `walkGuidanceBanner` 본체는 `WalkLabSceneSection` 으로 이전.
    /// 본 함수의 결과 (`uniqueBlockingReasons`) 를 `heroRow` 가 sub-view 에 주입.
    /// 본 함수는 sidebar `PresetButton.blockingReason` 도 사용 (계산 책임 유지).

    /// preset 별 차단 사유 모아서 unique 리스트 반환.
    private func uniqueBlockingReasons() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for preset in WalkLabPreset.allCases where preset != .idle {
            if let r = presetBlockingReason(for: preset).reason, !seen.contains(r) {
                seen.insert(r)
                ordered.append(r)
            }
        }
        return ordered
    }

    private func presetBlockingReason(for preset: WalkLabPreset) -> (reason: String?, unblock: (() -> Void)?) {
        // idle 은 정지 버튼이므로 차단 안 함.
        if preset == .idle { return (nil, nil) }
        // **v1.14.6 (2026-05-21)** — 시뮬 모드 (bus 미연결) 면 cradle 검사 skip.
        // 사용자가 실 로봇 없이도 보행 알고리즘 / preset 동작을 미리 확인 가능.
        // 실 로봇 연결 시에만 cradle 강제 — 안전.
        if store.bus != nil && !session.cradleConfirmed {
            return ("정비 스탠드에 거치 후 활성화", nil)
        }
        // 보행 중 → 다른 non-idle preset 비활성 (이미 walking 표시는 active 별도).
        if session.isWalkActive && session.current != preset {
            let activeLabel = session.activeRobotPreset?.label ?? session.current.label
            return ("'\(activeLabel)' 진행 중 — 정지 후 변경", nil)
        }
        // caution preset 인데 자세 보정 OFF → 차단 + 한 번에 켜는 unblock 제공.
        if preset.safety == .caution && !session.enableBalanceCorrection {
            return ("자세 보정 OFF — 켜야 시작 가능", { session.enableBalanceCorrection = true })
        }
        // advanced + stability critical → 차단.
        if session.advanced && session.stabilityScore.category == .critical {
            return ("고급 슬라이더 위험도 critical — 조합 점검", nil)
        }
        // high risk preset → risk 동의 안 됐으면 안내만 (실 차단은 risk sheet 가 처리).
        if preset.requiresRiskConfirmation && !session.riskAcknowledged {
            return ("위험 동의 필요 — 클릭 후 확인", nil)
        }
        return (nil, nil)
    }

    /// v1.11.25 audit log-B — operatorNote 1줄 TextField.
    /// 사용자가 "표면 / 배터리 / 환경" 같은 세션 맥락 메모 입력 → 다음 보행 시작 시
    /// header.operatorNoteAtStart 로 영구 저장. 분석가가 retrospective 시 활용.
    private var operatorNoteField: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro) {
            Text("운영자 메모 (다음 보행 헤더에 저장)")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, DFSpace.sm)
            TextField(
                "예: '두꺼운 카펫, 배터리 11.2V'",
                text: Binding(
                    get: { session.operatorNote ?? "" },
                    set: { session.operatorNote = $0.isEmpty ? nil : $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(DFFont.bodySmall)
            .padding(.horizontal, DFSpace.sm)
        }
        .padding(.top, DFSpace.xs)
    }
}
