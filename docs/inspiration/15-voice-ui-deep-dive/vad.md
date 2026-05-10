# VAD — Voice Activity Detection

## 한 줄 소개

음성·무음 검출. 사용자가 말을 끝낸 시점 자동 검출 → STT 종료. UX의 핵심.

## 도구

### 1. Silero VAD ★★

| 항목 | 내용 |
|------|------|
| 라이선스 | MIT |
| 정확도 | ★★★ 최고 (다양한 환경) |
| 지연 | <30ms |
| 모델 크기 | ~2 MB |
| 형식 | ONNX, PyTorch, TFLite |
| Apple Silicon | ✅ ONNX runtime |

### 2. WebRTC VAD (Google)

| 항목 | 내용 |
|------|------|
| 라이선스 | BSD-3 |
| 정확도 | ★★ 양호 |
| C 라이브러리 | `libfvad` |

### 3. Apple SFSpeechRecognizer 자체

`SFSpeechRecognizer`가 자체 무음 검출. 별도 VAD 불필요. 정확도 양호.

## DarwinForge 통합

Apple Speech Framework 1차 옵션이라면 VAD 별도 구현 불필요. mlx-whisper
폴백 시:

```swift
// 신규 — 간단한 RMS 기반 VAD (Silero 미사용 시)
func isVoiceActive(_ buf: AVAudioPCMBuffer, threshold: Float = 0.01) -> Bool {
    return buf.rms > threshold
}

// silence 1.5초 누적 → STT 종료
var silenceStart: Date?
let silenceLimit: TimeInterval = 1.5

audioEngine.inputNode.installTap(...) { buf, _ in
    if isVoiceActive(buf) {
        silenceStart = nil
    } else {
        if silenceStart == nil { silenceStart = Date() }
        if let s = silenceStart, Date().timeIntervalSince(s) > silenceLimit {
            stopListening()
        }
    }
}
```

## 출처

- Silero VAD: https://github.com/snakers4/silero-vad
- WebRTC VAD: https://webrtc.googlesource.com/src/+/master/common_audio/vad/
- libfvad: https://github.com/dpirch/libfvad
