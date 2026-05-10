# Wispr Flow — 음성 → 텍스트

## 한 줄 소개

음성 받아쓰기 도구. 단축키 누르고 말하면 → 텍스트로 어디든 입력. macOS
네이티브, 한국어 지원 (확인 필요 — 영어 우선).

## DarwinForge 적용

★★★ — DarwinForge가 양손 점유 시나리오에서 가장 결정적인 입력 방식.

### 후보 구현

#### 옵션 A — macOS Speech Framework
```swift
import Speech

let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
let request = SFSpeechAudioBufferRecognitionRequest()
let task = recognizer?.recognitionTask(with: request) { result, _ in
    if let text = result?.bestTranscription.formattedString {
        vm.input = text
    }
}
```

장점: 네이티브, 무료, 오프라인 일부.
단점: 한국어 정확도가 영어보다 낮을 수 있음.

#### 옵션 B — mlx-whisper (Apple Silicon 가속)
Whisper-Large-V3 또는 Distil-Whisper를 MLX로 추론. 한국어 정확도 매우 높음.

장점: 정확도 ↑.
단점: ~1.5 GB 모델, 첫 추론 ~1초.

#### 옵션 C — Whisper.cpp + ggml
```sh
brew install whisper-cpp
whisper-cli -m models/ggml-large-v3.bin -l ko -t 8 input.wav
```

forge-cli에 통합. 장점: 가장 가벼움. 단점: 별도 바이너리 의존.

### UI

`InputBar`에 마이크 버튼 추가. 누르고 있으면 녹음 (push-to-talk), 또는
toggle. 녹음 중 파형 시각화 (Apple Voice Memos 패턴).

## 출처

- Wispr Flow: https://wisprflow.ai
- macOS Speech Framework: https://developer.apple.com/documentation/speech
- mlx-whisper: https://github.com/ml-explore/mlx-examples/tree/main/whisper
- Whisper.cpp: https://github.com/ggerganov/whisper.cpp
