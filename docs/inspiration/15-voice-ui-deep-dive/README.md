# 15. 음성 UI 깊이 분석

> DarwinForge 자연어 입력의 "음성 모드" 채택 시 결정적. 양손이 cradle을
> 잡고 있는 상황에서 음성 입력은 가장 자연스럽다.

## 인덱스

| 도구 / 표준 | 영역 | DarwinForge 가능성 |
|-------------|------|---------------------|
| [Apple Speech Framework](apple-speech.md) | macOS 네이티브 STT | ★★★ — 1순위 (오프라인 + 한국어) |
| [Whisper / mlx-whisper](whisper.md) | OpenAI STT 오픈소스 | ★★★ — Apple Silicon 가속 |
| [Wispr Flow](wispr-flow.md) | 받아쓰기 도구 | ★★ — UX 패턴 참고 |
| [ChatGPT Voice Mode](chatgpt-voice.md) | 음성 대화 UX | ★★ — 인터랙션 모델 |
| [Gemini Live API](gemini-live.md) | 음성 + 비디오 실시간 | ★★ |
| [Siri / Alexa / Google Assistant](classic-assistants.md) | 클래식 음성 비서 | ★ — 패턴 참조 |
| [Mycroft](mycroft.md) | 오픈소스 음성 비서 | ★ — 아키텍처 영감 |
| [VAD (Voice Activity Detection)](vad.md) | 음성 검출 | ★★ — 무음 자동 종료 |
| [Wake word detection](wake-words.md) | "헤이 다윈" 검출 | ★★ — 양손 점유 시 결정적 |
| [Web Audio / AVFoundation](web-audio-avfoundation.md) | 오디오 캡처 | ★★★ — 우리 인프라 |

## DarwinForge — 권장 음성 스택

### 핵심 결정 (확정 후보)

```
사용자가 "헤이 다윈" 또는 단축키 (예: F5) →
  ↓
[Wake word: Picovoice Porcupine 또는 직접 정의]
  ↓
AVFoundation으로 16 kHz 모노 오디오 캡처
  ↓
VAD (Silero VAD 또는 Apple SFSpeechRecognizer 자체)
  ↓
STT — 우선순위 옵션 3개:
  A. Apple Speech Framework (Locale "ko-KR") — 무료, 오프라인 일부, 빠름
  B. mlx-whisper Large-V3-Turbo — Apple Silicon, 한국어 매우 정확, 메모리 1.5GB
  C. Whisper.cpp — 가장 가볍지만 별도 binary
  ↓
텍스트 → ConversationViewModel.send(text:)
  ↓
(기존 흐름) Claude → tool_use → forge_core
  ↓
응답 텍스트 → TTS:
  D. AVSpeechSynthesizer (Locale "ko-KR") — 무료, 자연스러움 보통
  E. mlx-bark / coqui-ko-tts — 더 자연스러움 + 사용자 voice clone 가능
```

### A vs B 비교 (한국어 정확도 추정)

| 옵션 | 한국어 WER (추정) | 지연 | 메모리 | 오프라인 |
|------|-------------------|------|---------|----------|
| Apple Speech Framework | ~10% | <500ms | 작음 | 일부 (on-device 모델) |
| Whisper Large-V3-Turbo (mlx) | ~5% | ~1s | 1.5 GB | ✅ |
| Whisper.cpp + ggml-medium | ~7% | ~800ms | 800 MB | ✅ |

→ **권장**: 옵션 A 1차 (간편 + 빠름) + 옵션 B 폴백 (정확도 우선 모드).
사용자가 설정에서 선택.

## 음성 UX 핵심 패턴 (배운 것 종합)

### 1. 명확한 시작/종료 신호 (Skype 채팅 vs 무전기)
- 무전기 모드 (push-to-talk) — 단축키 누르고 있는 동안 녹음. 가장 신뢰도 높음.
- 토글 모드 (한 번 누르고 시작, 다시 눌러 종료) — 망설임에 약함.
- VAD 자동 (무음 1.5초로 종료) — 자연스러우나 환경 노이즈에 약함.

→ **권장**: 무전기 모드 1차 (F5 / Cmd+M) + VAD 보조.

### 2. 시각 피드백
- **음파 비주얼라이저** — 사용자가 "내 목소리가 들리고 있다" 인지
- **상태 라벨**: "듣는 중…" / "생각 중…" / "실행 중…"

```swift
struct WaveformView: View {
    let amplitudes: [Float]
    var body: some View {
        Canvas { ctx, size in
            for (i, amp) in amplitudes.enumerated() {
                let x = CGFloat(i) * (size.width / CGFloat(amplitudes.count))
                let h = CGFloat(amp) * size.height
                let bar = Path { p in
                    p.move(to: CGPoint(x: x, y: size.height/2 - h/2))
                    p.addLine(to: CGPoint(x: x, y: size.height/2 + h/2))
                }
                ctx.stroke(bar, with: .color(DFColor.accent), lineWidth: 2)
            }
        }
    }
}
```

### 3. 거부 / 명확한 실패 처리
- "음… 잘 못 들었어요. 다시 한 번 말씀해 주실래요?"
- "이 명령은 안전하지 않을 수 있어요. 정말 진행할까요?"

### 4. 중단 가능성
- 사용자가 말 도중 멈추면 → 부분 텍스트라도 input field에 표시
- 사용자가 보낸 후 결과 도착 전 ⌘. (취소) 가능

### 5. 다중 언어 자동 전환
- 사용자가 "Wave to me" 영어로 말하면 자동 인식 → "안녕"으로 답할지 영어로 답할지
- 권장: **Claude system prompt에 "사용자 언어 미러링"** 지시.

## 출처

각 문서별 참조.
