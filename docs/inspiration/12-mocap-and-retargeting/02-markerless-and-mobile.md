# Markerless / 모바일 모션 캡처 — DarwinForge 적용 가능성

> "마커도 슈트도 없이, 평상복 입고 카메라 한두 대 앞에 서면 끝"
> — 2018년 OpenPose 이후 컴퓨터 비전 + 트랜스포머 + 소형 모델 발전이
> markerless를 mainstream으로 끌어올렸다. DarwinForge가 macOS 네이티브
> 앱이라는 점이 결정적 — **iPhone Pro 한 대로 사람 동작 → DARwIn-OP**
> 가 가능하다.
>
> 작성일: 2026-05-10. 출처 URL 필수.

---

## 1. DeepMotion Animate 3D — 클라우드 비디오 → 3D

미국 LA 기반 DeepMotion (2014~) 은 단일 비디오 클립을 업로드하면 SMPL 골격으로 풀어내는 클라우드 SaaS. 게임 / 인디 영화 / VTuber 가 주 사용자.

### 1.1 사양

- 입력: **단일 비디오** (mp4 / mov / webm), 720p~4K, 최대 5분
- 처리: 클라우드 (자체 트랜스포머 + IK 솔버 — 모델 비공개)
- 출력: **FBX** / **BVH** / **glTF** / **Unity HumanIK** / **Unreal**
- 정확도: 중상 (시각적 OK, 의생체역학 부적합)
- 가격: **Freemium** ($0 ~ $25/월, 분당 크레딧)
- API: REST + 웹훅 (Studio Plan 이상)

