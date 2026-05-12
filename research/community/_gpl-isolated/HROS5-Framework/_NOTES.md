# research/community/_gpl-isolated/HROS5-Framework/_NOTES.md

> ⚠ **GPL v3 격리.** 코드 임포트 금지. 알고리즘·페이지 메타데이터 인용만 OK.
> 격리 규칙: [`research/community/_gpl-isolated/README.md`](../README.md).

> Interbotix (구 Trossen Robotics) 가 ROBOTIS DARwIn-OP framework 를 HR-OS5 (Arbotix-Pro 컨트롤러)
> 에 포팅한 derivative. 우리 프로젝트에서는 **모션 편집기 UX (`rme`) + PS3 컨트롤러 텔레오프
> 패턴 + 페이지 의미화 리네이밍 (motion_dest.bin)** 의 알고리즘 reference.

## 메타

| 항목 | 값 |
|------|----|
| Upstream | <https://github.com/Interbotix/HROS5-Framework> |
| Commit | `a0640f194b89165b4a5b3ed637a19a31a8a3e339` (2016-07-03, **archived 2021-07**) |
| Target | HR-OS5 (Trossen/Interbotix) — Arbotix-Pro 서브컨트롤러, DARwIn-OP 변형 |
| License | **GPL v3** (저장소 단위 — 우리 코어에 임포트 금지) |
| Maintainer | Andrew Dresner (Trossen Robotics) |
| Repo size | ~4.6 MiB |

## 구조

```
HROS5-Framework/
├── README.md
├── LICENSE.md                   GPL v3 전문
├── CMakeLists.txt
├── package.xml
├── Data/
│   ├── config.ini               카메라/관절/색 LUT
│   ├── motion_4096.bin          HR-OS5 라이브 카탈로그 (20 명명 페이지)
│   ├── motion_src.bin           rme 변환 입력 (스톡 + skate, 46 페이지)
│   ├── motion_dest.bin          rme 변환 출력 (의미화 리네이밍, 46 페이지)
│   └── mp3/
├── Framework/                   DARwIn-OP 베이스 + Arbotix-Pro 어댑터
│   ├── include/
│   └── src/
│       ├── controller/           Arbotix-Pro 통신 (CM-730 대체)
│       ├── math/
│       ├── minIni/
│       ├── motion/
│       └── vision/
└── Linux/
    └── project/
        ├── dxl_monitor          (DARwIn-OP 동등)
        ├── node_server          node.js HTTP API 서버 (TODO 상태)
        ├── ps3_demo             PS3 컨트롤러로 모션 페이지 호출
        ├── rme                  **robot motion editor** — action_editor 개선판
        ├── tutorial
        └── walk_tuner
```

## 핵심 컴포넌트

### `Linux/project/rme/` — 개선된 모션 편집기 (Farrell Robotics 작성)

| 파일 | 역할 |
|------|------|
| `main.cpp` | entrypoint — `LinuxArbotixPro("/dev/ttyUSB0")` 로 시작, `MOTION_FILE_PATH=../../../Data/motion_4096.bin` |
| `cmd_process.cpp` / `cmd_process.h` | ncurses 인터랙티브 — 페이지 네비, step 편집, 개별 limb torque ON/OFF |
| `Makefile` | 빌드 |

**개선점** (README + cmd_process.cpp 분석):
- **개별 limb (팔/다리/머리) 별 torque ON/OFF 토글** — 스톡 action_editor 는 전체만.
- 페이지/step 카운트 표시 향상.
- 모션 실행 후 자동 sit-down 안전 종료.

> **우리 Sprint 4 motion editor UI 의 직접적 prior art.** 개별 limb torque control 은
> SwiftUI 토글 그룹으로 1:1 매핑 가능 (알고리즘 인용 — clean-room 재구현).

### `Linux/project/ps3_demo/`

