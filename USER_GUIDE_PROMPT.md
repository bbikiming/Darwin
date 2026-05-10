# DarwinForge 사용자 가이드 — Claude 도식화 프롬프트

> **이 파일의 용도**
> 이 markdown 전체를 Claude(claude.ai 또는 Claude Code)에 그대로 붙여넣어, 본 프로젝트(DarwinForge / claude-forge)의 **현재 구현 규모**를 시각적·다이어그램 중심으로 설명하는 **단일 HTML 사용자 가이드**를 생성하기 위한 프롬프트.
>
> 프롬프트는 Claude가 **추가 질문 없이** 한 번에 완성된 문서를 만들 수 있도록 모든 사실 자료를 본문에 그대로 임베드했다. 인용·재가공은 자유.
>
> **소스 진실(source of truth)**: 이 저장소(2026-05-10 시점 main 브랜치) — `README.md`, `ROADMAP.md`, `PROGRESS.md`, `docs/decisions/ADR-001..013`, `docs/architecture/*.md`, `docs/protocols/*.md`, `docs/motion-format/*.md`, `harness/**/*.md`, `app/core/forge-core/src/**/*.rs`, `app/core/forge-cli/src/main.rs`, `app/ui/DarwinForge/**/*.swift`, `docs/reports/SPRINT_*_REPORT.md`.

---

## ✂️ 여기서부터 Claude에 붙여넣기 ─────────────────────

# 역할

당신은 **로보틱스 플랫폼 테크니컬 라이터 + 인포그래픽 디자이너**다. 사용자(개발자·연구자·조립 담당자)가 처음 이 저장소를 받아도 **현재 어디까지 만들어졌고 / 어떻게 굴러가고 / 어떻게 시작하면 되는지**를 30분 안에 파악할 수 있도록, **다이어그램 중심**의 한국어 사용자 가이드를 한 번에 생성한다.

# 결과물 사양

- **출력 형식**: **단일 자급식(self-contained) HTML 파일 1개**.
  - `<!DOCTYPE html>` 부터 `</html>` 까지 하나의 artifact.
  - 한국어 본문(영문 식별자 그대로 유지) + 영문 코드 식별자.
  - **Mermaid v10 CDN** (`https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js`)로 다이어그램 렌더링.
  - **Tailwind CDN** (`https://cdn.tailwindcss.com`) 또는 인라인 CSS로 디자인.
  - **Inter / Pretendard** 폰트(Google Fonts) — 한글 가독성 확보.
  - 좌측 sticky 사이드바 ToC + 우측 본문 + 인쇄 친화 스타일(`@media print`).
- **인터랙티브**: 사이드바 클릭 → 스크롤 점프, 다이어그램 클릭 시 확대(modal) 옵션.
- **다크 모드**: prefers-color-scheme 기반 자동 전환 + 상단 토글.
- **목표 분량**: A4 PDF로 12~20쪽 기준의 정보량. 텍스트는 **간결**, 정보는 **표·다이어그램·체크리스트**로.
- **이모지**: 절제. 섹션 헤더 또는 상태 표시(✅ ❌ ⚠️) 정도만.

# 독자(audience persona) — 3종

각 독자가 "처음 30초"에 자기 영역을 찾도록 구성한다.

| 페르소나 | 관심사 | 가이드에서 봐야 할 섹션 |
|---|---|---|
| **🤖 로봇 운영자** (실기기 연결·테스트·시연) | "지금 무엇을 할 수 있나? 케이블·전원은?" | Quick Start, Hardware, CLI Cheatsheet, Safety |
| **🧑‍💻 백엔드 개발자** (Rust 코어 확장·FFI) | "모듈 경계·테스트 전략·다음 작업" | Architecture, Rust 모듈 맵, 테스트, ADR 인덱스 |
| **🎨 UI/UX 개발자** (SwiftUI 채움) | "현재 스텁 / FFI 경계 / 도메인 타입" | Swift Package, RootView/MotionEditorView 현황, FFI 계획 |

# 톤 & 스타일 가이드

- **간결**, **정확**, **데이터 우선**. "잘 만들어졌다" 같은 형용사 금지 — 숫자·표·코드로 보인다.
- 마케팅 카피 X. 엔지니어링 문서 + 사용자 가이드 톤.
- 표 셀에 단위(ms / m / V / Mbps / DOF) 표기.
- 모든 외부 인용(ROBOTIS / Ha et al. / ROBOTIS-OP2 module)은 출처 표기.
- 색상 팔레트(Tailwind 기반):
  - **Primary**: `slate-900` 본문 / `indigo-600` 강조 / `slate-100` 배경
  - **Hardware**: `amber-500` (배터리·전원) · `rose-500` (e-stop) · `blue-500` (USB·통신) · `emerald-500` (정상)
  - **Layer**: Rust = `orange-500` / Swift = `sky-500` / 외부 = `slate-400`
- 한국어/영어 혼용 시: "Joint(관절) / Bus(버스) / Frame(프레임)" 형태로 첫 등장에만 병기.

---

# 프로젝트 사실 자료 (Claude는 이 데이터만 사용 — 추측 금지)

## 1. 정체성

- **레포 이름**: `claude-forge` / `DarwinForge` (제품명).
- **저장소**: `git@github.com:bbikiming/Darwin.git` (HTTPS clone via gh: `https://github.com/bbikiming/Darwin`).
- **목적 한 줄**: macOS 전용 통합 앱. ROBOTIS DARWIN-OP 1세대(OP1 / CM-730) 와 ROBOTIS-OP2 2세대(CM-740) **두 대를 USB 직결**로 동시에 다루며, **모션을 설계하고 전략을 프로그래밍**한다.
- **라이선스**: Apache 2.0 (ROBOTIS upstream과 호환).
- **핵심 스택**: **Rust 코어** (`app/core/`) + **SwiftUI UI** (`app/ui/`).
- **승인 모드**: 사용자가 한 번 승인 후 끝까지 자율 (2026-05-09 결정).
- **MVP 달성**: **2026-05-09** (Sprint 6 종료 시점).

## 2. 진행 상태 — Phase + Sprint 매트릭스

다이어그램으로 표현할 핵심 데이터:

