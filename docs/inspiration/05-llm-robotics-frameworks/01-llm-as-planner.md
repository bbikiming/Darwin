# 01 — LLM-as-Planner (high-level reasoning)

> **카테고리 정의**: LLM이 자연어 의도를 받아 **사전 정의된 스킬 라이브러리** 또는 **코드 / 서브골 / 비용 함수**로 분해하는 패턴. 직접 모터 명령(joint targets)은 출력하지 않는다 — 출력은 항상 더 낮은 추상화 계층(스킬 호출, Python 함수, voxel cost map 등)에 위임된다.
>
> **DarwinForge 현재 위치와의 관계**: 우리는 이 카테고리의 가장 단순한 형태(L0 → 9개 화이트리스트 도구 호출)를 이미 사용한다. 본 보고서는 **표현력을 한 단계 끌어올리기 위한 다음 패턴**들을 평가한다.

---

## 1. Google SayCan / PaLM-SayCan

[Ahn et al. 2022] — "Do As I Can, Not As I Say: Grounding Language in Robotic Affordances"

### 1.1 핵심 아이디어

SayCan은 두 가지 점수를 곱(multiplicative)해서 다음 스킬을 고르는 alignment 알고리즘이다.

- **Language score**: LLM이 "이 스킬이 사용자 명령을 얼마나 잘 만족시키는가"를 점수화 (token log-prob).
- **Affordance score**: 별도 학습된 value function 이 "현재 환경에서 이 스킬이 성공할 확률"을 추정.

`p(skill | language, state) ∝ p_LLM(skill | language) · p_aff(skill | state)`

LLM이 "테이블 위 사과 가져와"라고 말해도, 어포던스 모델이 "지금 그리퍼에 다른 물체가 있어서 pick 스킬은 실패 확률이 높다"고 판단하면 가중치가 떨어진다.

### 1.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | 자연어 명령 + 사전 정의된 스킬 셋 (~100개) + 시각 / 상태 |
| 출력 | 스킬 시퀀스 (한 번에 한 스킬씩 그리디 선택) |
| 안전 | 스킬 셋 자체가 화이트리스트. affordance가 0이면 자동 차단 |

### 1.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (부분)**: SayCan의 "스킬 화이트리스트 + 환경 점수" 곱셈 구조 자체는 **이미 우리 L2 (Whitelist)** 가 비슷하게 가진다. 다만 우리는 affordance를 **이진(가능/불가)** 으로만 본다. 향후 배터리 / 토크 헤드룸 / 자세 안정도를 0~1 affordance score로 정량화하면, "할 수는 있지만 위험하다"를 명시할 수 있다.

