# ChatGPT — OpenAI 대화 인터페이스

## 핵심 UI 요소

### 1. Voice mode (Standard + Advanced)

- **Standard Voice** — Whisper STT → GPT-4o → TTS. 약 1초 지연.
- **Advanced Voice Mode** — 직접 음성 모달 (지연 ~300 ms). GPT-4o realtime API.

DarwinForge에 매우 중요. 로봇 cradle 잡고 있는 양손 점유 상황에서 음성
명령은 결정적.

### 2. Custom GPTs

사용자가 system prompt + tools를 묶어 "GPT" 생성. DarwinForge엔:
- "Darwin-1G GPT" / "Darwin-2G GPT" — 로봇별 시스템 프롬프트
- 또는 "Performance GPT" / "Maintenance GPT" — 모드별

### 3. Canvas (2024 도입)

긴 문서·코드를 우측 패널에 띄우고 그 안에서 인라인 편집. Claude Artifacts와
유사하지만 편집 권한이 더 강함.

### 4. Memory

대화 간 장기 메모리 (개인화). 사용자가 "내 로봇 두 대 — Darwin-1G,
Darwin-2G"를 한번 알리면 이후 모든 대화에서 인지.

### 5. DALL-E inline image generation

이미지 생성 결과를 대화 안에 직접 표시. DarwinForge 적용 예:
- "이 자세 보여줘" → 3D 렌더링 이미지 (또는 SceneKit 인라인)

## DarwinForge 차용

★★★ — Voice mode가 1순위 차용 패턴. macOS Speech Framework 또는 mlx-whisper.

★★ — Canvas 스타일 우측 패널은 Claude Artifacts와 같은 후보.

## 출처

- ChatGPT: https://chatgpt.com
- Voice mode 발표: https://openai.com/index/chatgpt-can-now-see-hear-and-speak/
- Advanced Voice (GPT-4o realtime): https://openai.com/index/introducing-the-realtime-api/
- Canvas: https://openai.com/index/introducing-canvas/