| 단계 | 명칭 | 산출물 요약 | 상태 |
|---|---|---|---|
| Phase 0 | Bootstrap | 워크스페이스, bootstrap-tools.sh, vendor/LICENSES | ✅ |
| Phase 1 | Discovery & Archive | 26 엔트리 / 4 클론 (ROBOTIS 공식 4개, 1세대, 커뮤니티, 학술) | ✅ |
| Phase 2 | Knowledge Synthesis | 5 신규 명세 + 2 보존 (`docs/protocols`, `docs/motion-format`, `docs/architecture`) | ✅ |
| Phase 3 | Harness Engineering | BOM 18부품, wiring-diagram.mmd, ADR-006/007/008 | ✅ |
| Phase 4 | App Architecture | ADR-009~013, Cargo workspace 18 tests | ✅ |
| Sprint 1 | Connection Layer | `serial`, `dynamixel::v1/v2/bus`, `controller::cm`, 4 CLI cmds | ✅ (26 tests) |
| Sprint 2 | Live Joint Control | `dynamixel::sync`, `joint::state`, `control::JointController`, 8 ms tick + e-stop | ✅ (35 tests) |
| Sprint 3 | Motion I/O | `motion::page/parser/writer`, `.mtn ↔ JSON`, 2-page fixture | ✅ (43 tests) |
| Sprint 4 | Motion Editor 골격 | `motion::timeline/library` + SwiftUI MotionEditorView 스텁 | ✅ (50 tests) |
| Sprint 5 | Walk Engine MVP | `walk::params/engine/imu`, `forge walk` sim CLI | ✅ (59 tests) |
| Sprint 6 | Vision & Strategy MVP | `vision::frame/segmentation` + `strategy` 5-state FSM, `forge strategy` | ✅ (**73 tests**) |

> **MVP 정의** (ROADMAP §5): "Sprint 1~3 완성 + Sprint 4 골격 + Sprint 5/6 데이터 모델". → 100% 충족.

## 3. 통계 스냅샷 (2026-05-10)

| 지표 | 값 |
|---|---|
| 단계별 보고서 | 11개 (Phase 0~4 + Sprint 1~6) |
| ADR | **13개** (ADR-001~013) |
| 명세 문서 | 12개 (`protocols` 3, `motion-format` 2, `architecture` 4, `harness` 3) |
| Rust 모듈 | **13개** — control, controller, dynamixel(bus·sync·v1·v2), error, joint(+state), motion(page·parser·writer·timeline·library), serial(loopback·posix), strategy, vision(frame·segmentation), walk(engine·imu·params) |
| Rust 테스트 | **73 / 73 통과** (`cargo test --workspace`) |
| Rust LOC (소스) | 3,898 (forge-core 3,380 + forge-cli 518) |
| Swift 타겟 | **11개** SwiftPM (executable 2 + library 9) |
| Swift LOC (소스) | 748 (Sources) + 97 (Tests) |
| Swift 테스트 타겟 | 3 (DynamixelKit, RobotKit, HarnessKit) |
| `forge` CLI 서브커맨드 | **9개** |
| Hardware BOM 부품 | 18 (OP1 15 + OP2 3 추가). OP1 합계 ~$584, OP2 합계 ~$640 |
| Research INDEX | 26 엔트리 |

## 4. 디렉토리 구조

```
claude-forge/
├── README.md, PROGRESS.md, ROADMAP.md, BLOCKERS.md, CONTRIBUTING.md, LICENSE
├── docs/
│   ├── architecture/   joint-conventions, op1-vs-op2-matrix, sensor-stack, walking-engine
│   ├── protocols/      dynamixel-1.0, dynamixel-2.0, cm-730-740
│   ├── motion-format/  mtn-format, page-format
│   ├── harness/        engineering-foundations, data-model
│   ├── decisions/      ADR-001..013
│   └── reports/        PHASE_0..4_REPORT, SPRINT_1..6_REPORT
├── research/           SURVEY, INDEX, EXTERNAL_LINKS, papers/REFERENCES.bib,
│                       robotis-official/{DynamixelSDK, ROBOTIS-Framework,
│                       ROBOTIS-OP2, ROBOTIS-OP-Series-Data}
├── vendor/             LICENSES.md + reference 문서
├── harness/
│   ├── op1/            BOM.md, leg-l-bus.yaml
│   ├── op2/            BOM.md
│   └── shared/         cable-specs, mac-driver-setup, safety, wiring-diagram.mmd
├── app/
│   ├── core/                       Rust 워크스페이스
│   │   ├── Cargo.toml              (workspace, resolver=2)
│   │   ├── forge-core/             라이브러리 크레이트
│   │   └── forge-cli/              실행 바이너리 `forge`
│   ├── ui/DarwinForge/             SwiftPM 11-target
│   │   ├── Package.swift
│   │   ├── Sources/                DarwinForgeApp, DarwinForgeCLI, DarwinForgeUI,
│   │   │                           DynamixelKit, HarnessKit, OnboardSyncKit,
│   │   │                           PersistenceKit, RemoteShellKit, RobotKit,
│   │   │                           SerialPortKit, WireVizBridge
│   │   └── Tests/                  DynamixelKitTests, RobotKitTests, HarnessKitTests
│   ├── motion-engine/, walk-engine/  README only — Phase 4에서 forge-core 통합
│   └── tests/                       e2e fixtures
├── motions/            모션 라이브러리 (현재 README only)
└── scripts/            bootstrap-tools.sh, check-mac-drivers.sh, dxl_scan.sh,
                        firmware_backup.sh, harness/probe.sh, render_wireviz.sh
```

## 5. 시스템 아키텍처 — 3계층

### 5.1 하드웨어 계층

- **Mac (Apple Silicon)** ↔ **USB Mini-B (2 m, double-shielded, ferrite at host)** ↔ **CM-730 (OP1) / CM-740 (OP2) sub-controller** (STM32F103RE @ 72 MHz).
- Sub-controller ↔ **Dynamixel TTL bus 1 Mbps half-duplex** ↔ **20× MX-28T 서보** (사용 ID: 1..6, 11..20 = **16 active joints**).
- Sub-controller ↔ **FSR 111 / 112** (좌·우 발 압력 — 옵션).
- Sub-controller ↔ **USB 카메라 Logitech C905** (현 단계: 카메라 캡처는 Mac AVFoundation으로 위임).
- 전원: **LiPo 11.1 V 1300 mAh 25C (Tattu)** 또는 **외부 SMPS 12 V 5 A 60 W (Mean Well GST60A12-P1J)**, 사이에 **inline SPDT toggle e-stop (5 A, red lockout)**.
- **USB hub 사용 금지** (FTDI latency 변동 회피).
- 옵션 경로 (option B): U2D2 dongle (USB-C → 3-pin TTL) 직접 Dynamixel bus 접속.

