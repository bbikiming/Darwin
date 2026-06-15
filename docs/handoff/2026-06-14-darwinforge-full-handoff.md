# DarwinForge — 전체 인계 문서 (2026-06-14)

> **목적**: 다른 Claude 계정/세션이 이 저장소를 **콜드 스타트**로 이어받아 작업할 수 있도록,
> 현재 버전 기준의 구현·구조·검증 상태·다음 작업을 한 문서에 정리한다.
> 결론 먼저 → 세부 순서. 모든 테스트 수치는 2026-06-14 실측.

---

## 0. 한눈에 (TL;DR)

- **무엇**: macOS 전용 앱으로 ROBOTIS **DARwIn-OP** 휴머노이드 2종(OP1=CM-730, OP2=CM-740)을
  USB 시리얼/SSH/UDP로 제어·모션 저작·프로그래밍. 비공식, ROBOTIS 무관, Apache 2.0.
- **스택**: **Rust 코어(`app/core/`) + SwiftUI(`app/ui/`)**, cbindgen C-FFI로 브리지.
  + iOS 동반앱(`app/mobile/`) + ROG Ally FPV 앱(`app/ally/`, 독립 워크스페이스) +
  로봇 온보드 C++ 펌웨어 패치(`firmware-patches/`).
- **현재 HEAD**: `8cdc282` (브랜치 `claude/robotis-darwin-op-setup-oyzTi`, = main 취급).
- **검증 상태 (실측)**:
  - Rust `cargo test --workspace` → **382 / 382 통과** (forge-cli 13, forge-core 322+15, forge-mcp-synth 32).
  - 펌웨어 호스트 테스트 `make -C firmware-patches/walklab-brokerage/tests` → **279 checks / 0 fail**.
  - Swift 테스트는 **선언 카운트만**(UI ~3577 + iOS ~151 `func test*`) — `swift test` 통과 수 **미검증**.
- **활성 프론티어**: WalkLab 게임패드 **직결 조종**(RG G01 Anbernic 패드 → 로봇 온보드 C++).
  최근 작업(하드닝·회전 튜닝·볼-추종 자동보행·D-패드 모션)은 **전부 코드 완료/호스트 GREEN,
  로봇 미배포(OFF)·실기 미검증**.
- **콜드 스타트 첫 행동**: §1 빌드/테스트 재현 → §6 프론티어 파악 → §7 게이트 사실(특히
  마이크는 `run-app.sh`, 로봇 세션은 단일 자원, 유선 123.1이 166x 빠름) 숙지.

---

## 1. 저장소 좌표 · 빌드 · 실행 · 테스트

### 1.1 git 상태
- 메인 작업 브랜치: **`claude/robotis-darwin-op-setup-oyzTi`** (이 저장소는 이 브랜치를 main으로 취급).
- HEAD `8cdc282`. 워킹트리 clean(인계 시점).
- 활성 워크트리 여럿(`.claude/worktrees/*`) — 과거 병렬 작업 잔재. **로봇·워크트리는 단일 공유
  자원**이므로 새 작업은 새 워크트리에서, 커밋 시 타 워크트리 미커밋 변경 혼입 주의.
- 커밋 컨벤션: Conventional Commits, **제목은 한국어**(주변 스타일 일치). 스코프 예: `dynamixel`,
  `motion`, `walk`, `walklab`, `gamepad`, `ui`, `connection`, `mobile-relay`, `appstore`, `ally`.

### 1.2 빌드/실행 (macOS, `Makefile`)
```sh
make doctor   # 도구 점검(git/python3/node/cargo/rustc/swift)
make run      # Rust 코어 빌드 → swift build → swift run DarwinForgeApp
make app      # 실행 없이 빌드만
make test     # cargo test --workspace (Rust 전용)
make lint     # cargo fmt --check + clippy -D warnings
make headers  # cbindgen 으로 forge-ffi/forge_core.h.in 재생성
```
- 파이프라인 `scripts/build-mac.sh`: Rust 정적 lib 빌드 → cbindgen → Swift 패키지가 링크하는
  `app/ui/DarwinForge/Vendor/CForgeCore/{lib,include}` 채움. 플래그: `-u`(universal),
  `--swift`, `--run`, `--skip-rust`(Vendor 재사용).
