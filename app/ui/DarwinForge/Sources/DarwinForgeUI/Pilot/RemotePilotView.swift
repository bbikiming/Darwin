import ForgeCore
import OSLog
import SwiftUI

/// Remote Pilot 메인 화면 — ⌘8.
///
/// 레이아웃 (Apple HIG + 반응형):
/// - `wide` (≥1280): 좌 380px 컨트롤 + 우 fill (카메라/3D/HUD)
/// - `regular` (820..1280): 좌 340px + 우 fill
/// - `compact` (<820): 세로 단일 컬럼, 3D 뷰 우선
///
/// 모든 좌측 컨트롤은 ScrollView 로 감싸 작은 윈도우에서도 잘리지 않음.
/// 모든 카드는 `DFPanel` 표준 — Studio/Teach 등 기존 view 와 일관성.
public struct RemotePilotView: View {
    @EnvironmentObject private var store: ConnectionStore
    @EnvironmentObject private var remoteShell: RemoteShell
    @StateObject private var gate = PilotSafetyGate()
    @StateObject private var channel = TeleopChannel()
    @StateObject private var headTracker = PilotHeadTracker()
    /// HSV preset — Phase E. Mac default 로 시작, robot 에서 load 시 갱신.
    @State private var hsvPreset: VisionHsvPreset = .macDefault

    @State private var mode: PilotMode = .manual
    @State private var demoStatus: PilotDemoStatus = .idle
    @State private var speedFraction: Double = 0.5
    @State private var meshFallback: Bool = false
    /// status polling task — onAppear 에서 시작, onDisappear 에서 cancel.
    @State private var statusPollTask: Task<Void, Never>? = nil
    /// 가장 최근 mode 전환 의도 (사용자가 picker 누른 값) — failure 시 mode 자동 복구 비교용.
    @State private var pendingModeChange: PilotMode? = nil
    /// robot 측 patched demo-pilot 설치 여부 — onAppear 에서 1회 확인.
    @State private var patchedDemoInstalled: Bool? = nil
    /// 모드 전환 step driver — overlay 가 표시할 단계 + 현재 active index.
    @State private var transitionTitle: String = ""
    @State private var transitionSteps: [PilotTransitionStep] = []
    @State private var transitionActiveIndex: Int? = nil
    /// 사용자가 .waitingForUser step 에서 "다음" 누르면 fulfill 되는 continuation.
    @State private var waitingForUserAdvance: CheckedContinuation<Void, Never>? = nil
    /// 사용자 cancel — 진행 중인 transition task 중단.
    @State private var transitionTask: Task<Void, Never>? = nil

    @Environment(\.dfResponsiveSize) private var responsive

    /// 사용자 선택 가능한 활성 단계 — @AppStorage 로 즉시 반영 (Codex 권고 2026-05-13).
    /// 이전 v1.0 의 `static let active` 는 앱 재시작 전까지 고정 → feature picker 안 됨.
    @AppStorage("df.pilot.featureLevel") private var featureLevelRaw: String = PilotFeatureLevel.v1_5.rawValue

    private var level: PilotFeatureLevel {
        PilotFeatureLevel(rawValue: featureLevelRaw) ?? .v1_5
    }

    private var flags: PilotFeatureFlags { level.flags }

    /// demo 모드가 USB bus 를 점유했는지 — Action Bar / D-pad / ARM 비활성에 사용.
    /// `.ballFollow` 가 사용자 의도이고 status 가 launching/active 이면 demo 가 활성.
    var demoOccupiesBus: Bool {
        switch demoStatus {
        case .ballFollowActive, .launching: return true
        case .idle, .stopping, .manualActive, .failure: return false
        }
    }

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < ResponsiveBreakpoints.compact
            let leftWidth: CGFloat = geo.size.width < 1100 ? 340 : (geo.size.width < 1400 ? 380 : 420)

