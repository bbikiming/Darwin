# NVIDIA Isaac Sim + Isaac Lab — RL 실험 표준

## 한 줄 소개

NVIDIA Omniverse 기반 사진실사급 GPU 가속 로봇 시뮬레이터. 강화학습용
프레임워크 **Isaac Lab**(2024년 IsaacGym 후속)이 함께 제공.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 개발사 | NVIDIA |
| 라이선스 | Isaac Sim 무료 사용권 (NVIDIA EULA) / Isaac Lab BSD-3 |
| 플랫폼 | Linux x86-64 (Ubuntu 22.04+), Windows. **macOS 미지원** ⚠️ |
| GPU | RTX 권장 (RTX 3070+) |
| 물리 엔진 | PhysX 5 (GPU 가속), Newton (2025 도입) |
| 학습 프레임워크 | Isaac Lab (이전 Orbit), RSL-RL, RL-Games |
| 최신 (2025-Q4 기준) | Isaac Sim 4.5, Isaac Lab 2.0 — 확인 필요 |

## 왜 중요한가

- **Foundation 모델 학습**용 표준: NVIDIA GR00T N1 (`docs/inspiration/05-llm-robotics-frameworks/02-vla-foundation-models.md`)이 Isaac Lab에서 학습됨.
- **Domain randomization** 자동화로 sim-to-real gap 축소.
- **Isaac Cloud** — 클라우드 RL 학습 (Tesla Optimus, Figure 등 일부 사용 추정 — 확인 필요)

## DARwIn-OP 적용 가능성

### 도전 과제
- 빌트인 모델 없음. URDF import 필요 ([HumaRobotics/darwin_description](https://github.com/HumaRobotics/darwin_description) 활용).
- 20 DOF의 작은 휴머노이드는 GR00T N1의 학습 도메인(보통 30+ DOF 대형
  휴머노이드)과 거리가 있음.
- macOS에서 직접 못 돌림 → Linux 머신 또는 클라우드 GPU 필요.

### 적용 가능한 시나리오
1. **Walk gait fine-tuning** — RL로 ROBOTIS-OP2의 stock 워킹보다 안정적인
   gait 학습. Reward = (전진 거리) − (낙상 페널티) − (관절 토크 페널티).
2. **Strategy FSM 정책 학습** — 공 추적 → 접근 → 차기 시퀀스를 PPO로 학습.
3. **Eureka 패턴** — Claude/LLM이 reward 함수를 생성하게 시켜 자동 reward
   shaping (Eureka 논문, NVIDIA 2023).

## UI / UX 분석

### 메인 창 (Omniverse Kit 기반)

- 좌측 **Stage** — USD 씬 그래프 (Webots Scene Tree와 유사)
- 중앙 **Viewport** — RTX 패스트레이싱 가능
- 우측 **Property** — 노드 속성
- 하단 **Console** + **Timeline**
- **Composer / Action Graph** — 비주얼 스크립팅 (Unreal Blueprint 유사)

### Isaac Lab CLI

```sh
# 학습
./isaaclab.sh -p source/standalone/workflows/rsl_rl/train.py \
  --task=Isaac-Velocity-Rough-Anymal-C-v0 --num_envs=4096

# 시각화
./isaaclab.sh -p source/standalone/workflows/rsl_rl/play.py \
  --task=Isaac-Velocity-Rough-Anymal-C-v0
```

→ 우리가 `Isaac-Velocity-Flat-Darwin-OP-v0` 같은 환경을 만들고 정책을
학습한 뒤, 학습된 정책 가중치(`.pt`)를 forge-core가 `tract` 또는
`burn` (Rust ML 라이브러리)으로 추론 가능.

## DarwinForge 적용 제안 (장기)

### Phase 1 — URDF 임포트 + 시각화만

```
app/core/forge-sim-isaac/        # Linux 전용 sub-crate
├── envs/
│   └── darwin_op_env.py         # gym-style 환경
└── usd/
    └── darwin-op.usd             # URDF → USD 변환
```

이 경로는 macOS DarwinForge 본 앱과는 분리. 사용자가 RL 학습 머신(Linux + RTX)에서 학습 후 가중치만 가져와 macOS에서 추론.

### Phase 2 — 학습된 walk 정책을 forge-core::walk::RLPolicy로 노출

```rust
// app/core/forge-core/src/walk/rl_policy.rs
pub struct RLPolicy {
    weights: tract_onnx::prelude::TypedRunnableModel<TypedFact, ...>,
}

impl RLPolicy {
    pub fn forward(&self, obs: &Observation) -> JointTargets { ... }
}
```

ONNX export → tract 추론. macOS에서 학습 X, 추론 O.

## 출처

- Isaac Sim: https://developer.nvidia.com/isaac/sim
- Isaac Lab: https://isaac-sim.github.io/IsaacLab/
- Isaac Lab GitHub: https://github.com/isaac-sim/IsaacLab
- Eureka 논문 (LLM-generated rewards): https://arxiv.org/abs/2310.12931
- DrEureka (domain randomization 자동화): https://eureka-research.github.io/dr-eureka/
- HumaRobotics URDF: https://github.com/HumaRobotics/darwin_description
