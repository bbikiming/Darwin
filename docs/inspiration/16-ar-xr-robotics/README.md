# 16. AR / XR + 로봇

> Apple Vision Pro, Microsoft HoloLens, Meta Quest 등 헤드셋 + 휴머노이드
> 결합. 미래 시연 / 디버깅 / 원격 조작.

## 핵심 사례

### 1. Apple Vision Pro ★★

| 항목 | 내용 |
|------|------|
| 출시 | 2024-02 (US) / 2024 점진 글로벌 |
| 가격 | $3,499 |
| OS | visionOS |
| 개발 | Xcode + Reality Composer Pro |
| 입력 | 시선 + 손 추적 (no controller, no Vision Pro 2 일부 controller) |

DarwinForge 시나리오:
- DARwIn-OP 3D 모델을 Reality Composer Pro에 임포트 (USDZ)
- Vision Pro 앱이 실 로봇과 mirror — Mac DarwinForge가 WebSocket으로
  joint state 송신, Vision Pro에서 가상 모델이 실 로봇 자세 따라감
- 시연 / 교육에서 강력 (관객은 로봇 옆에서 + Vision Pro로 동시 자세 확인)

### 2. Meta Quest 3

| 항목 | 내용 |
|------|------|
| 가격 | $499 (much cheaper) |
| 개발 | Unity / Unreal |

DarwinForge 시나리오: Vision Pro와 동일하나 가격 진입 장벽 낮음.

### 3. Microsoft HoloLens 2 (단종 진행 중)

산업용 AR. 2024년 단종 발표. 후속 미정.

### 4. Apple ARKit (iOS) — 휴머노이드 학습

iPhone만으로 사용자 자세 캡처 → DARwIn-OP retarget. (`12-mocap-and-retargeting/02-markerless-and-mobile.md` 참조)

## DarwinForge AR 시나리오 — 구체

### 시나리오 — 실시간 로봇 자세 미러링

```
DarwinForge.app (Mac) ─→ WebSocket (joint states 50Hz)
                              ↓
                       Vision Pro 앱 (visionOS)
                              ↓
                    DARwIn-OP USDZ 모델 자세 갱신
                              ↓
                  관객이 실 로봇 옆에서 가상 모델로 시각화
```

신규 코드:
- Mac 측: `forge-core::ws_server` (axum 또는 tungstenite)
- Vision Pro 측: 별도 visionOS 앱 (Swift), 서버에 WebSocket 연결

### 시나리오 — Mocap 입력

Vision Pro의 손 / 신체 추적으로 사용자가 자세를 시범하면 DARwIn-OP가
실시간 따라함. 단, 빠른 동작은 모터 한계로 위험 → 속도 제한 필수.

## 차용 우선순위

★★ — 시연 / 교육 가치 매우 큼. 단, Vision Pro 자체가 비싸서 1순위는 아님.
Sprint 12+ 후보.

## 출처

- Apple Vision Pro 개발: https://developer.apple.com/visionos/
- Reality Composer Pro: https://developer.apple.com/augmented-reality/reality-composer-pro/
- Meta Quest 3: https://www.meta.com/quest/quest-3/
