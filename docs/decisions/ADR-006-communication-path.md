# ADR-006: 통신 경로 — CM 직결 USB vs U2D2 dongle

- Status: Accepted
- Date: 2026-05-09

## Context

OP1/OP2와 호스트(Mac) 사이의 통신 경로는 두 가지 방법이 있다:

1. **CM 직결 USB**: Mac USB → CM-730/CM-740의 내장 USB(FTDI) → STM32 → Dynamixel TTL bus → 모터
2. **U2D2 dongle 우회**: Mac USB → U2D2(USB→TTL) → 3-pin TTL bus → 모터 (CM 우회)

옵션 A는 CM의 IMU·voltage·LED·버튼·마이크에 모두 접근. 옵션 B는 모터·FSR만 접근 가능, CM 보드 펌웨어가 죽었거나 모터 단위 격리 진단이 필요할 때만 유용.

## Decision

**기본은 옵션 A (CM 직결 USB)**. 옵션 B는 진단 모드로만 지원.

forge-core는 두 경로를 별도 `Bus` 구현으로 캡슐화하지만, 일반 사용자 워크플로우는 옵션 A에 최적화. 사용자가 명시적으로 `--via u2d2` 플래그를 줄 때만 옵션 B 활성화.

## Consequences

- **긍정**: CM의 IMU·voltage 등 보드 데이터를 1차 시민으로 다룰 수 있음. 부팅 시퀀스가 ROBOTIS 표준과 동일.
- **긍정**: 추가 하드웨어(U2D2) 없이 Mac만으로 작동.
- **부정**: CM 펌웨어가 손상되면 통신 경로 자체가 막힘 → 옵션 B fallback 필수. **U2D2는 비상용으로 권장 보유**.
- **부정**: USB Mini-B 커넥터 fatigue (BOM에 spare 케이블 1개 명시).
