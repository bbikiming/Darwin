# Page Catalog — `motion_4096.bin` (ROBOTIS DARwIn-OP v1.6.0)

> **출처**: `DARwIn-OP_ROBOTIS_v1.6.0/Data/motion_4096.bin`
> **추출일**: 2026-05-12
> **방법**: 256개 페이지 × 512 byte 디코딩 (PAGEHEADER + STEP×7)
> **목적**: Motion Synthesis PRD의 reference 데이터.

## 1. 파일 통계

| 항목 | 값 |
|------|-----|
| 파일 크기 | 131,072 bytes (128 KiB) |
| 페이지 수 | 256 (slot 0 빈 공간 포함) |
| 페이지 크기 | 512 bytes |
| 헤더 크기 | 64 bytes |
| Step 크기 | 64 bytes × 7 = 448 bytes |
| 점유 페이지 | **45개** (이름 또는 stepnum > 0) |
| 빈 페이지 | 211개 (확장 가능 슬롯) |
| 위치 해상도 | MX28 12-bit (0..4095), `motion_1024.bin`은 10-bit |

## 2. PAGEHEADER 정확 레이아웃 (검증됨)

`Framework/include/Action.h` line 41-59 정의를 디스크 덤프와 대조하여 확정:

| Offset | Size | Field | 비고 |
|-------:|----:|-------|------|
| 0 | 14 | `name[14]` | ASCII, NUL 패딩 |
| 14 | 1 | `reserved1` | 보통 0x00 |
| 15 | 1 | `repeat` | 1..255 (1이 기본) |
| 16 | 1 | `schedule` | `0x0A` = TIME_BASE, 그 외 = SPEED_BASE |
| 17 | 3 | `reserved2[3]` | 0x00 |
| 20 | 1 | `stepnum` | 1..7 |
| 21 | 1 | `reserved3` | 0x00 |
| 22 | 1 | `speed` | 1..255 (32 기본) |
| 23 | 1 | `reserved4` | 0x00 |
| 24 | 1 | `accel` | 1..255 (32 기본) |
| 25 | 1 | `next` | 0 = 종료, 그 외 = 페이지 chain |
| 26 | 1 | `exit` | E-stop / 중단 시 이동할 페이지 |
| 27 | 4 | `reserved5[4]` | 0x00 |
| 31 | 1 | `checksum` | 페이지 합 == 0xFF가 되도록 |
| 32 | 31 | `slope[31]` | 관절별 CW/CCW compliance (`0x55` 기본) |
| 63 | 1 | `reserved6` | 0x00 |

## 3. STEP 정확 레이아웃 (검증됨)

| Offset | Size | Field |
|-------:|----:|-------|
| 0 | 62 | `position[31]` (uint16 LE × 31) |
| 62 | 1 | `pause` |
| 63 | 1 | `time` |

### Position 인코딩의 특수 비트 (중요)

`Framework/include/Action.h`:
- `INVALID_BIT_MASK = 0x4000` — 이 비트가 셋이면 "이 step에서 해당 관절 미지정" → 직전 step의 값을 유지(=interpolation 베이스 그대로)
- `TORQUE_OFF_BIT_MASK = 0x2000` — 이 step에서 해당 관절 토크 OFF

즉 실제 각도는 `pos & 0x0FFF` (12-bit), 상위 4비트는 플래그.

> **검증 예**: `motion_4096.bin` 페이지 1 step 1의 R_SHOULDER_PITCH = `0x4000` → "invalid", 페이지 시작 시 직전 자세 유지.

## 4. 점유 페이지 카탈로그 (45개)

`rpt`=repeat, `sch`=schedule, `stp`=stepnum, `spd`=speed, `acc`=accel, `nxt`=next, `ext`=exit.

