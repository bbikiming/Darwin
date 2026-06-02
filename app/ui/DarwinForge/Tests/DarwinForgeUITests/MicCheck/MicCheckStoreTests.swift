import XCTest
@testable import DarwinForgeUI

/// 마이크 체크 오케스트레이터(5단계)의 결정론 검증.
/// mock SSH 실행기 + mock 전사기로 성공/장치없음/arecord없음/전송손상/STT거부 경로를 덮는다.
@MainActor
final class MicCheckStoreTests: XCTestCase {

    // MARK: - Mocks

    private struct MockRunner: RobotShellRunning {
        let handler: (String) throws -> RobotShellOutput
        func run(_ command: String) async throws -> RobotShellOutput { try handler(command) }
    }

    private struct MockTranscriber: MicCheckTranscribing {
        let outcome: Result<TranscriptionResult, Error>
        func transcribe(fileURL: URL, locale: Locale) async throws -> TranscriptionResult {
            try outcome.get()
        }
    }

    // MARK: - 헬퍼

    private func ok(_ stdout: String, exit: Int32 = 0) -> RobotShellOutput {
        RobotShellOutput(stdout: stdout, stderr: "", exitCode: exit, elapsedMs: 5)
    }

    private func fail(_ stderr: String, exit: Int32 = 1) -> RobotShellOutput {
        RobotShellOutput(stdout: "", stderr: stderr, exitCode: exit, elapsedMs: 5)
    }

    private let deviceProbe = """
    == which ==
    /usr/bin/arecord
    == arecord-l ==
    card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
    == cards ==
     1 [Device]: USB-Audio - USB Audio Device
    """

    /// 풀스케일 톤 WAV → base64 (신호 있음).
    private func signalWavBase64() -> String {
        let samples = (0..<8000).map { $0 % 2 == 0 ? Int16(30000) : Int16(-30000) }
        return makeWav(samples: samples).base64EncodedString()
    }

