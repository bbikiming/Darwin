# Motion Code Audit and Claude Follow-up Prompt

Date: 2026-05-14

이 문서는 현재 모션 관련 구현을 공식 ROBOTIS 자료와 대조한 감사 결과이며, Claude가 다음 작업을 이어받기 위한 실행 프롬프트다. 판단 기준은 "현재 코드가 공식 데모/자료와 같은가", "실 로봇에 잘못된 모션을 쓸 가능성이 있는가", "UI가 사용자에게 공식성/안전성을 과장하고 있는가"다.

## Claude에게 줄 핵심 지시

너는 `/Users/bbikiming/Documents/vibe_coding/Darwin` 저장소에서 모션 구현을 냉정하게 바로잡아야 한다. 모든 소스코드와 공식 ROBOTIS 자료는 이미 로컬에 있다. 외부 자료를 새로 찾기 전에 아래 공식 소스와 현재 코드부터 확인하라.

가장 중요한 규칙:

1. `motion_4096.bin` raw page를 재생/쓰기한다고 말하려면 공식 `Action.cpp`의 page header offset, 31-slot 인덱싱, invalid/torque-off bit, next/repeat, speed/accel/slope 의미와 맞아야 한다.
2. 안전한 합성 포즈는 유효하지만, 그것을 "공식 raw 모션"으로 라벨링하면 안 된다.
3. Swift, Rust, CLI, UI가 같은 `MotionStep.positions` 인덱싱 규약을 써야 한다. 공식 규약은 `positions[joint_id]`, slot 0 reserved다.
4. 수정 후 테스트가 현재의 잘못된 동작을 lock-in하고 있으면 테스트도 같이 고쳐라.

## 공식 기준 소스

- `DARwIn-OP_ROBOTIS_v1.6.0/Data/motion_4096.bin`
- `DARwIn-OP_ROBOTIS_v1.6.0/Framework/include/Action.h`
- `DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/modules/Action.cpp`
- `DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/modules/Walking.cpp`
- `DARwIn-OP_ROBOTIS_v1.6.0/Framework/include/Walking.h`
- `research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml`
- `docs/motion-format/page-catalog-motion4096.md`

## 정량 근거

공식 `motion_4096.bin`에서 직접 파싱한 주요 페이지 메타데이터:

| page | name | steps | speed | accel | next | raw duration | chain | chain duration |
|---:|---|---:|---:|---:|---:|---:|---|---:|
| 1 | init | 2 | 32 | 32 | 0 | 2000 ms | 1 | 2000 ms |
| 2 | ok | 5 | 32 | 32 | 0 | 2600 ms | 2 | 2600 ms |
| 3 | no | 5 | 32 | 32 | 0 | 2600 ms | 3 | 2600 ms |
| 4 | hi | 4 | 32 | 32 | 0 | 3600 ms | 4 | 3600 ms |
| 9 | walkready | 1 | 32 | 32 | 0 | 1000 ms | 9 | 1000 ms |
| 10 | f up | 5 | 32 | 32 | 0 | 3200 ms | 10 | 3200 ms |
| 11 | b up | 6 | 32 | 32 | 0 | 4200 ms | 11 | 4200 ms |
| 12 | rk | 7 | 32 | 32 | 0 | 1664 ms | 12 | 1664 ms |
| 13 | lk | 7 | 32 | 32 | 0 | 1664 ms | 13 | 1664 ms |
| 23 | d1 | 4 | 21 | 32 | 0 | 3000 ms | 23 | 3000 ms |
| 24 | d2 | 5 | 32 | 32 | 25 | 3600 ms | 24 -> 25 | 8192 ms |
| 38 | d2 | 5 | 32 | 32 | 39 | 3600 ms | 38 -> 39 | 7696 ms |
| 54 | int | 2 | 32 | 32 | 55 | 2000 ms | 54 -> 55 -> 56 -> 58 | 8296 ms |

현재 Swift/Rust soft limits 기준 공식 16개 카탈로그 페이지의 위반 수:

