# Wake Word Detection — "헤이 다윈"

## 한 줄 소개

특정 키워드만 듣고 활성화되는 패턴. Siri "헤이 시리", Alexa "Alexa".
양손 점유 + 자연스러운 시작 = 휴머노이드에 결정적.

## 도구

### 1. Picovoice Porcupine ★★

| 항목 | 내용 |
|------|------|
| 라이선스 | 무료 (개인) / 상용 ($) |
| 메모리 | ~50 KB |
| 지연 | <50ms |
| Apple Silicon | ✅ |
| 커스텀 wake word | 웹 콘솔에서 학습 — "Hey Darwin" / "다윈아" 등 |

장점: 가장 가볍고 빠름. 임베디드 친화.
단점: 상용 라이선스 필요 시 유료.

### 2. openWakeWord (커뮤니티)

| 항목 | 내용 |
|------|------|
| 라이선스 | Apache 2.0 (오픈) |
| 한국어 wake word | 직접 학습 필요 |
| 모델 | ONNX |

### 3. Rhasspy / Mycroft Precise

오픈소스 비서들의 wake word 모듈. macOS 빌드 노력 필요.

### 4. macOS "Hey Siri"는 우리가 못 씀

Apple만 사용 가능. 대신 macOS 14+ 단축키로 대체.

## DarwinForge 통합 — 권장 패턴

### 옵션 A — 단축키 1차 (가장 단순)

```swift
// AppDelegate에서 글로벌 단축키
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    if event.modifierFlags.contains(.command) && event.keyCode == 0x60 {  // F5
        ConversationViewModel.shared.startVoiceInput()
    }
}
```

장점: 가장 안정. 우연 trigger 없음.
단점: 양손 점유 시 발 또는 호흡으로 키보드 누르기 어려움.

### 옵션 B — Porcupine wake word

```sh
pod install Porcupine-iOS  # Cocoapods or SPM
```

```swift
import Porcupine

let porcupine = try Porcupine(
    accessKey: "AccessKey 발급",
    keywordPaths: ["resources/hey_darwin.ppn"]
)

audioEngine.installTap... { buf in
    if let idx = try? porcupine.process(audio: buf), idx == 0 {
        ConversationViewModel.shared.startVoiceInput()
    }
}
```

장점: 양손 자유, 자연스러움.
단점: AccessKey 필요, 우연 trigger 가능 (오인식).

### 옵션 C — 시스템 바이패스 (실험)

macOS Voice Control이 모든 자연어를 받음. 그 안에 "다윈아" → ⌘F5
매크로 매핑. 사용자 OS 설정 필요.

## DarwinForge 권장

✅ **단축키 (F5 또는 Fn+M)** + 옵션 B 사용자 토글.

## 출처

- Picovoice Porcupine: https://picovoice.ai/products/porcupine/
- openWakeWord: https://github.com/dscripka/openWakeWord
- Mycroft Precise: https://github.com/MycroftAI/mycroft-precise
- macOS Voice Control: https://support.apple.com/guide/mac-help/use-voice-control-mh40719/mac
