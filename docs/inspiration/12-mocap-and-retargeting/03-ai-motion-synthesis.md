# AI 모션 합성 — 텍스트 → 모션 → DARwIn-OP

> 카메라 / 슈트 / 마커가 없어도 **자연어 한 줄** 로 사람 모션을 생성할
> 수 있다. 2022년 MDM (Tel Aviv) 이후 diffusion 기반 모션 생성이
> mainstream이 됐다. DarwinForge는 이미 Claude tool_use 통합 → 자연어
> → 모션 생성 → DARwIn-OP 매핑이 자연스러운 다음 단계.
>
> 작성일: 2026-05-10. 출처 URL 필수.

---

## 1. MDM (Motion Diffusion Model) — Tel Aviv University, SIGGRAPH 2023

Guy Tevet 외 (Tel Aviv University) 의 Motion Diffusion Model은 **classifier-free diffusion** 을 모션 시퀀스에 적용한 첫 SOTA. 텍스트 / 액션 라벨 / 음악 등 다양한 조건을 받아 SMPL 모션을 샘플링한다.

### 1.1 사양

- 모델: Transformer encoder + diffusion (DDPM 1000-step, accelerated)
- 입력: 텍스트 (CLIP 임베딩) + length token
- 출력: SMPL 22-joint 6DoF rotation, 60 fps, 최대 196 프레임
- 데이터셋: **HumanML3D** (Guo 외 2022, 14,616개 모션 + 텍스트), KIT-ML
- 라이선스: **MIT**
- 학습: 3일 / RTX 3090 (single GPU)

