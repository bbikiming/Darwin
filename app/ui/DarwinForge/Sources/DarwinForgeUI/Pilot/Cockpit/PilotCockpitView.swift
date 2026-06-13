import AppKit
import ForgeCore
import SwiftUI

/// FPV 드론 시뮬레이터 스타일의 **조종 시뮬** 화면 — 사이드바 ⌘9 진입점.
///
/// # 레이아웃
///
/// ```
/// ┌──────────────── 배경: 짙은 navy / matte black ────────────────┐
/// │ [Status block]                          [Attitude indicator] │
/// │                                                              │
/// │                  ┌──────────────┐                            │
/// │                  │  RobotScene3D│                            │
/// │                  │  3인칭 locked│                            │
/// │                  └──────────────┘                            │
/// │                                                              │
/// │   [Stick L]    [Command readout · ×scale]      [Stick R]    │
/// │   [E-STOP ]                                    [RECOVER]    │
/// └──────────────────────────────────────────────────────────────┘
/// ```
///
/// # 입력 합류
///
/// - 마우스 드래그 가상 조이스틱 (좌 = 이동, 우 = 회전)
/// - GameController.framework (Xbox / DualSense / DJI RC MFi)
/// - 키보드: WASD = 이동, QE = 회전, Space = 긴급정지, R = 복구
///
/// 모든 입력은 `CockpitState` 로 합류하므로 HUD 와 가상 조이스틱 thumb 가 동일
/// 데이터를 표시. WalkLab cockpit-MVP 단계에서는 실 모터 dispatch 없이 입력
/// 시각화에 집중 (후속에서 `WalkLabRCBridge` 합류 예정).
/// **macOS HIG 기반 cockpit layout 결정**.
///
/// detail view 의 실제 사용 가능 width 만으로 column 폭 / scene inset / outer
/// padding 을 일관되게 계산. NavigationSplitView 가 sidebar 옆 영역만 detail
/// 에 할당하므로 본 width 가 cockpit 의 안전 영역.
///
/// # Breakpoints (Apple HIG + macOS Big Sur 이후 Window 표준)
///
/// - **compact** (< 720pt): 매우 좁음. 좌측 column 1개만 (ScrollView), 우측 panel
///   들은 좌측 column 안에 stack. drone 시뮬레이션 게임의 mobile/portrait fallback.
/// - **snug** (720~1099): column 200pt — DJI panel / Status block 텍스트가 1줄에
///   읽히는 최소 폭.
/// - **regular** (1100~1399): column 220pt — 한국어 라벨 + 진단 텍스트 여유.
/// - **roomy** (>= 1400): column 240pt — Studio Display / 외부 모니터.
struct CockpitLayout {
    let width: CGFloat

    init(width: CGFloat) {
        self.width = width
    }

    var isCompact: Bool { width < 720 }

    /// Symmetric outer padding fallback — Spacer 등 일반 사용.
    var outerPadding: CGFloat { width < 1100 ? 16 : 20 }

    /// **좌측 padding > 우측 padding (사용자 보고)**: 사이드바와의 시각 분리
    /// 강화. macOS HIG 의 NavigationSplitView 는 detail edge 가 sidebar 끝점에
    /// 닿으므로, 좌측 panel 을 더 안쪽으로 밀어 sidebar 경계와 명확히 분리.
    var leftPadding: CGFloat { width < 1100 ? 24 : 32 }
    var rightPadding: CGFloat { width < 1100 ? 16 : 20 }
    var topPadding: CGFloat { width < 1100 ? 14 : 18 }
    var bottomPadding: CGFloat { width < 1100 ? 14 : 18 }

    var columnW: CGFloat {
        if width < 720 { return min(width - 32, 280) }
        if width < 1100 { return CockpitMetrics.columnMin }
        if width < 1400 { return 244 }
        return CockpitMetrics.columnMax
    }

    var columnGap: CGFloat { 12 }

    var bottomBarReserve: CGFloat { 180 }
}

@MainActor
public struct PilotCockpitView: View {
    @EnvironmentObject private var store: ConnectionStore
    /// RootView 가 같은 인스턴스를 inject 하므로 WalkLab 탭이 ARM 한 상태 그대로
    /// 본 cockpit 화면에서 명령을 보낼 수 있다.
    @Environment(WalkLabSession.self) private var session
    @StateObject private var cockpit = CockpitState()
    /// **A3** — 유선 재프로브 모니터. 백그라운드 `WalkLabOnboardBridge` 가 ~5s 주기로 tick 해
    /// "유선 전환(166x)" 제안을 갱신하고, 본 view 가 그 `state` 를 읽어 dismissible 배너를 띄운다.
    /// 전환 동작은 배너에서 *주입* 한다(모니터는 host setter 를 보유하지 않음 — probe-and-prompt).
    @StateObject private var reprobeMonitor = WiredReprobeMonitor()
    @EnvironmentObject private var remoteShell: RemoteShell
    @State private var watcher: CockpitGameControllerWatcher?
    @State private var keyboardMonitor: CockpitKeyboardMonitor?
    @FocusState private var keyboardFocused: Bool
    /// **실 모터 dispatch** 사용자 명시 토글 (default OFF — 안전).
    /// ON 일 때만 stick 입력이 `WalkLabSession.pilotApplyAmplitude` 로 흘러 실
    /// motor 에 전달된다. cradle / dxlPower / emergency / bus 조건이 충족돼야
    /// 실제 dispatch 가 일어나며, 미충족 시 화면에 사유를 표시한다.
    @State private var realMotorEnabled: Bool = false

    /// **Phase 2.2 — Auto-DISARM dwell timer (DJI Fly Auto-Arm 방법론)**.
    /// stick zero 가 `autoDisarmDwellSec` 이상 지속되면 walking 자동 정지. 짧은
    /// release (예: W 잠시 떼고 다시 누름) 에 stop 안 함. teardown 시 cancel.
    @State private var autoDisarmTask: Task<Void, Never>?
    /// stick zero hold 시 walking 자동 종료까지의 dwell (초). 너무 짧으면 키 reload
    /// 시 깜빡임, 너무 길면 사용자가 명시 stop 못 함 (E-Stop 따로 있음).
    private let autoDisarmDwellSec: Double = 2.0

    /// **Phase 3 — Round-trip latency 측정**.
    /// stick 입력 시각 → motor write 완료 시각 의 차이 (ms). HUD 표시용.
    @State private var lastDispatchAt: Date?

    /// **머리 모터 write 스로틀** — DJI HID 가 100Hz 로 머리 각도를 갱신할 수 있어,
    /// 매 변화마다 servo write 하면 보행 freeform 과 같은 시리얼 bus 를 두 head 관절
    /// write 로 폭주시킨다. 최소 간격(50ms ⇒ ≤20Hz/관절)으로 제한.
    @State private var lastHeadWriteAt: Date?

    /// **실 robot 테스트 데이터 recorder** — 실 motor 세션의 명령↔자세 pair +
    /// lifecycle 이벤트를 JSONL 로 영속화. setup 시 생성, teardown 시 finalize.
    /// realMotorEnabled 일 때만 dispatch 기록 (= 실 robot 테스트 데이터 집합).
    @State private var recorder: CockpitPilotRecorder?

    /// 통합 「컨트롤러 연결」 시트 — 게임패드 + DJI RC 연결·매핑을 한 곳에서.
    @State private var showControllerSheet: Bool = false

    /// **DJI RC 라이브 경로 소유권 이전** — 종전 `CockpitDJIPanel` 이 watcher 를
    /// 소유했으나, 패널을 통합 시트로 합치면서 본 view 가 소유한다. 시트 개폐와
    /// 무관하게 살아 있어 실 RC 조종이 유지된다. (게임패드 watcher 와 동일 패턴:
    /// @State 옵셔널 + setup/teardown 수명주기.)
    #if canImport(IOKit)
    @State private var djiWatcher: DJIVirtualJoystickWatcher?
    #endif
    /// 현재 적용 중인 DJI 바인딩 프로파일 — 통합 시트가 편집·저장하면 watcher 에 반영.
    @State private var djiProfile: DJIBindingProfile = DJIBindingProfileStore.load()

    public init() {}

