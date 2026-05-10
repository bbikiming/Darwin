# Google Gemini — 대화 + Deep Research

## 핵심 UI 요소

### 1. Empty state with suggestion chips ★★★ (★ 우리 채용 출처)

화면 비어있을 때 4개의 대표 명령 칩 표시. 클릭하면 자동 입력.
DarwinForge `EmptyState.swift` 가 직접 차용.

```swift
// 우리 구현
let suggestions: [(icon: String, text: String)] = [
    ("hand.wave",        "로봇 깨워줘"),
    ("figure.walk",      "앞으로 두 보 걸어줘"),
    ("camera.viewfinder","현재 자세 캡처해줘"),
    ("pause.circle",     "모든 토크 꺼줘"),
]
```

### 2. Deep Research 모드

긴 작업(여러 분 소요)을 백그라운드에서 처리. 진행률 + 단계별 로그 + 최종
보고서. DarwinForge 적용 후보:
- "오늘 모터 상태 모두 점검해줘" → 16관절 BULK_READ + 온도/전압 그래프 →
  보고서 형태로 출력

### 3. Multimodal (이미지 + 비디오 입력)

비디오 분석 가능. DarwinForge에선 카메라 입력 (Sprint 6 vision 통합 후)을
Claude로 직접 분석 — "공이 보여? 어디 있어?".

### 4. Live (1.5 Live API)

실시간 음성 + 비디오. GPT-4o realtime과 유사. 휴머노이드의 경우 Live가
가장 자연스러움.

## DarwinForge 차용

★★★ — Suggestion chips (이미 적용)
★★ — Deep Research 패턴 (Sprint 8 후보 — 모터 헬스 종합 보고서)
★★ — Live (Sprint 9+ — 카메라 통합 후)

## 출처

- Gemini: https://gemini.google.com
- Deep Research: https://blog.google/products/gemini/google-gemini-deep-research/
- Live API: https://ai.google.dev/gemini-api/docs/live
