# 02 — Vision-Language-Action (VLA) Foundation 모델

> **카테고리 정의**: 비전 입력 + 자연어 명령을 받아 **직접 로봇 액션** (joint targets, EE pose, 토큰화된 motion primitives) 을 출력하는 end-to-end 모델군. LLM-as-Planner 와 달리 중간 스킬 라이브러리가 없다 — 모델 자체가 정책(policy)이다.
>
> **DarwinForge 현재 위치와의 관계**: 우리는 VLA를 **현재 사용하지 않는다**. Claude는 텍스트 도구 호출까지만 하고, 모터 제어는 forge-core (Rust) 의 결정론적 스크립트가 담당한다. 본 보고서는 **1년 내 zero-shot 시도가 가능한지** 와 **장기 (2027+) fine-tune 가치**를 평가한다.
>
> **결론 미리**: DARwIn-OP의 20 DOF 소형 폼팩터에 맞는 **사전학습된 weights는 없다**. 그러나 **π0의 hardware-agnostic action representation** 은 zero-shot 호출이 이론적으로 가능하며, 가장 흥미로운 후보다.

---

## 1. RT-1 (Robotics Transformer 1) — Google

[Brohan et al. 2022] — "RT-1: Robotics Transformer for Real-World Control at Scale"

### 1.1 개요

- **데이터셋**: 17개월간 13대 로봇으로 수집한 **130k 에피소드**, 700+ 작업
- **로봇 폼팩터**: Everyday Robots 모바일 매니퓰레이터 (7-DoF arm + gripper + base)
- **모델**: EfficientNet-B3 + USE (Universal Sentence Encoder) + Token Learner + Transformer (35M 파라미터)
- **출력**: 11차원 액션 (arm Δx,Δy,Δz,Δroll,Δpitch,Δyaw,gripper open + base 3-dof + termination + mode flag), 각 차원이 256 bin으로 이산화
- **추론 지연**: ~100ms (3Hz 제어)

### 1.2 핵심 트릭

- **액션 토큰화**: 연속 제어 차원을 256 bin으로 나누어 텍스트 토큰처럼 다룬다. → Transformer 학습이 안정적.
- **Token Learner** [Ryoo et al. 2021]: 81개 spatial token을 8개로 압축해 시퀀스 길이를 줄임.
- **Multi-task learning**: 700+ 작업을 하나의 모델로 학습 → 새 작업에 zero-shot 일반화.

### 1.3 차용 가능성

> ★ **DarwinForge 적용 (낮음)**: RT-1 모델 가중치는 부분 공개되었지만 **Everyday Robots 폼팩터에 강하게 종속** 된다. 7-DoF arm + gripper + 4-wheel base 가정이라 DARwIn-OP의 20-DOF 양다리 양팔과 호환되지 않는다. **액션 토큰화 컨셉 자체는 Sprint 9+ 자체 학습 시 참고할 가치**.

