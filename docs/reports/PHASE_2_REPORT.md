# Phase 2 — Knowledge Synthesis

## 요약

업스트림 코드(특히 ROBOTIS-OP2/op2_walking_module)와 ROBOTIS-Framework 헤더를 1차 출처로 삼아 5개의 신규 명세 문서를 작성. 기존 `dynamixel-1.0.md`와 `op1-vs-op2-matrix.md`는 검증 후 그대로 보존. 이로써 Sprint 1~5의 구현 명세가 모두 갖춰짐.

## 핵심 산출물

### 신규 명세

- `docs/protocols/dynamixel-2.0.md` — 1.0 vs 2.0 차이, 패킷 구조, CRC 다항식, **우리 코드 정책: v2 비활성**
- `docs/protocols/cm-730-740.md` — 사브컨트롤러 보드 차이, 컨트롤 테이블 전체, 펌웨어 업로드 정책 (벽돌 위험 — 사용자 명시 확인 전 금지), 부팅 순서, OP1↔OP2 분기 포인트
- `docs/motion-format/mtn-format.md` — RoboPlus Action `.mtn` 텍스트 포맷 분석 (Page/Step/Pose), 무손실 round-trip 정의, EUC-KR → UTF-8 변환 정책
- `docs/motion-format/page-format.md` — `motion_4096.bin` 메모리 레이아웃, 256페이지 × 7스텝 × 20관절 + 시간/옵션, 우리 내부 JSON 스키마
- `docs/architecture/walking-engine.md` — **업스트림 `param.yaml` 직접 발췌** (period_time=600 ms, dsp_ratio=0.1, foot_height=0.04 m, balance gains 4종), Phase 모델, IMU 피드백 루프, Sprint 5 구현 계획
- `docs/architecture/joint-conventions.md` — 20관절 ID 매핑 표, 좌표계, 각도 방향, position 단위 변환식, 보수적 안전 한계 표
- `docs/architecture/sensor-stack.md` — IMU/카메라/FSR/마이크/버튼/LED 전체, OP1/OP2 차이 (마이크 잭 OP2에서 제거 등)

### 보존 (이전 단계 작성, Phase 2에서 검증 후 그대로 사용)

- `docs/protocols/dynamixel-1.0.md` — 패킷 포맷, 명령 코드, CM/MX-28T 레지스터 맵
- `docs/architecture/op1-vs-op2-matrix.md` — 세대 비교 매트릭스

## 자기검증 결과

- [x] 신규 5개 + 보존 2개 = 7개 명세 문서 모두 존재
- [x] 미정 항목은 모두 `> TODO: needs verification` 명시 (mtn-format.md 5건, page-format.md 1건)
- [x] 모든 명세에 출처 링크 (research/ 내부 경로 + emanual URL)
- [x] 워킹 파라미터는 업스트림 `param.yaml`에서 1:1 복사 (추측 0)
- [x] Joint ID 매핑은 framework 헤더 인용 (community 문서의 ID 7/8 alt 표기는 명시적으로 거부)

## Blockers

없음. Phase 2의 mtn-format/page-format은 일부 필드 offset이 Sprint 3 시작 시 `Action.cpp`를 직접 읽어 확정하기로 함 (TODO로 남김, 진행 차단 아님).

## 다음 단계

**Phase 3 — Harness Engineering** 즉시 자율 시작:
1. `harness/op1/BOM.md`, `harness/op2/BOM.md` (부품·게이지·길이·단가)
2. `harness/shared/cable-specs.md` (호스트↔로봇 USB, 외부 SMPS, e-stop)
3. `harness/shared/mac-driver-setup.md` (FTDI VCP, CP210x, Apple In-Kernel)
4. `harness/shared/wiring-diagram.{svg,mmd}` — Mermaid로 결선도
5. `harness/shared/safety.md`
6. `scripts/harness/probe.sh`
7. ADR-006 (통신 경로), ADR-007 (전원), ADR-008 (e-stop)
