import SwiftUI
import Charts
import Accessibility

/// **v1.9 (2026-05-17 사용자 요청)**: 보행 데이터 메뉴 화면.
///
/// 디스크에 저장된 모든 session 의 summary 를 list 로 표시 + 선택 시 IMU 시계열 +
/// corrector delta + balance state strip 차트.
///
/// **V280-C (2026-05-24)**: 4-layer (detail + Critic V2 + Markdown + approval sheet)
/// → segmented control 통합. mode 3종 mutually exclusive — Apple HIG "Tabbed
/// Interface" + IBM Carbon "Mode-less interaction" 적용. toolbar 2 button 제거.
///
/// **위치**: Expert > 보행 데이터 (ExpertTab.walkData)
///
/// **데이터 흐름**:
/// - `WalkSessionStore.loadAllSummaries()` — 디스크 .summary.json 로드
/// - session 선택 → `loadSamples(for: sessionId)` 가 .jsonl 파싱
///
/// **Privacy**: 사용자가 휴지통 버튼 → 해당 session 삭제 가능.
public struct WalkDataView: View {
    /// **V280-C**: 우측 detail panel 의 mode (segmented control).
    /// 종전 `showV2Panel` + `claudeShowPanel` toggle 두 개 → 단일 enum 통합.
    /// mutually exclusive — 세 상태가 동시 활성 불가능.
    enum DetailMode: String, CaseIterable, Identifiable {
        case overview
        case claude
        case critic
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: return "개요"
            case .claude:   return "Claude 분석"
            case .critic:   return "Critic V2"
            }
        }

        /// App Store 빌드(§4): Claude/Critic 탭은 `claude` CLI 를 spawn 하므로
        /// 리뷰어 머신에서 '분석 실패' 로 깨진다 → 세그먼트 picker 에서 아예 제외.
        /// dev/DevID 빌드는 전체 노출.
        static var visibleCases: [DetailMode] {
            #if APPSTORE
            return [.overview]
            #else
            return allCases
            #endif
        }
    }

    // V280-C: extension (다른 file) 접근 위해 default internal scope 유지.
    @State var summaries: [WalkSessionSummary] = []
    @State var selectedId: String?
    @State private var loadedSamples: [WalkSessionSample] = []
    @State private var isLoadingSamples: Bool = false

    // **v1.11.9 (2026-05-19)** — Claude CLI 보행 분석.
    @State var claudeMarkdown: String? = nil
    @State var claudeError: String? = nil
    @State private var claudeInProgress: Bool = false
    @State private var claudeUserReport: String = ""

    // **v1.11.12 (2026-05-19)** — Critic V2 (typed JSON 응답).
    @EnvironmentObject var critic: WalkSessionClaudeCritic
    @EnvironmentObject var experimentLoop: ExperimentLoopController
    // **v1.11.14 (2026-05-19)** — RootView hoisted WalkLabSession.
    @Environment(WalkLabSession.self) var session
    // **v1.11.14.7 (2026-05-19)** — 테마 인식 — flat 모드에서 elev2 도 무채색.
    @Environment(\.dfTheme) private var theme: DFTheme

    // **V280-C**: 4-layer → segmented control 통합.
    @State private var detailMode: DetailMode = .overview

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init() {}

    public var body: some View {
        HSplitView {
            sessionListPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            detailSection
                .frame(minWidth: 500)
        }
        .sheet(isPresented: $showApprovalSheet) {
            if let resp = critic.currentResponse, let exp = resp.nextExperiment {
                // v1.11.14: 현재 WalkLabSession config 를 base 로 한 axis 만 override.
                // baseline header (디스크) 가 있으면 더 정확한 값 (당시 trim 등).
                // v1.11.14.3 cold #F fix: proposedConfig + validationResult 를 closure
                // 로 전달 — sheet body 평가 시마다 session.balanceExperimentConfig +
                // hipPitchOffsetTrimDeg 재read 하여 stale 차단.
                let baselineId = selectedId ?? (summaries.first?.id ?? "unknown")
                let baseHeader = loadHeader(forSessionId: baselineId)
                ExperimentApprovalUI(
                    response: resp,
                    baselineSessionId: baselineId,
                    proposedConfig: self.buildProposedConfig(
                        from: exp,
                        currentConfig: session.balanceExperimentConfig,
                        currentHipPitchOffsetTrimDeg: session.hipPitchOffsetTrimDeg,
                        baselineHeader: baseHeader
                    ).config,
                    validationResult: resp.validate(
                        currentConfig: session.balanceExperimentConfig,
                        currentTrim: session.hipPitchOffsetTrimDeg
                    ),
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

    // V280-C: extension 으로 분리 (WalkDataView+ExperimentApproval.swift) —
    // 다른 file extension 접근 위해 internal default scope 유지.
    @State var showApprovalSheet: Bool = false

    // MARK: - Detail section (V280-C segmented control)

    /// 우측 panel: segmented control + mode 별 sub-view.
    /// V280-C: 종전 HSplitView 우측 VStack 의 4-layer (detail + Critic V2 +
    /// Markdown) 를 단일 sub-view 로 추출 + segmented picker 도입.
    private var detailSection: some View {
        VStack(spacing: 0) {
            detailModePicker
            Divider()
            modeContent
        }
    }

    private var detailModePicker: some View {
        Picker("분석 모드", selection: $detailMode) {
            ForEach(DetailMode.visibleCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs)
        .background(DFColor.adaptiveElev2(theme))
        .onChange(of: detailMode) { _, newValue in
            harness.record(
                .walklabDataAnalysisPanelToggle, level: .info, actor: .user,
                data: ["panel": AnyCodable(newValue.rawValue),
                       "visible": AnyCodable(true)]
            )
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch detailMode {
        case .overview:
            overviewMode
        case .claude:
            // App Store 빌드(§4): Claude 패널은 `claude` CLI 의존 → overview 로 폴백
            // (picker 에서도 숨겨 도달 불가하지만 방어적으로 fallback).
            #if APPSTORE
            overviewMode
            #else
            claudePanelView
            #endif
        case .critic:
            #if APPSTORE
            overviewMode
            #else
            criticPanelView
            #endif
        }
    }

    @ViewBuilder
    private var overviewMode: some View {
        if let id = selectedId, let summary = summaries.first(where: { $0.id == id }) {
            detailPanel(summary: summary)
        } else {
            emptyDetailPanel
        }
    }

    /// V280-C: WalkDataClaudePanel 로 추출. binding 4종 + summaries + onAnalyze 전달.
    private var claudePanelView: some View {
        WalkDataClaudePanel(
            claudeMarkdown: $claudeMarkdown,
            claudeError: $claudeError,
            claudeInProgress: $claudeInProgress,
            claudeUserReport: $claudeUserReport,
            summaries: summaries,
            onAnalyze: { await invokeClaudeAnalysis() }
        )
    }

    private var criticPanelView: some View {
        WalkDataClaudeV2Panel(
            showApprovalSheet: $showApprovalSheet,
            summaries: summaries,
            headersById: loadHeaders(),
            sampleStatsBuilder: { sessionId in
                self.phaseStatsForSession(sessionId)
            }
        )
    }

    // MARK: - Claude AI invocation (v1.11.9)

    private func invokeClaudeAnalysis() async {
        claudeInProgress = true
        claudeError = nil
        defer { claudeInProgress = false }

        if summaries.isEmpty {
            claudeError = "분석할 세션이 없습니다."
            return
        }

        harness.record(
            .walklabDataAnalysisStarted, level: .info, actor: .user,
            data: ["session_count": AnyCodable(summaries.count)]
        )

        let prompt = WalkSessionClaudePrompt.build(
            sessions: summaries,
            userReport: claudeUserReport,
            sampleStatsBuilder: { Self.phaseStatsClassic(forSessionId: $0) }
        )
        let analyst = WalkSessionClaudeAnalyst(timeoutSeconds: 90)
        do {
            let md = try await analyst.analyze(prompt: prompt)
            claudeMarkdown = md
        } catch {
            claudeError = error.localizedDescription
        }
    }

    // V280-C: phaseStatsClassic 은 extension (WalkDataView+ExperimentApproval) 로 이동.

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
                .accessibilityLabel("디스크 다시 로드")
                if let dir = WalkSessionStore.sessionsDir {
                    Button {
                        NSWorkspace.shared.open(dir)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("저장 폴더 열기")
                    .buttonStyle(.borderless)
                    .accessibilityLabel("저장 폴더 열기")
                }
            }
            .padding(DFSpace.sm)
            .background(DFColor.adaptiveElev2(theme))

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
        .onChange(of: summary.id) { _, newId in
            harness.record(
                .walklabDataSessionSelected, level: .info, actor: .user,
                data: ["session_id_hash": AnyCodable(Harness.shortHash(newId))]
            )
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
            WalkDataIMUChart(samples: samples)
        }
        .padding(DFSpace.sm)
        .background(DFColor.adaptiveElev2(theme))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    @ViewBuilder
    private func balanceStateStrip(samples: [WalkSessionSample]) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("Balance State (시간 축)")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            WalkDataBalanceStripChart(samples: samples, stateColor: stateColor)
        }
        .padding(DFSpace.sm)
        .background(DFColor.adaptiveElev2(theme))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    @ViewBuilder
    private func correctorDeltaChart(samples: [WalkSessionSample]) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("Corrector Delta — R/L hip_roll (°)")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            WalkDataCorrectorDeltaChart(samples: samples)
        }
        .padding(DFSpace.sm)
        .background(DFColor.adaptiveElev2(theme))
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
        // Task.detached: parseSamples 는 nonisolated static 함수 — UI thread 점유
        // 없이 background 에서 파싱. await MainActor.run 으로 @State 안전 갱신.
        Task.detached(priority: .userInitiated) {
            let result = Self.parseSamples(sessionId: sessionId)
            await MainActor.run {
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
        harness.record(
            .walklabDataSessionDeleted, level: .warn, actor: .user,
            data: ["session_id_hash": AnyCodable(Harness.shortHash(id))]
        )
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
