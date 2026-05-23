import SwiftUI

/// **v1.15.0 (2026-05-21) — Phase 1 검색/탐색 UI**.
///
/// `WalkTrialLibraryView` 는 저장된 모든 trial 의 검색/탐색/라벨링/비교 UI 입니다.
///
/// # 화면 구조
///
/// - **상단 toolbar**: filter (preset/rating/no-falls 등) + sort + refresh
/// - **좌측 카드 리스트**: TrialIndexEntry 기반 (스크롤 + 검색 결과 수 표시)
/// - **우측 detail pane**: 선택된 trial 의 outcome + config + label + 재라벨 버튼
///
/// # 비유
///
/// 음악 라이브러리 (Apple Music / Spotify) — 좌측에 트랙 리스트, 우측에 트랙 상세. 필터로
/// "5별점 + Rock 장르" 같은 query 가능. 재생 (timeseries 시각화) 은 Phase 2 detail view 에서.
@MainActor
public struct WalkTrialLibraryView: View {
    @State private var indexEntries: [TrialIndexEntry] = []
    @State private var selectedTrial: WalkTrial?
    @State private var filter = TrialFilter()
    @State private var sort: TrialSort = .startedDesc
    @State private var labelingTrial: WalkTrial?
    /// **v1.19.1 (2026-05-21) 사이클 4**: AutoGenerator sheet 표시 토글.
    @State private var showingAutoGenerator: Bool = false

    private let store: WalkTrialStore

