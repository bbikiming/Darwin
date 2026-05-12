# Apple Speech Framework — macOS 네이티브 STT

## 한 줄 소개

Apple의 공식 음성 인식. iOS 10+, macOS 10.15+. **한국어 지원**. 일부
on-device, 일부 클라우드 (Apple).

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | Apple SDK (iOS/macOS dev 무료) |
| 한국어 | ✅ `Locale("ko-KR")` |
| On-device | iOS 13+ / macOS 10.15+ 일부 모델, iPhone 15+ / Apple Silicon Mac에서 강화 |
| 권한 | `Privacy - Speech Recognition Usage Description` (Info.plist) |
| 입력 | live audio (`AVAudioEngine`) 또는 파일 |

## 코드 — DarwinForge 통합 후보

```swift
// Sources/DarwinForgeUI/Conversation/SpeechCapture.swift
import Speech
import AVFoundation

@MainActor
public final class SpeechCapture: ObservableObject {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))!
    private let audioEngine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    @Published public var transcript: String = ""
    @Published public var isListening: Bool = false
    @Published public var amplitude: Float = 0

    public func startListening() throws {
        SFSpeechRecognizer.requestAuthorization { _ in }
        // 입력 노드
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true   // on-device 우선

        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            req.append(buf)
            self?.amplitude = buf.rms
        }

        audioEngine.prepare()
        try audioEngine.start()

        self.request = req
        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                if let r = result {
                    self?.transcript = r.bestTranscription.formattedString
                }
            }
        }
        isListening = true
    }

    public func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        isListening = false
    }
}

private extension AVAudioPCMBuffer {
    var rms: Float {
        guard let ch = floatChannelData else { return 0 }
        let n = Int(frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[0][i] * ch[0][i] }
        return sqrt(sum / Float(n))
    }
}
```

## 한국어 정확도 (실험 추정)

- 조용한 환경 + 표준 한국어: WER ~10%
- 시끄러운 환경 + 사투리: WER ~20%

→ 정확도 부족 시 mlx-whisper 폴백 (`whisper.md` 참조).

## DarwinForge 채택

★★★ — 1순위 옵션. 무료 + 즉시 + on-device + 한국어 OK.

## 출처

- Apple Speech: https://developer.apple.com/documentation/speech
- 권한 가이드: https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
- Apple Developer Sample (Speech Recognizer): https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio
