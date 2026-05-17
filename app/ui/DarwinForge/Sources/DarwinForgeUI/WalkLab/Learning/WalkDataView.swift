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

    public init() {}

    public var body: some View {
        HSplitView {
            sessionListPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            if let id = selectedId, let summary = summaries.first(where: { $0.id == id }) {
                detailPanel(summary: summary)
                    .frame(minWidth: 500)
            } else {
                emptyDetailPanel
                    .frame(minWidth: 500)
            }
        }
        .onAppear { reload() }
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