- **⚠️ 마이크/TCC 기능은 정식 `.app` 번들로만 동작**. `swift run`/`make run`은 Info.plist 가
  없어 마이크 누르면 TCC 크래시. → **`bash scripts/run-app.sh`** 사용(번들 패키징 후 `open`).

### 1.3 테스트
```sh
# Rust 전체
cargo test --workspace --manifest-path app/core/Cargo.toml
# Rust 단일 경로
cargo test -p forge-core --manifest-path app/core/Cargo.toml synth::
# Swift (반드시 직렬 — UserDefaults 전역키 공유로 병렬 시 교차오염)
swift test --package-path app/ui/DarwinForge --filter VirtualJoystickMapperTests
# 펌웨어 호스트 순수로직 테스트
make -C firmware-patches/walklab-brokerage/tests   # → 279 checks / 0 fail
```
- **Swift 테스트는 `--parallel` 금지**(CI도 plain `swift test`). UserDefaults 키
  (`mobileRelay.preferredHost`, `df.walklab.*`, harness 토스트 플래그) 공유 때문.

### 1.4 CI (`.github/workflows/ci.yml`)
- `rust` 잡(ubuntu): fmt --check, clippy `--lib` strict(`-D warnings`) + all-targets warn-only,
  build, test. `swift` 잡(macos-14, needs rust): `latest-stable` Xcode 선택(기본 15.x가 일부
  Sendable/MainActor 미스컴파일), Rust vendor lib 빌드 후 `swift build` + `swift test`.
  전역 `RUSTFLAGS: -D warnings`.

---

## 2. 전체 아키텍처

```
┌────────────────────────────────────────────────────────────────────┐
│  Mac 앱 (DarwinForgeApp, SwiftUI)                                   │
│   탭: Studio·Teach·Motion·WalkLab·Conversation·Pilot·Remote·       │
│        Expert·Cockpit  (+ AllyFpv 런처)                            │
│        │  Swift                                                     │
│   ForgeCore (Swift 래퍼)                                            │
│        │  C-FFI (cbindgen)                                          │
│   libforge_core.a  ◄── Vendor/CForgeCore (build-mac.sh 가 채움)     │
└────────┬───────────────────────────────────────────────────────────┘
         │  USB serial / TCP / SSH
         ▼
┌────────────────────────────────────────────────────────────────────┐
│  로봇 (DARwIn-OP, Linux ARM)                                        │
│   CM-730/740 (Dynamixel bus, 20 DOF MX-28)                          │
│   demo-pilot (ROBOTIS Framework 포크 + firmware-patches 적용)      │
│     ├ WalkLabBrokerage  (온보드 보행 중재 모드)                     │
│     ├ GamepadPilot      (RG G01 동글 직결 조종)                    │
│     └ WalkLabTransport  (명령 거버너/슬루/TEL 텔레메트리)          │
└────────────────────────────────────────────────────────────────────┘
   ▲                          ▲
   │ WebSocket relay          │ UDP/SSH (df-wire 14토큰 프로토콜)
   │                          │
┌──┴──────────────┐    ┌──────┴────────────────┐
│ iOS 동반앱       │    │ ROG Ally FPV 앱        │
│ app/mobile      │    │ app/ally (Tauri 2,     │
│ (Mobile Pilot)  │    │  독립 Cargo 워크스페이스)│
└─────────────────┘    └───────────────────────┘
```

- 설계 근거: `docs/decisions/` ADR-009..013 (Rust/Swift 경계).
- **연결 모드는 배타적**: CM 시리얼 라인 공유로 **보행 모드 ↔ 관절편집(bus) 모드**가 동시 불가.
  Studio/Teach는 관절편집 필요, WalkLab은 보행 모드 필요. 툴바 원클릭 스위처(커밋 960afb3).

---

## 3. Rust 코어 (`app/core/`) — 도메인 로직

Cargo 워크스페이스(Rust 1.78+, edition 2021), 4 멤버, ~19.6k LOC.

### 3.1 forge-core (도메인, ~9.8k LOC)
모듈별 현황 (`app/core/forge-core/src/`):