    public var body: some View {
        ZStack {
            // **HIG 정합**: backdrop Color 만 ignoresSafeArea — sidebar/toolbar
            // 영역 까지 어두운 배경을 깔되, content 자체는 detail safe area 안에서만
            // 그린다. 종전 sceneLayer 까지 ignoresSafeArea 한 결과 좌측 column 의
            // panel 이 NavigationSplitView 의 sidebar 영역까지 침범해 텍스트가 잘렸음.
            CockpitColors.backdrop.ignoresSafeArea()
            RadialGradient(colors: [Color.black.opacity(0),
                                    Color.black.opacity(0.55)],
                           center: .center,
                           startRadius: 200,
                           endRadius: 900)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            cockpitContent
        }
        .overlay(alignment: .topTrailing) { controllerSettingsButton }
        // **A3** — 유선 재프로브 배너. 무선 경로 중 유선(123.1:22)이 살아있으면 "유선 전환(166x)"
        // 을 *제안*만 한다(자동 전환 X). 사용자가 "전환" 을 누르면 주입된 closure 가 host 를 유선으로
        // 바꿔 onboard 텔레메트리를 빠른 경로로 재연결한다(브리지의 remoteShell.host onChange 가 처리).
        .overlay(alignment: .top) { wiredReprobeBanner }
        // **O4** — 온보드 TEL2 가 있을 때만 "명령 vs 래치값" 마이크로 인디케이터(래칭 지연 가시화).
        .overlay(alignment: .bottomLeading) {
            if let latch = store.onboardLatch {
                // 아코디언(기본 접힘) — 토글 클릭이 필요해 hit-testing 활성. 하단 바
                // (INPUT/bottomBar) 밴드와 겹치지 않게 그 위로 띄운다(겹침 방지,
                // 사용자 요청 2026-06-12).
                CockpitLatchIndicator(
                    cmdStrideMm: cockpit.motorCommand.strideMm,
                    cmdSideMm: cockpit.motorCommand.sideMm,
                    cmdTurnDeg: cockpit.motorCommand.turnDeg,
                    latch: latch)
                    .frame(maxWidth: 240, alignment: .leading)
                    .padding(.leading, 12)
                    .padding(.bottom, 96)
            }
        }
        // **O4** — 실로봇 보행 위상(TEL2)으로 시뮬 walkAnimator 위상 동기(화면=게이지=실모터).
        .onChange(of: store.onboardLatch) { _, latch in
            cockpit.onboardPhaseFraction01 = latch?.phaseFraction01
        }
        // 통합 컨트롤러 설정은 **독립 윈도우**로 띄운다 (.sheet 아님). .sheet 는 앱 메인
        // 창 크기를 절대 넘을 수 없어 작은 창(~1000×665)에선 1200×820 콘텐츠가 구조적으로
        // 잘렸다. 독립 윈도우는 화면 기준으로 크기·중앙배치가 자유 → 잘림 원천 차단.
        // 윈도우 open/close 는 showControllerSheet onChange 에서 수행.
        .focusable()
        .focused($keyboardFocused)
        .onAppear { setup() }
        .onDisappear { teardown() }
        // 스무딩된 motorCommand 를 모터로 dispatch — lastCommand(raw 목표)가 아니라
        // 30Hz EMA·결합제한을 거친 값이라 다축 입력이 매끄럽게 모터에 반영된다.
        .onChange(of: cockpit.motorCommand) { _, newCmd in
            dispatchRealMotorIfAllowed(cmd: newCmd)
        }
        // **CRITICAL fix — WalkLab advanced slider 와 동등 경로**:
        //
        // 종전 (V1) 은 `cockpit.lastCommand` 변화 시에만 motor 송출 → 사용자가
        // throttle slider 만 조절하고 stick 안 만지면 lastCommand 변화 없음 →
        // motor 의 customPeriodMs 갱신 안 됨. 즉 "throttle 올렸는데 robot 안 빨라
        // 짐" 의 critical 버그.
        //
        // WalkLab `WalkLabOnboardBridge` 의 `.onChange(of: session.customPeriodMs)
        // { scheduleDebouncedSend() }` 과 등가. cockpit 의 throttle 변화도 동일
        // dispatch chain 으로 motor 송출 보장.
        .onChange(of: cockpit.periodMs) { _, _ in
            dispatchRealMotorIfAllowed(cmd: cockpit.motorCommand)
        }
        // **머리 dispatch** — 적분된 머리 각도 변화 시 실 모터(servo 19/20) 송출.
        // 보행 freeform 과 독립 경로라 걸으면서 동시에 머리를 돌릴 수 있다.
        .onChange(of: cockpit.headPanDeg) { _, _ in dispatchHeadIfAllowed() }
        .onChange(of: cockpit.headTiltDeg) { _, _ in dispatchHeadIfAllowed() }
        // **볼 트래킹 토글 (2026-06-02)** — DJI 조종기 매핑(Button 3) 또는 게임패드가
        // cockpit.triggerBallTrackingToggle() 호출 → timestamp 변경 → 여기서 session 토글.
        // 온보드 자동 헤드 추적 on/off. (콕핏 화면 토글과 동일 상태 공유.)
        .onChange(of: cockpit.ballTrackingToggleAt) { _, newValue in
            if newValue != nil { session.ballTrackingEnabled.toggle() }
        }
        // **컨트롤러 E-STOP/복구 배선 (S1, 2026-06-11)** — 게임패드·DJI·드라이버가
        // `triggerEmergency()` 로 set 하는 `emergencyAt` 의 단일 소비자. 종전엔 소비자가
        // 0개라 컨트롤러 E-STOP 이 HUD flash 만 내고 하드웨어 정지를 못 했다(critical).
        // 모든 입력원(버튼·키·게임패드·DJI)이 이제 emergencyAt/recoveryAt 단일 진입점으로
        // 수렴 → 여기서 hardware torque-off 체인 호출. `cockpitEmergencyStop()` 은
        // triggerEmergency 를 재호출하지 않으므로(아래 정의 참조) 재진입 루프 없음.
        // 디바운스/스로틀 없음 — E-STOP 즉시발화 불변식 보존.
        .onChange(of: cockpit.emergencyAt) { _, newValue in
            if newValue != nil { cockpitEmergencyStop() }
        }
        .onChange(of: cockpit.recoveryAt) { _, newValue in
            if newValue != nil { cockpitRecover() }
        }
        // 통합 시트에서 DJI 프로파일을 저장하면 라이브 watcher 에 즉시 반영.
        .onChange(of: djiProfile) { _, newProfile in
            #if canImport(IOKit)
            djiWatcher?.applyBindingProfile(newProfile)
            #endif
        }
        // 매핑 창이 열려 있는 동안 NSEvent 키보드 모니터 정지(키업 추적) + 입력 zero —
        // 단축키 비활성과 함께 콕핏 키보드 경로를 완전히 차단한다. 닫으면 복구.
        // 독립 매핑 윈도우의 open/close 도 여기서 일원화.
        .onChange(of: showControllerSheet) { _, open in
            if open {
                keyboardMonitor?.stop()
                cockpit.release()
                openControllerWindow()
            } else {
                keyboardMonitor?.start()
                closeControllerWindow()
            }
        }
        .onChange(of: realMotorEnabled) { _, on in
            // **#1 (2026-05-31)**: 콕핏/조종 시뮬에서 실 모터 ON → WalkLab ARM 없이 **즉시**
            // DXL 전원 + 전체 토크 ON. 종전엔 motorGate 가 "DXL 토크 OFF (워크 랩 ARM 필요)"
            // 로 막아 사용자가 WalkLab 에서 별도 ARM 해야 했다. 이제 토글 ON 이 곧 ARM.
            if on {
                // **GPT 검수 fix (2026-06-01)**: 온보드 모드면 실 모터 ON 시 브로커리지를 켠다.
                // 브리지 shouldSend() 가 autoOnboardBrokering 을 요구하므로, 안 켜면 스틱이
                // accepted 돼도 SSH 명령이 안 나간다("dispatch 활성" 거짓 표시).
                if isOnboardMode { session.autoOnboardBrokering = true }
                // **#2 (2026-06-01)**: 콕핏 조종 walk 가 "cradleNotConfirmed" 로 거부돼 다리가
                // 안 움직이던 문제 — 실 모터 ON(=실 robot 조종 의사 명시)을 cradle 확인으로
                // 간주해 자동 confirm. 종전엔 WalkLab 에서 별도 거치대 확인을 해야 walk 가능했다.
                if !session.cradleConfirmed { session.cradleConfirmed = true }
                if let bus = store.bus, !store.isDxlPowerOn {
                    if let fail = session.preflightForWalkCycle(bus: bus) {
                        session.lastRobotEvent = "실 모터 ON 실패 — \(fail.userMessage)"
                    } else {
                        store._setDxlPowerState(true)
                        session.lastRobotEvent = "● 실 모터 ON — DXL 전원/토크 + 거치대 확인 (ARM 불필요)"
                    }
                }
            }
            // OFF 로 전환 시 즉시 robot 정지 명령 전송 (safety).
            if !on, !session.pilotIsEmergency {
                // **H3 fix (2026-05-30)**: freeform 보행 중 realMotor OFF 시 `pilotStop()`
                // 을 호출하지 않으면 freeform task 가 `mobileFreeformTuning` 을 계속 읽어
                // 보행이 지속됨. `teardown()` 과 동일 패턴: pilotIsWalking 이면 정식 stop.
                if session.pilotIsWalking {
                    session.pilotStop()
                } else {
                    _ = session.pilotApplyAmplitude(.stop)
                    session.pilotSyncEngine()
                }
                // 머리 입력도 정지 — walk 만 멈추고 머리 입력이 잔존하던 상태 비대칭 제거
                // (각도는 유지, 입력 norm 만 0 → 적분 멈춤).
                cockpit.applyHead(panNorm: 0, tiltNorm: 0)
            }
            recorder?.logEvent(on ? .realMotorOn : .realMotorOff)
        }
        // **maxDuration 감지**: 실 motor + stick 유지 중인데 walking 이 false 로
        // 떨어지면 (사용자가 명시 stop 안 했는데) freeform task 가 maxDurationSec
        // 로 자동 종료된 것. 테스트 데이터에 기록 → "왜 robot 이 멈췄나" 분석.
        .onChange(of: session.pilotIsWalking) { wasWalking, nowWalking in
            if wasWalking, !nowWalking, realMotorEnabled,
               !cockpit.lastCommand.isStop, !session.pilotIsEmergency,
               autoDisarmTask == nil {
                recorder?.logEvent(.maxDuration,
                                   detail: "walking ended while stick active")
            }
        }
        // **Hybrid keyboard 입력 (사용자 보고: monitor 단독 fail)**:
        //   - CockpitKeyboardHotkeys (.keyboardShortcut hidden buttons): keyDown +
        //     OS auto-repeat (hold) 잡음. apply 발사 + 250ms timer fallback.
        //   - CockpitKeyboardMonitor (NSEvent): keyUp 정확 release. monitor 가 어떤
        //     이유로 fail 해도 keyboardShortcut + timer 가 동작 보장.
        // 컨트롤러 연결 모달이 열려 있는 동안 콕핏 단축키(WASD/QE/Space/R) 비활성 —
        // 매핑 편집 중 키 입력이 로봇을 움직이거나 E-STOP 시키는 안전 사고 방지.
        .background(CockpitKeyboardHotkeys(
            cockpit: cockpit,
            onEmergency: { cockpit.triggerEmergency() },
            onRecover: { cockpit.triggerRecovery() })
            .disabled(showControllerSheet))
        // SSH↔LAN parity (2026-06-01): 콕핏은 WalkLabView 와 별개 최상위 화면이라
        // 자체 onboard bridge 가 필요. 이 invisible bridge 가 onboard 명령 전송 + 텔레메트리
        // 업링크 lifecycle(remoteShellRef/poller) + walklab 모드 검증을 소유한다.
        // 종전: 브리지가 WalkLabView 에만 있어 콕핏 조종 중엔 onboard 전송·텔레메트리·
        // e-stop(remoteShellRef nil)이 전부 dead 였음.
        .background(WalkLabOnboardBridge(session: session, reprobeMonitor: reprobeMonitor))
        .accessibilityIdentifier("cockpit.root")
    }

