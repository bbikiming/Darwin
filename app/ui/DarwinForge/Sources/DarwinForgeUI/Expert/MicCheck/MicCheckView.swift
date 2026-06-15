import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

/// 다윈 로봇 마이크 → 맥 음성 캡처 실험 패널 (전문가 콘솔).
///
/// 두 가지를 검증한다:
///   1. 로봇 마이크로 **소리가 잡히는가** (파형/레벨 + 재생)
///   2. 그 오디오가 **맥에 도달·이해되는가** (전송 바이트 + 음성→텍스트)
///
/// 모든 로봇 측 동작은 원격 명령 화면과 동일한 SSH 채널(`SSHShell`)로 실행된다.
public struct MicCheckView: View {

    @EnvironmentObject private var remoteShell: RemoteShell
    @StateObject private var store = MicCheckStore()
    @StateObject private var macStore = MacMicCheckStore()
    @State private var player: AudioPreviewPlayer = AudioPreviewPlayer()
    /// 로봇 마이크엔 입력이 없는 것이 확인돼 기본값은 맥 마이크.
    @State private var mode: Mode = .mac

    private enum Mode: String, CaseIterable, Identifiable {
        case mac, robot
        var id: String { rawValue }
        var label: String { self == .mac ? "맥 마이크" : "로봇 마이크" }
    }

    public init() {}

    public var body: some View {
        DFPageScaffold(
            "마이크 체크",
            subtitle: subtitleForMode,
            icon: "mic.fill",
            tint: DFColor.forge,
            trailing: { headerAction }
        ) {
            VStack(spacing: DFSpace.none) {
                modePicker
                Divider()
                switch mode {
                case .mac:   macContent
                case .robot: robotContent
                }
            }
        }
    }

    private var subtitleForMode: String {
        mode == .mac
            ? "맥 마이크로 음성을 받아 레벨·전사로 인식 여부를 확인"
            : "다윈 로봇 마이크로 캡처해 맥으로 가져오는 실험"
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(DFSpace.sm)
    }

    @ViewBuilder
    private var headerAction: some View {
        switch mode {
        case .robot: runButton
        case .mac:   macMicButton
        }
    }

    // MARK: - 맥 마이크 모드

    private var macMicButton: some View {
        DFButton(macStore.isRecording ? .danger : .forge, size: .small) {
            macStore.toggle()
        } label: {
            Label(macStore.isRecording ? "정지" : "말하기 시작",
                  systemImage: macStore.isRecording ? "stop.fill" : "mic.fill")
        }
    }