    public init(store: WalkTrialStore = .shared) {
        self.store = store
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 500)
            detail
                .frame(minWidth: 360)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("정렬", selection: $sort) {
                    ForEach(TrialSort.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                // **v1.19.1 (2026-05-21) 사이클 4**: AutoGenerator 진입점.
                Button(action: {
                    showingAutoGenerator = true
                    Harness.shared.record(
                        .walklabTrialAutogenOpened, level: .info, actor: .user
                    )
                }) {
                    Image(systemName: "sparkles.rectangle.stack")
                }
                .help("Trial 자동 생성 — Recommender 학습용")
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("새로고침")
            }
        }
        .sheet(isPresented: $showingAutoGenerator) {
            WalkTrialAutoGeneratorSheet()
                .onDisappear { refresh() }
        }
        .sheet(item: $labelingTrial) { trial in
            WalkTrialLabelSheet(trial: trial,
                                onSave: { label in
                                    store.updateLabel(id: trial.id, label: label)
                                    refresh()
                                    if selectedTrial?.id == trial.id {
                                        selectedTrial = store.load(id: trial.id)
                                    }
                                },
                                onSkip: nil)
        }
        .onAppear { refresh() }
        .onChange(of: filter) { _, newFilter in
            recordFilterChange(newFilter)
        }
        .onChange(of: sort) { _, newSort in
            recordFilterChange(filter, sort: newSort)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filteredEntries.isEmpty {
                emptyState
            } else {
                List(selection: $selectedTrial) {
                    ForEach(filteredEntries) { entry in
                        TrialRow(entry: entry)
                            .tag(store.load(id: entry.id))
                            .onTapGesture {
                                selectedTrial = store.load(id: entry.id)
                                Harness.shared.record(
                                    .walklabTrialSelected, level: .info, actor: .user,
                                    data: ["trial_id_hash": AnyCodable(Harness.shortHash(entry.id)),
                                           "preset": AnyCodable(entry.preset),
                                           "overall_score": AnyCodable(entry.overallScore)]
                                )
                            }
                    }
                }
                .listStyle(.inset)
            }
            countFooter
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("필터")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            HStack(spacing: 8) {
                Toggle("낙상 없음", isOn: $filter.noFallsOnly)
                    .toggleStyle(.button)
                    .font(.caption)
                Toggle("실 robot", isOn: $filter.realRobotOnly)
                    .toggleStyle(.button)
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12)
            HStack(spacing: 8) {
                Picker("preset", selection: Binding(
                    get: { filter.preset ?? "all" },
                    set: { filter.preset = $0 == "all" ? nil : $0 }
                )) {
                    Text("전체").tag("all")
                    ForEach(["idle", "march", "slowWalk", "normalWalk", "fastWalk", "jog", "turnLeft", "turnRight"], id: \.self) { p in
                        Text(p).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)
                Picker("별점", selection: Binding(
                    get: { filter.minRating ?? 0 },
                    set: { filter.minRating = $0 == 0 ? nil : $0 }
                )) {
                    Text("전체").tag(0)
                    Text("⭐ 3+").tag(3)
                    Text("⭐ 4+").tag(4)
                    Text("⭐ 5").tag(5)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 100)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("저장된 trial 이 없습니다")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("워크랩에서 보행 시작 → 정지 시 자동 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var countFooter: some View {
        HStack {
            Text("\(filteredEntries.count) / \(indexEntries.count) trial")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let trial = selectedTrial {
            TrialDetailView(trial: trial,
                            store: store,
                            onRelabel: { labelingTrial = trial },
                            onDelete: {
                                store.delete(id: trial.id)
                                selectedTrial = nil
                                refresh()
                            })
        } else {
            VStack(spacing: 8) {
                Image(systemName: "figure.walk.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("좌측에서 trial 을 선택하세요")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - State helpers

    private var filteredEntries: [TrialIndexEntry] {
        store.query(filter: filter, sort: sort)
    }

    private func refresh() {
        indexEntries = store.allIndex()
    }

    private func recordFilterChange(_ f: TrialFilter, sort s: TrialSort? = nil) {
        Harness.shared.record(
            .walklabTrialFilterChanged, level: .info, actor: .user,
            data: ["sort": AnyCodable((s ?? sort).rawValue),
                   "no_falls_only": AnyCodable(f.noFallsOnly),
                   "real_robot_only": AnyCodable(f.realRobotOnly),
                   "preset": AnyCodable(f.preset ?? "all"),
                   "min_rating": AnyCodable(f.minRating ?? 0)]
        )
    }
}

// MARK: - TrialRow

private struct TrialRow: View {
    let entry: TrialIndexEntry

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(String(format: "%.0f", entry.overallScore * 100))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(scoreColor)
                Text("점")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.preset)
                        .font(.callout.weight(.medium))
                    if entry.isRealRobot {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    if entry.fallEventCount > 0 {
                        Text("낙상 \(entry.fallEventCount)")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.red.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(shortDate(entry.startedAtIso))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0fs", entry.durationSec))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if entry.rating > 0 {
                        HStack(spacing: 1) {
                            ForEach(0..<entry.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            }
                        }
                    } else {
                        Text("미평가")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var scoreColor: Color {
        let s = entry.overallScore
        if s >= 0.8 { return .green }
        if s >= 0.6 { return .blue }
        if s >= 0.4 { return .orange }
        return .red
    }

    private func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MM/dd HH:mm"
        return out.string(from: d)
    }
}

// MARK: - Detail

private struct TrialDetailView: View {
    let trial: WalkTrial
    let store: WalkTrialStore
    let onRelabel: () -> Void
    let onDelete: () -> Void

    @Environment(WalkLabSession.self) private var session
    @State private var showingDeleteConfirm = false

    /// **v1.16.0 (2026-05-21) Phase 2**: 같은 preset 의 추천.
    /// **v1.16.0.1 fix (code-reviewer H2 + critic Minor #1)**: 종전 computed property 였으나
    /// 매 body 재평가 시 `store.query` × 2 (rule + coord) + `store.load` 디스크 I/O 반복.
    /// @State 로 캐시 + `onAppear` / trial 변경 시만 refresh.
    @State private var recommendations: [WalkTrialRecommendation] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                scoresSection
                Divider()
                configSection
                Divider()
                outcomeDetailSection
                Divider()
                labelSection
                if !recommendations.isEmpty {
                    Divider()
                    recommenderSection
                }
                Divider()
                actionsSection
            }
            .padding(20)
        }
        .onAppear { refreshRecommendations() }
        .onChange(of: trial.id) { _, _ in refreshRecommendations() }
    }

    private func refreshRecommendations() {
        // 사이클 151 (codex MAJOR #1 follow-up): 사용자의 robot 연결 상태에 따라
        // realRobotOnly 자동 결정 — 실 robot 연결 시 sim 추천 제외 (안전 default).
        // session.store?.bus != nil 이면 연결 — cycle 119 audit #31 의 의도 달성.
        let robotConnected = session.store?.bus != nil
        recommendations = WalkTrialRecommender.shared.recommend(
            for: trial.config.preset,
            realRobotOnly: robotConnected
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trial.config.preset)
                .font(.largeTitle.bold())
            HStack(spacing: 8) {
                Text(formatDate(trial.startedAtIso))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f초", trial.durationSec))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(trial.endReason.label)
                    .font(.subheadline)
                    .foregroundStyle(endReasonColor)
            }
        }
    }

    private var endReasonColor: Color {
        trial.endReason.isSuccess ? .green : .orange
    }

    private var scoresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("점수")
                .font(.headline)
            HStack(spacing: 12) {
                bigScore(title: "총점", value: trial.outcome.overallScore, color: overallColor(trial.outcome.overallScore))
                bigScore(title: "안정성", value: trial.outcome.stabilityScore, color: .green)
                bigScore(title: "부드러움", value: trial.outcome.smoothnessScore, color: .blue)
                bigScore(title: "효율", value: trial.outcome.energyScore, color: .orange)
            }
            if trial.outcome.isGoodTrial {
                Label("좋은 trial — Phase 2 추천 알고리즘의 baseline 후보", systemImage: "star.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func bigScore(title: String, value: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%.0f", value * 100))
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func overallColor(_ s: Double) -> Color {
        if s >= 0.8 { return .green }
        if s >= 0.6 { return .blue }
        if s >= 0.4 { return .orange }
        return .red
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("조건")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("preset", trial.config.preset)
                row("safety", trial.config.presetSafety)
                row("intensity", "\(trial.config.intensityLevel)")
                row("algorithm", trial.config.balanceConfig.algorithmMode.label)
                row("sign", trial.config.balanceConfig.signConvention.label)
                row("gain", trial.config.balanceConfig.gainProfile.label)
                row("apply", trial.config.balanceConfig.applyToRobot ? "ON" : "OFF")
                row("balanceCorr", trial.config.enableBalanceCorrection ? "ON" : "OFF")
                row("engine", trial.config.walkingEngine)
                row("real robot", trial.config.isRealRobot ? "YES" : "sim")
            }
            .font(.caption.monospacedDigit())
            if !trial.config.tuning.isDefault {
                Text("Tuning (사용자 조정)")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                    row("stride", String(format: "%.0f mm", trial.config.tuning.strideMm))
                    row("side", String(format: "%.0f mm", trial.config.tuning.sideMm))
                    row("turn", String(format: "%.0f °", trial.config.tuning.turnDeg))
                    row("period", String(format: "%.0f ms", trial.config.tuning.periodMs))
                    row("footHeight", String(format: "%.0f mm", trial.config.tuning.footHeightMm))
                    row("balanceGain", String(format: "%.2f", trial.config.tuning.balanceGain))
                }
                .font(.caption.monospacedDigit())
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .foregroundStyle(.secondary)
            Text(value)
        }
    }

    private var outcomeDetailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("측정")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                row("샘플 수", "\(trial.outcome.sampleCount)")
                row("step 수", "\(trial.outcome.stepsExecuted)")
                row("낙상 events", "\(trial.outcome.fallEventCount)")
                row("peak roll", String(format: "%.1f°", trial.outcome.peakAbsRollDeg))
                row("peak pitch", String(format: "%.1f°", trial.outcome.peakAbsPitchDeg))
                row("mean roll", String(format: "%.1f°", trial.outcome.meanAbsRollDeg))
                row("mean pitch", String(format: "%.1f°", trial.outcome.meanAbsPitchDeg))
                row("peak motor temp", String(format: "%.0f °C", trial.outcome.peakMotorTempC))
                row("bus write 실패", "\(trial.outcome.busWriteFailures)")
            }
            .font(.caption.monospacedDigit())
            VStack(alignment: .leading, spacing: 2) {
                Text("BalanceState 분포")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    ForEach(["normal", "caution", "warning", "danger", "emergency"], id: \.self) { state in
                        let pct = (trial.outcome.stateDistribution[state] ?? 0) * 100
                        if pct >= 0.5 {
                            VStack(spacing: 0) {
                                Text(String(format: "%.0f%%", pct))
                                    .font(.caption.monospacedDigit())
                                Text(state)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(stateColor(state).opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "normal":    return .green
        case "caution":   return .yellow
        case "warning":   return .orange
        case "danger":    return .red
        case "emergency": return .purple
        default:          return .gray
        }
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("라벨")
                    .font(.headline)
                Spacer()
                Button(trial.label == nil ? "라벨 추가" : "라벨 수정") { onRelabel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let label = trial.label {
                HStack(spacing: 2) {
                    ForEach(0..<label.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                    }
                    ForEach(0..<(5 - label.rating), id: \.self) { _ in
                        Image(systemName: "star")
                            .font(.callout)
                            .foregroundStyle(.secondary.opacity(0.3))
                    }
                }
                if !label.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(label.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
                if !label.freeText.isEmpty {
                    Text(label.freeText)
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text("아직 라벨이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionsSection: some View {
        HStack {
            Spacer()
            Button(role: .destructive) { showingDeleteConfirm = true } label: {
                Label("삭제", systemImage: "trash")
            }
            .confirmationDialog("이 trial 을 삭제하시겠습니까?",
                                isPresented: $showingDeleteConfirm) {
                Button("삭제", role: .destructive) { onDelete() }
                Button("취소", role: .cancel) {}
            }
        }
    }

    /// **v1.16.0 (2026-05-21) Phase 2**: 추천 카드 (각 strategy 별).
    /// **사이클 153**: robotConnected 전달 — sim only 추천 적용 시 confirmation.
    private var recommenderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("같은 preset (\(trial.config.preset)) 추천")
                .font(.headline)
            let robotConnected = session.store?.bus != nil
            ForEach(recommendations) { rec in
                WalkTrialRecommenderCard(
                    recommendation: rec,
                    robotConnected: robotConnected,
                    onApply: { applyRecommendation(rec) }
                )
            }
        }
    }

    /// Recommender 의 config 를 session 에 inject — 사용자가 다음 보행에서 자동 사용.
    private func applyRecommendation(_ rec: WalkTrialRecommendation) {
        session.applyRecommendation(rec)
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return out.string(from: d)
    }
}
