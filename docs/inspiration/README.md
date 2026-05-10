# DarwinForge 고도화 참고 자료 모음 (Inspiration)

> 세계의 다양한 로봇 모션 빌더 / LLM 기반 인공지능 툴 / UI·UX 패턴을
> DarwinForge(macOS 네이티브 앱) 고도화 시 차용 가능한 형태로 정리한 자료
> 디렉토리. 각 항목은 **"우리 SwiftUI / Rust 코드에 어떻게 옮길 수 있는가"**를
> 항상 묻는 관점으로 분석.
>
> 인용은 모든 항목 끝에 출처 URL을 둠. 미확인 항목은 명시적으로 "확인 필요"
> 라고 표기. 추측 금지.

## 디렉토리 구성

```
docs/inspiration/
├── README.md                   ← 이 파일 (전체 인덱스)
│
├── 01-simulation/              로봇 시뮬레이터 (Webots, Gazebo, Isaac Sim, MuJoCo, Drake)
├── 02-robotis-tools/           ROBOTIS 자체 SW 스택 (RoboPlus, Wizard, R+ Motion, OpenCR)
├── 03-humanoid-platforms/      세계 휴머노이드 (NAO, Pepper, Atlas, Helix, Optimus, Unitree, …)
├── 04-motion-authoring-uis/    모션 저작 도구 UI/UX (Choregraphe, Spot Choreographer, MotionBuilder, Ableton, Blender)
├── 05-llm-robotics-frameworks/ LLM-로봇 프레임워크 (SayCan, RT-2, π0, Helix, GR00T, OpenVLA, MCP, …)
├── 06-conversational-ai-uis/   대화형 AI 앱 UX (Claude, ChatGPT, Cursor, Copilot, Replit Agent, …)
├── 07-uiux-patterns/           일반 UX 패턴 (노드 에디터, 타임라인, 한국어 UX, 안전 컬러)
├── 08-game-engines/            게임/시뮬 엔진 (Isaac Lab + Omniverse, Unity ML-Agents, Unreal, Godot)
└── 09-academic-papers/         학술 자료 BibTeX + 분야별 가이드
```

## 우선 순위 — DarwinForge 차용 1순위

| 분류 | 도구 / 프레임워크 | 차용 핵심 |
|------|-------------------|-----------|
| 1순위 ★★★ | **NAO Choregraphe** | Behavior Box / Flow Diagram / Timeline keyframe 패턴 → SwiftUI 모션 에디터 |
| 1순위 ★★★ | **Spot Choreographer** | BPM 기반 다중 트랙 타임라인 → Walk Sim 확장 |
| 1순위 ★★★ | **Anthropic MCP** | forge-mcp 서버화 → 외부 에이전트가 DarwinForge 도구 호출 |
| 1순위 ★★★ | **Figure Helix** dual-system | 자연어 대화 (System 2) + 빠른 반응 컨트롤러 (System 1) 분리 |
| 2순위 ★★ | **OpenVLA / Octo** | DARwIn-OP에 zero-shot fine-tuning 시도 가능성 |
| 2순위 ★★ | **Webots DARwIn-OP 모델** | 실기기 없이 모션 검증 — Sim-to-Real |
| 2순위 ★★ | **Apple HIG / Linear / Raycast** | macOS 네이티브 디자인 토큰 (이미 일부 채택) |
| 2순위 ★★ | **토스 한국어 UX 8원칙** | 해요체 통일 (이미 채택) + 단어 통일 사전 확장 |

## 우리 현재 위치 (2026-05 기준)

DarwinForge가 이미 채용한 패턴:
- ✅ **Anthropic strict tool_use** (5계층 안전, L2 화이트리스트)
- ✅ **Constitutional AI / Claude refusal** (L1 prompt-level 거부)
- ✅ **HITL approve/edit/reject** (L4, LangGraph 패턴)
- ✅ **ISO 13850 Cat-1 e-stop** (L5, 좌상단 항상 가시 빨강+노랑)
- ✅ **토스 8원칙 + 해요체** (한국어 라이팅)
- ✅ **NavigationSplitView + Material 폴백** (Apple HIG)

후속 후보:
- ⏳ Code as Policies → Claude가 Swift 호출 코드 생성
- ⏳ Spot Choreographer 다중 트랙 타임라인 → Walk + 모션 동기화
- ⏳ MCP 서버 expose → 다른 에이전트가 forge tool 호출
- ⏳ Webots DARwIn-OP 모델 → sim-to-real 검증 파이프라인
- ⏳ OpenVLA fine-tuning 실험

## 사용 방법

각 카테고리 디렉토리의 `README.md`가 그 안의 파일들을 인덱싱한다. 위에서
아래로 읽는 순서가 기본 학습 흐름:

1. **01-simulation** — 어떤 시뮬레이터 위에 올릴지 결정
2. **02-robotis-tools** — 우리가 호환·대체할 기존 ROBOTIS 스택 이해
3. **03-humanoid-platforms** — 다른 로봇이 어떻게 풀었나
4. **04-motion-authoring-uis** — 우리 모션 에디터 UI 채울 때 참고
5. **05-llm-robotics-frameworks** — 우리 자연어 통합 다음 단계
6. **06-conversational-ai-uis** — 우리 대화창 UX 다듬을 때
7. **07-uiux-patterns** — 일반 UX·접근성·한국어 다듬기
8. **08-game-engines** — 시뮬레이션 + RL 실험
9. **09-academic-papers** — 학술 인용 / 알고리즘 출처