            ZStack(alignment: .top) {
                Group {
                    if isCompact {
                        compactLayout
                    } else {
                        wideLayout(leftWidth: leftWidth)
                    }
                }
                .padding(DFSpace.md)

                topBanner
                    .padding(.top, DFSpace.sm)
                    .padding(.horizontal, DFSpace.md)

                if !transitionSteps.isEmpty {
                    transitionOverlayLayer
                }
            }
            .overlay(toastOverlay, alignment: .bottom)
        }
        .background(DFColor.canvas)
        .onAppear {
            // 2026-05-16: 자동 RemoteShell 호출 제거 — 사용자 명시 요청.
            // 종전엔 onAppear 가 `startStatusPolling()` + `checkPatchedDemoOnce()` 즉시
            // 호출 → 두 함수가 `remoteShell.send` → SSH key 미셋업 시 SMB fallback →
            // `NSWorkspace.shared.open(smb://192.168.123.1/robotis)` → macOS Finder
            // 다이얼로그 자동 팝업 (사용자 의도 안 한 SMB 인증 요청).
            // 새 정책: ROBOTIS 측 통신 (RemoteShell.send) 은 사용자가 명시적으로
            // "상태 확인" 또는 "데모 시작" 버튼 누를 때만. attach 만 수행.
            channel.attach(store: store, gate: gate)
            headTracker.attach(store: store, gate: gate)
        }
        .onDisappear {
            statusPollTask?.cancel()
            statusPollTask = nil
        }
        .onReceive(store.$bus.dropFirst()) { _ in
            // 연결/끊김 시 ARM 자동 해제 — 안전.
            channel.disarm()
        }
        .onChange(of: mode) { _, newMode in
            Task { await handleModeChange(to: newMode) }
        }
    }

    // MARK: - Demo status polling (Sprint 18 — 한계 6 해결)

    /// `RobotSetupCommand.ballTrackerStatus` 를 10초 주기로 발송 → demoStatus 자동 갱신.
    /// ⌘6 에서 직접 데모를 띄워도 30초 내에 ⌘8 picker 가 반영. v1.5 가 아닐 때는 skip.
    private func startStatusPolling() {
        statusPollTask?.cancel()
        guard flags.ballFollow else { return }
        statusPollTask = Task { @MainActor in
            // 진입 즉시 1회.
            await pollOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                await pollOnce()
            }
        }
    }

    /// patched demo-pilot 설치 여부 확인 — onAppear 에서 1회.
    /// 결과의 첫 줄에 `DF_PATCH=installed` 또는 `DF_PATCH=missing` marker.
    private func checkPatchedDemoOnce() async {
        guard flags.ballFollow else { return }
        let trimmedHost = remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        let priorCount = remoteShell.history.count
        await remoteShell.send(RobotSetupCommand.demoPatchedStatus)
        let lastExchange = remoteShell.history.indices.contains(priorCount)
            ? remoteShell.history[priorCount]
            : remoteShell.history.last
        guard let result = lastExchange?.result else { return }

        let firstLine = result.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch firstLine {
        case "DF_PATCH=installed": patchedDemoInstalled = true
        case "DF_PATCH=missing":   patchedDemoInstalled = false
        default:                   break  // 명령 자체 실패 — 미확인 유지.
        }
    }

    /// 한 번 status 명령 발송 후 demoStatus 갱신.
    /// 변환 중인 상태 (.launching / .stopping / .failure) 에서는 polling 결과로 덮어쓰지 않음
    /// — 사용자의 명시적 의도를 우선.
    private func pollOnce() async {
        // 사용자가 이미 모드 전환을 진행 중이면 polling 결과 무시 (race 방지).
        switch demoStatus {
        case .launching, .stopping: return
        case .idle, .ballFollowActive, .manualActive, .failure: break
        }
        // host 정보가 없으면 send 시도 자체 skip — RemoteShell 이 어쨌든 실패할 것.
        let trimmedHost = remoteShell.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        let priorCount = remoteShell.history.count
        await remoteShell.send(RobotSetupCommand.ballTrackerStatus)
        let lastExchange = remoteShell.history.indices.contains(priorCount)
            ? remoteShell.history[priorCount]
            : remoteShell.history.last

        guard let result = lastExchange?.result,
              let parsed = PilotDemoStatusParser.parse(result) else { return }

        // failure 상태에 있던 사용자에게는 success polling 결과를 그대로 덮어씀 (정직).
        // ballFollowActive ↔ manualActive 자동 전환은 사용자가 ⌘6 에서 직접 띄운 경우 자동 동기화.
        demoStatus = parsed
        // polling 결과로 mode 도 동기화 — 사용자가 보는 picker 가 실제 상태와 일치.
        switch parsed {
        case .ballFollowActive:
            if mode != .ballFollow { mode = .ballFollow }
        case .manualActive, .idle:
            if mode != .manual { mode = .manual }
        default: break
        }
    }

    // MARK: - Mode change → ROBOTIS demo 명령 발송

    // MARK: - Transition overlay layer (Sprint 18 Phase C — 단계별 도움말 + 진행률)

    /// 모드 전환 중에 표시되는 dim background + 모달 — 사용자 시선을 단계에 집중.
    @ViewBuilder
    private var transitionOverlayLayer: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .transition(.opacity)
            PilotTransitionOverlay(
                title: transitionTitle,
                steps: transitionSteps,
                activeIndex: transitionActiveIndex,
                // **사이클 119 (audit #15, P0)**: patched demo 설치 → 실 진행 polling.
                // 그 외 → `Task.sleep(estimatedSeconds)` 만 → "추정 진행" 사용자 명시.
                usesRealPolling: (mode == .ballFollow && patchedDemoInstalled == true),
                onAdvance: { advanceUserStep() },
                onCancel: { cancelTransition() }
            )
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: transitionActiveIndex)
        .accessibilityIdentifier("pilot.transition.layer")
    }

    /// 사용자가 후면 버튼을 눌렀음을 알리는 액션 — waitingForUser step 진행.
    private func advanceUserStep() {
        // step_id 추출 — activeIndex nil 또는 out-of-range 시 "unknown" 으로 처리.
        let stepId: String = {
            guard let activeIdx = transitionActiveIndex,
                  transitionSteps.indices.contains(activeIdx) else { return "unknown" }
            return transitionSteps[activeIdx].id
        }()
        harness.record(
            .pilotTransitionAdvance, level: .info, actor: .user,
            data: ["step_index": AnyCodable(transitionActiveIndex ?? -1),
                   "step_id": AnyCodable(stepId)])
        waitingForUserAdvance?.resume()
        waitingForUserAdvance = nil
    }

    /// 사용자가 cancel 누름 — task 중단 + step UI 정리.
    private func cancelTransition() {
        harness.record(
            .pilotTransitionCancel, level: .info, actor: .user,
            data: ["step_index": AnyCodable(transitionActiveIndex ?? -1),
                   "step_count": AnyCodable(transitionSteps.count)])
        transitionTask?.cancel()
        transitionTask = nil
        // continuation 도 정리 — leak 방지.
        waitingForUserAdvance?.resume()
        waitingForUserAdvance = nil
        transitionSteps = []
        transitionActiveIndex = nil
        // demoStatus 는 그대로 유지 (이미 변경됐을 수 있음).
    }

    /// step 의 kind 업데이트 — completed / failed.
    private func updateStep(at index: Int, kind: PilotTransitionStep.Kind) {
        guard transitionSteps.indices.contains(index) else { return }
        transitionSteps[index].kind = kind
    }

    /// Pilot mode 변경 시 robot 측 데몬 전환 + step-by-step overlay.
    ///
    /// 흐름 (Phase C):
    ///   1. 시나리오 선택 (patched / original / manualRecovery)
    ///   2. overlay 표시 + 명령 발송 (async)
    ///   3. 자동 step 들은 estimatedSeconds 동안 fake progress
    ///   4. waitingForUser step 은 사용자가 "후면 버튼 눌렀음" 클릭 대기
    ///   5. 마지막 step 에 명령 결과 반영 (.completed / .failed)
    ///   6. overlay dismiss + demoStatus 갱신
    private func handleModeChange(to newMode: PilotMode) async {
        guard flags.ballFollow else { return }

        // Idempotent guard — polling 으로 mode 가 set 된 경우 명령 재발송 skip.
        let alreadyInDesiredState: Bool = {
            switch (newMode, demoStatus) {
            case (.ballFollow, .ballFollowActive): return true
            case (.manual, .manualActive), (.manual, .idle): return true
            default: return false
            }
        }()
        if alreadyInDesiredState { return }

        pendingModeChange = newMode

        harness.record(
            .pilotDemoModeRequested, level: .info, actor: .user,
            data: ["from_mode": AnyCodable(mode == .ballFollow ? "ballFollow" : "manual"),
                   "to_mode": AnyCodable(newMode == .ballFollow ? "ballFollow" : "manual"),
                   "patched_demo": AnyCodable(patchedDemoInstalled ?? false)])

        // 진행 중 ARM 은 명시 disarm — demo 가 bus 를 곧 점유.
        if newMode == .ballFollow && gate.armed {
            channel.disarm()
        }

        // 시나리오별 step 시퀀스.
        let steps: [PilotTransitionStep]
        let title: String
        let command: String
        switch newMode {
        case .ballFollow:
            steps = (patchedDemoInstalled == true)
                ? PilotTransitionFlow.ballFollowPatched()
                : PilotTransitionFlow.ballFollowOriginal()
            title = "공 자동 추적 시작"
            command = RobotSetupCommand.ballTrackerStart
            demoStatus = .launching
        case .manual:
            steps = PilotTransitionFlow.manualRecovery()
            title = "수동 모드 복구"
            command = RobotSetupCommand.demoStop
            demoStatus = .stopping
        }

        transitionTitle = title
        transitionSteps = steps
        transitionActiveIndex = 0

        // 명령은 백그라운드로 발송 — step driver 가 별도로 fake progress.
        let priorCount = remoteShell.history.count
        let sendTask: Task<Void, Never> = Task { @MainActor in
            await remoteShell.send(command)
        }

        // Step driver — cancel 가능한 task 로 추적.
        let driver = Task { @MainActor in
            await runStepDriver()
        }
        transitionTask = driver
        await driver.value

        // 명령 완료 대기 — 사용자가 cancel 안 한 경우.
        await sendTask.value

        // 결과 파싱.
        let lastExchange = remoteShell.history.indices.contains(priorCount)
            ? remoteShell.history[priorCount]
            : remoteShell.history.last
        let result = (lastExchange?.result ?? "") + (lastExchange?.error.map { "\nERR: \($0)" } ?? "")
        let success = lastExchange?.error == nil &&
            !result.lowercased().contains("not found") &&
            !result.lowercased().contains("failed to start") &&
            !result.lowercased().contains("미설치")

        if success {
            harness.record(
                .pilotDemoModeResult, level: .info, actor: .system,
                data: ["mode": AnyCodable(newMode == .ballFollow ? "ballFollow" : "manual"),
                       "success": AnyCodable(true)])
            // 마지막 step 을 completed 로.
            if let last = transitionSteps.indices.last {
                updateStep(at: last, kind: .completed)
            }
            demoStatus = (newMode == .ballFollow) ? .ballFollowActive : .manualActive
            pendingModeChange = nil
            // 1초 후 overlay dismiss — 사용자가 결과 확인 시간.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            transitionSteps = []
            transitionActiveIndex = nil
        } else {
            let snippet = result.split(separator: "\n")
                .first(where: { !$0.hasPrefix("DF_STATUS=") })
                .map(String.init) ?? "원격 명령 실패"
            // PII-safe: SSH error 원문 대신 hash 만 telemetry 기록.
            harness.record(
                .pilotDemoModeResult, level: .warn, actor: .system,
                data: ["mode": AnyCodable(newMode == .ballFollow ? "ballFollow" : "manual"),
                       "success": AnyCodable(false),
                       "error_hash": AnyCodable(Harness.shortHash(snippet))])
            // 마지막 active step 또는 첫 step 을 failed 로.
            let idx = transitionActiveIndex ?? 0
            updateStep(at: idx, kind: .failed(snippet))
            demoStatus = .failure(snippet)

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard pendingModeChange == newMode else { return }
                if newMode == .ballFollow {
                    mode = .manual
                    demoStatus = .manualActive
                } else {
                    demoStatus = .idle
                }
                transitionSteps = []
                transitionActiveIndex = nil
                pendingModeChange = nil
            }
        }
    }

    /// step 시퀀스 진행기 — progress 파일 polling (patched ballFollow) 또는 estimated fake.
    ///
    /// **Phase D1 (Sprint 18)**: patched demo 가 `/tmp/df-pilot-progress` 에 단계 ID 기록 →
    /// Mac 이 1초 polling 으로 실제 진행 단계 sync. fake progress 가 아닌 real progress.
    private func runStepDriver() async {
        // ballFollow + patched + ballFollowPatched flow 의 경우 progress polling 활성.
        let usesProgressPoll = (mode == .ballFollow && patchedDemoInstalled == true)
        for idx in transitionSteps.indices {
            if Task.isCancelled { return }
            transitionActiveIndex = idx
            let step = transitionSteps[idx]
            switch step.kind {
            case .automatic:
                if usesProgressPoll && idx > 0 {
                    // Progress 파일 polling — robot 측에서 우리 step.id 에 도달할 때까지 대기.
                    let reached = await pollUntilStage(step.id,
                                                       timeoutSeconds: max(5, Int(step.estimatedSeconds * 4)))
                    if Task.isCancelled { return }
                    if !reached && idx < transitionSteps.count - 1 {
                        // timeout 시에도 일단 진행 — 마지막 명령 결과가 final 판정.
                    }
                } else {
                    // estimated fake progress — patched 아닌 시나리오 (원본 demo / manual recovery).
                    let ns = UInt64(step.estimatedSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: ns)
                }
                if Task.isCancelled { return }
                if idx < transitionSteps.count - 1 {
                    updateStep(at: idx, kind: .completed)
                }
            case .waitingForUser:
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    waitingForUserAdvance = cont
                }
                if Task.isCancelled { return }
                updateStep(at: idx, kind: .completed)
            case .completed, .failed:
                continue
            }
        }
    }

    /// patched demo 의 progress 파일을 polling — `target` 단계에 도달하거나 timeout.
    /// progress order (robot 측 demoInjectBlock 작성 순서):
    /// "start-demo" → "auto-soccer-mode" → "walk-ready" → "gyro-calibration" → "tracking-active".
    private func pollUntilStage(_ target: String, timeoutSeconds: Int) async -> Bool {
        let order = ["start-demo", "auto-soccer-mode", "walk-ready",
                     "gyro-calibration", "tracking-active"]
        guard let targetIdx = order.firstIndex(of: target) else {
            // 우리 step.id 가 robot stage 와 다른 시나리오 — fake 로 fallback.
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 100_000_000)
            return false
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if Task.isCancelled { return false }
            let priorCount = remoteShell.history.count
            await remoteShell.send(RobotSetupCommand.demoProgressRead)
            let lastEx = remoteShell.history.indices.contains(priorCount)
                ? remoteShell.history[priorCount]
                : remoteShell.history.last
            let result = lastEx?.result ?? ""
            let firstLine = result.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if firstLine.hasPrefix("DF_STAGE=") {
                let stage = String(firstLine.dropFirst("DF_STAGE=".count))
                if let robotIdx = order.firstIndex(of: stage), robotIdx >= targetIdx {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // 1Hz polling.
        }
        return false
    }

    // MARK: - Layouts

    @ViewBuilder
    private func wideLayout(leftWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: DFSpace.md) {
            leftPanel
                .frame(width: leftWidth)

            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var compactLayout: some View {
        // 좁은 윈도우 — 세로 단일 컬럼. 우선순위: 3D + 진단 → ARM → Action Bar → 나머지.
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                headerBlock
                robot3DPanel
                    .frame(height: 280)
                PilotDiagnosticsPanel(store: store, channel: channel)
                hudPanel
                PilotArmSlider(channel: channel, gate: gate, demoOccupiesBus: demoOccupiesBus)
                PilotActionBar(channel: channel, gate: gate, flags: flags,
                               demoOccupiesBus: demoOccupiesBus)
                PilotModePicker(mode: $mode, flags: flags, demoStatus: demoStatus,
                                patchedDemoInstalled: patchedDemoInstalled)
                PilotSpeedGauge(speedFraction: $speedFraction)
                PilotDpad(channel: channel, gate: gate, flags: flags)
                cameraPanel
            }
        }
    }

    private var leftPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                headerBlock
                PilotModePicker(mode: $mode, flags: flags, demoStatus: demoStatus,
                                patchedDemoInstalled: patchedDemoInstalled)
                PilotArmSlider(channel: channel, gate: gate, demoOccupiesBus: demoOccupiesBus)
                PilotActionBar(channel: channel, gate: gate, flags: flags,
                               demoOccupiesBus: demoOccupiesBus)
                PilotDiagnosticsPanel(store: store, channel: channel)
                PilotSpeedGauge(speedFraction: $speedFraction)
                PilotDpad(channel: channel, gate: gate, flags: flags)
            }
            .padding(.bottom, DFSpace.md)
        }
        .frame(maxHeight: .infinity)
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            cameraPanel
                .frame(height: cameraHeight)
            robot3DPanel
                .frame(maxHeight: .infinity)
            hudPanel
        }
    }

    private var cameraHeight: CGFloat {
        switch responsive {
        case .compact: return 200
        case .regular: return 240
        case .wide:    return 280
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(DFColor.accent)
                Text("원격 조종")
                    .font(DFFont.title)
                Spacer(minLength: 0)
                featurePickerMenu
            }
            HStack(spacing: DFSpace.xs2) {
                Text(level.rawValue)
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.accent)
                    .padding(.horizontal, DFSpace.xs2).padding(.vertical, 2)
                    .background(Capsule().fill(DFColor.accent.opacity(DFOpacity.subtle)))
                Text(level.subtitle)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 작은 Menu picker — 우상단. UserDefaults 즉시 반영.
    private var featurePickerMenu: some View {
        Menu {
            ForEach(PilotFeatureLevel.allCases) { lv in
                Button {
                    let oldLevel = level.rawValue
                    featureLevelRaw = lv.rawValue
                    harness.record(
                        .pilotFeatureLevelChanged, level: .info, actor: .user,
                        data: ["from": AnyCodable(oldLevel),
                               "to": AnyCodable(lv.rawValue)])
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(lv.label)
                            Text(lv.subtitle).font(DFFont.caption)
                        }
                    } icon: {
                        Image(systemName: lv == level ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(level.label)
                    .font(DFFont.caption.monospaced())
                Image(systemName: "chevron.down")
                    .font(.system(size: DFFontSize.s10, weight: .semibold))
            }
            .padding(.horizontal, DFSpace.xs2).padding(.vertical, 2)
            .background(
                Capsule().fill(DFColor.elev2)
                    .overlay(Capsule().stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: DFSize.borderHairline))
            )
            .foregroundStyle(DFColor.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pilot 활성 단계 — 즉시 반영")
        .accessibilityIdentifier("pilot.feature.picker")
    }

    // MARK: - 3D 로봇 뷰

    private var robot3DPanel: some View {
        DFPanel(
            "3D 시뮬레이션",
            subtitle: simStatusText,
            icon: "cube.transparent",
            tint: DFColor.success,
            trailing: {
                if let slot = channel.playingSlot, let meta = MotionCatalog.find(slot: slot) {
                    DFChip(meta.displayNameKo, icon: meta.icon, style: .success)
                } else if gate.armed {
                    DFChip("ARM", icon: "lock.open.fill", style: .success)
                } else {
                    DFChip("잠금", icon: "lock.fill", style: .neutral)
                }
            }
        ) {
            ZStack(alignment: .bottomLeading) {
                RobotScene3D(
                    pose: livePose,
                    footTrace: [],
                    highlight: nil,
                    showAxes: true,
                    onMeshFallback: { fallback in meshFallback = fallback },
                    preset: .cockpit
                )
                .background(
                    LinearGradient(
                        colors: [DFColor.canvas.opacity(DFOpacity.dim), DFColor.canvas],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))

                if meshFallback {
                    meshFallbackBanner
                        .padding(DFSpace.sm)
                }

                // 조명·머티리얼 튜닝 — 우상단(이 화면은 top-trailing 비어 있음).
                SceneTuningControl()
                    .padding(DFSpace.sm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 220)
        }
    }

    /// 현재 화면에 그릴 자세 — 진행 중이면 target, ARM 만 됐으면 walkReady, 아니면 idle.
    private var livePose: RobotPose {
        if let slot = channel.playingSlot,
           let poseID = MotionCatalog.find(slot: slot)?.v1TargetPoseID,
           let pose = PoseLibrary.get(poseID)?.pose {
            return pose
        }
        if gate.armed { return .walkReady }
        return .idle
    }

    private var simStatusText: String {
        if let slot = channel.playingSlot, let meta = MotionCatalog.find(slot: slot) {
            return "재생 중 — \(Int(channel.progress * 100))%  ·  \(meta.rawName)"
        } else if gate.armed {
            return "ARM 완료 — 동작 버튼 대기"
        } else {
            return "DISARM — 우측 슬라이더를 끌어 ARM"
        }
    }

    private var meshFallbackBanner: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                Text("기본 모델 로드 실패")
                    .font(DFFont.bodyEmph)
                Text("단순 형상으로 표시 중 — 빌드의 .stl 메쉬 확인")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .strokeBorder(DFColor.warning.opacity(DFOpacity.dim), lineWidth: 1)
        )
    }

    // MARK: - Camera panel

    private var cameraPanel: some View {
        PilotCameraView(
            flags: flags,
            endpoint: cameraEndpoint,
            demoStatus: demoStatus,
            headTracker: headTracker,
            hsvPreset: $hsvPreset,
            remoteShell: remoteShell,
            onRequestMode: { newMode in
                // 카메라 HUD 의 토글 버튼 → picker 와 동일한 mode 변경 경로.
                mode = newMode    // onChange(of: mode) → handleModeChange 자동 발동.
            }
        )
    }

    private var cameraEndpoint: PilotCameraEndpoint {
        if let endpoint = store.activeEndpoint ?? store.lastSuccessfulEndpoint,
           case .network(let host, _) = endpoint {
            return PilotCameraEndpoint(host: host)
        }
        let manualHost = store.networkHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manualHost.isEmpty {
            return PilotCameraEndpoint(host: manualHost)
        }
        return PilotCameraEndpoint(host: DFConnectionConstants.robotEthernetIP)
    }

    // MARK: - HUD panel

    private var hudPanel: some View {
        PilotHudStrip(store: store, channel: channel, gate: gate, flags: flags)
    }

    // MARK: - Overlays

    /// 상태에 따라 다른 배너:
    ///   - .error: 큰 빨간 배너 + 재연결 버튼 (사용자 즉시 인지 필요)
    ///   - .connecting: 작은 노란 회전 배너
    ///   - .disconnected (bus nil): 시뮬 모드 배너 (작은 캡슐)
    ///   - .connected: 배너 없음
    @ViewBuilder
    private var topBanner: some View {
        switch store.status {
        case .error(let msg):
            errorBanner(message: msg)
        case .connecting(let label):
            connectingBanner(label: label)
        case .disconnected where store.bus == nil:
            simBanner
        case .disconnected, .connected:
            EmptyView()
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DFFontSize.s14, weight: .bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: DFSpace.none) {
                Text("연결 오류")
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(.white)
                Text(message)
                    .font(DFFont.caption)
                    .foregroundStyle(.white.opacity(DFOpacity.o85))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: DFSpace.sm)
            if store.lastSuccessfulEndpoint != nil {
                Button {
                    if let ep = store.lastSuccessfulEndpoint {
                        harness.record(
                            .pilotReconnectTapped, level: .info, actor: .user,
                            data: ["endpoint_hash": AnyCodable(
                                Harness.shortHash(String(describing: ep)))])
                        store.connect(endpoint: ep)
                    }
                } label: {
                    Text("재연결")
                        .font(DFFont.bodyEmph)
                        .padding(.horizontal, DFSpace.sm)
                        .padding(.vertical, DFSpace.xs2)
                        .background(.white.opacity(DFOpacity.o25))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pilot.reconnect")
            }
        }
        .padding(.horizontal, DFSpace.md).padding(.vertical, DFSpace.sm)
        .background(DFColor.danger)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .shadow(color: DFColor.danger.opacity(DFOpacity.o45), radius: 6, y: 2)
        .accessibilityIdentifier("pilot.error.banner")
    }

    private func connectingBanner(label: String) -> some View {
        HStack(spacing: DFSpace.xs2) {
            ProgressView().controlSize(.mini).tint(DFColor.warning)
            Text("연결 중 — \(label)")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.warning)
        }
        .padding(.horizontal, DFSpace.sm3).padding(.vertical, DFSpace.xs2)
        .background(.regularMaterial)
        .background(DFColor.warning.opacity(DFOpacity.o10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DFColor.warning.opacity(DFOpacity.o45), lineWidth: DFSize.borderHairline))
    }

    private var simBanner: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "wifi.slash")
                .font(.system(size: DFFontSize.s11, weight: .semibold))
            Text("시뮬 모드 — 실 로봇 연결 안 됨. 동작 버튼은 시각 미리보기만.")
                .font(DFFont.caption)
        }
        .padding(.horizontal, DFSpace.sm3).padding(.vertical, DFSpace.xs2)
        .foregroundStyle(DFColor.warning)
        .background(.regularMaterial)
        .background(DFColor.warning.opacity(DFOpacity.o10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DFColor.warning.opacity(DFOpacity.strong), lineWidth: DFSize.borderHairline))
    }

    @ViewBuilder
    private var toastOverlay: some View {
        VStack(spacing: DFSpace.xs2) {
            if let err = channel.lastError {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DFColor.warning)
                    Text(err)
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(DFColor.warning)
                }
                .padding(.horizontal, 14).padding(.vertical, DFSpace.sm)
                .background(.regularMaterial)
                .background(DFColor.warning.opacity(DFOpacity.o10))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DFColor.warning.opacity(DFOpacity.o45), lineWidth: DFSize.borderHairline))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("pilot.error")
            }
            if let msg = channel.lastToast {
                Text(msg)
                    .font(DFFont.bodyEmph)
                    .padding(.horizontal, 14).padding(.vertical, DFSpace.sm)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(DFColor.accent.opacity(DFOpacity.strong), lineWidth: DFSize.borderHairline))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("pilot.toast")
            }
        }
        .padding(.bottom, DFSpace.lg)
    }
}
