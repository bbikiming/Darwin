import SwiftUI

/// A/B 비교 워크플로우 패널. baseline / experiment 두 세션을 골라 비교 결과를 보여준다.
///
/// 원칙:
/// - "한 번에 하나의 변수만 바꿔야" 라는 게이트를 명시.
/// - quality 가 부족하면 verdict 를 `.inconclusive` 또는 `.incomparable` 로 솔직히 표시.
public struct WalkABComparisonPanel: View {
    @ObservedObject var model: WalkSessionListModel
    @State private var baselineId: WalkSessionListItem.ID?
    @State private var experimentId: WalkSessionListItem.ID?

    public init(model: WalkSessionListModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pickers
            Divider()
            result
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .foregroundStyle(.blue)
            Text("A / B 비교")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("한 번에 한 변수만 바꿔 비교하세요")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 6) {
            picker(title: "A 기준 세션", binding: $baselineId)
            picker(title: "B 실험 세션", binding: $experimentId)
        }
    }

    private func picker(title: String, binding: Binding<WalkSessionListItem.ID?>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 100, alignment: .leading)
            Picker("", selection: binding) {
                Text("선택 안 됨").tag(WalkSessionListItem.ID?.none)
                ForEach(model.items) { item in
                    Text(rowLabel(item))
                        .tag(Optional(item.id))
                }
            }
            .labelsHidden()
        }
    }

    private func rowLabel(_ item: WalkSessionListItem) -> String {
        "\(item.summary.preset) · \(item.summary.dataQuality.grade.rawValue) · \(item.summary.startTimeIso)"
    }

    @ViewBuilder
    private var result: some View {
        if let bId = baselineId, let eId = experimentId,
           let baseline = model.items.first(where: { $0.id == bId }),
           let experiment = model.items.first(where: { $0.id == eId }) {
            comparisonResult(baseline: baseline, experiment: experiment)
        } else {
            Text("두 세션을 선택하세요")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func comparisonResult(baseline: WalkSessionListItem,
                                   experiment: WalkSessionListItem) -> some View {
        let baselineDecoded = try? model.store.loadSession(file: baseline.url)
        let expDecoded = try? model.store.loadSession(file: experiment.url)

        if let bd = baselineDecoded, let ed = expDecoded {
            let result = WalkComparisonEngine.compare(baseline: bd, experiment: ed)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    verdictBadge(result.verdict)
                    Text("변경 변수: \(result.variableChanged.rawValue)")
                        .font(.caption.monospacedDigit())
                }
                metricRow(label: "평균 abs pitch Δ",
                          value: String(format: "%+.2f°", result.deltaMeanAbsPitch))
                metricRow(label: "평균 abs roll Δ",
                          value: String(format: "%+.2f°", result.deltaMeanAbsRoll))
                metricRow(label: "pitch stdev Δ",
                          value: String(format: "%+.2f°", result.deltaPitchStdev))
                metricRow(label: "roll stdev Δ",
                          value: String(format: "%+.2f°", result.deltaRollStdev))
                metricRow(label: "진동 Δ (pitch/roll)",
                          value: String(format: "%+.2f / %+.2f Hz",
                                        result.deltaOscillationPitch,
                                        result.deltaOscillationRoll))
                if !result.reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("주의/사유")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(result.reasons, id: \.self) { reason in
                            Text("· \(reason)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        } else {
            Text("세션 로드 실패")
                .foregroundStyle(.red)
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced))
        }
    }

    private func verdictBadge(_ verdict: WalkComparisonEngine.Verdict) -> some View {
        let (label, color): (String, Color) = {
            switch verdict {
            case .improved: return ("개선됨", .green)
            case .worsened: return ("악화됨", .red)
            case .inconclusive: return ("판단 불가", .orange)
            case .incomparable: return ("비교 불가", .secondary)
            }
        }()
        return Text(label)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
