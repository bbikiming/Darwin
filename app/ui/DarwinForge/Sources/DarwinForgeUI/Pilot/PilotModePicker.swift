import SwiftUI

/// Pilot 조작 모드 — 수동 / 공 자동 추적 (PRD §3 좌측 패널 2).
///
/// **모드 모델 (Sprint 18 — Codex 권고)**:
///   - `.manual`: forge-bridge (5530) 활성, Mac 앱이 모터 직접 송출 (Action Bar / D-pad sim).
///   - `.ballFollow`: 로봇 측 ROBOTIS `demo` 가 USB bus 점유 + vision/soccer 모드 (걷기·차기 포함).
///     Mac 앱은 카메라 미리보기만 가능, 모터 직접 송출은 불가.
///
/// 모드 변경은 `RemotePilotView` 가 `RemoteShell` 로 `RobotSetupCommand.demoStop`
/// 또는 `RobotSetupCommand.ballTrackerStart` 를 발송하여 로봇 측 데몬을 전환한다.
public enum PilotMode: String, Sendable, CaseIterable, Identifiable {
    case manual
    case ballFollow

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .manual:     return "수동"
        case .ballFollow: return "공 자동 추적"
        }
    }
    public var detailLabel: String {
        switch self {
        case .manual:     return "Mac 앱이 모터 직접 송출"
        case .ballFollow: return "로봇 데모가 vision + 걷기 + 차기"
        }
    }
    public var icon: String {
        switch self {
        case .manual:     return "gamecontroller"
        case .ballFollow: return "target"
        }
    }
}

public struct PilotModePicker: View {
    @Binding var mode: PilotMode
    let flags: PilotFeatureFlags
    /// Pilot demo 모드 전환의 진행/결과 상태 — 부모(RemotePilotView)에서 주입.
    let demoStatus: PilotDemoStatus
    /// patched `demo-pilot` binary 가 robot 측에 설치돼 있는지.
    /// nil = 미확인, true = 자동 SOCCER 진입 가능, false = 사용자가 후면 버튼 필요.
    let patchedDemoInstalled: Bool?

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init(mode: Binding<PilotMode>, flags: PilotFeatureFlags,
                demoStatus: PilotDemoStatus = .idle,
                patchedDemoInstalled: Bool? = nil) {
        self._mode = mode
        self.flags = flags
        self.demoStatus = demoStatus
        self.patchedDemoInstalled = patchedDemoInstalled
    }

