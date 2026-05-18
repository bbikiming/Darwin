import SwiftUI
import Charts

/// **v1.9 (2026-05-17 사용자 요청)**: 보행 데이터 메뉴 화면.
///
/// 디스크에 저장된 모든 session 의 summary 를 list 로 표시 + 선택 시 IMU 시계열 +
/// corrector delta + balance state strip 차트.
///
/// **위치**: Expert > 보행 데이터 (ExpertTab.walkData)
///
/// **데이터 흐름**:
/// - `WalkSessionStore.loadAllSummaries()` — 디스크 .summary.json 로드
/// - session 선택 → `loadSamples(for: sessionId)` 가 .jsonl 파싱
///
/// **Privacy**: 사용자가 휴지통 버튼 → 해당 session 삭제 가능.
public struct WalkDataView: View {
    @State private var summaries: [WalkSessionSummary] = []
    @State private var selectedId: String?
    @State private var loadedSamples: [WalkSessionSample] = []
    @State private var isLoadingSamples: Bool = false

    // **v1.11.9 (2026-05-19)** — Claude CLI 보행 분석.
    @State private var claudeMarkdown: String? = nil
    @State private var claudeError: String? = nil
    @State private var claudeInProgress: Bool = false
    @State private var claudeUserReport: String = ""
    @State private var claudeShowPanel: Bool = false

    // **v1.11.12 (2026-05-19)** — Critic V2 (typed JSON 응답).
    @EnvironmentObject private var critic: WalkSessionClaudeCritic
    @EnvironmentObject private var experimentLoop: ExperimentLoopController
    // **v1.11.14 (2026-05-19)** — RootView hoisted WalkLabSession.
    // ExperimentApprovalUI 의 onApprove 가 실제 WalkLabSession config 를 변경하기 위해
    // 필요. 종전엔 WalkLabView 내부 @StateObject 라 접근 불가했음.
    @EnvironmentObject private var session: WalkLabSession
    @State private var showV2Panel: Bool = false

    public init() {}

