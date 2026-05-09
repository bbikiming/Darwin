# app/motion-engine/

모션 엔진. 보간·타임라인·키프레임 → 관절 각도 시퀀스.

Phase 5 Sprint 3·4에서 Rust 크레이트로 구현 (`forge-core::motion`).

## 핵심 책임

- `.mtn` (RoboPlus Action) 파일 파싱·직렬화
- 내부 JSON 포맷 정의
- 키프레임 보간 (선형, 쿠빅, 이징)
- 모션 라이브러리 (SQLite 백엔드)