    /// HIG 표준 safe-area 안에서 그리는 cockpit content. GeometryReader 가
    /// detail view 의 실제 사용 가능 width 를 측정 → column 폭 + scene inset 동적.
    ///
    /// **구조**: sceneLayer 가 cockpit detail view 전체를 채우고, 모든 instrument
    /// panel 은 sceneLayer 의 .overlay 로 부유. ZStack 의 외곽 padding 이 없어 scene
    /// 자체가 cockpit detail view 의 가장자리까지 그려지므로, NavigationSplitView 의
    /// sidebar 와는 절대 시각적 겹침이 발생하지 않는다.
    @ViewBuilder
    private var cockpitContent: some View {
        GeometryReader { geo in
            let layout = CockpitLayout(width: geo.size.width)
            if layout.isCompact {
                compactLayout(layout: layout)
            } else {
                threeColumnLayout(layout: layout)
            }
        }
    }

    /// 와이드/표준: 3D scene 이 cockpit 전체 영역 (full-bleed) + panel 들이
    /// `.overlay(alignment:)` 로 가장자리에 floating. 게임/시뮬 cockpit 의 표준
    /// 패턴 — 사용자가 panel 영역을 3D 위에 "떠 있는 instrument" 로 인지.
    ///
    /// **잘림 해결**: scene 이 cockpit detail view 전체를 차지하므로 사이드바와의
    /// 경계는 cockpit detail view 의 leading edge — NavigationSplitView 가 보장.
    /// panel 들은 sceneLayer 의 좌상/좌하/우상/우하 corner 안쪽에서만 그려져 절대
    /// 사이드바 영역을 침범하지 않는다.
    @ViewBuilder
    private func threeColumnLayout(layout: CockpitLayout) -> some View {
        sceneLayer
            .overlay(alignment: .topLeading) {
                leftColumn
                    .frame(width: layout.columnW)
                    .padding(.leading, layout.leftPadding)
                    .padding(.top, layout.topPadding)
            }
            .overlay(alignment: .topTrailing) {
                rightColumn
                    .frame(width: layout.columnW)
                    .padding(.trailing, layout.rightPadding)
                    .padding(.top, layout.topPadding)
            }
            .overlay(alignment: .bottom) {
                bottomBar(layout: layout)
                    .padding(.bottom, layout.bottomPadding)
            }
            .overlay(alignment: .top) {
                // 화면 상단 중앙 — SIM 알림 banner (사용자 보고: 중앙 표시).
                simBanner
                    .padding(.top, layout.topPadding)
            }
    }

