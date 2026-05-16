import SwiftUI
import ForgeCore

/// v1.1 — 카테고리별 모션 카탈로그 브라우저.
///
/// 좌측 sidebar = 15 카테고리 + 페이지 수 / 우측 = 모션 카드 grid + 검색.
/// 카드 클릭 = 페이지 detail / "스튜디오로 로드" 액션.
///
/// 단독 독립 view — MotionStudioView 에서 별도 sheet 또는 sub-tab 으로 호출.
public struct MotionCatalogBrowser: View {

    @State private var selectedCategory: MotionCategory = .basicPose
    @State private var searchText: String = ""
    @State private var selectedPage: MotionPage?

    /// 외부에서 받아 페이지를 스튜디오로 로드할 콜백 (옵션).
    public var onLoadToStudio: ((MotionPage) -> Void)?

    public init(onLoadToStudio: ((MotionPage) -> Void)? = nil) {
        self.onLoadToStudio = onLoadToStudio
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            content
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(item: $selectedPage) { page in
            pageDetail(page)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("모션 카탈로그")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(BundledMotionCatalog.totalMotionCount) 개 — 15 카테고리")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(MotionCategory.displayOrder, id: \.self) { cat in
                        categoryRow(cat)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private func categoryRow(_ cat: MotionCategory) -> some View {
        let count = BundledMotionCatalog.count(for: cat)
        let isSelected = cat == selectedCategory

        return Button {
            selectedCategory = cat
            searchText = ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cat.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? .tint : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.label)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Text(cat.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))
                    .clipShape(Capsule())
                    .foregroundStyle(isSelected ? .tint : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: - Content (grid + search)

    private var content: some View {
        VStack(spacing: 0) {
            // Header — 검색바 + 카테고리 라벨.
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: selectedCategory.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text(selectedCategory.label)
                        .font(.system(size: 17, weight: .semibold))
                    Text("(\(filteredPages.count))")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("모션 이름 검색", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 240)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Grid.
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 12)
                ], spacing: 12) {
                    ForEach(filteredPages) { page in
                        motionCard(page)
                    }
                }
                .padding(16)
            }
        }
    }

    private var filteredPages: [MotionPage] {
        let all = BundledMotionCatalog.pages(for: selectedCategory)
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func motionCard(_ page: MotionPage) -> some View {
        Button {
            selectedPage = page
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: selectedCategory.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tint)
                    Spacer()
                    Text("#\(page.id)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(page.name.isEmpty ? "모션 \(page.id)" : page.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(page.steps.count) step")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatMs(totalMs(page)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func totalMs(_ page: MotionPage) -> Int {
        page.steps.reduce(0) { $0 + $1.playMs + $1.pauseMs }
    }

    private func formatMs(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000.0
        return String(format: "%.1f s", s)
    }

    // MARK: - Detail sheet

    private func pageDetail(_ page: MotionPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: selectedCategory.icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.name.isEmpty ? "모션 \(page.id)" : page.name)
                        .font(.title3.bold())
                    Text("\(selectedCategory.label) · #\(page.id) · \(page.steps.count) step · \(formatMs(totalMs(page)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { selectedPage = nil }
            }

            Divider()

            // Step list.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(page.steps.enumerated()), id: \.offset) { idx, step in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("play \(step.playMs) ms" + (step.pauseMs > 0 ? " · pause \(step.pauseMs) ms" : ""))
                                    .font(.caption.monospacedDigit())
                                Text("관절 raw: " + stepSummary(step))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                if let load = onLoadToStudio {
                    Button("스튜디오로 로드") {
                        load(page)
                        selectedPage = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("닫기") { selectedPage = nil }
            }
        }
        .padding(24)
        .frame(width: 560, height: 540)
    }

    private func stepSummary(_ step: MotionStep) -> String {
        // 처음 5 슬롯의 raw 위치 표시 (가독성).
        let head = step.positions.prefix(6).map { String($0) }.joined(separator: " ")
        return head + "..."
    }
}

#Preview {
    MotionCatalogBrowser()
        .frame(width: 980, height: 720)
}