(출처: DeepMotion https://www.deepmotion.com/animate-3d)

### 1.2 추가 기능

- **Hand Tracking**: 손가락 21점
- **Face Tracking**: 52 blendshape (Apple ARKit 호환)
- **Multi-Person**: 동일 클립 내 다인 분리

### 1.3 DarwinForge 적용 가능성

**★★ 클라우드 의존**. macOS 앱에서 비디오 업로드 → 1분 대기 → FBX 다운 → 리타겟. 사용자가 인터넷 + 계정 / 결제를 갖춰야 함. 오프라인 / 프라이버시 필요한 경우 부적합. 그러나 "한 번 시범 보이고 싶은 동작" 이 있을 때 빠른 길.

---

## 2. RADiCAL Motion — 모바일 우선

RADiCAL (NYC, 2017~) 은 모바일 앱이 주력. iPhone / Android에서 직접 촬영 + 업로드 + 결과 확인 워크플로우.

### 2.1 사양

- 입력: 모바일 라이브 또는 비디오 업로드
- iOS / Android 앱 (RADiCAL Motion)
- 출력: **FBX** / **BVH** / Maya / Blender 플러그인
- 가격: $19/월~ (개인 / 팀)
- API: 있음 (사이트 인증 후)

(출처: RADiCAL https://radicalmotion.com/)

### 2.2 DarwinForge 적용 가능성

**★ DeepMotion과 유사**. 모바일 우선이지만 macOS에서 직접 호출은 어려움. 사용자가 iPhone에서 RADiCAL → BVH export → DarwinForge import. 두 단계가 됨.

---

## 3. Plask AI — 한국팀, 비디오 기반

Plask Inc. (서울, 2019~) 은 한국 스타트업으로 Plask Motion (구 Plask AI) 을 운영. 단일 비디오 업로드 + 간단한 GUI 편집.

### 3.1 사양

- 입력: 비디오 업로드 (mp4)
- 처리: 클라우드, "Plask Engine" (자체)
- 출력: **FBX** / **BVH** / glTF
- 가격: Freemium (Pro $15/월~)
- 한국어 UI / 지원

(출처: Plask https://plask.ai/)

### 3.2 DarwinForge 적용 가능성

**★★ 한국팀이라는 강점**. 같은 한국 시장 / 시간대 / 언어. 사업 협력 / 한국어 지원 채널 우호적일 수 있음. API 직접 통합은 미공개 — "확인 필요". 사용자가 Plask 결과 BVH export → DarwinForge import 경로가 현실적.

---

## 4. Move.ai — multi-camera markerless ★

영국 Move.ai (2020~) 은 **여러 대의 모바일 카메라**를 동기화해 마커 없이 광학급 정확도를 노리는 도전. 단일 카메라 (Move One) + 다중 카메라 (Move Pro) 구성.

### 4.1 사양

| 모드 | 카메라 수 | 정확도 | 가격 |
|------|-----------|--------|------|
| Move One | 1 (iPhone) | 중상 | $15/월 |
| Move Pro | 2~6 (iPhone) | 상 (광학 근접) | $365/월~ |
| Move Live | 다중 + 실시간 | 상 (실시간) | 별도 견적 |

- 출력: **FBX** / **BVH** / glTF / USD
- iOS 앱 + 클라우드 처리

(출처: Move.ai https://www.move.ai/)

### 4.2 DarwinForge 적용 가능성

**★ 정확도 우위, 그러나 워크플로우 복잡**. Move Pro는 iPhone 2~6대 + 동기화 + 클라우드 업로드의 다단계 워크플로우. macOS 앱 통합은 큰 작업. Move One (1대) 만 노리되, 그 영역은 ARKit Body Tracking과 직접 경쟁.

---

## 5. Apple ARKit Body Tracking ★★★ — DarwinForge 1순위

Apple이 iOS 13 (2019) 에서 ARKit 3에 추가한 ARBodyTrackingConfiguration. iOS 17 / iOS 18에서 지속 강화. **iPhone Pro / iPad Pro의 LiDAR + Apple Neural Engine** 으로 실시간 91-joint 3D 골격 추적.

### 5.1 사양

| 항목 | 값 |
|------|-----|
| 지원 기기 | iPhone XS 이상 (LiDAR 권장 — Pro 12+) / iPad Pro M4 |
| 모델 | ARSkeleton3D (91 joints, hierarchical) |
| 프레임률 | 60 fps (iPhone 15 Pro+ 에서 안정) |
| API | ARBodyTrackingConfiguration / ARBodyAnchor |
| 가격 | **무료** (Apple Developer 계정만) |
| 정확도 | 중 (관절 5~10° 오차, 전신 1~3 cm 위치) |

(출처: Apple Developer https://developer.apple.com/documentation/arkit/arbodytrackingconfiguration)

### 5.2 ARSkeleton3D 골격

91개 관절은 SMPL 23보다 풍부 (얼굴 5, 손가락 30 포함). 핵심 본은:

```
root
├── hips
│   ├── left_upLeg → left_leg → left_foot → left_toes
│   └── right_upLeg → right_leg → right_foot → right_toes
├── spine_1 → spine_2 → spine_3 → spine_4 → spine_5 → spine_6 → spine_7
│   ├── neck_1 → neck_2 → neck_3 → neck_4 → head
│   ├── left_shoulder_1 → left_arm → left_forearm → left_hand
│   │   └── (left_handIndexStart → ... 5개 손가락)
│   └── right_shoulder_1 → ... (대칭)
```

(출처: Apple ARSkeleton.JointName https://developer.apple.com/documentation/arkit/arskeleton/jointname)

### 5.3 RealityKit / Vision 통합

- **RealityKit**: BodyTrackedEntity로 캐릭터에 자동 바인딩 가능
- **Vision** Framework: VNHumanBodyPose3DObservation (iOS 17+, RGB만으로도 3D 추정)

iOS 17 이후 **Vision-only** (LiDAR 없이) 도 가능 — VNDetectHumanBodyPose3DRequest. 그러나 LiDAR가 있을 때 정확도 차이 큼 (Z축 깊이).

### 5.4 macOS 통합 — Continuity Camera

macOS Sonoma (14+) 의 **Continuity Camera** 는 iPhone을 macOS의 카메라로 즉시 사용 가능 (USB / Wi-Fi 둘 다). DarwinForge에서:

```
[macOS DarwinForge]
   ↓ AVFoundation으로 Continuity Camera 선택
[iPhone 카메라 영상 macOS로 스트림]
   ↓ 그러나 ARKit 자체는 iOS에서 실행, 결과만 macOS로
[iPhone에서 ARKit Body Tracking 실행]
   ↓ Multipeer Connectivity 또는 Sharing API
[macOS DarwinForge가 ARSkeleton3D 91 관절 수신]
   ↓ forge-core::mocap::arkit_to_smpl
[SMPL 23 joint quaternion]
   ↓ retarget
[DARwIn-OP 20 DOF]
```

핵심 인사이트: ARKit Body Tracking은 **iPhone 본체에서만 실행 가능**. macOS 측은 결과를 받기만 함. 두 가지 구현 옵션:

1. **DarwinForge Companion (iOS 앱)**: SwiftUI iOS 앱에서 ARKit 실행, Multipeer Connectivity (또는 Network framework) 로 macOS에 스트림
2. **Continuity Camera + Vision** (macOS 14.4+): macOS에서 Vision의 VNDetectHumanBodyPose3DRequest 직접 호출 가능 (LiDAR 미지원이라 정확도 낮지만 Companion 앱 불필요)

### 5.5 DarwinForge 적용 가능성 — ★★★ 1순위

**가장 자연스럽다**. 이유:

1. iPhone 보유율 (한국 시장 50%+) → 추가 비용 0
2. ARKit / RealityKit / Vision 모두 Swift / SwiftUI 네이티브 → 우리 스택과 100% 일치
3. Continuity Camera로 Mac과 즉시 페어링
4. 사용자 데이터가 Apple 디바이스 내부에서만 처리 → **프라이버시** 강점
5. iOS 17 Vision API가 LiDAR 없이도 동작 → 진입 장벽 낮음

> ★ 차용 1 (★★★): **DarwinForge Companion** iOS 앱 신설.
> SwiftUI + ARKit body tracking. macOS 앱과 Multipeer Connectivity로
> 페어링. Companion이 iPhone 카메라로 사람을 보고, 91 joint 시계열을
> macOS로 60 Hz 스트림. macOS forge-core::mocap::arkit_listener 가
> 수신, SMPL → DARwIn-OP 리타겟 후 라이브 따라하기.

> ★ 차용 2 (★★): **macOS-only 모드** — Continuity Camera + Vision
> framework. 사용자가 Companion 앱 설치 없이도 iPhone을 USB로 연결
> 후 macOS에서 직접 실행. 정확도 낮지만 즉시성.

(출처: Apple Continuity Camera https://support.apple.com/en-us/HT213244 / Vision VNDetectHumanBodyPose3DRequest https://developer.apple.com/documentation/vision/vndetecthumanbodypose3drequest)

---

## 6. Apple Vision Pro — Hand / Body Tracking

Apple Vision Pro (2024~) 의 visionOS는 **자체 Hand Tracking + Body Tracking** API를 제공. 단, 일부 API는 Enterprise 한정.

### 6.1 Hand Tracking

- ARKit visionOS 의 `HandAnchor` / `HandSkeleton`
- 26개 관절 / 손, 양손 동시
- 60 Hz, 사용자 동의 후 사용
- API: `HandTrackingProvider` (visionOS 2.0+)

(출처: Apple HandTrackingProvider https://developer.apple.com/documentation/arkit/handtrackingprovider)

### 6.2 Body / Object 추적

visionOS 2.0 부터 `WorldTrackingProvider` + `ObjectTrackingProvider` 도입. **사람 신체 전체 추적 API는 visionOS Enterprise에서만 (또는 미공개) — 확인 필요**.

### 6.3 DarwinForge 적용 가능성 — ★★

VP 가격 ($3,499) + 사용자 모수 한정. 그러나 **Hand tracking** 만으로도 DARwIn-OP의 손 / 어깨 모션 시연이 가능. forge-core::mocap::vision_pro_hands 모듈 가능. visionOS 앱 + macOS 앱 페어링 시나리오.

---

## 7. 기타 markerless / 데스크탑 솔루션

### 7.1 OpenPose / MediaPipe / MMPose (오픈소스 기반)

- **OpenPose** (CMU 2017): COCO 17 keypoints / Body 25, MIT 라이선스 with 상업 제한
- **MediaPipe Pose / Holistic** (Google): TFLite 기반, 33 keypoints, Apache 2.0
- **MMPose / MMHuman3D** (OpenMMLab): SMPL 추정 SOTA, Apache 2.0

(출처: MediaPipe https://developers.google.com/mediapipe / MMPose https://github.com/open-mmlab/mmpose)

DarwinForge 적용도 **★★ 기술 호기심**. macOS / Apple Silicon용 Core ML 변환 → on-device 추론 가능. 그러나 ARKit 대비 **카메라 보정 / 깊이 / 안정성** 떨어짐.

### 7.2 Sony Mocopi

Sony Mocopi (2023~) 은 6개 IMU + 스마트폰 앱으로 IMU / 모바일 하이브리드. 가격 $359. macOS 직접 통합은 어렵지만 **BVH export** 지원 → 표준 import 경로.

(출처: Sony Mocopi https://www.sony.net/Products/mocopi-dev/en/)

---

## 8. 비교 요약

### 8.1 DarwinForge 관점 비교

| 솔루션 | 입력 | 정확도 | 비용 | macOS 통합 | DarwinForge 적합도 |
|--------|------|--------|------|------------|---------------------|
| **Apple ARKit Body** | iPhone Pro | 중 | 무료 | ★★★ 네이티브 | ★★★ |
| **Apple Vision** | macOS 14.4+ | 중하 | 무료 | ★★★ 네이티브 | ★★ |
| Apple Vision Pro Hand | VP | 상 | $3,499 | ★★ visionOS 앱 | ★★ |
| Move.ai Move One | iPhone | 중상 | $15/월 | ★ FBX export | ★ |
| DeepMotion Animate 3D | 비디오 | 중상 | $25/월 | ★ FBX export | ★★ |
| RADiCAL Motion | 모바일 | 중 | $19/월 | ★ FBX export | ★ |
| Plask AI (한국) | 비디오 | 중 | $15/월 | ★ FBX export | ★★ |
| OpenPose / MediaPipe | 비디오 | 중 | 오픈 | ★★ Core ML | ★★ |

### 8.2 Apple 생태계 통합 우위

DarwinForge의 가장 큰 차별점은 **macOS 네이티브 SwiftUI** 라는 점. 이 강점을 살려 Apple ARKit / Vision 생태계를 **1순위**로 다루고, 나머지는 BVH / FBX 표준 import로 간접 지원.

---

## 9. ★ 차용 박스 — 즉시 적용

> ★ 차용 1 (1순위): **DarwinForge Companion (iOS)** — SwiftUI iOS 앱.
> ARKit Body Tracking으로 iPhone Pro 카메라로 사람 동작 캡처, 91-joint
> SMPL-like 골격을 Multipeer Connectivity (또는 Network framework) 로
> macOS DarwinForge에 60 Hz 스트림. macOS 측 `MocapView` 가 라이브
> 실루엣 + 동기화된 DARwIn-OP 시뮬 동시 표시.

> ★ 차용 2 (2순위): **macOS Vision-only fallback** — Companion 앱
> 미설치 시 Continuity Camera + VNDetectHumanBodyPose3DRequest 로
> macOS만으로 동작. 정확도는 떨어지지만 진입 장벽 0.

> ★ 차용 3: **forge-core::mocap::arkit** Rust 모듈 — Swift 측에서
> 변환된 SMPL skeleton frames (JSON / FlatBuffers) 를 받아 retarget
> 파이프라인 진입. 이는 04-retargeting-pipeline-for-darwin-op.md
> 에서 상세.

> ★ 차용 4: **BVH 표준 import drop zone** — DeepMotion / RADiCAL /
> Plask / Move.ai / Sony Mocopi 결과를 사용자가 .bvh / .fbx 로 export
> 하면 DarwinForge에 drag & drop. 이로써 모든 markerless 도구를 간접
> 지원.

(출처: 본 §9 — 본인 작성)

---

## 10. macOS DarwinForge 설계 시나리오

### 10.1 사용자 스토리 — "1분 만에 인사 동작"

```
1. 사용자: macOS DarwinForge 실행 → "동작 시범" 메뉴
2. 앱: "iPhone과 페어링하시겠어요?" QR 코드 표시
3. 사용자: iPhone에서 DarwinForge Companion 앱 → QR 스캔
4. 자동 페어링 (Multipeer Connectivity, ~3초)
5. iPhone 화면: "10초 카운트다운, 인사 동작을 보여주세요"
6. 사용자: 손 흔들기, 90° 절
7. iPhone: ARKit이 60 Hz로 91-joint 시계열 macOS로 송신
8. macOS DarwinForge: 라이브 retarget preview (DARwIn-OP 실루엣)
9. 캡처 종료 → "이름을 입력하세요" → "인사_시범_01"
10. 모션 라이브러리에 카드 자동 추가
```

총 소요시간: **약 1분**. 추가 하드웨어: iPhone (사용자 보유). 추가 비용: 0.

### 10.2 한국어 UX 텍스트

- "동작 시범" (button)
- "iPhone과 페어링" (sheet title)
- "10초 동안 동작을 보여주세요" (instruction)
- "동작이 너무 빨라요. 다시 시도해주세요." (validation)
- "사람 시범과 로봇 동작이 다를 수 있어요." (disclaimer, retarget 한계)

(토스 8원칙 + 해요체 — 우리 스타일 가이드 따름)

---

## 11. 정리

ARKit Body Tracking (iPhone Pro) 이 DarwinForge에 가장 자연스러운 markerless 채널이다. Companion iOS 앱 + macOS Multipeer 페어링이 1주~2주 작업으로 가능하며, 사용자 진입 장벽이 0. BVH / FBX 표준 import는 클라우드 SaaS (DeepMotion, Plask 등) 호환을 위한 보조 채널. 다음 문서 [03-ai-motion-synthesis.md](03-ai-motion-synthesis.md) 에서는 카메라조차 없이 **자연어로 모션을 생성** 하는 AI 합성 모델을 다룬다.

(출처: 본 §11 결론 — 본인 작성)