### 5.2 소프트웨어 계층 — Rust 코어 + SwiftUI UI (ADR-009)

| 책임 | Rust (`app/core/forge-core`) | Swift (`app/ui/DarwinForge`) |
|---|---|---|
| 직렬 포트 I/O | ✅ `serial` (`PosixSerial`, `LoopbackBus`) | ❌ |
| Dynamixel 코덱 | ✅ `dynamixel::v1` / `v2` / `bus` / `sync` | ❌ |
| CM-730/740 제어 | ✅ `controller::cm` | ❌ |
| 관절 매핑·한계 | ✅ `joint::JointId` / `JointState` / `JointLimits` | (도메인 미러: RobotKit) |
| 모션 데이터 | ✅ `motion::page/parser/writer/timeline/library` | (UI 호출만) |
| 워크 엔진 | ✅ `walk::engine/params/imu` | (UI 호출만) |
| 비전 | ✅ `vision::frame/segmentation` | (카메라 캡처는 Swift) |
| 전략 FSM | ✅ `strategy::StrategyState` | (UI 호출만) |
| 앱 라이프사이클 | ❌ | ✅ `DarwinForgeApp` |
| UI 컴포넌트 | ❌ | ✅ `DarwinForgeUI` |
| 카메라 캡처 | (포맷 변환만 — 미구현) | ✅ AVFoundation (예정) |
| 영속성 | (SQLite 스키마는 forge-core에서 — 예정) | ✅ `PersistenceKit` |
| 온보드 SSH | ❌ | ✅ `RemoteShellKit` + `OnboardSyncKit` |
| 하네스 데이터 | ✅ — | ✅ `HarnessKit` (`Yams`로 `leg-l-bus.yaml` 파싱) |

### 5.3 통합(Integration) 계층 — Boundary 메커니즘

- **1차**: Rust `staticlib` (`libforge_core.a`) + 자동 생성 헤더 → SwiftPM의 `cSettings.headerSearchPath` + `linkedLibrary` → Swift는 `import CForgeCore`.
- **2차**: 복잡 타입은 `swift-bridge` 또는 `uniffi` (Sprint 4 이후 결정).
- **데이터 통과 규약**:
  - 작은 값(int, double, enum) — direct C type
  - 문자열 — `*const c_char` + `String(cString:)`
  - 큰 버퍼 — `*const u8 + len`, Swift는 `Data(bytesNoCopy:)`로 **zero-copy**
  - 복합 객체 — JSON serialize → Swift `Codable`로 decode
- **비동기**: Rust 코어는 synchronous + `std::thread`. Swift는 `async/await`. FFI 호출은 모두 sync + 별도 `Task`로 spawn.
- **panic 보호**: 모든 export 함수는 `catch_unwind`로 감싸 Swift 측 미정의 동작 방지.

## 6. Rust 코어 모듈 인벤토리

| 모듈 | 파일 (LOC) | 역할 | 핵심 타입 |
|---|---|---|---|
| `error` | error.rs (30) | 공통 에러 | `Error` (`#[from]` thiserror) |
| `serial::posix` | posix.rs (90) | macOS/Linux POSIX serial | `PosixSerial` (open/list_ports/read/write, 1 Mbps 8-N-1) |
| `serial::loopback` | loopback.rs (102) | 단위 테스트용 가짜 버스 | `LoopbackBus` (queue_read / written) |
| `dynamixel::v1` | v1.rs (304) | Protocol 1.0 패킷 코덱 | `Instruction` (Ping/ReadData/WriteData/RegWrite/Action/FactoryReset/Reboot/SyncWrite/BulkRead), `ErrorFlags`, `InstructionPacket`, `StatusPacket`, `Codec::checksum` |
| `dynamixel::v2` | v2.rs (6) | Protocol 2.0 placeholder | (Sprint 후속) |
| `dynamixel::bus` | bus.rs (186) | `Bus<P: SerialPort>` 추상화 | `ping`, `read`, `write`, `scan`, `with_timeout` |
| `dynamixel::sync` | sync.rs (141) | SYNC_WRITE / BULK_READ 코덱 | `SyncWriteEntry`, `BulkReadEntry` |
| `controller::cm` | cm.rs (133) | CM-730/740 wrapper (ID 200) | `CmController`, `BoardSnapshot` (model/version/voltage/button), `set_dxl_power`, `set_chest_led` |
| `joint` | mod.rs (173) | 16-DOF 매핑 | `JointId` enum, `BodyPart`, `position_to_radians` / `radians_to_position` |
| `joint::state` | state.rs (102) | 관절 상태 + 한계 | `JointState` (goal/present/speed/load/voltage/temp/torque), `JointLimits` (clamp_position) |
| `control` | mod.rs (204) | 다중 관절 명령 + 안전 강제 | `JointController` (`set_position` clamps, `set_torque_many` SYNC_WRITE, `read_state` 3-read assemble, `emergency_stop`) |
| `motion::page` | page.rs (175) | Page / Step 데이터 | `MotionStep` (31-slot positions), `MotionPage` (compliance[31], next/exit/repeat/speed/accel), `Motion` (version + pages) |
| `motion::parser` | parser.rs (241) | `.mtn` 텍스트 파서 | `parse_mtn`, `ParseError` (9가지 variant) |
| `motion::writer` | writer.rs (121) | `.mtn` 라이터 | `write_mtn`, round-trip lossless |
| `motion::timeline` | timeline.rs (124) | 키프레임 보간 | `Interpolation::{Linear, SmoothInOut}` |
| `motion::library` | library.rs (113) | 모션 라이브러리 | `MotionLibrary` (in-memory) |
| `walk::params` | params.rs (139) | 워킹 파라미터 | `WalkParams` (period_time=600 ms, dsp_ratio=0.1, foot_height=0.04 m, balance_*_gain 4종, p_gain=32) — `op2_walking_module/config/param.yaml` 1:1 |
| `walk::imu` | imu.rs (101) | Complementary filter | `ComplementaryFilter` (gyro_weight=0.98), `ImuSample` |
| `walk::engine` | engine.rs (209) | Phase + sin파 발 궤적 | `WalkEngine`, `WalkCommand` (x/y/a amplitude + enabled), `WalkPhase` (Phase0~3), `FootTargets` |
| `vision::frame` | frame.rs (117) | 이미지 + HSV 변환 | `Pixel` (RGBA + HSV via atan2), `Frame` (Vec<Pixel>) |
| `vision::segmentation` | segmentation.rs (152) | HSV blob detection | `HsvRange::{ROBOCUP_BALL, ROBOCUP_GOAL_YELLOW}`, `BlobResult` (pixel_count + centroid), `detect_blob` |
| `strategy` | mod.rs (188) | 5-state FSM | `StrategyState::{Idle, LookingForBall, ApproachingBall, Kicking, Cooldown}`, `StrategyInput`, `next` deterministic transitions |

**의존성 (workspace.dependencies)**: `thiserror 1.0`, `anyhow 1.0`, `serde 1.0`, `serde_json 1.0`, `clap 4.5`, `tracing 0.1`, `tracing-subscriber 0.3`, `serialport 4.7+`, `nix 0.26`.

## 7. SwiftUI 11-target 패키지 (Package.swift)

플랫폼: `.macOS(.v14)`. swift-tools-version 5.10. 의존성: swift-nio 2.65+, swift-nio-ssh 0.10+, Yams 5.1+, swift-argument-parser 1.4+.

```
[Executable]
  DarwinForgeApp     ← DarwinForgeUI                   (앱 진입점)
  DarwinForgeCLI     ← RobotKit, HarnessKit,           (보조 CLI — Swift 측)
                       DynamixelKit, SerialPortKit,
                       ArgumentParser

[UI]
  DarwinForgeUI      ← RobotKit, HarnessKit, DynamixelKit,
                       OnboardSyncKit, PersistenceKit, WireVizBridge
                       (현재: RootView + MotionEditorView 스켈레톤만)

[Application Services]
  OnboardSyncKit     ← RemoteShellKit, RobotKit
  PersistenceKit     ← RobotKit, HarnessKit
  WireVizBridge      ← HarnessKit

[Domain]
  RobotKit           (no deps — 도메인 타입 미러: Joint, Robot)
  HarnessKit         ← Yams                           (leg-l-bus.yaml 파싱)

[Infrastructure]
  SerialPortKit      (no deps)                        (* 향후 forge-core가 대체)
  DynamixelKit       ← SerialPortKit                  (* 향후 forge-core가 대체)
  RemoteShellKit     ← NIOCore, NIOSSH                (온보드 SSH)

[Tests]
  DynamixelKitTests, RobotKitTests, HarnessKitTests
```

> ADR-009 부속: `SerialPortKit`, `DynamixelKit`은 Sprint 1 이후 **Rust forge-core가 대체**. 현재 Swift 구현은 빌드는 되지만 향후 FFI로 교체 예정. `RobotKit` / `HarnessKit`은 데이터 모델만 유지, 로직은 Rust 호출로.

**현재 SwiftUI 화면 (Sources/DarwinForgeUI/)**:
- `RootView.swift` — `NavigationSplitView`로 `[Robot]` 사이드바 (다윈-1G / 다윈-2G), 디테일은 `ContentUnavailableView`. (~22 lines)
- `MotionEditorView.swift` — `[MotionPageStub]` 사이드바(Stand Up, Wave 샘플) + 디테일은 "Sprint 4 스켈레톤" 텍스트. forge-core::motion FFI 후 채워짐 명시. (~40 lines)

## 8. `forge` CLI — 9개 서브커맨드

```text
forge ports                                      USB 직렬 포트 나열
forge ping --port <path> [--id 200] [--baud 1000000] [--timeout 200]
forge scan --port <path> [--range 1-20] [--baud 1000000] [--timeout 50]
forge board --port <path> [--baud 1000000]       CM 모델/버전/전압/버튼 출력
forge list-joints                                16개 캐논 관절 표
forge joint set    --port --id <u8> <pos 0..4095>     position SYNC clamped
forge joint state  --port --id <u8>                   goal/present/speed/load/V/°C/torque
forge joint torque --port --target all|<id> --enable on|off
forge joint estop  --port                              모든 관절 토크 OFF (⌘⇧.)
forge motion import <input.mtn>  [--output X.json] [--generation op|op2]
forge motion export <input.json> [--output X.mtn]
forge motion inspect <input.mtn|.json>           page id/name/steps/next/exit/repeat/speed
forge walk [--x 0.0] [--y 0.0] [--a 0.0] [--cycles 1]   시뮬레이션 (실기기 명령 X)
forge strategy [--ball found|none]               FSM 6 step 시뮬레이션
```

**컨테이너에서 실 동작 검증된 것**: `list-joints`, `ports` (빈 결과 출력), `motion import/export/inspect` (LoopbackBus + fixture), `walk` sim, `strategy` sim. **실기기 USB 연결이 필수**: `ping`, `scan`, `board`, `joint set/state/torque/estop` (Mac 사용자 측에서 검증).

## 9. 16-DOF 관절 매핑 + 특수 ID

`docs/architecture/joint-conventions.md` + `forge-core/src/joint/mod.rs`. ID는 ROBOTIS `JointData.h`와 동일.

| ID | 심볼 | 부위 | 축 | + 방향 | 안전 한계 |
|---|---|---|---|---|---|
| 1 | R_SHOULDER_PITCH | 우 어깨 | pitch | 앞으로 들기 | -180° / +180° |
| 2 | L_SHOULDER_PITCH | 좌 어깨 | pitch | 앞으로 들기 | -180° / +180° |
| 3 | R_SHOULDER_ROLL | 우 어깨 | roll | 옆으로 벌리기 | -90° / +90° |
| 4 | L_SHOULDER_ROLL | 좌 어깨 | roll | 옆으로 벌리기 | -90° / +90° |
| 5 | R_ELBOW | 우 팔꿈치 | pitch | 굽히기 | 0° / +150° |
| 6 | L_ELBOW | 좌 팔꿈치 | pitch | 굽히기 | 0° / +150° |
| 11 | R_HIP_YAW | 우 고관절 | yaw | 안쪽 회전 | -90° / +90° |
| 12 | L_HIP_YAW | 좌 고관절 | yaw | 안쪽 회전 | -90° / +90° |
| 13 | R_HIP_ROLL | 우 고관절 | roll | 다리 벌리기 | -45° / +45° |
| 14 | L_HIP_ROLL | 좌 고관절 | roll | 다리 벌리기 | -45° / +45° |
| 15 | R_HIP_PITCH | 우 고관절 | pitch | 다리 들기 | -90° / +60° |
| 16 | L_HIP_PITCH | 좌 고관절 | pitch | 다리 들기 | -90° / +60° |
| 17 | R_KNEE | 우 무릎 | pitch | 굽히기 | 0° / +150° |
| 18 | L_KNEE | 좌 무릎 | pitch | 굽히기 | 0° / +150° |
| 19 | HEAD_PAN | 목 | yaw | 좌측 회전 | -90° / +90° |
| 20 | HEAD_TILT | 목 | pitch | 위로 들기 | -45° / +45° |

