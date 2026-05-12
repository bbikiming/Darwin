# Phase 3 — Harness Engineering

## 요약

OP1/OP2 외부 하네스 BOM, 케이블 사양, Mac 드라이버 셋업, 결선도(Mermaid), 안전 매뉴얼, 진단 스크립트, 3개 ADR 모두 완성.

## 핵심 산출물

### BOM (발주 가능 수준)
- `harness/op1/BOM.md` — 15개 부품, 5개 카테고리(통신/전원/진단/안전/보관), 합계 ~584 USD
- `harness/op2/BOM.md` — OP1 ↑ + OP2 전용 3개 (mini-HDMI, mSATA 어댑터·교체 SSD), 합계 ~640 USD

### 사양·결선·안전
- `harness/shared/cable-specs.md` — 통신/전원/e-stop 3 카테고리, 옵션 A vs B, 길이·금지 항목
- `harness/shared/mac-driver-setup.md` — FTDI·CP210x·CH340·Apple In-Kernel, Sequoia 권한 처리, 트러블슈팅 4단계
- `harness/shared/wiring-diagram.mmd` — Mermaid 결선도 (Mac ↔ SMPS ↔ LiPo ↔ E-stop ↔ Robot ↔ DXL bus ↔ Servos/FSR/Cam, U2D2 옵션 분기)
- `harness/shared/safety.md` — 매번/모션/워크엔진 작업 전 체크리스트 + 절대 금지 6항 + 사고 대응 4가지

### 도구
- `scripts/harness/probe.sh` — 4단계 진단 (Mac /dev/cu.* 후보, forge CLI 가용성, LiPo 전압, 안전 체크리스트). Mac/Linux 양쪽 graceful 동작.

### ADR (3개)
- `ADR-006-communication-path.md` — CM 직결 USB가 1차, U2D2는 진단 모드만
- `ADR-007-power-strategy.md` — 단계별 권고 (Phase 4~Sprint 4 = SMPS, Sprint 5 = LiPo)
- `ADR-008-estop-topology.md` — 인라인 SPDT 토글이 1차, 소프트 e-stop은 보조

## 자기검증 결과

- [x] BOM이 발주 가능 수준 (Mfg P/N + 수량 + 단가 + 구매처 모두 기재)
- [x] 결선도가 OP1/OP2 양쪽에 적용 (CM-730/CM-740를 단일 박스로 표기)
- [x] `probe.sh`가 더미 환경(컨테이너)에서도 에러 없이 실행
- [x] mac-driver-setup.md에 Apple Silicon 시나리오 명시 (Sequoia 시스템 확장)
- [x] safety.md가 forge-cli에 의해 첫 연결 시 출력될 형태 (Sprint 1에서 wiring 예정)
- [x] ADR 3개 모두 Status/Date/Context/Decision/Consequences 표준 양식

## Blockers

없음.

## 다음 단계

**Phase 4 — App Architecture** 즉시 자율 시작:
1. ADR-009 ~ ADR-013 작성 (Rust+Swift 이원화, 모듈 경계, 직렬 추상화, SQLite, 테스트)
2. `app/core/forge-core/` Cargo workspace 초기화
3. `app/core/forge-core` `cargo build` 통과 검증
4. Sprint 1로 즉시 진입 가능한 상태 만들기