| page | name | violations | worst margin |
|---:|---|---:|---|
| 10 | f up | 6 | R_HIP_PITCH step 2, -100.8 deg, limit -90..90 |
| 11 | b up | 2 | R_HIP_PITCH step 1, -90.3 deg, limit -90..90 |
| 24 | d2 | 5 | HEAD_TILT step 1, 45.9 deg, limit -45..45 |
| 12 | rk | 0 | HEAD_TILT margin 4.7 deg |
| 13 | lk | 0 | HEAD_TILT margin 4.7 deg |

판단: get-up류가 caution인 것은 자연스럽지만, page 24 `Wow`는 공식 safe gesture인데 현재 head tilt limit에서 0.9도 초과한다. raw official replay를 validator에 태우면 safe page도 막힐 수 있다.

## 주요 문제 목록

### P0. `forge synth commit` binary encoder의 PAGEHEADER offset이 공식과 다르다

공식 기준:

- `Action.h`의 `PAGEHEADER`: name 0..13, repeat 15, schedule 16, stepnum 20, speed 22, accel 24, next 25, exit 26, slope 32..62.
- Rust decoder `app/core/forge-core/src/synth/library.rs`도 이 offset을 사용한다.

현재 문제:

- `app/core/forge-cli/src/synth.rs:879`의 `encode_page_to_raw`는 stepnum을 19, speed를 21, accel을 23, next를 24, exit를 25, slope를 28부터 쓴다.
- `app/core/forge-cli/src/synth.rs:1047` 테스트가 잘못된 offset을 정답으로 고정한다.

영향:

- `forge synth commit`으로 `motion_4096.bin`에 쓰면 공식 Action player가 stepnum/speed/accel/next/exit/slope를 잘못 읽을 수 있다.
- 이건 문서/라벨 문제가 아니라 실제 파일 손상 가능성이 있는 P0다.

수정 지시:

- `encode_page_to_raw` offset을 `synth::library::decode_raw_page`와 같은 상수로 통일하라.
- encode 후 decode해서 page 1 fixture와 header가 byte-level로 맞는 테스트를 추가하라.
- 기존 `encode_page_round_trips_to_raw_size` 테스트의 잘못된 offset assert를 제거/수정하라.

### P0. Swift `MotionDoc.MotionStep`은 공식 31-slot 인덱싱과 off-by-one이다

공식 기준:

- `Action.cpp`는 `bID=JointData::ID_R_SHOULDER_PITCH`부터 돌며 `position[bID]`를 읽는다. 즉 joint ID가 배열 index이고 slot 0은 reserved다.
- Rust `motion_play.rs`, validators, synth ops도 대부분 `positions[slot]` for `slot in 1..=20` 규약을 쓴다.

현재 문제:

- `app/ui/DarwinForge/Sources/ForgeCore/MotionDoc.swift:119` 주석은 `positions[id - 1]`를 표준이라고 말한다.
- `MotionStep.raw(for:)`와 `MotionStep.from(pose:)`도 `joint.rawValue - 1`을 사용한다.

영향:

- Swift Motion Studio에서 만든 JSON을 Rust/MTN 경로로 넘기면 모든 관절이 한 칸 밀린다.
- 예: R_SHOULDER_PITCH가 reserved slot 0에 들어가고, HEAD_TILT는 HEAD_PAN slot으로 들어갈 수 있다.
- Swift 내부 미리보기는 self-consistent라 테스트가 통과할 수 있지만, 공식 파일/CLI/실 로봇 경로와 연결되면 위험하다.

수정 지시:

- Swift `MotionStep`도 `positions[Int(joint.rawValue)]`를 사용하게 바꿔라.
- slot 0은 reserved/skip으로 유지하라.
- 기존 저장 문서가 있다면 migration이 필요한지 확인하라. 앱 내 starter/generated page만 런타임 생성이면 직접 수정으로 충분할 수 있다.
- `toPose()`는 invalid marker를 2048로 바꾸지 말고 이전 자세를 유지하는 `toPose(previous:)` 경로를 추가하라. 공식 Action은 invalid bit를 "center"가 아니라 previous target hold로 처리한다.

