import Foundation

/// 다윈 마이크 → 맥 음성 캡처 실험의 오케스트레이터.
///
/// # 비유
///
/// 항공기 사전점검(preflight) 체크리스트를 한 줄씩 짚어 내려가는 부조종사. 각 항목을
/// 실행하고 통과/실패를 표시하며, 한 항목이 막히면 그 아래는 "건너뜀"으로 둔다. 여기선
/// 5개 항목(탐색→녹음→전송→분석→이해)을 순서대로 실행한다.
///
/// # 의존성 주입
///
/// - `RobotShellRunning` — 로봇 SSH 실행기(`run(using:)` 인자로 매 실행 시 주입; host/user 가
///   바뀔 수 있어 호출 시점에 받는다).
/// - `MicCheckTranscribing` — 파일 음성 전사기(기본 `SpeechFileTranscriber`).
/// - `fileWriter` / `countdownTick` — 디스크/시간 부수효과를 추상화해 단위 테스트를 결정론화.
@MainActor
public final class MicCheckStore: ObservableObject {

    // MARK: - 관찰 가능 상태

    @Published public private(set) var outcomes: [StageOutcome]
    @Published public private(set) var isRunning: Bool = false
    /// 녹음 직전 준비 카운트다운(3,2,1). nil = 카운트다운 아님.
    @Published public private(set) var countdown: Int?
    @Published public private(set) var wavInfo: WavAnalysis.WavInfo?
    @Published public private(set) var transcript: String?
    /// 재생용 맥 측 WAV 파일. 분석 단계에서 채워짐.
    @Published public private(set) var localWavURL: URL?
    /// 사용자 조절 녹음 길이(초). 1~15.
    @Published public var durationSeconds: Int

    // MARK: - 주입 의존성

    private let transcriber: MicCheckTranscribing
    private let locale: Locale
    private let fileWriter: (Data) throws -> URL
    private let countdownTick: () async -> Void

    public init(
        transcriber: MicCheckTranscribing = SpeechFileTranscriber(),
        locale: Locale = Locale(identifier: "ko-KR"),
        durationSeconds: Int = 5,
        fileWriter: @escaping (Data) throws -> URL = MicCheckStore.defaultFileWriter,
        countdownTick: @escaping () async -> Void = MicCheckStore.defaultCountdownTick
    ) {
        self.transcriber = transcriber
        self.locale = locale
        self.durationSeconds = RobotMicCommands.clampDuration(durationSeconds)
        self.fileWriter = fileWriter
        self.countdownTick = countdownTick
        self.outcomes = MicCheckStage.allCases.map(StageOutcome.pending)
    }

    // MARK: - 진입점

    /// 5단계 실험을 순서대로 실행. 이미 실행 중이면 no-op.
    public func run(using runner: RobotShellRunning) async {
        guard !isRunning else { return }
        isRunning = true
        resetState()
        defer { isRunning = false; countdown = nil }

        guard let device = await runProbe(runner) else { return }

        guard await runRecord(runner, device: device.argument) else {
            skipFrom(.transfer); return
        }
        guard let wavData = await runTransfer(runner) else {
            skipFrom(.analyze); return
        }
        guard await runAnalyze(wavData) else {
            skip(.transcribe); return
        }
        await runTranscribe()

        // 로봇 임시 파일 정리 — best effort.
        _ = try? await runner.run(RobotMicCommands.cleanup)
    }

    // MARK: - Stage 1: 장치 탐색

    /// 반환: 녹음을 진행할 장치(있으면). `nil` = arecord 자체가 없어 중단.
    private func runProbe(_ runner: RobotShellRunning) async -> ProbeDecision? {
        mark(.probe, .running, "캡처 장치 탐색 중…")
        do {
            let out = try await runner.run(RobotMicCommands.probe)
            if RobotMicCommands.isArecordMissing(in: out.combined) {
                mark(.probe, .failed, "arecord 미설치 — 로봇에서 녹음 불가", out.combined)
                skipFrom(.record)
                return nil
            }
            let devices = RobotMicCommands.parseCaptureDevices(from: out.combined)
            if let first = devices.first {
                let names = devices.map(\.name).joined(separator: ", ")
                mark(.probe, .passed,
                     "캡처 장치 \(devices.count)개 발견: \(names)", out.combined)
                return ProbeDecision(argument: first.plughwArgument)
            }
            // arecord 는 있으나 캡처 장치 목록이 비었음 — default PCM 으로 시도(진실은 녹음이 판정).
            mark(.probe, .warning,
                 "캡처 장치 미발견 — ALSA 기본 장치로 시도", out.combined)
            return ProbeDecision(argument: nil)
        } catch {
            mark(.probe, .failed, "탐색 실패 — SSH 연결 확인", String(describing: error))
            skipFrom(.record)
            return nil
        }
    }

    private struct ProbeDecision { let argument: String? }

    // MARK: - Stage 2: 녹음

