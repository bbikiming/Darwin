# ADR-007: 전원 전략 — 배터리 vs 외부 SMPS

- Status: Accepted
- Date: 2026-05-09

## Context

OP1/OP2는 두 종류 전원을 동시 받을 수 있다:

- **11.1 V LiPo 배터리** (Deans T 커넥터)
- **12 V 외부 SMPS** (DC 5.5×2.5 mm jack)

두 입력은 보드 내부에서 OR-ing. SMPS가 약간 높은 전압이라 둘 다 연결 시 SMPS가 우선 공급, 배터리는 idle.

선택 기준:
- **개발/디버그**: SMPS — 배터리 충전 부담 X, 전압 안정, 무제한 시간
- **시연/이동**: 배터리 — 케이블 없이 자유 이동
- **walk engine 실기기**: 배터리 — SMPS 케이블 텐션이 보행 위험

## Decision

**개발 단계별 권고:**

| 단계 | 1차 전원 | 비고 |
|------|---------|------|
| Phase 4 ~ Sprint 4 (책상) | SMPS | 배터리는 hot-swap 테스트용 |
| Sprint 5 (walk engine 실기기) | 배터리 | walk start 직전 SMPS 분리 |
| Sprint 6 (시연) | 배터리 | LiPo 2팩 운용 |

forge-cli는 첫 연결 시 `voltage` 레지스터(주소 50)를 읽고 9.5 V 미만이면 경고, 9.0 V 미만이면 작업 차단.

## Consequences

- **긍정**: 배터리 수명 연장, 디버그 시 무한 시간 작업 가능.
- **긍정**: 시연 모드 명확히 분리 — 사용자 mistake 방지.
- **부정**: 사용자가 모드 전환 잊어버리면 walk start 도중 SMPS 케이블 잡아당겨 로봇 낙하 위험. Sprint 5 walk start UI에서 "케이블 분리하셨습니까?" 체크박스 강제.
