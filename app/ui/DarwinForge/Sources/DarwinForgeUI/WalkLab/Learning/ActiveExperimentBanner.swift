import SwiftUI

/// **v1.11.14.7 (2026-05-19) — 사용자 평가 HIGH fix**: 활성 실험 floating banner.
///
/// 사용자가 critic 권고 승인 후 실험 진행 중 — RootView 위에 floating banner 표시:
/// - 현재 experimentId + baselineSessionId
/// - lastComparison 의 verdict (있으면)
/// - "Rollback" 버튼 (변경 전 config 복원)
/// - "완료 (수락)" 버튼 (clearExperimentContext — 변경 유지)
///
/// 종전: 자동 rollback (failRollback verdict) 만 구현. 사용자 명시 rollback 불가.
/// inconclusive verdict 후 사용자가 "그냥 원래대로 돌리고 싶다" 의도 지원.
public struct ActiveExperimentBanner: View {
    @Environment(WalkLabSession.self) private var session
    @EnvironmentObject private var experimentLoop: ExperimentLoopController
    @Environment(\.dfTheme) private var theme: DFTheme

    public init() {}

    public var body: some View {
        // 활성 실험 없으면 표시 X.
        if let expId = session.activeExperimentId {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                headerRow(experimentId: expId)
                if let comp = experimentLoop.lastComparison {
                    verdictRow(comp: comp)
                }
                buttonRow
            }
            .padding(DFSpace.sm2)
            .background(DFColor.adaptiveCard(theme))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(DFColor.info.opacity(DFOpacity.o30),
                            lineWidth: DFSize.borderHairline)
            )
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .frame(maxWidth: 360)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("활성 실험 \(expId)")
        }
    }

    private func headerRow(experimentId: String) -> some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "flask.fill")
                .foregroundStyle(DFColor.info)
            VStack(alignment: .leading, spacing: 1) {
                Text("실험 진행 중")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textPrimary)
                Text(experimentId)
                    .font(DFFont.monoLabel)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func verdictRow(comp: WalkLabExperimentLoop.ComparisonResult) -> some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: verdictIcon(comp.verdict))
                .foregroundStyle(verdictColor(comp.verdict))
            Text("최근 비교: \(comp.verdict.rawValue)")
                .font(DFFont.label)
                .foregroundStyle(verdictColor(comp.verdict))
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var buttonRow: some View {
        HStack(spacing: DFSpace.xs) {
            Button {
                _ = session.rollbackExperiment()
            } label: {
                Label("Rollback", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(DFFont.label)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DFColor.warning)
            .help("변경 전 config 로 복원. 보행 중이면 자동 stop 후 복원.")

            Spacer()

            Button {
                Task { @MainActor in
                    await experimentLoop.finalize()
                    session.clearExperimentContext()
                }
            } label: {
                Label("수락 (완료)", systemImage: "checkmark.circle.fill")
                    .font(DFFont.label)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DFColor.success)
            .help("실험 변경 유지하고 종료 — history 기록.")
        }
    }

    private func verdictIcon(_ v: WalkLabExperimentLoop.Experiment.Verdict) -> String {
        switch v {
        case .success: return "checkmark.circle.fill"
        case .failRollback: return "xmark.circle.fill"
        case .inconclusive: return "questionmark.circle.fill"
        }
    }

    private func verdictColor(_ v: WalkLabExperimentLoop.Experiment.Verdict) -> Color {
        switch v {
        case .success: return DFColor.success
        case .failRollback: return DFColor.danger
        case .inconclusive: return DFColor.warning
        }
    }
}