    /// Compact: 좌측 ScrollView 안에 모든 panel stack + bottomBar 그대로. scene 은
    /// full-bleed 유지하고 좌측 floating column 만 표시.
    @ViewBuilder
    private func compactLayout(layout: CockpitLayout) -> some View {
        sceneLayer
            .overlay(alignment: .topLeading) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        CockpitStatusBlock(
                            controllerName: cockpit.connectedController,
                            macConnected: true,
                            robotConnected: store.isRobotConnected,
                            armed: isArmed,
                            dxlPowerOn: store.isDxlPowerOn)
                        CockpitControllerStatusCard(
                            cockpit: cockpit,
                            djiStreaming: djiStreamingNow,
                            onOpenSettings: { showControllerSheet = true })
                        CockpitKeyboardOverlayCompact(cockpit: cockpit)
                        CockpitAttitudeIndicator(
                            rollDeg: currentIMURoll,
                            pitchDeg: currentIMUPitch,
                            headingDeg: cockpit.simHeadingDeg,
                            batteryV: store.lastTelemetry?.board?.voltageVolts,
                            tempC: store.lastTelemetry?.avgTemperature,
                            latencyMs: store.lastRoundTripMs.map { Int($0.rounded()) })
                            .cockpitTelemetryStale(telemetryStale)
                        CockpitSpeedGauge(
                            forwardMmPerSec: cockpit.simForwardSpeedMmPerSec,
                            lateralMmPerSec: cockpit.simLateralSpeedMmPerSec,
                            turnDegPerSec: cockpit.simTurnSpeedDegPerSec,
                            peakForwardMmPerSec: cockpit.peakForwardSpeedMmPerSec)
                        CockpitPositionMinimap(
                            positionMM: cockpit.simPositionMM,
                            headingDeg: cockpit.simHeadingDeg,
                            trail: cockpit.pathTrail,
                            totalDistanceMm: cockpit.totalDistanceMm)
                        speedColumn
                    }
                    .frame(width: layout.columnW)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(layout.outerPadding)
            }
            .overlay(alignment: .bottom) {
                bottomBar(layout: layout).padding(.bottom, layout.outerPadding)
            }
    }

    // MARK: - A3 유선 재프로브 배너 (probe-and-prompt)

    /// **A3** — 무선 경로 중 유선(123.1)이 살아있을 때 "유선 전환(166x)" 을 *제안*하는 dismissible
    /// 배너. 모니터(`reprobeMonitor`)는 host setter 를 보유하지 않으므로, 전환 동작을 여기서 *주입*
    /// 한다(probe-and-prompt 불변식). [전환] = 주입된 closure 1회 발동, [✕] = 제안만 닫음.
    @ViewBuilder
    private var wiredReprobeBanner: some View {
        if case let .offerWired(target) = reprobeMonitor.state {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 12, weight: .bold))
                Text("유선 전환 (166x) — \(target)")
                    .font(.system(size: CockpitMetrics.bannerText, weight: .heavy,
                                  design: .monospaced))
                Button("전환") {
                    // 주입된 전환 동작 — 모니터는 host 를 직접 건드리지 않는다. host 를 유선으로
                    // 바꾸면 브리지의 remoteShell.host onChange 가 onboard 텔레메트리를 재연결.
                    reprobeMonitor.accept {
                        remoteShell.host = WiredReprobeMonitor.wiredTarget
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(CockpitColors.live)
                Button {
                    reprobeMonitor.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black.opacity(0.6))
                .accessibilityLabel("유선 전환 배너 닫기")
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(CockpitColors.cyan, in: Capsule())
            .shadow(color: CockpitColors.cyan.opacity(0.45), radius: 8, x: 0, y: 2)
            .padding(.top, 10)
            .accessibilityIdentifier("cockpit.wiredReprobeBanner")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - SIM banner (floating top-center)

    /// 화면 상단 중앙 floating banner — 시뮬 모드 / 실 모터 상태 알림.
    /// 시뮬 활성이거나 motor gate 차단 사유가 있을 때 표시 (둘 다 X 면 hidden).
    @ViewBuilder
    private var simBanner: some View {
        VStack(spacing: 4) {
            telemetryPathBadge
            if cockpit.simulationEnabled {
                banner(text: "◐ SIM — robot 이동은 시뮬 (실 모터 미전송)",
                       tone: CockpitColors.warn)
            }
            if realMotorEnabled, let gate = motorGate {
                banner(text: "⚠ 실 모터 차단 — \(gate)",
                       tone: CockpitColors.danger)
            } else if realMotorEnabled {
                banner(text: "● 실 모터 dispatch 활성",
                       tone: CockpitColors.live)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 텔레메트리 경로 배지 + 안전게이트 (W5, ssh-parity-contract §D.5)

    /// 화면 상단 중앙 — 현재 텔레메트리 경로(온보드SSH vs LAN)와 안전게이트 온/오프라인.
    ///
    /// **정직성**: 온보드(SSH)는 로봇이 IMU/전압만 업링크(관절/온도 없음)하므로, 어느
    /// 경로로 데이터가 흐르는지 + 안전게이트가 살아있는지를 cockpit 상단에 항상 노출한다.
    /// `store.telemetryMode` 를 읽는다(W3 선언). 지연/오프라인은 호박/회색으로 강등.
    @ViewBuilder
    private var telemetryPathBadge: some View {
        let mode = store.telemetryMode
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: mode.iconSystemName)
                    .font(.system(size: 10, weight: .bold))
                Text(mode.pathLabel)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
            }
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 12)
            HStack(spacing: 4) {
                // 정직성 fix: Mac 게이트 실제 동작 여부 기준. 온보드는 "로봇 자율"(Mac 미작동).
                let gateOK = mode.safetyBanner.level == .ok
                Image(systemName: gateOK ? "checkmark.shield.fill"
                      : (mode == .onboard ? "shield.lefthalf.filled" : "shield.slash.fill"))
                    .font(.system(size: 10, weight: .bold))
                Text(gateOK ? "게이트 온라인" : (mode == .onboard ? "게이트: 로봇 자율" : "게이트 오프라인"))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(telemetryBadgeTone, in: Capsule())
        .shadow(color: telemetryBadgeTone.opacity(0.4), radius: 6, x: 0, y: 2)
    }

    /// cockpit 배지 tone — DFColor 가 아닌 CockpitColors(네온) 팔레트로 매핑.
    private var telemetryBadgeTone: Color {
        switch store.telemetryMode {
        case .lan, .onboard: return CockpitColors.live
        case .onboardStale:  return CockpitColors.warn
        case .offline:       return Color.white.opacity(0.5)
        }
    }

    private func banner(text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: CockpitMetrics.bannerText, weight: .heavy, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(tone, in: Capsule())
            .shadow(color: tone.opacity(0.45), radius: 8, x: 0, y: 2)
    }

    // MARK: - Columns

    /// 좌측 instrument column — status + DJI + compact keyboard.
    /// **반응형(리뷰)**: ScrollView 로 감싸 짧은 창 높이에서도 DJI/키보드 패널이 잘리지 않음.
    private var leftColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                CockpitStatusBlock(
                    controllerName: cockpit.connectedController,
                    macConnected: true,
                    robotConnected: store.isRobotConnected,
                    armed: isArmed,
                    dxlPowerOn: store.isDxlPowerOn)
                CockpitControllerStatusCard(
                    cockpit: cockpit,
                    djiStreaming: djiStreamingNow,
                    onOpenSettings: { showControllerSheet = true })
                CockpitKeyboardOverlayCompact(cockpit: cockpit)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 우측 instrument column — attitude + speed gauge + position minimap + throttle.
    /// ScrollView 안에 stack — 좁은 화면에서도 아래까지 접근 가능.
    private var rightColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 10) {
                CockpitAttitudeIndicator(
                    rollDeg: currentIMURoll,
                    pitchDeg: currentIMUPitch,
                    headingDeg: cockpit.simHeadingDeg,
                    batteryV: store.lastTelemetry?.board?.voltageVolts,
                    tempC: store.lastTelemetry?.avgTemperature,
                    latencyMs: store.lastRoundTripMs.map { Int($0.rounded()) })
                    .cockpitTelemetryStale(telemetryStale)
                CockpitSpeedGauge(
                    forwardMmPerSec: cockpit.simForwardSpeedMmPerSec,
                    lateralMmPerSec: cockpit.simLateralSpeedMmPerSec,
                    turnDegPerSec: cockpit.simTurnSpeedDegPerSec,
                    peakForwardMmPerSec: cockpit.peakForwardSpeedMmPerSec)
                CockpitPositionMinimap(
                    positionMM: cockpit.simPositionMM,
                    headingDeg: cockpit.simHeadingDeg,
                    trail: cockpit.pathTrail,
                    totalDistanceMm: cockpit.totalDistanceMm)
                speedColumn
            }
        }
    }

    /// 하단 중앙 bar — joystick + command + safety.
    /// **반응형(리뷰 H1)**: 조이스틱·버튼 크기를 창 폭으로 단계화 — 좁은 창(<900pt)에서
    /// 한 단계 축소해 bottom HStack 오버플로/씬 잠식 방지.
    private func bottomBar(layout: CockpitLayout) -> some View {
        let w = layout.width
        let jsize = CockpitMetrics.joystickSize(w)
        let bw = CockpitMetrics.safetyW(w)
        let bh = CockpitMetrics.safetyH(w)
        return VStack(spacing: 10) {
            CockpitCommandReadout(command: cockpit.lastCommand,
                                  speedScale: cockpit.speedScale,
                                  source: cockpit.lastSource)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: CockpitMetrics.bottomGap(w)) {
                // 실 모터 토글 + E-STOP — 진입 즉시 보이는 고정 위치 (스크롤 불필요).
                VStack(spacing: 6) {
                    realMotorBottomToggle
                    safetyButton(title: "E-STOP",
                                 systemImage: "exclamationmark.octagon.fill",
                                 tint: CockpitColors.danger,
                                 width: bw, height: bh) {
                        cockpit.triggerEmergency()
                    }
                    .accessibilityIdentifier("cockpit.estop")
                }
                MouseJoystickPad(cockpit: cockpit)
                    .frame(width: jsize, height: jsize)
                    .accessibilityIdentifier("cockpit.virtualPad")
                safetyButton(title: "RECOVER",
                             systemImage: "arrow.clockwise.circle.fill",
                             tint: CockpitColors.live,
                             width: bw, height: bh) {
                    cockpit.triggerRecovery()
                }
                .accessibilityIdentifier("cockpit.recover")
            }
        }
    }

    /// **하단 바 고정 실 모터 토글** — 조종 시뮬 진입 즉시 노출 (우측 ScrollView 하단
    /// 의 종전 위치는 스크롤해야 보였음). speedColumn 의 토글을 본 위치로 이동해 단일
    /// source of truth 유지. `realMotorEnabled` @State·onChange·recorder 로깅은 불변.
    private var realMotorBottomToggle: some View {
        VStack(spacing: 3) {
            Toggle(isOn: $realMotorEnabled) {
                Text("실 모터")
                    .font(.system(size: CockpitMetrics.toggleLabel, weight: .bold, design: .monospaced))
                    .foregroundStyle(realMotorEnabled
                                     ? CockpitColors.danger : .white.opacity(0.85))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 124)
            .accessibilityIdentifier("cockpit.real.toggle")
            Text(motorGate ?? "dispatch 활성 ✓")
                .font(.system(size: CockpitMetrics.sectionLabel, weight: .semibold, design: .monospaced))
                .foregroundStyle(motorGate == nil
                                 ? CockpitColors.live
                                 : CockpitColors.warn.opacity(0.9))
                .frame(width: 130)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        // **리뷰 M3**: 바 위에 떠 있던 토글에 패널 backing — 밝은 씬 위 가독성 확보.
        .cockpitPanel(tint: realMotorEnabled ? CockpitColors.danger : CockpitColors.live,
                      strokeOpacity: 0.3, padding: 10)
    }

    // MARK: - Sub layers

    private var sceneLayer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(CockpitColors.live.opacity(0.18), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.35))
                )
            CockpitChaseSceneView(
                pose: effectivePose,
                simulatedHeadingDeg: cockpit.simulationEnabled ? cockpit.simHeadingDeg : 0,
                simulatedPositionMM: cockpit.simulationEnabled ? cockpit.simPositionMM : .zero,
                imuRollDeg: currentIMURoll,
                imuPitchDeg: currentIMUPitch)
                .cornerRadius(12)
                .accessibilityIdentifier("cockpit.scene")
            // SIM banner 는 scene 상단 중앙으로 분리 (simBanner property).
            // Corner cut-out frame marks — FPV cliché
            Canvas { ctx, size in
                let inset: CGFloat = 8
                let len: CGFloat = 18
                let color = GraphicsContext.Shading.color(CockpitColors.live)
                func cornerStroke(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint) {
                    var path = Path()
                    path.move(to: p0); path.addLine(to: p1)
                    path.move(to: p0); path.addLine(to: p2)
                    ctx.stroke(path, with: color, lineWidth: 1.5)
                }
                cornerStroke(.init(x: inset, y: inset),
                             .init(x: inset + len, y: inset),
                             .init(x: inset, y: inset + len))
                cornerStroke(.init(x: size.width - inset, y: inset),
                             .init(x: size.width - inset - len, y: inset),
                             .init(x: size.width - inset, y: inset + len))
                cornerStroke(.init(x: inset, y: size.height - inset),
                             .init(x: inset + len, y: size.height - inset),
                             .init(x: inset, y: size.height - inset - len))
                cornerStroke(.init(x: size.width - inset, y: size.height - inset),
                             .init(x: size.width - inset - len, y: size.height - inset),
                             .init(x: size.width - inset, y: size.height - inset - len))
            }
            .allowsHitTesting(false)
        }
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 12) {
            CockpitStatusBlock(
                controllerName: cockpit.connectedController,
                macConnected: true, // 본 view 가 살아있으면 Mac runtime live.
                robotConnected: store.isRobotConnected,
                armed: isArmed,
                dxlPowerOn: store.isDxlPowerOn)
            CockpitControllerStatusCard(
                cockpit: cockpit,
                djiStreaming: djiStreamingNow,
                onOpenSettings: { showControllerSheet = true })
                .frame(maxWidth: 260)
            Spacer()
            CockpitAttitudeIndicator(
                rollDeg: currentIMURoll,
                pitchDeg: currentIMUPitch,
                headingDeg: cockpit.simHeadingDeg,
                batteryV: store.lastTelemetry?.board?.voltageVolts,
                tempC: store.lastTelemetry?.avgTemperature,
                latencyMs: store.lastRoundTripMs.map { Int($0.rounded()) })
                .cockpitTelemetryStale(telemetryStale)
        }
    }

    private var bottomRow: some View {
        VStack(spacing: 14) {
            CockpitCommandReadout(command: cockpit.lastCommand,
                                  speedScale: cockpit.speedScale,
                                  source: cockpit.lastSource)
                .frame(maxWidth: .infinity)
            HStack(alignment: .bottom, spacing: 24) {
                VStack(spacing: 10) {
                    CockpitStickIndicator(label: "LEFT STICK · MOVE",
                                          value: SIMD2(cockpit.leftStick.x, cockpit.leftStick.y),
                                          xLabel: "lat",
                                          yLabel: "fwd")
                    safetyButton(title: "E-STOP",
                                 systemImage: "exclamationmark.octagon.fill",
                                 tint: CockpitColors.danger) {
                        cockpit.triggerEmergency()
                    }
                    .accessibilityIdentifier("cockpit.estop")
                }
                MouseJoystickPad(cockpit: cockpit)
                    .frame(width: 220, height: 220)
                    .accessibilityIdentifier("cockpit.virtualPad")
                Spacer()
                speedColumn
                Spacer()
                VStack(spacing: 10) {
                    CockpitStickIndicator(label: "RIGHT STICK · TURN",
                                          value: SIMD2(cockpit.rightStick.x, 0),
                                          xLabel: "yaw",
                                          yLabel: "—")
                    safetyButton(title: "RECOVER",
                                 systemImage: "arrow.clockwise.circle.fill",
                                 tint: CockpitColors.live) {
                        cockpit.triggerRecovery()
                    }
                    .accessibilityIdentifier("cockpit.recover")
                }
            }
        }
    }

    private var speedColumn: some View {
        // 2026-05-31: 걸음 로직 LAB 패널을 throttle/밸런스 패널 아래에 함께 배치 —
        // speedColumn 이 모든 레이아웃(compact/snug/wide)에서 쓰이므로 한 곳에서 노출.
        VStack(spacing: 10) {
        VStack(spacing: 8) {
            Text("THROTTLE")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: Binding(
                get: { cockpit.speedScale },
                set: { cockpit.setSpeedScale($0) }),
                   in: 0.5...1.5)
                .controlSize(.small)
                .frame(width: 180)
                .accessibilityIdentifier("cockpit.throttle")
            Text(String(format: "×%.2f", cockpit.speedScale))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(CockpitColors.cyan)
            Divider().background(CockpitColors.live.opacity(0.2))
            // (실 모터 토글은 하단 바 E-STOP 옆으로 이동 — 진입 즉시 노출.
            //  speedColumn 은 throttle + 자이로 보정 + 시뮬 토글만 유지.)
            // **방법론 (Walking.cpp::sensoryFeedback + IMU freshness gate)**:
            // 자이로 보정 master switch. WalkLab 의 enableBalanceCorrection 과
            // 동일 toggle — Cockpit 에서도 직접 access 가능. ON 시 매 motor step
            // 마다 applyBalanceCorrectionIfEnabled 가 IMU error 를 P-control 로
            // 4 관절 그룹 (hip/knee/ankle) delta 로 변환 → 실 motor 송출 전 적용.
            Toggle(isOn: balanceCorrectionBinding) {
                HStack(spacing: 4) {
                    Text("자이로 보정")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(session.enableBalanceCorrection
                                         ? CockpitColors.live : .white.opacity(0.65))
                    // 실시간 상태 dot: green = 적용 중, gray = 비활성 / stale.
                    Circle()
                        .fill(balanceCorrectionStatusColor)
                        .frame(width: 6, height: 6)
                        .shadow(color: balanceCorrectionStatusColor.opacity(0.6),
                                radius: session.enableBalanceCorrection ? 3 : 0)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 160)
            .accessibilityIdentifier("cockpit.balance.toggle")
            Divider().background(CockpitColors.live.opacity(0.2))
            // 자동 일어나기 토글 — enableAutoGetUp 바인딩.
            // ON 시 낙하 감지 → get-up 모션 page 10/11 자동 실행.
            // 현재 Recovery 단계도 간략히 표시.
            @Bindable var bindableSession = session
            Toggle(isOn: $bindableSession.enableAutoGetUp) {
                HStack(spacing: 4) {
                    Text("자동 일어나기")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(session.enableAutoGetUp
                                         ? CockpitColors.live : .white.opacity(0.65))
                    if session.enableAutoGetUp,
                       session.autoRecoveryPhase != .idle {
                        Text(autoGetUpPhaseLabel)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CockpitColors.warn)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 160)
            .accessibilityIdentifier("cockpit.autoGetUp.toggle")
            Divider().background(CockpitColors.live.opacity(0.2))
            // 볼 트래킹 토글 (2026-06-02) — 로봇 온보드 자동 헤드 추적.
            // ON 시 robot-side 브로커리지가 카메라+BallTracker 로 머리를 공에 맞춰
            // 움직인다(기본 데모와 동일). serializedLine 13번째 필드로 전달.
            Toggle(isOn: $bindableSession.ballTrackingEnabled) {
                HStack(spacing: 4) {
                    Text("볼 트래킹")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(session.ballTrackingEnabled
                                         ? CockpitColors.live : .white.opacity(0.65))
                    Image(systemName: session.ballTrackingEnabled ? "eye.fill" : "eye")
                        .font(.system(size: 9))
                        .foregroundStyle(session.ballTrackingEnabled
                                         ? CockpitColors.live : .white.opacity(0.4))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 160)
            .accessibilityIdentifier("cockpit.ballTrack.toggle")
            Divider().background(CockpitColors.live.opacity(0.2))
            // 시뮬 모드 토글 — robot 위치/방향만 시뮬.
            Toggle(isOn: $cockpit.simulationEnabled) {
                Text("시뮬 이동")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(cockpit.simulationEnabled
                                     ? CockpitColors.warn : .white.opacity(0.65))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 160)
            .accessibilityIdentifier("cockpit.sim.toggle")
        }
        .cockpitPanel(tint: CockpitColors.cyan, strokeOpacity: 0.3)
            CockpitWalkLogicPanel()
        }
    }

    /// 자동 일어나기 현재 단계 라벨 — .idle 이외 상태일 때 표시.
    private var autoGetUpPhaseLabel: String {
        switch session.autoRecoveryPhase {
        case .idle:                 return ""
        case .fallen(let dir):      return dir == .forward ? "앞 감지" : "뒤 감지"
        case .settling:             return "정착 대기"
        case .gettingUp:            return "일어나는 중…"
        case .done:                 return "완료"
        case .failed:               return "실패"
        }
    }

    private func safetyButton(title: String,
                              systemImage: String,
                              tint: Color,
                              width: CGFloat = CockpitMetrics.safetyButtonW,
                              height: CGFloat = CockpitMetrics.safetyButtonH,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .heavy))
                Text(title)
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
            }
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: CockpitMetrics.panelRadius, style: .continuous)
                    .fill(tint.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: CockpitMetrics.panelRadius, style: .continuous)
                            .stroke(.white.opacity(0.45), lineWidth: 1))
            )
            .shadow(color: tint.opacity(0.35), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived state

    /// **정직성**: ConnectionStore 가 published `RobotPose` 를 노출하지 않으므로
    /// (현재 pose 는 bus read 시점에만 계산), cockpit 은 실 pose 가 환경상 보장될
    /// 때까지 정자세(`walkReady`) 만 표시한다. 추후 ConnectionStore 가 published
    /// pose 를 노출하거나 WalkLabSession.currentPose 가 share 되면 그 값을 사용.
    private var livePose: RobotPose {
        RobotPose.walkReady
    }

    /// 화면에 그릴 robot pose. `CockpitPoseResolver` 의 pure 함수에 위임 — 결정
    /// 규칙이 단위 테스트로 검증되고, 다른 진입점 (preview / 외부 SDK) 에서 재사용
    /// 가능.
    private var effectivePose: RobotPose {
        CockpitPoseResolver.effective(
            realMotorEnabled: realMotorEnabled,
            isWalking: session.pilotIsWalking,
            visualPose: session.visualPose,
            animatedPose: cockpit.animatedPose)
    }

    private var currentIMURoll: Double {
        store.imuFilter.rollDeg
    }

    private var currentIMUPitch: Double {
        store.imuFilter.pitchDeg
    }

    /// **staleness 탈색(W5, 계약 §D.5/§F-7)**: 텔레메트리가 라이브가 아니거나 온보드
    /// 지연이면 HUD 계기(전압/온도/IMU 자세)를 무채색·반투명으로 강등해 "보존된 값"임을
    /// 명시한다. LAN stale 데이터를 fresh-green 으로 보이지 않게 하는 게 목적.
    private var telemetryStale: Bool {
        store.telemetryMode.shouldDesaturate
    }

    // MARK: - 컨트롤러 세팅 진입 버튼

    private var controllerSettingsButton: some View {
        Button {
            showControllerSheet = true
        } label: {
            Label("컨트롤러 연결", systemImage: "gamecontroller.fill")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(CockpitColors.panelSolid))
                .overlay(Capsule().stroke(CockpitColors.cyan.opacity(0.5), lineWidth: 1))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.top, 14).padding(.trailing, 16)
        .help("게임패드·DJI 조종기 연결과 키 매핑을 한 곳에서")
    }

    /// 통합 「컨트롤러 연결」 패널 (본연 1100×760) — IOKit 가용 시 DJI watcher 주입,
    /// 아니면 게임패드 전용 폴백. (watcher 는 setup() 에서 생성되어 진입 시 non-nil.)
    @ViewBuilder
    private var controllerConnectionSheet: some View {
        #if canImport(IOKit)
        if let djiWatcher {
            CockpitControllerConnectionSheet(
                cockpit: cockpit,
                isPresented: $showControllerSheet,
                djiProfile: $djiProfile,
                djiWatcher: djiWatcher)
        } else {
            CockpitControllerSettingsSheet(cockpit: cockpit, isPresented: $showControllerSheet)
        }
        #else
        CockpitControllerConnectionSheet(
            cockpit: cockpit,
            isPresented: $showControllerSheet,
            djiProfile: $djiProfile)
        #endif
    }

    /// 좌측 상태 카드용 — DJI HID 라이브 스트리밍 여부.
    private var djiStreamingNow: Bool {
        #if canImport(IOKit)
        djiWatcher?.isStreaming ?? false
        #else
        false
        #endif
    }

    // MARK: - 독립 매핑 윈도우 (잘림 원천 차단)

    /// 「컨트롤러 연결」 매핑 화면을 담는 독립 NSWindow. .sheet 는 앱 메인 창보다 클 수
    /// 없어 작은 창에선 콘텐츠가 구조적으로 잘렸다 — 독립 윈도우는 **화면(스크린)** 기준
    /// 으로 크기를 잡고 OS 가 중앙 배치하므로 어떤 메인 창 크기에서도 잘리지 않는다.
    @State private var mappingWindow: NSWindow?
    /// 타이틀바 빨간 닫기 버튼 → showControllerSheet 동기화용 observer 토큰.
    @State private var mappingWindowCloseToken: NSObjectProtocol?

    private func openControllerWindow() {
        if let win = mappingWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        // 상태바가 @EnvironmentObject store 를 읽으므로 새 윈도우 트리에 명시 주입.
        let root = controllerConnectionSheet.environmentObject(store)
        let host = NSHostingController(rootView: AnyView(root))
        let win = NSWindow(contentViewController: host)
        win.title = "컨트롤러 연결"
        win.styleMask = [.titled, .closable, .resizable]
        win.contentMinSize = NSSize(width: 980, height: 620)
        win.isReleasedWhenClosed = false
        // 본연 크기를 기본으로 하되, 화면(visibleFrame)보다 크면 화면에 맞춰 줄인다.
        let natural = CockpitControllerConnectionSheet.naturalSize
        let screen = NSScreen.main?.visibleFrame.size
            ?? CGSize(width: natural.width + 80, height: natural.height + 80)
        win.setContentSize(NSSize(width: min(natural.width, screen.width - 40),
                                  height: min(natural.height, screen.height - 40)))
        win.center()
        // 빨간 닫기 버튼으로 닫혀도 콕핏 상태(키보드 복구 등)가 동기화되도록.
        mappingWindowCloseToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { _ in
            Task { @MainActor in
                if showControllerSheet { showControllerSheet = false }
            }
        }
        win.makeKeyAndOrderFront(nil)
        mappingWindow = win
    }

    private func closeControllerWindow() {
        guard let win = mappingWindow else { return }
        if let token = mappingWindowCloseToken {
            NotificationCenter.default.removeObserver(token)
        }
        mappingWindowCloseToken = nil
        mappingWindow = nil
        win.contentViewController = nil   // SwiftUI onDisappear(스트리밍 재개 등) 보장.
        win.close()
    }


    // MARK: - Lifecycle

    private func setup() {
        let w = CockpitGameControllerWatcher(state: cockpit)
        w.start()
        watcher = w
        // **DJI RC 라이브 경로** — 종전 CockpitDJIPanel 의 책임을 본 view 로 이전.
        // 통합 시트 개폐와 무관하게 살아 있어 실 RC 조종이 끊기지 않는다.
        #if canImport(IOKit)
        let dw = DJIVirtualJoystickWatcher(cockpit: cockpit)
        dw.start()
        dw.applyBindingProfile(djiProfile)
        djiWatcher = dw
        #endif
        // **방법론 (Unity InputManager keyDown/keyUp)**: NSEvent local monitor
        // 로 정확한 hold/release 추적. SwiftUI keyboardShortcut (keyDown 1회) 의
        // 한계를 우회.
        let km = CockpitKeyboardMonitor(state: cockpit)
        km.start()
        keyboardMonitor = km
        cockpit.startSimulation()
        keyboardFocused = true
        startTestDataRecorder()
    }

    private func teardown() {
        // 콕핏 화면을 떠나면 매핑 윈도우도 닫는다 (cockpit/watcher 참조 정리).
        closeControllerWindow()
        showControllerSheet = false
        watcher?.stop()
        watcher = nil
        #if canImport(IOKit)
        djiWatcher?.stop()
        djiWatcher = nil
        #endif
        keyboardMonitor?.stop()
        keyboardMonitor = nil
        cockpit.stopSimulation()
        cockpit.release()
        // **Phase 2.2 fix**: dwell timer leak 방지 — view 사라질 때 task cancel.
        autoDisarmTask?.cancel()
        autoDisarmTask = nil
        // 화면 나갈 때 실 motor 가 활성이었으면 정지 명령 전송 (안전).
        if realMotorEnabled, !session.pilotIsEmergency {
            // Walking 진행 중이면 정식 stop. 아니면 amplitude 0 만.
            if session.pilotIsWalking {
                session.pilotStop()
            } else {
                _ = session.pilotApplyAmplitude(.stop)
                session.pilotSyncEngine()
            }
            // 머리 moving speed 를 factory default(0=무제한)로 복원 — JointControl /
            // MotionStudio 등 다른 화면이 머리를 정상 속도로 쓰게. best-effort.
            try? store.writeJointMovingSpeed(.headPan, speed: 0)
            try? store.writeJointMovingSpeed(.headTilt, speed: 0)
        }
        lastHeadWriteAt = nil
        // 테스트 데이터 finalize — summary.json write + handle close.
        recorder?.logEvent(.sessionEnd)
        recorder?.finalize()
        recorder = nil
    }

    /// 실 robot 테스트 데이터 recorder 생성 + manifest 기록.
    private func startTestDataRecorder() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        // 파일시스템 안전 sessionId — ISO 의 `:` 제거.
        let sessionId = "cockpit-" + stamp
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String) ?? "unknown"
        let manifest = CockpitPilotManifest(
            sessionId: sessionId,
            startedAtISO: stamp,
            appVersion: appVersion,
            realMotor: realMotorEnabled,
            robotConnected: store.isRobotConnected,
            dxlPowerOn: store.isDxlPowerOn,
            controllerName: cockpit.connectedController,
            balanceCorrectionAtStart: session.enableBalanceCorrection)
        let rec = CockpitPilotRecorder(manifest: manifest)
        rec.logEvent(.sessionStart,
                     detail: "robot=\(store.bus != nil) dxl=\(store.isDxlPowerOn)")
        recorder = rec
    }

    // MARK: - Emergency / Recover (cockpit → session 안전 bridge)

    /// **냉정 점검 CRITICAL fix (4.8)**: cockpit 의 E-STOP 버튼/Space 키가 실 robot
    /// 을 즉시 정지시킨다.
    ///
    /// 종전엔 `cockpit.triggerEmergency()` (HUD flash 만) + `cockpit.release()`
    /// (stick zero) 만 호출 → 실 motor 는 stride-0 freeform 으로 제자리 marching 만
    /// 하다가 2초 dwell 후 graceful stop. 큰 빨강 E-STOP 버튼이 거짓 안심 제공
    /// (기울어지는 robot 에 2초 지연은 위험).
    ///
    /// 본 helper 는 `session.emergencyStop` (hardware torque-off 체인) 을 즉시 호출
    /// + autoDisarm dwell 취소 + 로컬 cockpit state reset 까지 한 곳에서 처리.
    /// **S1 (2026-06-11)**: 모든 입력원이 `cockpit.triggerEmergency()` → `emergencyAt`
    /// onChange 를 거쳐 이 함수로 수렴한다. 따라서 여기서 `triggerEmergency()` 를 다시
    /// 호출하면 onChange 재발화로 무한루프가 된다 — 절대 호출하지 않는다. HUD flash 는
    /// emergencyAt 변경 자체가 구동한다.
    private func cockpitEmergencyStop() {
        cockpit.release()               // stick / heldKeys zero
        autoDisarmTask?.cancel()        // dwell timer 무효화 (emergency 가 우선)
        autoDisarmTask = nil
        // 실 motor hardware emergency — torque off / P_GAIN 0 체인.
        session.emergencyStop(trigger: .userClick)
        recorder?.logEvent(.eStop)
    }

    /// E-STOP 후 복구 — cockpit HUD + session emergency 모드 해제.
    /// **S1 (2026-06-11)**: `recoveryAt` onChange 의 단일 소비자. `triggerRecovery()` 를
    /// 재호출하지 않는다(무한루프 방지) — recoveryAt 변경은 진입점이 이미 수행.
    private func cockpitRecover() {
        if session.pilotIsEmergency {
            session.pilotEmergencyExit()
        }
        recorder?.logEvent(.recover)
    }

    // MARK: - Head motor dispatch

    /// 적분된 머리 각도를 실 모터(servo 19 HEAD_PAN / 20 HEAD_TILT)로 송출.
    ///
    /// 보행 dispatch 와 **동일 게이트**(realMotorEnabled + motorGate)를 통과해야만
    /// write — `writeJointPosition` 은 dxlPower OFF 시 throws + emergencyStop 부작용
    /// 이 있어, 게이트로 그 경로를 사전 차단한다. 100Hz HID jitter 폭주를 막기 위해
    /// 50ms 최소 간격으로 스로틀(≤20Hz/관절). 보행과 독립이라 걸으며 머리 회전 가능.
    ///
    /// **Fix #1 — 보행 중 버스 인터리브 제거**:
    /// 보행 중에는 직접 writeJointPosition 을 호출하지 않는다. 대신 session 의
    /// pending head 버퍼에 raw 값을 저장 → sendStep 이 다리 write 루프 완료 직후
    /// 같은 동기 블록에서 flush (headProvider 경유). 이렇게 하면 다리+머리 write 가
    /// 하나의 직렬화된 step 안에서 순서대로 실행되어 인터리브가 없다.
    private func dispatchHeadIfAllowed() {
        // **SSH parity (W5, 계약 §D.7)**: 온보드 경로에서도 머리 패리티를 위해 머리 각도를
        // 항상 session seam(`onboardHeadPanDeg`/`Tilt`)에 publish 한다. 게이트와 무관하게
        // 갱신해야 `currentWalkingEngineCommand` 가 onboard serializedLine 의 head 필드를
        // 최신 값으로 직렬화한다(로봇이 `Head::MoveByAngle` 로 적용). 직접 servo write 와
        // 독립적인 경로 — 게이트 차단 시에도 의도된 각도는 명령선으로 흐른다.
        session.onboardHeadPanDeg = cockpit.headPanDeg
        session.onboardHeadTiltDeg = cockpit.headTiltDeg

        guard realMotorEnabled, motorGate == nil else {
            // 게이트 차단 시 pending 도 클리어 (torque OFF 상태에서 잔류 명령 제거).
            if session.pilotIsWalking {
                session.pendingHeadPanRaw = nil
                session.pendingHeadTiltRaw = nil
            }
            return
        }

        // **온보드(SSH) 경로 — 직접 servo write 불가**: 로봇이 `/dev/ttyUSB0` 를 점유해
        // Mac bus 가 없다(`store.bus == nil`). 머리는 onboard serializedLine(위 seam)으로
        // 전달되므로 직접 `writeJointPosition` 경로를 건너뛴다(중복/충돌 방지).
        if isOnboardMode {
            if session.pilotIsWalking {
                session.pendingHeadPanRaw = nil
                session.pendingHeadTiltRaw = nil
            }
            return
        }

        let panRaw = Kinematics.raw(fromDegrees: cockpit.headPanDeg)
        let tiltRaw = Kinematics.raw(fromDegrees: cockpit.headTiltDeg)

        if session.pilotIsWalking {
            // 보행 중 — 직접 write 금지. pending 버퍼에 저장 → sendStep 에서 flush.
            session.setPendingHead(panRaw: panRaw, tiltRaw: tiltRaw)
            return
        }

        // 보행 비활성 — 기존 직접 write 경로 (throttle 50ms + freshSession speed 설정).
        let now = Date()
        // 머리 조종 새 시작(첫 write 또는 1초+ 휴지) 시 moving speed 1회 설정 — 모터가
        // 목표각을 적분 rate 와 같은 속도로 끊김없이 추종해 stop-and-go(드드득) 제거.
        // 연속 조종 중엔 재설정하지 않는다.
        let freshSession = lastHeadWriteAt.map { now.timeIntervalSince($0) > 1.0 } ?? true
        if let last = lastHeadWriteAt, now.timeIntervalSince(last) < 0.05 { return }
        lastHeadWriteAt = now
        let panRawU16 = UInt16(clamping: panRaw)
        let tiltRawU16 = UInt16(clamping: tiltRaw)
        // **J2 (2026-06-11)**: 동기 4왕복(speed×2 + position×2) → 코얼레싱 detached
        // SYNC_WRITE(1패킷). dxlPower 게이트·E-STOP·실패 회계는 writeHeadPose 내부.
        // freshSession 일 때만 moving speed 1회 설정(연속 조종 중 재설정 안 함).
        let panSpeed: UInt16? = freshSession
            ? CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: CockpitHeadKinematics.panRateDegPerSec)
            : nil
        let tiltSpeed: UInt16? = freshSession
            ? CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: CockpitHeadKinematics.tiltRateDegPerSec)
            : nil
        store.writeHeadPose(panRaw: panRawU16, tiltRaw: tiltRawU16,
                            panSpeed: panSpeed, tiltSpeed: tiltSpeed)
        recorder?.logEvent(
            .headMove,
            detail: "pan=\(Int(cockpit.headPanDeg)) tilt=\(Int(cockpit.headTiltDeg))")
    }

    // MARK: - Real motor dispatch

    /// `realMotorEnabled` + 안전 조건 모두 충족 시 WalkLabSession 에 실제
    /// amplitude 를 전달. 조건은 다음 순서로 점검 (실패 시 dispatch 차단):
    ///
    /// 1. `realMotorEnabled` 토글이 ON
    /// 2. `store.bus != nil` — robot 이 연결돼 있어야 함
    /// 3. `store.isDxlPowerOn` — 모터 토크가 활성이어야 함
    /// 4. `!session.pilotIsEmergency` — emergency 상태가 아니어야 함
    ///
    /// 조건 미충족이어도 silent: HUD 의 `motorStatusLabel` 가 사유를 보여준다.
    ///
    /// # Auto-ARM (Phase 2.1, DJI Fly 방법론)
    ///
    /// stick 이 active (cmd != stop) + WalkLabSession 이 not walking → freeform
    /// cycle 자동 시작 (`pilotApplyFreeform`). 사용자가 cockpit 의 stick 만 잡으면
    /// robot 이 켜진다. WalkLab 탭에서 별도 ARM 절차 불필요.
    ///
    /// # Auto-DISARM (Phase 2.2)
    ///
    /// stick 이 stop (zero) 이 `autoDisarmDwellSec` 이상 지속되면 `pilotStop()`
    /// 호출. 짧은 release (예: W 잠시 떼고 다시 누름) 에 stop 안 함 (hysteresis).
    ///
    /// # 연속 무중단 경로 (code review HIGH-1 fix)
    ///
    /// 모든 amplitude/period 갱신은 `pilotApplyFreeform` (= `startOrUpdateMobile-
    /// Freeform`) 경유. preset restart (walkReady 멈칫) 없이 단일 연속 task 가
    /// 매 phase 마다 tuning 을 재읽어 motor 에 즉시 반영. 화면 (animator) 과
    /// 실 motor 의 cadence/amplitude 가 연속적으로 일치 (digital twin).
    private func dispatchRealMotorIfAllowed(cmd: WalkingCommand) {
        let action = CockpitDispatchDecision.decide(
            isStickActive: !cmd.isStop,
            realMotorEnabled: realMotorEnabled,
            motorGateOpen: motorGate == nil,
            isWalking: session.pilotIsWalking,
            disarmTimerActive: autoDisarmTask != nil)

        switch action {
        case .noop:
            return

        case .autoArmThenApply:
            // freeform start-or-update 가 idempotent — 보행 미시작 시 자동 start,
            // 진행 중 시 무중단 update. 별도 pilotStart 불필요.
            let started = !session.pilotIsWalking
            applyFreeformAndRecord(cmd)
            if started && session.pilotIsWalking {
                session.pilotPostEvent("Auto-ARM 시작 (Cockpit)",
                                       source: cockpit.lastSource)
                recorder?.logEvent(.autoArm, detail: cockpit.lastSource.label)
            }
            // active 입력이라 dwell timer 취소 (혹시 살아있다면).
            autoDisarmTask?.cancel()
            autoDisarmTask = nil

        case .applyAmplitudeOnly:
            applyFreeformAndRecord(cmd)
            // active 입력이면 dwell timer cancel — 사용자가 다시 stick 잡음.
            if !cmd.isStop {
                autoDisarmTask?.cancel()
                autoDisarmTask = nil
            }

        case .applyAmplitudeAndScheduleDisarm:
            // stick zero + walking 중 → stride 0 freeform (제자리 marching) 유지
            // 하며 dwell 후 정지. 즉시 walkReady 로 끊지 않아 자연스러운 감속.
            applyFreeformAndRecord(cmd)
            scheduleAutoDisarm()
        }
    }

    /// Freeform tuning write + 무중단 갱신 + dispatch 시각 기록.
    ///
    /// **방법론 (ROBOTIS Walking 속도 공식 + 무중단 freeform)**:
    /// `forward_speed_mmps = strideMm × 2000 / periodMs`. amplitude (stick) 와
    /// period (throttle) 둘 다 `pilotApplyFreeform` 으로 전달 → `startOrUpdate-
    /// MobileFreeform` 이 보행 중이면 engine.setCommand + setPeriodMs 를 **재시작
    /// 없이** 직접 갱신. throttle 변화가 walkReady 멈칫 없이 즉시 robot 에 반영.
    private func applyFreeformAndRecord(_ cmd: WalkingCommand) {
        let dispatchStart = Date()
        let accepted = session.pilotApplyFreeform(cmd, periodMs: cockpit.periodMs)
        if accepted {
            lastDispatchAt = dispatchStart
        }
        recordDispatch(cmd: cmd, accepted: accepted)
    }

    /// 실 robot 테스트 데이터에 dispatch 1건 기록 — commanded vs effective (clamp 후)
    /// + 명령 시점 IMU pair + gate. recorder 가 nil 이거나 실 motor 비활성이면 skip.
    private func recordDispatch(cmd: WalkingCommand, accepted: Bool) {
        guard let recorder, realMotorEnabled else { return }
        // 실 motor 가 받는 effective amplitude = mobileFreeformClamp 후 (게이지와 동일).
        let eff = WalkMotionLibrary.mobileFreeformClamp(
            WalkMotionLibrary.AdvancedTuning(
                strideMm: cmd.strideMm, sideMm: cmd.sideMm, turnDeg: cmd.turnDeg,
                periodMs: cockpit.periodMs, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13.0))
        let speed = eff.strideMm * 2000.0 / cockpit.periodMs
        recorder.logDispatch(
            source: cockpit.lastSource.label,
            cmdStrideMm: cmd.strideMm, cmdSideMm: cmd.sideMm,
            cmdTurnDeg: cmd.turnDeg, periodMs: cockpit.periodMs,
            effStrideMm: eff.strideMm, effSideMm: eff.sideMm, effTurnDeg: eff.turnDeg,
            robotSpeedMmPerSec: speed,
            imuRollDeg: currentIMURoll, imuPitchDeg: currentIMUPitch,
            balanceOn: session.enableBalanceCorrection,
            accepted: accepted,
            // **#2 진단 (2026-06-01)**: 조종기 walk 가 거부될 때 generic "freeform-rejected"
            // 대신 구체 사유를 남긴다 — startBlockedReason 이 alreadyWalking / onboardWalking
            // Active / walkCycleTask 잔존 등을 알려줘 "헤드만 됨"의 원인을 다음 테스트에서 즉시 판별.
            gateReason: accepted ? nil
                : (motorGate ?? session.startBlockedReason ?? "freeform-rejected"))
    }

    /// stick zero + walking 중 → dwell 후 자동 stop. 도중 active 입력 들어오면
    /// task cancel (caller responsibility).
    private func scheduleAutoDisarm() {
        let dwellSec = autoDisarmDwellSec
        autoDisarmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(dwellSec * 1_000_000_000))
            if Task.isCancelled { return }
            // **code review LOW-1 fix**: task 참조를 side effect 전에 clear.
            // 종전엔 pilotStop() 후 nil 처리 → 그 사이 re-arm 이 만든 새 task 를
            // 덮어쓸 race 여지. 먼저 nil 로 비우고 side effect 실행.
            autoDisarmTask = nil
            if cockpit.lastCommand.isStop && session.pilotIsWalking {
                session.pilotStop()
                session.pilotPostEvent(
                    "Auto-DISARM (\(Int(dwellSec))s idle)",
                    source: cockpit.lastSource)
                recorder?.logEvent(.autoDisarm, detail: "\(Int(dwellSec))s idle")
            }
        }
    }

    /// **냉정 점검 MINOR fix**: cockpit 이 실 robot 을 능동 제어 중인가 = 실 모터
    /// 토글 ON + WalkLabSession 이 actually walking. 종전 `armed: false` 하드코딩
    /// 은 robot 이 걷는 중에도 "ARMED: false" 거짓 표시했음.
    private var isArmed: Bool {
        realMotorEnabled && session.pilotIsWalking
    }

    /// **온보드(SSH) 모드인가** — ROBOTIS 온보드 엔진 선택 = 로봇이 `/dev/ttyUSB0` 를
    /// 점유하고 자체 보행, Mac 은 SSH 명령선/텔레메트리만 사용(Mac bus 없음).
    private var isOnboardMode: Bool {
        session.walkingEngine == .robotisOnboard
    }

    /// nil = 모든 조건 충족. 아니면 사용자에게 표시할 차단 사유.
    ///
    /// **온보드(SSH) 분기(W5, 계약 §D.5)**: 온보드 모드는 Mac bus 가 없는 게 정상이라
    /// "로봇 미연결" 로 막으면 안 된다. 대신 onboard 텔레메트리/SSH 건강도
    /// (`store.telemetryMode`)로 게이트한다 — 라이브가 아니면 명령이 로봇에 닿는지
    /// 확신할 수 없으므로 차단 사유를 표시한다.
    private var motorGate: String? {
        if !realMotorEnabled { return "실 모터 토글 OFF" }
        if session.pilotIsEmergency { return "긴급 정지 활성 — 복구 필요" }
        if isOnboardMode {
            // 온보드 — bus/DXL 토글 대신 SSH 업링크 건강도로 판정.
            // **GPT 검수 fix**: 브로커리지가 꺼져 있으면 명령이 SSH 로 안 나간다 →
            // "dispatch 활성" 거짓 표시 방지. 차단 사유 명시.
            if !session.autoOnboardBrokering { return "온보드 브로커리지 OFF — 재연결 필요" }
            switch store.telemetryMode {
            case .onboard:      break                               // 라이브 — 통과.
            case .onboardStale: return "온보드 텔레메트리 지연 — SSH 응답 확인"
            case .lan:          return "엔진=온보드인데 경로=LAN — 온보드 시작 필요"
            case .offline:      return "온보드 오프라인 — SSH/데몬 연결 필요"
            }
        } else {
            if store.bus == nil { return "로봇 미연결" }
            if !store.isDxlPowerOn { return "DXL 전원 ON 실패 — 실 모터 토글 다시 시도" }
        }
        // **자동 일어나기 우선** — recovery 진행 중에는 조종(보행·머리) dispatch 를
        // 차단해 get-up 모션이 같은 bus 를 두고 경쟁/충돌하지 않게 한다. walk 와 head
        // dispatch 가 모두 본 gate 를 거치므로 한 곳에서 일괄 차단된다.
        if session.autoRecoveryPhase != .idle { return "자동 일어나기 중 — 조종 일시 차단" }
        return nil
    }

    // MARK: - 자이로 보정 toggle binding + 상태

    /// `session.enableBalanceCorrection` 을 SwiftUI Toggle 에 bind. @Observable 매크
    /// 로 사용 중 (`@Environment(WalkLabSession.self)`) 이라 `$session` 으로 Binding
    /// 직접 못 만듦 — 명시 get/set 의 Binding 합성.
    private var balanceCorrectionBinding: Binding<Bool> {
        Binding(
            get: { session.enableBalanceCorrection },
            set: { newValue in
                session.enableBalanceCorrection = newValue
                recorder?.logEvent(newValue ? .balanceOn : .balanceOff)
            })
    }

    /// 자이로 보정 실시간 상태 dot 색상. 사용자가 "지금 보정 동작 중인가" 즉시 인지.
    ///
    /// - **green**: ON + 최근 corrections 적용됨 (lastCorrectionApplied=true) + IMU fresh
    /// - **amber**: ON 인데 IMU stale 또는 corrections 미적용 (가만히 서있을 때)
    /// - **gray**: OFF
    private var balanceCorrectionStatusColor: Color {
        guard session.enableBalanceCorrection else { return Color.gray.opacity(0.4) }
        // lastCorrectionApplied true = 직전 step 에 보정 active.
        if session.lastCorrectionApplied {
            return CockpitColors.live  // green
        }
        return CockpitColors.warn  // amber (보정 ON 인데 적용 안 됨)
    }
}