    private var macContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                macIntroCard
                macLevelCard
                macTranscriptCard
            }
            .padding(DFSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var macIntroCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Label("맥 마이크 모드", systemImage: "laptopcomputer")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.forge)
            Text("로봇에는 사용 가능한 마이크 입력이 없어 맥 마이크로 음성을 받습니다. ‘말하기 시작’을 누르고 말하면 레벨 막대가 움직이고(소리 인지) 아래에 전사가 실시간으로 표시됩니다(이해).")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
    }

    private var macLevelCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: macStore.isRecording ? "waveform" : "waveform.slash")
                    .foregroundStyle(macStore.isRecording ? DFColor.success : DFColor.textSecondary)
                Text(macStatusText)
                    .font(DFFont.caption)
                    .foregroundStyle(macStatusTint)
                Spacer()
            }
            levelBar(label: "현재", fraction: macStore.level, tint: DFColor.accent)
            levelBar(label: "피크", fraction: macStore.peakObserved, tint: DFColor.forge)
            if let err = macStore.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
            }
        }
        .padding(DFSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private var macTranscriptCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Text("이해 (음성 → 텍스트)")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.textPrimary)
            if macStore.hasTranscript {
                Text("“\(macStore.transcript)”")
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DFSpace.sm)
                    .background(DFColor.success.opacity(DFOpacity.o06))
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                    .textSelection(.enabled)
            } else {
                Text(macStore.isRecording ? "인식 대기 중…" : "아직 인식된 텍스트가 없습니다")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private var macStatusText: String {
        if macStore.errorMessage != nil { return "오류 — 아래 메시지 확인" }
        if macStore.isRecording { return "녹음 중 — 말해보세요" }
        if macStore.hasFinished {
            return macStore.signalDetected ? "소리 인지됨 ✓" : "소리가 거의 안 잡힘"
        }
        return "대기 — ‘말하기 시작’을 누르세요"
    }

    private var macStatusTint: Color {
        if macStore.errorMessage != nil { return DFColor.danger }
        if macStore.isRecording { return DFColor.success }
        if macStore.hasFinished {
            return macStore.signalDetected ? DFColor.success : DFColor.warning
        }
        return DFColor.textSecondary
    }

    // MARK: - 로봇 마이크 모드

    private var robotContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                introCard
                controlRow
                ForEach(store.outcomes) { outcome in
                    stageCard(outcome)
                }
            }
            .padding(DFSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { countdownOverlay }
    }

    // MARK: - 헤더 실행 버튼 (로봇)

    private var runButton: some View {
        DFButton(.forge, size: .small) {
            let runner = SSHRobotShellRunner(host: remoteShell.host, user: remoteShell.username)
            Task { await store.run(using: runner) }
        } label: {
            Label(store.isRunning ? "실행 중…" : "실험 시작",
                  systemImage: store.isRunning ? "hourglass" : "play.fill")
        }
        .disabled(store.isRunning)
    }

    // MARK: - 안내 카드

    private var introCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Label("실험용 기능 — 로봇 SSH 연결 필요", systemImage: "flask.fill")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.forge)
            Text("다윈 마이크 캡처 가능 여부는 공장 펌웨어에서 검증된 바 없습니다. 1단계에서 캡처 장치를 먼저 탐지하며, 장치가 없으면 그 사실도 정상 결과로 표시됩니다.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Text("대상: \(remoteShell.username)@\(remoteShell.host)")
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
    }

    // MARK: - 컨트롤 (녹음 길이)

    private var controlRow: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "timer").foregroundStyle(DFColor.textSecondary)
            Text("녹음 길이")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Slider(
                value: Binding(
                    get: { Double(store.durationSeconds) },
                    set: { store.durationSeconds = Int($0.rounded()) }
                ),
                in: 1...15, step: 1
            )
            .frame(maxWidth: 220)
            .disabled(store.isRunning)
            Text("\(store.durationSeconds)초")
                .font(.system(size: DFFontSize.s12, design: .monospaced))
                .foregroundStyle(DFColor.textPrimary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(DFSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - 단계 카드

    @ViewBuilder
    private func stageCard(_ o: StageOutcome) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs2) {
                stageStatusIcon(o.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.stage.title)
                        .font(.system(size: DFFontSize.s13, weight: .semibold))
                        .foregroundStyle(DFColor.textPrimary)
                    Text(o.stage.subtitle)
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                }
                Spacer()
            }

            if !o.summary.isEmpty {
                Text(o.summary)
                    .font(DFFont.caption)
                    .foregroundStyle(statusTint(o.status))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 분석 단계엔 레벨 바 + 재생 버튼.
            if o.stage == .analyze, let info = store.wavInfo {
                analyzeExtras(info)
            }
            // 이해 단계엔 전사 텍스트 강조.
            if o.stage == .transcribe, let text = store.transcript, !text.isEmpty {
                transcriptBubble(text)
            }

            if !o.detail.isEmpty {
                DisclosureGroup("원시 출력") {
                    Text(o.detail)
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DFSpace.xs2)
                        .background(DFColor.elev2)
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                        .textSelection(.enabled)
                }
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.sm2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(statusTint(o.status).opacity(DFOpacity.o25), lineWidth: 0.5)
        )
        .opacity(o.status == .skipped ? DFOpacity.dim : 1)
    }

    // MARK: - 분석 추가 UI (레벨 바 + 재생)

    @ViewBuilder
    private func analyzeExtras(_ info: WavAnalysis.WavInfo) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            levelBar(label: "피크", fraction: info.peakAmplitude, tint: DFColor.forge)
            levelBar(label: "RMS", fraction: info.rms, tint: DFColor.accent)
            HStack(spacing: DFSpace.sm) {
                Button {
                    if let url = store.localWavURL { player.play(url: url) }
                } label: {
                    Label("재생", systemImage: "play.circle.fill")
                        .font(DFFont.caption)
                }
                .buttonStyle(.borderless)
                .disabled(store.localWavURL == nil)

                Text(String(format: "%.1f초 · %dHz · %dch",
                            info.durationSeconds, info.sampleRate, info.channels))
                    .font(.system(size: DFFontSize.s9, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.top, DFSpace.xs2)
    }

    private func levelBar(label: String, fraction: Double, tint: Color) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Text(label)
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 32, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DFColor.elev2)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
            }
            .frame(height: 8)
        }
    }

    private func transcriptBubble(_ text: String) -> some View {
        Text("“\(text)”")
            .font(DFFont.bodyEmph)
            .foregroundStyle(DFColor.success)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DFSpace.sm)
            .background(DFColor.success.opacity(DFOpacity.o06))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .textSelection(.enabled)
    }

    // MARK: - 카운트다운 오버레이

    @ViewBuilder
    private var countdownOverlay: some View {
        if let n = store.countdown {
            ZStack {
                Color.black.opacity(DFOpacity.disabled)
                VStack(spacing: DFSpace.sm) {
                    Text("\(n)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(DFColor.forge)
                    Text("곧 녹음을 시작합니다 — 준비하세요")
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(.white)
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - 상태 아이콘 / 색

    @ViewBuilder
    private func stageStatusIcon(_ status: StageStatus) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        default:
            Image(systemName: statusIconName(status))
                .foregroundStyle(statusTint(status))
                .font(.system(size: DFFontSize.s14))
        }
    }

    private func statusIconName(_ status: StageStatus) -> String {
        switch status {
        case .pending:  return "circle"
        case .running:  return "arrow.triangle.2.circlepath"
        case .passed:   return "checkmark.circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .failed:   return "xmark.octagon.fill"
        case .skipped:  return "minus.circle"
        }
    }

    private func statusTint(_ status: StageStatus) -> Color {
        switch status {
        case .pending:  return DFColor.textSecondary
        case .running:  return DFColor.accent
        case .passed:   return DFColor.success
        case .warning:  return DFColor.warning
        case .failed:   return DFColor.danger
        case .skipped:  return DFColor.textSecondary.opacity(DFOpacity.dim)
        }
    }
}

// MARK: - 오디오 재생 헬퍼

/// 분석된 WAV 를 한 번에 한 개씩 재생하는 작은 래퍼.
final class AudioPreviewPlayer {
    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    #endif

    func play(url: URL) {
        #if canImport(AVFoundation)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        #endif
    }
}
