# Cable Specifications — 호스트↔로봇 + 전원 + e-stop

> OP1/OP2 공통. 케이블 종류·사양·구입처는 [`../op1/BOM.md`](../op1/BOM.md).

## 1. 호스트(Mac) ↔ 로봇 통신 케이블

### 옵션 A: CM 직결 USB (1차 권장 — Sprint 1~3)

```
Mac USB-A/USB-C ── USB Mini-B ── CM-730/CM-740 (back panel)
                              │
                              └── FTDI FT232RL → STM32 USART1
```

**사양:**
- 종류: USB 2.0 Mini-B
- 길이: 2 m max (USB 2.0 사양 5 m 이내, 잡음 최소화 위해 짧게)
- 차폐: double-shielded (foil + braid)
- 페라이트: 호스트 측 1개 (모터 PWM noise 차단)
- 라텐시: macOS는 FTDI 라텐시 timer 1 ms로 (`mac-driver-setup.md`)

**장점:** 추가 도구 없음, 1 Mbps 풀 속도, 부팅 시퀀스 표준.
**단점:** Mini-B는 잦은 탈착에 약함. → 비상 시 케이블만 교체할 수 있도록 spare 1개 유지.

### 옵션 B: U2D2 dongle 우회 (2차 — TTL 직접 디버그용)

```
Mac USB-C ── U2D2 ── 3-pin TTL ── Dynamixel daisy chain (CM 우회)
```

**용도:**
- CM-730 펌웨어 손상으로 직접 통신 불가 시
- 모터 단위 격리 점검 (특정 ID 모터를 빼서 단독 핑)
- 공장 출고 모터 ID 변경 (factory ID 1 → 11/12 등)

**단점:** CM의 IMU/voltage/LED 접근 불가. e-stop 흐름이 변경됨 (직접 LiPo 차단 필수).

### 결정

→ **ADR-006**: 기본은 옵션 A (CM 직결 USB). 옵션 B는 진단 모드로만 사용.

## 2. 전원 케이블

### 두 모드

| 모드 | 설명 | 사용 시점 |
|------|------|-----------|
| **배터리** | 11.1 V 3S LiPo, Deans T → CM 보드 | 보행·시연 (자유 이동) |
| **외부 SMPS** | 12 V 5 A → DC 5.5×2.5 mm → CM 보드 DC jack | 책상 디버깅, 장시간 (배터리 보호) |
| **혼용** | 둘 다 연결, SMPS가 배터리보다 약간 높은 전압이라 SMPS가 우선 공급 | 시연 직전 hot-swap |

→ **ADR-007**: 개발 단계별 권고
- Phase 4 ~ Sprint 4 (책상 디버깅): 외부 SMPS 우선
- Sprint 5 (walk engine 실기기): 배터리, SMPS는 walk engine 시작 직전 분리
- Sprint 6 (시연): 배터리 only

### e-stop (인라인)

```
LiPo + ── 인라인 SPDT 토글 ── CM Vin
       │
       └── (off) → 즉시 모터 전원 차단 (DXL_POWER 무관)
```

**사양:**
- 토글: SPDT, 5 A 연속 정격, 빨간 lockout cap, 손가락 한 번에 조작 가능
- 위치: 로봇에서 50 cm 이내 (즉시 손이 닿는 거리)
- 표지: 빨간색 라벨 "STOP"

→ **ADR-008**: 인라인 토글이 1차. 소프트 e-stop (forge-cli `kill --all-torque`)는 보조.

## 3. 케이블 길이 가이드

| 용도 | 길이 |
|------|------|
| Mac ↔ CM USB | 2 m (책상), 1 m (이동 카트) |
| 외부 SMPS DC | 2 m |
| LiPo 직결 (e-stop 포함) | 30 cm (cable manage 후 15 cm 이내 가시) |

## 4. 한계·금지

- **USB Hub 통한 연결 금지**: latency timer / power negotiation 문제로 1 Mbps 안정성 떨어짐. 직결만 사용.
- **2 m 초과 USB 케이블 금지**: PWM noise + USB 2.0 길이 한계.
- **AWG 24 미만 (얇은) 전원선 금지**: LiPo 충전기 측은 AWG 14, CM 측은 AWG 18 이상.

## 출처

- ROBOTIS DARwIn-OP Wiring Manual
- `docs/harness/engineering-foundations.md` §4 ROBOTIS-specific 섹션
- NUbots OP2 Restoration Guide