// MARK: - Mouse joystick pad

/// Mouse-drag virtual joystick used inside the cockpit's bottom bar.
struct MouseJoystickPad: View {
    @ObservedObject var cockpit: CockpitState

    @State private var offset: CGSize = .zero
    @State private var dragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let thumb: CGFloat = size * 0.30
            let maxOff: CGFloat = (size - thumb) / 2 - 6

            ZStack {
                Circle().fill(Color.black.opacity(0.55))
                Circle()
                    .stroke(CockpitColors.live.opacity(dragging ? 0.85 : 0.45),
                            lineWidth: 1.4)
                Circle()
                    .fill(CockpitColors.live.opacity(dragging ? 0.18 : 0.05))
                    .frame(width: size * 0.6, height: size * 0.6)
                Circle()
                    .fill(CockpitColors.live)
                    .frame(width: thumb, height: thumb)
                    .overlay(Image(systemName: "dot.circle.fill")
                        .foregroundStyle(.black.opacity(0.5))
                        .imageScale(.small))
                    .offset(offset)
                    .shadow(color: CockpitColors.live.opacity(0.6),
                            radius: dragging ? 10 : 4)
                    .animation(.interactiveSpring(response: 0.18,
                                                  dampingFraction: 0.7),
                               value: offset)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let constrained = constrain(
                            CGSize(width: value.translation.width,
                                   height: value.translation.height),
                            max: maxOff)
                        offset = constrained
                        cockpit.apply(
                            leftX: Double(constrained.width / maxOff),
                            leftY: Double(constrained.height / maxOff),
                            turn: cockpit.rightStick.x,
                            from: .virtualJoystick)
                    }
                    .onEnded { _ in
                        offset = .zero
                        dragging = false
                        cockpit.apply(leftX: 0, leftY: 0,
                                      turn: cockpit.rightStick.x,
                                      from: .virtualJoystick)
                    }
            )
        }
    }

    private func constrain(_ s: CGSize, max: CGFloat) -> CGSize {
        let length = sqrt(s.width * s.width + s.height * s.height)
        if length <= max { return s }
        let scale = max / length
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}

