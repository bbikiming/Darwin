# Replit Agent — 자율 코딩 에이전트

## 핵심 UI 요소

### 1. Plan 출력 + 인라인 편집

사용자 명령 → Agent가 plan을 markdown으로 출력 → 사용자가 plan 자체를
편집 (단계 추가/삭제) → 실행 시작.

### 2. 실시간 진행률

각 단계마다 spinner + 로그 + 결과. 사용자는 언제든 중단 가능.

### 3. Browser preview embedded

생성된 웹앱을 즉시 옆에 띄움. **즉각적 피드백 루프**가 핵심.

DarwinForge 매핑:
- "춤 모션 만들어줘" → Claude plan → 사용자 OK → 모션 생성 +
  **3D preview 자동 재생**
- 실 로봇 연결 시: Claude가 step 생성 → 즉시 실 로봇으로 재생 → 사용자 피드백
  ("팔을 더 들어")

## DarwinForge 차용

★★★ — Plan + 실시간 미리보기 결합. Sprint 8 후보. 우리는 3D viewer (URDF
+ SceneKit)가 그 역할.

## 출처

- Replit Agent: https://replit.com/agent
- 발표: https://blog.replit.com/agent
