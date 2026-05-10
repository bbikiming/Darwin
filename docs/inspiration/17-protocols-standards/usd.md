# USD — Universal Scene Description (Pixar)

## 한 줄 소개

Pixar에서 시작 (2016 오픈), 현재 영화·게임·로봇 모두에서 표준화 진행.
NVIDIA Omniverse / Apple ARKit / Unity / Unreal이 모두 지원.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 출처 | Pixar Animation Studios |
| 라이선스 | Apache 2.0 (modified — Pixar Modified) |
| 확장자 | `.usd`, `.usda` (텍스트), `.usdz` (압축, AR 표준) |
| 지원 | Maya / Houdini / Blender / Unity / Unreal / Omniverse / RealityKit |

## DarwinForge 적용

### 시나리오 — DARwIn-OP을 USD로 export

```
HumaRobotics URDF (BSD-2)
  ↓ urdf2usd (NVIDIA Isaac 도구)
DARwIn-OP.usd
  ↓
다양한 도구에서 열기:
  - Apple Reality Composer Pro (macOS native)
  - Apple Vision Pro 앱
  - NVIDIA Isaac Sim
  - Blender 4.0+
  - Maya 2025+
```

### 실무적 가치

★★ — 중기. DarwinForge가 USD를 "내보내기" 포맷으로 추가하면:
- Apple Vision Pro 앱에 DARwIn-OP 임포트 → AR로 모션 미리보기
- Reality Composer Pro에서 환경과 상호작용 시연
- Isaac Sim에서 RL 학습 즉시 가능

```
forge export --format usd --output darwin-op.usdz
```

## 출처

- USD: https://openusd.org/
- Pixar USD GitHub: https://github.com/PixarAnimationStudios/OpenUSD
- Apple Reality Composer Pro: https://developer.apple.com/augmented-reality/reality-composer-pro/
- urdf2usd (NVIDIA): https://docs.omniverse.nvidia.com/extensions/latest/ext_isaacsim/ext_omni_isaac_urdf.html
