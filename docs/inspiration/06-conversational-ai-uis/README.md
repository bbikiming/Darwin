# 06. 대화형 AI 앱 UX

> DarwinForge의 1차 인터페이스가 자연어 대화창인 만큼, 세계 최고 수준의
> 대화형 AI 앱들의 UX를 깊이 분석. 우리가 이미 채택한 패턴 + 향후 차용
> 후보를 정리.

## 인덱스

| 도구 | 회사 | 주력 | 차용 1순위 |
|------|------|------|-----------|
| [Claude.ai](claude.md) | Anthropic | 일반 LLM | Artifacts / projects / file uploads |
| [ChatGPT](chatgpt.md) | OpenAI | 일반 LLM | Custom GPTs / Voice mode / Canvas |
| [Gemini](gemini.md) | Google | 일반 LLM, deep research | Empty state suggestion chips ★ (이미 채용) |
| [Perplexity](perplexity.md) | Perplexity AI | 검색 + LLM | 출처 인라인 표기 |
| [Cursor](cursor.md) | Anysphere | 코드 에디터 + AI | Diff acceptance UI |
| [Replit Agent](replit-agent.md) | Replit | 코딩 에이전트 | Plan-then-execute 패턴 |
| [GitHub Copilot Workspace](copilot.md) | GitHub | 코드 작성 | Inline suggestion + Specification edit |
| [v0.dev](v0-dev.md) | Vercel | UI 생성 | Generate → Edit → Apply 흐름 |
| [Claude Code (CLI)](claude-code-cli.md) | Anthropic | 터미널 에이전트 | TodoWrite, plan mode |
| [Wispr Flow](wispr-flow.md) | Wispr | 음성 입력 | 음성 → 텍스트 정확도 (확인 필요) |

## 우리가 이미 채택한 패턴

✅ **Empty state with suggestion chips** (Gemini, Claude.ai 패턴)
   `EmptyState.swift`의 4개 추천 칩 ("로봇 깨워줘", "왼팔 들어줘", …)

✅ **HITL approve/edit/reject** (LangGraph + Anthropic 패턴)
   `ToolCallCard` — `needs_confirmation=true`일 때 사용자 승인 대기

✅ **Tool call inline rendering** (Claude.ai Artifacts 패턴 일부)
   `MessageBubble`의 `.toolCall` 변형이 도구 호출과 결과를 하나의 카드로

✅ **Constitutional refusal** (Claude.ai 패턴)
   System prompt가 위험 명령(자기충돌·낙상) 사전 거부

✅ **System prompt + few-shot examples** (Anthropic best practice)
   `SystemPromptBuilder.swift`가 한국어 거부 예시 포함

## 우리가 아직 안 한 패턴 — 차용 후보

### ★★★ 1순위 — Voice input (Wispr / ChatGPT Voice mode)

DarwinForge가 로봇 옆에서 양손을 못 쓰는 상황 가정 (cradle 잡고 있음).
**음성 입력**이 결정적. macOS Speech Framework + 한국어 모델.

```swift
// 신규: app/ui/DarwinForge/Sources/DarwinForgeUI/Conversation/VoiceInputButton.swift
import Speech

struct VoiceInputButton: View {
    @State private var recognizer: SFSpeechRecognizer?
    @State private var task: SFSpeechRecognitionTask?
    @State private var isListening = false

    var body: some View {
        Button {
            isListening.toggle()
            if isListening { startListening() } else { stop() }
        } label: {
            Image(systemName: isListening ? "mic.fill" : "mic")
                .foregroundStyle(isListening ? DFColor.danger : DFColor.accent)
        }
    }
    // … SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
}
```

→ Sprint 7 후보. 또는 OpenAI Whisper local (mlx-whisper로 Apple Silicon 가속).

### ★★ 2순위 — Plan-then-execute (Replit Agent / Claude Code)

복잡한 작업("인사 모션 만들고 두 번 재생해줘")을 대화에서:
1. Claude가 plan 출력 (text)
2. 사용자가 plan에 OK
3. 단계별 execution + 진행률 표시

현재는 plan-and-execute 단일 호출. plan 단계 분리 시 사용자 신뢰도 ↑.

### ★★ 3순위 — Artifacts (Claude.ai)

긴 출력(모션 JSON, 워크 트레이스 표 등)을 대화 인라인이 아닌 별도 패널에
띄움. SwiftUI에서 `NavigationSplitView`의 우측 detail이 자동으로 artifact
패널 역할 가능.

### ★ 4순위 — Diff acceptance (Cursor / GitHub Copilot)

"이 모션의 step 3을 수정" → Claude가 변경 제안 → 사용자가 diff 보고
Apply / Reject. 현재는 일괄 변경.

### ★ 5순위 — Slash commands (ChatGPT, Claude Code)

`/help`, `/clear`, `/settings`, `/safety on` 등. macOS NSCommand로 구현 용이.

## 우선순위 적용 로드맵

| 시점 | 패턴 | 효과 |
|------|------|------|
| Sprint 7 | Voice input (한국어) | 양손 사용 중에도 명령 |
| Sprint 8 | Plan-then-execute | 복잡 작업 신뢰도 |
| Sprint 9 | Artifacts panel | 긴 출력 가독성 |
| Sprint 10 | Diff acceptance | 모션 점진 편집 |
| Sprint 10 | Slash commands | 파워 유저 |

## 출처

각 도구별 파일 참조.
