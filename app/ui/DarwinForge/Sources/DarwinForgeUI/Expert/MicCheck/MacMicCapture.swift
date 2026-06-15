import Foundation
#if canImport(Speech)
import Speech
import AVFoundation
#endif

/// 맥 로컬 마이크 캡처 추상화 — 레벨 미터 + 실시간 전사.
///
/// 로봇 마이크가 없을 때의 대안 경로. 라이브 입력 버퍼에서 두 가지를 동시에 뽑는다:
///   1. RMS/피크 레벨(소리가 잡히는지 시각화)
///   2. 음성→텍스트 전사(맥이 이해하는지)
///
/// `VoiceRecognizing`(VoicePilot)과 별도 — 그 기능을 건드리지 않도록 자체 AVAudioEngine 을 둔다.
/// `MacMicCheckStore` 단위 테스트를 위해 protocol 로 추상화하고 mock 을 주입한다.
@MainActor
public protocol MacMicCapturing: AnyObject {
    /// 버퍼별 (rms, peak) 0...1 콜백.
    func setOnLevel(_ handler: @escaping @MainActor (Double, Double) -> Void)
    /// 전사 텍스트(interim+final) 콜백.
    func setOnTranscript(_ handler: @escaping @MainActor (String) -> Void)
    /// 권한 거부 / 엔진 에러 콜백.
    func setOnError(_ handler: @escaping @MainActor (String) -> Void)
    /// 마이크+음성 권한 요청 후 캡처 시작. 실패 시 throw.
    func start() throws
    /// 캡처 중단. idempotent.
    func stop()
}

#if canImport(Speech)

/// 실 AVAudioEngine + SFSpeechRecognizer 기반 맥 마이크 캡처 — macOS 14+.
///
/// # 정책
/// - `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`(Info.plist) 필수.
/// - 권한 거부도 정상 흐름 — onError 로 메시지 발화.
/// - SwiftPM executable 은 sandbox 기본 비활성이라 마이크 entitlement 불요.
@MainActor
public final class AVMacMicCapture: MacMicCapturing {

    private let audioEngine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var onLevel: (@MainActor (Double, Double) -> Void)?
    private var onTranscript: (@MainActor (String) -> Void)?
    private var onError: (@MainActor (String) -> Void)?

    public init(locale: Locale = Locale(identifier: "ko-KR")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func setOnLevel(_ handler: @escaping @MainActor (Double, Double) -> Void) { onLevel = handler }
    public func setOnTranscript(_ handler: @escaping @MainActor (String) -> Void) { onTranscript = handler }
    public func setOnError(_ handler: @escaping @MainActor (String) -> Void) { onError = handler }

    public func start() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            let m = "음성 인식기를 현재 지역에서 사용할 수 없음"
            onError?(m)
            throw MacMicError.unavailable(m)
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self = self else { return }
                switch status {
                case .authorized:
                    do { try self.beginCapture() }
                    catch { self.onError?("마이크 시작 실패: \(error.localizedDescription)") }
                case .denied:        self.onError?("음성 인식 권한 거부됨 — 시스템 설정 > 개인정보 > 음성 인식")
                case .restricted:    self.onError?("음성 인식 제한됨")
                case .notDetermined: self.onError?("음성 인식 권한 미결정")
                @unknown default:    self.onError?("알 수 없는 권한 상태")
                }
            }
        }
    }

    public func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func beginCapture() throws {
        stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let (rms, peak) = Self.levels(from: buffer)
            request.append(buffer)
            Task { @MainActor [weak self] in self?.onLevel?(rms, peak) }
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor [weak self] in self?.onTranscript?(text) }
            }
            if let error = error {
                Task { @MainActor [weak self] in
                    self?.onError?("인식 에러: \(error.localizedDescription)")
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// PCM float 버퍼에서 (rms, peak) 0...1 계산.
    private static func levels(from buffer: AVAudioPCMBuffer) -> (Double, Double) {
        guard let channel = buffer.floatChannelData else { return (0, 0) }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return (0, 0) }
        let samples = channel[0]
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frames {
            let v = samples[i]
            sumSquares += v * v
            peak = Swift.max(peak, abs(v))
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        return (Double(min(rms, 1)), Double(min(peak, 1)))
    }
}

public enum MacMicError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let m): return m }
    }
}

#else

/// Speech/AVFoundation 미지원 플랫폼(예: Linux CI) — start 시 throw.
@MainActor
public final class AVMacMicCapture: MacMicCapturing {
    public init(locale: Locale = Locale(identifier: "ko-KR")) {}
    public func setOnLevel(_ handler: @escaping @MainActor (Double, Double) -> Void) {}
    public func setOnTranscript(_ handler: @escaping @MainActor (String) -> Void) {}
    public func setOnError(_ handler: @escaping @MainActor (String) -> Void) {}
    public func start() throws { throw MacMicError.unavailable("이 플랫폼은 마이크를 지원하지 않음") }
    public func stop() {}
}

public enum MacMicError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? {
        switch self { case .unavailable(let m): return m }
    }
}

#endif
