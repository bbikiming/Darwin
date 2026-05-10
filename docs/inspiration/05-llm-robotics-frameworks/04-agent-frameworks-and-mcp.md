# 04 — Agent Frameworks and Model Context Protocol (MCP)

> **카테고리 정의**: LLM을 단일 호출이 아닌 **다중 호출 / 다중 에이전트 / 도구 사용 / 사람-기계 협업** 의 형태로 묶는 프레임워크 (LangGraph / CrewAI / AutoGen / Swarm) 와, 그 사이의 **상호운용 표준** (Anthropic Model Context Protocol, MCP).
>
> **DarwinForge 현재 위치와의 관계**: 우리는 단일 Claude CLI 호출 패턴이며 multi-agent / 외부 도구 통합 / approve-edit-reject HITL UX 등의 구조화된 패턴이 부족하다. 본 보고서는 (1) **HITL 패턴**을 LangGraph에서 차용하고 (2) **MCP 서버**를 노출해 다른 에이전트와 상호운용 가능하게 만드는 두 큰 방향을 제안한다.
>
> **핵심 결론 미리**: `forge-mcp` Rust crate를 만들어 forge-ffi 위에 MCP 표준 서버를 구현하면, **DarwinForge가 Claude Desktop / Cursor / Warp / 기타 MCP 클라이언트에서 직접 호출 가능한 로봇 도구가 된다**. 이는 Sprint 6 후반의 가장 큰 전략 베팅이다.

---

## 1. LangGraph — approve / edit / reject / respond 패턴

LangChain Inc., "LangGraph" 프레임워크 (오픈소스, MIT)

### 1.1 핵심 아이디어

LangGraph는 LLM 에이전트를 **DAG / 상태 머신** 으로 명시 모델링한다. 노드 = LLM 호출 또는 도구 호출, 엣지 = 분기 / 루프. 핵심은 모든 상태 전이가 **persisted** 되어 중단 / 재개 / 분기 / 시간여행이 가능하다는 점.

#### Human-in-the-loop 패턴

LangGraph의 가장 영향력 있는 contribution 은 **표준화된 4가지 HITL 응답** [LangChain 공식 문서]:

| 응답 | 의미 | UX |
|---|---|---|
| **approve** | 제안된 다음 단계 승인 | 한 번 클릭으로 진행 |
| **edit** | 다음 단계의 입력값을 사람이 수정 | 인라인 폼으로 파라미터 변경 |
| **reject** | 거부 (다른 행동 요청) | LLM이 다른 plan 생성 |
| **respond** | 새 자연어 명령 / 추가 컨텍스트 주입 | 채팅 메시지로 추가 정보 |

이 4 동작은 `interrupt(...)` API 로 표준화되어 있고, Resume 시 LangGraph가 graph state를 정확히 복구한다.

### 1.2 우리 차용 가능 여부

> ★ **DarwinForge 적용 (P1, 3개월)**: 우리 SwiftUI confirmation UI는 현재 **approve / cancel 두 가지** 만 가진다. LangGraph의 4가지로 확장하면:
>
> | LangGraph 응답 | DarwinForge SwiftUI |
> |---|---|
> | approve | 기존 "확인" 버튼 |
> | **edit** | **새 추가**: 도구 파라미터를 인라인 편집. 예: Claude가 `walk(forward, 30cm)` 를 제안 → 사용자가 슬라이더로 20cm로 수정 → 그 값으로 dispatch. |
> | reject | 기존 "취소" + 자연어 이유 입력 → Claude에게 다시 prompt |
> | **respond** | **새 추가**: 채팅으로 추가 컨텍스트. 예: "공이 멀리 있어, 더 천천히 가" → 다음 plan에 반영. |
>
> 이 4가지는 Claude API의 `tool_result` 메시지로 자연스럽게 매핑된다 — `tool_use_id`에 대해 서로 다른 result를 보내면 된다.
>
> **구현 노트**: graph state persistence (LangGraph의 핵심) 는 우리에게 **현 단계 과제**가 아니지만, ADR-012 (Persistence) 와 결합해서 SwiftData 모델로 쉬운 추가 가능. 단기 (3개월) 에는 메모리만으로도 OK.