| 모듈 | 내용 | 성숙도 |
|---|---|---|
| `error.rs` | 통합 `Error`/`Result` (Io/Codec/Timeout/DeviceNotFound/EstopPreempted/Other) | 완성 |
| `dynamixel/v1.rs` | 프로토콜 1.0 패킷 코덱(PING/READ/WRITE/REG_WRITE/ACTION/SYNC_WRITE…) | 완성 |
| `dynamixel/v2.rs` | 프로토콜 2.0 | **비활성 placeholder**(OP1/OP2 불필요) |
| `dynamixel/bus.rs`·`sync.rs` | `Bus<P: SerialPort>` 제네릭 + SyncWrite 배치 | 완성 |
| `serial/posix.rs` | macOS/Linux PosixSerial(`serialport` 4.7 + FTDI latency ioctl) | 완성 |
| `serial/tcp.rs` | TcpBus(원격 로봇) | 완성 |
| `serial/loopback.rs` | 단위 테스트 픽스처 | 테스트용 |
| `controller/cm.rs` | CM-730/740 추상화(snapshot/IMU/FSR 읽기) | 완성 |
| `joint/` | 20-DOF JointId + JointMap(Official/LegacyOp1) + JointState/Limits + FSR | 완성 |
| `control/mod.rs` | JointController(토크/위치/속도/P_GAIN SYNC_WRITE, e-stop, 8ms 틱) | 완성 |
| `motion/bin4096.rs` | `motion_4096.bin`(256페이지) byte-identical 코덱 | 완성 |
| `motion/parser.rs`·`writer.rs` | `.mtn` ↔ JSON 라운드트립 | 완성 (parser.rs:25 RoboPlus 변형 정규화 TODO) |
| `motion/page.rs`·`library.rs`·`player.rs`·`timeline.rs`·`walkready.rs` | 페이지/스텝 모델, 공식 카탈로그(16), 재생+CancelHandle, 보간, walkReady 포즈 | 완성 |
| `walk/engine.rs` | 보행 합성 | **MVP** — 다리 IK 단순 sin/사다리꼴(실 IK 후속) |
| `walk/imu.rs`·`ini_pose.rs`·`params.rs`·`preset.rs` | 상보필터, op2 ini 포즈, 파라미터, 속도 프리셋/안전모드 | 완성 |
| `vision/segmentation.rs` | HSV blob 검출(RoboCup 주황 공) | 완성(MVP, 카메라 캘리브 없음) |
| `safety/self_collision.rs`·`torque_ramp.rs` | 자기충돌 휴리스틱, P_GAIN 램프(0→8→16→32) | 완성 |
| `strategy/mod.rs` | 싸커 FSM(Idle→Looking→Approaching→Kicking→Cooldown) | 완성 |
| `synth/` | 모션 합성: 6 오퍼레이터(sequence/layer/morph/mutate/mirror/procedural) + 4단 검증기(V1 관절한계·V2 속도·V3 자기충돌·V4 정적안정성) + provenance | 완성. 단 **V4 정적안정성은 hip_pitch 휴리스틱 프록시**(실 CoM은 URDF+IK 필요) |

### 3.2 forge-ffi (C-ABI, ~600 LOC)
- **33개 `extern "C"` 함수**: 버전/포트, 버스 open/close(USB+TCP), ping/scan, 보드/IMU/FSR,
  관절 토크/위치/속도/P_GAIN/상태, e-stop(soft + S4 preempt), 모션 변환·재생(async cancel/is_running),
  walk(new/free/set_command/tick), strategy step, vision ball.
- 에러코드 i32: `FC_OK=0` … `FC_ERR_ESTOP_PREEMPTED=-7`(의도된 중단), `FC_ERR_PANIC=-99`.
- 헤더: `forge-ffi/forge_core.h.in`(cbindgen) → 빌드 시 Swift `Vendor/CForgeCore/include/`로 복사.
- 2026-05-17 감사 픽스: 모션/estop Arc 별칭 UB 제거, walk 함수 panic catch(`safe_call`).

### 3.3 forge-cli (`forge`, 13 서브커맨드)
`ports · ping · scan · board · list-joints · joint{set-position,state,torque,emergency-stop} ·
motion{mtn-to-json,json-to-mtn} · walk(sim) · strategy(sim) · serve(USB↔TCP 브리지, 기본
127.0.0.1 바인드) · connect(모델·맵 자동감지) · walk-ready(4단 토크램프) · synth(라이브러리/오퍼/검증/commit)`.
- `motion play`는 기본 dry-run; `--engage`가 실제 송출.
- `serve`는 Ctrl+C → `emergency_stop`(P0 안전).