(출처: GitHub https://github.com/GuyTevet/motion-diffusion-model / 논문 https://guytevet.github.io/mdm-page/)

### 1.2 텍스트 예시

- "a person walks forward and waves their right hand"
- "a person performs a roundhouse kick"
- "a person dances in circles"

생성 결과는 SMPL 표준 골격 (pelvis-root, 22 joints) 의 angle-axis 또는 6D rotation 형식.

### 1.3 DarwinForge 적용 가능성

**★★ 자연어 → 모션 → 로봇 ★★** 은 우리 비전과 일치. 다만:

1. MDM은 PyTorch 기반 — Apple Silicon (MPS) 지원 가능, 그러나 추론 시간 ~10초 / 클립 (3090 기준)
2. SMPL 22 joints → DARwIn-OP 20 DOF 리타겟 필요 (다음 문서)
3. 초기에는 **사전 생성된 라이브러리** 가 더 실용적 — MDM으로 1000개 모션 미리 합성, 임베딩 검색

> ★ 차용 1 (장기): forge-core::mocap::mdm_client 가 Python subprocess
> 또는 ONNX Runtime으로 MDM 추론 호출. SwiftUI에서 "Claude, 인사
> 동작을 만들어줘" → MDM "wave" 합성 → retarget → 미리보기.

---

## 2. MotionGPT — OpenMotionLab, NeurIPS 2023

OpenMotionLab (上海科技大学 + Fudan + Microsoft Research Asia) 의 MotionGPT는 **VQ-VAE로 모션을 토큰화** 한 뒤 **T5 LLM** 으로 번역 / 생성하는 발상.

### 2.1 사양

- 모델: VQ-VAE (모션 → discrete tokens) + T5-base (LLM)
- 입력: 자연어 텍스트 + (선택) action / motion 토큰
- 출력: SMPL 모션 (22 joints) — 텍스트와 동일한 vocabulary로 통합
- 학습: HumanML3D + 멀티태스크 (motion ↔ text 양방향)

(출처: GitHub https://github.com/OpenMotionLab/MotionGPT / 논문 https://motion-gpt.github.io/)

### 2.2 강점

- **양방향**: 텍스트 → 모션, 모션 → 텍스트 (캡셔닝)
- **편집 가능**: "insert wave at 2.5s" 같은 부분 수정
- **LLM 통합**: GPT-스타일 프롬프트 / chain-of-thought

### 2.3 DarwinForge 적용 가능성

**★★ Claude와 직접 연결 가능**. Claude 가 LLM 단에서 MotionGPT 토큰을 출력하도록 fine-tuning 한다면, "Claude, 손 흔들기" → 토큰 시퀀스 → VQ-VAE 디코더 → SMPL → DARwIn-OP가 한 흐름. 그러나 fine-tuning 비용 큼. 초기에는 MotionGPT를 별도 마이크로서비스로 보고, Claude는 "MotionGPT 호출" tool을 사용.

---

## 3. PriorMDM — MDM에 사전 조건 부과

Tel Aviv University 후속 연구 PriorMDM은 MDM 위에 **추가 조건** (시작 / 종료 자세, 키프레임 일부) 을 강제하는 식으로 더 정확한 제어를 제공한다.

### 3.1 핵심

- MDM 출력에 prior로 자세 / 위치 / 트라젝토리 강제
- "지금 자세 → 인사 → 끝 자세" 식 시점-제어된 합성 가능
- MIT 라이선스

(출처: PriorMDM https://priormdm.github.io/)

### 3.2 DarwinForge 적용 가능성

**★ 정밀 제어**. DARwIn-OP가 "현재 자세에서 → 일어서서 → 인사" 식의 **자세 사이 보간** 을 LLM 자연어로 받아야 할 때 PriorMDM 식 구조가 유용. 그러나 MDM 같은 PyTorch 의존성, 추론 시간 부담.

---

## 4. OmniControl — 다중 관절 제어 가능 MDM 확장

OmniControl (UCSD 2024) 은 MDM을 확장해 **임의의 관절을 시점별로 제어** 할 수 있게 한다. 예: "왼손은 0~3초에 정확히 (0.5, 1.2, 0.3) 위치, 나머지는 자연스럽게."

### 4.1 핵심

- MDM 위에 control branch 추가
- Sparse keypoint constraint: 임의 (joint, time, position) 튜플
- 학습된 모션 prior와 명시적 제약을 동시에 만족

(출처: OmniControl https://neu-vi.github.io/omnicontrol/)

### 4.2 DarwinForge 적용 가능성

**★ 키프레임 + AI 합성 하이브리드**. 사용자가 timeline에 핵심 키프레임 3~4개만 찍고 "사이를 자연스럽게 채워줘" 하면 OmniControl이 사이를 합성. 이는 우리 현재 sin-wave 보간보다 훨씬 자연스러움. 단, PyTorch 의존성 동일.

---

## 5. MoMask — Masked Generative Motion Model

MoMask (Carnegie Mellon 2024) 는 **Masked Autoencoder** 식으로 일부 모션 마스크 후 채우는 생성 모델. 다양한 조건 (텍스트, 부분 모션) 받음.

### 5.1 핵심

- 모션 시퀀스를 토큰화 후 일부 마스크
- Bidirectional Transformer가 채움 → 빠른 추론 (BERT 식)
- Diffusion보다 ~10배 빠른 추론

(출처: MoMask https://github.com/EricGuo5513/momask-codes)

### 5.2 DarwinForge 적용 가능성

**★ 추론 속도 우위**. DiM (Diffusion in Motion) 계열 대비 빠르므로 **인터랙티브** 사용 가능. macOS Apple Silicon Core ML 변환 가능성 (MAE는 Transformer라 ANE 친화).

---

## 6. ChatMotion — LLM ↔ Motion 통합

ChatMotion (2024) 은 LLM 대화 인터페이스에서 모션을 생성 / 검색 / 편집하는 시스템. Claude / GPT-4 같은 LLM이 "어떤 모션을 만들지" 결정하고, 백엔드 모션 생성 모델을 호출.

(출처: 논문 / 데모 다양 — "확인 필요" 권위 출처)

이 방향은 DarwinForge의 **Claude tool_use** 패턴과 가장 직접 일치. Claude가 `generate_motion(text="wave hand")` 도구를 호출 → 백엔드 (MDM/MotionGPT) → 결과 반환 → 사용자 승인 (HITL L4) → DARwIn-OP 적용.

---

## 7. Adobe Mixamo — 무료 모션 라이브러리 + 자동 리깅 ★★★

Adobe Mixamo는 AI **합성** 이 아니라 **사람이 만든 라이브러리** 지만, "자연어 검색 → FBX 다운" 의 즉시성이 너무 강해서 1순위 후보.

### 7.1 사양

- 무료 (Adobe 계정만)
- 약 **2,500+ 개 모션** (걷기, 달리기, 인사, 댄스, 무술, 엔터테인먼트)
- 자동 리깅 (사용자 캐릭터 FBX 업로드 → Mixamo 표준 65-bone rig 적용)
- 출력: **FBX** / DAE / BVH (제한 / "확인 필요")
- 키프레임 60 fps, T-pose binding

(출처: Mixamo https://www.mixamo.com/)

### 7.2 라이선스

Adobe 약관: 개인 / 상업적 사용 모두 허용 (Mixamo 모션을 자체 게임 / 영화 / 로봇 동작으로 사용 가능). 단 Mixamo 자체를 재배포 / 판매는 금지.

(출처: Adobe Mixamo Terms https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html)

### 7.3 DarwinForge 적용 가능성 — ★★★ 즉시 적용

**가장 빠른 길**. 이유:

1. 무료 + 즉시 + 2,500+ 모션 → DarwinForge 모션 라이브러리에 즉시 100~500개 추가 가능
2. FBX 표준 → forge-core::mocap::fbx_loader 한 모듈로 모두 import
3. 자연어 검색 (Mixamo 자체) 가능
4. T-pose binding 표준이라 retarget 일관성

> ★ 차용 1 (★★★ 즉시): forge-core::mocap::mixamo_importer 모듈.
> 사용자가 Mixamo에서 .fbx 다운 → DarwinForge drag & drop →
> 자동 SMPL 변환 → DARwIn-OP retarget → 라이브러리 카드 추가.

> ★ 차용 2 (★★): "Mixamo 검색 위젯" — Mixamo 비공식 API 또는
> 웹뷰 임베드. 사용자가 macOS 앱 안에서 검색 / 미리보기 / 다운로드.
> 단 Adobe 약관 검토 필요.

> ★ 차용 3 (★★★): "사전 생성 라이브러리" — Mixamo 핵심 100개 모션을
> 미리 retarget 해서 DarwinForge 기본 라이브러리에 포함. 사용자는
> 즉시 100개 사용 가능, 추가 import는 옵션.

---

## 8. CMU Motion Capture Database — 학술 표준

Carnegie Mellon University Graphics Lab의 **CMU Mocap DB** (2003~) 는 약 2,605개 모션 시퀀스를 포함하는 학술 표준. 영화 / 게임 / 로봇 학습에 광범위하게 사용.

### 8.1 사양

- 포맷: **AMC + ASF** (Acclaim 표준), C3D, BVH (변환판)
- 30개 마커 → ~31 본 골격
- 라이선스: 학술 / 상업 모두 무료 (출처 명시 의무)
- 약 2,605 trial, 109명 subject

(출처: CMU Mocap https://mocap.cs.cmu.edu/)

### 8.2 DarwinForge 적용 가능성

**★★ 학술 인용 + 무료**. AMC/ASF 파서가 추가 작업이지만, 한 번 만들면 2,605개 baseline. BVH 변환판 사용 시 즉시 import 가능 (Mixamo 다음 후보).

---

## 9. AMASS — 통합 SMPL 모션 데이터베이스

Max Planck Institute의 AMASS (2019) 는 **15개 모션 캡처 데이터셋을 SMPL로 통합** 한 메타 DB. 약 11,000+ 모션, 350+ 시간.

### 9.1 사양

- 포맷: **SMPL 표준** (numpy arrays, .npz)
- 학술 / 비상업 사용
- 데이터셋: CMU, BMLrub, KIT, EKUT, BMLmovi, ACCAD, HumanEva, MPIHDM05, MPIMoSh, SOMA 등 통합

(출처: AMASS https://amass.is.tue.mpg.de/)

### 9.2 DarwinForge 적용 가능성

**★★ 학술용**. 11,000+ SMPL 모션이 baseline. 라이선스는 학술 / 비상업 한정 — 상업적 DarwinForge 배포에는 부적합. 그러나 **연구 / 데모 목적** 에서 강력.

---

## 10. 비교 요약

### 10.1 AI 합성 vs 라이브러리

| 도구 | 종류 | 가격 | 즉시성 | DarwinForge 적합도 |
|------|------|------|--------|---------------------|
| **Mixamo** ★ | 사람 제작 라이브러리 | 무료 | 즉시 | ★★★ 1순위 |
| **CMU Mocap DB** | 학술 라이브러리 | 무료 | 즉시 | ★★★ |
| **AMASS** | 학술 통합 (SMPL) | 학술 무료 | 즉시 | ★★ |
| MDM | 텍스트 → 모션 (Diffusion) | MIT | ~10초 / 클립 | ★★ |
| MotionGPT | LLM ↔ 모션 | 비상업 | 즉시 (서버) | ★★ |
| PriorMDM | MDM + 사전조건 | MIT | ~10초 | ★ |
| OmniControl | MDM + 정밀 제어 | 연구 | ~10초 | ★ |
| MoMask | Masked Generative | MIT | ~1초 | ★★ |

### 10.2 Claude tool_use 통합 시나리오

DarwinForge가 이미 Anthropic strict tool_use 통합을 갖고 있으므로, 자연스러운 다음 단계는:

```python
# Claude가 호출할 도구 (forge-mcp 또는 SwiftUI 앱 내부)
tools = [
  {
    "name": "search_mixamo_motion",
    "description": "Mixamo 라이브러리에서 텍스트로 모션 검색",
    "input_schema": { "query": "string" }
  },
  {
    "name": "generate_motion_mdm",
    "description": "MDM 모델로 텍스트에서 모션 합성 (~10초 소요)",
    "input_schema": { "text": "string", "duration_sec": "number" }
  },
  {
    "name": "retarget_to_darwin_op",
    "description": "SMPL 모션을 DARwIn-OP 20DOF로 리타겟",
    "input_schema": { "smpl_motion_id": "string" }
  },
  {
    "name": "preview_motion",
    "description": "Walk Sim에서 미리보기",
    "input_schema": { "motion_id": "string" }
  },
  {
    "name": "save_to_library",
    "description": "모션 라이브러리에 추가 (사용자 승인 필요)",
    "input_schema": { "motion_id": "string", "name": "string" }
  }
]
```

(출처: 본 §10.2 — 본인 작성, Anthropic strict tool_use 패턴 https://docs.claude.com/en/docs/build-with-claude/tool-use)

---

## 11. ★ 차용 박스 — 우선 순위

> ★ 차용 1 (★★★ 즉시 적용): **Mixamo + CMU Mocap DB 사전 생성
> 라이브러리** — DarwinForge 1차 출시에 100~200개 모션 미리 retarget
> 해 포함. 사용자는 즉시 사용 가능.
>
> ★ 차용 2 (★★ 다음 분기): **forge-core::mocap::fbx_loader / bvh_loader**
> — Mixamo / Plask / Rokoko 결과 모두 import 가능한 표준 채널.
>
> ★ 차용 3 (★★ 후기): **forge-core::mocap::mdm_subprocess** — MDM /
> MotionGPT를 Python subprocess (또는 Apple Core ML 변환 후 Swift 직접
> 호출) 로 구동. Claude tool에 노출.
>
> ★ 차용 4 (★ 장기): **자연어 모션 검색 임베딩** — Mixamo / CMU DB
> 메타데이터를 OpenAI text-embedding-3-small 또는 sentence-transformers
> 로 임베딩. 사용자가 "춤 같은 동작" 입력 → top-k 모션 카드 표시.

---

## 12. 한국어 UX 시나리오

```
사용자: "다음 동작을 만들어줘 — 손 흔들면서 인사"
Claude:  도구 호출 search_mixamo_motion("waving hello")
        → 5개 결과 (썸네일 + 길이)
사용자:  "두 번째가 좋아요"
Claude:  도구 호출 retarget_to_darwin_op("Mixamo_Wave_Hello_2")
        → 미리보기 영상 (Walk Sim)
사용자:  "조금 더 천천히 했으면"
Claude:  도구 호출 retime_motion(speed=0.7)
사용자:  "저장해주세요"
Claude:  도구 호출 save_to_library(name="인사_Mixamo_Wave_2")
        → HITL approve / edit / reject (L4)
```

(출처: 본 §12 — 본인 작성)

---

## 13. 정리

AI 합성 (MDM 계열) 은 학술적 가능성이 크지만 **추론 시간 / 의존성 / 정확도** 에서 즉시 도입은 부담. **Mixamo + CMU Mocap DB** 의 사전 라이브러리 + retarget 파이프라인이 1순위. Claude가 자연어로 라이브러리를 검색하고 추천하는 식의 UX가 우리 강점과 가장 자연스럽게 결합. 다음 문서 [04-retargeting-pipeline-for-darwin-op.md](04-retargeting-pipeline-for-darwin-op.md) 에서는 SMPL → DARwIn-OP 20-DOF 리타겟의 알고리즘 상세를 다룬다.

(출처: 본 §13 결론 — 본인 작성)