특수 ID — `joint::special`:
- **200** CM-730 / CM-740 sub-controller
- **254** broadcast (no response)
- **111** 우측 발 FSR
- **112** 좌측 발 FSR

> ID 7~10은 사용 안 함 (구버전 흔적). MX-28T 위치 레지스터: 0..4095, 2048 = 0°, `position_radians = (raw - 2048) * π / 2048`.

## 10. 핵심 알고리즘 — 3종

### 10.1 Walking Engine (Sprint 5)

ROBOTIS-OP2 `op2_walking_module` 1:1 포팅. **고정 주기 + ZMP 보정** closed-form 보행 패턴 생성기 (Ha et al. RoMeLa).

- 주기: `period_time = 600 ms`
- 위상: `Phase0 (정지) → Phase1 (첫 발 떼기) → Phase2 (양 발 지지, DSP 비율 0.1) → Phase3 (다음 발 떼기)`
- 발 궤적: `z_swing = foot_height * sin(theta + π/2).max(0)` (위로 들기 절반 사이클), `x_swing = x_amp * cos(theta)`, `y_swing = y_amp * cos(theta)` — 좌·우 발 반대 위상.
- 균형 보정 게인: `balance_hip_roll_gain=0.5`, `balance_knee_gain=0.3`, `balance_ankle_roll_gain=1.0`, `balance_ankle_pitch_gain=0.9`.
- 8 ms 실시간 루프 (`loop every 8 ms: BULK_READ → estimate roll/pitch → update_balance → 20-joint SYNC_WRITE`).
- 입력 명령: `WalkCommand { x_amplitude (m/cycle), y_amplitude (m/cycle), a_amplitude (rad/cycle), enabled }`.
- **현재 한계**: 실 6-DOF leg IK 미구현(foot_targets은 골반 좌표계 위치만). IMU 닫힌 루프 미연결. 실기기 검증은 후속.

### 10.2 Vision (Sprint 6)

- `Pixel` — RGBA + HSV 변환(atan2 기반 색상환).
- `Frame` — `Vec<Pixel>` + width/height + `solid()` / `get_pixel` / `set_pixel`.
- `HsvRange` — h_min/h_max wrap-around 지원, s/v floor.
- 사전 정의: `HsvRange::ROBOCUP_BALL` (주황 0..30°), `HsvRange::ROBOCUP_GOAL_YELLOW` (40..70°).
- `detect_blob(&Frame, HsvRange) -> BlobResult { pixel_count, centroid_x, centroid_y }`. `BlobResult::NONE`, `found()`.
- **현재 한계**: 카메라 캡처는 Mac AVFoundation 측 후속. 거리 추정은 픽셀 카운트 기반 (캘리브레이션 미적용).

### 10.3 Strategy FSM (Sprint 6)

5-state deterministic FSM:

```
Idle  ──[start]──>  LookingForBall
LookingForBall  ──[ball found]──>  ApproachingBall
LookingForBall  ──[no ball]──>  LookingForBall (self-loop)
ApproachingBall  ──[lost ball]──>  LookingForBall
ApproachingBall  ──[is_close_enough(pixel_count > 1000)]──>  Kicking
ApproachingBall  ──[else]──>  ApproachingBall (self-loop)
Kicking  ──>  Cooldown (unconditional next tick)
Cooldown  ──[since_kick_ms > 1500]──>  LookingForBall
Cooldown  ──[else]──>  Cooldown
*  ──[abort]──>  Idle  (어떤 상태에서든 abort=true면 Idle로)
```

- 입력: `StrategyInput { ball: BlobResult, since_kick_ms: u32, abort: bool }`.
- 거리 판정: `pixel_count > 1000` (320×240 frame 기준 약 1.3%). 카메라 calibration 없는 MVP 휴리스틱.
- **현재 한계**: FSM은 Walk/Joint 명령을 발행하지 않음 — 순수 결정 로직. 실 액션 dispatch는 Mac 측 strategy harness에서.

## 11. Dynamixel Protocol 1.0 핵심

- 헤더: `0xFF 0xFF`, ID, LENGTH, INSTRUCTION, PARAMS..., CHECKSUM.
- Half-duplex TTL bus @ 1 Mbps (서보 전체 데이지체인).
- Instructions (구현됨): `Ping (0x01)`, `ReadData (0x02)`, `WriteData (0x03)`, `RegWrite (0x04)`, `Action (0x05)`, `FactoryReset (0x06)`, `Reboot (0x08)`, `SyncWrite (0x83)`, `BulkRead (0x92)`.
- Status 패킷 ERROR 비트: INPUT_VOLTAGE(1), ANGLE_LIMIT(2), OVERHEATING(4), RANGE(8), CHECKSUM(16), OVERLOAD(32), INSTRUCTION(64).
- Sub-controller ID = 200 (CM-730 / CM-740). Broadcast = 254.

## 12. Hardware BOM 요약

OP1 ~$584 (15부품) + OP2 ~$56 추가 (3부품) = OP2 총 ~$640.

| 카테고리 | OP1 USD | 핵심 부품 |
|---|---|---|
| 통신 | 38 | USB Mini-B 2 m double-shielded ferrite, USB-A↔C 어댑터, FTDI 디버그 케이블 |
| 전원·배터리 | 168 | Mean Well GST60A12-P1J 12V/5A SMPS, DC 5.5×2.5 2 m, **inline SPDT e-stop 5 A red lockout**, Tattu 11.1 V 1300 mAh 25C ×2, IMAX B6 충전기, LiPo safe bag |
| 진단·안전 | 348 | Fluke 117 멀티미터, UNI-T UT210E 클램프(100 A), Fluke 62 MAX IR 온도계, LiPo cell checker |
| 보관·운반 | 30 | foam-lined 트레이, 정비 cradle 스탠드 |
| **OP2 추가** | **+56** | mini-HDMI ↔ HDMI, mSATA → USB 3.0, mSATA SSD 64 GB spare |