| ID | Name | rpt | sch | stp | spd | acc | nxt | ext | 추정 용도 |
|---:|------|----:|----:|----:|----:|----:|----:|----:|-----------|
| 1 | `init` | 1 | 10 | 2 | 32 | 32 | 0 | 0 | 기본 자세 (≈ walkready) |
| 2 | `ok` | 1 | 10 | 5 | 32 | 32 | 0 | 0 | "Yes" 동작 (고개 끄덕임 + 손짓) |
| 3 | `no` | 1 | 10 | 5 | 32 | 32 | 0 | 0 | "No" 동작 |
| 4 | `hi` | 1 | 10 | 4 | 32 | 32 | 0 | 0 | 인사 / Thank you |
| 5 | `??` | 1 | 10 | 3 | 32 | 32 | 0 | 0 | "What?" / Sensor calibration fail 사운드 짝 |
| 6 | `talk1` | 1 | 10 | 7 | 32 | 32 | 0 | 0 | 발화 제스처 (짧음) |
| 9 | `walkready` | 1 | 10 | 1 | 32 | 32 | 0 | 0 | 보행 전 자세 |
| 10 | `f up` | 1 | 10 | 5 | 32 | 32 | 0 | 0 | Forward getup (앞 낙상 복구) |
| 11 | `b up` | 1 | 10 | 6 | 32 | 32 | 0 | 0 | Backward getup |
| 12 | `rk` | 1 | 10 | 7 | 32 | 32 | 0 | 0 | Right kick |
| 13 | `lk` | 1 | 10 | 7 | 32 | 32 | 0 | 0 | Left kick |
| 15 | `sit down` | 1 | 10 | 1 | 32 | 32 | 0 | 0 | Sit down (단일 자세) |
| 16 | `stand up` | 1 | 10 | 1 | 32 | 32 | 0 | 0 | Stand up |
| 17 | `mul1` | 1 | 10 | 7 | 32 | 32 | **18** | 0 | Multi-stage motion ① |
| 18 | `mul2` | 1 | 10 | 7 | 32 | 32 | **19** | 0 | Multi-stage motion ② |
| 19 | `mul3` | 1 | 10 | 6 | 32 | 32 | 0 | 0 | Multi-stage motion ③ |
| 23 | `d1` | 1 | 10 | 4 | 21 | 32 | 0 | 0 | Demo 동작 1 (느림) |
| 24 | `d2` | 1 | 10 | 5 | 32 | 32 | **25** | 0 | Demo 동작 2 ① |
| 25 | `d2` | 1 | 10 | 6 | 32 | 32 | 0 | 0 | Demo 동작 2 ② |
| 27 | `d3` | 1 | 10 | 5 | 32 | 32 | 0 | 0 | Demo 동작 3 |
| 29 | `talk2` | 1 | 10 | 5 | 21 | 32 | **30** | 0 | 긴 발화 제스처 ① |
| 30 | `talk2` | 1 | 10 | 5 | 21 | 32 | 0 | 0 | 긴 발화 제스처 ② |
| 31 | `d4` | 1 | 10 | 6 | 32 | 32 | 0 | 0 | Demo 동작 4 |
| 38 | `d2` | 1 | 10 | 5 | 32 | 32 | **39** | 0 | Demo 동작 2-variant ① |
| 39 | `d2` | 1 | 10 | 6 | 32 | 32 | 0 | 0 | Demo 동작 2-variant ② |
| 41 | `talk2` | 1 | 10 | 3 | 21 | 32 | **42** | 0 | Introduction long-chain ① |
| 42 | `talk2` | 1 | 10 | 5 | 21 | 32 | **43** | 0 | ② |
| 43 | `talk2` | 1 | 10 | 5 | 32 | 32 | **44** | 0 | ③ |
| 44 | `talk2` | 1 | 10 | 5 | 21 | 32 | **45** | 0 | ④ |
| 45 | `talk2` | 1 | 10 | 7 | 32 | 32 | **46** | 0 | ⑤ |
| 46 | `talk2` | 1 | 10 | 5 | 32 | 32 | **47** | 0 | ⑥ |
| 47 | `talk2` | 1 | 10 | 6 | 32 | 32 | 0 | 0 | ⑦ (Introduction 종료) |
| 54 | `int` | 1 | 10 | 2 | 32 | 32 | **55** | 0 | Interactive ① |
| 55 | `int` | 1 | 10 | 6 | 16 | 32 | **56** | 0 | ② (느리게) |
| 56 | `int` | 1 | 10 | 6 | 16 | 32 | **58** | 0 | ③ |
| 57 | `int` | 1 | 10 | 6 | 16 | 32 | **58** | 0 | ③-alt |
| 58 | `int` | 1 | 10 | 1 | 32 | 32 | 0 | 0 | 종료 자세 |
| 70 | `rPASS` | 1 | 10 | 7 | 32 | 32 | 0 | 0 | Right pass (축구) |
| 71 | `lPASS` | 1 | 10 | 7 | 32 | 32 | 0 | 0 | Left pass |
| 90 | `lie down` | 1 | 10 | 4 | 32 | 32 | 0 | 0 | 엎드리기 (Headstand 직전) |
| 91 | `lie up` | 1 | 10 | 3 | 32 | 32 | 0 | 0 | 일어서기 |
| 237 | `sit down` | 6 | 10 | 2 | 12 | 32 | 0 | 0 | Sit down 반복 (느림) |
| 239 | `sit down` | 4 | 10 | 2 | 12 | 32 | **240** | 0 | Sit down chain ① |
| 240 | `sit down` | 4 | 10 | 2 | 12 | 32 | **241** | 0 | ② |
| 241 | `sit down` | 20 | 10 | 2 | 12 | 32 | 0 | 0 | ③ (20회 반복) |

## 5. 데모 코드에서의 페이지 호출 매핑 (`Linux/project/demo`)