    public var body: some View {
        DFPanel(
            "조작 모드",
            subtitle: subtitleText,
            icon: "switch.2",
            tint: panelTint,
            trailing: { statusChip }
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                Picker("모드", selection: $mode) {
                    Label(PilotMode.manual.label, systemImage: PilotMode.manual.icon)
                        .tag(PilotMode.manual)
                    Label(PilotMode.ballFollow.label, systemImage: PilotMode.ballFollow.icon)
                        .tag(PilotMode.ballFollow)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .labelsHidden()
                // 2026-05-17 a11y: labelsHidden 후 VoiceOver 가 "Picker" 만 announce.
                .accessibilityLabel("조작 모드 선택")
                .accessibilityValue(mode == .manual ? "수동" : "공 추적")
                .disabled(!flags.ballFollow && mode != .manual)
                .onChange(of: mode) { _, newMode in
                    harness.record(
                        .pilotModeChanged, level: .info, actor: .user,
                        data: ["mode": AnyCodable(newMode.rawValue),
                               "ball_follow_enabled": AnyCodable(flags.ballFollow)]
                    )
                    if newMode == .ballFollow && !flags.ballFollow {
                        mode = .manual
                    }
                }

                modeDescription
                physicalButtonHint

                if !flags.ballFollow {
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(PilotColor.comingSoon)
                        Text("공 자동 추적은 v1.5 부터 활성 (ROBOTIS demo 의 soccer 모드 호출)")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, DFSpace.sm)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .fill(PilotColor.comingSoon.opacity(DFOpacity.o10))
                    )
                }
            }
        }
    }

    // MARK: - Subtitle / chip / description

    private var subtitleText: String {
        if !flags.ballFollow { return "v1.0: 수동만 활성" }
        switch demoStatus {
        case .idle:               return "수동 / 공 자동 추적 선택"
        case .launching:          return "ROBOTIS demo 시작 중…"
        case .stopping:           return "데모 종료 후 forge-bridge 복구 중…"
        case .ballFollowActive:   return "공 자동 추적 데모 활성 — Mac 직접 송출 비활성"
        case .manualActive:       return "수동 모드 — Mac 앱이 모터 직접 송출"
        case .failure(let msg):   return "전환 실패: \(msg)"
        }
    }

    private var panelTint: Color {
        switch demoStatus {
        case .ballFollowActive, .manualActive: return DFColor.success
        case .launching, .stopping:            return DFColor.warning
        case .failure:                         return DFColor.danger
        case .idle:                            return DFColor.info
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch demoStatus {
        case .idle:
            EmptyView()
        case .launching:
            DFChip("전환 중", icon: "arrow.triangle.2.circlepath", style: .warning)
        case .stopping:
            DFChip("종료 중", icon: "arrow.triangle.2.circlepath", style: .warning)
        case .ballFollowActive:
            DFChip("ROBOTIS demo", icon: "target", style: .success)
        case .manualActive:
            DFChip("수동 모드", icon: "gamecontroller", style: .success)
        case .failure:
            DFChip("실패", icon: "exclamationmark.triangle.fill", style: .danger)
        }
    }

    /// 모드별 한 줄 의미 — 사용자가 무엇이 가능/불가능한지 인지.
    @ViewBuilder
    private var modeDescription: some View {
        HStack(alignment: .top, spacing: DFSpace.xs2) {
            Image(systemName: mode.icon)
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.detailLabel)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textPrimary)
                Text(secondaryDescriptionText)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .fill(DFColor.accent.opacity(DFOpacity.o10))
        )
    }

    private var secondaryDescriptionText: String {
        switch mode {
        case .manual:
            return "Action Bar / D-pad / ARM 사용 가능 (USB 또는 네트워크 5530)."
        case .ballFollow:
            return "로봇이 자체적으로 공을 찾아 head·walk·kick 수행. Mac 모터 송출은 비활성."
        }
    }

    /// 로봇 후면 MODE / START 버튼 안내 — patched demo 없을 때 필요.
    /// patched 가 설치돼 있으면 "자동 진입" 표시, 미설치/미확인이면 후면 버튼 안내.
    @ViewBuilder
    private var physicalButtonHint: some View {
        if mode == .ballFollow && flags.ballFollow {
            HStack(alignment: .top, spacing: DFSpace.xs2) {
                Image(systemName: patchedDemoInstalled == true
                      ? "checkmark.seal.fill"
                      : "button.programmable")
                    .foregroundStyle(patchedDemoInstalled == true ? DFColor.success : DFColor.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(physicalHintTitle)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textPrimary)
                    Text(physicalHintBody)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .fill((patchedDemoInstalled == true ? DFColor.success : DFColor.info)
                          .opacity(DFOpacity.o10))
            )
        }
    }

    private var physicalHintTitle: String {
        switch patchedDemoInstalled {
        case .some(true):  return "패치 demo 설치됨 — 자동 SOCCER 진입"
        case .some(false): return "원본 demo — 로봇 후면 버튼 1회씩 필요"
        case .none:        return "demo 시작 방법"
        }
    }

    private var physicalHintBody: String {
        switch patchedDemoInstalled {
        case .some(true):
            return "demo 가 시작되면 약 3-5초간 gyro calibration 후 자동으로 공 추적 시작."
        case .some(false):
            return "로봇 후면 MODE 버튼 1회 → SOCCER 선택, START 버튼 1회 → 공 추적 시작. ⌘6 → ‘패치 demo 빌드’ 한 번 실행하면 자동 진입 가능."
        case .none:
            return "1) Mac UI 가 자동 (패치 demo 빌드 후) 또는  2) 로봇 후면 MODE → START 버튼 (각 1회)."
        }
    }
}

/// 모드 전환 라이프사이클 — RemotePilotView 가 owner.
public enum PilotDemoStatus: Equatable, Sendable {
    case idle
    case launching
    case stopping
    case ballFollowActive
    case manualActive
    case failure(String)
}

/// `RobotSetupCommand.ballTrackerStatus` 의 결과 첫 줄 marker 를 PilotDemoStatus 로 변환.
///
/// 출력 contract:
/// - `DF_STATUS=demo`   → ROBOTIS demo 실행 중 → `.ballFollowActive`
/// - `DF_STATUS=bridge` → forge-bridge 만 활성 → `.manualActive`
/// - `DF_STATUS=idle`   → 둘 다 비활성 → `.idle`
/// - 그 외/빈 결과     → 변경하지 않음 (nil 반환, 호출자가 기존 status 유지)
public enum PilotDemoStatusParser {
    public static func parse(_ raw: String?) -> PilotDemoStatus? {
        guard let raw, !raw.isEmpty else { return nil }
        let firstLine = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "DF_STATUS=demo":   return .ballFollowActive
        case "DF_STATUS=bridge": return .manualActive
        case "DF_STATUS=idle":   return .idle
        default:                 return nil
        }
    }
}