### P0. `walkReady`라는 이름으로 서로 다른 두 공식 자세가 섞여 있다

현재 두 기준:

- `RobotPose.walkReady`와 `motion/walkready.rs`: `motion_4096.bin` page 9 step 0. hip 약 36도, knee 약 53도, ankle 약 30도.
- `walk/ini_pose.rs`와 `ini_pose.yaml`: OP2 manager init target pose. hip 65도, knee 130도, ankle 70도.

영향:

- 둘 다 "공식 walkReady"라고 부르면 안전 검증, UI 설명, ARM 전환, 보행 시작자세가 뒤섞인다.
- 현재 static stability와 JointLimits 주석 일부는 ini_pose 기준을 쓰고, UI/Teleop은 page 9 기준을 쓴다.

수정 지시:

- 이름을 분리하라.
  - `actionWalkReady` 또는 `motionPage9WalkReady`
  - `managerInitPose` 또는 `op2ManagerIniPose`
- UI/Teleop/WalkLab에서 실제 사용하는 anchor가 무엇인지 문서와 라벨에 명확히 쓰라.
- 두 자세의 차이 hip 29도, knee 77도, ankle 40도를 테스트/문서로 남겨라.

### P1. `forge motion play`는 raw page를 읽지만 공식 Action player와 동등하지 않다

현재 장점:

- `app/core/forge-cli/src/motion_play.rs`는 `decode_raw_page`를 사용하고 next-page chain도 따라간다.
- invalid/torque-off bit는 필터링한다.

현재 문제:

- official `Action.cpp`의 speed/accel/slope 기반 trapezoid section을 재현하지 않고, `set_positions_many` 후 `sleep(play_ms/pause_ms)`만 한다.
- `setup_ctrlc_handler()`는 placeholder다. 문서 상으로는 Ctrl+C emergency stop을 약속하지만 실제 구현은 없다.
- `raw == 0`을 unused로 skip한다. 공식적으로 skip은 invalid bit 또는 torque-off bit이며, raw 0은 12-bit position으로는 유효한 값이다.

수정 지시:

- CLI help와 주석에서 "official-equivalent playback"처럼 보이는 문장을 낮춰라. 현재는 "raw step coarse playback"이다.
- Ctrl+C emergency stop을 실제 구현하거나, 문서에서 약속을 제거하라.
- `raw == 0` skip은 slot 21..30 같은 reserved 처리에만 제한하거나 제거하라.
- 공식 Action 보간까지 맞출 계획이면 `Action.cpp`의 PRE/MAIN/POST/PAUSE section을 별도 replayer로 구현해야 한다.

### P1. `MotionCatalog`는 raw official catalog와 single-pose approximation을 섞어 보여준다

현재 코드:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/MotionCatalog.swift`
- `TeleopChannel.sendMotion()`은 `v1TargetPoseID`가 있으면 `PoseLibrary`의 단일 target pose로 보낸다.

문제:

- 파일 상단 주석은 `motion_4096.bin` byte-identical page라고 말하지만, 실제 Pilot v1은 single pose mapping이다.
- page 13 Left Kick은 메인 7 슬롯에 있지만 `v1TargetPoseID == nil`이다. Right Kick은 가능하고 Left Kick은 불가능한 비대칭 UX다.
- page 24/38/54는 공식 chain page인데 catalog duration은 첫 page 또는 single pose 기준이다.
  - page 24 official chain: 8192 ms, catalog: 3600 ms.
  - page 38 official chain: 7696 ms, catalog: 3600 ms.
  - page 54 official chain: 8296 ms, catalog: 2000 ms.
- page 38 raw name은 공식 bin에서 `d2`인데 catalog는 `d2 bye`다.

수정 지시:

- `MotionCatalog` 주석을 현재 구현에 맞게 고쳐라. "official source metadata plus v1 single-pose approximation" 정도가 정확하다.
- raw official duration과 v1 approximation duration을 별도 필드로 나눠라.
- page 13은 left kick pose를 연결하거나, main 7에서 제거/비활성 라벨을 명확히 하라.
- chain page는 raw chain replay가 준비되기 전까지 "공식 모션 재생"으로 보여주면 안 된다.

### P1. official page 12 right kick raw를 수동 복붙했지만 timing이 틀리다

현재 코드:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkMotionLibrary.swift:516`

