# motions/

캡처·생성된 모션 라이브러리. 사용자가 GUI로 만든 모션, 임포트한 `.mtn` 파일, 기본 인사·웨이브 등.

## 형식

- `*.mtn` — RoboPlus Action 호환 (직접 로봇으로 업로드 가능)
- `*.json` — 내부 표현 (Phase 2에서 스키마 결정)
- `*.yaml` — 사람이 읽기 쉬운 변형 (선택)

## 디렉토리 (Phase 1·5에서 채워짐)

- `op1/` — OP1 전용
- `op2/` — OP2 전용
- `shared/` — 양쪽에 적용 가능
- `imported/` — 외부에서 임포트한 원본 보존
- `external/` — 외부 커뮤니티 `motion_4096.bin` 카탈로그 (4 저장소 · 6 .bin) — [README](external/README.md)
- `test/` — 우리가 생성한 테스트 모션
  - [`walk-progression-v1.bin`](test/walk-progression-v1.bin) + [`.json`](test/walk-progression-v1.json) — Sprint 5 walk-engine 진입 전 검증용 6 페이지 (slot 110~115). 프로토콜: [`docs/walk-lab/WALK_PROGRESSION_TEST.md`](../docs/walk-lab/WALK_PROGRESSION_TEST.md)