// MARK: - Keyboard hotkeys (WASD/QE/Space/R)

private struct CockpitKeyboardHotkeys: View {
    @ObservedObject var cockpit: CockpitState
    /// Space 키 — cockpit + session 동시 emergency (CRITICAL fix). 부모가 주입.
    let onEmergency: () -> Void
    /// R 키 — cockpit + session 동시 recover. 부모가 주입.
    let onRecover: () -> Void
    var body: some View {
        // **방법론 (검증된 SwiftUI keyboardShortcut + OS auto-repeat)**:
        // 각 키마다 hidden button + `.keyboardShortcut`. OS 가 hold 시 ~30ms 마다
        // auto-repeat fire — 사용자가 hold 하면 cockpit.markKeyPressed 가 매번
        // 호출되어 250ms timer 가 reset → keyPressed 유지. release 시 250ms 후
        // timer expire 또는 monitor 가 keyUp 받아 즉시 release.
        ZStack {
            // **HIGH #2 fix**: heldKeys 직접 mutation 제거. state.insertHeldKey 만
            // 사용 → 단일 source-of-truth + 자동 applyHeldKeys.
            holdHotkey("w", apply: { $0.insertHeldKey("w") })
            holdHotkey("s", apply: { $0.insertHeldKey("s") })
            holdHotkey("a", apply: { $0.insertHeldKey("a") })
            holdHotkey("d", apply: { $0.insertHeldKey("d") })
            holdHotkey("q", apply: { $0.insertHeldKey("q") })
            holdHotkey("e", apply: { $0.insertHeldKey("e") })
            hotkey(" ", marking: " ", action: onEmergency)
            hotkey("r", marking: "r", action: onRecover)
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Hold hotkey — fire 시 heldKeys.insert + applyHeldKeys + 250ms timer 로
    /// auto-release. OS auto-repeat 가 hold 동안 매번 timer reset 하므로 키 유지.
    private func holdHotkey(_ key: Character,
                            apply: @escaping (CockpitState) -> Void) -> some View {
        Button(action: {
            cockpit.markKeyPressed(key)
            apply(cockpit)
            // 250ms timer: 키 release 시 keyUp event 가 monitor 에 안 잡혀도 자동 클리어.
            cockpit.scheduleHeldKeyAutoRelease(key)
        }) { EmptyView() }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    private func hotkey(_ key: Character,
                        marking: Character,
                        action: @escaping () -> Void) -> some View {
        Button(action: {
            cockpit.markKeyPressed(marking)
            action()
        }) { EmptyView() }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
    }
}

// MARK: - WASD/QE compact overlay (좌측 instrument column 용)

/// 좌측 instrument column 에 들어가는 compact 키 표시. 사용성 / 가독성을 위해
/// 키캡을 30×30 px 로 줄이고, 화살표 아이콘 + 작은 라벨만 표시. WASD 행과 QE
/// 행을 vertically 쌓고, E-Stop/Recover 는 별도 row.
///
/// **방법론**: 시뮬레이터 cockpit UX — 핵심 입력 표시는 시야 가장자리에 두어
/// 메인 scene 가독성을 우선한다 (FPV 드론 OSD 와 동일 패턴).
struct CockpitKeyboardOverlayCompact: View {
    @ObservedObject var cockpit: CockpitState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("KEY")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 3) {
                keyCap("Q", icon: "arrow.turn.up.left", active: isPressed("q"))
                keyCap("W", icon: "arrow.up", active: isPressed("w"))
                keyCap("E", icon: "arrow.turn.up.right", active: isPressed("e"))
            }
            HStack(spacing: 3) {
                keyCap("A", icon: "arrow.left", active: isPressed("a"))
                keyCap("S", icon: "arrow.down", active: isPressed("s"))
                keyCap("D", icon: "arrow.right", active: isPressed("d"))
            }
            HStack(spacing: 3) {
                wideCap("SPC", active: isPressed(" "), tone: CockpitColors.danger)
                wideCap("R", active: isPressed("r"), tone: CockpitColors.live)
            }
        }
        .cockpitPanel(tint: CockpitColors.live, strokeOpacity: 0.25, padding: 12)
    }