(출처: https://robotics-transformer1.github.io/ , https://arxiv.org/abs/2212.06817)

---

## 2. RT-2 (★ 기준점) — Google DeepMind

[Brohan et al. 2023] — "RT-2: Vision-Language-Action Models Transfer Web Knowledge to Robotic Control"

### 2.1 개요

- **베이스 모델**: PaLI-X (5B/55B) 또는 PaLM-E (12B) — 인터넷 규모 비전-언어 모델
- **트릭**: Web-scale VL 데이터 + RT-1 로봇 데이터를 **co-fine-tune** 해서 LLM이 액션 토큰을 텍스트와 동일 공간에서 출력하게 한다.
- **추론 지연**: 클라우드 TPU 사용 시 200~600ms (1–3 Hz)
- **공개 여부**: 비공개 (closed). 논문만 공개.

### 2.2 가장 큰 contribution

**"Chain of thought + action"** — RT-2가 "이 컵을 정리해" 명령에 대해

```
Plan: pick up the empty cup, then place it on the counter
Action: <BIN_127><BIN_45><BIN_200>...
```

처럼 자연어 plan 다음에 액션 토큰을 출력한다. 이 mixed mode 가 일반화 성능에 결정적이었다.

### 2.3 차용 가능성

> ★ **DarwinForge 적용 (불가, but reference)**: RT-2는 closed model이라 직접 호출 불가. 그러나 "**Plan + Action을 한 번에 생성**" 패턴은 Code as Policies (`01-llm-as-planner.md` §2) 와 결합 시 매력적이다 — Claude가 자연어 plan을 먼저 출력하고, 같은 응답에 mini-DSL action 시퀀스를 함께 출력하면, 사용자에게 **추론 과정을 노출** 하면서 실행 권한을 받을 수 있다.

(출처: https://robotics-transformer2.github.io/ , https://arxiv.org/abs/2307.15818)

---

## 3. RT-X / Open X-Embodiment — 21개 기관 공동

[Padalkar et al. 2023] — "Open X-Embodiment: Robotic Learning Datasets and RT-X Models"

### 3.1 개요

- **21개 기관**, **22개 로봇 폼팩터**, **160만+ 에피소드**, **527개 스킬** 통합 데이터셋. 라이선스 CC-BY 4.0.
- **RT-1-X / RT-2-X**: 이 통합 데이터로 재학습한 모델. 동일 폼팩터에서도 +50% 성공률 향상 보고.
- **핵심 메시지**: "여러 로봇의 데이터를 섞어 학습하면 cross-embodiment transfer가 일어난다."

### 3.2 데이터 구조

각 에피소드는 `tf.data.Dataset` (RLDS 포맷) 으로 통일. 관측 / 액션 차원이 로봇별로 달라도 같은 스키마로 묶인다.

### 3.3 차용 가능성

> ★ **DarwinForge 적용 (장기, 데이터 기여 형태)**: DARwIn-OP는 OXE 데이터셋에 **포함되어 있지 않다** (확인 필요 — 22개 로봇 리스트는 주로 매니퓰레이터, OP3는 미포함). 만약 우리가 **DarwinForge로 자연어 → 모션 재생을 시연한 episodes를 RLDS 포맷으로 export 하는 기능을 만들면**, OXE에 기여할 수 있는 잠재적 가치가 있다. 이는 1년+ 미래의 옵션.

(출처: https://robotics-transformer-x.github.io/ , https://arxiv.org/abs/2310.08864)

---

## 4. Google Gemini Robotics (2025) — 최신 기준점

Google DeepMind, "Gemini Robotics: Bringing AI into the Physical World" (March 2025 발표)

### 4.1 개요

- 두 가지 모델군 발표:
  - **Gemini Robotics**: VLA (Gemini 2.0 기반). 직접 액션 출력.
  - **Gemini Robotics-ER (Embodied Reasoning)**: 비전 + 추론까지만, 액션은 외부.
- **하드웨어 파트너**: Apptronik Apollo 등.
- **공개 여부**: API 형태로 일부 파트너에게만 (확인 필요 — 일반 공개 여부).

### 4.2 강조점

- **dexterity**: 종이 접기, 카드 다루기 같은 미세 조작.
- **generalization**: 학습에 없던 작업에도 적응.
- **interactivity**: 자연어 follow-up 명령으로 실시간 수정.

### 4.3 차용 가능성

> ★ **DarwinForge 적용 (기다림)**: Gemini Robotics API 가 일반 공개되면 **L0 옵션**으로 추가할 가치. 우리 ClaudeCommander 구조는 Anthropic Claude 종속이지만 `LLMProvider` 추상화를 두면 Gemini 도 swap 가능. 다만 **로봇 액션을 직접 받지는 말고, 추론 텍스트만 사용** — 우리 안전 모델 (5계층) 을 우회하지 않게 격리.

(출처: https://deepmind.google/discover/blog/gemini-robotics-brings-ai-into-the-physical-world/ , 기술 보고서 PDF: https://storage.googleapis.com/deepmind-media/gemini-robotics/gemini_robotics_report.pdf)

---

## 5. Figure Helix (★★) — Figure AI

Figure AI, "Helix: A Vision-Language-Action Model for Generalist Humanoid Control" (Feb 2025 발표)

### 5.1 개요

**듀얼 시스템 아키텍처** — 인지심리학의 Kahneman "System 1 / System 2" 직접 차용.

| 구성 | 역할 | 모델 / 빈도 |
|---|---|---|
| **System 2 (S2)** | 시각 / 언어 이해, 장면 추론, 상위 의도 이해 | 7B VLM, 7–9 Hz |
| **System 1 (S1)** | 빠른 시각운동 정책, 토크 컨트롤까지 | 80M Visuomotor Transformer, **200 Hz** |

S2가 latent vector 를 S1에 전달 (단순 교차주의 핸드오프). S1은 200Hz로 양손 35-DoF 휴머노이드 액션 토크를 직접 출력.

### 5.2 가장 큰 contribution

- **Single neural network** 으로 **다양한 작업** + **양손 35 DoF 토크 컨트롤** 을 동시에 다룸. 이전 휴머노이드 VLA들이 '데모 한두 개' 수준이었던 것과 대비.
- **Multi-robot collaboration**: 두 휴머노이드가 협력하는 데모 공개. 같은 모델이 두 로봇에 동시 동작.

### 5.3 차용 가능성

> ★ **DarwinForge 적용 (개념적 매우 유의미)**: Helix의 S1/S2 분리는 우리 아키텍처와 **놀라울 정도로 닮아 있다**.
>
> | Helix | DarwinForge 대응 |
> |---|---|
> | S2 (7B VLM, 7-9Hz) | **Claude API** (1–3s, 따라서 0.3–1Hz) |
> | S1 (80M, 200Hz) | **forge-core (Rust) 의 결정론적 모션 재생** (50Hz) |
> | latent vector handoff | **JSON tool call** (의미적 latent) |
>
> 다른 점은:
> - 우리 S1은 학습된 정책이 아니라 **수작업 모션 라이브러리**.
> - 우리 latent는 latent vector가 아니라 **structured JSON**.
> - 따라서 우리 시스템은 더 안전하고 검증 가능, 대신 표현력은 낮다.
>
> **얻을 교훈**: 1) 두 시스템이 서로 다른 빈도로 돌아도 OK. 2) S2가 S1에 "무엇을 하라"보다 "어떤 latent context"를 주는 디자인은 Code as Policies / mini-DSL 과 호환된다.

(출처: https://www.figure.ai/news/helix , 기술 발표 페이지 외 학술 논문은 미공개 (확인 필요))

---

## 6. NVIDIA GR00T N1 (★★) — NVIDIA

[NVIDIA 2025] — "GR00T N1: An Open Foundation Model for Generalist Humanoid Robots" (March 2025)

### 6.1 개요

- **GR00T (Generalist Robot 00 Technology)** 프로젝트의 첫 공개 모델.
- **모델 크기**: ~2B 파라미터 (확인 필요 — N1 카드별 변형 있음)
- **학습 데이터**: 대규모 시뮬 (Isaac Sim) + 실제 로봇 + 인터넷 비디오 (이형 폼팩터 transfer 강조)
- **라이선스**: NVIDIA Open Model License (가중치 공개, 상업적 사용 일부 제한 — 확인 필요)
- **공개 여부**: Hugging Face에 가중치 공개됨.

### 6.2 핵심 디자인

- **dual-system 추론** (System 1: fast policy / System 2: VLM, Helix와 유사)
- **휴머노이드 표준 액션 공간**: 28-DOF 휴머노이드 (Apptronik / Boston Dynamics 류) 가정
- **Isaac GR00T workflow**: 시뮬에서 데이터 생성 → fine-tune → 실기 transfer

### 6.3 차용 가능성

> ★ **DarwinForge 적용 (zero-shot 어려움)**: GR00T N1은 "**대형 휴머노이드** (1.5–2m, 30+ DOF)" 가정이 강해서 DARwIn-OP의 20 DOF 45cm 폼팩터에 직접 매핑 어렵다. URDF만으로 transfer 시도해도 키네매틱 차이가 너무 크다.
>
> **단**, 다음 한 가지는 가능성 있다:
> - **GR00T 의 perception 부분만** (vision encoder + 언어 grounding) 활용해서 Claude Vision의 대안으로 사용. 단, NVIDIA Open Model License 의 deployment 조건 검증 필요.

(출처: https://developer.nvidia.com/isaac/gr00t , 모델 카드: https://huggingface.co/nvidia/GR00T-N1-2B (확인 필요), GTC 2024 발표: https://blogs.nvidia.com/blog/foundation-model-isaac-robotics-simulation/)

---

## 7. OpenVLA — Stanford / Berkeley (★ 사용 가능)

[Kim et al. 2024] — "OpenVLA: An Open-Source Vision-Language-Action Model"

### 7.1 개요

- **베이스**: Llama-2 7B + DINOv2 + SigLIP visual encoders
- **데이터**: OXE의 970k 에피소드
- **액션 출력**: 7-DoF (EE Δx,Δy,Δz,Δrx,Δry,Δrz,gripper) — 매니퓰레이터 표준
- **추론 지연**: A100 GPU에서 ~240ms
- **라이선스**: MIT (코드) + Llama 2 community license (가중치)
- **가중치 공개**: HuggingFace `openvla/openvla-7b`

### 7.2 차용 가능성

> ★ **DarwinForge 적용 (제한적, 실험 가능)**: OpenVLA는 **7-DoF 매니퓰레이터 가정**이라 DARwIn-OP에 직접 매핑 어렵다. 그러나:
> - DARwIn-OP의 **상체 한쪽 팔만** (어깨 yaw + roll + 팔꿈치, 3 DOF + 손) 분리해서 OpenVLA의 출력 일부를 매핑하는 **toy 실험** 은 가능하다. 정확도는 낮겠지만 "VLA가 우리 시스템에 들어맞는가"를 보는 데 의미.
> - 더 가치 있는 활용: **OpenVLA 코드베이스를 fork** 해서 OP의 20-DOF 액션 공간으로 fine-tune. 다만 데이터셋 수집 (수천 episode) 이 큰 비용이라 1년 내 비현실적.

(출처: https://openvla.github.io/ , https://arxiv.org/abs/2406.09246 , 가중치: https://huggingface.co/openvla/openvla-7b)

---

## 8. Octo — Berkeley (★ 사용 가능)

[Octo Model Team 2024] — "Octo: An Open-Source Generalist Robot Policy"

### 8.1 개요

- **모델 크기**: 27M (Octo-Small) / 93M (Octo-Base) — OpenVLA의 1/100 수준
- **베이스**: T5 텍스트 인코더 + ViT vision + 자체 transformer policy head
- **액션 출력**: continuous **action chunk** (한 번에 미래 4–10 step 출력)
- **추론 지연**: 30–100ms (OpenVLA보다 훨씬 빠름)
- **라이선스**: MIT
- **데이터**: OXE 800k 에피소드

### 8.2 핵심 설계

- **Diffusion action head**: Gaussian 대신 diffusion으로 액션 분포를 표현 → 멀티모달 행동 (예: "왼쪽 또는 오른쪽으로 가도 됨") 표현 가능
- **action chunking**: 한 번에 여러 스텝 미리 예측하면 latency 감소 + smoothness 증가

### 8.3 차용 가능성

> ★ **DarwinForge 적용 (실험 가능, P2 6개월)**: Octo는 OpenVLA 대비 **추론이 4–8배 빠르고**, **27M 모델이라 macOS Mac mini / M2 Pro 에서 ANE / Metal Performance Shaders 로 추론 가능성** 이 있다. 작업:
> 1. Octo-Small 가중치 로드 → CoreML 변환 검증.
> 2. DARwIn-OP의 상체 (15 DOF) 액션 공간을 EE 7-DoF에 매핑하는 어댑터 작성 (정확하진 않더라도).
> 3. **읽기 전용 모드** — Octo 출력은 화면에만 표시, 실제 모터는 보내지 않음. "VLA가 보면 어떻게 움직이고 싶어할까" 시각화.
>
> 이 실험만으로도 우리 안전 모델 (5계층) 의 검증력에 큰 통찰을 준다 (VLA 가 위험한 출력을 낼 때 우리 L3 Safety Clip이 차단하는지 검증 가능).

(출처: https://octo-models.github.io/ , https://arxiv.org/abs/2405.12213 , 가중치: https://huggingface.co/rail-berkeley/octo-base-1.5)

---

## 9. π0 (Pi-Zero) — Physical Intelligence (★ 가장 흥미)

[Black et al. 2024] — "π0: A Vision-Language-Action Flow Model for General Robot Control"

### 9.1 개요

- **창립자**: Sergey Levine, Chelsea Finn 외 (Berkeley/Stanford 출신)
- **베이스**: PaliGemma (3B) + flow matching action expert
- **데이터**: Physical Intelligence 자체 수집 + OXE
- **액션 출력**: **50 Hz action chunks** (continuous, 50 step / 1 sec)
- **추론 지연**: 20–50ms (action chunk 1초어치를 미리 출력)
- **라이선스**: **Apache-2.0 (모델 + 가중치 공개)** — VLA 중 가장 자유로운 라이선스
- **가중치**: GitHub https://github.com/Physical-Intelligence/openpi

### 9.2 핵심 contribution

- **Flow matching** [Lipman et al. 2023] 을 액션 디코더에 사용. Diffusion 보다 빠르고 학습 안정적.
- **여러 폼팩터** 단일 모델로 학습: 단일/양팔 매니퓰레이터, 모바일 매니퓰레이터, **휴머노이드** 까지 포함. → **hardware-agnostic** 의 가능성.
- **action chunk** + flow matching → 50Hz 고주파 제어 가능.

### 9.3 hardware-agnostic action representation 분석

π0의 가장 흥미로운 부분은 **"여러 로봇을 하나의 모델로 학습할 때 action 차원을 어떻게 통일하느냐"** 다.

논문에 따르면 π0는:
1. **로봇별 액션 차원을 padding** 으로 통일 (예: max DOF 32 가정, 부족한 차원은 0 padding + mask)
2. **로봇 ID를 cross-attention condition** 으로 추가
3. flow matching 디코더가 로봇 ID를 보고 적절한 차원만 활성화

이는 **이론상 새로운 로봇 (DARwIn-OP) 도 ID + URDF 만 추가하면 zero-shot 호출 가능** 하다는 뜻이다. 다만 실제로 그렇게 일반화될지는 별개 문제 — π0 학습 데이터셋에 휴머노이드 (Helix급) 가 포함되어 있는지가 결정적.

> ★ **DarwinForge 적용 (P3, 12개월)**: 가장 우선해서 시도할 zero-shot 후보.
> 1. π0 모델 로드 (`openpi` repo) → DARwIn-OP URDF 매핑.
> 2. 카메라 한 대 + 자연어 명령 입력 → action chunk 출력.
> 3. **실모터 송신 금지**, 시뮬레이션 또는 화면 시각화만.
> 4. 결과가 의미 있으면 (자세 안정 / 의도 정확) Sprint 9+ 의 fine-tune 후보로 격상.
>
> 라이선스가 Apache-2.0인 점이 결정적이다 — closed model (RT-2 / Gemini Robotics / Helix) 과 달리 우리 로컬에서 검증 가능.

(출처: https://www.physicalintelligence.company/blog/pi0 , https://arxiv.org/abs/2410.24164 , 코드 / 가중치: https://github.com/Physical-Intelligence/openpi)

---

## 10. π0.5 / π0+ — 후속

[Physical Intelligence 2025] — "π0.5: Open-World Generalization for Robot Foundation Models"

### 10.1 개요

- π0의 후속. **open-world generalization** 강조: 학습에 전혀 없던 환경 / 객체에서도 작업 수행.
- **공개 여부**: π0.5 는 **closed (PI 상업 라이선스)** — π0와 달리 가중치 비공개 (확인 필요, 2025 후반 부분 공개 가능성).

### 10.2 차용 가능성

> ★ **DarwinForge 적용 (보류)**: closed라서 직접 사용 불가. 학술적 참조점.

(출처: https://www.physicalintelligence.company/blog/pi05 , 논문 링크 미공개 (확인 필요))

---

## 11. 데이터 부트스트래핑 — 시뮬레이션 + LLM (Isaac / Eureka / DrEureka)

VLA fine-tune을 하려면 **수천~수만 episode 데이터** 가 필요하다. 실로봇 수집은 비싸므로 시뮬 + RL로 부트스트랩하는 워크플로가 표준화되고 있다.

### 11.1 NVIDIA Isaac Lab + Isaac Sim

- **Isaac Sim**: PhysX 5 기반 GPU 가속 로봇 시뮬레이터. URDF / USD 임포트.
- **Isaac Lab** (구 Orbit): RL 학습 프레임워크. Isaac Sim 위.
- **GR00T workflow**: Isaac Lab 에서 RL 학습 → real-world fine-tune → 실기 deploy.

### 11.2 Eureka — NVIDIA

[Ma et al. 2023] — "Eureka: Human-Level Reward Design via Coding Large Language Models"

- LLM (GPT-4) 이 **RL reward 함수 (Python 코드)** 를 자동 생성.
- 진화 알고리즘으로 reward 함수를 변형 / 평가 / 선택 반복.
- 5개 GPU로 수 시간만에 인간 수준 보상 함수 도달 (Shadow Hand, IsaacGym 환경).

### 11.3 DrEureka — NVIDIA

[Ma et al. 2024] — "DrEureka: Language Model Guided Sim-To-Real Transfer"

- Eureka의 후속. **domain randomization 파라미터** 도 LLM이 자동 생성.
- sim-to-real gap 을 자동으로 줄이는 randomization (마찰 / 질량 / 조명 / 센서 노이즈) 범위를 LLM이 추천.

### 11.4 차용 가능성

> ★ **DarwinForge 적용 (장기 비전)**: Isaac Sim은 macOS 미지원 (확인 필요 — Windows/Linux 우선). 우리 macOS-only 정책과 충돌. 단, **MuJoCo + DARwIn URDF + Eureka 스타일 reward 자동 생성** 은 macOS에서도 가능하다 (MuJoCo 3은 Apple Silicon 네이티브). Sprint 10+ 옵션:
> 1. MuJoCo로 DARwIn 시뮬 환경 구축.
> 2. Claude에게 reward 함수 코드 생성 요청 ("일어서기" 보상 함수 작성).
> 3. RL 학습 → 시뮬 정책 → DarwinForge 모션 라이브러리에 추가.
>
> 이 흐름은 우리 안전 모델과 잘 맞는다 — 실로봇 학습은 위험하지만 시뮬 학습은 안전하다.

(출처:
- Isaac Sim: https://developer.nvidia.com/isaac/sim
- Isaac Lab: https://github.com/isaac-sim/IsaacLab
- Eureka: https://eureka-research.github.io/ , https://arxiv.org/abs/2310.12931
- DrEureka: https://eureka-research.github.io/dr-eureka/ , https://arxiv.org/abs/2406.01967
- MuJoCo: https://mujoco.org/)

---

## 12. 종합 — 차용 가능성 평가 매트릭스

DARwIn-OP의 20 DOF 양다리 휴머노이드 폼팩터가 모든 평가의 기준이다.

| 모델 | 라이선스 | DOF 매핑 | macOS 추론 | zero-shot 가능 | fine-tune 가능 | 1년 내 차용 |
|---|---|---|---|---|---|---|
| RT-1 | 부분 공개 | ✗ (매니퓰레이터) | 어려움 | ✗ | ✗ | ✗ |
| RT-2 | Closed | — | — | ✗ | ✗ | ✗ |
| Gemini Robotics | Closed (API only) | ✗ (대형 휴머노이드) | API | △ (텍스트만) | ✗ | △ (Gemini text API 만 사용) |
| Helix | Closed | ✗ (대형 휴머노이드) | — | ✗ | ✗ | ✗ |
| GR00T N1 | NVIDIA Open ML | ✗ (대형 휴머노이드) | △ (Linux 우선) | △ | △ | △ (perception만 검토) |
| **OpenVLA** | MIT + Llama2 | △ (매니퓰레이터, 어댑터 필요) | △ (7B 무거움) | ◯ (toy) | △ (큰 비용) | ◯ (toy 실험) |
| **Octo** | MIT | △ (어댑터 필요) | ◯ (27/93M, ANE 가능성) | ◯ | ◯ | ◯ (P2 6개월) |
| **π0** | **Apache-2.0** | △ (휴머노이드 부분) | △ (3B + flow matching) | ◯ (가장 흥미) | ◯ | **◯ (P3 12개월 — 가장 매력)** |
| π0.5 | Closed | — | — | ✗ | ✗ | ✗ |

**실행 권고**:
1. **P2 (6개월)**: Octo zero-shot 시각화 실험 (액션 출력은 화면만, 모터 X).
2. **P3 (12개월)**: π0 zero-shot 시도 — Apache-2.0 라이선스 + hardware-agnostic 디자인.
3. **Non-Goal (1년 내)**: 자체 VLA fine-tune. 데이터 / GPU 예산 부족.

가장 흥미로운 결론은 **"π0가 진짜로 hardware-agnostic 인지"** 가 향후 1년의 결정적 검증 항목이라는 것이다. 만약 π0가 DARwIn-OP에 zero-shot으로 의미 있는 액션을 낸다면, DarwinForge는 단번에 L3 (VLA end-to-end) 까지 도달할 수 있다. 안 된다면 Code as Policies + 결정론적 모션 라이브러리 조합에 머무는 것이 안전 측면에서도 합리적이다.

---

## 출처 (정리)

- **RT-1**: https://robotics-transformer1.github.io/ , https://arxiv.org/abs/2212.06817
- **RT-2**: https://robotics-transformer2.github.io/ , https://arxiv.org/abs/2307.15818
- **RT-X / OXE**: https://robotics-transformer-x.github.io/ , https://arxiv.org/abs/2310.08864
- **Gemini Robotics**: https://deepmind.google/discover/blog/gemini-robotics-brings-ai-into-the-physical-world/ , 기술 보고서 PDF: https://storage.googleapis.com/deepmind-media/gemini-robotics/gemini_robotics_report.pdf
- **Figure Helix**: https://www.figure.ai/news/helix
- **NVIDIA GR00T N1**: https://developer.nvidia.com/isaac/gr00t , https://blogs.nvidia.com/blog/foundation-model-isaac-robotics-simulation/ , 모델 카드 (확인 필요)
- **OpenVLA**: https://openvla.github.io/ , https://arxiv.org/abs/2406.09246 , https://huggingface.co/openvla/openvla-7b
- **Octo**: https://octo-models.github.io/ , https://arxiv.org/abs/2405.12213 , https://huggingface.co/rail-berkeley/octo-base-1.5
- **π0**: https://www.physicalintelligence.company/blog/pi0 , https://arxiv.org/abs/2410.24164 , https://github.com/Physical-Intelligence/openpi
- **π0.5**: https://www.physicalintelligence.company/blog/pi05
- **Eureka / DrEureka**: https://eureka-research.github.io/ , https://eureka-research.github.io/dr-eureka/
- **Isaac Sim / Lab**: https://developer.nvidia.com/isaac/sim , https://github.com/isaac-sim/IsaacLab
- **MuJoCo**: https://mujoco.org/
- **Flow Matching (참고)**: https://arxiv.org/abs/2210.02747
