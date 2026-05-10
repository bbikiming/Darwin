# Claude Code (CLI) — Anthropic 터미널 에이전트

## 한 줄 소개

우리가 **이미 사용하는 도구** (`claude` 명령). DarwinForge가 자연어 →
forge 도구 호출을 위해 subprocess로 실행.

## 핵심 패턴 (우리 차용 / 차용 예정)

### 1. ✅ Tool use (strict schema)

Anthropic Messages API의 `tool_use` 블록. JSON schema 강제로 LLM 출력이
프로그램적으로 안전.

```swift
// 우리: ClaudeCommander.swift
let cmd = "claude --bare --print --output-format json --max-budget-usd 0.10 --model haiku"
```

### 2. ✅ System prompt + few-shot 거부 예시

`SystemPromptBuilder.swift` 한국어 거부 예시 포함:
- "자기 충돌 명령 → '안전하지 않아 거부합니다'"

### 3. ⏳ TodoWrite (작업 분해)

Claude Code 내부 도구. 작업 시작 시 todos를 작성하고 진행하며 갱신. plan
가시화의 핵심. 우리도 도구 add 가능:

```swift
ForgeTool.addTodo(items: [...])
ForgeTool.completeTodo(index: ...)
```

→ ConversationView 우측 패널에 todo list 카드.

### 4. ⏳ Plan mode

Claude Code의 `/plan` 명령. 실 변경 X, plan만 출력. 사용자 OK 후 실행.
DarwinForge에 channel 분리:
- "/plan 인사 모션 만들어줘" → text-only plan
- "go" → execute

### 5. ⏳ Background agents

Claude Code의 `&` 백그라운드 실행. DarwinForge 매핑:
- "10분간 모터 온도 모니터해줘" → 백그라운드 작업 + 임계치 초과 시 푸시
- macOS NSUserNotification으로 알림

### 6. ✅ MCP integration

Claude Code가 외부 MCP 서버를 도구로 인식. DarwinForge가 MCP **서버**로
expose하면 Claude Code도 forge tool 호출 가능.

→ `forge-mcp` 서브 crate 후보.

## 사용 측면 — 명령어 옵션 (우리가 쓰는 것)

```sh
claude --bare \
       --print \
       --output-format json \
       --max-budget-usd 0.10 \
       --model haiku
```

- `--bare` — 디바이스 인증 화면 스킵 (CI/subprocess 용)
- `--print` — stdout으로만 출력
- `--output-format json` — 파싱 가능
- `--max-budget-usd 0.10` — 비용 상한 (한 명령당 약 0.10 USD)
- `--model haiku` — 빠른 응답 (Haiku 4.5 등)

## DarwinForge 차용 우선순위

| 우선순위 | 패턴 | 시점 |
|----------|------|------|
| ✅ 적용 | Tool use strict | 현재 |
| ✅ 적용 | System prompt + few-shot | 현재 |
| ✅ 적용 | MCP 호환 (소비자 측) | 현재 |
| ⏳ Sprint 7 | TodoWrite | 가까움 |
| ⏳ Sprint 8 | Plan mode (`/plan`) | 가까움 |
| ⏳ Sprint 9 | MCP 서버 expose | 후속 |
| ⏳ Sprint 10 | Background agents | 후속 |

## 출처

- Claude Code 문서: https://docs.claude.com/en/docs/claude-code
- Claude Agent SDK: https://docs.claude.com/en/api/agent-sdk
- MCP 표준: https://modelcontextprotocol.io
- Tool use guide: https://docs.anthropic.com/en/docs/build-with-claude/tool-use