    public var body: some View {
        HSplitView {
            sessionListPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            VStack(spacing: 0) {
                if let id = selectedId, let summary = summaries.first(where: { $0.id == id }) {
                    detailPanel(summary: summary)
                } else {
                    emptyDetailPanel
                }
                if showV2Panel {
                    Divider()
                    // v1.11.12: typed JSON UI.
                    WalkDataClaudeV2Panel(
                        showApprovalSheet: $showApprovalSheet,
                        summaries: summaries,
                        headersById: loadHeaders(),
                        sampleStatsBuilder: { sessionId in
                            self.phaseStatsForSession(sessionId)
                        }
                    )
                    .frame(maxHeight: 480)
                } else if claudeShowPanel {
                    Divider()
                    claudePanel
                        .frame(maxHeight: 360)
                }
            }
            .frame(minWidth: 500)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showV2Panel.toggle()
                    if showV2Panel { claudeShowPanel = false }
                } label: {
                    Label(showV2Panel ? "Critic V2 숨김" : "Critic V2 (typed)",
                          systemImage: "sparkles.rectangle.stack.fill")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    claudeShowPanel.toggle()
                    if claudeShowPanel { showV2Panel = false }
                } label: {
                    Label(claudeShowPanel ? "Markdown 패널 숨김" : "Markdown 분석 (v1.11.9)",
                          systemImage: "sparkles")
                }
            }
        }
        .sheet(isPresented: $showApprovalSheet) {
            if let resp = critic.currentResponse, let exp = resp.nextExperiment {
                // v1.11.14: 현재 WalkLabSession config 를 base 로 한 axis 만 override.
                // baseline header (디스크) 가 있으면 더 정확한 값 (당시 trim 등).
                let baselineId = selectedId ?? (summaries.first?.id ?? "unknown")
                let baseHeader = loadHeader(forSessionId: baselineId)
                let (proposedConfig, _) = buildProposedConfig(
                    from: exp,
                    currentConfig: session.balanceExperimentConfig,
                    currentHipPitchOffsetTrimDeg: session.hipPitchOffsetTrimDeg,
                    baselineHeader: baseHeader
                )
                // v1.11.14.1: validate(currentConfig:) 미리 계산 — sheet 안에 issue 표시.
                let validationResult = resp.validate(
                    currentConfig: session.balanceExperimentConfig,
                    currentTrim: session.hipPitchOffsetTrimDeg
                )
                ExperimentApprovalUI(
                    response: resp,
                    baselineSessionId: baselineId,
                    proposedConfig: proposedConfig,
                    validationResult: validationResult,
                    onApprove: {
                        Task {
                            await applyExperimentApproval(
                                response: resp,
                                experiment: exp,
                                currentConfig: session.balanceExperimentConfig,
                                currentTrim: session.hipPitchOffsetTrimDeg,
                                session: session
                            )
                        }
                    },
                    onCancel: { showApprovalSheet = false }
                )
            }
        }
        .onAppear { reload() }
    }

    @State private var showApprovalSheet: Bool = false

    /// 모든 세션의 jsonl 에서 header load.
    private func loadHeaders() -> [String: WalkSessionHeader] {
        var map: [String: WalkSessionHeader] = [:]
        guard let dir = WalkSessionStore.sessionsDir else { return map }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return map
        }
        let decoder = JSONDecoder()
        for url in files where url.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: url),
                  let firstLine = data.split(separator: 0x0a).first,
                  let header = try? decoder.decode(WalkSessionHeader.self, from: Data(firstLine))
            else { continue }
            map[header.sessionId] = header
        }
        return map
    }

    private func phaseStatsForSession(_ sessionId: String) -> [WalkSessionClaudePromptV2.PhaseStatsV2] {
        guard let dir = WalkSessionStore.sessionsDir else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let match = files.first { $0.lastPathComponent.contains(sessionId) && $0.pathExtension == "jsonl" }
        guard let url = match, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var samples: [WalkSessionSample] = []
        for line in data.split(separator: 0x0a).dropFirst() {
            if let s = try? decoder.decode(WalkSessionSample.self, from: Data(line)) {
                samples.append(s)
            }
        }
        return WalkSessionClaudePromptV2.phaseStatsV2(from: samples)
    }

    /// **v1.11.14 (2026-05-19) — fix 진단 문서 #2**: 현재 WalkLab config 기준 + 한 axis 만 override.
    /// `currentConfig` 는 RootView/WalkLabView 가 전달. baseline session 의 Header V2
    /// 도 우선 사용 (있으면 더 정확). nil 이면 default — backward compat.
    /// **v1.11.14.1**: tuning slider (stride/side/turn/period/footHeight/balanceGain) +
    /// customGain* 4종 도 ExperimentDeltas 로 반환.
    func buildProposedConfig(from exp: NextExperiment,
                             currentConfig: BalanceExperimentConfig?,
                             currentHipPitchOffsetTrimDeg: Double = 13.0,
                             baselineHeader: WalkSessionHeader? = nil)
        -> (config: BalanceExperimentConfig, deltas: WalkLabSession.ExperimentDeltas) {
        // base = current config or baseline header values or default.
        var algorithm: BalanceAlgorithmMode = currentConfig?.algorithmMode ?? .robotisPControl
        var sign: BalanceSignConvention = currentConfig?.signConvention ?? .robotisWalkingCpp
        var gain: BalanceGainProfile = currentConfig?.gainProfile ?? .robotisOriginal
        var apply: Bool = currentConfig?.applyToRobot ?? true
        var pitchInput: BalancePitchInputConvention = currentConfig?.pitchInputConvention ?? .imuRaw
        if let h = baselineHeader {
            if let v = h.balanceAlgorithmMode.flatMap(BalanceAlgorithmMode.init) { algorithm = v }
            if let v = h.balanceSignConvention.flatMap(BalanceSignConvention.init) { sign = v }
            if let v = h.balanceGainProfile.flatMap(BalanceGainProfile.init) { gain = v }
            if let v = h.pitchInputConvention.flatMap(BalancePitchInputConvention.init) { pitchInput = v }
        }

        _ = currentHipPitchOffsetTrimDeg  // baseline header 우선이지만 logging 용 reserved.
        _ = baselineHeader?.hipPitchOffsetTrimDegAtStart  // header 의 baseline trim 도 검사 reserved.
        var deltas = WalkLabSession.ExperimentDeltas()

        // 한 axis 만 override.
        switch exp.axis {
        case .algorithmMode:
            if let v = BalanceAlgorithmMode(rawValue: exp.to) { algorithm = v }
        case .signConvention:
            if let v = BalanceSignConvention(rawValue: exp.to) { sign = v }
        case .gainProfile:
            if let v = BalanceGainProfile(rawValue: exp.to) { gain = v }
        case .pitchInputConvention:
            if let v = BalancePitchInputConvention(rawValue: exp.to) { pitchInput = v }
        case .applyToRobot:
            apply = (exp.to.lowercased() == "true")
        case .hipPitchOffsetTrimDeg:
            if let d = Double(exp.to) { deltas.hipPitchOffsetTrimDeg = d }
        // v1.11.14.1: tuning slider 6종 + customGain 4종 적용.
        case .strideMm:
            if let d = Double(exp.to) { deltas.strideMm = d }
        case .sideMm:
            if let d = Double(exp.to) { deltas.sideMm = d }
        case .turnDeg:
            if let d = Double(exp.to) { deltas.turnDeg = d }
        case .periodMs:
            if let d = Double(exp.to) { deltas.customPeriodMs = d }
        case .footHeightMm:
            if let d = Double(exp.to) { deltas.footHeightMm = d }
        case .balanceGain:
            if let d = Double(exp.to) { deltas.balanceGain = d }
        case .customGainHipRoll:
            if let d = Double(exp.to) { deltas.customHipRollGain = d }
        case .customGainKnee:
            if let d = Double(exp.to) { deltas.customKneeGain = d }
        case .customGainAnklePitch:
            if let d = Double(exp.to) { deltas.customAnklePitchGain = d }
        case .customGainAnkleRoll:
            if let d = Double(exp.to) { deltas.customAnkleRollGain = d }
        default:
            break
        }
        let config = BalanceExperimentConfig(
            algorithmMode: algorithm, signConvention: sign,
            gainProfile: gain, applyToRobot: apply,
            pitchInputConvention: pitchInput
        )
        return (config, deltas)
    }

    /// **v1.11.14**: 사용자 명시 승인 후 ExperimentLoop start + WalkLabSession 실 변경.
    /// 진단 문서 #1 fix — 승인 시 실제 config 변경.
    @MainActor
    private func applyExperimentApproval(response: ClaudeCriticResponse,
                                         experiment: NextExperiment,
                                         currentConfig: BalanceExperimentConfig?,
                                         currentTrim: Double,
                                         session: WalkLabSession?) async {
        let baselineId = selectedId ?? (summaries.first?.id ?? "unknown")
        let baseHeader = loadHeader(forSessionId: baselineId)
        let (proposedConfig, deltas) = buildProposedConfig(
            from: experiment,
            currentConfig: currentConfig,
            currentHipPitchOffsetTrimDeg: currentTrim,
            baselineHeader: baseHeader
        )
        // v1.11.14 진단 문서 #5 fix — 현재 config 기준 forbidden 조합 검증.
        // self.validate() 는 응답 시점에 이미 실행됨 (analyst); 여기는 사용자 명시
        // 승인 직전 추가 검사. 응답이 통과됐어도 사용자 현재 config 와 조합 시
        // safetyVerdict.blocked 이면 reject.
        let validation = response.validate(currentConfig: currentConfig ?? proposedConfig,
                                           currentTrim: currentTrim)
        if !validation.passed {
            // experimentLoop 가 lastError 에 issues 첫 줄 표시.
            experimentLoop.setLastError("승인 검증 실패: \(validation.issues.joined(separator: " | "))")
            showApprovalSheet = false
            return
        }
        let started = await experimentLoop.startExperiment(
            from: response,
            baselineSessionId: baselineId,
            proposedConfig: proposedConfig
        )
        if started, let session = session, let current = experimentLoop.current {
            // 실 WalkLabSession 에 한 axis 변경 적용 (사용자 명시 승인 + safety gate 통과 후).
            // v1.11.14.1: deltas struct 로 tuning slider + customGain* 4종 모두 포함.
            let result = session.applyExperimentChange(
                experimentId: current.id,
                baselineSessionId: baselineId,
                proposedConfig: proposedConfig,
                deltas: deltas
            )
            switch result {
            case .applied: break  // WalkLab 의 lastRobotEvent 가 사용자에게 표시.
            case .failed(let reason):
                // safetyVerdict 강등 등 — experimentLoop.cancel 후 사용자 안내.
                await experimentLoop.cancel()
                _ = reason  // 별도 alert 또는 lastError 채널 (v1.11.15)
            }
        }
        showApprovalSheet = false
    }

    /// 한 sessionId 의 jsonl 첫 줄 (header) load.
    private func loadHeader(forSessionId id: String) -> WalkSessionHeader? {
        guard let dir = WalkSessionStore.sessionsDir else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let match = files.first { $0.lastPathComponent.contains(id) && $0.pathExtension == "jsonl" }
        guard let url = match, let data = try? Data(contentsOf: url),
              let firstLine = data.split(separator: 0x0a).first
        else { return nil }
        return try? JSONDecoder().decode(WalkSessionHeader.self, from: Data(firstLine))
    }

    // MARK: - Claude AI panel (v1.11.9)

    @ViewBuilder
    private var claudePanel: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "sparkles")
                    .foregroundStyle(DFColor.accent)
                Text("Claude AI 분석")
                    .font(DFFont.bodyEmph)
                Spacer()
                if claudeInProgress {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await invokeClaudeAnalysis() }
                } label: {
                    Label("분석 실행", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(claudeInProgress || summaries.isEmpty)

                if claudeMarkdown != nil {
                    Button {
                        claudeMarkdown = nil
                        claudeError = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("결과 초기화")
                }
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.top, DFSpace.xs)

            // 사용자 자연어 보고 입력.
            HStack(alignment: .top, spacing: DFSpace.xs) {
                Image(systemName: "text.bubble")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
                TextField("사용자 보고 (예: \"앞으로 넘어지려고 했어\")",
                          text: $claudeUserReport,
                          axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
                    .font(DFFont.label)
            }
            .padding(.horizontal, DFSpace.sm)

            Divider()

            // 결과 표시.
            ScrollView {
                if let md = claudeMarkdown {
                    Text(md)
                        .font(DFFont.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DFSpace.sm)
                } else if let err = claudeError {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("분석 실패", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(DFColor.danger)
                            .font(DFFont.bodyEmph)
                        Text(err)
                            .font(DFFont.label)
                            .foregroundStyle(DFColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DFSpace.sm)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Claude CLI 가 최근 \(min(WalkSessionClaudePrompt.maxSessions, summaries.count))개 세션 + 사용자 보고를 분석합니다.")
                            .font(DFFont.label)
                            .foregroundStyle(DFColor.textSecondary)
                        Text("• 8 axis (engine/algorithm/sign/gain/pitchInput/apply/correction/trim) 기반 진단")
                            .font(DFFont.micro)
                            .foregroundStyle(DFColor.textSecondary)
                        Text("• Mac sparse vs ROBOTIS onboard architecture 한계 인식")
                            .font(DFFont.micro)
                            .foregroundStyle(DFColor.textSecondary)
                        Text("• axis 별 권고 + 다음 실험 가설")
                            .font(DFFont.micro)
                            .foregroundStyle(DFColor.textSecondary)
                    }
                    .padding(DFSpace.sm)
                }
            }
        }
        .background(DFColor.accent.opacity(DFOpacity.o06))
    }

    private func invokeClaudeAnalysis() async {
        claudeInProgress = true
        claudeError = nil
        defer { claudeInProgress = false }

        if summaries.isEmpty {
            claudeError = "분석할 세션이 없습니다."
            return
        }

        // sessionId → jsonl 파일에서 sample 배열 load 후 phase 통계.
        let builder: (String) -> [WalkSessionClaudePrompt.PhaseStats] = { sessionId in
            guard let dir = WalkSessionStore.sessionsDir else { return [] }
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            let match = files.first { $0.lastPathComponent.contains(sessionId) && $0.pathExtension == "jsonl" }
            guard let url = match else { return [] }
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            var samples: [WalkSessionSample] = []
            for line in data.split(separator: 0x0a).dropFirst() {
                if let s = try? decoder.decode(WalkSessionSample.self, from: Data(line)) {
                    samples.append(s)
                }
            }
            return WalkSessionClaudePrompt.phaseStats(from: samples)
        }

        let prompt = WalkSessionClaudePrompt.build(
            sessions: summaries,
            userReport: claudeUserReport,
            sampleStatsBuilder: builder
        )

        let analyst = WalkSessionClaudeAnalyst(timeoutSeconds: 90)
        do {
            let md = try await analyst.analyze(prompt: prompt)
            claudeMarkdown = md
        } catch {
            claudeError = error.localizedDescription
        }
    }

    private var sessionListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("보행 세션 (\(summaries.count))")
                    .font(DFFont.bodyEmph)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("디스크 다시 로드")
                .buttonStyle(.borderless)
                if let dir = WalkSessionStore.sessionsDir {
                    Button {
                        NSWorkspace.shared.open(dir)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("저장 폴더 열기")
                    .buttonStyle(.borderless)
                }
            }
            .padding(DFSpace.sm)
            .background(DFColor.elev2)

            if summaries.isEmpty {
                VStack(spacing: DFSpace.sm) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(DFColor.textSecondary)
                    Text("저장된 보행 데이터 없음")
                        .font(DFFont.body)
                        .foregroundStyle(DFColor.textSecondary)
                    Text("워크랩에서 보행 cycle 완료 시 자동 저장됨")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(summaries, selection: $selectedId) { s in
                    summaryRow(s)
                        .tag(s.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .background(DFColor.elev3)
    }

    private func summaryRow(_ s: WalkSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(presetLabel(s.preset))
                    .font(DFFont.bodyEmph)
                Spacer()
                Text(String(format: "%.1fs", s.durationSec))
                    .font(DFFont.monoLabel)
                    .foregroundStyle(DFColor.textSecondary)
            }
            HStack {
                Text(formatTime(s.startTimeIso))
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                tiltBadge(s)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Finder 에서 보기") {
                if let url = sessionFileURL(for: s.id) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("이 세션 삭제", role: .destructive) {
                deleteSession(id: s.id)
            }
        }
    }

    private func tiltBadge(_ s: WalkSessionSummary) -> some View {
        let m = max(s.meanAbsRoll, s.meanAbsPitch)
        let color: Color = m < 5 ? DFColor.success : (m < 12 ? DFColor.warning : DFColor.danger)
        return Text(String(format: "%.1f°", m))
            .font(DFFont.monoLabel)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(DFOpacity.o15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Detail panel

    private func detailPanel(summary: WalkSessionSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                metaHeader(summary)
                summaryMetricsRow(summary)
                if isLoadingSamples {
                    ProgressView("샘플 로딩 중...")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if loadedSamples.isEmpty {
                    Text("샘플 데이터 없음 (jsonl 파일 누락 / 손상)")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    // Critic v1.9 Major #1 fix: chart 렌더링 전 downsample (max 400 points).
                    // 3분 session (3600 samples) 도 600pt 이하로 cap → Charts UI lag 차단.
                    let ds = Self.downsample(loadedSamples, maxPoints: 400)
                    imuChart(samples: ds)
                    balanceStateStrip(samples: ds)
                    correctorDeltaChart(samples: ds)
                }
                recommendationCard(summary)
            }
            .padding(DFSpace.md)
        }
        .onChange(of: summary.id) { _, _ in
            loadSamples(for: summary.id)
        }
        .onAppear {
            loadSamples(for: summary.id)
        }
    }

    private var emptyDetailPanel: some View {
        VStack(spacing: DFSpace.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 64))
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o25))
            Text("좌측에서 세션을 선택하세요")
                .font(DFFont.body)
                .foregroundStyle(DFColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metaHeader(_ s: WalkSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack {
                Text(presetLabel(s.preset))
                    .font(DFFont.title)
                Spacer()
                Text(formatTime(s.startTimeIso))
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Text("\(s.sampleCount) samples · \(String(format: "%.1f", s.durationSec))s · 강도 \(s.intensityLevelUsed)단계")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    private func summaryMetricsRow(_ s: WalkSessionSummary) -> some View {
        HStack(spacing: DFSpace.md) {
            metricCard("평균 |Roll|", String(format: "%.1f°", s.meanAbsRoll), DFColor.info)
            metricCard("평균 |Pitch|", String(format: "%.1f°", s.meanAbsPitch), DFColor.info)
            metricCard("Peak", String(format: "%.1f°", max(s.peakAbsRoll, s.peakAbsPitch)), DFColor.warning)
            metricCard("진동", String(format: "%.1fHz", s.oscillationScore),
                       s.oscillationScore > 4 ? DFColor.danger : DFColor.success)
            metricCard("효과", String(format: "%+.2f", s.correctorEffectivenessScore),
                       s.correctorEffectivenessScore > 0.3 ? DFColor.success
                       : (s.correctorEffectivenessScore < -0.3 ? DFColor.danger : DFColor.textSecondary))
        }
    }

    private func metricCard(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            Text(value).font(DFFont.bodyEmph.monospaced()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DFSpace.sm)
        .background(color.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    @ViewBuilder
    private func imuChart(samples: [WalkSessionSample]) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("IMU Roll / Pitch (°)")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("t", s.t / 1000.0), y: .value("Roll", s.imuRollDeg))
                        .foregroundStyle(by: .value("Series", "Roll"))
                }
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    LineMark(x: .value("t", s.t / 1000.0), y: .value("Pitch", s.imuPitchDeg))
                        .foregroundStyle(by: .value("Series", "Pitch"))
                }
                RuleMark(y: .value("zero", 0))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o25))
            }
            .chartForegroundStyleScale(["Roll": DFColor.info, "Pitch": DFColor.accent])
            .chartXAxisLabel("시간 (s)")
            .chartYAxisLabel("각도 (°)")
            .frame(height: 200)
        }
        .padding(DFSpace.sm)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    @ViewBuilder
    private func balanceStateStrip(samples: [WalkSessionSample]) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("Balance State (시간 축)")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    BarMark(
                        x: .value("t", s.t / 1000.0),
                        y: .value("state", 1)
                    )
                    .foregroundStyle(stateColor(s.balanceState))
                }
            }
            .chartYAxis(.hidden)
            .chartXAxisLabel("시간 (s)")
            .frame(height: 40)
        }
        .padding(DFSpace.sm)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    @ViewBuilder
    private func correctorDeltaChart(samples: [WalkSessionSample]) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("Corrector Delta — R/L hip_roll (°)")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    LineMark(
                        x: .value("t", s.t / 1000.0),
                        y: .value("R hipRoll", s.correctorDeltas.first ?? 0)
                    )
                    .foregroundStyle(by: .value("Series", "R hipRoll"))
                }
                ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                    LineMark(
                        x: .value("t", s.t / 1000.0),
                        y: .value("L hipRoll", s.correctorDeltas.dropFirst().first ?? 0)
                    )
                    .foregroundStyle(by: .value("Series", "L hipRoll"))
                }
                RuleMark(y: .value("zero", 0))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.o25))
            }
            .chartForegroundStyleScale(["R hipRoll": DFColor.forge, "L hipRoll": DFColor.success])
            .chartXAxisLabel("시간 (s)")
            .chartYAxisLabel("delta (°)")
            .frame(height: 150)
        }
        .padding(DFSpace.sm)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func recommendationCard(_ s: WalkSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack {
                Image(systemName: "lightbulb")
                    .foregroundStyle(DFColor.warning)
                Text("자동 튜닝 권고")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text("신뢰도 \(Int(s.confidence * 100))%")
                    .font(DFFont.monoLabel)
                    .foregroundStyle(s.confidence >= 0.5 ? DFColor.success : DFColor.textSecondary)
            }
            Text(s.recommendationReason)
                .font(DFFont.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("권고 강도:")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Text("\(s.intensityLevelUsed) → \(s.recommendedIntensityLevel)")
                    .font(DFFont.bodyEmph.monospaced())
                    .foregroundStyle(s.recommendedIntensityLevel != s.intensityLevelUsed
                                     ? DFColor.info : DFColor.success)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.warning.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Helpers

    private func reload() {
        summaries = WalkSessionStore.loadAllSummaries()
        if let id = selectedId, !summaries.contains(where: { $0.id == id }) {
            selectedId = nil
        }
    }

    private func loadSamples(for sessionId: String) {
        isLoadingSamples = true
        loadedSamples = []
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.parseSamples(sessionId: sessionId)
            DispatchQueue.main.async {
                self.loadedSamples = result
                self.isLoadingSamples = false
            }
        }
    }

    /// **Critic Major #1 fix**: Chart 성능 — 큰 sample 배열을 stride 로 downsample.
    /// 1200+ samples 시 Apple Charts framework lag — 400 points cap.
    static func downsample(_ samples: [WalkSessionSample], maxPoints: Int) -> [WalkSessionSample] {
        guard samples.count > maxPoints else { return samples }
        let stride = max(1, samples.count / maxPoints)
        return samples.enumerated().compactMap { idx, sample in
            idx % stride == 0 ? sample : nil
        }
    }

    /// .jsonl 파일에서 모든 sample 파싱 (첫 줄 header 제외).
    static func parseSamples(sessionId: String) -> [WalkSessionSample] {
        guard let url = sessionFileURL(for: sessionId),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var result: [WalkSessionSample] = []
        let lines = data.split(separator: 0x0A)  // newline byte
        // 첫 줄은 header — skip.
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            let lineData = Data(line)
            if let sample = try? decoder.decode(WalkSessionSample.self, from: lineData) {
                result.append(sample)
            }
        }
        return result
    }

    static func sessionFileURL(for sessionId: String) -> URL? {
        guard let dir = WalkSessionStore.sessionsDir else { return nil }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil) else { return nil }
        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
        // 1) 정확 매칭 시도 (v1.9.2 fix 후 새 session).
        if let exact = jsonlFiles.first(where: { $0.lastPathComponent.contains(sessionId) }) {
            return exact
        }
        // 2) **v1.9.2 fallback** — 종전 timestamp drift (3ms) 로 mismatched 된 기존 session:
        //    초 단위 (yyyy-MM-ddTHH-mm-ss) 까지만 매칭. ".999Z" 같은 millisecond 무시.
        let prefix = String(sessionId.prefix(19))  // "2026-05-17T11-28-42"
        return jsonlFiles.first { $0.lastPathComponent.contains(prefix) }
    }

    private func sessionFileURL(for sessionId: String) -> URL? {
        Self.sessionFileURL(for: sessionId)
    }

    private func deleteSession(id: String) {
        guard let url = sessionFileURL(for: id) else { return }
        let summaryURL = url.deletingPathExtension().appendingPathExtension("summary.json")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: summaryURL)
        reload()
        if selectedId == id { selectedId = nil }
    }

    private func presetLabel(_ raw: String) -> String {
        switch raw {
        case "idle": return "정지"
        case "march": return "제자리 걸음"
        case "slowWalk": return "천천히 걷기"
        case "normalWalk": return "보통 걷기"
        case "fastWalk": return "빠르게 걷기"
        case "jog": return "조깅"
        case "turnLeft": return "좌회전"
        case "turnRight": return "우회전"
        default: return raw
        }
    }

    private func formatTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: iso) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MM/dd HH:mm:ss"
            return displayFormatter.string(from: d)
        }
        return iso
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "normal":    return DFColor.success
        case "caution":   return DFColor.info
        case "warning":   return DFColor.warning
        case "danger":    return DFColor.warning.opacity(0.7)
        case "emergency": return DFColor.danger
        default:          return DFColor.textSecondary
        }
    }
}