### 3.4 forge-mcp-synth (MCP 서버, 11 툴)
- stdio JSON-RPC 2.0, Claude Code `/synth` 가 스폰. 툴: `library_search/get`,
  `synth_sequence/layer/morph/mutate/mirror/procedural`, `validate`, `commit`, `preview`.
- `commit`은 4단 검증기 전부 PASS 요구(PRD §12.3 R6).

### 3.5 코어 알려진 한계 (다음 작업 후보)
1. `walk/engine.rs` — 보행 IK가 단순 sin 매핑(MVP). 실 IK 솔버 미구현.
2. `synth/validator/static_stability.rs` — V4가 hip_pitch 차분 휴리스틱(실 CoM 아님).
3. `motion/parser.rs:25` — RoboPlus `.mtn` 라벨 변형 정규화 TODO.
4. `dynamixel/v2.rs` — 프로토콜 2.0 미구현(현 하드웨어 불필요).

---

## 4. SwiftUI macOS 앱 (`app/ui/DarwinForge/`)

SwiftPM 패키지. Products: `DarwinForgeApp`(실행), `DarwinForgeUI`(기능), `ForgeCore`(FFI 래퍼).

### 4.1 루트 & 탭
- 진입 `Sources/DarwinForgeApp/DarwinForgeApp.swift`(AppDelegate + 창 최대화),
  `RootView.swift`(NavigationSplitView, 7개 StateObject 주입, 툴바 연결/배터리/온도/토크 pill).
- **탭(Section enum)**: `studio`(3D 포즈 인스펙터) · `teach`(수동 포즈 캡처) ·
  `motion`(RoboPlus형 타임라인 에디터) · `walk`(WalkLab — 활성) · `conversation`(Claude 채팅) ·
  `pilot`(원격 텔레옵+MJPEG) · `remote`(SSH 빠른 명령) · `expert`(5탭 콘솔: 보드/관절/모션/보행/전략) ·
  `cockpit`(게임패드/DJI 시뮬레이터).