**자주 망가지는 부품 (OP1 특유)** — 2배수 재고 권장: LiPo 배터리(~200 cycle), USB Mini-B 커넥터(잦은 탈착 → 솔더 fatigue), MX-28 호른 기어(낙하 즉시 손상).

## 13. 안전 규약 (`harness/shared/safety.md` + ADR-008)

- **e-stop = 빨간 lockout 토글 1개**, LiPo + → CM 사이 inline.
- 모터 토크 ON 전 **반드시 cradle 스탠드에 거치**.
- LiPo 부풀면 즉시 폐기.
- 9.5 V 이하면 `forge board` 출력에 ⚠️ 경고. 충전 트리거.
- e-stop 단축키: **⌘⇧.** (소프트 e-stop, 모든 관절 torque OFF SYNC_WRITE).
- USB hub 사용 금지 (FTDI latency 변동 → 패킷 timeout).
- 두 컨트롤 경로(USB direct vs onboard SSH demo)는 동일 `/dev/ttyUSB0` 경합 — ADR-005에 따라 demo 정지 후 USB direct 진입.

## 14. 테스트 전략 (ADR-013) — 4 등급

| 등급 | 위치 | 환경 | 명령 | 현재 |
|---|---|---|---|---|
| 1. Rust unit | `forge-core/src/**/#[cfg(test)] mod tests` | 컨테이너+Mac | `cargo test --lib` | 73 통과 |
| 2. Rust integration | `forge-core/tests/` | 컨테이너+Mac (LoopbackBus) | `cargo test --test '*'` | (fixture 기반) |
| 3. Swift unit | `app/ui/DarwinForge/Tests/` | Mac만 | `swift test` | 3 타겟 (DynamixelKit/RobotKit/HarnessKit) |
| 4. e2e (실기기) | `app/tests/e2e/` | Mac+로봇 | 사용자 수동 + `forge` CLI | 5 시나리오 (ping → joint slider → motion replay → walk start → vision) |

- 1·2 등급 합쳐 **70% 라인 커버리지** 목표 (`cargo llvm-cov`).
- Mock 전략: `LoopbackBus` (Dynamixel), `MockClock` (walk 시간), `MockShell` (OnboardSyncKit), `:memory:` SQLite (실 SQLite 사용, mock X).
- 품질 바: `cargo fmt --check && cargo clippy -- -D warnings && cargo test` (모든 PR).

## 15. ADR 인덱스 — 13건

| # | 제목 | 결정 요지 |
|---|---|---|
| 001 | macOS-only, native Swift / SwiftUI | Mac 전용. 크로스플랫폼 미지원 |
| 002 | Swift Package layout (11 targets) | UI/도메인/인프라 분리 (ADR-009로 일부 보강) |
| 003 | Protocol 1.0 only (OP3 out of scope) | OP1/OP2만, OP3는 Protocol 2.0 — 범위 외 |
| 004 | SwiftData 영속성 + WireViz YAML 교환 | 영속성 + 외부 도구 호환 (ADR-012로 SQLite로 변경) |
| 005 | 2-layer hardware integration | USB direct vs onboard SSH 두 경로를 distinct connection types로 |
| 006 | 통신 경로: 직결 USB vs U2D2 | 1차 USB direct, 옵션으로 U2D2 |
| 007 | 전원: 배터리 vs 외부 SMPS | 양쪽 지원, e-stop 공통 |
| 008 | E-stop topology | inline SPDT toggle (LiPo+ → CM) |
| 009 | Rust + SwiftUI 이원화 | 코어=Rust, UI=Swift. 이유 4가지 (테스트·재사용·성능·crate 생태계) |
| 010 | 모듈 경계 | 책임 분담 표 + staticlib FFI + JSON 통과 |
| 011 | 직렬 추상화 | `SerialPort` trait, `PosixSerial` + `LoopbackBus` |
| 012 | 영속성 (SQLite) | rusqlite, migration v1, `:memory:` 테스트 |
| 013 | 테스트 전략 | 4-등급, 70% 커버리지, mock 표 |

---

# 생성해야 할 다이어그램 — **최소 12개**, 모두 Mermaid

각 다이어그램은 **반드시** 본문 사실 자료의 데이터를 1:1 반영. 새 사실을 추가하지 말고, 위 데이터에서 인용·도식화만.

## D1. 시스템 컨텍스트 (system-context, flowchart LR)

목적: "Mac부터 서보까지 한 그림". 색상 클래스 — `external/robot/power/estop` (저장소의 `harness/shared/wiring-diagram.mmd`와 동일 스타일).

요건:
- Mac (Apple Silicon) → USB Mini-B → CM-730/740 sub-controller → Dynamixel TTL bus → 20× MX-28T(IDs 1..6, 11..20) + FSR 111/112 + USB 카메라.
- 외부 SMPS 12 V 5 A → DC jack. LiPo 11.1 V → e-stop SPDT → battery deans → CM.
- "(NO USB hub)" 명시.
- 옵션 경로 (option B): U2D2 dongle USB-C → 3-pin TTL → DXLBus.

## D2. 소프트웨어 계층 (component diagram, flowchart TD)

목적: Rust 코어 ↔ FFI 경계 ↔ Swift UI 책임 분담을 한눈에.

요건:
- 상단: SwiftUI (`DarwinForgeApp` → `DarwinForgeUI` → `OnboardSyncKit / PersistenceKit / WireVizBridge / RobotKit / HarnessKit`).
- 중간: **FFI Boundary** (점선 박스 — staticlib + JSON serde / catch_unwind).
- 하단: Rust forge-core 모듈 13개를 5개 그룹으로 묶기 (control, dynamixel, motion, walk/strategy/vision, infra(serial/joint/error)).
- forge-cli도 forge-core를 사용함을 화살표로.
- "* SerialPortKit / DynamixelKit는 Sprint 1 이후 forge-core가 대체" 주석 inline.

## D3. Phase + Sprint 타임라인 (gantt 또는 timeline)

목적: 11단계 진행 + 누적 테스트 수.

요건: gantt 사용. 각 항목을 `done` 상태로. 우측 라벨에 누적 테스트(예: `Sprint 6 — 73 tests`).

## D4. Rust 모듈 의존성 그래프 (flowchart TD)

목적: forge-core 13개 모듈 + forge-cli의 의존선.

