import ForgeCore
import SwiftUI

/// 사이클 183 (P1 #3.5 fix, cycle 177 audit): Expert WalkDiagnostics 의 trial 비교 card.
///
/// # 비유
///
/// 학생 의 성적표 두 장 을 나란히 펴 놓고 과목 별 변화 를 화살표 로 표시. 사용자가 "지난
/// 보행 시도 와 비교해서 안정성 이 얼마나 좋아졌나" 한눈에 파악.
///
/// # 동작
///
/// 1. WalkTrialStore 에서 최근 N trial 목록 표시 (dropdown).
/// 2. 두 trial 선택 → TrialComparisonModel 로 4 metric diff 생성.
/// 3. baseline → candidate 화살표 + 개선/악화 라벨 표시.
public struct TrialComparisonCard: View {
    /// WalkTrialStore singleton 사용 — Recommender / Library 와 동일 데이터 source.
    @State private var trialIndex: [TrialIndexEntry] = []
    @State private var baselineId: String = ""
    @State private var candidateId: String = ""
    @State private var comparison: TrialComparisonModel.Comparison? = nil

    /// 최근 trial 표시 개수 — 너무 많으면 UI 클러터.
    private let recentLimit: Int = 20

    public init() {}

    public var body: some View {
        DFPanel(
            "Trial 비교",
            subtitle: "과거 vs 현재 metric diff",
            icon: "arrow.left.arrow.right.circle",
            tint: DFColor.info
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                if trialIndex.isEmpty {
                    emptyStateBody
                } else {
                    pickersRow
                    if let cmp = comparison {
                        Divider()
                        comparisonGrid(cmp)
                        Text(cmp.summaryLabel)
                            .font(DFFont.caption.bold())
                            .foregroundStyle(cmp.improvementRatio >= 0.5 ? DFColor.success : DFColor.warning)
                            .padding(.top, DFSpace.xs)
                    } else {
                        Text("두 trial 을 선택하면 4 metric 의 차이가 표시됩니다.")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
            }
        }
        .onAppear { loadTrials() }
    }

    private var emptyStateBody: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Label("저장된 trial 없음", systemImage: "tray")
                .foregroundStyle(DFColor.textSecondary)
            Text("WalkLab 에서 보행 trial 을 완료하면 자동으로 누적됩니다.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    private var pickersRow: some View {
        HStack(spacing: DFSpace.sm) {
            picker(title: "기준", selection: $baselineId)
            Image(systemName: "arrow.right")
                .foregroundStyle(DFColor.textSecondary)
            picker(title: "비교", selection: $candidateId)
            Spacer()
            Button("비교") {
                computeComparison()
            }
            .controlSize(.small)
            .disabled(baselineId.isEmpty || candidateId.isEmpty || baselineId == candidateId)
        }
    }

    private func picker(title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            Text(title)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Picker("", selection: selection) {
                Text("선택…").tag("")
                ForEach(trialIndex) { entry in
                    Text(label(for: entry)).tag(entry.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 220)
        }
    }

    private func label(for entry: TrialIndexEntry) -> String {
        let scorePct = Int(entry.overallScore * 100)
        let preset = entry.preset.isEmpty ? "?" : entry.preset
        let real = entry.isRealRobot ? "실" : "시뮬"
        return "\(preset) · \(scorePct)% · \(real) · \(entry.id.prefix(6))"
    }

    private func comparisonGrid(_ cmp: TrialComparisonModel.Comparison) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            ForEach(cmp.metrics, id: \.label) { m in
                HStack(spacing: DFSpace.xs) {
                    Text(m.label)
                        .font(DFFont.caption.bold())
                        .frame(width: 90, alignment: .leading)
                    Text(m.koreanLabel)
                        .font(DFFont.caption.monospaced())
                        .foregroundStyle(m.isImprovement ? DFColor.success : DFColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Data load

    /// 사이클 187 (codex MINOR fix cycle 183): WalkTrialStore.allIndex() 가 disk
    /// IO + JSON parse → main thread 차단 위험. 신규: Task.detached 로 background
    /// 에서 fetch + sort + truncate, 결과만 MainActor 로 publish.
    private func loadTrials() {
        let limit = recentLimit
        Task.detached(priority: .userInitiated) {
            let truncated: [TrialIndexEntry] = WalkTrialStore.shared.allIndex()
                .sorted { $0.startedAtIso > $1.startedAtIso }
                .prefix(limit)
                .map { $0 }
            await MainActor.run { [truncated] in
                self.trialIndex = truncated
            }
        }
    }

    /// 사이클 212 (cycle 212 critic MAJOR-1): disk I/O on main thread — loadTrials() 와
    /// 동일 패턴 적용. WalkTrialStore.load(id:) 는 Data(contentsOf:) + JSONDecoder 사용.
    private func computeComparison() {
        let bId = baselineId
        let cId = candidateId
        Task.detached(priority: .userInitiated) {
            guard let baselineTrial = WalkTrialStore.shared.load(id: bId),
                  let candidateTrial = WalkTrialStore.shared.load(id: cId)
            else {
                await MainActor.run { self.comparison = nil }
                return
            }
            let result = TrialComparisonModel.compare(
                baselineId: bId,
                candidateId: cId,
                baseline: baselineTrial.outcome,
                candidate: candidateTrial.outcome
            )
            await MainActor.run { self.comparison = result }
        }
    }
}