    private func runRecord(_ runner: RobotShellRunning, device: String?) async -> Bool {
        // 준비 카운트다운 — "지금 말하세요".
        for n in stride(from: 3, through: 1, by: -1) {
            countdown = n
            await countdownTick()
        }
        countdown = nil

        let duration = RobotMicCommands.clampDuration(durationSeconds)
        mark(.record, .running, "녹음 중 (\(duration)초) — 지금 말하세요")
        do {
            let cmd = RobotMicCommands.record(durationSeconds: duration, device: device)
            let out = try await runner.run(cmd)
            // arecord 실패 신호: non-zero exit 또는 ALSA 에러 키워드.
            if !out.ok || Self.containsAlsaError(out.combined) {
                mark(.record, .failed, "녹음 실패 — 마이크가 응답하지 않음", out.combined)
                return false
            }
            // 파일 크기 확인.
            let sizeOut = try await runner.run(RobotMicCommands.fileSizeBytes)
            let bytes = Int(sizeOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if bytes <= 44 {
                mark(.record, .failed, "녹음 파일이 비어 있음 (\(bytes) bytes)", out.combined)
                return false
            }
            mark(.record, .passed, "녹음 완료 (\(duration)초, \(formatBytes(bytes)))", cmd)
            return true
        } catch {
            mark(.record, .failed, "녹음 명령 오류", String(describing: error))
            return false
        }
    }

    // MARK: - Stage 3: 맥으로 전송

    private func runTransfer(_ runner: RobotShellRunning) async -> Data? {
        mark(.transfer, .running, "맥으로 전송 중…")
        do {
            let out = try await runner.run(RobotMicCommands.transferBase64)
            guard out.ok, !out.stdout.isEmpty,
                  let data = Data(base64Encoded: out.stdout, options: .ignoreUnknownCharacters),
                  !data.isEmpty else {
                mark(.transfer, .failed, "base64 디코드 실패 — 전송 손상", out.combined)
                return nil
            }
            mark(.transfer, .passed,
                 "전송 완료: \(formatBytes(data.count)) 맥 도달 (\(out.elapsedMs)ms)")
            return data
        } catch {
            mark(.transfer, .failed, "전송 오류", String(describing: error))
            return nil
        }
    }

    // MARK: - Stage 4: 분석 · 재생

    private func runAnalyze(_ data: Data) async -> Bool {
        mark(.analyze, .running, "파형 분석 중…")
        do {
            let info = try WavAnalysis.analyze(data)
            wavInfo = info
            localWavURL = try? fileWriter(data) // 재생/전사용. 실패해도 분석 자체는 유효.

            let level = String(format: "RMS %.0f dBFS, 피크 %.0f%%",
                               info.rmsDBFS, info.peakAmplitude * 100)
            let dur = String(format: "%.1f초", info.durationSeconds)
            if info.hasSignal {
                mark(.analyze, .passed, "소리 인지됨 — \(level), \(dur)")
            } else {
                mark(.analyze, .warning,
                     "신호 거의 없음 (무음/마이크 미동작 가능) — \(level)")
            }
            return true
        } catch {
            mark(.analyze, .failed, "WAV 분석 실패 — 손상된 오디오",
                 (error as? WavAnalysis.WavError).map { String(describing: $0) } ?? "\(error)")
            return false
        }
    }

    // MARK: - Stage 5: 이해 (전사)

    private func runTranscribe() async {
        guard let url = localWavURL else {
            mark(.transcribe, .skipped, "재생 파일이 없어 전사 생략")
            return
        }
        mark(.transcribe, .running, "음성 → 텍스트 인식 중…")
        do {
            let result = try await transcriber.transcribe(fileURL: url, locale: locale)
            transcript = result.text
            let onDeviceNote = result.onDevice ? "기기 내 인식" : "⚠︎ 서버 인식(인터넷 필요)"
            if result.hasText {
                mark(.transcribe, .passed, "이해됨: “\(result.text)”", onDeviceNote)
            } else {
                mark(.transcribe, .warning,
                     "전사 결과 없음 (무음/미인식 가능)", onDeviceNote)
            }
        } catch {
            let message = (error as? TranscriptionError)?.errorDescription ?? "\(error)"
            mark(.transcribe, .failed, message)
        }
    }

    // MARK: - 상태 변경 헬퍼 (불변 — 요소 교체)

    private func resetState() {
        outcomes = MicCheckStage.allCases.map(StageOutcome.pending)
        wavInfo = nil
        transcript = nil
        localWavURL = nil
        countdown = nil
    }

    private func mark(_ stage: MicCheckStage, _ status: StageStatus,
                      _ summary: String, _ detail: String = "") {
        guard let idx = outcomes.firstIndex(where: { $0.stage == stage }) else { return }
        var updated = outcomes
        updated[idx] = StageOutcome(stage: stage, status: status,
                                    summary: summary, detail: detail)
        outcomes = updated
    }

    private func skip(_ stage: MicCheckStage) {
        mark(stage, .skipped, "앞 단계 실패로 건너뜀")
    }

    /// `stage` 부터 끝까지 전부 skipped 표시.
    private func skipFrom(_ stage: MicCheckStage) {
        guard let start = MicCheckStage.allCases.firstIndex(of: stage) else { return }
        for s in MicCheckStage.allCases[start...] where outcome(s)?.status == .pending {
            skip(s)
        }
    }

    public func outcome(_ stage: MicCheckStage) -> StageOutcome? {
        outcomes.first { $0.stage == stage }
    }

    // MARK: - 포맷 / 판정 헬퍼

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    private static func containsAlsaError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["cannot open", "no such", "no soundcards", "device or resource busy",
                "audio open error", "invalid argument"].contains { lowered.contains($0) }
    }

    // MARK: - 기본 부수효과 구현

    /// 디코드된 WAV 를 맥 임시 디렉터리에 저장하고 URL 반환.
    ///
    /// **nonisolated**: `MicCheckStore` 가 `@MainActor` 라 static 메서드도 기본
    /// main-actor 격리된다. 그러면 동기 클로저 기본인자(`init` 의 `fileWriter` 기본값)
    /// 평가가 nonisolated 컨텍스트에서 일어나 격리 위반 컴파일 에러가 난다. 본 메서드는
    /// 디스크 임시파일 쓰기만 하고 actor 상태를 만지지 않으므로 nonisolated 가 안전.
    public nonisolated static func defaultFileWriter(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("df_mic_check_\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    /// 카운트다운 1틱 = 0.7초 대기.
    public static func defaultCountdownTick() async {
        try? await Task.sleep(nanoseconds: 700_000_000)
    }
}
