# BOM — DARwIn-OP 1세대 (CM-730) 외부 하네스

> 로봇 외부에서 연결하는 케이블·전원·도구의 BOM. 로봇 내부 Dynamixel
> 데이지체인은 별도 (`harness/op1/leg-l-bus.yaml` 외 추후).

## 1. 호스트 ↔ 로봇 통신 케이블

| # | 부품 | Mfg P/N | 수량 | 단가 (USD) | 구매처 | 비고 |
|---|------|---------|------|-----------|--------|------|
| 1 | USB Mini-B 케이블, 2 m, double-shielded, ferrite core | UGREEN US132 | 1 | 7 | Amazon | OP1 CM-730 USB 포트 |
| 2 | USB-A → USB-C 어댑터 (Apple Silicon Mac) | Apple MJ1M2AM/A | 1 | 19 | Apple | Mac mini/studio M2/M3 |
| 3 | USB-Serial 디버그 케이블 (3.3 V TTL, FTDI FT232RL) | Adafruit 70 | 1 | 12 | Adafruit | 펌웨어 진단용 (옵션) |

## 2. 전원 케이블 (외부 SMPS 옵션)

| # | 부품 | Mfg P/N | 수량 | 단가 (USD) | 구매처 | 비고 |
|---|------|---------|------|-----------|--------|------|
| 4 | SMPS 12 V 5 A, 60 W, 잠금 DC plug | Mean Well GST60A12-P1J | 1 | 36 | DigiKey | 시연·장시간 디버깅용 |
| 5 | DC 5.5×2.5 mm extension, 2 m, 18 AWG | Adafruit 327 | 1 | 4 | Adafruit | OP1 DC jack |
| 6 | 인라인 SPDT 토글 스위치 (긴급차단), 5 A 정격, 5.5×2.5 splice | (custom) | 1 | 8 | DigiKey | **e-stop**, 빨간 lockout cap |
| 7 | LiPo 배터리 11.1 V 1300 mAh 25C, Deans T | Tattu BSCT13003S25 | 2 | 22 | HobbyKing | 1세트 충전·1세트 사용 |
| 8 | LiPo 충전기 IMAX B6 V2 + 12 V 어댑터 | SkyRC | 1 | 60 | HobbyKing | |
| 9 | LiPo safe bag, 18×22 cm | (generic) | 2 | 8 | Amazon | 보관·충전 시 사용 |

## 3. 진단/안전 도구

| # | 부품 | Mfg P/N | 수량 | 단가 (USD) | 구매처 | 비고 |
|---|------|---------|------|-----------|--------|------|
| 10 | 디지털 멀티미터 (DC V/A, 연속도) | Fluke 117 | 1 | 200 | Fluke distributor | 전압·통전 점검 |
| 11 | 클램프 미터 (DC A, 100 A) | UNI-T UT210E | 1 | 60 | Amazon | 모터 stall 전류 모니터 |
| 12 | IR 비접촉 온도계 | Fluke 62 MAX | 1 | 80 | Fluke distributor | MX-28 케이스 온도 |
| 13 | LiPo 부저식 cell checker | (generic 1S–8S) | 1 | 8 | HobbyKing | |

## 4. 보관·운반

| # | 부품 | Mfg P/N | 수량 | 단가 (USD) | 구매처 | 비고 |
|---|------|---------|------|-----------|--------|------|
| 14 | DARwIn-OP 운반 트레이 (foam-lined) | (custom 3D print) | 1 | n/a | 자작 | 머리 보호용 |
| 15 | 정비 스탠드, 모터 토크 ON 시 안전 cradling | (custom) | 1 | 30 | 자작/Amazon | **사용 전 cradle 필수** |

## 5. 합계 (참고)

| 카테고리 | USD |
|----------|-----|
| 통신 | 38 |
| 전원·배터리 | 168 |
| 진단·안전 | 348 |
| 보관·운반 | 30 |
| **합계** | **~584** |

> 가격은 2026-05 시점 추정. 실제 발주 전 재확인.

## 자주 망가지는 부품 (OP1 특유)

- LiPo 배터리 (수명 ~200 cycle, 부풀면 즉시 폐기)
- USB Mini-B 커넥터 (CM-730 PCB 측 — 잦은 탈착으로 솔더 fatigue)
- MX-28 호른 기어 (낙하 시 즉시 손상)

권장: 위 3개는 **2배수 재고** 유지.

## 출처

- ROBOTIS DARwIn-OP Wiring Manual (`research/.../Hardware/Mechanics/`)
- `vendor/LICENSES.md`에 기록된 가이드들 (NUbots, Seed Robotics)
- DigiKey/Adafruit/Apple/HobbyKing 공시 단가 (2026-05)
