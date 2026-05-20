import SwiftUI

/// Walk Lab 의 Learning 섹션 top-level — Session List + A/B 비교 패널 + 안내.
public struct WalkLearningView: View {
    @StateObject private var model: WalkSessionListModel
    @State private var showABPanel: Bool = false

    public init(store: WalkSessionStore = WalkSessionStore()) {
        _model = StateObject(wrappedValue: WalkSessionListModel(store: store))
    }

    public var body: some View {
        VStack(spacing: 0) {
            tipBanner
            Divider()
            HSplitView {
                listSide
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
                rightSide
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.reload() }
    }

    private var tipBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("데이터 품질이 통과하지 않으면 알고리즘 비교 결론은 내리지 않습니다.")
                    .font(.caption.weight(.semibold))
                Text("v1 (구버전) 로그는 IMU 중복률이 높아 대부분 \"기울기 확인만 가능\" 또는 \"판단 불가\" 로 분류됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("A/B 비교", isOn: $showABPanel)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.06))
    }

    private var listSide: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("기록된 세션")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(model.items.count)개")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("다시 스캔")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if model.items.isEmpty {
                emptyState
            } else {
                List(model.items, selection: $selectedItemId) { item in
                    WalkSessionListRow(item: item)
                        .padding(.vertical, 4)
                        .tag(item.id)
                }
                .listStyle(.inset)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    @State private var selectedItemId: WalkSessionListItem.ID?

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
    private var rightSide: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showABPanel {
                    WalkABComparisonPanel(model: model)
                }
                if let id = selectedItemId,
                   let item = model.items.first(where: { $0.id == id }) {
                    WalkSessionQualityDetailPanel(summary: item.summary)
                } else if !showABPanel {
                    placeholderDetail
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, 60)
    }
}
