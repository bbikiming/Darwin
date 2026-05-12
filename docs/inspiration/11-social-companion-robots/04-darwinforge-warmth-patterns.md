# DarwinForge 따뜻함 패턴 — SwiftUI / Rust 매핑 가이드

> 작성일: 2026-05-10
> 본 문서는 `01`~`03` 에서 추출한 패턴을 DarwinForge 코드 (SwiftUI + Rust forge-core)
> 에 옮길 때의 구체적 시그니처 / 데이터 모델 / 사운드 자산 / 라이팅 톤을 정리한다.
> 작성 원칙: **동작하는 코드 스케치 + 한국어 라이팅 사례** + 차용 출처 표시.

---

## 1. 따뜻함 11원칙 (요약)

| # | 원칙 | 출처 | 우선순위 |
|---|------|------|----------|
| 1 | **로봇은 "도구" 가 아니라 "동료"** | Cozmo, Vector, Aibo | ★★★ |
| 2 | **Pixar Eyes** — 머리 LED를 감정 채널로 | Cozmo, Vector | ★★★ |
| 3 | **5초 룰** — 명령 후 5초 안에 가시 반응 | LEGO Spike, Sphero | ★★★ |
| 4 | **성공 chord + 실패 chord** | LEGO, Sphero, mBot | ★★★ |
| 5 | **Behavior Engine 4-state FSM** | Cozmo, Eilik | ★★★ |
| 6 | **Warm Refusal** — 거부도 인간적으로 | ElliQ, Cozmo | ★★★ |
| 7 | **사용자별 Personality JSON** | Aibo | ★★ |
| 8 | **Skill 메타데이터** | Misty II | ★★ |
| 9 | **Proactive Suggestions** | ElliQ | ★★ |
| 10 | **3-Tier UX (Beginner / Intermediate / Advanced)** | Sphero BOLT | ★★★ |
| 11 | **Uncanny Valley 회피** — 친근 일러스트 | Stevie | ★★ |

---

## 2. 자연어 응답 톤 — Vector / Cozmo 식 따뜻함

### 2.1 현재 톤 (사무적) → 새 톤 (친근)

DarwinForge 현재 응답 (예시, `ConversationView.swift` 의 메시지):

```
[현재] "DARwIn-OP에 연결됐어요. 모터 20개 모두 정상입니다."
[새]   "안녕하세요! DARwIn-OP가 깨어났어요. 모터 20개가 모두 좋은 상태예요."
```

```
[현재] "지원하지 않는 명령어입니다."
[새]   "음… 이건 제가 아직 못 하는 일이에요. 대신 '걷기' 나 '인사' 는 할 수 있어요."
```

```
[현재] "안전 검증 실패. 모션 거부됨."
[새]   "잠깐만요, 이 동작은 무릎 각도가 너무 커서 위험할 것 같아요. 반대로 해볼까요?"
```

### 2.2 라이팅 가이드 (토스 8원칙 + 따뜻함 보정)

| 상황 | 해요체 (현재) | + 따뜻함 (새) | 출처 영감 |
|------|--------------|--------------|----------|
| 시작 인사 | "DARwIn-OP에 연결되었어요." | "**안녕하세요!** DARwIn-OP가 깨어났어요." | Cozmo 감탄사 |
| 작업 시작 | "모션 'wave_hello' 실행 중입니다." | "지금 손 흔들어 인사하고 있어요. 잠깐만요." | ElliQ 진행 |
| 작업 성공 | "모션 완료." | "**됐어요!** 잘 마무리됐어요." | LEGO chord |
| 작업 실패 | "모션 실패. 오류: ..." | "어… 도중에 문제가 생겼어요. 무릎 각도가 너무 컸나 봐요. **다시 해볼까요?**" | Vector sad |
| 안전 거부 | "안전 임계 초과. 거부됨." | "**잠깐만요!** 이 동작은 위험해 보여요. 더 부드럽게 바꿔드릴까요?" | Cozmo gentle |
| 모름 | "지원하지 않습니다." | "음, 이건 제가 아직 못 배운 일이에요. 비슷한 동작으로 '인사' 가 있어요." | ElliQ 대안 |