- PS3 컨트롤러 (BlueZ4 + sixad) → 모션 페이지 dispatch.
- README: "Triangle 버튼 = walk-ready 진입".
- **컨트롤러 → 페이지 매핑 패턴**: 우리 Sprint 11 (텔레메트리/원격 제어) 에서 Mac UI →
  USB CM-730 로 매핑할 때 reference.

### `Linux/project/node_server/`

- node.js HTTP API 서버 (README: "Test/Finalize api_wrapper & node.js server" TODO).
- 실용도 낮음 — node.js 12 시절 코드.

### `Framework/src/controller/` — Arbotix-Pro 어댑터

- ROBOTIS CM-730 (Atmel SAM) → Arbotix-Pro (Atmel Mega) 컨트롤러 차이 추상화.
- **우리 OP1/OP2 (CM-730/740) 와 무관** — 호환성 없음.

## 페이지 카탈로그

자세히 → `motions/external/_catalog/hros5-motion_{4096,src,dest}.csv`

### `motion_4096.bin` — HR-OS5 라이브 (20 페이지)

소셜 / 댄스 / 데모 중심:
- 0: (empty 1-step)
- 1: init (base pose)
- 8: slow-wake (→1)
- 9: walkready
- 15: sit down
- 20: wave (→1, exit=1)
- 22: arms up (→1)
- 25: scratch (→1, exit=1)
- 30: bow (→1)
- 35: excite (→1, exit=1)
- 40: talking (→1)
- 45: thanks (→1)
- 46: pose (→1)
- 47: dance1 (→101, exit=1)
- 48: dance (→51, exit=1)
- 51: (→1) — dance 체인 종료
- 55: long pose (→1)
- 100~102: test1/test2/test3

> **`exit=1` 활용 빈도가 높음** — Stop() 호출 시 page 1 (init) 으로 안전 복귀 패턴.
> 스톡 ROBOTIS 는 거의 사용 안 함. **인터랙티브 시나리오 권장 패턴**.

### `motion_src.bin` — 스톡 ROBOTIS + skate (46 페이지)

스톡 카탈로그 (`darwinop-ens/motion_4096.bin` 과 거의 동일) + **page 75 = skate**.

### `motion_dest.bin` — rme 변환 출력 (46 페이지)

src 와 페이지 ID 동일하나 **무명 페이지에 의미 부여**:
- page 1: init → int (글자 잘림)
- page 27: d3 → **scratch_head**
- page 38/39: d2/d2 → **wave_1a / wave_1b** (체이닝 의미화)

> **모션 라이브러리 의미화 리네이밍 패턴 reference.** 우리 페이지 라이브러리 큐레이션 시
> "d2, d3" 같은 의미 없는 이름을 의미 있게 바꾸는 절차 — rme 의 사례를 그대로 적용.

## 우리 프로젝트에서의 활용

| 분야 | 참고 방식 |
|------|-----------|
| Sprint 4 motion editor UI | `rme/cmd_process.cpp` 의 개별 limb torque toggle UX (알고리즘 인용, clean-room 재구현) |
| Sprint 11 텔레메트리·원격 제어 | `ps3_demo` 의 컨트롤러 → 페이지 dispatch 패턴 |
| 모션 라이브러리 큐레이션 | `motion_dest.bin` 의 의미화 리네이밍 → 우리 라이브러리 페이지 이름 가이드 |
| 인터랙티브 시나리오 디자인 | `motion_4096.bin` 의 `exit=1` 안전 복귀 패턴 — 우리 모든 인사·댄스 페이지에 적용 |
| Arbotix-Pro 컨트롤러 | **무관** — 우리는 CM-730/740 만 지원 |

## 제한 사항

1. **upstream archived 2021-07** — 5 년간 정체.
2. **Arbotix-Pro 전용** — 모터 통신 코드는 CM-730/740 과 호환 X. 펌웨어 부분은 참고 X.
3. **GPL v3** — 어떤 코드 줄도 우리 src/ 에 들어가면 안 됨. 알고리즘 학습 OK, 복사 X.
4. **node.js 12 시절 코드** — `node_server` 는 모던 Node 에서 빌드 X.
