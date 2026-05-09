# ADR-008: 비상정지 회로 토폴로지

- Status: Accepted
- Date: 2026-05-09

## Context

OP1/OP2는 stall(잠김), 자기 충돌, 낙하 시 즉시 모터 전원 차단이 필요. 옵션:

1. **소프트 e-stop**: forge-cli가 모든 모터에 `torque_enable = 0` (DXL_POWER 게이트도 OFF). 빠르지만 USB 통신 살아있어야 작동.
2. **보드 e-stop**: CM의 BUTTON 이벤트로 firmware가 자체 차단. 펌웨어 의존.
3. **인라인 하드웨어 e-stop**: LiPo + ↔ CM Vin 사이에 SPDT 토글. 통신·펌웨어 모두 무관, 절대적.

## Decision

**1차 = 인라인 하드웨어 토글, 2차 = 소프트 e-stop.**

회로:
```
LiPo + ── 인라인 SPDT 토글 (5 A, lockout cap) ── CM Vin
LiPo − ────────────────────────────────────────── CM GND
```

토글은 로봇에서 50 cm 이내, 빨간색 표지, 한 손가락으로 조작 가능 위치.

소프트 e-stop은 보조: forge-cli `kill --all-torque` (단축키 ⌘⇧.).

## Consequences

- **긍정**: 통신 끊겨도 작동. 펌웨어 손상에도 안전.
- **긍정**: 사용자가 시각적으로 "전원 차단" 상태를 확인 가능.
- **부정**: BOM에 토글 + 와이어 추가 (8 USD, BOM #6).
- **부정**: 케이블 길이가 늘어나 IR drop 약간 증가 (무시 가능).

## 운용 규칙

- 매 작업 시작 시 토글 ON-OFF 동작 확인 (safety.md 체크리스트)
- 토글이 OFF 상태에서 LiPo 연결 후 작업 시작 → 안정성 확인 후 ON
- 작업 종료 시 OFF → 그 후에 LiPo 분리 (스파크 방지)
