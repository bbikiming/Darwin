import ForgeCore
import SwiftUI

/// 영상 편집 도구 (Adobe Premiere / Final Cut Pro / After Effects) 스타일의 transport bar.
///
/// 레이아웃 (좌→우):
///   - Transport cluster: ⏮ ◀ ⏯ ▶ ⏭ (rewind / step back / play-pause / step forward / fast forward)
///   - Loop 토글 / Speed selector (0.5x / 1x / 2x)
///   - Timecode display (큰 monospace, 현재 / 총 + step counter)
///   - Action cluster: Live to Robot (record red) + 자세 추가 + 로봇 자세 가져오기
///
/// 디자인 ref: Premiere Pro source monitor, Final Cut Pro viewer, AE composition panel.
public struct TransportBar: View {

    // MARK: - Inputs

    @ObservedObject public var player: MotionPlayer
    public let totalDurationMs: Double
    public let stepCount: Int
    public let hasBus: Bool
    @Binding public var sendToHardware: Bool
    public let isDirty: Bool
    public let executingOnRobot: Bool
    public let canUndo: Bool
    public let canRedo: Bool
    public let onPlay: () -> Void
    public let onAddStep: () -> Void
    public let onCapture: () -> Void
    public let onRunOnRobot: () -> Void
    public let onSave: () -> Void
    public let onUndo: () -> Void
    public let onRedo: () -> Void

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    public init(
        player: MotionPlayer,
        totalDurationMs: Double,
        stepCount: Int,
        hasBus: Bool,
        sendToHardware: Binding<Bool>,
        isDirty: Bool,
        executingOnRobot: Bool,
        canUndo: Bool,
        canRedo: Bool,
        onPlay: @escaping () -> Void,
        onAddStep: @escaping () -> Void,
        onCapture: @escaping () -> Void,
        onRunOnRobot: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void
    ) {
        self.player = player
        self.totalDurationMs = totalDurationMs
        self.stepCount = stepCount
        self.hasBus = hasBus
        self._sendToHardware = sendToHardware
        self.isDirty = isDirty
        self.executingOnRobot = executingOnRobot
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.onPlay = onPlay
        self.onAddStep = onAddStep
        self.onCapture = onCapture
        self.onRunOnRobot = onRunOnRobot
        self.onSave = onSave
        self.onUndo = onUndo
        self.onRedo = onRedo
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: DFSpace.md) {
            transportCluster
            Divider().frame(height: DFSize.iconLg)
            undoRedoCluster
            Divider().frame(height: DFSize.iconLg)
            loopSpeedCluster
            Divider().frame(height: DFSize.iconLg)
            timecode
            Spacer(minLength: DFSpace.md)
            actionCluster
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm2)
        .background(transportBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - 1. Transport cluster (5 buttons)

    private var transportCluster: some View {
        HStack(spacing: DFSpace.xs) {
            // ⏮ — 처음으로 (Home)
            transportButton(
                icon: "backward.end.fill",
                help: "처음으로 (Home)",
                action: {
                    harness.record(.uiButtonTapped, level: .trace, actor: .user,
                                         data: ["button": AnyCodable("transport_rewind_home")])
                    player.seekToStart()
                }
            )
            .keyboardShortcut(.home, modifiers: [])

            // ◀ — 한 스텝 전 (←)
            transportButton(
                icon: "backward.frame.fill",
                help: "이전 키프레임 (←)",
                action: {
                    harness.record(.uiButtonTapped, level: .trace, actor: .user,
                                         data: ["button": AnyCodable("transport_step_back")])
                    player.step(by: -1)
                }
            )
            .keyboardShortcut(.leftArrow, modifiers: [])

            // ⏯ — 큰 재생/일시정지 (Space)
            playPauseButton

            // ▶ — 한 스텝 후 (→)
            transportButton(
                icon: "forward.frame.fill",
                help: "다음 키프레임 (→)",
                action: {
                    harness.record(.uiButtonTapped, level: .trace, actor: .user,
                                         data: ["button": AnyCodable("transport_step_forward")])
                    player.step(by: 1)
                }
            )
            .keyboardShortcut(.rightArrow, modifiers: [])

            // ⏭ — 끝으로 (End)
            transportButton(
                icon: "forward.end.fill",
                help: "끝으로 (End)",
                action: {
                    harness.record(.uiButtonTapped, level: .trace, actor: .user,
                                         data: ["button": AnyCodable("transport_fast_forward_end")])
                    player.seekToEnd()
                }
            )
            .keyboardShortcut(.end, modifiers: [])

            // ⏹ — 정지 + 처음으로 (재생 + 시간 초기화)
            transportButton(
                icon: "stop.fill",
                help: "정지 (재생을 멈추고 처음으로)",
                action: {
                    harness.record(.motionPlayAbort, level: .info, actor: .user,
                                         data: ["source": AnyCodable("transport_stop")])
                    player.stop()
                }
            )
        }
    }

    /// 가장 큰 재생/일시정지 버튼 — forge orange tint, prominent 위계.
    private var playPauseButton: some View {
        let isPlaying = player.mode == .playing
        return Button {
            if isPlaying {
                // pause ≠ abort — 구분하여 uiButtonTapped 로 기록.
                harness.record(.uiButtonTapped, level: .info, actor: .user,
                                     data: ["button": AnyCodable("transport_pause")])
                player.pause()
            } else {
                harness.record(.motionPlayStart, level: .info, actor: .user)
                onPlay()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [DFColor.forge, DFColor.forge.opacity(DFOpacity.o85)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: DFSize.iconXl, height: DFSize.iconXl)
                    .shadow(color: DFColor.forge.opacity(DFOpacity.strong),
                            radius: DFSpace.xs, y: DFSpace.micro)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: DFFontSize.s14, weight: .bold))
                    .foregroundStyle(.white)
                    // play 아이콘은 시각적으로 우측으로 치우쳐 보임 — 1pt 보정.
                    .offset(x: isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(isPlaying ? "일시 정지 (Space)" : "재생 (Space)")
        .accessibilityLabel(isPlaying ? "일시 정지" : "재생")
    }

    private func transportButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s12, weight: .semibold))
                .foregroundStyle(DFColor.textPrimary)
                .frame(width: DFSize.iconMd2, height: DFSize.iconMd2)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                                lineWidth: DFSize.borderHairline)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - 1.5 Undo / Redo cluster

    /// Adobe / Apple 표준 위치 — Transport 다음, 편집 동작용.
    /// 단축키 ⌘Z / ⌘⇧Z 는 MotionStudioView 의 hidden Button 에서 등록.
    private var undoRedoCluster: some View {
        HStack(spacing: DFSpace.xs) {
            editButton(
                icon: "arrow.uturn.backward",
                help: "되돌리기 (⌘Z)",
                enabled: canUndo,
                action: {
                    harness.record(.uiButtonTapped, level: .info, actor: .user,
                                         data: ["button": AnyCodable("transport_undo")])
                    onUndo()
                }
            )
            editButton(
                icon: "arrow.uturn.forward",
                help: "다시 앞으로 (⌘⇧Z)",
                enabled: canRedo,
                action: {
                    harness.record(.uiButtonTapped, level: .info, actor: .user,
                                         data: ["button": AnyCodable("transport_redo")])
                    onRedo()
                }
            )
        }
    }

    /// 편집 도구용 작은 아이콘 버튼 — undo / redo / copy / paste / split 공통 스타일.
    private func editButton(
        icon: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s12, weight: .semibold))
                .foregroundStyle(enabled ? DFColor.textPrimary : DFColor.textSecondary.opacity(DFOpacity.disabled))
                .frame(width: DFSize.iconMd2, height: DFSize.iconMd2)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                                lineWidth: DFSize.borderHairline)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - 2. Loop + Speed

    private var loopSpeedCluster: some View {
        HStack(spacing: DFSpace.xs) {
            // Loop 토글
            Button {
                let newValue = !player.isLooping
                harness.record(.uiButtonTapped, level: .info, actor: .user,
                                     data: ["button": AnyCodable("transport_loop_toggle"),
                                            "enabled": AnyCodable(newValue)])
                player.isLooping.toggle()
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                    .foregroundStyle(player.isLooping ? DFColor.accent : DFColor.textSecondary)
                    .frame(width: DFSize.iconMd2, height: DFSize.iconMd2)
                    .background(player.isLooping ? DFColor.accent.opacity(DFOpacity.subtle) : DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.xs2)
                            .stroke(
                                (player.isLooping ? DFColor.accent : DFColor.textSecondary).opacity(DFOpacity.subtle),
                                lineWidth: DFSize.borderHairline
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(player.isLooping ? "반복 재생 ON" : "반복 재생 OFF")
            .accessibilityLabel(player.isLooping ? "반복 재생 끄기" : "반복 재생 켜기")

            // Speed selector — 0.5x / 1x / 2x cycle.
            Button {
                harness.record(.uiButtonTapped, level: .info, actor: .user,
                                     data: ["button": AnyCodable("transport_speed_cycle"),
                                            "current_rate": AnyCodable(player.playbackRate)])
                player.cyclePlaybackRate()
            } label: {
                Text(speedLabel)
                    .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(player.playbackRate == 1.0 ? DFColor.textSecondary : DFColor.accent)
                    .frame(minWidth: 40, minHeight: DFSize.iconMd2)
                    .padding(.horizontal, DFSpace.xs2)
                    .background(player.playbackRate == 1.0 ? DFColor.elev2 : DFColor.accent.opacity(DFOpacity.subtle))
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.xs2)
                            .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle),
                                    lineWidth: DFSize.borderHairline)
                    )
            }
            .buttonStyle(.plain)
            .help("재생 속도 (클릭으로 0.5× / 1× / 2× 순환)")
        }
    }

    private var speedLabel: String {
        switch player.playbackRate {
        case 0.5: return "0.5×"
        case 2.0: return "2×"
        default:  return "1×"
        }
    }

    // MARK: - 3. Timecode display (큰 monospace)

    private var timecode: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 시간 — 큰 mono (After Effects style).
            HStack(spacing: DFSpace.xs) {
                Text(formatTimecode(player.elapsedMs))
                    .font(.system(size: DFFontSize.s16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DFColor.textPrimary)
                    .monospacedDigit()
                Text("/")
                    .font(.system(size: DFFontSize.s12, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                Text(formatTimecode(totalDurationMs))
                    .font(.system(size: DFFontSize.s12, weight: .regular, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                    .monospacedDigit()
            }
            // Step counter — caption.
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
                Text("\(player.currentStepIndex + 1) / \(stepCount) 키프레임")
                    .font(.system(size: DFFontSize.s9, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    /// `MM:SS.dd` 포맷 — Premiere/FCP 표준 timecode (centiseconds).
    private func formatTimecode(_ ms: Double) -> String {
        let total = max(0, ms) / 1000.0
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        let centi = Int((total - Double(Int(total))) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centi)
    }

    // MARK: - 4. Action cluster (right side)

    private var actionCluster: some View {
        HStack(spacing: DFSpace.xs) {
            // 저장 — dirty 시 활성화. 모든 동작 변경 추적.
            saveButton

            // 자세 한 컷 추가 — 작은 secondary 버튼.
            iconActionButton(
                icon: "plus.rectangle.on.rectangle",
                help: "지금 자세를 키프레임으로 추가",
                tint: DFColor.accent,
                action: {
                    harness.record(.motionStepAdded, level: .info, actor: .user,
                                         data: ["source": AnyCodable("transport_add_step"),
                                                "step_index": AnyCodable(player.currentStepIndex)])
                    onAddStep()
                }
            )

            // 로봇 자세 가져오기.
            iconActionButton(
                icon: "scope",
                help: hasBus ? "실 로봇의 현재 자세 → 편집기" : "USB 연결 후 사용 가능",
                tint: DFColor.info,
                disabled: !hasBus,
                action: {
                    harness.record(.teachSnapshotCaptured, level: .info, actor: .user,
                                         data: ["source": AnyCodable("transport_capture_pose")])
                    onCapture()
                }
            )

            Divider().frame(height: DFSize.iconLg)

            // LIVE — 재생 중 실시간 자세 스트리밍 토글.
            recordToggle

            // ▶ 로봇에 실행 — 명시 실행 버튼. 처음부터 끝까지 한 번 + 송출 + 자동 종료.
            runOnRobotButton
        }
    }

    /// 저장 버튼 — dirty 표시 점 + 클릭 시 saveDocAs.
    private var saveButton: some View {
        Button {
            harness.record(.motionPageSaved, level: .info, actor: .user,
                                  data: ["was_dirty": AnyCodable(isDirty)])
            onSave()
        } label: {
            HStack(spacing: DFSpace.xs) {
                ZStack {
                    Image(systemName: "tray.and.arrow.up.fill")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                    if isDirty {
                        // 우측 상단 dirty dot.
                        Circle()
                            .fill(DFColor.warning)
                            .frame(width: DFSize.indicatorXs, height: DFSize.indicatorXs)
                            .offset(x: 7, y: -6)
                    }
                }
                Text(isDirty ? "변경 저장…" : "저장…")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
            }
            .foregroundStyle(isDirty ? DFColor.warning : DFColor.textSecondary)
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs2)
            .background(isDirty ? DFColor.warning.opacity(DFOpacity.subtle) : DFColor.elev2)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(
                        (isDirty ? DFColor.warning : DFColor.textSecondary).opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline
                    )
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: .command)
        .help(isDirty
              ? "변경 사항 있음 — .json 으로 다른 이름 저장 (⌘S)"
              : "현재 동작 doc 을 .json 으로 저장 (⌘S)")
    }

    /// "▶ 로봇에 실행" — 강조 버튼. 안전 확인 후 처음→끝 한 번 재생 + 송출.
    /// LIVE 토글 (스트리밍) 과 구분 — 이건 "지금 한 번" semantic 의 explicit 액션.
    private var runOnRobotButton: some View {
        Button {
            harness.record(.uiButtonTapped, level: .info, actor: .user,
                                  data: ["button": AnyCodable("transport_run_on_robot"),
                                         "step_count": AnyCodable(stepCount)])
            onRunOnRobot()
        } label: {
            HStack(spacing: DFSpace.xs) {
                if executingOnRobot {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("실행 중…")
                        .font(.system(size: DFFontSize.s11, weight: .bold))
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: DFFontSize.s11, weight: .bold))
                    Text("로봇에 실행")
                        .font(.system(size: DFFontSize.s11, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DFSpace.sm3)
            .padding(.vertical, DFSpace.xs2)
            .background(
                LinearGradient(
                    colors: hasBus && !executingOnRobot
                        ? [DFColor.forge, DFColor.forge.opacity(DFOpacity.o85)]
                        : [DFColor.textSecondary.opacity(DFOpacity.disabled),
                           DFColor.textSecondary.opacity(DFOpacity.o30)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(Capsule())
            .shadow(
                color: hasBus && !executingOnRobot
                    ? DFColor.forge.opacity(DFOpacity.strong)
                    : .clear,
                radius: DFSpace.xs, y: DFSpace.micro
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasBus || executingOnRobot)
        .help(hasBus
              ? (executingOnRobot
                  ? "재생 중 — 끝나면 자동 정지"
                  : "현재 동작을 처음부터 끝까지 1회 재생하면서 로봇에 송출")
              : "USB 연결 후 사용 가능")
    }

    /// Live to Robot — 빨간 record-style 토글 (After Effects 의 red record dot).
    private var recordToggle: some View {
        Button {
            let newValue = !sendToHardware
            harness.record(.uiButtonTapped, level: .info, actor: .user,
                                  data: ["button": AnyCodable("transport_live_toggle"),
                                         "enabled": AnyCodable(newValue)])
            sendToHardware.toggle()
        } label: {
            HStack(spacing: DFSpace.xs) {
                ZStack {
                    Circle()
                        .fill(sendToHardware ? DFColor.danger : DFColor.danger.opacity(DFOpacity.disabled))
                        .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)
                    // 활성 시 outer ring (record-on 강조).
                    if sendToHardware {
                        Circle()
                            .stroke(DFColor.danger.opacity(DFOpacity.strong), lineWidth: DFSpace.micro2)
                            .frame(width: DFSize.indicatorMd, height: DFSize.indicatorMd)
                    }
                }
                .frame(width: DFSize.indicatorMd, height: DFSize.indicatorMd)
                Text("LIVE")
                    .font(.system(size: DFFontSize.s10, weight: .bold, design: .monospaced))
                    .foregroundStyle(sendToHardware ? DFColor.danger : DFColor.textSecondary)
            }
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs2)
            .background(sendToHardware ? DFColor.danger.opacity(DFOpacity.subtle) : DFColor.elev2)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(
                        sendToHardware ? DFColor.danger.opacity(DFOpacity.strong) : DFColor.textSecondary.opacity(DFOpacity.subtle),
                        lineWidth: DFSize.borderHairline
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasBus)
        .help(hasBus
              ? (sendToHardware ? "로봇에 실시간 전송 ON — 재생 자세가 모터로 송출" : "Live to Robot OFF")
              : "USB 연결 후 사용 가능")
    }

    private func iconActionButton(
        icon: String,
        help: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s12, weight: .semibold))
                .foregroundStyle(disabled ? DFColor.textSecondary.opacity(DFOpacity.disabled) : tint)
                .frame(width: DFSize.iconMd2, height: DFSize.iconMd2)
                .background(disabled ? DFColor.elev2 : tint.opacity(DFOpacity.subtle))
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(
                            disabled ? DFColor.textSecondary.opacity(DFOpacity.subtle) : tint.opacity(DFOpacity.strong),
                            lineWidth: DFSize.borderHairline
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Background

    /// Subtle elevation — 영상 편집 도구 transport bar 의 어두운 톤.
    private var transportBackground: some View {
        LinearGradient(
            colors: [DFColor.elev2.opacity(DFOpacity.dim), DFColor.elev2.opacity(DFOpacity.disabled)],
            startPoint: .top, endPoint: .bottom
        )
    }
}