요건:
- `error`를 모든 모듈이 사용 (점선 표시).
- `serial::{posix, loopback}` ← `dynamixel::bus` ← `controller::cm`.
- `dynamixel::{v1, v2, sync}` ← `bus`.
- `joint::{mod, state}` ← `control` (사용).
- `motion::{page, parser, writer, timeline, library}`.
- `walk::{params, imu, engine}`.
- `vision::{frame, segmentation}` ← `strategy`.
- `forge-cli/main.rs`가 control / controller / dynamixel / joint / motion / serial / strategy / vision / walk를 사용.

## D5. SwiftPM 11-target 의존 그래프 (flowchart TD)

목적: ADR-002 + Package.swift 그대로.

요건:
- 4 layer: Infrastructure(Serial/Dynamixel/RemoteShell), Domain(RobotKit, HarnessKit), App Services(OnboardSync/Persistence/WireVizBridge), UI(DarwinForgeUI), Executable(DarwinForgeApp/CLI).
- 외부 의존성: NIOCore/NIOSSH (RemoteShellKit), Yams (HarnessKit), ArgumentParser (DarwinForgeCLI).
- `*` 표시 — SerialPortKit / DynamixelKit는 Rust forge-core로 대체 예정.

## D6. Strategy FSM (stateDiagram-v2)

`§10.3` 그대로:
- 5 상태 (Idle / LookingForBall / ApproachingBall / Kicking / Cooldown).
- 모든 전이 조건을 화살표 라벨로 표기.
- `[*] --> Idle`, abort 전이는 색상 강조.

## D7. Walking Engine 위상 다이어그램 (stateDiagram-v2)

요건:
- Phase0 → Phase1 (첫 발 떼기, ssp/2) → Phase2 (DSP, dsp_ratio=0.1) → Phase3 (다음 발 떼기, ssp/2) → (period 600 ms wrap).
- enabled=false → Phase0 self-loop.
- 각 phase 옆에 시간 분할 식 표기 (`phase1_time = ssp_ratio * period_time / 2` 등).

## D8. 8 ms 실시간 루프 (sequenceDiagram)

요건: walk loop 한 사이클을 시간순으로.
- `Mac (forge-core)` → `CM-730/740`: BULK_READ (gyro, accel, voltage)
- `CM` → `Mac`: status (raw IMU)
- `Mac` (internal): `ComplementaryFilter::update(gyro, accel)` → roll/pitch
- `Mac` (internal): `WalkEngine::tick(8ms)` + balance gain 적용 → 20 joint targets
- `Mac` → `CM`: SYNC_WRITE goal_position (20 servos)
- `CM` → `MX-28T`: TTL packet (1 Mbps half-duplex)

## D9. 모션 데이터 모델 (classDiagram 또는 erDiagram)

요건:
- `Motion { version, robot_generation, pages: [MotionPage] }`
- `MotionPage { id u8, name 14ch, compliance[31], next_page, exit_page, repeat, speed, accel, steps: [MotionStep] }`
- `MotionStep { positions[31] u16, pause_time u8 (×8 ms), play_time u8 (×8 ms) }`
- 컴포지션 화살표 + JSON ↔ `.mtn` 변환 양방향 표기.

## D10. 16-DOF 관절 트리 (flowchart 또는 mindmap)

요건:
- 루트 `Robot` → Head(HeadPan 19, HeadTilt 20) / RightArm(RShoulderPitch 1, RShoulderRoll 3, RElbow 5) / LeftArm(LShoulderPitch 2, LShoulderRoll 4, LElbow 6) / RightLeg(RHipYaw 11, RHipRoll 13, RHipPitch 15, RKnee 17) / LeftLeg(LHipYaw 12, LHipRoll 14, LHipPitch 16, LKnee 18).
- 특수 ID 200/254/111/112는 별도 사이드 박스.

## D11. Dynamixel Protocol 1.0 패킷 구조 (flowchart 또는 packet)

요건:
- 헤더 박스: `0xFF | 0xFF | ID | LENGTH | INSTRUCTION | PARAMS... | CHECKSUM`.
- 인스트럭션 enum 9개 표 (0x01..0x92).
- ERROR 비트 7가지.

## D12. 안전 토폴로지 (flowchart LR)

요건: ADR-008 그대로.
- LiPo + → e-stop SPDT toggle (red lockout 5A) → Battery Deans T → CM. 토글 OFF 시 배터리 단절.
- ⌘⇧. soft e-stop은 별도 — Mac → SYNC_WRITE TORQUE_ENABLE=0 to all 16 joints.
- 두 종류의 e-stop을 색상으로 구분 (hardware = stroke 3px red, software = dashed orange).

## (옵션) D13. 데이터 플로우 — Vision → Strategy → Walk → Joint

요건: sequenceDiagram. 카메라 frame → HSV blob → BlobResult → StrategyInput → StrategyState 전이 → WalkCommand 또는 Motion page id → JointController SYNC_WRITE.

---

# 가이드 본문 섹션 구성 (필수)

각 섹션은 **다이어그램 1개 이상 + 본문 + 상호참조**.

1. **표지** — 제목, 한 줄 요약, 버전·날짜 (2026-05-10), MVP 달성 배지.
2. **30초 요약** — 카드 4개: "무엇 / 누가 / 어디서 / 지금 무엇이 가능한지". 통계 4종(73 tests / 9 CLI / 13 ADR / 18 BOM 부품).
3. **시스템 개요** — D1 + D2.
4. **현재 진행 상태** — D3 + Phase/Sprint 표.
5. **Quick Start (운영자용)**
   - 사전 준비: `bash scripts/bootstrap-tools.sh`, `bash scripts/check-mac-drivers.sh`.
   - 빌드: `cargo build --release --manifest-path app/core/Cargo.toml` / `swift build --package-path app/ui/DarwinForge`.
   - 첫 명령: `forge ports` → `forge ping --port <path>` → `forge board --port <path>` → `forge scan --port <path>`.
   - 안전 체크리스트.
6. **하드웨어** — D1 + D12 + BOM 표 + 전원·e-stop 지침.
7. **소프트웨어 아키텍처** — D2 + ADR-009/010 요약 + FFI 데이터 통과 표.
8. **Rust 코어 모듈** — D4 + 모듈 표 + 코드 발췌(JointId / ParseError / WalkParams).
9. **SwiftUI 패키지** — D5 + 11-target 표 + 현재 화면 스크린(텍스트로 RootView·MotionEditorView 설명) + 향후 채워질 영역.
10. **CLI 레퍼런스** — 9개 서브커맨드 + 예시 출력(Sprint 보고서 그대로 인용).
11. **알고리즘**
    - 11.1 워킹 — D7 + D8 + 파라미터 yaml.
    - 11.2 비전 — HSV 사전 정의 + BlobResult 식.
    - 11.3 전략 FSM — D6 + D13.
