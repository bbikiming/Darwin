# DarwinForge — 대화형 로봇 조종 UX 재설계 명세

> **문서 종류**: 통합 디자인 문서 (Integrated Design Document)
> **작성일**: 2026-05-10
> **상태**: 사용자 승인 대기 → 구현 진입 예정
> **선행 조사**: 7개 영역 / 약 200+ 출처 / 인용 가능한 1차 자료 기반
> **변경 범위**: SwiftUI UI 전면 재설계 + Claude CLI 통합 신규 + 한국어 UX 라이팅 적용. **Rust 코어(forge-core / forge-ffi) 변경 없음**.

---

## 0. 한 페이지 요약 (TL;DR)

| 항목 | 결정 |
|---|---|
| **이전 UI 문제** | 5탭 전문가 콘솔(Connection/Board/Joint/Motion/Walk/Strategy). USB 포트 / 16진 ID / raw position 등 비전문가 진입 불가. |
| **새 1차 인터페이스** | **대화형(Conversation) 단일 화면** — 사용자가 한국어 자연어로 지시 → Claude(Haiku)가 의도 분류 → Swift dispatch가 안전 클리핑 → forge FFI 실행 → 한국어 결과 응답. |
| **2차 인터페이스** | 기존 5탭은 "전문가 모드"로 보존. ⌘⇧E 단축키로 토글. |
| **Claude 통합** | `claude --bare --print --output-format json --no-session-persistence --max-budget-usd 0.10 --model haiku` subprocess. system prompt에 9개 도구의 한국어 설명 + 안전 규칙 + JSON 응답 강제. |
| **안전 5계층** | (L1) Constitutional refusal → (L2) Whitelist (Swift dispatch만 9개 도구 인식) → (L3) Dry-run 시뮬레이션 → (L4) 사용자 "실행" 탭 (HITL) → (L5) E-Stop ESC 단축키 + 좌상단 항상 가시. ISO 13850 Cat-1 controlled stop 채택. |
| **디자인 언어** | **macOS 14+ 호환 (Material.regular/.thin)** + 향후 Liquid Glass 마이그레이션 마커. 12 컬러 토큰 / 7 타이포 스케일 / 12 컴포넌트. |
| **한국어 UX** | 토스 8원칙 + 해요체 + 능동형. "토크 ON" → "관절 깨우기". "Goal Position 2048" → "정면을 보고 있어요". 메시지 50종 한글화 표 적용. |
| **구현 단계** | Phase 1 (이번 세션): 골격 — 대화창 + e-stop + 1~3개 도구 매핑. Phase 2: 9개 전체 + dry-run. Phase 3: 시뮬레이터 통합. Phase 4: 음성 입력 + Liquid Glass. |
| **빌드 환경** | Swift 6.0.3 / Xcode 16 / macOS 14 SDK. Liquid Glass(Xcode 26+) 미적용, Material 폴백. |

---

## 1. 문제 진술

### 1.1 현재 UI의 한계 (관찰)

기존 [`RootView.swift`](app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift)는 5탭 NavigationSplitView 구조:

| 탭 | 노출되는 비전문가 진입 장벽 |
|---|---|
| Connection | `/dev/cu.usbserial-A1B2C3` 직렬 포트 경로 직접 선택 |
| Board Status | `model_number=730`, `voltage_raw=121`, `error_byte=0x00` |
| Joint Control | "Goal Position 0..4095", 16개 raw 슬라이더 |
| Motion Library | `.mtn` / `.json` 파일 경로 직접 import |
| Walk Sim | `x_amplitude=0.04 m/cycle` |
| Strategy FSM | `StrategyState.ApproachingBall` |

→ 로봇 학과 출신·MX-28 데이터시트 숙련자만 사용 가능. 사용자 요청: "그냥 사용자가 '이렇게 해줘' 하면 ... 자연어로".

### 1.2 두 가지 문제를 동시에 풀어야 함

1. **자연어 → 로봇 명령 변환** — Claude를 인터프리터로 두되, 환각/오인식이 모터 직결되지 않아야 함.
2. **한국어 UX** — 비전문가가 보는 모든 메시지가 자연스러운 한국어로 풀려야 함.

### 1.3 사용자 명시 요구

> "클로드 cli와 연동해서 그냥 사용자가 이렇게 해줘 하면 구조화된 로봇 전용 하네스 엔지니어링을 기반으로 조종, 모션을 생성해서 로봇에 적용해줄 수 있는 시스템"
> "근거 기반으로 명확하게 많이 조사해서 적용"
> "모든 언어는 한글로 이해하기 쉬운 ux라이팅을 적용"
> "GUI도 최상위 퀄리티로 업그레이드 해 최소 100번 이상 조사하고 검증해"

→ 본 문서가 만족시켜야 할 4개 축: **자연어 인터페이스 / 안전성 / 한국어 UX / GUI 퀄리티**.

---

## 2. 7개 조사 통합 인사이트

### 2.1 ROBOTIS / RoboCup 워크플로 (조사 A)