### 4.2 기능 디렉터리 요약 (`Sources/DarwinForgeUI/`)
- **WalkLab/**(49 파일, 최활성): `WalkLabSession`(@Observable 코어 + 24 확장파일),
  `WalkLabView`, 3D 씬, 모니터링 컬럼. 입력 경로: Gamepad/Keyboard/Tello RC(UDP)/Voice/VirtualJoystick.
  로봇 통신: 온보드 텔레메트리(UDP push 10~30Hz + SSH 폴백 0.5s), 모션 디스패치(SYNC_WRITE),
  학습 루프(`Learning/` ExperimentLoopController + Claude critic + AutoTuner), 낙상 텔레메트리,
  ZMP/FallPredictor 안전 파이프라인, Trials 저장/분석.
- **Connection/**(27): USB/SSH/Ethernet 추상화, Bonjour 발견, 헬스/RTT SLO, 유선 재프로브.
- **Pilot/**(89, Cockpit 57 포함): 원격 텔레옵 + 콕핏 시뮬레이터(컨트롤러 드라이버/바인딩 프로파일,
  DJI 가상 조이스틱, 보행 애니메이터, 레이턴시 트레이서).
- **MobileRelay/**(12): iPhone 원격 제어 게이트웨이(툴바 chip + 페어링 + walk conflation).
- **Motion/**(15): 타임라인 에디터, 문서 I/O(.motion), 공식 카탈로그 동기.
- **Expert/**(24): 진단 콘솔 + MicCheck(음성 캡처/전사) + WalkDiagnostics(시계열 차트).
- **Studio·Teach·Synth·Conversation·Claude·AllyFpv·Remote·Visualization·DesignSystem** 등.

### 4.3 #if APPSTORE (App Store 빌드에서 숨김)
- 탭 제거: `conversation`(Claude CLI 의존), `remote`(샌드박스 SSH 차단).
- WalkData Claude critic 패널, AllyFpv 런처, 외부 CLI 의존 기능 봉인(`b0e5e9d`).

### 4.4 테스트
- `DarwinForgeUITests`(~278 파일), `ForgeCoreTests`(8). **선언 카운트만 — 통과 수 미검증**.

---

## 5. 로봇 온보드 펌웨어 패치 (`firmware-patches/walklab-brokerage/`) — **활성 프론티어**

> 가장 최근 작업이 집중된 영역. 다른 계정이 이어받을 가능성이 가장 높음.

### 5.1 무엇 & 왜
- Mac sparse keyframe 보행(~10Hz 등가)은 아키텍처상 실 로봇 안정보행 불가. 그래서 **로봇 측
  `Walking::GetInstance()`의 8ms/125Hz 루프를 그대로 쓰되**, Mac/패드 명령(stride/period/turn 등)을
  받아 적용하는 **brokerage 모드**를 demo-pilot에 패치로 추가.
- 6개 핵심 파일: `WalkLabBrokerage.{h,cpp}`(온보드 중재 모드·상태머신·D패드/킥/볼추종),
  `GamepadPilot.{h,cpp}`(RG G01 동글 직결 조종), `WalkLabTransport.{h,cpp}`(명령 거버너/슬루/TEL).
  + `main.cpp.patch`·`Makefile.patch`·`install-onboard.sh`·`balltrack.ini`·`deploy-kick.sh`.

### 5.2 명령 프로토콜
- **v1(영구, 14토큰)**: `enabled x y a period foot hip …` — 한 줄 텍스트(`/tmp/df-walklab-cmd`).
- **v2 twist(REP-103 SI)**: `V2 seq t_tx flags vx_mms vy_mms wz_mrad_s period foot hip_cdeg blevel
  pan_cdeg tilt_cdeg` — 로봇이 SI→진폭 변환 소유(`k_x` 초기 1.0, **벤치 확정 TODO**).
- **셰이핑은 로봇이 단일 지점(`ApplyCommandLine`)에서 소유**: ① 결합 엔벨로프 거버너
  (`|x|/x_max+|y|/y_max+|a|/a_max≤1.15`), ② 래치 단위 슬루, ③ 속도비례 게이트 스케줄.
  임의 클라이언트(모바일/Switch/패드) 위험 명령도 로봇이 직접 클램프(이중 방어).
- 텔레메트리: TEL2 30Hz UDP(위상·FSR/CoP·seq_applied). 상세 계약 `docs/ssh-parity-contract.md`.

### 5.3 현재 게임패드 매핑 (RG G01 Anbernic, `GamepadPilot.h`)
- LS=이동/횡, RS=헤드 레이트(팬/틸트), **LT/RT=좌/우 아날로그 회전**, B=E-STOP,
  Y=복구(소프트 토크 램프), X=볼트랙(머리만), **START=볼-추종 자동보행 토글**,
  A=ARM, **LB=왼발 킥(page13)·RB=오른발 킥(page12)**.
- **D-패드 모션**(rising edge, ARM 필요): 위=서기(page16)·아래=앉기(page15)·좌=lPASS(page71)·우=rPASS(page70).
- 현재 튜닝 상수(2026-06-14 실기 튜닝 최종): `ENVELOPE_Y_MAX=32`(측보), `ENVELOPE_A_MAX=28`(회전),
  `GP_MAX_STRIDE_MM=38`. **불변식**: `GP_MAX_SIDE_MM==ENVELOPE_Y_MAX`,
  `GP_MAX_TURN_DEG==ENVELOPE_A_MAX`(구조적 동일 정의 — 한쪽만 바꿔도 발산 불가).
- `GP_DEADMAN_REQUIRED=false`(LB 데드맨 해제 — 이동 게이트는 ARM 단일), `GP_ARM_IDLE_TIMEOUT_MS=15000`.
- failsafe 3티어: ① release 합성→데드맨 해제, ② ENODEV/노드 소멸→disarm+제자리 슬루+재스캔,
  ③ 이벤트 침묵 ≥1.5s→제자리 슬루(disarm 아님). 빌드 게이트 `-DDF_NO_GAMEPAD_PILOT`(기본 ON).
- E-STOP만 예외: 읽기 스레드에서 즉시 `TriggerEstopImmediate()`(Walking::Stop+토크OFF+flag).

### 5.4 최근 작업 (HEAD까지) — **전부 로봇 미배포(OFF)·실기 미검증**
| 커밋 | 내용 | 상태 |
|---|---|---|
| `1bfe8ef`·`1c7f35c` | Anbernic 하드닝 14-에이전트 감사 + Batch A/B/C(A1 ForceDisarm·소스소멸 단일화·신선창 정렬, B2 측보정 정규화, B3 idle timeout) | 호스트 GREEN |
| `423e7f0`·`58866f9`·`ef65c02` | 회전각 18→24→28°, 좌우 보폭/횡속 28→32mm, 트리거 회전 연속화 | 호스트 GREEN |
| `c67fd4a`·`7c89d22` | 볼-추종 자동 보행(START 토글, 싸커 데모 BallFollower 응용, balltrack 0/1/2) + 보행 중 추적 끊김 수정 | 호스트 GREEN |
| `8cdc282` | D-패드 모션(STAND/SIT/PASS_L/PASS_R, 공식 Action 속도 준수, 앉음 상태머신 `m_sitting`) | 호스트 GREEN |
- 안전 사실: STAND도 STANDUP 요구(낙상=auto-getup), 모든 D-패드/킥 ARM 필요.
  킥은 Action 개루프(능동 자이로밸런스 없음) → 감속·착지 settle·사후낙상 즉시 getup으로 안정화(`58efaa8`).
- 호스트 테스트: `tests/test_transport.cpp`(순수 거버너/슬루) + `tests/test_gamepad.cpp`(패드 FSM) →
  합산 **279 checks / 0 fail**.

### 5.5 배포 메커닉 (메모리 `robot-onboard-deploy-mechanics`)
- Mac→로봇 비대화형 배포: **`/usr/bin/ssh`**(homebrew ssh는 UseKeychain 거부),
  `darwin` alias=`robotis@192.168.123.1`(유선 직결+비번), i686 g++4.6.3.
- demo 디렉터리가 robotis 소유라 `install-onboard.sh`를 **sudo 없이** 완주. rc.local 훅 기설치면 스킵.
- **배포는 디스크에만 반영 — 재기동(demo-pilot 재시작) 시 적용**. "터미널에서 배포했는데 안 됨"의
  흔한 원인 = 구 바이너리 잔존(재배포+재기동 필요).

---

## 6. 보조 서브시스템

### 6.1 iOS 동반앱 (`app/mobile/DarwinForgeMobile/`)
- SwiftPM(5.10, iOS 17+) + XcodeGen. `MobilePilotKit`(Foundation, 테스트 가능) +
  `DarwinForgeMobileApp`(SwiftUI). WebSocket relay로 Mac에 콕핏 텔레메트리/제어 중계.
- 구현: relay 클라이언트, 파일럿 상태머신(arm/estop/recover), 3-게이트 ARM, 게임패드 어댑터(30Hz),
  **WalkFrameThrottle(10Hz latest-wins, stop/release는 throttle 안 함)**, 콕핏 HUD.
- **v1.3.0(build 18) TestFlight 출하**. 테스트 17개(통과 수는 호스트 swift test 의존).
- 대기: 실 IMU attitude/robot link quality — iOS 수신 준비됐으나 **Mac `cockpit.telemetry`/`cockpit.link`
  브로드캐스트 미구현**(`app/mobile/.../docs/MAC_COCKPIT_TELEMETRY_PROMPT.md`).

### 6.2 ROG Ally FPV (`app/ally/`, 독립 Cargo 워크스페이스)
- Tauri 2(Windows 타깃), app/core와 분리(Windows 의존을 코어 lock/CI에서 격리).
- 크레이트: `df-wire`(와이어 계약, **W0 완성**, Python↔Rust 골든벡터 패리티 21 tests),
  `ally-link`(ssh/udp/metrics/session, **W1 코어 ~95%**, macOS selftest GREEN ACK eff_hz≈20),
  `ally-cli`(W1 수용 테스트 러너 완성), `ally-input`(**스텁** — gilrs 미통합),
  `ally-pose`(**빈 스텁** — W3 forge-core FK 연결 보류), `darwin-fpv`(Tauri bin, **워크스페이스 미등록**).
- Wave: **W0·W1 완료**(호스트/selftest GREEN), **W1 유선 실기 게이트(Ally 기기) 대기**.
  W2(Tauri 콕핏+카메라)·W3(3D 포즈)·W4(패키징) 보류. 설계 `app/ally/docs/00~05`.
- Mac 진입점: 전문가 'FPV 조종' 탭(`40434a0`).

### 6.3 tools/ (Switch 어플라이언스)
- `switch-pilot`(앱)·`switch-appliance`(Switchroot 봉인 — CFW 아님, Darwin 전용 봉인).
- **전부 하드웨어 미검증**(RCM jig 미보유). Switch↔Darwin SSH 브리지는 실기 검증됨(2026-06-07,
  로봇 IP=192.168.0.33 무선, 123.1은 timeout).

---

## 7. 하드웨어 · 안전 · 게이트 사실 (반드시 숙지)

1. **CM-740(OP2) 펌웨어는 CM-730(OP1)과 핀 비호환 — 절대 교차 플래시 금지.**
2. 모션 저작 전: 정비 스탠드에 거치, 다리 토크 차단(`disableTorque(.leftLeg,.rightLeg)`),
   배터리 분리 손 닿는 곳.
3. **마이크/TCC 기능은 `run-app.sh`로만**(swift run은 Info.plist 없어 TCC 크래시).
4. **로봇·워크트리는 단일 공유 자원** — 세션당 한 번만 접근(코디네이터가 소유권 지정).
   **실기 측정 시 Mac 앱 종료 필수**(시리얼 경합).
5. **유선 `192.168.123.1` 직결이 무선(0.33)보다 ~166x 빠름.** 폴러가 무선에 고착 가능 →
   앱 '유선' 재프로브가 핵심. SSH 폴링은 4~8Hz.
6. 로봇 demo엔 ROBOPLUS 모드 없음(READY/SOCCER/MOTION/VISION만). WalkLab은 auto-mode 경로
   (`/tmp/df-pilot-mode=walklab`)로만 진입.
7. DARWIN-OP엔 ALSA capture 장치 없음 — **음성 캡처는 Mac 마이크로**.
8. 카메라: walklab 중 8080 MJPEG ~8fps 실기검증됨(2026-06-12). 함정 2개(send_image 무조건 호출·
   SIGPIPE SIG_IGN) 기록.
9. 펌웨어 배포는 디스크만 — **재기동 시 적용**(§5.5).

---

## 8. 활성 블로커 (`BLOCKERS.md` 발췌)

| # | 영역 | 핵심 |
|---|---|---|
| B-LAT1 | 레이턴시 | E-STOP/UDP 명령 패스트레인 펌웨어 완비됐으나 **Mac 핸드셰이크 미사용 100% 미배선**(dead code) |
| B-LAT2 | 네트워크 | 무선 경로 고착(유선 166x), SSH 폴링 4~8Hz. 앱 재프로브 배너로 일부 완화 |
| B-LAT3 | 계측 | E-STOP 물리정지 타임스탬프 계측 부재 → 레이턴시 0샘플 |
| B-AS1 | App Store | 코드 완료(P0/P1 시나리오 B). **잔여=개발자 포털**(새 App ID·profile·앱 레코드)·샌드박스 검증·데모 영상 |
| B-HW1 | Switch | 어플라이언스 하드웨어 미검증(RCM jig 미보유) |
| B-FLD1 | 실기 필드 | WalkLab P7·킥 K3·D1/D2·H1/H2 호스트만 GREEN, 필드 게이트 미수행. O3(FSR/IMU 밸런스) 미구현 |
| **B-FLD2** | 실기 필드 | **Anbernic 하드닝 + 게임패드 튜닝 + D-패드 + 볼-추종 전부 로봇 미배포(OFF)·실기 미검증.** 게이트 = M2M p95·침묵 임계·단절 매트릭스 4종 |

> Critical/High 코드 감사 이슈(C1~C3, H1~H5)는 대부분 2026-05-12 해결됨. H1(self_collision 5번째 룰)만 잔여.

---

## 9. 다음 작업 후보 (우선순위 제안)

콜드 스타트로 이어받을 때, 다음 중 사용자 지시에 맞는 것을 선택:

1. **[실기 게이트] B-FLD2 배포·검증** — 가장 최근 작업(하드닝/D패드/볼추종)을 로봇에 배포하고
   입회 검증. `install-onboard.sh`로 6파일 배포 → demo-pilot 재기동 → ARM→D패드/볼추종 거동 확인.
   *전제*: 로봇 전원 ON + 사용자 입회. 측정 중 Mac 앱 종료.
2. **[레이턴시] B-LAT1/3 배선** — UDP 명령 패스트레인이 펌웨어엔 있으나 Mac이 미사용. Mac 핸드셰이크
   배선 + E-STOP 물리정지 계측 수단. 설계 `docs/design/cockpit-latency-hardening.md` +
   `docs/reports/2026-06-13-latency-network-investigation.md`(9-에이전트 로드맵 Wave0~3).
3. **[iOS] cockpit.telemetry/link 브로드캐스트** — Mac이 실 IMU attitude/robot link quality를
   iOS로 송출(iOS는 이미 수신 준비). 가이드 `app/mobile/.../docs/MAC_COCKPIT_TELEMETRY_PROMPT.md`.
4. **[Ally] W1 유선 실기 게이트 또는 W2 Tauri 콕핏** — ally-input gilrs 통합(W1) 또는 darwin-fpv
   Tauri 셸(W2). 설계 `app/ally/docs/04_ACCEPTANCE_ROADMAP.md`.
5. **[App Store] B-AS1** — 개발자 포털 작업(사용자 영역) + 아카이브 샌드박스 검증.
   플랜 `docs/app-review/2026-06-13-pass-master-plan.md`.
6. **[코어 심화] 보행 IK / V4 정적안정성** — `walk/engine.rs` 실 IK, `static_stability.rs` 실 CoM
   (URDF+IK 필요). 장기 과제.

> **HARD-GATE**: 3파일 이상 변경·아키텍처/API/스키마 변경이면 `/plan` 먼저, 사용자 승인 후 코딩.
> 단순 1~2파일 수정·타이포·버그 패치는 예외.

---

## 10. 문서 지도

- **상태**: `PROGRESS.md`(살아있는 진행), `ROADMAP.md`, `BLOCKERS.md`.
- **롤업**: `docs/reports/2026-06-rollup.md`(2026-06 월간 8-arc 상세 원장 — 커밋해시·검증여부까지).
- **설계(design/)**: `gamepad-kick-motion.md`, `anbernic-gait-upgrade.md`,
  `anbernic-dongle-direct-control-hardening.md`, `walklab-onboard-teleop-upgrade.md`,
  `bus-direct-teleop-upgrade.md`, `cockpit-latency-hardening.md`, `3d-viewport-enhancement.md`,
  `handheld-direct-pilot-upgrade.md`, `implementation-prompts.md`(P1~P12 복붙용).
- **보고서(reports/)**: `2026-06-13-rgg01-bringup.md`(실기 브링업 입회),
  `2026-06-13-latency-network-investigation.md`, `2026-06-14-anbernic-control-hardening-*.md`,
  `2026-06-12-rgg01-usb-probe.md`(045e:028e 동글 확정).
- **프로토콜**: `docs/protocols/`(Dynamixel 1.0/2.0, CM-730/740), `docs/ssh-parity-contract.md`.
- **ADR**: `docs/decisions/`(ADR-001~013). **App Store**: `docs/app-review/`.
- **펌웨어**: `firmware-patches/walklab-brokerage/{README,INTEGRATION}.md`.
- **Ally**: `app/ally/docs/00~05`.

### 10.1 자동 메모리 (다른 계정엔 없음 — 핵심만 발췌)
> 이 사실들은 사용자 로컬 메모리(`~/.claude/.../memory/`)에 있어 **새 계정엔 자동 로드되지 않는다.**
> 위 §7 게이트 사실 + 다음을 인지: 앱 아이콘 변경 금지(사용자 지정 영구), 콕핏 매핑창=독립 NSWindow
> 1200×820(.sheet/오버레이 모두 잘림), 로봇 세션 경합 규칙, 펌웨어 배포 메커닉(§5.5).

---

## 11. 인계 체크리스트

새 계정/세션이 시작할 때:
- [ ] `git log --oneline -15` 로 HEAD(`8cdc282`)·최근 작업 arc 파악.
- [ ] `cargo test --workspace --manifest-path app/core/Cargo.toml` → 382/382 재현.
- [ ] `make -C firmware-patches/walklab-brokerage/tests` → 279 checks 재현.
- [ ] §7 게이트 사실 숙지(마이크=run-app.sh, 로봇=단일 자원, 유선 166x, 배포=재기동 적용).
- [ ] 작업 대상 정하면 §9 우선순위 + 해당 설계 문서 정독 → (3파일↑이면) `/plan`.
- [ ] 실기 작업이면 **사용자 입회 + 로봇 전원 + Mac 앱 종료** 필수.

---

*작성: 2026-06-14. 근거: `cargo test`/펌웨어 호스트 테스트 실측 + 코드베이스 3-에이전트 매핑 +
firmware-patches 직접 정독. 갱신 시 본 문서 상단 날짜·HEAD·테스트 수치를 함께 갱신.*