공식 page 12 timing:

| step | official play | official pause | official total |
|---:|---:|---:|---:|
| 1 | 496 | 0 | 496 |
| 2 | 200 | 0 | 200 |
| 3 | 72 | 0 | 72 |
| 4 | 72 | 144 | 216 |
| 5 | 72 | 0 | 72 |
| 6 | 112 | 0 | 112 |
| 7 | 496 | 0 | 496 |
| sum | 1520 | 144 | 1664 |

현재 Swift timing:

| step | Swift play | Swift pause | delta total |
|---:|---:|---:|---:|
| 1 | 496 | 0 | 0 |
| 2 | 200 | 0 | 0 |
| 3 | 160 | 0 | +88 |
| 4 | 160 | 144 | +88 |
| 5 | 160 | 0 | +88 |
| 6 | 160 | 0 | +48 |
| 7 | 496 | 0 | 0 |
| sum | 1832 | 144 | +312 |

판단:

- 현재 jog preset의 embedded right kick은 공식보다 312 ms 느리다. 약 18.8% 길다.
- raw 배열도 수동 복붙이라 앞으로 유지보수 리스크가 높다.

수정 지시:

- Swift 하드코딩을 제거하고 Rust `decode_raw_page` 결과를 JSON/fixture로 생성하거나, 최소한 timing을 공식과 맞춰라.
- page 12 raw/timing fixture를 공식 `motion_4096.bin`에서 재생성하는 테스트를 추가하라.

### P1. `WalkMotionLibrary`는 공식 Walking module이 아니라 sparse keyframe approximation이다

공식 기준:

- `Walking.cpp`는 8 ms loop에서 phase update, IK, gyro balance, P/I/D gain 적용을 수행한다.
- `Walking.cpp` 기본 상수는 X_OFFSET=-10, Y_OFFSET=5, Z_OFFSET=20, HIP_PITCH_OFFSET=13, PERIOD_TIME=600, DSP_RATIO=0.1, STEP_FB_RATIO=0.28, Z_MOVE_AMPLITUDE=40, Y_SWAP_AMPLITUDE=20, Z_SWAP_AMPLITUDE=5, PELVIS_OFFSET=3, ARM_SWING_GAIN=1.5다.

현재 코드:

- `WalkMotionLibrary.swift`는 주요 상수를 꽤 잘 옮겼다.
- 하지만 한 cycle을 6개 sample phase `[0.03, 0.18, 0.42, 0.52, 0.68, 0.92]`로 sparse keyframe화한다.
- turn slider에는 official에 없는 `yawBias`를 추가한다.
- IMU closed-loop balance와 8 ms realtime update는 없다.

판단:

- 방향은 나쁘지 않지만 "officialWalkingPose"라는 함수명과 일부 UI 라벨은 과장이다.
- 정확한 표현은 "ROBOTIS Walking.cpp inspired sparse keyframe approximation"이다.

수정 지시:

- `officialWalkingPose`를 `robotisWalkingApproxPose` 같은 이름으로 바꿔라.
- UI/문서의 "ROBOTIS 공식 보행" 표현을 낮춰라.
- 공식 parity를 목표로 한다면 8 ms walking engine replay를 Rust 쪽에서 구현하고 Swift는 preview만 담당하게 분리하라.

### P2. `MotionPage` model의 comment/default가 공식과 어긋난다

현재 문제:

- `app/core/forge-core/src/motion/page.rs:9`는 실제 사용 slot이 16개라고 말한다. OP2 공식 motor ID는 1..20 전체가 사용된다.
- `MotionPage::default()`는 compliance `[5]`, accel `0`이다. 공식 `Action.cpp::ResetPage`는 slope byte `0x55`, speed 32, accel 32를 쓴다.
- compliance라는 이름도 애매하다. 공식 header의 slope는 CW/CCW slope nibble pair byte이며 단순 0..7 scalar가 아니다.