(출처: https://say-can.github.io/ , arXiv: https://arxiv.org/abs/2204.01691)

---

## 2. Code as Policies (CaP) — Google Brain ★ 핵심 차용 후보

[Liang et al. 2023] — "Code as Policies: Language Model Programs for Embodied Control"

### 2.1 핵심 아이디어

LLM이 자연어를 **Python 코드**로 변환해서 로봇을 제어한다. 핵심 트릭은:

1. **Hierarchical code generation**: 상위 함수가 하위 함수를 호출. LLM은 필요하면 **새 함수도 정의**해서 재사용.
2. **Few-shot prompt**에 사전 정의된 perception / control API 시그니처를 함께 제공 — LLM은 이걸 호출하는 코드만 작성.
3. **NumPy / SciPy 등 일반 라이브러리** 도 호출 가능.

```python
# few-shot 예시 (Liang et al. 2023, Fig 2 발췌)
# Available APIs:
#   detect_object(name) -> (x, y, z)
#   move_to(pos)
#   pick(obj_name)

# User: "Stack the blocks on the empty bowl"
empty_bowl = detect_object("empty bowl")
blocks = detect_objects("block")
sorted_blocks = sorted(blocks, key=lambda b: b.size, reverse=True)
for b in sorted_blocks:
    pick(b.name)
    move_to(empty_bowl + np.array([0, 0, 0.05 * stack_idx]))
```

### 2.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | 자연어 + Python API 시그니처 + few-shot |
| 출력 | Python 코드 블록 (실행 직전에 검증) |
| 안전 | **샌드박스 실행 필수**. CaP 원논문은 `exec()` 직접 호출. 보안 검증은 호출자 책임 |

### 2.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (P1, 3개월 내)**: 현재 우리 9개 화이트리스트 도구는 표현력이 낮다 — "왼쪽으로 30cm 가서 인사하고 다시 돌아와" 같은 순차 의도는 한 번에 처리 못 한다. **Code as Policies 패턴**을 다음과 같이 채택:
> 1. Claude가 **Swift 함수 호출 시퀀스**를 JSON 배열이 아닌 **사전 정의된 DSL** (mini-Swift subset 또는 자체 expression language) 로 출력.
> 2. forge-core (Rust) 안에 **DSL 인터프리터**를 두고, AST 단계에서 화이트리스트 검증 (allowed function calls / 숫자 범위).
> 3. AST 통과 후에만 dispatch.
> 4. **Python 직접 실행은 절대 금지** — `exec()` 는 macOS 앱 샌드박스 정책과도 충돌하고 보안 리스크가 크다.

이 접근의 이점:
- 한 번 호출에 시퀀스 / 분기 / 루프 표현 가능 ("3번 인사한 후 누워")
- 검증은 AST 레벨에서 정확히 가능 (호출 빈도 / 좌표 범위 / 깊이 제한)
- LLM 호출 횟수 절감 (지금은 매 도구마다 follow-up이 필요하다)

(출처: https://code-as-policies.github.io/ , arXiv: https://arxiv.org/abs/2209.07753)

---

## 3. Inner Monologue / Chain of Thought

[Huang et al. 2022] — "Inner Monologue: Embodied Reasoning through Planning with Language Models"

### 3.1 핵심 아이디어

LLM이 **자기 자신과 대화**하면서 계획을 수정하는 패턴. 매 스텝마다 다음 시그널을 prompt에 누적한다:

- **Object / scene description**: "지금 테이블 위에 빨간 큐브, 파란 원통이 있다"
- **Success detection**: "방금 pick 시도가 실패했다 (그리퍼가 비었다)"
- **Active scene description**: 사용자가 끼어든 메시지

LLM은 이 누적 컨텍스트를 보고 다음 행동을 다시 선택한다. CoT (Chain of Thought) 프롬프팅 [Wei et al. 2022] 의 robotics 적용 사례.

### 3.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | 명령 + 누적 환경 피드백 (텍스트) |
| 출력 | 다음 행동 + 추론 텍스트 |
| 안전 | 자기 비판 단계가 들어가서 plan 재고 가능. 그러나 환각은 그대로 누적될 수 있음 |

### 3.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (이미 부분 적용)**: 우리 `ClaudeCommander` 는 매 턴 `IntentDispatcher` 결과(성공 / 실패 / 안전 클립 발동)를 다음 턴 시스템 프롬프트에 누적한다. 이는 Inner Monologue의 "active scene description" 과 같다.
> 추가 차용 가능 부분:
> - **Tool result reflection prompt** — Claude가 직전 도구 호출 결과(예: 모터 38번 토크 한도 도달)를 짧은 자연어로 자체 요약하게 해서, 사용자가 "왜 그렇게 했어?" 라고 물을 때 일관성 있게 답하게 함. UX 측면에서 강력하다.

(출처: https://innermonologue.github.io/ , arXiv: https://arxiv.org/abs/2207.05608)

---

## 4. ProgPrompt — Princeton

[Singh et al. 2022] — "ProgPrompt: Generating Situated Robot Task Plans using Large Language Models"

### 4.1 핵심 아이디어

CaP와 비슷하지만 **Pythonic pseudo-code prompt** 가 핵심. 환경의 객체 / 가능한 액션을 **import 문**과 **함수 시그니처** 처럼 prompt 앞에 둔다.

```python
# objects = ['mug', 'coffee_machine', 'sink']
# def grab(obj): ...
# def goto(loc): ...

# task: make coffee
def make_coffee():
    goto("coffee_machine")
    grab("mug")
    ...
```

LLM은 자연스레 Python 함수 본문을 채우는 형태로 plan을 생성한다.

### 4.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | objects 리스트 + action API + task 명령 |
| 출력 | Python 함수 본문 (execution은 별도) |
| 안전 | 객체 / 액션이 import 단계에서 닫혀 있어서 환각이 줄어듦 |

### 4.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (부분)**: ProgPrompt의 핵심 인사이트는 **환경 상태를 import 처럼 prompt에 넣는다**는 것이다. 우리도 시스템 프롬프트에 "사용 가능한 모션:" 리스트를 넣고 있지만, ProgPrompt 스타일로 **"현재 가능한 모션 / 현재 불가능한 모션 (이유 포함)"** 두 섹션으로 나누면 LLM 환각이 더 줄어들 가능성이 있다.

(출처: https://progprompt.github.io/ , arXiv: https://arxiv.org/abs/2209.11302)

---

## 5. VoxPoser — Stanford

[Huang et al. 2023] — "VoxPoser: Composable 3D Value Maps for Robotic Manipulation with Language Models"

### 5.1 핵심 아이디어

LLM이 **3D voxel cost map** 을 직접 생성한다. 출력이 코드도 스킬도 아닌 **공간상의 값 함수** 라는 점이 독특하다.

- **Affordance map** (이 voxel로 가야 한다)
- **Constraint map** (이 voxel은 피해야 한다)
- **Velocity map** (이 voxel에서는 이 속도로 움직여야 한다)

LLM은 이 cost map을 정의하는 **Python 코드**를 생성하고 (CaP 패턴), motion planner가 이 cost map을 따라 trajectory를 푼다. 즉 LLM은 **공간을 디자인**하지 trajectory를 직접 그리지 않는다.

### 5.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | RGB-D + 자연어 |
| 출력 | 3D cost map (실제로는 cost map을 정의하는 코드) |
| 안전 | constraint map으로 negative-space 제약 표현 가능 |

### 5.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (제한적)**: VoxPoser는 **6 DOF manipulator + RGB-D** 가정이라 DARwIn-OP에는 직접 적용 어렵다. 하지만 **개념** 한 가지는 살릴 만하다 — Claude가 "**금지 영역 / 회피 영역**" 을 출력하게 하는 것. 예: "공이 보이는 방향으로는 가지 마" → Claude가 yaw 영역 (e.g., -30°~+30°) 을 closed 영역으로 마킹 → 다음 명령들이 그 영역으로 가는 것을 자동 거부. 이는 우리 L3 Safety Clip 의 의미적 확장에 해당.

(출처: https://voxposer.github.io/ , arXiv: https://arxiv.org/abs/2307.05973)

---

## 6. TidyBot — Princeton

[Wu et al. 2023] — "TidyBot: Personalized Robot Assistance with Large Language Models"

### 6.1 핵심 아이디어

가정 정리(tidy) 시나리오에 특화. LLM이 **"개인 선호 규칙"** 을 추론한다 — 예: "사용자가 빨간 셔츠는 옷장에, 흰 셔츠는 서랍에 두는 경향이 있다" → LLM이 일반 규칙을 일반화 → 새로운 빨간 양말도 옷장으로 보낸다.

### 6.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | 객체-위치 예시 셋 + 새 객체 |
| 출력 | 새 객체의 목표 위치 |
| 안전 | 규칙 해석 단계에서 사용자가 검토 가능 |

### 6.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (낮음)**: TidyBot은 manipulation + 가정 도메인에 매우 특화되어 있다. DARwIn-OP는 manipulation 능력이 약하므로 직접 차용은 어렵다. 다만 **"사용자별 동작 선호 학습"** 컨셉은 살릴 가치가 있다 — 예: 사용자가 자주 "춤춰" 라고 명령했을 때 어떤 모션을 선호했는지 기록 → 다음번에 "춤춰" 가 다시 들어오면 그 모션 우선 추천. UX 측면에서 의미 있다.

(출처: https://tidybot.cs.princeton.edu/ , arXiv: https://arxiv.org/abs/2305.05658)

---

## 7. DROC — Distillation of Robot Operating Conditions

[Zha et al. 2024] — "DROC: Distillation of Robot Operating Conditions through Language Corrections"

### 7.1 핵심 아이디어

사람이 자연어로 "더 천천히", "거기 말고 왼쪽" 같은 **교정** 을 주면, LLM이 이걸 **재사용 가능한 지식 (knowledge)** 으로 distill 해서 다음 작업에 자동 적용한다. 즉 **사용자 교정을 학습 신호로 변환** 하는 모듈.

핵심 컴포넌트:
- **Correction parser**: 자연어 교정 → 의미적 변경 (속도 -20%, x 좌표 -5cm 등)
- **Knowledge memory**: "사용자는 컵 잡을 때 항상 위에서 접근하는 걸 선호한다" 같은 사실을 누적
- **Application policy**: 다음 task에서 메모리 항목을 자동 적용

### 7.2 입력 / 출력 / 안전

| 항목 | 내용 |
|---|---|
| 입력 | 작업 + 사용자 교정 텍스트 |
| 출력 | 교정된 정책 + 메모리 업데이트 |
| 안전 | 메모리가 누적되며 invalid 교정도 함께 누적될 수 있음 → 검증 필요 |

### 7.3 우리 차용 가능 여부

> ★ **DarwinForge 적용 (P2, 6개월 내)**: 우리 `MotionLibraryView` / `MotionEditor` 워크플로에 자연스럽게 들어맞는다.
> - 사용자가 "이 인사 모션은 너무 빨라" 라고 말하면 → Claude가 해당 모션의 `frame_duration_ms` 를 +20% 한 새 버전을 제안 → 사용자가 수락하면 motion JSON에 추가.
> - DROC식 "Knowledge memory" 는 **Per-robot preferences.json** 으로 디스크 저장. ("이 로봇은 항상 인사 모션 시 머리 각도를 +5° 더 숙이는 게 사용자 선호다")
> - 메모리 항목은 항상 **사용자 명시 동의** 후에만 누적 (자동 학습 금지). 이는 DROC 원논문보다 보수적이지만 안전 우선.

(출처: arXiv: https://arxiv.org/abs/2311.10678 , 프로젝트 페이지: https://sites.google.com/stanford.edu/droc)

---

## 8. 비교 분석 — Skill-Library Granularity vs. Code Generation

본 7개 프레임워크를 한 가지 축으로 보면 **"LLM 출력의 추상화 수준"** 으로 명확히 분류된다.

| 추상화 수준 | 프레임워크 | LLM 부담 | 검증 용이성 | 표현력 |
|---|---|---|---|---|
| **Discrete skill name** (단일 토큰) | SayCan | 낮음 | 매우 높음 | 매우 낮음 |
| **Skill sequence** (텍스트) | Inner Monologue | 중간 | 높음 | 낮음 |
| **Pythonic plan** (struct text) | ProgPrompt | 중간 | 높음 | 중간 |
| **Executable code** | Code as Policies | 높음 | 중간 (AST 검증) | 높음 |
| **Spatial value map** | VoxPoser | 매우 높음 | 어려움 | 매우 높음 |
| **Personalized rules** | TidyBot | 중간 | 어려움 | 도메인 특화 |
| **Correction memory** | DROC | 중간 | 어려움 | 누적 학습 |

DarwinForge 의 현재 위치는 **"Discrete skill name (sayCan급)"** 과 **"Skill sequence (Inner Monologue급)"** 의 중간이다. 9개 화이트리스트 도구가 사실상 9개 스킬, 매 응답이 한 번에 한 도구만 호출한다.

**추천 이동 경로**: → "Pythonic plan / Executable code (Code as Policies급)" 로 한 단계 이동. **표현력은 크게 올라가고 검증 용이성은 AST sandbox 구현으로 보존 가능**. 이는 본 보고서 §2 의 핵심 권고와 동일하다.

VoxPoser 까지 이동하는 것은 매력적이지만 RGB-D 의존이 강하고 검증이 어려워 우리 안전 우선 정책과 잘 맞지 않는다. 스킬 라이브러리 + Code as Policies 의 조합이 우리에게 가장 합리적인 다음 스텝이다.

---

## 9. 종합 — DarwinForge 1년 채택 로드맵

| 우선순위 | 패턴 | 출처 | DarwinForge 채택 형태 |
|---|---|---|---|
| **P1 (3개월)** | Code as Policies (Liang 2023) | §2 | mini-DSL 인터프리터를 forge-core에 추가. Claude가 시퀀스 / 분기 / 짧은 루프를 한 번에 출력. AST 검증 후 실행. |
| **P1 (이미 부분)** | Inner Monologue (Huang 2022) | §3 | tool result reflection 텍스트를 다음 prompt에 누적. UX 일관성 향상. |
| **P2 (6개월)** | DROC (Zha 2024) | §7 | per-robot preference 메모리. 사용자 동의 기반. |
| **P2 (6개월)** | ProgPrompt env-import 스타일 (Singh 2022) | §4 | "현재 가능 / 현재 불가능 (이유)" 두 섹션 prompt. |
| **P3 (12개월+)** | SayCan affordance score (Ahn 2022) | §1 | 배터리 / 토크 헤드룸을 0–1 affordance로 환산. weighted plan ranking. |
| **Non-Goal (1년 내)** | VoxPoser (Huang 2023) | §5 | RGB-D 가정 강함. 개념(금지 영역)만 차용. |
| **Non-Goal (1년 내)** | TidyBot (Wu 2023) | §6 | manipulation 특화. UX 인사이트만 차용. |

가장 중요한 결론은 **§2 Code as Policies 패턴이 우리 표현력 한계를 가장 직접적으로 푼다**는 점이다. 9개 화이트리스트 도구를 9개 함수 호출이 가능한 mini-DSL로 격상시키는 것만으로도 "왼쪽으로 가서 인사하고 돌아와" 류 복합 명령이 single LLM call로 처리된다. 다만 보안상 **Python `exec()` 가 아니라 자체 AST 인터프리터** 가 필수다 — 이는 VerifyLLM (`03-safety-and-verification.md` §1) 과 자연스럽게 결합된다.

---

## 출처 (정리)

- **SayCan**: https://say-can.github.io/ , https://arxiv.org/abs/2204.01691
- **Code as Policies**: https://code-as-policies.github.io/ , https://arxiv.org/abs/2209.07753
- **Inner Monologue**: https://innermonologue.github.io/ , https://arxiv.org/abs/2207.05608
- **CoT (참고)**: https://arxiv.org/abs/2201.11903
- **ProgPrompt**: https://progprompt.github.io/ , https://arxiv.org/abs/2209.11302
- **VoxPoser**: https://voxposer.github.io/ , https://arxiv.org/abs/2307.05973
- **TidyBot**: https://tidybot.cs.princeton.edu/ , https://arxiv.org/abs/2305.05658
- **DROC**: https://arxiv.org/abs/2311.10678 , https://sites.google.com/stanford.edu/droc
- **PaLM-E (SayCan 후속)**: https://palm-e.github.io/ , https://arxiv.org/abs/2303.03378 (참고)
