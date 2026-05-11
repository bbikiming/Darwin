# Page / Step 메모리 포맷

> CM-730/740의 모션 페이지 메모리(`motion_4096.bin`)와 RAM 내 Page/Step
> 구조체 명세.

## 메모리 모델

ROBOTIS DARwIn-OP framework는 **최대 256개 페이지**를 지원하며, 각 페이지는 **최대 7개 Step**. 한 Step은 **20개 관절 (ID 1..=20, 발목 4개 포함) + 시간 + 옵션**으로 구성. `motion_4096.bin` 파일은 정확히 131 072 byte = 256 페이지 × 512 byte/페이지.

> 우리 내부 `MotionStep::positions` 는 31-slot 배열을 유지(RoboPlus Action 호환). 실 사용 슬롯은 ID 1..=20에 대응되는 인덱스, 나머지는 32 767(스킵) 또는 2 048(중앙).

```
Page 0..255 ─── 256 pages
   │
   ├── header: name (14 bytes ASCII)
   ├── compliance[20]
   ├── play_param (next page, exit page, repeat, ...)
   └── steps[7]
        ├── pose[20]   (uint16, 0..4095)
        ├── pause_time (uint16, ms)
        ├── play_time  (uint16, ms)
        └── option     (uint8 bit flags)
```

### 페이지 헤더 (예상 — `> TODO: verify`)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 14 | name (ASCII, padded with `0x00`) |
| 14 | 1 | reserved |
| 15 | 1 | repeat_time |
| 16 | 1 | speed_rate |
| 17 | 1 | next_page |
| 18 | 1 | exit_page |
| 19 | 1 | accel |
| 20 | 1 | reserved |
| 21 | 1 | step_num (1..7) |

### Step (예상)

| Offset | Size | Field |
|--------|------|-------|
| 0..39 | 40 (= 20 × 2) | pose[20] uint16 LE |
| 40 | 2 | pause_time (ms / 8 ticks?) |
| 42 | 2 | play_time |
| 44 | 1 | option flags |
| 45 | 3 | reserved/padding |

> 위 offset은 추정. Sprint 3 작업 시 `Framework/src/motion/Action.cpp`를 직접 읽고 확정한다.

## 파일 (`motion_4096.bin`)

`/darwin/Data/motion_4096.bin` — 파일 크기 4096 바이트의 256배 = 1 048 576 바이트가 아니라, **256개 페이지 × 페이지 크기**. (정확한 페이지 크기는 위 구조 sum 후 8-byte 정렬 추정 — Sprint 3 검증)

## 우리 내부 JSON (Sprint 3)

```json
{
  "version": 1,
  "robot_generation": "op2",
  "pages": [
    {
      "id": 1,
      "name": "Stand Up",
      "next": 0,
      "exit": 0,
      "repeat": 1,
      "speed": 100,
      "compliance": [5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5],
      "steps": [
        {
          "pose": {"r_shoulder_pitch": 2048, "l_shoulder_pitch": 2048, ...},
          "pause_ms": 0,
          "play_ms": 1500,
          "options": []
        }
      ]
    }
  ]
}
```

## 호환성

- OP1 ↔ OP2: 페이지/스텝 레이아웃은 동일. 컴플라이언스 매핑이 약간 다를 수 있음 (모터 수명 차이).
- OP1/OP2 ↔ OP3: 호환되지 않음 (OP3는 XM-430, 위치 4096-step → 4096 동일하나 다른 스케일·회전 반전).

## 출처

- `darwinop-ens/darwin-op` `Framework/src/motion/Action.cpp`
- ROBOTIS RoboPlus Action 매뉴얼
- `research/robotis-official/ROBOTIS-OP-Series-Data/ROBOTIS-OP, ROBOTIS-OP2/Tutorials/`
