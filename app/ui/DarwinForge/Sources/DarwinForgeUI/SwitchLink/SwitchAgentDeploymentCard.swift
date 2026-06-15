import SwiftUI

/// **에이전트 자동 배포 카드 (R2)** — `SwitchRobotLinkView` 의 한 섹션.
///
/// 한 번의 클릭으로 최신 `darwin-switch-agent` 를 Switch 에 설치·재시작한다:
/// package(번들 tarball) → scp → 원격 압축해제 → install.sh(sudo) → 검증.
/// sudo 비밀번호는 `SecureField` 로 1회 입력받아 install 단계 stdin 으로만 전달하고,
/// 배포 후 즉시 비운다(저장/로그 없음).
struct SwitchAgentDeploymentCard: View {

    @ObservedObject var deploy: SwitchAgentDeploySession
    @Binding var sudoPassword: String

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            header
            sudoField
            Label("비밀번호는 install 단계 stdin 으로만 전달 — 저장/로그하지 않습니다.",
                  systemImage: "lock.shield")
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
            deployButton
            ForEach(SwitchAgentDeployCommand.Stage.allCases) { stage in
                stageRow(stage)
            }
            if deploy.lastSucceeded {
                Label("배포 완료 — Switch 의 darwin-switch-agent 가 최신 코드로 재시작되었습니다.",
                      systemImage: "checkmark.seal.fill")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.success)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.sm)
            .stroke(DFColor.accent.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("에이전트 자동 배포")
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                Text("최신 darwin-switch-agent 를 Switch 에 설치 + 재시작")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
    }

    private var sudoField: some View {
        SecureField("Switch sudo 비밀번호", text: passwordBinding)
            .textFieldStyle(.roundedBorder)
            .disabled(deploy.isDeploying)
            .accessibilityIdentifier("switchlink.deploy.sudoField")
    }

    private var deployButton: some View {
        Button {
            let password = sudoPassword
            Task {
                _ = await deploy.deploy(sudoPassword: password)
                sudoPassword = ""   // 사용 후 즉시 비움.
            }
        } label: {
            HStack(spacing: DFSpace.xs) {
                if deploy.isDeploying {
                    ProgressView().controlSize(.small)
                    Text("배포 중…").font(DFFont.caption)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("배포 시작").font(DFFont.caption)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(DFColor.accent)
        .disabled(deploy.isDeploying || sudoPassword.isEmpty)
        .accessibilityIdentifier("switchlink.deploy.start")
    }

    private func stageRow(_ stage: SwitchAgentDeployCommand.Stage) -> some View {
        let outcome = deploy.outcome(stage)
        return HStack(alignment: .top, spacing: DFSpace.sm) {
            statusIcon(outcome.phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title).font(.system(size: DFFontSize.s11, weight: .medium))
                if !outcome.message.isEmpty {
                    Text(outcome.message)
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(phaseColor(outcome.phase))
                }
            }
            Spacer()
        }
    }

    /// 배포 중에는 SecureField 편집 잠금.
    private var passwordBinding: Binding<String> {
        Binding(get: { sudoPassword },
                set: { if !deploy.isDeploying { sudoPassword = $0 } })
    }

    private func statusIcon(_ phase: SwitchAgentDeploySession.Phase) -> some View {
        let (name, tint): (String, Color) = {
            switch phase {
            case .idle:    return ("circle", DFColor.textSecondary)
            case .running: return ("arrow.triangle.2.circlepath", DFColor.accent)
            case .success: return ("checkmark.circle.fill", DFColor.success)
            case .failed:  return ("xmark.octagon.fill", DFColor.danger)
            }
        }()
        return Image(systemName: name)
            .font(.system(size: DFFontSize.s12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 20)
    }

    private func phaseColor(_ phase: SwitchAgentDeploySession.Phase) -> Color {
        switch phase {
        case .success: return DFColor.success
        case .failed:  return DFColor.danger
        case .running: return DFColor.accent
        case .idle:    return DFColor.textSecondary
        }
    }
}