| Demo path | 호출 페이지 |
|-----------|------------|
| `StatusCheck.cpp:112` (Soccer start) | 9 (walkready) |
| `StatusCheck.cpp:35` (Forward fall) | 10 (f up) |
| `StatusCheck.cpp:37` (Backward fall) | 11 (b up) |
| `StatusCheck.cpp:144` (Motion start) | 1 (init) |
| `StatusCheck.cpp:63, 149` (idle) | 15 (sit down) |
| `demo/main.cpp:271, 276` (kick) | 12, 13 |
| `VisionMode.cpp` (RED) | 4 (hi=Thank you) |
| `VisionMode.cpp` (YELLOW) | 41 (talk2 = Introduction chain) |
| `VisionMode.cpp` (BLUE) | 24 (d2 = Wow) |
| `VisionMode.cpp` (RED+YELLOW) | 38 (d2 = Bye bye) |
| `VisionMode.cpp` (RED+BLUE) | 54 (int = Clap please) |
| `VisionMode.cpp` (RGB all) | 27 (d3 = Oops) |
| `VisionMode.cpp:53,57` | 15, 1 (idle) |

## 6. MP3 동기화 사운드 (`Data/mp3/`)

`Linux/project/tutorial/action_script/script.asc`에서 `(page, mp3_path)` 튜플로 호출:

```
(4,  Thank you.mp3)            (41, Introduction.mp3)
(24, Wow.mp3)                  (23, Yes go.mp3)
(15, Sit down.mp3)             (1,  Stand up.mp3)
(54, Clap please.mp3)          (38, Bye bye.mp3)
(2,  Yes.mp3)                  (3,  No.mp3)
(12, Right kick.mp3)           (13, Left kick.mp3)
(27, Oops.mp3)                 (90+91, Headstand.mp3)
```

## 7. 합성에 유용한 페이지 분류

### 7.1 자세(static-like, stepnum=1~2)
`1 init`, `9 walkready`, `15 sit down`, `16 stand up`, `58 int(종료)` — 시퀀스의 시작/끝 anchor로 활용 가능.

### 7.2 단일 동작(stepnum 3~7, 독립)
`2 ok`, `3 no`, `4 hi`, `5 ??`, `6 talk1`, `12 rk`, `13 lk`, `23 d1`, `27 d3`, `31 d4`, `70 rPASS`, `71 lPASS`.

### 7.3 Chained sequence (next != 0)
- `17→18→19` (mul1/2/3, 총 ≤21 step)
- `24→25` (d2 long)
- `29→30` (talk2 short)
- `38→39` (d2 variant)
- `41→42→43→44→45→46→47` (talk2 long, **7-page Introduction** — 가장 긴 시퀀스)
- `54→55→56→58` (int Interactive, "Clap please" 동기)
- `239→240→241` (sit down 반복)

### 7.4 Recovery (낙상 복구)
`10 f up` (앞), `11 b up` (뒤) — 데모 펌웨어가 자이로로 자동 트리거.

### 7.5 좌우 대칭쌍 (mirror 후보)
`12 rk` ↔ `13 lk`, `70 rPASS` ↔ `71 lPASS`. 이 쌍을 비교하면 좌우 미러링 공식의 ground truth 확보 가능.

## 8. 합성에 유용한 메타 통계

| 항목 | 값 |
|------|-----|
| `speed` 분포 | 32(기본 다수), 21(talk2 4개), 16(int 3개), 12(sit down 4개) |
| `repeat` 분포 | 1(대부분), 4(239/240), 6(237), 20(241) |
| `schedule` | 전부 10 = **TIME_BASE_SCHEDULE** |
| chain 최대 길이 | 7 (Introduction: 41→47) |
| stepnum=7 (포화) | 6 페이지 (`6 talk1`, `12 rk`, `13 lk`, `17 mul1`, `18 mul2`, `45 talk2`, `70 rPASS`, `71 lPASS`) |
| `exit` ≠ 0 | 0개 (현재 펌웨어는 미사용) |

## 9. 검증 노트

- 페이지 1 step 1의 `R_SHOULDER_PITCH = 0x4000` = `INVALID_BIT_MASK` → "이전 자세 유지". Step 2는 모든 관절이 ≈ 2047 (= 4096/2 ≈ MX28 zero pose), 즉 walkready ≈ T-pose-lite.
- 모든 페이지의 `schedule=10` → 새 모션 합성 시 기본값으로 채택.
- `motion_1024.bin`은 동일 구조에 position을 1024 해상도로 인코딩 (RX28 펌웨어용). 본 카탈로그는 4096 기준.

---

> **이 카탈로그는 Motion Synthesis v1 PRD의 reference 데이터다.**
> 알고리즘이 페이지 ID를 인용할 때는 본 문서의 ID 컬럼을 그대로 사용한다.