    private func isPressed(_ key: Character) -> Bool {
        cockpit.keyPressed.contains(key)
    }

    private func keyCap(_ label: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
            Image(systemName: icon)
                .imageScale(.medium)
        }
        .foregroundStyle(active ? .black : .white.opacity(0.7))
        .frame(width: CockpitMetrics.keyCap, height: CockpitMetrics.keyCap)
        .background(active ? CockpitColors.live : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(active ? CockpitColors.live : Color.white.opacity(0.2),
                        lineWidth: 1)
        )
        .shadow(color: active ? CockpitColors.live.opacity(0.7) : .clear,
                radius: active ? 4 : 0)
        .animation(.easeOut(duration: 0.08), value: active)
    }

    private func wideCap(_ label: String, active: Bool, tone: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundStyle(active ? .black : .white.opacity(0.7))
            .frame(width: CockpitMetrics.keyCapWide, height: 26)
            .background(active ? tone : Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(active ? tone : Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: active ? tone.opacity(0.7) : .clear,
                    radius: active ? 4 : 0)
            .animation(.easeOut(duration: 0.08), value: active)
    }
}

// MARK: - WASD/QE 큰 overlay (보존 — 미래 다른 화면에서 재활용 가능)

struct CockpitKeyboardOverlay: View {
    @ObservedObject var cockpit: CockpitState

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Spacer()
                keyCap("Q", icon: "arrow.turn.up.left", active: isPressed("q"))
                keyCap("W", icon: "arrow.up", active: isPressed("w"))
                keyCap("E", icon: "arrow.turn.up.right", active: isPressed("e"))
                Spacer()
            }
            HStack(spacing: 4) {
                Spacer()
                keyCap("A", icon: "arrow.left", active: isPressed("a"))
                keyCap("S", icon: "arrow.down", active: isPressed("s"))
                keyCap("D", icon: "arrow.right", active: isPressed("d"))
                Spacer()
            }
            HStack(spacing: 4) {
                Spacer()
                wideKeyCap("SPACE", label: "E-STOP",
                           active: isPressed(" "),
                           tone: CockpitColors.danger)
                wideKeyCap("R", label: "복구",
                           active: isPressed("r"),
                           tone: CockpitColors.live)
                Spacer()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(CockpitColors.panel.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(CockpitColors.live.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private func isPressed(_ key: Character) -> Bool {
        cockpit.keyPressed.contains(key)
    }

    private func keyCap(_ label: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
            Image(systemName: icon)
                .imageScale(.small)
        }
        .foregroundStyle(active ? .black : .white.opacity(0.75))
        .frame(width: 42, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? CockpitColors.live : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(active ? CockpitColors.live : Color.white.opacity(0.25),
                        lineWidth: 1)
        )
        .shadow(color: active ? CockpitColors.live.opacity(0.7) : .clear,
                radius: active ? 6 : 0)
        .animation(.easeOut(duration: 0.08), value: active)
    }

    private func wideKeyCap(_ key: String,
                            label: String,
                            active: Bool,
                            tone: Color) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .opacity(0.85)
        }
        .frame(width: 90, height: 26)
        .foregroundStyle(active ? .black : .white.opacity(0.75))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? tone : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(active ? tone : Color.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: active ? tone.opacity(0.7) : .clear,
                radius: active ? 6 : 0)
        .animation(.easeOut(duration: 0.08), value: active)
    }
}

// MARK: - Telemetry staleness desaturation (W5)

private extension View {
    /// 텔레메트리가 stale 일 때 HUD 계기를 무채색·반투명으로 강등.
    /// `stale == false` 면 원본 그대로(no-op). LAN stale / 온보드 지연 시 사용자가
    /// "지금 표시값은 보존된 과거값"임을 색으로 인지하게 한다(계약 §D.5/§F-7).
    @ViewBuilder
    func cockpitTelemetryStale(_ stale: Bool) -> some View {
        if stale {
            self.saturation(0).opacity(0.6)
        } else {
            self
        }
    }
}