12. **모션 포맷 (`.mtn` ↔ JSON)** — D9 + 31-slot 설명 + round-trip 검증 출력.
13. **관절 매핑** — D10 + 16-DOF 표 + 안전 한계.
14. **Dynamixel Protocol 1.0** — D11 + ERROR 비트 + Sub-controller 200.
15. **테스트 & 품질** — 4-등급 표 + 73 tests breakdown by 모듈 + `cargo fmt/clippy/llvm-cov` 명령.
16. **ADR 인덱스** — 13건 표 + 각 status (Accepted).
17. **로드맵 다음 단계** — PROGRESS.md "다음 단계" 5개 (Mac SwiftUI 본 구현 / 실기기 검증 / walk loop 실 활성화 / 카메라+strategy 통합 / PR #1 리뷰 전환).
18. **FAQ / Troubleshooting** — `forge ports` 빈 결과, 9.5V 미만 경고, FTDI latency, ⌘⇧., demo와 USB direct 충돌.
19. **부록** — 디렉토리 트리(축약) + 글로서리(20개 용어).

---

# UI 요구

- **상단 nav**: 좌측 로고 텍스트 "DarwinForge", 가운데 검색(섹션 제목), 우측 다크모드 토글 + 버전 배지(`v0.1.0 · MVP achieved 2026-05-09`).
- **사이드바 ToC**: 19개 섹션 + 현재 위치 하이라이트 (IntersectionObserver). 모바일은 햄버거.
- **본문 컬럼**: 최대 폭 ~880 px, 본문 폰트 16 px, 행간 1.7.
- **표**: zebra striping, sticky header, 좌측 첫 컬럼 sticky.
- **다이어그램 박스**: 캡션(`그림 D3 — Phase + Sprint 타임라인`) + 다이어그램 + 출처 링크(예: `source: ROADMAP.md §Phase`).
- **코드 블록**: 단일 라이트 테마 + copy 버튼.
- **인쇄 스타일**: 다이어그램 페이지 분리, ToC 숨김.

---

# 정확성 규칙 (반드시 지킬 것)

1. **사실 자료 외 데이터 추가 금지** — 모르면 비워둘 것. "예상", "추정"으로 채우지 말 것.
2. **수치 일관성** — 73 tests, 9 CLI subcommands, 13 ADR, 11 SwiftPM targets, 16 active joints, 18 BOM parts (OP1 15 + OP2 3), 600 ms period, 1 Mbps bus, 8 ms loop. 본문 어디에서도 다른 값 쓰지 말 것.
3. **상태 표시** — Phase 0~4와 Sprint 1~6 모두 ✅. "in progress"·"planned" 표기 금지(MVP 달성).
4. **현재 한계는 반드시 표기** — 실 IK 미구현, 카메라 캡처 미연결, IMU 닫힌 루프 미연결, Mac SwiftUI 본 구현은 스켈레톤만. 거짓으로 "완성됨"이라 쓰지 말 것.
5. **언어 일관성** — UI 본문 한국어, 코드/식별자/CLI 영문 그대로.
6. **출처 표기** — 각 다이어그램 캡션에 1차 출처 파일명(예: `app/core/forge-core/src/strategy/mod.rs`).

---

# 인수 기준 (acceptance checklist)

생성된 HTML이 다음을 **모두** 만족해야 한다:

- [ ] 단일 `.html` 파일 — 외부 CSS/JS 파일 의존 없음(모두 CDN 또는 인라인).
- [ ] 다이어그램 12개 이상 모두 렌더링 (Mermaid 오류 0개).
- [ ] 19개 섹션 ToC + 사이드바 클릭 → 정확히 해당 섹션으로 점프.
- [ ] 표·다이어그램·코드 블록·체크리스트 4종 사용.
- [ ] 다크모드 / 라이트모드 토글 작동.
- [ ] 사실 자료의 모든 수치가 본문과 일치.
- [ ] "현재 한계" 섹션에 실 IK / 카메라 / IMU 닫힌 루프 / SwiftUI 스켈레톤 4종 명시.
- [ ] 한국어 본문 자연스러움 + 영문 식별자 변형 없음(`forge-core`, `JointId::HeadPan`, `HsvRange::ROBOCUP_BALL` 등).
- [ ] 인쇄 시 ToC 숨김 + 다이어그램 페이지 분리.

---

# 산출물 명령

> 위 모든 사양을 충족하는 **단일 HTML artifact**를 즉시 생성하라. 파일은 `darwinforge-user-guide.html`로 명명. 추가 질문 없이 한 번에 완성하라. 길이가 길어도 자르지 말 것.

## ✂️ Claude에 붙여넣기 종료 ─────────────────────

---

# 사용 방법 (본 문서 작성자 / 사용자)

1. 위 `✂️` 사이의 모든 텍스트를 복사.
2. claude.ai / Claude Code 의 새 채팅에 붙여넣기.
3. Claude가 단일 HTML artifact를 생성. 다운로드 후 브라우저에서 열어 확인.
4. 다이어그램이 깨지면 "Mermaid 다이어그램 N번 오류 — 수정해 줘"로 후속 지시.
5. PDF가 필요하면 브라우저 인쇄 → "PDF로 저장" (인쇄 스타일 적용됨).

# 갱신 가이드

본 프로젝트가 변경되면 아래 "프로젝트 사실 자료" 섹션의 숫자/표만 갱신하면 그대로 재사용 가능:
- §3 통계 스냅샷 (테스트 수, LOC, ADR 수)
- §6 Rust 코어 모듈 인벤토리 (모듈 추가 시)
- §7 SwiftUI 11-target (타겟 추가 시)
- §8 CLI 서브커맨드 (커맨드 추가 시)
- §10 알고리즘 한계 (실 IK 구현 등 진척 반영)
- §15 ADR 인덱스 (ADR 추가 시)

# 참고: 파생 사용 사례

- **PDF 매뉴얼**: 위 HTML을 인쇄.
- **온보딩 데크**: 같은 프롬프트의 §1~5 + 다이어그램 D1·D2·D3을 발췌해 슬라이드용으로 변형 요청.
- **README badge**: §3 통계 스냅샷 4개를 shields.io 배지로 변환 요청.
- **PR description**: §15 + "다음 단계" 5개를 PR 설명문으로 압축 요청.
