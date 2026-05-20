import SwiftUI

/// 디스크의 세션 파일들을 나열. 각 row 에 quality badge / preset / duration / algorithm /
/// 추천 액션을 한 줄 요약으로 보여준다.
public struct WalkSessionListView: View {
    @StateObject private var model: WalkSessionListModel
    @State private var selection: WalkSessionListItem.ID?

    public init(store: WalkSessionStore = WalkSessionStore()) {
        _model = StateObject(wrappedValue: WalkSessionListModel(store: store))
    }

    public var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.reload()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("기록된 세션")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.items.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.items.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(model.items) { item in
                        WalkSessionListRow(item: item)
                            .tag(item.id)
                            .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("아직 기록된 세션이 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let item = model.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WalkSessionQualityDetailPanel(summary: item.summary)
                }
                .padding(14)
            }
        } else {
            placeholderDetail
        }
    }

    private var placeholderDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("세션을 선택하면 데이터 품질과 추천이 표시됩니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 한 row — preset / duration / quality / recommendation 요약.
struct WalkSessionListRow: View {
    let item: WalkSessionListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.summary.preset)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f초", item.summary.durationSec))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                WalkSessionQualityBadge(grade: item.summary.dataQuality.grade,
                                         useClass: item.summary.dataQuality.useClass)
                Spacer()
                Text(String(format: "중복 %.0f%%",
                            item.summary.dataQuality.imuDuplicateRatio * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(item.summary.dataQuality.imuDuplicateRatio > 0.4 ? .orange : .secondary)
            }
            HStack(spacing: 6) {
                Text(WalkRecommendationLabels.actionLabel(item.summary.recommendation.action))
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(actionTint)
                Spacer()
                Text(item.algorithmLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionTint: Color {
        switch item.summary.recommendation.action {
        case .doNotUseForLearning, .markSignSuspicious, .markHybridPhaseSuspicious: return .red
        case .raiseIntensity: return .blue
        case .lowerIntensity, .switchToObserveOnly: return .orange
        case .keepCurrent, .collectMoreData: return .secondary
        }
    }
}

/// 리스트 행 모델 — 디코드된 세션 + summary 짝.
public struct WalkSessionListItem: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let summary: WalkSessionSummaryV2
    public let header: WalkSessionHeaderResolved

    public var algorithmLabel: String {
        let mode = header.balanceAlgorithmMode ?? "알고리즘 정보 없음"
        let apply = header.correctionApplyMode ?? ""
        if apply.isEmpty { return mode }
        return "\(mode) · \(apply)"
    }
}

@MainActor
public final class WalkSessionListModel: ObservableObject {
    @Published public var items: [WalkSessionListItem] = []
    public let store: WalkSessionStore

    public init(store: WalkSessionStore) {
        self.store = store
    }

    public func reload() {
        let urls = store.discoverSessions()
        var rows: [WalkSessionListItem] = []
        for url in urls {
            guard let decoded = try? store.loadSession(file: url) else { continue }
            let summary = WalkSessionAnalyzer.summarize(session: decoded)
            rows.append(WalkSessionListItem(
                id: decoded.header.sessionId,
                url: url,
                summary: summary,
                header: decoded.header
            ))
        }
        self.items = rows
    }
}
