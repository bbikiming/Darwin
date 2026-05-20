import SwiftUI

/// **v1.11.12 (2026-05-19)** — Critic V2 typed JSON 응답 UI.
///
/// markdown text 대신 ClaudeCriticResponse 의 typed 필드를 구조화 표시:
/// - DataQuality verdict badge (pass/weak/fail 색)
/// - Diagnosis cards (axis + severity + evidence + confidence)
/// - NextExperiment card (axis + from→to + 승인 버튼)
/// - Forbidden warnings
/// - Recommendation badge
/// - "사용자 자연어 보고" 입력
public struct WalkDataClaudeV2Panel: View {
    @EnvironmentObject var critic: WalkSessionClaudeCritic
    @Binding var showApprovalSheet: Bool
    public var summaries: [WalkSessionSummary]
    public var headersById: [String: WalkSessionHeader]
    public var sampleStatsBuilder: (String) -> [WalkSessionClaudePromptV2.PhaseStatsV2]

    public init(showApprovalSheet: Binding<Bool>,
                summaries: [WalkSessionSummary],
                headersById: [String: WalkSessionHeader],
                sampleStatsBuilder: @escaping (String) -> [WalkSessionClaudePromptV2.PhaseStatsV2]) {
        self._showApprovalSheet = showApprovalSheet
        self.summaries = summaries
        self.headersById = headersById
        self.sampleStatsBuilder = sampleStatsBuilder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            header
            userReportInput
            Divider()
            if critic.inProgress {
                ProgressView("Claude critic 분석 중…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(DFSpace.sm)
            } else if let response = critic.currentResponse {
                ScrollView {
                    typedResponseContent(response)
                }
            } else if let error = critic.error {
                errorView(error)
            } else {
                placeholderView
            }
        }
        .background(DFColor.accent.opacity(DFOpacity.o06))
    }

    // MARK: - Components