(출처:
- LangGraph: https://langchain-ai.github.io/langgraph/
- HITL 가이드: https://langchain-ai.github.io/langgraph/concepts/human_in_the_loop/
- GitHub: https://github.com/langchain-ai/langgraph)

---

## 2. CrewAI

CrewAI Inc., "CrewAI" (오픈소스, MIT)

### 2.1 핵심 아이디어

여러 LLM 에이전트가 **역할 (role)** 을 부여받고 **task** 를 나눠서 처리한다. 예:
- Agent 1 (Researcher) — 정보 수집
- Agent 2 (Writer) — 글 작성
- Agent 3 (Reviewer) — 검토

각 에이전트는 독립 도구를 가지고, **Process** (sequential / hierarchical) 가 협업 흐름을 결정한다.

### 2.2 차용 가능 여부

> ★ **DarwinForge 적용 (낮음 / 미래)**: 현 단계에서 우리 시스템에는 단일 에이전트 (Claude) 만 필요하다. 그러나 **장기 (12개월+)** 다음 분리는 의미 있을 수 있다:
>
> - **Claude Planner** — 자연어 → mini-DSL plan
> - **Claude Verifier** — plan을 두 번째 LLM 호출로 검증 ("이 plan이 안전한가? 사용자 의도와 일치하는가?")
> - **Claude Critic** — 실행 후 결과를 사용자 친화 텍스트로 요약
>
> 이는 Constitutional AI 의 self-critique 패턴 (`03-safety-and-verification.md` §3) 의 multi-agent 판이다. 단, 호출 비용 / 지연이 3배 증가하므로 P3 (12개월+) 에 검토.

(출처:
- CrewAI: https://www.crewai.com/
- GitHub: https://github.com/crewAIInc/crewAI
- 문서: https://docs.crewai.com/)

---

## 3. AutoGen — Microsoft

[Wu et al. 2023] — "AutoGen: Enabling Next-Gen LLM Applications via Multi-Agent Conversation"

### 3.1 핵심 아이디어

**대화형 멀티 에이전트** — 에이전트들이 자연어로 서로 메시지를 주고받으면서 task를 푼다. 가장 영향력 있는 패턴은 **GroupChat** + **Manager** 구조 — 여러 에이전트가 대화하고 manager가 다음 발언자를 라우팅.

각 에이전트는:
- LLM 호출 (자기 차례에)
- 도구 호출
- 사람 입력 대기 (HumanProxy)

### 3.2 차용 가능 여부

> ★ **DarwinForge 적용 (개념적)**: AutoGen 자체는 Python 의존성이 무거워서 macOS 앱에 직접 임베드하기 어렵다. 그러나 **HumanProxy 컨셉**은 직접 차용 가능 — 사용자를 "에이전트의 일종"으로 모델링하면 LangGraph HITL 응답 4종 (§1) 과 자연스럽게 결합된다.

(출처:
- AutoGen: https://microsoft.github.io/autogen/
- GitHub: https://github.com/microsoft/autogen
- 논문: https://arxiv.org/abs/2308.08155)

---

## 4. Anthropic Agent SDK / Claude Code SDK — 우리가 쓰는 것

Anthropic, "Claude Agent SDK" (구 Claude Code SDK) — 이 보고서를 작성하고 있는 환경 자체.

### 4.1 핵심 아이디어

Claude를 **자율 에이전트** 로 운영하기 위한 SDK. 핵심 컴포넌트:

- **Tool framework** — JSON schema로 도구 정의. `tool_use` / `tool_result` 메시지로 dispatch.
- **System prompt** + **prompt caching** — 긴 컨텍스트를 캐싱해서 비용 / 지연 절감.
- **Streaming** — token-by-token 응답.
- **Multi-turn conversation** — 메시지 리스트 누적.
- **Session resumption** — `--resume <session-id>` 로 대화 이어가기 (CLI).

### 4.2 우리 차용 가능 여부

> ★ **DarwinForge 적용 (이미 사용 중)**: 우리 1차 구현이 그것. 평가:
>
> | 기능 | 우리 사용 여부 | 비고 |
> |---|---|---|
> | Tool framework | ◯ (system prompt로 제약, strict tools 미사용) | §2 (`03-safety-and-verification.md`) 에서 strict 권장 |
> | Prompt caching | ✗ (CLI subprocess 라 캐시 활용 어려움) | API 직접 호출 시 활성화 가치 |
> | Streaming | ✗ (`--print` 모드 = 비스트리밍) | UX 개선 시 검토 |
> | Multi-turn | △ (직전 결과를 prompt에 누적) | LangGraph state 패턴이 더 견고 |
> | Session resumption | ✗ | ADR-012 (Persistence) 와 결합 시 가치 |
>
> **권고**: Sprint 6/7에 **CLI subprocess → API 직접 호출 (Rust SDK 또는 HTTP)** 전환 검토. 이유:
> 1. strict tools 활성화.
> 2. prompt caching → 시스템 프롬프트 (현재 ~2KB) 캐시로 비용 ~70% 절감.
> 3. streaming → SwiftUI 의 자연스러운 채팅 UI 가능.
> 4. tool_choice 파라미터 → 위험 작업 강제 차단 가능.

(출처:
- Anthropic Agent SDK: https://docs.anthropic.com/en/agents/overview (확인 필요 — URL 구조)
- Claude Code SDK: https://docs.claude.com/en/docs/claude-code/sdk
- Prompt caching: https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)

---

## 5. Model Context Protocol (MCP) — Anthropic 2024 표준 ★★★

Anthropic, "Introducing the Model Context Protocol" (Nov 2024 발표).

### 5.1 핵심 아이디어

MCP는 **LLM 클라이언트 ↔ 외부 시스템** 간의 표준 프로토콜이다. JSON-RPC over stdio / SSE / HTTP. 세 가지 주요 객체:

| 객체 | 역할 |
|---|---|
| **Tools** | LLM이 호출 가능한 함수 (input schema + output) |
| **Resources** | LLM이 읽기 가능한 데이터 (URI 기반) |
| **Prompts** | 사용자가 호출 가능한 prompt 템플릿 (parameterized) |

서버는 stdio 또는 HTTP 로 listen. 클라이언트 (Claude Desktop, Cursor, Continue, Warp, Zed 등) 가 connect 해서 capabilities 를 discover, tool / resource를 호출한다.

### 5.2 왜 표준화가 중요한가

MCP 이전 — 각 LLM 클라이언트가 자체 도구 인터페이스 (OpenAI plugin, Anthropic tool use, GPT Actions 등) 를 사용. 도구 개발자는 N×M 통합 작성.

MCP 이후 — 도구는 한 번 작성, 모든 MCP 클라이언트에서 사용. **N+M 통합** 으로 줄어든다. 이미 1년 만에 사실상 industry standard 화되었다 (2025 기준 Cursor / Continue / Zed / Warp / Cline / Goose / Microsoft VS Code Insiders 등 대부분의 코딩 IDE 채택).

### 5.3 MCP 깊이 분석 — DarwinForge 가 MCP 서버를 expose 하는 시나리오

> ★ **DarwinForge 적용 (P0–P1, 가장 큰 전략 베팅)**: `forge-mcp` Rust crate 를 만들어 forge-ffi 위에 MCP 표준 서버를 구현.
>
> #### 5.3.1 노출할 객체
>
> **Tools** (모터 제어 / 모션 재생):
> - `darwin_status` — 배터리 / 모터 상태 / 자세 텔레메트리. 읽기 전용.
> - `darwin_play_motion` — 모션 라이브러리 항목 재생. `motion_id` + `speed_scale`.
> - `darwin_stop` — 즉시 안전 정지 (E-Stop 트리거).
> - `darwin_walk` — 보행 명령. 방향 / 거리 / 속도.
> - `darwin_pose` — 사전 정의 자세. `pose_id`.
>
> **Resources** (읽기 전용):
> - `motion://library/{id}` — 모션 JSON.
> - `telemetry://current` — 실시간 상태.
> - `log://session/{date}` — 세션 로그.
>
> **Prompts**:
> - `darwin_calibrate` — 캘리브레이션 워크플로 prompt 템플릿.
> - `darwin_demo` — 데모 시나리오 prompt 템플릿.
>
> #### 5.3.2 통합 시나리오
>
> 1. **Claude Desktop 사용자가 DarwinForge 도구를 직접 호출** — DarwinForge 앱이 macOS에서 돌고 있고, MCP 서버가 stdio로 listen. Claude Desktop의 MCP config 에 `forge-mcp` 등록 → 사용자가 Claude Desktop에서 "내 DARwIn 일어서게 해줘" 입력 → Claude Desktop이 forge-mcp의 `darwin_pose(stand)` 호출 → DarwinForge 가 dispatch.
> 2. **Cursor / VS Code 에서 모션 코드 디버깅** — 개발자가 IDE 안에서 motion JSON을 작성하다가 Claude Sonnet 4.5에게 "이 모션 실제 로봇에서 어떻게 보일지 시각화" 요청 → IDE가 forge-mcp 호출 → forge가 시뮬 또는 실기 재생.
> 3. **다른 에이전트 시스템과 chaining** — LangGraph / CrewAI 가 MCP 클라이언트로 forge-mcp 와 다른 도구 (계산 / 검색) 를 함께 사용하는 멀티 에이전트.
> 4. **DarwinForge 자기 자신이 MCP 클라이언트** — 우리 ClaudeCommander 가 forge-mcp + filesystem MCP + GitHub MCP 등을 함께 사용하면, 사용자가 "이 GitHub 이슈에 적힌 문제 재현해" 같은 명령을 처리할 수 있다.
>
> #### 5.3.3 보안 / 안전 통합
>
> MCP 서버 노출은 **공격 표면 확대**다. 우리 5계층 안전 모델은 그대로 유지된다:
>
> - **L1 Refusal** — MCP 클라이언트의 LLM이 자체 거부 (Claude Desktop이라면 동일).
> - **L2 Whitelist** — `forge-mcp` 가 노출하는 도구가 곧 화이트리스트.
> - **L2.5 Pre/Post Condition** — `forge-mcp` 가 forge-core를 통해 호출하므로 동일 가드 적용.
> - **L3 Safety Clip** — forge-core 안에 그대로.
> - **L4 HITL** — **여기가 미묘**. MCP 클라이언트는 SwiftUI confirmation UI를 띄우지 못한다. 따라서 `forge-mcp` 는 **위험한 도구 호출 시 macOS native notification을 띄우고 사용자가 click 해야 dispatch** 하도록 구현. macOS `UserNotifications` API 사용.
> - **L5 Hardware E-Stop** — 변동 없음.
>
> #### 5.3.4 구현 형태 — `forge-mcp` Rust crate
>
> ```
> /crates
>   /forge-core      (existing)
>   /forge-ffi       (existing)
>   /forge-mcp       (NEW)
>     Cargo.toml
>     src/
>       lib.rs        — MCP server entry
>       tools.rs      — 5개 도구 정의 (input schema)
>       resources.rs  — 3개 리소스 정의
>       prompts.rs    — 2개 prompt 템플릿
>       transport.rs  — stdio / SSE / HTTP transport
>       guard.rs      — L4 HITL native notification trigger
> ```
>
> Anthropic 의 공식 Rust MCP SDK는 2025년 시점 부분 공개 — `mcp-rust` 크레이트 (확인 필요). 또는 직접 JSON-RPC 구현 가능 (200~300 LoC).
>
> #### 5.3.5 라이선스 / 생태계
>
> MCP 사양 자체는 open spec (Apache-2.0). SDK도 Apache-2.0. 우리는 자체 구현을 MIT/Apache로 공개해서 ROBOTIS / Dynamixel 커뮤니티 에 기여 가능. 이는 DarwinForge 의 differentiator 가 된다 — **로봇 분야 MCP 서버는 아직 거의 없다** (2025 기준 대부분이 코딩 / 검색 / 데이터 도메인).

(출처:
- MCP 공식: https://modelcontextprotocol.io/
- MCP 발표 블로그: https://www.anthropic.com/news/model-context-protocol
- MCP spec: https://spec.modelcontextprotocol.io/
- TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
- Python SDK: https://github.com/modelcontextprotocol/python-sdk
- Rust SDK: https://github.com/modelcontextprotocol/rust-sdk (확인 필요 — 2025 부분 공개)
- 서버 예시 collection: https://github.com/modelcontextprotocol/servers)

---

## 6. Devin / Cognition AI

Cognition AI, "Devin: The first AI software engineer" (March 2024 발표).

### 6.1 핵심 아이디어

Devin은 **코딩 / shell / 브라우저 / 에디터** 통합 환경을 가진 자율 에이전트. 핵심 노출은:
- **Agent computer interface (ACI)** — LLM이 OS를 사용하는 인터페이스 (이미지 + 좌표 + key press).
- **장기 plan tracking** — 며칠 걸리는 task를 분해해서 추적.
- **자기 비판 / 재계획** — 실패 시 plan 갱신.

### 6.2 차용 가능 여부

> ★ **DarwinForge 적용 (낮음)**: Devin의 OS-level interface는 우리 도메인과 거리가 있다. 그러나 **장기 plan tracking** 컨셉은 모션 라이브러리 작성 워크플로에 작은 적용이 가능하다 — "이 시연을 위한 모션 5개 만들기" 같은 multi-step 작업의 진행률 추적.

(출처:
- Devin: https://www.cognition.ai/blog/introducing-devin
- 회사 페이지: https://www.cognition.ai/)

---

## 7. OpenAI Swarm / Agents API

OpenAI, "Swarm" (오픈소스 실험, 2024) → 2025년 "Agents SDK / Responses API" 로 정식화.

### 7.1 핵심 아이디어

**Hand-off** 기반 multi-agent — 한 에이전트가 자기 일을 끝내면 명시적으로 다른 에이전트에게 전달. LangGraph의 DAG 보다 가볍지만 명시적이지 않은 분기는 어렵다.

OpenAI Agents SDK (2025) 는 Swarm 의 후속. tool / handoff / tracing / guardrails 통합.

### 7.2 차용 가능 여부

> ★ **DarwinForge 적용 (개념적)**: hand-off 는 우리 단일 Claude 시스템에 직접 적용 어려움. 그러나 향후 **specialized agents** (Planner / Verifier / Critic, §2 참조) 도입 시 패턴 차용 가치.

(출처:
- Swarm: https://github.com/openai/swarm
- OpenAI Agents SDK: https://platform.openai.com/docs/guides/agents (확인 필요)
- Responses API: https://platform.openai.com/docs/api-reference/responses)

---

## 8. xAI Grok (확인 필요)

xAI, Grok 2 / Grok 3 (2024–2025). 로봇 통합 발표:
- Tesla Optimus 와의 통합 가능성이 일론 머스크에 의해 시사됨 (2024) — 그러나 **공식 SDK / API 통합은 미확인** (확인 필요).

> ★ **DarwinForge 적용 (보류)**: 현 시점 (2026-05) Grok API 의 tool use / function calling 기능 성숙도 / 안정성에 대한 공개 자료 부족. 트래킹은 하되 단기 채택 X.

(출처: https://x.ai/ , https://x.ai/grok , 통합 발표는 미공개 (확인 필요))

---

## 9. 종합 — DarwinForge 1년 채택 로드맵

| 우선순위 | 항목 | 출처 / 영감 | 구현 형태 |
|---|---|---|---|
| **P0 (즉시)** | **`forge-mcp` Rust crate 설계 시작** | MCP §5 | Sprint 6 후반 spike. tools 5개 / resources 3개 / prompts 2개 |
| **P1 (3개월)** | LangGraph 4-응답 HITL UX | LangGraph §1 | SwiftUI confirmation에 edit / respond 추가 |
| **P1 (3개월)** | CLI subprocess → API 직접 호출 | Anthropic Agent SDK §4 | Rust crate `anthropic-rs` 또는 직접 HTTP |
| **P1 (3개월)** | Prompt caching 활성화 | §4 | system prompt 캐시 (~70% 비용 절감) |
| **P2 (6개월)** | `forge-mcp` v1 출시 + Hugging Face / GitHub 공개 | §5 | community contribution |
| **P3 (12개월)** | Multi-agent (Planner / Verifier / Critic) | CrewAI §2 + AutoGen §3 + Swarm §7 | 검토 단계, RFC |
| **Tracking** | xAI Grok / Gemini Robotics API | §8 + Gemini Robotics (`02-vla-foundation-models.md` §4) | LLMProvider 추상화로 swap 가능하게 설계 |

---

## 10. 핵심 결론 — 왜 MCP가 가장 큰 베팅인가

세 가지 이유로 `forge-mcp` 가 **본 보고서 전체에서 가장 우선순위 높은 신규 작업**이다.

1. **외부 의존성 최소** — MCP는 Apache-2.0 open spec. 자체 구현으로 200–500 LoC. Anthropic API에 비종속.
2. **Differentiator** — 2026 시점 로봇 분야 MCP 서버는 거의 없다. DarwinForge가 ROBOTIS DARwIn-OP 의 표준 MCP 서버가 되면, 이는 **community moat** 다.
3. **구조 호환성** — 우리 forge-ffi 가 이미 C ABI로 Swift / Rust 모두 노출하므로, MCP wrapper만 추가하면 된다. 기존 5계층 안전 모델은 forge-core에 그대로 — MCP는 단지 새 transport 일 뿐.
4. **에코시스템 부수 효과** — Claude Desktop / Cursor / Warp / Zed 사용자 모두가 잠재 사용자. 별도 macOS UI 없이도 forge가 의미 있게 활용 가능. 이는 **사용자 채널 확장**.

가장 미묘한 부분은 **L4 HITL** — MCP 클라이언트 측 UI 가 우리 SwiftUI confirmation 을 대체할 수 없으므로, **macOS native notification + 명시 click confirm** 으로 대체해야 한다 (§5.3.3). 이는 단점이 아니라 **추가 안전 채널** 로 기능한다 — DarwinForge 앱이 백그라운드에서 돌고 있어도 사용자가 모든 위험 작업에 명시 동의해야 dispatch.

본 카테고리에서 **P0/P1으로 채택 권하는 핵심 4개**:

1. **`forge-mcp` Rust crate** (MCP §5) — 새 도구 노출 표준.
2. **LangGraph 4-응답 HITL** (§1) — confirmation UX 격상.
3. **CLI → API 직접 호출** (§4) — strict tools / caching / streaming 활성화.
4. **LLMProvider 추상화** (§8 함의) — 향후 Gemini / GPT-5 / Grok swap 가능하게.

나머지 (CrewAI, AutoGen, Devin, Swarm, π0.5) 는 학술 / 산업 트래킹 대상이지 단기 차용 대상은 아니다.

---

## 출처 (정리)

- **LangGraph**: https://langchain-ai.github.io/langgraph/ , https://langchain-ai.github.io/langgraph/concepts/human_in_the_loop/ , https://github.com/langchain-ai/langgraph
- **CrewAI**: https://www.crewai.com/ , https://docs.crewai.com/ , https://github.com/crewAIInc/crewAI
- **AutoGen**: https://microsoft.github.io/autogen/ , https://github.com/microsoft/autogen , https://arxiv.org/abs/2308.08155
- **Anthropic Agent SDK / Claude Code SDK**: https://docs.claude.com/en/docs/claude-code/sdk , https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview , https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
- **MCP**: https://modelcontextprotocol.io/ , https://www.anthropic.com/news/model-context-protocol , https://spec.modelcontextprotocol.io/ , https://github.com/modelcontextprotocol/servers , https://github.com/modelcontextprotocol/typescript-sdk , https://github.com/modelcontextprotocol/python-sdk , https://github.com/modelcontextprotocol/rust-sdk (확인 필요)
- **Devin**: https://www.cognition.ai/blog/introducing-devin , https://www.cognition.ai/
- **OpenAI Swarm / Agents**: https://github.com/openai/swarm , https://platform.openai.com/docs/guides/agents (확인 필요), https://platform.openai.com/docs/api-reference/responses
- **xAI Grok**: https://x.ai/ , https://x.ai/grok (로봇 통합은 확인 필요)
