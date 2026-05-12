# LLM Robotics Frameworks — DarwinForge 통합 리서치 인덱스

> **문서 종류**: 인스피레이션 리서치 (Inspiration Research)
> **작성일**: 2026-05-10
> **대상 프로젝트**: DarwinForge — ROBOTIS DARwIn-OP/OP2 자연어 조종 macOS 앱
> **현재 1차 구현**: Claude CLI(`claude --bare --print --output-format json`) subprocess 호출 + 5계층 안전 모델 (L1 Refusal / L2 Whitelist / L3 Safety Clip / L4 HITL / L5 Hardware E-Stop)
> **본 보고서 목적**: 1차 구현 위에 무엇을 추가 채택할지 결정하기 위한 36개 프레임워크 비교 리서치

---

## 1. 카테고리 인덱스

본 리서치는 LLM 기반 로봇 제어를 다음 6개 카테고리로 분류했다. 각 카테고리는 별도 파일로 분리되어 있다.

| # | 파일 | 카테고리 | 핵심 질문 |
|---|---|---|---|
| 1 | [`01-llm-as-planner.md`](01-llm-as-planner.md) | LLM-as-Planner (high-level reasoning) | LLM이 어떻게 자연어를 로봇이 이해할 수 있는 행동 시퀀스로 분해하는가? |
| 2 | [`02-vla-foundation-models.md`](02-vla-foundation-models.md) | Vision-Language-Action (VLA) Foundation 모델 | LLM이 직접 모터 명령(joint targets)을 출력할 수 있는가? |
| 3 | [`03-safety-and-verification.md`](03-safety-and-verification.md) | 안전 / 검증 프레임워크 | LLM의 환각/오인식이 실제 로봇 액션으로 흘러가지 않게 어떻게 막는가? |
| 4 | [`04-agent-frameworks-and-mcp.md`](04-agent-frameworks-and-mcp.md) | 에이전트 프레임워크 + Model Context Protocol | DarwinForge가 다른 AI 에이전트와 어떻게 상호운용 가능하게 만들 것인가? |

> **주의**: 시뮬레이션 기반 학습 워크플로(NVIDIA Isaac GR00T workflow / Isaac Lab + Sim / Eureka / DrEureka)는 [`02-vla-foundation-models.md`](02-vla-foundation-models.md) 후반부 "데이터 부트스트래핑" 절에 통합 서술. 별도 파일을 만들지 않았다 — DARwIn-OP는 20 DOF 소형이라 Isaac/Sim 통합은 1년 이상 미래 작업이며, 직접 차용보다 "참고 워크플로" 성격이 강하다.

---

## 2. 분류 Taxonomy 표

LLM 로봇 시스템을 5개 축(Layer / Input / Output / Latency / 라이선스)으로 정렬한 표.

### 2.1 Layer 정의

- **L0 — Cloud Reasoner**: 자연어 의도 분류, 작업 계획 (Claude / GPT / Gemini API)
- **L1 — Mid-level Skill Composer**: 스킬 라이브러리 호출 코드 생성 (Code as Policies, ProgPrompt)
- **L2 — Mid-level VLM Planner**: 비전 + 언어 → 서브골 (SayCan, Inner Monologue)
- **L3 — VLA End-to-End**: 비전 + 언어 → joint targets / EE pose (RT-2, π0, OpenVLA)
- **L4 — Low-level Controller**: 50–1000 Hz 모터 제어 (PID, MPC, Robotis CM-740)

### 2.2 비교 표

