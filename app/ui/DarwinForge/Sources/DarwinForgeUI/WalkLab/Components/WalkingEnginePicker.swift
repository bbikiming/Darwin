import SwiftUI

/// **v1.11.5 (2026-05-18) — 보행 엔진 선택 UI 패널**.
///
/// 사용자가 한 화면에서 두 보행 엔진을 토글:
/// - **Mac sparse keyframe** (default) — 즉시 동작, 약 10Hz 등가, IMU balance 없음
/// - **ROBOTIS onboard** — 안정 보행 (Ball tracker 와 동일 엔진), robot-side patch 필요
///
/// 사용자 흐름:
/// 1. 패널에서 ROBOTIS onboard 선택
/// 2. 안전 경고 표시 — "robot-side patch 미설치 시 SOCCER 기본 모드로 시작됨"
/// 3. "ROBOTIS 측 시작" 버튼 — RemoteShell 통해 walkLabRobotisStart 명령 send
/// 4. WalkLab preset 시작 → Mac sparse 합성 우회, robot 측 Walking::GetInstance() 사용
/// 5. 사용자가 종료 시 "ROBOTIS 측 종료" 버튼 → walkLabRobotisStop send
public struct WalkingEnginePicker: View {
    @ObservedObject var session: WalkLabSession
    /// RemoteShell 명령 전송 callback — 부모 view 가 inject. nil 이면 버튼 disabled.
    public var onStartOnboard: (() -> Void)? = nil
    public var onStopOnboard: (() -> Void)? = nil
    /// **v1.11.5.1 (2026-05-18)** — 현재 preset/tuning 의 x/y/a 명령 brokering callback.
    /// 부모 view 가 `WalkLabSession.currentWalkingEngineCommand(enabled:)` 결과를
    /// `RemoteShell.send(RobotSetupCommand.walkLabRobotisSendCommand(line:))` 로 전달.
    public var onSendCommand: ((WalkingEngineCommand) -> Void)? = nil

    public init(
        session: WalkLabSession,
        onStartOnboard: (() -> Void)? = nil,
        onStopOnboard: (() -> Void)? = nil,
        onSendCommand: ((WalkingEngineCommand) -> Void)? = nil
    ) {
        self.session = session
        self.onStartOnboard = onStartOnboard
        self.onStopOnboard = onStopOnboard
        self.onSendCommand = onSendCommand
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            // 헤더
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "cpu.fill")
                    .font(DFFont.label)
                    .foregroundStyle(engineTint)
                Text("보행 엔진 (v1.11.5)")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textPrimary)
                Spacer()
                Text(session.walkingEngine.shortLabel)
                    .font(DFFont.micro)
                    .foregroundStyle(engineTint)
            }

            // 2 옵션 picker — segmented.
            // **v1.11.7.1 (2026-05-18) fix**: macOS SwiftUI Picker.segmented 의 HStack
            // 안 tag 시각 버그 — selection binding 변경되지만 indicator 가 첫 옵션에
            // 남는 케이스. Text-only + tag 단순화로 시각/실제 state 일치 보장.
            Picker("보행 엔진", selection: $session.walkingEngine) {
                ForEach(WalkingEngine.allCases) { engine in
                    Text(engine.shortLabel).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // 현재 엔진 설명
            Text(session.walkingEngine.description)
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // ROBOTIS onboard 시 안전 경고 + 시작/종료 버튼
            if session.walkingEngine == .robotisOnboard {
                onboardWarning
                onboardActions
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.info.opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Components

    private var engineTint: Color {
        switch session.walkingEngine {
        case .macSparseKeyframe: return DFColor.textSecondary
        case .robotisOnboard:    return DFColor.warning
        }
    }

    @ViewBuilder
    private var onboardWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.warning)
                Text("robot-side patch 필요")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textPrimary)
            }
            Text("미설치 시 SOCCER 기본 모드로 동작 (ball tracker 와 동일). Mac 측 x/y/a 명령은 무시됩니다. patched binary 경로: ~/Framework/Linux/project/demo/demo-pilot")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DFSpace.xs2)
    }

    @ViewBuilder
    private var onboardActions: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs2) {
                Button {
                    onStartOnboard?()
                } label: {
                    Label("ROBOTIS 측 시작", systemImage: "play.fill")
                        .font(DFFont.micro)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(onStartOnboard == nil)

                Button {
                    onStopOnboard?()
                } label: {
                    Label("ROBOTIS 측 종료", systemImage: "stop.fill")
                        .font(DFFont.micro)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(onStopOnboard == nil)

                Spacer()
            }

            // **v1.11.5.1 (2026-05-18)** — x/y/a 명령 brokering 송출 버튼.
            // 사용자가 preset 또는 tuning 변경 후 누르면 robot 의 `/tmp/df-walklab-cmd`
            // 에 한 줄 write — robot-side patch 가 5Hz polling 으로 read.
            //
            // **v1.11.24 (2026-05-20) audit iter2-E** — quickPreflight 와 동일한 차단 사유
            // (cradle / caution + balance OFF / SSH / IMU) 를 버튼 단계에서 적용.
            // 종전: 사용자가 fastWalk + 보정 OFF 상태로 본 버튼 눌러 robot 에 직접 송출 가능 → 낙상 위험.
            // v1.11.24 audit iter3-B — enabled 는 실 motor task 가 active 인 preset 우선.
            // 종전: session.current 만 보고 enabled 결정 → preflight 차단으로 current 가
            // 바뀌지 않더라도 stale `enabled` 송출. 일관성을 위해 bridge 와 같은 source.
            let effectivePreset = session.activeRobotPreset ?? session.current
            let currentCmd = session.currentWalkingEngineCommand(
                enabled: effectivePreset != .idle
            )
            let manualSendBlock = session.onboardManualSendBlockReason
            HStack(spacing: DFSpace.xs2) {
                Button {
                    onSendCommand?(currentCmd)
                } label: {
                    Label("현재 명령 송출 (\(currentCmd.serializedLine))",
                          systemImage: "paperplane.fill")
                        .font(DFFont.micro)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(onSendCommand == nil || manualSendBlock != nil)
                .help(manualSendBlock ?? "현재 preset/tuning 을 robot 에 송출")
                if let reason = manualSendBlock {
                    Text(reason)
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.warning)
                        .lineLimit(1)
                }
                Spacer()
            }

            // **v1.11.6 (2026-05-18)** — 자동 brokering 토글 + 300ms debounce 안내.
            // ON 이면 preset/tuning 변경 시 WalkLabOnboardBridge 가 자동 SSH send.
            Toggle(isOn: $session.autoOnboardBrokering) {
                HStack(spacing: 4) {
                    Image(systemName: session.autoOnboardBrokering
                          ? "antenna.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                        .font(DFFont.micro)
                        .foregroundStyle(session.autoOnboardBrokering ? DFColor.success : DFColor.textSecondary)
                    Text("자동 명령 송출 (300ms debounce)")
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }
}
