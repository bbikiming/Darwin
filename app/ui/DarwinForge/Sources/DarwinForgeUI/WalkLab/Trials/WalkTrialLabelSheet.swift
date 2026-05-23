import SwiftUI

/// **v1.15.0 (2026-05-21) — Phase 1 라벨 modal**.
///
/// trial 종료 직후 또는 검색 UI 에서 사용자가 trial 을 평가하는 sheet.
///
/// # 라벨 구성
///
/// 1. **별점 1-5** — 빠른 정량 평가 (필수 X, 0 = 미평가).
/// 2. **자동 태그 추천** — outcome metric 기반 (smooth/unstable/etc), 사용자가 선택/해제.
/// 3. **사용자 정의 태그** — 자유 입력 (콤마 또는 enter 로 분리).
/// 4. **자유 텍스트** — Claude critic 의 학습 신호.
///
/// # UX 원칙
///
/// - 별점은 키보드 1-5 단축키 지원 (빠른 라벨링).
/// - 자동 태그는 토글 chip (한 번 더 누르면 해제).
/// - "건너뛰기" 버튼으로 label 없이 종료 가능 (사용자 압박 X).
/// - sheet 진입 즉시 outcome metric 표시 (사용자가 "왜 별점 5?" 결정 가능).
public struct WalkTrialLabelSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 라벨링 대상 trial. WalkTrialStore 에 저장 후 sheet 진입.
    public let trial: WalkTrial

    /// 사용자 saved label callback. SafetyGate 등 외부에서 chain 처리.
    public let onSave: (UserLabel) -> Void

    /// 사용자가 sheet 닫기만 누를 때 호출 (skip).
    public let onSkip: (() -> Void)?

    @State private var rating: Int = 0
    @State private var freeText: String = ""
    @State private var selectedAutoTags: Set<String> = []
    @State private var customTagsInput: String = ""

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init(trial: WalkTrial, onSave: @escaping (UserLabel) -> Void, onSkip: (() -> Void)? = nil) {
        self.trial = trial
        self.onSave = onSave
        self.onSkip = onSkip
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            outcomeSummary
            Divider()
            ratingSection
            Divider()
            autoTagsSection
            customTagsSection
            freeTextSection
            Spacer()
            footerButtons
        }
        .padding(20)
        .frame(width: 520, height: 620)
        .onAppear {
            // 자동 태그 추천을 default 선택 — 사용자가 빠르게 confirm 또는 해제.
            selectedAutoTags = Set(WalkTrialAutoTag.suggest(for: trial))
        }
    }

    // MARK: - Sub views

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("이번 보행 어땠나요?")
                    .font(.title2.weight(.semibold))
                Text("\(trial.config.preset) · \(String(format: "%.1f", trial.durationSec))초 · \(trial.endReason.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: {
                harness.record(.walklabTrialLabelSkipped, level: .info, actor: .user)
                onSkip?()
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("건너뛰기 (라벨 저장 안 함)")
        }
    }

    private var outcomeSummary: some View {
        HStack(spacing: 16) {
            scorePill(title: "안정성", score: trial.outcome.stabilityScore, color: .green)
            scorePill(title: "부드러움", score: trial.outcome.smoothnessScore, color: .blue)
            scorePill(title: "효율", score: trial.outcome.energyScore, color: .orange)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("총점")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f", trial.outcome.overallScore * 100))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(overallColor)
            }
            if trial.outcome.fallEventCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("낙상")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(trial.outcome.fallEventCount)건")
                        .font(.callout.bold())
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var overallColor: Color {
        let s = trial.outcome.overallScore
        if s >= 0.8 { return .green }
        if s >= 0.6 { return .blue }
        if s >= 0.4 { return .orange }
        return .red
    }

    private func scorePill(title: String, score: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f", score * 100))
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("별점")
                .font(.headline)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Button(action: { rating = star }) {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(star <= rating ? Color.yellow : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(star)")), modifiers: [])
                    .help("\(star) 별점 (키보드 \(star))")
                }
                Spacer()
                if rating > 0 {
                    Button("초기화") { rating = 0 }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    private var autoTagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("자동 추천 태그")
                    .font(.headline)
                Spacer()
                Text("\(selectedAutoTags.count)개 선택")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            let auto = WalkTrialAutoTag.suggest(for: trial)
            if auto.isEmpty {
                Text("추천 태그 없음 — 직접 입력 또는 건너뛰기")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayoutTags(tags: auto, selected: $selectedAutoTags)
            }
        }
    }

    private var customTagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("직접 태그 (콤마 또는 엔터로 분리)")
                .font(.headline)
            TextField("예: dance-ready, demo-good", text: $customTagsInput)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var freeTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("자유 메모 (Claude 가 학습 신호로 사용)")
                .font(.headline)
            TextEditor(text: $freeText)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("건너뛰기") {
                harness.record(.walklabTrialLabelSkipped, level: .info, actor: .user)
                onSkip?()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("저장") {
                let allTags = Array(selectedAutoTags) + parseCustomTags(customTagsInput)
                let dedup = Array(Set(allTags))
                let trimmedFreeText = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
                harness.record(
                    .walklabTrialLabeled, level: .info, actor: .user,
                    data: ["rating": AnyCodable(max(1, rating)),
                           "tag_count": AnyCodable(dedup.count),
                           "has_free_text": AnyCodable(!trimmedFreeText.isEmpty)]
                )
                let label = UserLabel(
                    rating: max(1, rating),  // 별점 0 도 저장 시 1 로 보정 (UserLabel init 정책).
                    freeText: trimmedFreeText,
                    tags: dedup,
                    labeledAtIso: ISO8601DateFormatter().string(from: Date())
                )
                onSave(label)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(rating == 0 && freeText.isEmpty && selectedAutoTags.isEmpty && customTagsInput.isEmpty)
        }
    }

    private func parseCustomTags(_ input: String) -> [String] {
        input
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - FlowLayout for tag chips

/// 가변 길이 태그를 wrap 하는 단순 flow layout. SwiftUI 기본 미제공이라 자체 구현.
private struct FlowLayoutTags: View {
    let tags: [String]
    @Binding var selected: Set<String>

    var body: some View {
        // Apple-suggested approach: HStack with .layoutPriority + ViewThatFits.
        // 단순 구현 — 2-row HStack with manual chunking (10개 max 예상).
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunk(tags, by: 4), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { tag in
                        TagChip(tag: tag, isSelected: selected.contains(tag)) {
                            if selected.contains(tag) {
                                selected.remove(tag)
                            } else {
                                selected.insert(tag)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func chunk(_ array: [String], by size: Int) -> [[String]] {
        guard !array.isEmpty else { return [] }
        var result: [[String]] = []
        var current: [String] = []
        for tag in array {
            current.append(tag)
            if current.count == size {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private struct TagChip: View {
    let tag: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