| 시스템 | Layer | 입력 | 출력 | 추론 지연 | 라이선스 / 공개 |
|---|---|---|---|---|---|
| **SayCan** [Ahn et al. 2022] | L1+L2 | 자연어 + 사전 정의 스킬 셋 | 스킬 시퀀스 | 1–3s | Closed (Google) |
| **Code as Policies** [Liang et al. 2023] | L1 | 자연어 + Python API 시그니처 | Python 코드 | 1–2s | Apache-2 partial |
| **VoxPoser** [Huang et al. 2023] | L2 | 자연어 + RGB-D | 3D voxel cost map | 5–15s | MIT (research) |
| **TidyBot** [Wu et al. 2023] | L1+L2 | 자연어 + 객체 분류 | 정리 규칙 | 2–5s | MIT |
| **ProgPrompt** [Singh et al. 2022] | L1 | 자연어 + Pythonic prompt | Python like 행동 | 1–2s | Closed |
| **DROC** [Zha et al. 2024] | L1+L4 | 자연어 + 인간 교정 | 교정된 정책 | varies | research |
| **RT-1** [Brohan et al. 2022] | L3 | RGB + 명령 | EE 7-DoF + gripper | 100ms | Apache-2 (model card) |
| **RT-2** [Brohan et al. 2023] | L3 | RGB + 명령 (PaLI-X / PaLM-E) | 토큰화된 액션 | 200–600ms | Closed |
| **RT-X / OXE** [Padalkar et al. 2023] | dataset | — | — | — | CC-BY 4.0 데이터셋 |
| **Gemini Robotics** (2025) | L0+L3 | 멀티모달 | 액션 + 추론 | 200–500ms | Closed (Google DeepMind) |
| **Figure Helix** (2025) | L0+L3 듀얼 | RGB + 명령 | System 1 (200Hz 액션) + System 2 (7-9Hz 추론) | 5ms / 110ms | Closed (Figure AI) |
| **NVIDIA GR00T N1** (2025) | L3 | RGB + 자연어 | 휴머노이드 액션 시퀀스 | <100ms | NVIDIA Open Model License |
| **OpenVLA** [Kim et al. 2024] | L3 | RGB + 명령 (Llama-2 7B) | 토큰화된 7-DoF | 240ms | MIT + Llama license |
| **Octo** [Octo Team 2024] | L3 | RGB + 명령 (transformer 27M/93M) | continuous action chunk | 30–100ms | MIT |
| **π0 (Pi-Zero)** [Black et al. 2024] | L3 | RGB + 명령 (PaliGemma + flow matching) | 50Hz action chunks | 20–50ms | Apache-2 (model + weights) |
| **π0.5** (2025) | L3 | + open-world generalization | as π0 | as π0 | Closed (PI commercial) |
| **Claude 4.x + Computer Use** | L0 | text + 스크린샷 | tool calls + 좌표 | 1–3s | Closed (Anthropic API) |
| **GPT-5 + Function Calling** | L0 | text + 멀티모달 | structured tool calls | 1–2s | Closed (OpenAI API) |
| **Gemini 2.5 / 3.0** | L0 | 멀티모달 + native tools | tool calls + 코드 | 1–2s | Closed (Google API) |
| **VerifyLLM** [Chen et al. 2024] | safety | 계획 + condition 명세 | 검증 결과 | <1s | research |
| **AutoTAMP** [Chen et al. 2024] | L1 | 자연어 + 도메인 모델 | TAMP 스켈레톤 | 5–30s | research |
| **Eureka** [Ma et al. 2023] | offline | 환경 코드 + 목표 | RL reward 함수 | minutes | MIT |
| **DrEureka** [Ma et al. 2024] | offline | + sim parameters | randomization 파라미터 | minutes | MIT |
| **LangGraph** | agent | DAG 정의 + state | 분기 / HITL | per-node | MIT |
| **CrewAI** | agent | role + task 명세 | 멀티 에이전트 협업 | varies | MIT |
| **AutoGen** | agent | conversational agents | 멀티 턴 협업 | varies | MIT (Microsoft) |
| **Anthropic Agent SDK** | agent | system + tools | tool calls | 1–3s | Closed (API) |
| **MCP (Model Context Protocol)** | infra | tool / resource / prompt schema | JSON-RPC | <50ms | open spec (Apache-2 SDK) |
| **OpenAI Swarm / Agents** | agent | role agents | hand-off graph | varies | MIT (experimental) |

---

## 3. DarwinForge가 어디에 위치하는가

### 3.1 현재 위치 (2026-05, Sprint 5 종료 시점)

DarwinForge는 현재 **L0 + L4** 구성이다.

- **L0 (Cloud Reasoner)**: Claude Haiku를 subprocess로 호출. 9개 한국어 설명 도구. 시스템 프롬프트로 JSON 강제.
- **L4 (Low-level Controller)**: forge-core (Rust)가 CM-740 / Dynamixel Protocol 1.0으로 50Hz 모터 제어.
- **중간 L1–L3은 비어 있음** — Claude가 직접 9개 화이트리스트 도구를 호출하면 Swift dispatcher가 forge FFI로 전달한다.

이 구성은 SayCan 이전 "LLM-as-orchestrator" 패턴에 해당한다. 견고하지만 표현력이 낮다 — "공을 보고 따라가" 같은 폐루프 perception 명령은 처리할 수 없다.

