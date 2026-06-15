import SwiftUI

/// **V280-C (2026-05-24)**: WalkDataView 4-layer → segmented control 통합.
/// `claudePanel` (markdown 분석) sub-view 를 별도 file 로 추출.
///
/// 종전: WalkDataView.swift line 339-432 (94 LOC) 내장.
/// 변경: 분리 추출 — WalkDataView 800 LOC 한계 준수 + cohesion 향상.
///
/// **v1.11.9 패턴 보존**: Claude CLI 가 markdown 으로 분석 결과 반환.
/// 사용자 자연어 보고 입력 → Claude prompt builder → analyst.analyze() 호출.
public struct WalkDataClaudePanel: View {
    @Binding var claudeMarkdown: String?
    @Binding var claudeError: String?
    @Binding var claudeInProgress: Bool
    @Binding var claudeUserReport: String
    public var summaries: [WalkSessionSummary]
    public var onAnalyze: () async -> Void

    public init(claudeMarkdown: Binding<String?>,
                claudeError: Binding<String?>,
                claudeInProgress: Binding<Bool>,
                claudeUserReport: Binding<String>,
                summaries: [WalkSessionSummary],
                onAnalyze: @escaping () async -> Void) {
        self._claudeMarkdown = claudeMarkdown
        self._claudeError = claudeError
        self._claudeInProgress = claudeInProgress
        self._claudeUserReport = claudeUserReport
        self.summaries = summaries
        self.onAnalyze = onAnalyze
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            header
            userReportInput
            Divider()
            resultArea
        }
        .background(DFColor.accent.opacity(DFOpacity.o06))
    }

    private var header: some View {
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
                Task { await onAnalyze() }
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
                .accessibilityLabel("Claude 분석 결과 초기화")
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.top, DFSpace.xs)
    }

    private var userReportInput: some View {
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
    }

    @ViewBuilder
    private var resultArea: some View {
        ScrollView {
            if let md = claudeMarkdown {
                Text(md)
                    .font(DFFont.monoCaption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DFSpace.sm)
            } else if let err = claudeError {
                errorView(err)
            } else {
                placeholderView
            }
        }
    }

    private func errorView(_ err: String) -> some View {
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
    }

    private var placeholderView: some View {
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