    private func makeWav(sampleRate: Int = 16000, channels: Int = 1, samples: [Int16]) -> Data {
        let blockAlign = channels * 2
        let dataSize = samples.count * 2
        var d = Data()
        func a(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        a("RIFF"); u32(UInt32(36 + dataSize)); a("WAVE")
        a("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * blockAlign)); u16(UInt16(blockAlign)); u16(16)
        a("data"); u32(UInt32(dataSize))
        for s in samples { let r = UInt16(bitPattern: s); d.append(contentsOf: [UInt8(r & 0xFF), UInt8((r >> 8) & 0xFF)]) }
        return d
    }

    /// 디스크/시간 부수효과를 제거한 store.
    private func makeStore(transcriber: MicCheckTranscribing) -> MicCheckStore {
        MicCheckStore(
            transcriber: transcriber,
            durationSeconds: 4,
            fileWriter: { _ in URL(fileURLWithPath: "/tmp/df_mic_check_test.wav") },
            countdownTick: { }
        )
    }

    private func status(_ store: MicCheckStore, _ stage: MicCheckStage) -> StageStatus? {
        store.outcome(stage)?.status
    }

    // MARK: - 1. 성공 경로 (전 단계 통과)

    func testFullSuccessPath() async {
        let b64 = signalWavBase64()
        let runner = MockRunner { cmd in
            if cmd == RobotMicCommands.probe { return self.ok(self.deviceProbe) }
            if cmd.hasPrefix("arecord ") { return self.ok("") }
            if cmd == RobotMicCommands.fileSizeBytes { return self.ok("128044") }
            if cmd == RobotMicCommands.transferBase64 { return self.ok(b64) }
            if cmd == RobotMicCommands.cleanup { return self.ok("") }
            return self.ok("")
        }
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "안녕하세요 다윈", onDevice: true))))

        await store.run(using: runner)

        XCTAssertEqual(status(store, .probe), .passed)
        XCTAssertEqual(status(store, .record), .passed)
        XCTAssertEqual(status(store, .transfer), .passed)
        XCTAssertEqual(status(store, .analyze), .passed)
        XCTAssertEqual(status(store, .transcribe), .passed)
        XCTAssertEqual(store.transcript, "안녕하세요 다윈")
        XCTAssertEqual(store.wavInfo?.hasSignal, true)
        XCTAssertFalse(store.isRunning)
    }

    // MARK: - 2. arecord 있음 + 캡처 장치 없음 → 녹음 ALSA 에러

    func testNoCaptureDeviceRecordFails() async {
        let noDevProbe = """
        == which ==
        /usr/bin/arecord
        == arecord-l ==
        arecord: device_list:276: no soundcards found...
        """
        let runner = MockRunner { cmd in
            if cmd == RobotMicCommands.probe { return self.ok(noDevProbe) }
            if cmd.hasPrefix("arecord ") {
                return self.fail("arecord: main:828: audio open error: No such device")
            }
            return self.ok("")
        }
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "x", onDevice: true))))

        await store.run(using: runner)

        XCTAssertEqual(status(store, .probe), .warning) // arecord 있으나 장치 미발견
        XCTAssertEqual(status(store, .record), .failed)
        XCTAssertEqual(status(store, .transfer), .skipped)
        XCTAssertEqual(status(store, .analyze), .skipped)
        XCTAssertEqual(status(store, .transcribe), .skipped)
    }

    // MARK: - 3. arecord 미설치 → 즉시 중단

    func testArecordMissingStops() async {
        let runner = MockRunner { cmd in
            if cmd == RobotMicCommands.probe {
                return self.ok("== which ==\nNO_ARECORD\n== arecord-l ==\nsh: arecord: not found")
            }
            return self.ok("")
        }
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "x", onDevice: true))))

        await store.run(using: runner)

        XCTAssertEqual(status(store, .probe), .failed)
        XCTAssertEqual(status(store, .record), .skipped)
        XCTAssertEqual(status(store, .transfer), .skipped)
        XCTAssertEqual(status(store, .analyze), .skipped)
        XCTAssertEqual(status(store, .transcribe), .skipped)
        XCTAssertNil(store.wavInfo)
    }

    // MARK: - 4. 전송 base64 손상

    func testCorruptTransferFails() async {
        let runner = MockRunner { cmd in
            if cmd == RobotMicCommands.probe { return self.ok(self.deviceProbe) }
            if cmd.hasPrefix("arecord ") { return self.ok("") }
            if cmd == RobotMicCommands.fileSizeBytes { return self.ok("99999") }
            if cmd == RobotMicCommands.transferBase64 { return self.ok("***") } // 디코드 불가
            return self.ok("")
        }
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "x", onDevice: true))))

        await store.run(using: runner)

        XCTAssertEqual(status(store, .record), .passed)
        XCTAssertEqual(status(store, .transfer), .failed)
        XCTAssertEqual(status(store, .analyze), .skipped)
        XCTAssertEqual(status(store, .transcribe), .skipped)
    }

    // MARK: - 5. STT 권한 거부 → 전사만 실패

    func testTranscriptionDeniedOnlyTranscribeFails() async {
        let b64 = signalWavBase64()
        let runner = MockRunner { cmd in
            if cmd == RobotMicCommands.probe { return self.ok(self.deviceProbe) }
            if cmd.hasPrefix("arecord ") { return self.ok("") }
            if cmd == RobotMicCommands.fileSizeBytes { return self.ok("128044") }
            if cmd == RobotMicCommands.transferBase64 { return self.ok(b64) }
            if cmd == RobotMicCommands.cleanup { return self.ok("") }
            return self.ok("")
        }
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .failure(TranscriptionError.unauthorized("테스트"))))

        await store.run(using: runner)

        XCTAssertEqual(status(store, .probe), .passed)
        XCTAssertEqual(status(store, .record), .passed)
        XCTAssertEqual(status(store, .transfer), .passed)
        XCTAssertEqual(status(store, .analyze), .passed)
        XCTAssertEqual(status(store, .transcribe), .failed)
        XCTAssertNil(store.transcript)
    }

    // MARK: - 6. 무음 → analyze warning

    func testSilenceProducesAnalyzeWarning() async {
        let silentB64 = makeWav(samples: Array(repeating: 0, count: 8000)).base64EncodedString()
        let runner = MockRunner { cmd in
            if cmd == RobotMicCommands.probe { return self.ok(self.deviceProbe) }
            if cmd.hasPrefix("arecord ") { return self.ok("") }
            if cmd == RobotMicCommands.fileSizeBytes { return self.ok("16044") }
            if cmd == RobotMicCommands.transferBase64 { return self.ok(silentB64) }
            if cmd == RobotMicCommands.cleanup { return self.ok("") }
            return self.ok("")
        }
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "", onDevice: true))))

        await store.run(using: runner)

        XCTAssertEqual(status(store, .analyze), .warning)
        XCTAssertEqual(store.wavInfo?.hasSignal, false)
        // 빈 전사 → warning.
        XCTAssertEqual(status(store, .transcribe), .warning)
    }

    // MARK: - 7. 초기 상태 / 길이 clamp

    func testInitialStateAllPending() {
        let store = makeStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "", onDevice: true))))
        XCTAssertEqual(store.outcomes.count, 5)
        XCTAssertTrue(store.outcomes.allSatisfy { $0.status == .pending })
        XCTAssertEqual(store.durationSeconds, 4)
    }

    func testDurationClampedAtInit() {
        let store = MicCheckStore(transcriber: MockTranscriber(
            outcome: .success(TranscriptionResult(text: "", onDevice: true))),
            durationSeconds: 99)
        XCTAssertEqual(store.durationSeconds, 15)
    }
}
