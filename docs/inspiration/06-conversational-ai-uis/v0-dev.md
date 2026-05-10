# v0.dev — UI 생성 인터페이스

## 한 줄 소개

Vercel의 자연어 → React/Next.js UI 생성 도구. 빠른 프로토타이핑 도구의
UX 모범.

## 핵심 UI 요소

### 1. Generate → Preview → Iterate 루프

1. 사용자: "프로필 카드 만들어줘"
2. v0: 코드 출력 + 우측에 라이브 프리뷰
3. 사용자: "더 어두운 배경" → diff 적용 → 프리뷰 갱신

DarwinForge 매핑 매우 강력:
- "팔 흔드는 동작" → Claude가 motion JSON 생성 + 3D 프리뷰 자동 재생
- "더 빠르게" → step play_time 감소 + 재실행
- "팔을 더 높이" → R_SHOULDER_PITCH 위치 +200 + 재실행

### 2. Variants (한번에 4개)

같은 명령에 4가지 변형 동시 생성, 사용자가 베스트 선택.

## DarwinForge 차용

★★ — Generate-iterate 루프 (Sprint 8 후보, Replit Agent의 변형)
★ — Variants는 모션 생성에 적용 가능 (4개 변형 모션 → 베스트 선택)

## 출처

- v0.dev: https://v0.dev
