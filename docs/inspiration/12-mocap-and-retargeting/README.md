# 12. 모션 캡처 시스템 + 휴머노이드 모션 리타겟팅

> DarwinForge는 ROBOTIS DARwIn-OP / OP2 (20-DOF 데스크탑 휴머노이드) 의
> 모션을 macOS SwiftUI 앱에서 저작한다. 현재는 키프레임 + sin파 워크
> 만으로 동작을 만들지만, 사람이 직접 시범을 보이면 그대로 로봇이
> 따라하도록 만들 수 있다면 학습 곡선이 극적으로 낮아진다.
>
> 본 카테고리는 **사람의 모션을 캡처해서 DARwIn-OP에 옮기는 파이프라인**
> 을 위해 세계의 모션 캡처 도구·기법·표준을 조사한다. 광학 / IMU /
> markerless / AI 합성 / 리타겟팅 / 표준 포맷 6분야로 구성.
>
> 모든 항목 끝에 출처 URL. 미확인은 "확인 필요" 명시. 추측 금지.
> 작성일: 2026-05-10.

---

## 인덱스

| 파일 | 주제 | 분량 |
|------|------|------|
| [01-optical-and-imu.md](01-optical-and-imu.md) | 광학 (Vicon/OptiTrack) + IMU (Rokoko/Xsens) 슈트 | ~1500 단어 |
| [02-markerless-and-mobile.md](02-markerless-and-mobile.md) | DeepMotion / Plask / Move.ai / **Apple ARKit Body Tracking** | ~1500 단어 |
| [03-ai-motion-synthesis.md](03-ai-motion-synthesis.md) | MDM / MotionGPT / PriorMDM / OmniControl / Mixamo | ~1500 단어 |
| [04-retargeting-pipeline-for-darwin-op.md](04-retargeting-pipeline-for-darwin-op.md) | SMPL → DARwIn-OP 매핑, HumanPlus / OmniH2O, Rust forge-core::mocap 설계 | ~2000 단어 |

---

## 분류 비교표

### 가) 광학 모션 캡처 (전문급, 스튜디오 고정)

| 시스템 | 정확도 (mm) | 가격 | 마커 | 무선 | SDK | DarwinForge 적합도 |
|--------|-------------|------|------|------|-----|---------------------|
| Vicon Vantage / Valkyrie | 0.1~0.5 | $50K~250K+ | 수동 패시브 | △ (slate) | Datastream / Tracker | △ 연구실 한정 |
| OptiTrack PrimeX | 0.2~1.0 | $20K~150K | 수동 패시브 | △ | Motive + NatNet | ★ 대학 보유 시 |
| Motion Analysis Raptor | 0.5~1.0 | $50K+ | 수동 패시브 | × | Cortex | △ |
| Qualisys Miqus / Arqus | 0.2~1.0 | $30K~200K | 수동 패시브 | △ | QTM | △ |
| PhaseSpace Impulse | 0.5~2.0 | $20K~100K | 능동 LED | ○ | OWL | △ |

(출처: 각 제조사 공식 사이트 — 본문에서 인용)

### 나) IMU / 무선 모션 캡처 (저가·이동식)

| 시스템 | 정확도 | 가격 | 센서 수 | 무선 | 출력 | DarwinForge 적합도 |
|--------|--------|------|---------|------|------|---------------------|
| **Rokoko Smartsuit Pro II** ★ | 1~2° (관절) | $2,495 | 19 IMU | ✓ Wi-Fi | LiveStream / FBX / BVH | **★★★ 1순위** |
| **Xsens MVN Awinda** | 0.5~1° | $12K~25K | 17 IMU | ✓ 무선 | MVNX / BVH / FBX | ★★ 정확도 최고 |
| Perception Neuron Studio | 1~3° | $1,500~3,000 | 17~32 IMU | ✓ | BVH / FBX | ★★ 가성비 |
| SHADOW Motion Capture | 1~2° | $5,000~15,000 | 17 IMU | ✓ | BVH / C3D | ★ |