| 검증된 사실 | 출처 | 본 프로젝트 매핑 |
|---|---|---|
| RoboPlus 1.0은 Windows 전용·레거시. 신규 권장 = **DYNAMIXEL Wizard 2.0** + R+ Motion 2.0 + DynamixelSDK Python | [emanual all-software](https://github.com/ROBOTIS-GIT/emanual/blob/master/docs/en/software/all-software.md) | DarwinForge가 정확히 이 자리의 **macOS 네이티브 대안** |
| RoboCup 표준 5단계 워크플로: 영점 캘리브레이션 → 키프레임 → 시뮬 검증 → walk 합성 → 점진 배포 | [Bit-Bots motion](https://github.com/bit-bots/bitbots_motion) / [B-Human Walking](https://docs.b-human.de/coderelease2024/motion/motion-walking/) | 5단계를 한국어 명령 시퀀스로 표현 |
| 키프레임 / 보행 / 전략 **3-레이어 분리** | [B-Human Motion](https://wiki.b-human.de/coderelease2021/motion-documentation/) | forge-core가 이미 motion / walk / strategy 모듈 분리 — 정합 |
| Spot Choreographer = 트랙 타임라인 + BPM 동기 + Maya import | [Spot SDK Choreography](https://dev.bostondynamics.com/docs/concepts/choreography/readme) | Phase 4에서 차용 (현재 범위 외) |
| e-stop은 **즉시 전원 차단 X**. **Cat-1 controlled stop** — fall-safe 자세로 감속 후 STO | [ISO 13850](https://www.iso.org/standard/59970.html) / [GT-Engineering EN ISO 13850 §4.4](https://www.gt-engineering.it/en/technical-standards/en-iso-standards/emergency-sto-en-13850/4-4-emergency-stop-device/) | DarwinForge e-stop = `fc_emergency_stop` (모든 토크 OFF SYNC_WRITE) — DARwIn-OP는 정적 안정성 있어 즉시 토크 OFF 가능 |

### 2.2 LLM-to-robot 검증 아키텍처 (조사 B)

| 시스템 | 핵심 패턴 | DarwinForge 적용 |
|---|---|---|
| **SayCan** ([arXiv 2204.01691](https://arxiv.org/abs/2204.01691)) | LLM이 스킬 점수화(`Say`) × affordance 점수(`Can`), 곱이 최대인 스킬 선택 | "공 차줘" → strategy.kick 활성화 |
| **Code as Policies** ([arXiv 2209.07753](https://arxiv.org/abs/2209.07753)) | LLM이 Python 코드 생성, 사전 정의된 로봇 API 호출 | Phase 4 후속 (현재 범위 외) |
| **Figure Helix / NVIDIA GR00T N1** ([arXiv 2503.14734](https://arxiv.org/abs/2503.14734)) | **System 1 / System 2 분리** — 느린 추론(Claude) ↔ 빠른 실행(forge-core) | 본 시스템이 정확히 이 패턴 |
| **5계층 안전망** ([VerifyLLM](https://arxiv.org/html/2507.05118), [Plug in the Safety Chip](https://arxiv.org/abs/2309.09919), ISO 13849) | L1 Refusal → L2 Whitelist → L3 sim → L4 HITL → L5 hardware e-stop | §6 안전 모델 |
| **Anthropic strict tool use** ([platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use)) | 토큰 단계에서 JSON 스키마 grammar로 강제 | Claude CLI에선 system prompt + JSON 모드로 등가 효과 |
| **권장 = 옵션 B** | Haiku 4.5 + strict tool_use + Swift dispatch (안전 클리핑) + dry-run + HITL | **본 프로젝트 채택** |

### 2.3 한국어 UX 라이팅 (조사 C)

| 원칙 | 출처 | 적용 예 |
|---|---|---|
| 토스 8가지 라이팅 원칙 — predictable hint, weed cutting, easy-to-speak, suggest over force | [toss.tech/article/8-writing-principles-of-toss](https://toss.tech/article/8-writing-principles-of-toss) | "토크 켜기" → "로봇 깨우기 (관절에 힘이 들어가요)" |
| 앱인토스 — **해요체** + 능동형 + "닫기"(취소 X) | [developers-apps-in-toss.toss.im/design/ux-writing.html](https://developers-apps-in-toss.toss.im/design/ux-writing.html) | "확인하시겠어요?" → "확인할까요?" |
| 토스 에러 메시지 시스템 — 왜·무엇·할 일 3단 구조 | [toss.tech/article/introducing-toss-error-message-system](https://toss.tech/article/introducing-toss-error-message-system) | 에러 헤드라인 + 본문 + (상세보기) + 액션 |
| KS 안전 표지 (산업안전보건법 시행규칙 별표 7) | [KOSHA](https://www.kosha.or.kr/) | 빨강=금지·위험, 노랑=주의, 초록=안전, 파랑=정보 |
| ROBOTIS e-Manual 한국어 표기 | [emanual.robotis.com/docs/kr](https://emanual.robotis.com/docs/kr/) | "Servo" → "관절 모터", "Compliance" → "관절 부드럽기" |

### 2.4 macOS 26 Liquid Glass + SwiftUI 6 (조사 D)

| 결정 | 근거 |
|---|---|
| Liquid Glass는 **navigation layer 전용** (toolbar/sidebar/floating accessory). 본문·표·차트 금지 | [LiquidGlassReference](https://github.com/conorluddy/LiquidGlassReference), [NN/g 비판](https://www.nngroup.com/articles/liquid-glass/) |
| 두 개 이상 glass → `GlassEffectContainer` | [Apple HIG GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) |
| `.tint()`는 의미만. 장식 금지 | LiquidGlassReference DON'T |
| **빌드 환경 제약** — Xcode 16 / Swift 6.0.3 / macOS 14 SDK. Liquid Glass API 미사용 → `Material.regularMaterial` 폴백 | 본 빌드 호스트 확인 |
| 벤치마크 5패턴 차용: ⌘K 명령 팔레트(Linear/Raycast) / `?` 단축키 시트 / Type-to-search modeless / Sidebar = nav single source / Bottom accessory floating | 조사 D §3 |

### 2.5 휴머노이드 GUI 표준 (조사 E)

| 시스템 | 차용 패턴 |
|---|---|
| **NAO Choregraphe** ([doc.aldebaran.com](http://doc.aldebaran.com/2-4/software/choregraphe/)) | Box library + Flow diagram + Robot 3D View 3-pane. 키프레임 master/slave |
| **Boston Dynamics Spot Choreographer** ([dev.bostondynamics.com](https://dev.bostondynamics.com/docs/concepts/choreography/choreographer.html)) | Track 타임라인 + BPM 동기 + Animation editor |
| **1X NEO** ([humanoidsdaily.com](https://www.humanoidsdaily.com/feed/1x-ceo-details-neo-s-two-modes-and-defends-teleoperation-as-more-secure-than-a-cleaner)) | **Autonomous + Expert** 두 모드. Expert는 텔레오퍼레이터 fallback |
| **Apptronik Apollo** ([apptronik.com](https://apptronik.com/apollo)) | "Point-and-click" 라이브러리에서 태스크 선택 → fleet 할당 |
| **Foxglove** ([foxglove.dev/product](https://foxglove.dev/product)) | URDF + JointState 직접 구동 — forward kinematics 자체 계산 |
| **시뮬레이터 4분할 황금 비율** | Webots/Gazebo/Isaac Sim 공통: Scene Tree 좌측 / 3D View 중앙 / Property 우측 / Console 하단 |
| **e-stop 스펙** | ISO 13850 — 빨강 actuator + 노란 배경, 머쉬룸 헤드 ≥40mm, 0.6~1.7m 손 닿는 위치, **즉시 실행 — 확인 다이얼로그 ❌** |

### 2.6 AI 채팅 UI 베스트 (조사 F)

| 패턴 | 출처 | 적용 |
|---|---|---|
| Claude.ai 메시지 — 사용자만 버블, 어시스턴트는 평문 흐름 | [IntuitionLabs comparison](https://intuitionlabs.ai/articles/conversational-ai-ui-comparison-2025) | 본 프로젝트 동일 |
| `@Observable` + Observation framework로 streaming token reactive | [DEV SwiftUI streaming guide](https://dev.to/programmingcentral/building-a-real-time-ai-chat-ui-with-swiftui-the-ultimate-guide-to-streaming-tokens-and-observable-244) | ChatViewModel에 적용 |
| Tool 호출 카드 = intent + args + dry-run + 4-scope approve (Once/Session/Workspace/Always) | [VSCode Copilot agent-tools](https://code.visualstudio.com/docs/copilot/agents/agent-tools) | ToolCallCard 컴포넌트 |
| LangGraph HITL 4-way: approve/edit/reject/respond | [docs.langchain.com](https://docs.langchain.com/oss/python/langchain/human-in-the-loop) | HITL 게이트 |
| Wispr Flow 음성 — silence 시 waveform이 flat | [docs.wisprflow.ai](https://docs.wisprflow.ai/articles/4351452717-troubleshooting-mic-issues) | Phase 4 후속 |
| 단축키 12개 표준 | [BoltAI ChatGPT shortcuts](https://docs.boltai.com/blog/chatgpt-keyboard-shortcuts-for-mac) / [ClaudeLog Tab thinking](https://claudelog.com/faqs/how-to-toggle-thinking-in-claude-code/) | §10 |

### 2.7 3D + 접근성 (조사 G)

| 결정 | 근거 |
|---|---|
| 3D 렌더러 = SceneKit + `SceneView` (1차) | [SCNView Apple Docs](https://developer.apple.com/documentation/scenekit/scnview), 즉시 카메라 컨트롤. Phase 1에서는 placeholder 마커 또는 후속 |
| Swift Charts **small multiples 4×4 sparkline** (CDC 가이드 — 5+ 시리즈 분리) | [CDC Small Multiples](https://www.cdc.gov/cove/data-visualization-types/small-multiples.html), [Swift Charts](https://developer.apple.com/documentation/Charts) |
| 접근성 4종 환경 변수 | `accessibilityReduceMotion` / `accessibilityReduceTransparency` / `accessibilityDifferentiateWithoutColor` / `accessibilityIncreaseContrast` |
| 광민감성 — WCAG 2.3.1 초당 3회 이상 깜빡임 금지 | [WCAG 2.3.1](https://www.w3.org/WAI/WCAG21/Understanding/three-flashes-or-below-threshold.html) |
| 색약 — 색+패턴+아이콘 3중 인코딩 | [David Nichols](https://davidmathlogic.com/colorblind/) |
| String Catalog `.xcstrings` (Xcode 15+) — ko/en 동시 | [WWDC23 String Catalogs](https://developer.apple.com/videos/play/wwdc2023/10155/) |
| STT — WhisperKit 1차 + SpeechAnalyzer 폴백, **버튼 트리거 권장** | [WhisperKit](https://github.com/argmaxinc/WhisperKit), [WWDC25 SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/) |

---

## 3. 시스템 아키텍처

### 3.1 데이터 흐름 (사용자 → Claude → Dispatch → FFI → 로봇 → 사용자)

```
┌────────────────────────────────────────────────────────────────┐
│ SwiftUI ConversationView                                       │
│   사용자 입력: "지금 일어서줘"                                  │
└─────────────────┬──────────────────────────────────────────────┘
                  │
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ ClaudeCommander (actor)                                        │
│   spawn: claude --bare --print --output-format json            │
│          --no-session-persistence --max-budget-usd 0.10        │
│          --model haiku                                         │
│          --system-prompt <SYSTEM_PROMPT>                       │
│   stdin:  사용자 입력 (UTF-8 한국어)                            │
│   stdout: {"type":"result","result":"{\"tool\":\"motion_play\",│
│            \"args\":{\"page_id\":1},                           │
│            \"speak\":\"로봇을 일으킬게요. 약 3초 걸려요.\",    │
│            \"needs_confirmation\":true}"}                      │
└─────────────────┬──────────────────────────────────────────────┘
                  │
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ IntentDispatcher (actor) — L2 Whitelist + L3 Safety Clip       │
│   1. tool 이름이 9개 화이트리스트에 있는가?                     │
│   2. args가 도메인 범위에 들어가는가?                           │
│      walk x ∈ [-0.04, 0.04], joint position ∈ [1024, 3072] 등  │
│   3. needs_confirmation이면 → HITL 카드로 사용자에게 노출       │
│   4. dry_run=true이면 → 시뮬만, 모터 명령 X                     │
└─────────────────┬──────────────────────────────────────────────┘
                  │ 사용자 "실행" 탭 (HITL L4)
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ ForgeCore (Swift wrapper) → forge-ffi (C) → forge-core (Rust)  │
│   fc_motion_mtn_to_json / fc_joint_set_position /              │
│   fc_walk_set_command / fc_emergency_stop / ...                │
└─────────────────┬──────────────────────────────────────────────┘
                  │
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ USB → CM-730/740 → Dynamixel TTL Bus → 16× MX-28T              │
└────────────────────────────────────────────────────────────────┘

(역방향: 로봇 응답 → forge-ffi → IntentDispatcher → ConversationView 한국어 응답)

L5 Hardware E-Stop 우회 경로:
ConversationView E-Stop 버튼 (좌상단 항상 가시, ESC 단축키)
    └─ 즉시 fc_emergency_stop (LLM 경로 우회)
```

### 3.2 5계층 안전 모델

| Layer | 위치 | 메커니즘 |
|---|---|---|
| **L1 Refusal** | Claude (system prompt) | "위험 명령(자살/자기충돌/낙상)은 거부하고 `tool: "refuse"` 반환" |
| **L2 Whitelist** | Swift `IntentDispatcher` | 9개 도구 enum 스위치. 미지정 도구 → ForgeError.unknownTool |
| **L3 Safety Clip / Dry-run** | Swift `SafetyGate` | walk x/y/a 범위 클립, joint position [1024, 3072] 클립, motion 미존재 페이지 거부, `dry_run=true` 우선 |
| **L4 HITL Approval** | SwiftUI `ToolCallCard` | needs_confirmation=true이면 사용자 "실행" 탭까지 대기 |
| **L5 Hardware E-Stop** | SwiftUI `EStopButton` (좌상단) + ESC 단축키 | LLM 경로 우회 — 직접 `fc_emergency_stop` 호출. ISO 13850 Cat-1 controlled stop |

### 3.3 모듈 구조 (Swift)

```
Sources/
├── ForgeCore/                    [기존, 변경 없음]
│   ├── Bus.swift, Walk.swift, Strategy.swift, ...
│   └── ForgeError.swift
├── DarwinForgeUI/                [전면 재구성]
│   ├── DesignSystem/             [신규]
│   │   ├── DesignTokens.swift   — 색상 12 / 타이포 7 / 스페이싱
│   │   └── KoreanUX.swift       — 한국어 UX 라이팅 상수 50+
│   ├── Conversation/             [신규]
│   │   ├── ConversationView.swift           — 메인 화면
│   │   ├── ConversationViewModel.swift       — @Observable
│   │   ├── MessageBubble.swift               — user/system/toolCall/error 4종
│   │   ├── ToolCallCard.swift                — HITL 4-way 승인
│   │   ├── InputBar.swift                    — 텍스트 + slash + @ + (음성 후속)
│   │   └── EmptyState.swift                  — 환영 + 4 suggestion chip
│   ├── Components/               [신규 공용]
│   │   ├── EStopButton.swift                 — 좌상단 56pt + ESC
│   │   ├── ModeBadge.swift                   — 시뮬/실기/오프라인
│   │   ├── BatteryGauge.swift               — 잔량 + 분 추정
│   │   ├── StatusPill.swift                  — chip 상태
│   │   └── DFCard.swift                      — 표준 카드
│   ├── Claude/                   [신규]
│   │   ├── ClaudeCommander.swift            — CLI subprocess wrapper
│   │   ├── CommandSchema.swift              — 9 forge tool JSON 스키마
│   │   ├── SystemPromptBuilder.swift        — 한국어 system prompt 빌더
│   │   └── IntentDispatcher.swift           — dispatch + safety clip
│   ├── Expert/                   [기존 5탭 유지, "전문가 모드"로]
│   │   ├── BoardStatusView.swift   [기존]
│   │   ├── ConnectionView.swift    [기존]
│   │   ├── JointControlView.swift  [기존]
│   │   ├── MotionLibraryView.swift [기존]
│   │   ├── WalkSimView.swift       [기존]
│   │   └── StrategyView.swift      [기존]
│   ├── ConnectionStore.swift     [기존, 보존]
│   └── RootView.swift            [교체 — 대화 1차, 전문가 2차]
├── DarwinForgeApp/
│   └── DarwinForgeApp.swift      [최소 변경 — Settings scene 추가]
└── (Tests/)
    └── ForgeCoreTests/StrategyTests.swift  [기존]
```

---

## 4. 정보 구조 (IA)

### 4.1 화면 구조 ─ 1차/2차/3차

```
┌──────────────────────────────────────────────────────────────┐
│ [E-Stop]  DarwinForge   [Mode: 시뮬]  [배터리 67%·25분]       │ ← 항상 상단 toolbar
├──────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌────────────┐   ┌──────────────────────────────────────┐ │
│   │  대화 ✓   │   │  대화 메시지 흐름                    │ │
│   │            │   │                                      │ │
│   │  전문가     │   │   "지금 일어서줘"                    │ │
│   │  ├ 연결     │   │       └ 로봇을 일으킬게요...         │ │
│   │  ├ 보드     │   │                                      │ │
│   │  ├ 관절     │   │   ┌─ 도구 호출 카드 ────────────┐   │ │
│   │  ├ 모션     │   │   │ 🤖 모션 재생: '일어서기'    │   │ │
│   │  ├ 보행     │   │   │ 약 3초, 4개 키프레임        │   │ │
│   │  └ 전략     │   │   │ [닫기] [실행]              │   │ │
│   │            │   │   └────────────────────────────┘   │ │
│   │            │   │                                      │ │
│   │            │   ├──────────────────────────────────────┤ │
│   │            │   │  /명령  @자원   ⌘L 음성    [ 보내기]│ │
│   │            │   └──────────────────────────────────────┘ │
│   └────────────┘                                            │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

- **사이드바 1단** — `대화` (체크) / `전문가 ▾` (트리). Arc/Linear 패턴.
- **상단 항상 가시** — E-Stop / Mode / Battery. Spot Tablet 패턴.
- **주 영역** — 대화 흐름 + 입력 바. Claude.ai 풍.

### 4.2 사용자 진입 시나리오 5가지

| 사용자 발화 | 시스템 처리 | 응답 |
|---|---|---|
| "로봇 깨워줘" | `fc_joint_set_torque(all=true)` 1단계 토큰 | "관절 16개에 힘이 들어왔어요. 살짝 자세를 잡아요." |
| "왼팔 들어봐" | `fc_joint_set_position(LShoulderPitch=2700)` — 안전 클립 | 카드: "왼쪽 어깨를 30° 올릴게요. 진행할까요?" |
| "지금 어때?" | `fc_bus_board_snapshot` + `fc_joint_read_state(all)` | "관절 16개 모두 정상이에요. 배터리 67%, 오른쪽 어깨가 살짝 따뜻해요(48°C)." |
| "비상 정지" | (LLM 경로 우회) E-Stop 버튼 동작 | "비상 정지! 모든 관절의 힘을 풀었어요. 손으로 받쳐주세요." |
| "공 차줘" | `strategy.activate` (Phase 4) | "[준비 중] 비전 시스템이 아직 카메라와 연결 안 됐어요. 시뮬로 보여드릴까요?" |

---

## 5. 디자인 시스템

### 5.1 색상 토큰 (12 + 다크 모드)

| Token | Light | Dark | 용도 |
|---|---|---|---|
| `surface.canvas` | #F2F2F7 | #1C1C1E | 윈도우 배경 |
| `surface.card` | #FFFFFF | #2C2C2E | 카드 |
| `surface.elev2` | #F9F9FB | #3A3A3C | nested |
| `text.primary` | #1C1C1E | #FFFFFF | 본문 |
| `text.secondary` | #3C3C43 60% | #EBEBF5 60% | 보조 |
| `accent.primary` | #0A84FF | #0A84FF | CTA |
| `accent.forge` | #FF6A00 | #FF8A3D | 브랜드 |
| `state.success` | #34C759 | #30D158 | 정상 |
| `state.warning` | #FF9F0A | #FFD60A | 한계 근접 (KS 노랑) |
| `state.danger` | #FF3B30 | #FF453A | E-Stop / fault (KS 빨강) |
| `state.info` | #5AC8FA | #64D2FF | 텔레메트리 (KS 파랑) |
| `joint.torque` | #BF5AF2 | #DA8FFF | 토크 시각화 |

### 5.2 타이포 스케일 (7 + Mono)

| Token | Family / Size / Weight | 용도 |
|---|---|---|
| `display` | SF Pro Display 28 / Bold | 화면 헤더 |
| `title` | SF Pro Display 22 / Semibold | 섹션 헤더 |
| `subtitle` | SF Pro Display 20 / Regular | 카드 헤더 |
| `body` | SF Pro Text 13 / Regular | 본문 |
| `bodyEmph` | SF Pro Text 13 / Semibold | 강조 본문 |
| `caption` | SF Pro Text 11 / Regular | 메타 |
| `mono` | SF Mono 12 / Regular | 좌표·로그 |

### 5.3 스페이싱 / 라운드 / 그림자

| Token | Value |
|---|---|
| `space.xs/sm/md/lg/xl/2xl` | 4 / 8 / 16 / 24 / 32 / 48 |
| `radius.sm/md/lg/pill` | 8 / 12 / 16 / capsule |
| `shadow.card` | y=4 blur=12 black @ 8% |
| `shadow.float` | y=8 blur=24 black @ 16% |
| `border.hairline` | 0.5pt separator system color |

### 5.4 12개 컴포넌트 카탈로그

| # | 이름 | 용도 | 핵심 속성 |
|---|---|---|---|
| 1 | `DFCard` | 표준 카드 | `surface.card` + radius 16 + shadow.card |
| 2 | `Toolbar` | 상단 toolbar | `Material.regular` 폴백, ToolbarSpacer |
| 3 | `Sidebar` | NavigationSplitView 좌측 | `.regularMaterial` + sectioned list |
| 4 | `StatusPill` | 상태 chip | Capsule + tint × opacity 0.2 + Label |
| 5 | `ModalSheet` | 시트 | `presentationDetents([.medium, .large])` |
| 6 | `Toast` | 알림 | floating Capsule + 자동 dismiss 4s |
| 7 | `Chart` | Swift Charts wrapping | 60s 슬라이딩 윈도우 |
| 8 | `StatusIndicator` | SF Symbol 상태 | `.symbolEffect(.variableColor.iterative)` |
| 9 | `JointWidget` | 관절 카드 | label + position gauge + temp LED |
| 10 | `EStopButton` | 비상 정지 | 56pt + ESC + 즉시 실행 + ISO 13850 색상 |
| 11 | `ModeBadge` | 모드 표시 | 색+아이콘+텍스트 3중 |
| 12 | `MessageBubble` | 대화 버블 | user / system / toolCall / error 4종 |

상세 SwiftUI 의사코드는 §7 컴포넌트 명세 참조.

### 5.5 Liquid Glass 적용 정책

| 영역 | 정책 | 이유 |
|---|---|---|
| Toolbar / Sidebar / Inspector | `Material.regularMaterial` (현재) → Xcode 26에서 `.glassEffect()` 마이그레이션 | Apple HIG navigation layer 전용 |
| 본문 (대화 메시지, 차트, 표) | 솔리드 색상만 | NN/g 비판 + 가독성 |
| E-Stop / Mode / Telemetry | 솔리드 색상 + 강한 contrast | 안전 critical — glass-on-glass 절대 금지 |
| 모달 / 시트 / Toast | `.thinMaterial` | translucent 적정 |
| 키프레임 / 3D 뷰어 (Phase 4) | 솔리드 배경 | base layer |

**현재 상태**: macOS 14 SDK이므로 `Material.regularMaterial / .thinMaterial / .ultraThinMaterial` 사용. Xcode 26 + macOS 26 SDK 마이그레이션 시 `.glassEffect()` + `GlassEffectContainer`로 자동 업그레이드 가능.

---

## 6. 안전 게이트 (5계층 상세)

### 6.1 L1 Refusal — Claude system prompt

```
<system>
당신은 DarwinForge라는 휴머노이드 로봇 제어 비서입니다. 사용자(한국어)
명령을 받아 9개 도구 중 하나를 호출하는 JSON 객체만 출력합니다.

## 거부해야 할 명령
- 자기 충돌을 유발할 수 있는 자세 (예: "팔을 등 뒤로 200도 꺾어")
- 낙상 위험 명령 (예: "한 발로 5초 점프")
- 안전 한계를 명시적으로 넘기는 요구 ("관절 한계 무시하고")
- 위 경우 → tool: "refuse", reason 필드에 한국어 설명

## 모든 동작 명령은 needs_confirmation: true
- 모터를 움직이는 명령은 항상 사용자 확인 필요
- 단, 비상 정지("멈춰", "비상", "정지")는 즉시 실행 가능 (needs_confirmation: false)

## 출력 형식 (반드시 JSON 객체만)
{
  "tool": "<tool_name>",
  "args": { ... },
  "speak": "<한국어 자연스러운 응답 1~2문장>",
  "needs_confirmation": true | false,
  "confidence": 0.0~1.0
}
</system>
```

### 6.2 L2 Whitelist — Swift IntentDispatcher

```swift
enum ForgeTool: String, CaseIterable {
    case ports                  // forge ports
    case ping                   // forge ping
    case scan                   // forge scan
    case board_snapshot         // forge board
    case joint_state            // forge joint state
    case joint_set_position     // forge joint set
    case joint_torque           // forge joint torque
    case emergency_stop         // forge joint estop
    case motion_inspect         // forge motion inspect
    // composite intents (Phase 2):
    case wake_up                // 토크 ON + Stand Up 모션
    case sleep                  // 안전 자세 + 토크 OFF
    case status_report          // board + joint state(all)
    case refuse                 // 거부
}

let claudeOutput: ClaudeResponse = ...
guard let tool = ForgeTool(rawValue: claudeOutput.tool) else {
    throw ForgeError.unknownTool(claudeOutput.tool)
}
```

### 6.3 L3 Safety Clip — `SafetyGate.swift`

```swift
struct SafetyClip {
    static func clipWalkAmplitude(x: Double) -> Double {
        return x.clamped(to: -0.04...0.04)  // m/cycle
    }
    static func clipJointPosition(_ raw: Int, joint: JointID) -> Int {
        let limits = joint.safeLimits  // 보수적 limits — JointConventions
        return raw.clamped(to: limits)
    }
    static func validateMotionPage(id: Int, library: MotionLibrary) -> Bool {
        return library.contains(id: id)
    }
}
```

### 6.4 L4 HITL — ToolCallCard

```
┌─ 도구 호출 카드 ────────────────────────┐
│ 🤖 왼팔 들어 올리기                    │
│ ─────────────────────────────────────  │
│ 무엇이 일어날지                         │
│   왼쪽 어깨를 30° 들어 올려요 (약 1초)  │
│ ─────────────────────────────────────  │
│ 미리보기 ▸ [향후: 3D 시뮬]            │
│ ✓ 안전 한계 안 / ⚠ 자기충돌 검사 미구현│
│ ─────────────────────────────────────  │
│ [닫기]            [실행 (⌘⇧A)]        │
└────────────────────────────────────────┘
```

- 비상 정지(`needs_confirmation=false`)는 카드 없이 즉시 실행
- 그 외 모든 동작은 카드 → 사용자 "실행" 탭까지 대기
- 카드는 fade-in 0.2s, 결과 메시지가 도착하면 자동 collapse

### 6.5 L5 Hardware E-Stop — `EStopButton`

```swift
struct EStopButton: View {
    @EnvironmentObject var dispatcher: IntentDispatcher
    var body: some View {
        Button(role: .destructive) {
            Task { try? await dispatcher.emergencyStop() }
            // LLM 경로 우회 — 직접 fc_emergency_stop 호출
        } label: {
            Label("긴급정지", systemImage: "stop.fill")
                .font(.system(.headline, weight: .bold))
        }
        .keyboardShortcut(.escape, modifiers: [])
        .background(.red)
        .overlay(Circle().stroke(.yellow, lineWidth: 4))   // ISO 13850 빨강+노랑
        .accessibilityLabel("긴급정지")
        .accessibilityHint("로봇 모든 관절의 힘을 즉시 풀어요")
    }
}
```

- 위치: 상단 toolbar 좌측, 항상 가시 (모달 위에서도)
- 단축키: ESC (단순) — Apple HIG 표준 cancel 키
- 즉시 실행 — 확인 다이얼로그 없음 (ISO 13850 §4.4 준수)

---

## 7. 한국어 UX 라이팅 적용 명세

### 7.1 톤 한 줄 요약

> "로봇 옆에서 어깨 너머로 거드는 친절한 동료처럼, 정확한 동작은 숨김없이 알려주되 어려운 단어는 모두 풀어 말한다. 해요체, 능동형, 잡초 뽑기."

### 7.2 단어 통일 사전 (필수 통일 — `KoreanUX.swift` 임베드)

| 통일 단어 | 금지 변형 | 비고 |
|---|---|---|
| 로봇 | 디바이스, 장치, 기기 | 일관성 |
| 관절 | 모터, 서보 (괄호 병기 허용) | ROBOTIS 한글 매뉴얼 차용 |
| 힘 | 토크 (전문 화면 외 금지) | 토스 8원칙 #5 |
| 동작 | 모션, 액션 | |
| 깨우기 / 재우기 | 토크 ON/OFF | 비유적 표현 |
| 닫기 | 취소 | 앱인토스 규정 |
| 다시 시도 | 재시도, 리트라이 | |
| 보낼 위치 | Goal Position | |
| 지금 위치 | Present Position | |
| 통신 라인 | Bus, 데이지체인 | |
| 응답 신호 | Status Packet | |
| 자동 차단 | Shutdown | |

### 7.3 메시지 50개 한글화 (조사 C 적용)

§7.3.1~7.3.4에 분류된 50개. 본 문서에는 카테고리별 5개씩 발췌. 전체는 `KoreanUX.swift`에 임베드.

#### 7.3.1 연결 / 펌웨어
| 영문 | 한국어 |
|---|---|
| Connect to /dev/cu.usbserial-A1B2C3 | "USB 케이블로 로봇과 연결할게요" |
| Bus scan complete — found IDs: 1,2,3,11,12 | "관절 5개를 찾았어요 (어깨·팔꿈치·머리)" |
| Ping ID 200 OK | "허리 관절(200번)이 정상이에요" |
| FTDI driver not loaded | "USB 드라이버가 꺼져 있어요. 시스템 설정에서 켜야 해요. [열어보기]" |
| Demo process holding port | "다른 프로그램이 로봇을 잡고 있어요. 먼저 그 프로그램을 닫아주세요" |

#### 7.3.2 모터 / 동작
| 영문 | 한국어 |
|---|---|
| Goal position clamped from 5000 to 3072 | "목표 위치가 안전 범위(3072)로 자동 조정됐어요" |
| Torque enabled on all 16 servos | "관절 16개에 모두 힘이 들어갔어요" |
| Emergency stop triggered — all torque OFF | "비상 정지! 모든 관절의 힘을 풀었어요" |
| Walking engine x=0.04 m/cycle | "한 걸음에 4cm씩 걸을게요" |
| Joint HeadPan at 2048 (=0°) | "고개가 정면을 보고 있어요" |

#### 7.3.3 전원 / 안전
| 영문 | 한국어 |
|---|---|
| Voltage low (9.2V) | "배터리가 거의 없어요 (9.2V). 5분 안에 충전하지 않으면 곧 멈춰요" |
| Motor RShoulder overheating (78°C) | "오른쪽 어깨 모터가 과열됐어요 (78°C). 5분 쉬어야 해요" |
| Tilt > 30° — fall imminent | "로봇이 30° 넘게 기울었어요. 손으로 잡아주세요" |
| Self-collision detected | "로봇이 자기 몸과 부딪힐 뻔해서 멈췄어요" |
| Two conflicting goals | "두 명령이 부딪혔어요. 가장 마지막 명령을 따랐어요" |

#### 7.3.4 시스템 / 에러
| 영문 | 한국어 |
|---|---|
| macOS deny serial port (TCC) | "macOS가 USB 접근을 막고 있어요. '시스템 설정 > 개인정보 보호'에서 허용해 주세요. [열기]" |
| Network unreachable | "서버에 연결되지 않아요. 와이파이를 확인해 주세요" |
| Are you sure? | "이대로 진행할까요?" |
| Save successful | "저장했어요" |
| Unknown command | "잘 모르겠어요. 혹시 '○○'을 말씀하셨나요?" |

### 7.4 안전 다이얼로그 7종 (긴급도 매핑 — KS S ISO 7010)

| 등급 | 색상 | 아이콘 | 예 |
|---|---|---|---|
| 정보 (Info) | `state.success` 초록 | `info.circle` | "저장했어요" |
| 진행 (Action) | `accent.primary` 파랑 | `arrow.forward.circle` | "토크 켜는 중..." |
| 주의 (Warning) | `state.warning` 노랑 | `exclamationmark.triangle` | "관절 한계 근접" |
| 위험 (Critical) | `state.danger` 빨강 | `exclamationmark.octagon` | "비상 정지!" |

### 7.5 빈 상태 (Empty State) 4 suggestion chip

```
┌──────────────────────────────────────────┐
│  🤖 안녕하세요!                          │
│  로봇에게 무엇을 시키고 싶으세요?         │
│                                          │
│  [로봇 깨워줘]   [지금 어때?]            │
│  [왼팔 들어]     [천천히 한 발 앞으로]    │
│                                          │
│  💡 / 명령 · @ 자원 · ⌘L 음성            │
└──────────────────────────────────────────┘
```

---

## 8. Claude 통합 명세

### 8.1 Subprocess 호출 패턴

```swift
let argv = [
    "claude",
    "--bare",                          // 후크/플러그인 비활성
    "--print",                         // 비대화형
    "--output-format", "json",         // 구조화된 결과
    "--no-session-persistence",
    "--max-budget-usd", "0.10",        // 비용 캡
    "--model", "haiku",                // Haiku 4.5 — $1/$5 per Mtok
    "--system-prompt-file", systemPromptPath
]
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = argv
process.standardInput = pipe(userText.utf8)
process.standardOutput = stdoutPipe
try process.run()
```

### 8.2 응답 파싱

```
{
  "type": "result",
  "result": "{\"tool\":\"motion_inspect\",\"args\":{...},\"speak\":\"...\",\"needs_confirmation\":true,\"confidence\":0.92}",
  "session_id": "...",
  "total_cost_usd": 0.0023,
  "duration_ms": 1240,
  "is_error": false
}
```

Swift는 외부 JSON → `result` 필드 추출 → 내부 JSON 재파싱:

```swift
struct ClaudeWrapper: Decodable { let type, result: String; let total_cost_usd: Double }
struct ClaudeResponse: Decodable {
    let tool: String
    let args: JSONValue          // 도구별 다른 형태
    let speak: String
    let needs_confirmation: Bool
    let confidence: Double
}
```

### 8.3 9개 forge 도구 JSON 스키마 (system prompt에 임베드)

```jsonc
{
  "tools": [
    {
      "name": "ports",
      "description": "USB 직렬 포트 목록을 조회한다.",
      "args": {}
    },
    {
      "name": "ping",
      "description": "디바이스 응답 확인 (ID 200=컨트롤러, 1~20=관절)",
      "args": { "id": "int 1..253", "port": "string" }
    },
    {
      "name": "scan",
      "description": "관절 ID 범위 스캔",
      "args": { "lo": "int", "hi": "int", "port": "string" }
    },
    {
      "name": "board_snapshot",
      "description": "CM 보드 상태 (모델/펌웨어/전압/버튼)",
      "args": { "port": "string" }
    },
    {
      "name": "joint_state",
      "description": "한 관절 상태 (위치/속도/부하/온도/전압/토크)",
      "args": { "id": "int", "port": "string" }
    },
    {
      "name": "joint_set_position",
      "description": "관절 위치 명령 (0..4095). 안전 범위에서 자동 클립",
      "args": { "id": "int", "position": "int 0..4095" }
    },
    {
      "name": "joint_torque",
      "description": "관절 힘 켜기/끄기. all=true면 전체 16개",
      "args": { "id": "int 또는 'all'", "enable": "bool" }
    },
    {
      "name": "emergency_stop",
      "description": "모든 관절 힘 풀기 (비상 정지)",
      "args": {}
    },
    {
      "name": "motion_inspect",
      "description": ".mtn 또는 .json 모션 파일 정보",
      "args": { "path": "string" }
    },
    {
      "name": "refuse",
      "description": "위험·범위 외 요청 거부",
      "args": { "reason": "string (한국어)" }
    }
  ]
}
```

### 8.4 한국어 system prompt 풀 본문 (300줄 기준)

`SystemPromptBuilder.swift`에서 동적 생성. 핵심 골격:

```
당신은 DarwinForge — ROBOTIS DARwIn-OP / OP2 두 휴머노이드 로봇을 macOS에서
다루는 한국어 비서입니다.

## 출력 규칙
- JSON 객체만 출력. 마크다운, 설명, 주석 모두 금지.
- 모든 한국어는 해요체. "확인하시겠어요?" → "확인할까요?"
- speak 필드는 1~2문장, 가능한 짧게.

## 도구 (9개) — 정확히 이 중 하나만 호출
[위 8.3의 JSON 스키마]

## 안전 규칙
- 자기충돌·낙상 위험 명령 → tool="refuse", reason에 이유.
- 모든 모터 동작은 needs_confirmation=true (단, "비상", "멈춰" 등 정지 명령은 false).
- 수치는 항상 단위 명시 (cm, deg, sec).

## 단어 통일
- "토크" 사용 금지 → "힘"
- "Goal Position" → "보낼 위치"
- "Servo" → "관절"
... (KoreanUX.swift의 단어 사전 동기화)

## 거부 예시
사용자: "팔을 등 뒤로 200도 꺾어줘"
출력: {"tool":"refuse","args":{"reason":"관절 한계를 넘어요. 어깨는 ±90°까지만 안전해요."},"speak":"...","needs_confirmation":false,"confidence":0.95}

## 정지 예시 (즉시 실행)
사용자: "멈춰"
출력: {"tool":"emergency_stop","args":{},"speak":"비상 정지! 모든 힘을 풀었어요.","needs_confirmation":false,"confidence":0.99}
```

---

## 9. 접근성 + i18n

### 9.1 4개 환경 변수 분기

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion
@Environment(\.accessibilityReduceTransparency) var reduceTransparency
@Environment(\.accessibilityDifferentiateWithoutColor) var differentiateColor
@Environment(\.accessibilityIncreaseContrast) var increaseContrast

var background: some ShapeStyle {
    reduceTransparency ? AnyShapeStyle(.background.secondary) : AnyShapeStyle(.thinMaterial)
}
```

### 9.2 VoiceOver 의무

| 컴포넌트 | label | hint |
|---|---|---|
| EStopButton | "긴급정지" | "로봇 모든 관절의 힘을 즉시 풀어요" |
| ModeBadge | "현재 모드: 시뮬" | "탭하여 실기/오프라인 변경" |
| MessageBubble (toolCall) | "도구 호출 제안" | "왼팔 들어 올리기 - 실행하려면 두 번 탭" |
| BatteryGauge | "배터리 67%, 25분 남음" | — |

### 9.3 i18n — String Catalog

`Localizable.xcstrings` Xcode 15+ 자동 추출. ko (1차), en (2차) 동시 운영.

```swift
Text("로봇을 일으킬게요")
    .accessibilityLabel(Text("로봇을 일으키는 동작 시작"))
```

### 9.4 광민감성

WCAG 2.3.1 — 초당 3회 이상 깜빡임 금지. 본 프로젝트:
- 비상 깜빡임 = 1Hz 또는 2Hz (정적 표시 우선)
- 5Hz 이상 깜빡임 절대 사용 안 함

---

## 10. 키보드 단축키 12개

| Key | Action | 적용 |
|---|---|---|
| ⌘K | Command palette (Phase 2) | Linear/Raycast |
| ⌘↩ | 메시지 보내기 | ChatGPT |
| ⇧↩ | 입력 줄바꿈 | ChatGPT |
| ESC | **E-Stop** | ISO 13850 / Apple HIG cancel |
| ⌘. | 도구 호출 거부 | macOS 표준 cancel |
| ⌘/ | 단축키 시트 | Linear |
| ⌘L | 음성 입력 (Phase 4) | Wispr Flow / OpenWispr |
| ⌘⇧N | 새 대화 | ChatGPT |
| ⌘⇧A | 도구 실행 승인 | Copilot |
| ⌘⇧E | 전문가 모드 토글 | 자체 |
| ⌘⇧P | 시뮬 모드 (dry-run only) | Claude Code permissions |
| ⌘⇧C | 마지막 코드 복사 | ChatGPT |

---

## 11. 구현 단계 (4 Phase)

### Phase 1 — 골격 (이번 세션)

| 산출물 | 상태 |
|---|---|
| 디자인 문서 (이 파일) | ✅ |
| `DesignTokens.swift` (12 컬러 + 7 타이포 + 스페이싱) | 진입 |
| `KoreanUX.swift` (단어 사전 + 메시지 50종) | 진입 |
| `CommandSchema.swift` (9 forge 도구 정의) | 진입 |
| `ClaudeCommander.swift` (CLI subprocess) | 진입 |
| `IntentDispatcher.swift` (L2 + L3 골격) | 진입 |
| `EStopButton.swift`, `ModeBadge.swift` | 진입 |
| `ConversationView.swift` (메인) | 진입 |
| `RootView.swift` 교체 (대화 1차) | 진입 |
| swift build GREEN + 시각 확인 | 진입 |

### Phase 2 — 9개 도구 풀 매핑 (다음 세션)

- 9개 forge 도구 IntentDispatcher에 모두 wired
- ToolCallCard dry-run preview (텍스트만)
- 4-scope 승인 (Once/Session/Workspace/Always)
- ⌘K command palette
- 16관절 small multiples sparkline (Swift Charts)
- BoardStatus 한국어 라이팅 적용

### Phase 3 — 시뮬레이터 통합

- SCNView + DARwIn-OP URDF 변환 USDZ
- ToolCallCard 안에 3D ghost arm 미리보기
- Webots 연결 (옵션)

### Phase 4 — Liquid Glass + 음성

- Xcode 26 + macOS 26 SDK 마이그레이션
- `.glassEffect()` 적용 (toolbar/sidebar/floating)
- WhisperKit + ⌘L push-to-talk
- 한국어 wake word (옵션)

---

## 12. 출처 (200+ 통합)

### 조사 A — ROBOTIS / RoboCup
- [emanual all-software](https://github.com/ROBOTIS-GIT/emanual/blob/master/docs/en/software/all-software.md)
- [emanual op/development](https://github.com/ROBOTIS-GIT/emanual/blob/master/docs/en/platform/op/development.md)
- [emanual rplus2/motion](https://emanual.robotis.com/docs/en/software/rplus2/motion/)
- [emanual dynamixel/dynamixel_wizard2](https://emanual.robotis.com/docs/en/software/dynamixel/dynamixel_wizard2/)
- [github ROBOTIS-GIT/DynamixelSDK](https://github.com/ROBOTIS-GIT/DynamixelSDK)
- [arXiv 2401.05909 NimbRo](https://arxiv.org/html/2401.05909v1)
- [bit-bots/bitbots_motion](https://github.com/bit-bots/bitbots_motion)
- [docs.bit-bots.de animation](https://docs.bit-bots.de/package/bitbots_animation_server/latest/manual/animation.html)
- [B-Human SimRobot](https://docs.b-human.de/coderelease2021/simrobot/)
- [B-Human Walking](https://docs.b-human.de/coderelease2024/motion/motion-walking/)
- [Spot SDK Choreography](https://dev.bostondynamics.com/docs/concepts/choreography/readme)
- [Apptronik Apollo](https://apptronik.com/apollo)
- [1X NEO](https://www.1x.tech/neo)
- [arXiv 2310.12931 Eureka](https://arxiv.org/abs/2310.12931)
- [DrEureka paper](https://eureka-research.github.io/dr-eureka/)
- [Code as Policies](https://code-as-policies.github.io/)
- [ISO 13850:2015](https://www.iso.org/standard/59970.html)
- [arXiv 2103.04616 Sim Comparison](https://arxiv.org/pdf/2103.04616)
- [Humanoid-Gym](https://github.com/roboterax/humanoid-gym)

### 조사 B — LLM-to-robot
- [arXiv 2204.01691 SayCan](https://arxiv.org/abs/2204.01691)
- [arXiv 2209.07753 Code as Policies](https://arxiv.org/abs/2209.07753)
- [arXiv 2210.03094 VIMA](https://arxiv.org/abs/2210.03094)
- [arXiv 2307.05973 VoxPoser](https://arxiv.org/abs/2307.05973)
- [arXiv 2307.15818 RT-2](https://arxiv.org/abs/2307.15818)
- [arXiv 2310.08864 Open X-Embodiment](https://arxiv.org/abs/2310.08864)
- [arXiv 2406.09246 OpenVLA](https://arxiv.org/abs/2406.09246)
- [arXiv 2503.14734 NVIDIA GR00T N1](https://arxiv.org/abs/2503.14734)
- [Figure Helix](https://www.figure.ai/news/helix)
- [arXiv 2212.08073 Constitutional AI](https://arxiv.org/abs/2212.08073)
- [arXiv 2309.09919 Plug in the Safety Chip](https://arxiv.org/abs/2309.09919)
- [arXiv 2507.05118 VerifyLLM](https://arxiv.org/html/2507.05118)
- [arXiv 2503.03911 Safe LLM-Controlled Robots](https://arxiv.org/abs/2503.03911)
- [Anthropic Tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview)
- [Anthropic Strict tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use)
- [Anthropic MCP](https://www.anthropic.com/news/model-context-protocol)
- [Claude CLI reference](https://code.claude.com/docs/en/cli-reference)
- [LangGraph HITL](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)

### 조사 C — 한국어 UX 라이팅
- [토스 8가지 라이팅 원칙](https://toss.tech/article/8-writing-principles-of-toss)
- [앱인토스 UX 라이팅](https://developers-apps-in-toss.toss.im/design/ux-writing.html)
- [토스 에러 메시지 시스템](https://toss.tech/article/introducing-toss-error-message-system)
- [카카오톡 UI 휴리스틱](https://medium.com/diby-uxresearchops/ui-%ED%9C%B4%EB%A6%AC%EC%8A%A4%ED%8B%B1-%ED%8F%89%EA%B0%80-10%EC%9B%90%EC%B9%99-%EC%B9%B4%ED%86%A1%EC%9C%BC%EB%A1%9C-%EC%95%8C%EC%95%84%EB%B3%B4%EA%B8%B0-7e26fea7921e)
- [네이버페이 deFign](https://medium.com/naverfinancial/defign-%EB%84%A4%EC%9D%B4%EB%B2%84%ED%8C%8C%EC%9D%B4%EB%82%B8%EC%85%9C%EC%9D%98-%EB%94%94%EC%9E%90%EC%9D%B8-%EC%8B%9C%EC%8A%A4%ED%85%9C%EC%9D%84-%EC%A0%95%EC%9D%98%ED%95%98%EB%8B%A4-7b7449832f26)
- [Samsung Designing Words](https://design.samsung.com/kr/contents/ux-writing/)
- [ROBOTIS e-Manual 한국어](https://emanual.robotis.com/docs/kr/)
- [KOSHA 안전보건표지](https://www.kosha.or.kr/)
- [금융투자협회 어려운 금융용어 풀이](https://www.kofia.or.kr/npboard/m_18/view.do?nttId=110404)

### 조사 D — macOS 26 Liquid Glass
- [Apple Newsroom Liquid Glass 2025-06](https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)
- [Apple Newsroom macOS Tahoe 26](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/)
- [Apple HIG Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [glassEffect API](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- [WWDC25 Build SwiftUI app new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [WWDC25 SF Symbols 7](https://developer.apple.com/videos/play/wwdc2025/337/)
- [LiquidGlassReference GitHub](https://github.com/conorluddy/LiquidGlassReference)
- [NN/g Liquid Glass Cracked](https://www.nngroup.com/articles/liquid-glass/)
- [Linear shortcuts](https://linear.app/changelog/2021-03-25-keyboard-shortcuts-help)
- [Raycast](https://www.raycast.com/) / [Raycast AI](https://manual.raycast.com/ai)
- [Things 3 review MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- [Arc Wikipedia](https://en.wikipedia.org/wiki/Arc_(web_browser))
- [Spot App Menus](https://support.bostondynamics.com/s/article/Spot-App-Menus-and-General-Controls-49952)
- [NN/g Tesla Touchscreen](https://www.nngroup.com/articles/tesla-big-touchscreen/)

### 조사 E — 휴머노이드 GUI 표준
- [NAO Choregraphe doc 2.4](http://doc.aldebaran.com/2-4/software/choregraphe/)
- [NAO Timeline panel](http://doc.aldebaran.com/1-14/software/choregraphe/panels/timeline_panel.html)
- [NAO Pose library 2.1](http://doc.aldebaran.com/2-1/software/choregraphe/panels/pose_library_panel.html)
- [Spot Choreographer 5.1.4](https://dev.bostondynamics.com/docs/concepts/choreography/choreographer.html)
- [Spot animation_file_specification](https://github.com/boston-dynamics/spot-sdk/blob/master/docs/concepts/choreography/animation_file_specification.md)
- [Spot Tablet Controller](https://support.bostondynamics.com/s/article/About-the-Spot-Tablet-Controller-72071)
- [1X NEO Two Modes](https://www.humanoidsdaily.com/feed/1x-ceo-details-neo-s-two-modes-and-defends-teleoperation-as-more-secure-than-a-cleaner)
- [Apptronik GR00T](https://www.therobotreport.com/apptronik-integrates-apollo-humanoid-nvidia-project-gr00t/)
- [Unitree Go1 manual](https://static.generation-robots.com/media/user-manual-go1-unitree-robotics.pdf)
- [Unitree H1 SDK](https://support.unitree.com/home/en/H1_developer)
- [Webots User Interface](https://cyberbotics.com/doc/guide/the-user-interface)
- [Gazebo GUI](https://gazebosim.org/docs/latest/gui/)
- [MuJoCo Visualization](https://mujoco.readthedocs.io/en/stable/programming/visualization.html)
- [Isaac Sim Interface](https://docs.isaacsim.omniverse.nvidia.com/4.2.0/introductory_tutorials/tutorial_intro_interface.html)
- [Foxglove URDF](https://foxglove.dev/robotics/urdf)
- [Joint State Publisher GUI](https://my.cytron.io/tutorial/visualizing-robot-models-with-rviz2)
- [ISO 13850 IDEC](https://eu.idec.com/idec-eu/en_EU/RD/safety/law/iso-iec/iso13850)
- [GT-Engineering ISO 13850 §4.4](https://www.gt-engineering.it/en/technical-standards/en-iso-standards/emergency-sto-en-13850/4-4-emergency-stop-device/)
- [Pilz US E-stop](https://www.pilz.com/en-US/support/law-standards-norms/iso-standards/choosing-guards/emergency-stop)

### 조사 F — AI 채팅 UI
- [IntuitionLabs Conversational AI 2025](https://intuitionlabs.ai/articles/conversational-ai-ui-comparison-2025)
- [Reverse-engineering Claude generative UI](https://michaellivs.com/blog/reverse-engineering-claude-generative-ui/)
- [OpenAI Apps SDK UI](https://developers.openai.com/apps-sdk/concepts/ui-guidelines)
- [Anthropic Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)
- [ClaudeLog Tab thinking](https://claudelog.com/faqs/how-to-toggle-thinking-in-claude-code/)
- [Vercel AI SDK Code Block](https://ai-sdk.dev/elements/components/code-block)
- [VSCode Copilot agent-tools](https://code.visualstudio.com/docs/copilot/agents/agent-tools)
- [Anthropic Configure permissions](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [LangGraph HITL](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)
- [Wispr Flow Mic issues](https://docs.wisprflow.ai/articles/4351452717-troubleshooting-mic-issues)
- [WWDC25 SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [HashiCorp terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)
- [arXiv 2411.13851 AR-Enhanced HRI](https://arxiv.org/abs/2411.13851)
- [Notion Slash commands](https://www.notion.com/help/guides/using-slash-commands)
- [BoltAI ChatGPT shortcuts](https://docs.boltai.com/blog/chatgpt-keyboard-shortcuts-for-mac)
- [DEV SwiftUI Real-Time AI Chat](https://dev.to/programmingcentral/building-a-real-time-ai-chat-ui-with-swiftui-the-ultimate-guide-to-streaming-tokens-and-observable-244)
- [NN/g Skeleton Screens](https://www.nngroup.com/articles/skeleton-screens/)
- [Mobbin Empty State](https://mobbin.com/glossary/empty-state)
- [AWS Builders' Library Backoff](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)

### 조사 G — 3D + 접근성
- [SCNView Apple Docs](https://developer.apple.com/documentation/scenekit/scnview)
- [SCNNode orientation](https://developer.apple.com/documentation/scenekit/scnnode/1408048-orientation)
- [SceneKit Quaternions Medium](https://medium.com/@jacob.waechter/scenekit-rotations-with-quaternions-d74dc6ba68c6)
- [RealityKit Overview](https://developer.apple.com/augmented-reality/realitykit/)
- [HumaRobotics darwin_description](https://github.com/HumaRobotics/darwin_description)
- [ROBOTIS-OP3-Common](https://github.com/ROBOTIS-GIT/ROBOTIS-OP3-Common)
- [MuJoCo Menagerie](https://github.com/google-deepmind/mujoco_menagerie)
- [urdf-usd-converter](https://github.com/newton-physics/urdf-usd-converter)
- [Swift Charts Apple Docs](https://developer.apple.com/documentation/Charts)
- [WWDC22 Hello Swift Charts](https://developer.apple.com/videos/play/wwdc2022/10136/)
- [CDC Small Multiples](https://www.cdc.gov/cove/data-visualization-types/small-multiples.html)
- [Accessibility modifiers](https://developer.apple.com/documentation/swiftui/view-accessibility)
- [Accessibility rotors Majid](https://swiftwithmajid.com/2021/09/14/accessibility-rotors-in-swiftui/)
- [@ScaledMetric AvanderLee](https://www.avanderlee.com/swiftui/scaledmetric-dynamic-type-support/)
- [WCAG 2.3.1 Three Flashes](https://www.w3.org/WAI/WCAG21/Understanding/three-flashes-or-below-threshold.html)
- [David Nichols Colorblind](https://davidmathlogic.com/colorblind/)
- [WWDC23 String Catalogs](https://developer.apple.com/videos/play/wwdc2023/10155/)
- [SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)
- [IEC 60204-1 IDEC](https://us.idec.com/RD/safety/law/iso-iec/iec60204)

---

## 부록 A. 본 문서가 명시적으로 다루지 않는 것

- 음성 입력 (Phase 4) — WhisperKit 통합은 본 골격 외
- 3D pose preview (Phase 3) — SceneKit 시각화는 placeholder만
- MCP 서버화 (옵션 C) — 본 단계에서 채택 안 함
- 시뮬레이터 통합 (Phase 3) — Webots/MuJoCo 후속
- Liquid Glass 실 적용 (Phase 4) — Xcode 26 SDK 도착 시
- 다중 로봇 fleet (현재 1대 가정)

## 부록 B. 검증 안 된 항목 (Unverified)

- ISO 13850 본문에 "38mm" 명시값 — 산업 사실상 40mm 머쉬룸 헤드, 디지털 UI 환산 38pt는 합리적이나 표준 본문 미명시
- 한국어 wake word 라이브러리 (Porcupine 등) 정확한 한국어 모델 가용성
- macOS HIG의 E-Stop 표준 키보드 단축키 — ESC 채택은 일반적 cancel 관행 차용
- Claude.ai의 정확한 streaming token chunk 사이즈 / fade-in duration — 비공개

본 문서의 모든 권고는 위 부록 B를 제외하고 인용 가능한 1차/2차 출처를 가짐.

---

**다음**: §11 Phase 1 산출물 (코드)을 본 세션에서 즉시 진입.