### 3.2 1년 후 (2027-05) 목표

본 리서치 결과 다음 4축 확장을 제안한다.

| 축 | 현재 | 1년 후 | 출처 |
|---|---|---|---|
| **계획 표현력** | 9개 화이트리스트 도구 | **Code as Policies 패턴**: Claude가 미리 정의된 Swift API를 호출하는 "정책 코드 블록"을 생성, 검증 후 실행 | [Liang et al. 2023] / [`01-llm-as-planner.md`](01-llm-as-planner.md) |
| **시각 폐루프** | 없음 (open-loop) | iPhone 카메라 또는 웹캠 → Claude Vision → 서브골 갱신. 우선 1Hz 저주파 폐루프부터 | [Huang et al. 2023] (VoxPoser) / Gemini Robotics |
| **검증 계층** | 안전 클립만 | **VerifyLLM 패턴 (Sprint 7?)**: pre-condition (배터리 / 토크 / 자세) + post-condition (목표 자세 도달 검증) 명시화 | [Chen et al. 2024] / [`03-safety-and-verification.md`](03-safety-and-verification.md) |
| **상호운용** | DarwinForge 단독 | **`forge-mcp` Rust crate**: Anthropic MCP 표준 서버를 forge-ffi 위에 구현 → Claude Desktop / Cursor / 다른 에이전트가 forge tool을 직접 호출 | [Anthropic 2024] / [`04-agent-frameworks-and-mcp.md`](04-agent-frameworks-and-mcp.md) |

DARwIn-OP의 20 DOF는 RT-2 / π0 같은 VLA 모델을 직접 fine-tune하기엔 데이터셋이 너무 작다 (RT-1 데이터셋: 17개월 / 13대 로봇 / 13만 에피소드 [Brohan et al. 2022]). 하지만 zero-shot으로 OpenVLA / Octo를 호출하는 실험은 가능하다 — 자세한 내용은 [`02-vla-foundation-models.md`](02-vla-foundation-models.md).

### 3.3 명시적 Non-Goal (1년 내)

- **자체 VLA 학습**: 데이터 / GPU 예산 부족. π0는 Apache-2 라이선스이므로 zero-shot 호출은 시도 가능하지만 fine-tune은 보류.
- **Isaac Sim 통합**: macOS-only 앱 정책과 충돌. 시뮬레이션은 MuJoCo 정도까지만 검토.
- **자체 RL 학습 루프**: Eureka / DrEureka는 흥미롭지만 "빠른 폐쇄형 안전 데모" 목표와 거리가 있다.

---

## 4. 본 리서치 적용 우선순위 (TL;DR)

| 우선순위 | 항목 | 출처 파일 |
|---|---|---|
| **P0 (즉시)** | Anthropic strict tool use schema 강제 + refusal 이중화 | [`03-safety-and-verification.md`](03-safety-and-verification.md) §2 |
| **P0 (즉시)** | MCP 서버 (`forge-mcp` crate) 설계 — Sprint 6 후반 | [`04-agent-frameworks-and-mcp.md`](04-agent-frameworks-and-mcp.md) §3 |
| **P1 (3개월)** | Code as Policies 패턴 — Claude가 Swift 정책 함수 호출 코드 생성 | [`01-llm-as-planner.md`](01-llm-as-planner.md) §2 |
| **P1 (3개월)** | LangGraph approve/edit/reject HITL 패턴 차용 | [`04-agent-frameworks-and-mcp.md`](04-agent-frameworks-and-mcp.md) §1 |
| **P2 (6개월)** | VerifyLLM pre/post condition layer | [`03-safety-and-verification.md`](03-safety-and-verification.md) §1 |
| **P2 (6개월)** | OpenVLA / Octo zero-shot 시도 (오프라인 평가만) | [`02-vla-foundation-models.md`](02-vla-foundation-models.md) §4 |
| **P3 (12개월)** | π0 weights 평가 — DARwIn URDF 매핑 가능성 | [`02-vla-foundation-models.md`](02-vla-foundation-models.md) §5 |

---

(출처:
- Anthropic Model Context Protocol — https://modelcontextprotocol.io/
- ROBOTIS DARwIn-OP datasheet — https://emanual.robotis.com/docs/en/platform/op2/getting_started/
- DarwinForge 내부 ADR-005 (Two-Layer Integration), ADR-008 (E-Stop Topology) — `docs/decisions/`)
