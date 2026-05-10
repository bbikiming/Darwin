# 13. LLM 로봇 데이터셋

> π0 / OpenVLA / Octo zero-shot 시도, 또는 DARwIn-OP fine-tuning을 위한
> 공개 데이터셋 카탈로그. **만약 우리가 VLA 시도를 한다면**, 데이터가
> 가장 큰 결정 요인.

## 인덱스 — 휴머노이드/매니퓰레이션 데이터셋 비교

| 데이터셋 | 기관 | 라이선스 | 크기 | 모달리티 | 휴머노이드 | DARwIn-OP 적합도 |
|----------|------|----------|------|----------|-----------|-------------------|
| [Open X-Embodiment / RT-X](#open-x-embodiment) | Google + 21 기관 | 다양 (대부분 CC-BY) | 1M+ trajectory | RGB + 액션 | 일부 | ★★ — π0 학습에 사용됨 |
| [DROID](#droid) | Stanford | CC-BY-4.0 | 76k trajectory, 350 HW | RGB + dual-arm | ❌ | ★ — manipulation 위주 |
| [BridgeData V2](#bridgedata-v2) | Berkeley | CC-BY-4.0 | 60k+ trajectory | RGB + WidowX 액션 | ❌ | ★ — 단일 팔 |
| [AGIBOT WORLD](#agibot-world) | AgiBot (중국) | CC-BY-NC | 1M+ trajectory | RGB + 휴머노이드 액션 | ★★★ | ★★ — 휴머노이드 전용 |
| [Ego4D / Ego-Exo4D](#ego4d) | Meta + 14 대학 | CC-BY 4.0 | 3000+ 시간 | 1인칭 비디오 | (간접) | ★ — 의도 학습 보조 |
| [HumanML3D](#humanml3d) | Tel Aviv University | MIT | 14,616 motions | SMPL skeleton | (인간) | ★★ — 모션 retargeting source |
| [LAFAN1 (Ubisoft)](#lafan1) | Ubisoft La Forge | CC-BY-NC | 5 hours | BVH | (인간) | ★ — 게임 모션 |
| [CMU MoCap](#cmu-mocap) | CMU | 무료 | 2,605 motions | C3D + ASF/AMC | (인간) | ★★ — 휴머노이드 retarget 입문 |
| [AGIBot World Colosseum](#agibot-colosseum) | AgiBot | CC-BY-NC | 100M+ frames | RGB + 듀얼 팔 휴머노이드 | ★★★ | ★ — 직접 매핑 필요 |
| [GR00T 모델 사전학습 데이터](#groot-data) | NVIDIA | 비공개 | n/a | n/a | ★★★ | ❌ — 비공개 |

## DarwinForge 시나리오별 권고

### 시나리오 A — π0 / OpenVLA zero-shot 시도 (우리가 학습 X)

→ **데이터 불필요**. 이미 학습된 π0 / OpenVLA 모델 가중치를 다운받고
DARwIn-OP의 BULK_READ로 관찰을 만들어 inference만. 성공률은 낮을 가능성
크다(20 DOF는 학습 도메인 외).

### 시나리오 B — fine-tune (우리가 ~1000 trajectory 캡처 후 LoRA)

→ **DROID 스타일로 우리가 자체 캡처**. 카메라 + IMU + joint state +
액션을 1000~5000 에피소드 모아서 LoRA로 fine-tune. Berkeley 학생
1명이 한 달이면 가능. 우리는 사람이 적어 어려움.

### 시나리오 C — 인간 mocap을 DARwIn-OP로 retarget (★★ 가장 가능성)

→ **HumanML3D / CMU MoCap / Mixamo** 인간 모션을 retarget. SMPL → DARwIn-OP
20-DOF 매핑 (`docs/inspiration/12-mocap-and-retargeting/04-retargeting-pipeline-for-darwin-op.md` 참조).

이게 가장 현실적 — 우리는 데이터 안 찍고 기존 인간 모션 라이브러리 활용.

## 주요 데이터셋 상세

### Open X-Embodiment {#open-x-embodiment}

- **출처**: Google DeepMind + Stanford + Berkeley + UPenn 외 21개 기관 (2023-10)
- **크기**: 1.4 M+ robot trajectory, 22개 다른 로봇 embodiment
- **포맷**: TFDS (TensorFlow Datasets) + RLDS (Reinforcement Learning Datasets)
- **모달리티**: RGB (1~3 카메라) + proprio + action
- **라이선스**: CC-BY-4.0 (대부분)
- **사용**: RT-X-1, RT-X-2, OpenVLA, Octo, π0 모두 사전 학습에 사용

DarwinForge에서:
- Octo / OpenVLA 가중치 → 즉시 추론 시도 (zero-shot)
- 자체 fine-tune은 불필요 — Open X-Embodiment 전체로 학습된 모델 활용

(출처: https://robotics-transformer-x.github.io/, https://arxiv.org/abs/2310.08864)

### DROID {#droid}

- **출처**: Stanford / Berkeley / Princeton / 워싱턴 대학 (2024)
- **크기**: 76k trajectory, 564 scenes, 86 tasks, 13개월 수집, 350 hardware setups
- **하드웨어**: Franka Panda 7-DOF 단일 팔
- **모달리티**: RGB (3 카메라 — wrist + 2 third-person) + Franka state + action
- **라이선스**: CC-BY-4.0
- **링크**: https://droid-dataset.github.io/

DarwinForge 적용:
- 매니퓰레이션 위주라 DARwIn-OP에 직접 매핑 X
- 그러나 데이터 수집 프로토콜 + UI는 모범:
  - VR controller로 사람이 시범
  - 자동 episode 분할 + 메타데이터 태깅
  - GitHub에 수집 SW 오픈소스 (`droid_dataset/`)

(출처: https://droid-dataset.github.io/)

### BridgeData V2 {#bridgedata-v2}

- **출처**: Berkeley (Sergey Levine 그룹) (2023)
- **크기**: 60k trajectory, 24 환경, 13 task type
- **하드웨어**: WidowX 250 6-DOF 단일 팔
- **라이선스**: CC-BY-4.0

DarwinForge 적용:
- 매니퓰레이션 위주 — 직접 적용 X
- π0 / OpenVLA 학습에 포함되어 있어 indirect 영향

(출처: https://rail-berkeley.github.io/bridgedata/)

### AGIBOT WORLD {#agibot-world}

- **출처**: AgiBot (上海智元) (2024-12 공개)
- **크기**: 1M+ trajectory, 휴머노이드 듀얼 팔 + ego camera
- **하드웨어**: AgiBot G1 (양팔 + 다리 X — 좌식)
- **라이선스**: CC-BY-NC 4.0 (비상업)
- **링크**: https://agibot-world.com/

DarwinForge 적용:
- ★★ — 가장 휴머노이드에 가까운 대규모 데이터셋
- 그러나 AGIBOT G1은 휠베이스 + 양팔. DARwIn-OP는 다리 + 양팔. 액션 공간
  매핑이 trivial하지 않음.
- 비상업 라이선스라 상용화 시 주의.

(출처: https://github.com/OpenDriveLab/AgiBot-World)

### Ego4D / Ego-Exo4D {#ego4d}

- **출처**: Meta + 14개 대학 (2022 / 2024)
- **크기**: 3,025 시간 (Ego4D), Ego-Exo4D는 1,422 시간
- **모달리티**: 1인칭 RGB + 시선 + 음성. Ego-Exo4D는 1인칭 + 3인칭 동기.
- **라이선스**: CC-BY 4.0
- **링크**: https://ego4d-data.org/

DarwinForge 적용:
- 직접 액션 데이터 X (관찰만). 의도 / 인식 학습용.
- DARwIn-OP에 시선 정보 학습은 카메라 1대로 제한적.
- ★ — 보조 영감.

(출처: https://ego4d-data.org/, https://ego-exo4d-data.org/)

### HumanML3D {#humanml3d}

- **출처**: Tel Aviv University (Guy et al. 2022)
- **크기**: 14,616 motion (총 28.6시간), 텍스트 기술
- **포맷**: SMPL (24 joints) + 텍스트 캡션
- **라이선스**: MIT (코드) + 데이터 재배포 조건
- **링크**: https://github.com/EricGuo5513/HumanML3D

DarwinForge 적용 ★★:
- **텍스트 → 모션** 학습 데이터의 표준
- DarwinForge에서 "인사하는 모션" 같은 자연어 → SMPL 모션 → DARwIn-OP retarget
- MotionDiffusion (MDM) 학습에 사용됨

(출처: https://arxiv.org/abs/2207.01696)

### LAFAN1 (Ubisoft La Forge) {#lafan1}

- **출처**: Ubisoft (2020)
- **크기**: 5시간, 다양한 액션
- **포맷**: BVH
- **라이선스**: CC-BY-NC 4.0
- **링크**: https://github.com/ubisoft/ubisoft-laforge-animation-dataset

DarwinForge 적용:
- 게임 캐릭터 모션 — 휴머노이드에 가까움
- BVH는 표준 포맷 → DARwIn-OP retarget 가능
- 비상업 — 우리 시연/연구용 OK

### CMU MoCap {#cmu-mocap}

- **출처**: Carnegie Mellon University (1990s~)
- **크기**: 2,605 motion (Subject 1~144)
- **포맷**: C3D, AMC + ASF, BVH (변환본)
- **라이선스**: 무료 (비상업), 학술 표준
- **링크**: http://mocap.cs.cmu.edu/

DarwinForge 적용 ★★:
- 가장 큰 무료 모션 라이브러리
- Subject별 다양한 동작 (걷기, 무용, 격투, 일상)
- DARwIn-OP retarget 입문에 결정적

(출처: http://mocap.cs.cmu.edu/)

### Mixamo (Adobe) — 데이터셋 아니지만 가장 실용적

- **출처**: Adobe
- **크기**: 2,500+ motion + auto-rig
- **포맷**: FBX, GLB
- **라이선스**: 무료 (Adobe 계정 필요), 상업 사용 가능
- **링크**: https://www.mixamo.com/

DarwinForge 적용 ★★★:
- **즉시 사용 가능한 휴머노이드 모션 컬렉션**
- 사용자가 "Mixamo에서 'Wave' 다운받아 import" → DarwinForge가 자동
  retarget → DARwIn-OP에 적용
- 라이선스 가장 너그러움 (상업 OK)

## DARwIn-OP에 가장 현실적 파이프라인

```
인간 모션 소스 (택 1):
  1. CMU MoCap (BVH)
  2. Mixamo (FBX) — 가장 실용적 ★★★
  3. HumanML3D (SMPL) — 텍스트 → 모션 시
  4. iPhone ARKit Body Tracking — 사용자 시범 캡처 ★★

      ↓
   SMPL/BVH → SMPL canonical (24 joints) 변환
      ↓
   SMPL → DARwIn-OP 20 joints retargeting:
     - SHOULDER 좌우 (P/R) → R/L_SHOULDER_PITCH/ROLL
     - ELBOW → R/L_ELBOW
     - HIP (P/R/Y) → R/L_HIP_PITCH/ROLL/YAW
     - KNEE → R/L_KNEE
     - HEAD → HEAD_PAN/TILT
     - HAND/FOOT → 무시 (DARwIn-OP에 없음)
      ↓
   안전 한계 클램프 (1024..3072) + 속도 제한
      ↓
   foot contact 감지 → IMU 보정 (Walk 합성 시)
      ↓
   .mtn motion page (forge-core::motion::page::MotionPage)
      ↓
   재생 (Mac → forge-cli motion play 또는 SwiftUI Motion Library)
```

## DarwinForge 차용 우선순위

| 우선순위 | 데이터셋 / 도구 | 이유 |
|----------|------------------|------|
| ★★★ | **Mixamo** | 즉시 사용 가능, 라이선스 너그러움, 휴머노이드 fits |
| ★★★ | **iPhone ARKit Body Tracking** | 사용자가 직접 시범 → 가장 직관적 |
| ★★ | **CMU MoCap** | 무료, 양 풍부, 학술 표준 |
| ★★ | **HumanML3D** | 텍스트 → 모션 (자연어 명령에 직접 적용) |
| ★ | **Open X-Embodiment** | π0 / OpenVLA가 학습 시 사용 — 우리가 추론만 |
| ★ | **AGIBOT WORLD** | 휴머노이드 데이터 풍부, 비상업 |

## 우리가 만들 수 있는 데이터 (자체 수집)

DarwinForge가 사용 중에 자동 수집:
- 사용자 명령 (자연어) ← Claude 입력
- Claude의 tool_call (의도 분해) ← schema-validated
- 실 로봇 응답 (BULK_READ) ← `JointState` 트레이스
- 사용자 피드백 (HITL approve/reject) ← thumbs up/down

→ 1년 사용 시 ~1000 episode 누적 가능. **DARwIn-OP 전용 미세 데이터셋**.
이걸로 Claude system prompt에 in-context learning 또는 LoRA 시도.

## 출처

- Open X-Embodiment: https://robotics-transformer-x.github.io/
- DROID: https://droid-dataset.github.io/
- BridgeData V2: https://rail-berkeley.github.io/bridgedata/
- AGIBOT WORLD: https://agibot-world.com/
- Ego4D: https://ego4d-data.org/
- HumanML3D: https://github.com/EricGuo5513/HumanML3D
- LAFAN1: https://github.com/ubisoft/ubisoft-laforge-animation-dataset
- CMU MoCap: http://mocap.cs.cmu.edu/
- Mixamo: https://www.mixamo.com/
- π0 데이터셋 정보: https://www.physicalintelligence.company/blog/pi0