(출처: Rokoko https://www.rokoko.com/products/smartsuit-pro / Movella Xsens https://www.movella.com/products/mocap-pro/xsens-mvn-awinda)

### 다) Markerless / 모바일 (의상 무관)

| 시스템 | 입력 | 정확도 | 가격 | DarwinForge 적합도 |
|--------|------|--------|------|---------------------|
| DeepMotion Animate 3D | 단일 비디오 | 중상 | $25/월~ | ★★ 클라우드 |
| RADiCAL Motion | 모바일 비디오 | 중 | $19/월~ | ★ |
| Plask AI (한국) | 비디오 | 중 | freemium | ★★ 한국팀 |
| Move.ai Move One / Pro | 1~6 카메라 | 상 | $15/월~ | ★ |
| **Apple ARKit Body Tracking** ★ | iPhone 단독 | 중 (실시간) | **무료** (iPhone Pro+) | **★★★ 1순위** |
| Apple Vision Pro Hand/Body | VP 단독 | 상 | VP 가격 | ★★ |

(출처: Apple Developer ARKit https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration)

### 라) AI 모션 합성 (텍스트/제어 → 모션)

| 도구 | 입력 | 백본 | 라이선스 | DarwinForge 적합도 |
|------|------|------|----------|---------------------|
| MDM (Motion Diffusion Model) | 텍스트 / 액션 | Diffusion Transformer | MIT | ★★ |
| MotionGPT | 자연어 | LLM + VQ-VAE | 비상업 연구 | ★★ |
| PriorMDM | 텍스트 + 사전조건 | MDM 위 | 동일 | ★ |
| OmniControl | 다중 관절 제어 | MDM 확장 | 연구 | ★ |
| MoMask | 텍스트 → 마스크 | MAE | MIT | ★ |
| **Adobe Mixamo** ★ | 라이브러리 + 자동 리깅 | (검색식 + IK) | 무료 (FBX 다운로드) | **★★★ 즉시 적용** |

(출처: GuyTevet/MDM https://github.com/GuyTevet/motion-diffusion-model / OpenMotionLab/MotionGPT https://github.com/OpenMotionLab/MotionGPT / Mixamo https://www.mixamo.com/)

### 마) 리타겟팅 도구 / 알고리즘

| 도구 / 논문 | 종류 | DarwinForge 적합도 |
|-------------|------|---------------------|
| Autodesk MotionBuilder | 수동 GUI 리타겟 (산업 표준) | ★ 외부 사용 후 import |
| Maya HumanIK | 캐릭터 리그 IK | ★ |
| Blender Auto-Rig Pro / Rigify | 오픈소스 리그 | ★★ |
| Unreal Live Link | 실시간 스트리밍 | ★ |
| Unity Mecanim / Animation Rigging | 게임 리타겟 | ★ |
| **DeepMimic** (Berkeley 2018) | 물리 + RL 모방 | ★★ |
| **AMP (Adversarial Motion Priors)** | GAN + RL | ★★ |
| **PHC** (CMU) | 물리 휴머노이드 컨트롤 | ★★ |
| **HumanPlus** (Stanford 2024) ★ | 사람 → 휴머노이드 zero-shot | **★★★ 차용 1순위** |
| **OmniH2O** (CMU/MIT 2024) | 사람-휴머노이드 universal | ★★★ |
| **Expressive Whole-Body Control** (CMU 2024) | 표현형 전신 제어 | ★★ |

(출처: HumanPlus https://humanoid-ai.github.io/ / OmniH2O https://omni.human2humanoid.com/)

### 바) 표준 포맷

| 포맷 | 발원 | 용도 | DarwinForge 차용 |
|------|------|------|-------------------|
| **BVH** | Biovision (1990s) | 골격 + 모션 텍스트 표준 | ★★★ 1순위 import |
| **FBX** | Autodesk | 산업 통용 바이너리 | ★★ Mixamo 호환 |
| **glTF + animations** | Khronos | 웹 표준 | ★★ 미래 |
| **USD** | Pixar / NVIDIA | Isaac Sim 통합 | ★★ |
| C3D | Vicon (Biomech) | 마커 좌표 시계열 | ★ |
| AMC + ASF | CMU | CMU 모션 DB 기본 포맷 | ★ DB 사용 시 |

(출처: BVH 사양 https://research.cs.wisc.edu/graphics/Courses/cs-838-1999/Jeff/BVH.html / glTF https://www.khronos.org/gltf/)

---

## DarwinForge에 가장 가능성 있는 파이프라인 — 3개

### 파이프라인 A — "iPhone 1대 시범" (★★★ 가장 빠른 길)

```
사용자 iPhone 카메라 (Continuity Camera)
    ↓ (ARKit Body Tracking - ARSkeleton3D, 91 joints)
macOS DarwinForge 앱 (LAN AVFoundation 또는 RealityKit Sharing)
    ↓ (forge-core::mocap::arkit_to_smpl)
SMPL-like 23 joints
    ↓ (forge-core::mocap::retarget)
DARwIn-OP 20 DOF
    ↓ (forge-core::motion::page)
.mtn 페이지 + 라이브러리 추가
```

장점: 추가 하드웨어 0 원, macOS Continuity Camera (Sonoma+) 와 자연스럽게 결합. 단점: ARKit Body Tracking은 iPhone Pro급 LiDAR 필요, 정밀도 (관절 5° 이상 오차) 가 산업급 IMU에 미달.

### 파이프라인 B — "Mixamo 라이브러리 임포트" (★★★ 즉시 적용)

```
Mixamo (Adobe) 검색 "wave" / "kick" / "dance"
    ↓ (FBX 다운로드, T-pose binding)
DarwinForge 임포트 (forge-core::mocap::fbx_loader)
    ↓ (FBX → glTF → SMPL skeleton 추정)
SMPL → DARwIn-OP 리타겟
    ↓
모션 라이브러리 카드 자동 생성 (썸네일 + 메타)
```

장점: 즉시 수백 개 모션 확보, 라이선스 완화 (개인 계정 무료). 단점: 모션이 "사람 비례" 라 DARwIn-OP의 짧은 다리 / 큰 머리 비율에 자기 충돌 발생 가능 — `04-retargeting-pipeline-for-darwin-op.md` §5 참조.

### 파이프라인 C — "Rokoko Smartsuit + LiveStream" (★★ 연구실용)

```
Rokoko Smartsuit Pro II (19개 IMU)
    ↓ (Rokoko Studio app, USB / Wi-Fi)
LiveStream API (UDP, JSON / Custom Binary, 60-100 Hz)
    ↓ (forge-core::mocap::rokoko_stream Tokio listener)
SMPL → DARwIn-OP 리얼타임 리타겟
    ↓
DARwIn-OP 즉시 따라하기 (50 Hz BulkRead/Write 한도 내)
```

장점: 정확도 1~2°, 시연 즉각성 (라이브). 단점: 슈트 가격 $2,495, 사람 18-19개 IMU 부착 시간 ~10분.

(출처: Rokoko LiveStream API https://github.com/Rokoko/rokoko-studio-live-blender / Apple ARKit https://developer.apple.com/documentation/arkit/capturing-body-motion-in-3d / Mixamo https://www.mixamo.com/)

---

## 우선 순위 — DarwinForge 차용 1~3순위 (요약)

| 순위 | 도구 | 차용 핵심 |
|------|------|-----------|
| ★★★ 1순위 | **Apple ARKit Body Tracking** | iPhone 한 대로 사람 동작 → DARwIn-OP. macOS DarwinForge에 Continuity Camera 모듈 추가 |
| ★★★ 1순위 | **Adobe Mixamo + FBX import** | 수백 개 모션 즉시 라이브러리화. forge-core::mocap::fbx_loader |
| ★★★ 1순위 | **HumanPlus / OmniH2O 알고리즘** | 사람 SMPL → 휴머노이드 리타겟의 학술 baseline |
| ★★ 2순위 | **Rokoko Smartsuit + LiveStream** | 라이브 스트리밍 데모 (행사/박람회) |
| ★★ 2순위 | **MDM / MotionGPT** | 자연어 → 모션 (Claude tool 호출 후속) |
| ★★ 2순위 | **BVH 표준 포맷** | 모든 mocap 도구의 공약수, import / export |
| ★ 3순위 | **DeepMimic / AMP** | sim-to-real 연구 단계, Webots + DARwIn-OP |

(출처: 본 README 작성 — 본 보고서, 2026-05-10)
