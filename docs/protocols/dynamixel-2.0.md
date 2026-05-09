# Dynamixel Protocol 2.0 — 참고용 명세

> **우리 OP1/OP2는 Protocol 1.0을 사용한다.** 이 문서는 다음 두 이유로
> 존재한다:
> 1) 사용자가 향후 OP3나 X시리즈 모터로 확장할 가능성에 대한 참고
> 2) DynamixelSDK가 두 프로토콜을 같은 API에 노출하므로 코드 읽을 때 혼동 방지

## Protocol 1.0 vs 2.0 차이 (한눈에)

| 항목 | 1.0 (MX-28T, CM-730/740, FSR) | 2.0 (XM-430, OP3, U2D2 호환 일부) |
|------|------|------|
| 헤더 | `0xFF 0xFF` | `0xFF 0xFF 0xFD 0x00` |
| 길이 필드 | 1 byte | 2 byte (LSB first) |
| 무결성 | 1-byte checksum (`~sum & 0xFF`) | 2-byte CRC-16 IBM/ANSI |
| 최대 패킷 | 256 byte | 65 535 byte |
| 인스트럭션 셋 | 9개 (PING, READ, WRITE, REG_WRITE, ACTION, FACTORY_RESET, REBOOT, SYNC_WRITE, BULK_READ) | 1.0 + STATUS, FAST_SYNC_READ, FAST_BULK_READ, CLEAR, BACKUP, CONTROL_TABLE_BACKUP, ... |
| Status 패킷 분리 | 없음 (응답=일반 패킷에 ERROR 바이트) | `STATUS=0x55` 인스트럭션으로 분리 |
| 에러 표현 | 비트 OR (8가지) | 단일 코드 + 알람 비트 |
| Stuffing | 없음 | `0xFF 0xFF 0xFD` 시퀀스가 페이로드에 나오면 `0xFD` 삽입 (Byte stuffing) |

## 패킷 구조 (요약)

```
Instruction:
  0xFF 0xFF 0xFD 0x00  ID  LEN_L LEN_H  INSTR  PARAM_1..N  CRC_L CRC_H

Status:
  0xFF 0xFF 0xFD 0x00  ID  LEN_L LEN_H  0x55   ERR  PARAM_1..N  CRC_L CRC_H
```

`LEN` = 파라미터 개수 + 인스트럭션(1) + ERR(0/1) + CRC(2) — 즉 헤더 다음 모든 바이트 수.

## CRC 다항식

CRC-16 IBM/ANSI: `x^16 + x^15 + x^2 + 1` (다항식 `0x8005`, init `0`, no reflection).

## 우리 코드 정책

- `app/core/forge-core/src/dynamixel/v1/` — 1차 구현 (Sprint 1)
- `app/core/forge-core/src/dynamixel/v2/` — 비활성, 더미 모듈만 둠 (확장 가능성 신호)
- 두 모듈은 같은 `Bus` trait를 구현하지만 별도 module path. **버전 자동 감지 금지** — 호출자가 명시적으로 선택.

## 출처

- [emanual.robotis.com/docs/en/dxl/protocol2/](https://emanual.robotis.com/docs/en/dxl/protocol2/)
- `research/robotis-official/DynamixelSDK/c++/include/dynamixel_sdk/protocol2_packet_handler.h`