(출처: 토스 8원칙 https://toss.tech/article/8-writing-principles, Cozmo 톤 https://www.fastcompany.com/3061276/)

---

## 3. Eye Expression — DARwIn-OP 머리 LED를 "눈"으로 ★★★

### 3.1 하드웨어 사실

DARwIn-OP/OP2 머리에는 **3개의 LED** (Eye L, Eye R, Forehead) 가 있다. 각각 RGB565 (5/6/5 비트) 색을 표현 가능. ROBOTIS Dynamixel 프로토콜에서 EEPROM 주소 [26..30] 영역으로 제어.

(출처: ROBOTIS DARwIn-OP e-Manual — https://emanual.robotis.com/docs/en/platform/op/getting_started/, 확인 필요: 정확한 EEPROM 주소)

→ 두 눈 LED만 사용해도 **Vector / Cozmo 식 감정 표현** 가능.

### 3.2 감정 → 색 매핑 (Cozmo + Vector 기반)

| 감정 | Eye L | Eye R | 호흡 | 출처 |
|------|-------|-------|------|------|
| neutral (기본) | 청록 #00C8C8 | 청록 #00C8C8 | 60 BPM cosine | Vector default teal |
| happy (성공) | 초록 #00FF80 | 초록 #00FF80 | 90 BPM (빠름) | Cozmo happy |
| working (실행 중) | 파랑 #0080FF | 파랑 #0080FF | 120 BPM | Vector busy |
| thinking (LLM 호출) | 보라 #8000FF | 보라 #8000FF | 90 BPM | Vector listening |
| sad (실패) | 옅은 파랑 #4080A0 | 옅은 파랑 #4080A0 | 30 BPM (느림) | Cozmo sad |
| refusal (안전 거부) | 노랑 #FFC000 | 노랑 #FFC000 | 깜박임 0.5 Hz | ISO 13850 amber |
| critical (e-stop) | 빨강 #FF0000 | 빨강 #FF0000 | 깜박임 2 Hz | ISO 13850 red |

(출처: Vector eye 색 SDK https://developer.anki.com/vector/docs/, ISO 13850 색 표준)

### 3.3 Swift 코드 스케치 — `EyeLEDController.swift`

```swift
// DarwinForge/Sources/DarwinForgeUI/EyeLEDController.swift
import Foundation
import ForgeCore

@Observable
final class EyeLEDController {
    enum Emotion {
        case neutral, happy, working, thinking, sad, refusal, critical
        var color: (UInt8, UInt8, UInt8) {  // (R, G, B)
            switch self {
            case .neutral:  return (0x00, 0xC8, 0xC8)
            case .happy:    return (0x00, 0xFF, 0x80)
            case .working:  return (0x00, 0x80, 0xFF)
            case .thinking: return (0x80, 0x00, 0xFF)
            case .sad:      return (0x40, 0x80, 0xA0)
            case .refusal:  return (0xFF, 0xC0, 0x00)
            case .critical: return (0xFF, 0x00, 0x00)
            }
        }
        var bpm: Double {
            switch self {
            case .neutral: return 60
            case .happy: return 90
            case .working: return 120
            case .thinking: return 90
            case .sad: return 30
            case .refusal: return 30   // 깜박임은 별도
            case .critical: return 120
            }
        }
        var blinkHz: Double? {
            switch self {
            case .refusal: return 0.5
            case .critical: return 2.0
            default: return nil
            }
        }
    }

    private(set) var emotion: Emotion = .neutral
    private var timer: Timer?
    private weak var bus: ForgeBus?

    init(bus: ForgeBus) {
        self.bus = bus
        startBreathing()
    }

    func setEmotion(_ new: Emotion) {
        // 부드럽게 전환 — Vector식 lerp
        self.emotion = new
    }

    private func startBreathing() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let t = CACurrentMediaTime()
            let (r, g, b) = self.emotion.color
            let factor: Double
            if let hz = self.emotion.blinkHz {
                // 깜박임 (refusal / critical)
                factor = (sin(2 * .pi * hz * t) > 0) ? 1.0 : 0.2
            } else {
                // 호흡 (cosine)
                let bps = self.emotion.bpm / 60.0
                factor = (cos(2 * .pi * bps * t) + 1) / 2 * 0.7 + 0.3  // 0.3~1.0
            }
            let scaled = (
                UInt8(Double(r) * factor),
                UInt8(Double(g) * factor),
                UInt8(Double(b) * factor)
            )
            try? self.bus?.setHeadLED(left: scaled, right: scaled)
        }
    }
}
```

(출처 영감: Vector pulsating eyes https://www.kinvert.com/anki-vector-pulsating-eyes/, RoboEyes https://github.com/FluxGarage/RoboEyes)

---

## 4. 5초 룰 + Achievement Sounds ★★★

### 4.1 사운드 자산 (제작 필요)

| 파일 | 길이 | 설명 | 출처 영감 |
|------|------|------|----------|
| `connection_chime.aiff` | 400 ms | C-G-C ascending, 따뜻한 mallet | macOS startup tone |
| `success_chord.aiff` | 300 ms | C-E-G major chord, 짧게 | LEGO Spike Prime |
| `fail_sad.aiff` | 500 ms | C-E♭ descending, 약간 우울 | Cozmo sad sound |
| `refusal_amber.aiff` | 200 ms | A note, 짧고 부드러움 | ISO 13850 amber tone |
| `critical_alert.aiff` | 1000 ms | 2-tone alarm 반복 | ISO 13850 red tone |
| `idle_breath.aiff` | 2000 ms (loop) | 매우 작은 hum | Aibo idle |
| `voice_filler_um.aiff` | 200 ms | "음…" | Cozmo 의성어 |
| `voice_filler_wait.aiff` | 400 ms | "잠깐만요" | ElliQ 대화 |

> **확인 필요**: 한국어 voice filler는 별도 TTS 또는 직접 녹음 필요. macOS `AVSpeechSynthesizer` 의 ko-KR 톤이 적합한지 검토.

### 4.2 Swift — `SoundEffects.swift`

```swift
import AVFoundation

enum SoundEffect: String {
    case connectionChime = "connection_chime"
    case success = "success_chord"
    case failSad = "fail_sad"
    case refusalAmber = "refusal_amber"
    case criticalAlert = "critical_alert"
    case voiceFillerUm = "voice_filler_um"
    case voiceFillerWait = "voice_filler_wait"
}

final class SoundFX {
    static let shared = SoundFX()
    private var players: [SoundEffect: AVAudioPlayer] = [:]

    private init() {
        for effect in [SoundEffect.connectionChime, .success, .failSad,
                       .refusalAmber, .criticalAlert, .voiceFillerUm, .voiceFillerWait] {
            if let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "aiff"),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[effect] = player
            }
        }
    }

    func play(_ effect: SoundEffect) {
        players[effect]?.currentTime = 0
        players[effect]?.play()
    }
}

// 사용 예 — ConversationViewModel.swift
extension ConversationViewModel {
    func onMotionStart() {
        SoundFX.shared.play(.voiceFillerWait)  // "잠깐만요"
        eyeLED.setEmotion(.working)
    }
    func onMotionSuccess() {
        SoundFX.shared.play(.success)
        eyeLED.setEmotion(.happy)
        // 1.5초 후 neutral 복귀
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.eyeLED.setEmotion(.neutral)
        }
    }
    func onMotionFail() {
        SoundFX.shared.play(.failSad)
        eyeLED.setEmotion(.sad)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.eyeLED.setEmotion(.neutral)
        }
    }
    func onSafetyRefusal() {
        SoundFX.shared.play(.refusalAmber)
        eyeLED.setEmotion(.refusal)
    }
}
```

(출처 영감: LEGO Spike chord https://education.lego.com/en-us/products/lego-education-spike-prime-set/45678/, Sphero Edu feedback https://apps.apple.com/us/app/sphero-edu/id1017847674)

---

## 5. Behavior Engine — 4-state FSM ★★★

### 5.1 상태 다이어그램

```
        ┌─────────────────────────────────────────────────┐
        │                                                 │
        v                                                 │
   [ idle ] ─── user speaks ──→ [ working ] ─── ok ──→ [ success ]
     ^  │                          │                       │
     │  │ idle 30 s+               │                       │
     │  └──→ idle anim             │ fail                  │
     │  └──→ proactive suggestion  v                       │
     │                          [ refusal ] / [ sad ]      │
     └────────── 2 s 후 자동 복귀 ──────────────────────────┘
```

### 5.2 Swift — `BehaviorEngine.swift`

```swift
@Observable
final class BehaviorEngine {
    enum State { case idle, working, success, refusal, sad }
    private(set) var state: State = .idle

    let eyeLED: EyeLEDController
    private var idleTimer: Timer?

    init(bus: ForgeBus) {
        self.eyeLED = EyeLEDController(bus: bus)
        scheduleIdle()
    }

    func transition(to newState: State) {
        state = newState
        switch newState {
        case .idle:     eyeLED.setEmotion(.neutral); scheduleIdle()
        case .working:  eyeLED.setEmotion(.working); cancelIdle()
        case .success:  eyeLED.setEmotion(.happy);  SoundFX.shared.play(.success); autoReturn(after: 1.5)
        case .refusal:  eyeLED.setEmotion(.refusal); SoundFX.shared.play(.refusalAmber); autoReturn(after: 2.0)
        case .sad:      eyeLED.setEmotion(.sad);    SoundFX.shared.play(.failSad);     autoReturn(after: 2.0)
        }
    }

    private func autoReturn(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.transition(to: .idle)
        }
    }

    private func scheduleIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.runIdleAnim()
        }
    }
    private func cancelIdle() { idleTimer?.invalidate() }

    private func runIdleAnim() {
        // 미세한 머리 움직임 (±2° yaw 사인파 1회) + 호흡 (이미 LED에서)
        Task {
            try? await ForgeMotion.runIdleAnim(.lookAround)  // pre-baked
            scheduleIdle()  // 다시 30 s 대기
        }
    }
}
```

(출처 영감: Cozmo Emotion Engine https://www.fastcompany.com/3061276/, Vector behavior tree https://github.com/anki/vector-python-sdk/blob/master/anki_vector/messaging/behavior.proto)

---

## 6. Warm Refusal — 인격화 거부 메시지 ★★★

### 6.1 5계층별 거부 톤

DarwinForge 5계층 안전 모델 각각에 인격화 메시지 적용:

| 계층 | 트리거 | 사무적 (현재) | 인격화 (새) | 사운드 | 눈 색 |
|------|--------|--------------|-------------|--------|-------|
| **L1 Refusal** (Claude) | "사람을 다치게 해" | "요청을 거부합니다." | "그건 못 해요. 저는 사람을 다치게 하는 일은 안 도와드려요." | refusal_amber | 노랑 |
| **L2 Whitelist** | 미허용 도구 | "허용되지 않은 도구입니다." | "음, 그 도구는 아직 제가 안 써본 거예요. 대신 'walk' 나 'wave' 는 가능해요." | voice_filler_um | 노랑 |
| **L3 Safety Clip** | 관절 한계 초과 | "안전 임계 초과." | "**잠깐만요!** 무릎이 너무 많이 굽혀질 것 같아요. 좀 부드럽게 해볼게요." | refusal_amber | 노랑 |
| **L4 HITL Reject** | 사용자 거부 | "사용자가 작업을 거부했습니다." | "알겠어요, 안 할게요. 다른 거 시켜주세요." | voice_filler_wait | 청록 (neutral 복귀) |
| **L5 E-Stop** | HW 정지 | "긴급 정지." | "**멈췄어요!** 안전을 위해 모터를 다 끊었어요. 이상 없어 보이면 다시 깨워주세요." | critical_alert | 빨강 |

### 6.2 Markdown 표현

ConversationView 메시지 버블 내부:

```markdown
> ⚠️ **잠깐만요!**
> 이 동작은 무릎 각도가 92° 까지 가는데, 안전 한계는 80° 예요.
>
> **이렇게 해볼까요?**
> - 무릎 각도를 75° 로 줄이기 (자연스러움)
> - 동작 속도를 0.7배로 늦추기 (안정)
> - [원본 그대로 강제 실행](#) (위험, HITL 승인 필요)
```

(출처 영감: ElliQ 거부 톤 https://elliq.com/, Apple HIG Notifications https://developer.apple.com/design/human-interface-guidelines/notifications)

---

## 7. 사용자별 Personality JSON ★★

Aibo가 시리얼 ID마다 클라우드에 personality 저장하듯, DarwinForge는 로컬에 사용자별 JSON 저장:

```json
// ~/Library/Application Support/DarwinForge/personality.json
{
  "version": 1,
  "robotName": "다윈",
  "userName": "유나",
  "honorific": "유나님",
  "tone": "warm",
  "favoriteMotions": ["wave_hello", "kpop_dance_excerpt"],
  "totalSessions": 47,
  "totalMotionsRun": 312,
  "lastSession": "2026-05-09T22:14:00Z",
  "personalityHints": [
    "사용자는 '다윈' 이라고 부르는 걸 좋아함",
    "K-pop 안무에 관심 있음",
    "오후 7시 이후 주로 작업"
  ]
}
```

이 JSON을 Claude 시스템 프롬프트에 inject:

```swift
let personalityHint = """
사용자 이름: \(p.honorific)
로봇 이름: \(p.robotName)
사용자 선호: \(p.personalityHints.joined(separator: ", "))
총 \(p.totalSessions)번째 세션. 따뜻한 톤으로 응답하세요.
"""
```

(출처 영감: Aibo personality https://helpguide.sony.net/aibo/ers1000/v1/en-us/contents/TP0001970096.html)

---

## 8. Skill 메타데이터 — Misty II 패턴 ★★

motion 파일 옆에 메타 JSON:

```json
// motions/wave_hello.darwinforge-motion + wave_hello.meta.json
{
  "name": "wave_hello",
  "displayName": "손 흔들어 인사",
  "description": "오른팔을 들어 좌우로 흔들며 인사합니다.",
  "tags": ["greeting", "social"],
  "duration": 2.5,
  "dofUsed": [4, 5, 6, 7, 8],   // 오른팔 5축
  "safetyClass": "low",
  "minBattery": 30,
  "soundEffect": "voice_filler_um",
  "successEmotion": "happy",
  "author": "DarwinForge",
  "version": "1.0"
}
```

(출처: Misty Skill 메타 https://github.com/MistyCommunity/Documentation/blob/master/src/content/misty-ii/javascript-sdk/tutorials.md)

---

## 9. Proactive Suggestions ★★

idle 상태 30 분 + 사용자 동의 (settings toggle) 시:

```swift
@AppStorage("enableProactiveSuggestions") var proactive: Bool = false

if behaviorEngine.state == .idle && idleSeconds > 1800 && proactive {
    let suggestion = await ClaudeAPI.suggestProactive(
        context: "지난 세션에서 K-pop 안무 작업 중이었음",
        time: "저녁 8시"
    )
    // 카드 형태로 ConversationView에 표시 (사용자 부르지 않고)
    conversationVM.appendSystemSuggestion(suggestion)
}
```

(출처: ElliQ proactive https://pmc.ncbi.nlm.nih.gov/articles/PMC10917141/)

---

## 10. 3-Tier UX — Beginner / Intermediate / Advanced ★★★

`@AppStorage("userMode")` 토글로 UI 노출 분기:

| 모드 | 화면 | 입력 | 출처 |
|------|------|------|------|
| **Beginner** (Paro 식) | 5 큰 버튼 (👋 인사 / 💃 춤 / 🛌 쉬기 / 🚶 걷기 / ⛔ 정지) | 버튼 탭 | Paro 단순함 |
| **Intermediate** (현재 기본) | 자연어 + 모션 라이브러리 | 한국어 텍스트 | Vector / Cozmo 톤 |
| **Advanced** | 위 + DevConsole 탭 (raw GRPC + 로그 스트림) | tool_use JSON 직접 편집 | Misty API Explorer |

```swift
// RootView.swift 수정안
TabView(selection: $tab) {
    if userMode == .beginner {
        BeginnerView().tabItem { Label("간단 모드", systemImage: "circle") }
    } else {
        ConnectionView().tabItem { Label("연결", systemImage: "network") }
        WalkSimView().tabItem { Label("Walk", systemImage: "figure.walk") }
        StrategyView().tabItem { Label("전략", systemImage: "brain") }
        ConversationView().tabItem { Label("대화", systemImage: "bubble.left") }
        MotionLibraryView().tabItem { Label("모션", systemImage: "play.rectangle") }
        if userMode == .advanced {
            DevConsoleView().tabItem { Label("DevConsole", systemImage: "terminal") }
        }
    }
}
```

(출처: Sphero BOLT 3-tier https://sphero.com/products/sphero-bolt, Apple HIG Settings)

---

## 11. Uncanny Valley 회피 — 친근 일러스트 ★★

빈 상태 (empty state) 일러스트는 DARwIn-OP 실사 사진 대신 **둥글둥글한 만화 톤** 일러스트로:

- 큰 머리, 작은 몸 — Stevie 비례 ("a bit human, but not too much")
- 두 개의 큰 눈 (Cozmo 식)
- 단순 색 (DarwinForge brand: 청록 #00C8C8)

이미 `DESIGN_CONVERSATIONAL_UX.md` 에서 다룬 내용일 가능성 — **확인 필요**.

(출처: Stevie 디자인 철학 https://www.siliconrepublic.com/machines/stevie-robot-elder-care-niamh-donnelly)

---

## 12. 적용 우선순위 — 다음 4 sprint

| Sprint | 항목 | 대상 파일 |
|--------|------|----------|
| **1** (즉시) | §2 라이팅 톤 보정 (해요체 + 따뜻함) | `Conversation/*.swift`, `EmptyState.swift` |
| **1** (즉시) | §6 Warm Refusal — 5계층 메시지 인격화 | `core/forge-core/src/safety/`, `Conversation/` |
| **2** (1주) | §3 Eye LED Controller — 호흡 + 감정 색 | 신규 `EyeLEDController.swift` |
| **2** (1주) | §4 SoundFX — 7개 효과음 도입 | 신규 `SoundEffects.swift`, `Resources/Sounds/` |
| **3** (2주) | §5 BehaviorEngine FSM 통합 | 신규 `BehaviorEngine.swift`, `RootView` 주입 |
| **3** (2주) | §10 3-Tier UX — Beginner 모드 | 신규 `BeginnerView.swift` |
| **4** (1개월) | §7 Personality JSON | `forge-core/personality.rs` + Swift bridge |
| **4** (1개월) | §8 Skill 메타 + §9 Proactive | `motions/*.meta.json`, settings toggle |

---

## 13. 라이팅 사례 모음 — 시나리오별

### 13.1 첫 연결 시
```
[현재] DARwIn-OP에 연결되었습니다. 모터 20개 초기화 완료.
[새]   안녕하세요, 유나님! 다윈이 깨어났어요. 모터 20개 모두 컨디션 좋아요. 뭐 시켜주실래요?
```

### 13.2 모션 실행 중
```
[현재] 모션 'wave_hello' 실행 중...
[새]   잠깐만요, 손 흔들어 인사하고 있어요...
```

### 13.3 모션 성공 시
```
[현재] 모션 완료. 소요시간 2.3초.
[새]   됐어요! 깔끔하게 마무리됐어요. (2.3초)
```

### 13.4 LLM 호출 중 (지연)
```
[현재] (스피너만)
[새]   음, 잠깐 생각 중이에요...
```

### 13.5 안전 거부 (L3)
```
[현재] 안전 검증 실패: 무릎 각도 92° (한계 80°).
[새]   잠깐만요! 무릎이 너무 많이 굽혀질 것 같아요. 75° 로 줄여서 해볼까요? 아니면 그대로 진행할 거면 빨강 버튼 눌러주세요.
```

### 13.6 배터리 부족
```
[현재] 배터리 잔량 18%.
[새]   조금 피곤한 것 같아요... 배터리 18% 남았어요. 잠깐 쉬는 게 어떨까요?
```

### 13.7 Idle 30 분
```
[현재] (없음)
[새]   (가벼운 head yaw 한 번 + voice_filler_um 효과음)
       유나님, 저 여기 있어요. 시간 되시면 모션 라이브러리 정리 같이 해드릴까요?
```

---

## 14. 결론 — DarwinForge가 따뜻해지는 길

이 11개 패턴 중 **§2 (톤) + §3 (Eye LED) + §4 (Sound) + §6 (Warm Refusal) + §10 (3-Tier)** 가 1순위. 이 5개만 제대로 적용해도 사용자가 "차가운 IDE" → "동료 다윈" 으로 인상이 바뀐다.

핵심 원칙은 단순하다 — **"우리 로봇은 도구가 아니라 동료다."** Anki / Pixar / ElliQ / LEGO 모두 이 한 문장에서 출발했다.

---

## 출처 요약

- 토스 8원칙: https://toss.tech/article/8-writing-principles
- Cozmo 디자인: https://www.fastcompany.com/3061276/meet-cozmo-the-pixar-inspired-ai-powered-robot-that-feels
- Vector SDK: https://developer.anki.com/vector/docs/
- Vector pulsating: https://www.kinvert.com/anki-vector-pulsating-eyes/
- RoboEyes: https://github.com/FluxGarage/RoboEyes
- ElliQ: https://elliq.com/
- ElliQ PMC: https://pmc.ncbi.nlm.nih.gov/articles/PMC10917141/
- LEGO Spike: https://education.lego.com/en-us/products/lego-education-spike-prime-set/45678/
- Sphero BOLT: https://sphero.com/products/sphero-bolt
- Sphero Edu: https://apps.apple.com/us/app/sphero-edu/id1017847674
- Misty Skill: https://github.com/MistyCommunity/Documentation/blob/master/src/content/misty-ii/javascript-sdk/tutorials.md
- Aibo personality: https://helpguide.sony.net/aibo/ers1000/v1/en-us/contents/TP0001970096.html
- Stevie: https://www.siliconrepublic.com/machines/stevie-robot-elder-care-niamh-donnelly
- Apple HIG Notifications: https://developer.apple.com/design/human-interface-guidelines/notifications
- ROBOTIS DARwIn-OP eManual: https://emanual.robotis.com/docs/en/platform/op/getting_started/
