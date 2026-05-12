# DYNAMIXEL SDK — 우리가 Rust로 포팅한 원본

## 한 줄 소개

ROBOTIS 공식 다언어 SDK. C/C++/Python/Java/MATLAB/LabVIEW/C# 지원.
forge-core::dynamixel이 Rust로 1:1 포팅한 알고리즘 출처.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | **Apache 2.0** |
| 저장소 | github.com/ROBOTIS-GIT/DynamixelSDK |
| 최신 | tag 4.0.5 (`2ded684`) — 우리 클론 시점 |
| 지원 프로토콜 | 1.0 (MX-28T), 2.0 (X 시리즈) |
| 언어 바인딩 | C/C++/Python/Java/MATLAB/LabVIEW/Mono/C#/Rust(unofficial) |

## 우리 매핑

| DynamixelSDK (C++) | forge-core (Rust) |
|---------------------|--------------------|
| `Protocol1PacketHandler` | `forge-core::dynamixel::v1::Codec` |
| `PortHandler` (Linux/Mac/Win) | `forge-core::serial::PosixSerial` |
| `groupSyncWrite` | `forge-core::dynamixel::sync::sync_write` |
| `groupBulkRead` | `forge-core::dynamixel::bus::bulk_read` |

## 차이점

- **언어 차이** — C++ → Rust. ownership 명확, codec 단위 테스트 작성 용이.
- **에러 처리** — int 반환 → `Result<T, Error>` enum.
- **테스트 가능성** — `LoopbackBus` mock으로 단위 테스트 73개 (DynamixelSDK
  자체는 통합 테스트 위주).

## 차용한 알고리즘 핵심

### Protocol 1.0 체크섬

```cpp
// DynamixelSDK
uint8_t calculateChecksum(uint8_t *packet) {
    uint16_t sum = 0;
    for (uint8_t i = 2; i < packet[3] + 3; i++) sum += packet[i];
    return ~(uint8_t)sum;
}
```

```rust
// forge-core::dynamixel::v1
pub fn checksum(id: u8, length: u8, opcode: u8, params: &[u8]) -> u8 {
    let mut sum: u32 = id as u32 + length as u32 + opcode as u32;
    for &b in params { sum = sum.wrapping_add(b as u32); }
    !(sum as u8)
}
```

### SYNC_WRITE 패킷 (브로드캐스트 ID 254)

`docs/protocols/dynamixel-1.0.md` 참조. C++/Rust 동일 바이트 시퀀스.

## 차용 우선순위

★★★ — 이미 1순위로 채용. 후속 변경:
- **Protocol 2.0** 추가 (forge-core::dynamixel::v2 placeholder만 존재).
  OP3 호환 시 활성화.
- **Group sync read** (Protocol 2.0 only) — 더 효율적인 다중 read.

## 출처

- GitHub: https://github.com/ROBOTIS-GIT/DynamixelSDK
- 라이선스: Apache 2.0
- Protocol 1.0 명세: https://emanual.robotis.com/docs/en/dxl/protocol1/
- Protocol 2.0 명세: https://emanual.robotis.com/docs/en/dxl/protocol2/
- 우리 노트: research/robotis-official/DynamixelSDK/_NOTES.md