    private var header: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(DFColor.accent)
            Text("Claude Critic V2 (typed JSON)")
                .font(DFFont.bodyEmph)
            Spacer()
            if critic.currentResponse != nil {
                Button {
                    critic.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("결과 초기화")
            }
            Button {
                Task { await invokeAnalysis() }
            } label: {
                Label("분석 실행", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(critic.inProgress || summaries.isEmpty)
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.top, DFSpace.xs)
    }

    private var userReportInput: some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "text.bubble")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
            TextField("사용자 보고 (예: \"앞으로 넘어졌어\")",
                      text: $critic.userReport, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)
                .font(DFFont.label)
        }
        .padding(.horizontal, DFSpace.sm)
    }

    @ViewBuilder
    private var placeholderView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude critic 이 최근 \(min(WalkSessionClaudePromptV2.maxSessions, summaries.count))개 세션 + 사용자 보고를 typed JSON 으로 분석합니다.")
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
            Text("• 8 axis V2 + DataQuality verdict + sagittal metric 통합 prompt")
                .font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            Text("• Critic role — controller 아님. 한 번에 한 axis 만 변경 권고")
                .font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            Text("• forbidden 4건 자동 차단 (hybridBA/v110/alternate/negate+alt)")
                .font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            Text("• 결과는 ~/Library/Application Support/DarwinForge/analyses/ 에 자동 저장")
                .font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.sm)
    }

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Critic 분석 실패", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DFColor.danger)
                .font(DFFont.bodyEmph)
            Text(err)
                .font(DFFont.label)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DFSpace.sm)
    }

    @ViewBuilder
    private func typedResponseContent(_ response: ClaudeCriticResponse) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            // 1. Quality verdict badge.
            qualityBadge(response.dataQuality)

            // 2. Summary (한 줄 요약).
            if let summary = response.summary, !summary.isEmpty {
                Text(summary)
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                    .padding(.horizontal, DFSpace.sm)
            }

            // 3. Diagnosis cards.
            if !response.diagnosis.isEmpty {
                Text("진단 (\(response.diagnosis.count)건)")
                    .font(DFFont.sectionLabel)
                    .padding(.horizontal, DFSpace.sm)
                ForEach(0..<response.diagnosis.count, id: \.self) { i in
                    diagnosisCard(response.diagnosis[i])
                }
            }

            // 4. nextExperiment card + 승인 버튼.
            if let exp = response.nextExperiment {
                nextExperimentCard(exp)
            } else if response.dataQuality.verdict == .fail {
                recollectCard(response.dataQuality.reasons)
            }

            // 5. Forbidden warnings.
            if !response.forbiddenChanges.isEmpty {
                forbiddenSection(response.forbiddenChanges)
            }

            // 6. Recommendation badge.
            if let rec = response.recommendation {
                recommendationBadge(rec)
            }

            // 7. Confidence + sessions analyzed.
            footer(response)
        }
        .padding(.bottom, DFSpace.sm)
    }

    @ViewBuilder
    private func qualityBadge(_ q: DataQualityVerdict) -> some View {
        let color: Color = {
            switch q.verdict {
            case .pass: return DFColor.success
            case .weak: return DFColor.warning
            case .fail: return DFColor.danger
            }
        }()
        HStack(spacing: DFSpace.xs) {
            Image(systemName: q.verdict == .pass ? "checkmark.shield.fill"
                  : (q.verdict == .weak ? "exclamationmark.shield.fill"
                     : "xmark.shield.fill"))
                .foregroundStyle(color)
            Text("데이터 품질: \(q.verdict.rawValue.uppercased())")
                .font(DFFont.bodyEmph)
                .foregroundStyle(color)
            Spacer()
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
        .padding(.horizontal, DFSpace.sm)
        if !q.reasons.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(q.reasons, id: \.self) { r in
                    Text("• \(r)")
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            .padding(.horizontal, DFSpace.sm)
        }
    }

    @ViewBuilder
    private func diagnosisCard(_ d: DiagnosisItem) -> some View {
        let severityColor: Color = {
            switch d.severity {
            case .low:      return DFColor.textSecondary
            case .med:      return DFColor.info
            case .high:     return DFColor.warning
            case .critical: return DFColor.danger
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(severityColor)
                Text("`\(d.axis.rawValue)`")
                    .font(DFFont.monoLabel)
                    .foregroundStyle(DFColor.textPrimary)
                Text(d.severity.rawValue.uppercased())
                    .font(DFFont.micro)
                    .foregroundStyle(severityColor)
                Spacer()
                Text("confidence \(Int(d.confidence * 100))%")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            ForEach(d.evidence, id: \.self) { ev in
                Text("• \(ev)")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DFSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(severityColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
        .padding(.horizontal, DFSpace.sm)
    }

    @ViewBuilder
    private func nextExperimentCard(_ exp: NextExperiment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "flask")
                    .foregroundStyle(DFColor.info)
                Text("다음 실험 제안")
                    .font(DFFont.bodyEmph)
                Spacer()
                Button {
                    showApprovalSheet = true
                } label: {
                    Label("승인 검토", systemImage: "hand.tap")
                        .font(DFFont.micro)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            HStack(spacing: DFSpace.xs) {
                Text("`\(exp.axis.rawValue)`:")
                    .font(DFFont.monoLabel)
                Text("\(exp.from) → \(exp.to)")
                    .font(DFFont.monoLabel.bold())
                    .foregroundStyle(DFColor.info)
            }
            Text("preset: \(exp.preset) · safety: \(exp.safety)")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
            Text("✓ 성공 metric: \(exp.successMetric)")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.success)
            Text("✗ rollback 조건: \(exp.rollbackCondition)")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.danger)
            if let risk = exp.riskNote {
                Text("⚠️ \(risk)")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.warning)
            }
        }
        .padding(DFSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.info.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
        .padding(.horizontal, DFSpace.sm)
    }

    @ViewBuilder
    private func recollectCard(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "arrow.clockwise.icloud")
                    .foregroundStyle(DFColor.warning)
                Text("데이터 재수집 권고")
                    .font(DFFont.bodyEmph)
            }
            Text("Quality verdict = FAIL — 분석 신뢰도 부족. 다음 조건 해결 후 재시도:")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
            ForEach(reasons.prefix(5), id: \.self) { r in
                Text("• \(r)")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
        .padding(.horizontal, DFSpace.sm)
    }

    @ViewBuilder
    private func forbiddenSection(_ list: [String]) -> some View {
        if list.isEmpty { EmptyView() } else {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list, id: \.self) { f in
                        Text("• `\(f)`")
                            .font(DFFont.micro)
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Forbidden \(list.count)건", systemImage: "hand.raised.fill")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.warning)
            }
            .padding(.horizontal, DFSpace.sm)
        }
    }

    @ViewBuilder
    private func recommendationBadge(_ r: Recommendation) -> some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: actionIcon(r.action))
                .foregroundStyle(actionColor(r.action))
            Text("권고: \(r.action.rawValue)")
                .font(DFFont.sectionLabel)
            if r.requiresHumanApproval {
                Text("(승인 필요)")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.warning)
            }
            Spacer()
        }
        .padding(.horizontal, DFSpace.sm)
    }

    private func actionIcon(_ action: Recommendation.Action) -> String {
        switch action {
        case .applyToBaseline: return "checkmark.circle"
        case .recollect:       return "arrow.clockwise"
        case .holdAndObserve:  return "eye"
        case .abort:           return "xmark.octagon"
        case .unknown:         return "questionmark.circle"
        }
    }

    private func actionColor(_ action: Recommendation.Action) -> Color {
        switch action {
        case .applyToBaseline: return DFColor.success
        case .recollect:       return DFColor.warning
        case .holdAndObserve:  return DFColor.info
        case .abort:           return DFColor.danger
        case .unknown:         return DFColor.textSecondary
        }
    }

    @ViewBuilder
    private func footer(_ response: ClaudeCriticResponse) -> some View {
        HStack(spacing: DFSpace.xs) {
            if let c = response.confidence {
                Text("Confidence \(Int(c * 100))%")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            if let sessions = response.sessionsAnalyzed, !sessions.isEmpty {
                Text("\(sessions.count) sessions")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.horizontal, DFSpace.sm)
    }

    // MARK: - Actions

    private func invokeAnalysis() async {
        await critic.analyze(
            sessions: summaries,
            headers: headersById,
            sampleStatsBuilder: sampleStatsBuilder
        )
    }
}