수정 지시:

- comment를 20 joints + 31 slots로 바로잡아라.
- default가 official page authoring을 목표로 한다면 slope `[0x55;31]`, accel 32로 바꿔라. 단, 기존 JSON 호환 영향은 테스트하라.
- 필드명을 바꾸기 어렵다면 문서에 "slope byte" 의미를 명확히 남겨라.

### P2. Rust official catalog import 경로가 두 갈래다

현재 상태:

- `app/core/forge-core/src/synth/library.rs::PageLibrary::from_official_bin()`은 실제 raw page decode를 한다.
- `app/core/forge-core/src/motion/library.rs::Library::with_official_catalog()`는 raw page를 찾지만 steps를 비우고 header도 placeholder로 넣는다.

판단:

- 둘 다 official catalog처럼 보이므로 다음 작업자가 헷갈릴 수 있다.

수정 지시:

- `with_official_catalog()`를 `PageLibrary::from_official_bin()` 기반으로 통합하거나 deprecated/legacy로 명시하라.
- "official catalog"라고 부르는 API는 하나만 남겨라.

### P2. 기타 문서/주석 불일치

- `app/core/forge-core/src/motion/bin4096.rs` 상단은 "step offsets pending"이라고 하지만 이미 `synth/library.rs`에 decoder가 있다.
- `ReferenceMotionLibrary.swift`는 `RobotPose.walkReady`를 "대칭 표준"이라고 말하지만, 현재 page 9 raw는 공식 calibration residual을 보존하며 완전 대칭이 아니다.
- `docs/motion-format/page-catalog-motion4096.md`의 stepnum=7 count 설명은 숫자가 맞지 않는다.

## 권장 작업 순서

1. P0 binary encoder offset 수정 및 테스트 교체.
2. Swift `MotionDoc` 31-slot 인덱싱을 공식 규약으로 수정.
3. `walkReady` naming split 및 관련 주석/테스트 정리.
4. `MotionCatalog`에서 official raw duration과 v1 approximation duration 분리.
5. page 12 timing을 공식 값으로 맞추거나 Rust decoder 기반 fixture로 대체.
6. `WalkMotionLibrary` 네이밍/라벨을 approximation으로 낮추기.
7. official 16 catalog page가 validator에서 어떤 정책으로 통과/차단되어야 하는지 테스트 추가.

## 반드시 추가해야 할 테스트

- `encode_page_to_raw` header offset test:
  - decode page 1 -> encode -> header bytes가 공식 offset에 들어가는지 확인.
  - stepnum은 byte 20, speed byte 22, accel byte 24, next byte 25, exit byte 26, slope byte 32부터.
- Swift `MotionStep` indexing test:
  - `MotionStep.from(pose:)`에서 R_SHOULDER_PITCH는 positions[1], HEAD_TILT는 positions[20]이어야 한다.
  - positions[0]은 reserved로 남아야 한다.
- official page 12 timing test:
  - `[496, 200, 72, 216, 72, 112, 496]` total 1664 ms.
- official catalog validator audit:
  - 현재 기준 page 10, 11, 24가 limit fail하는 것을 explicit test 또는 documented expected failure로 남겨라.
- MotionCatalog metadata parity:
  - rawName, rawDuration, chainDuration이 `motion_4096.bin` parser 결과와 일치해야 한다.
  - v1 approximation duration은 별도 필드로 검증하라.

## 수락 기준

- `cargo test -p forge-core -p forge-cli -p forge-ffi` 통과.
- `swift test` 통과.
- `forge synth commit` encoder가 공식 `Action.h` offset과 일치한다.
- Swift Motion Studio에서 만든 Motion JSON이 Rust parser/writer/CLI와 같은 joint slot 의미를 가진다.
- UI 문구에서 "공식", "raw", "byte-identical"이라는 표현은 실제 raw official path에만 남는다.
- single-pose approximation은 사용자에게 approximation으로 드러난다.

