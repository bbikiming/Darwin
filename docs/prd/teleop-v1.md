# PRD — Remote Teleoperation (원격 조종) v1

> **상태**: Draft — 설계 동결 / 구현 대기
> **작성일**: 2026-05-12
> **대상 스프린트**: Sprint 15 (forge-core::teleop + SwiftUI `RemotePilotView`)
> **선행 의존**: Sprint 1 Connection · Sprint 5 Walk (sim) · Sprint 6 Vision/Strategy · Sprint 8 Safety · Phase B Motion Catalog · BLOCKER C3 (실 IK 부재) — 본 PRD 는 C3 가 stub 인 동안에도 사용자 가치를 내는 single-pass design.

---

## 0. TL;DR — 한 줄 결론

**기존 `Bus`(USB / TCP 5530) + `WalkEngine`(sim) + `WalkPreset`(8 모드) + `StrategyState`(공-추적 FSM) + `vision::detect_blob`(HSV) 다섯 모듈을 “Remote Pilot” 한 화면에 묶어, ⌘8 으로 진입하는 가상 조종기를 만든다.** 두 모드만 제공한다 — (a) **수동 조종**: 가상 D-pad + 슬라이더로 `WalkCommand{x, y, a}` 를 1 Hz~10 Hz 로 발행하고 `forge motion play` 슬롯을 트리거 (kick / sit / wave), (b) **공 팔로우**: `vision_demo` MJPEG → HSV blob → centroid offset 으로 `WalkCommand` 자동 생성, 거리 기준으로 `StrategyState` 단계 전이. **양 모드 모두 같은 4-layer 안전 게이트** (Cradle 체크 / max-duration / IMU roll watchdog / Dead-man hold) 와 같은 명령 송신 경로(`TeleopChannel`)를 공유한다.

---

## 1. 배경 & 문제 정의

### 1.1 현재 상태 (2026-05-12 기준)

| 레이어 | 자산 | 상태 |
|---|---|---|
| **연결** | `Endpoint{usbSerial, network}` + `Bus` + `ConnectionStore` watchdog | ✅ 완성 (Sprint 1, 8) |
| **원격 셸** | `RemoteShellView` (⌘6) — SSH 30 ms / SMB 2 s | ✅ 완성 (디버그·셋업·서비스 제어용) |
| **걷기 시뮬** | `WalkEngine{set_command(x,y,a,enabled), set_period_ms}` | ✅ sim only (BLOCKER C3 — 실 IK 미완성) |
| **걷기 프리셋** | `WalkPreset` 8개 + `WalkSafety{Safe, Caution, HighRisk}` + `max_duration_secs` | ✅ 완성 (Sprint 14 후보) |
| **모션 송출** | `forge motion play --slot N --engage` SYNC_WRITE | ✅ 완성 (Sprint 13 — kick / sit / wave 등 16 페이지) |
| **비전 blob** | `vision::detect_blob(frame, HsvRange::ROBOCUP_BALL)` + `BlobResult{pixel_count, centroid}` | ✅ Rust 완성 (Sprint 6) — Mac 측 카메라 입력만 없음 |
| **전략 FSM** | `StrategyState{Idle, LookingForBall, Approaching, Kicking, Cooldown}` | ✅ 완성 (Sprint 6) |
| **카메라 stream** | 로봇 onboard `vision_demo` MJPEG `http://192.168.123.1:8080/?action=stream` | ✅ 로봇 측 데몬 존재 — Mac UI 가 아직 구독 안 함 |
| **안전 모듈** | `precheck_motion(confirm_risk)` + `TorqueRamper` + `emergencyStop()` ⌘⇧. | ✅ 완성 (Phase B) |

### 1.2 사용자의 요구

> *"현재 모인 모션과 원격 연결의 정보와 데이터를 기반으로 다윈을 원격 조종할 수 있는 기능을 설계해 줘. 프로그램 내에서 가상의 조종기를 통해 로봇을 앞뒤로 조종하거나 공을 팔로우하는 등 원격 조종기 역할을 하는 메뉴를."*

요구 분해:
1. **원격 조종기 메뉴** — 별도의 화면. 기존 `Remote Shell`(⌘6) 과 구분.
2. **앞뒤 조종** — 직진 / 후진 / 좌우 평행이동 / 회전 + 동작 트리거 (kick / wave / sit).
3. **공 팔로우** — 카메라 → 공 → 자동 추적 (사용자 supervision 모드).
4. **현재 모인 정보로** — 기존 모듈 재사용. 새 IK / 새 walk algorithm 없음.
5. **논리적 근거 기반** — 안전·기존 API·MVP 부재(C3) 를 모두 명시.

### 1.3 핵심 제약 (논리적 근거)

| 제약 | 출처 | 영향 |
|---|---|---|
| **C-1**: 실 IK 부재 (BLOCKER C3) | `app/core/forge-core/src/walk/engine.rs` 의 `foot_targets()` 는 sin파 sim only | v1 의 walk 송출은 **WalkPreset 기반 사전 검증된 5종** + sim 미리보기. 임의 (x, y, a) 슬라이더 → 실 모터 직결은 disable. |
| **C-2**: vision\_demo 가 별도 프로세스 | ROBOTIS framework `~/Framework/Linux/project/vision_demo` (자체 USB 점유) | vision\_demo 가 켜져 있으면 forge-bridge 5530 가 ttyUSB0 못 잡음. → Pilot 진입 시 **vision\_demo OFF + bridge ON** 자동 검사. |
| **C-3**: 안전 등급 3-tier | `WalkSafety {Safe, Caution, HighRisk}` + `SafetyClass` (모션) | UI 의 모든 명령 버튼은 등급별 시각 코드 (녹/황/적) + 등급별 자동 stop 시간. |
| **C-4**: 네트워크 jitter | `ConnectionStore.busFailureThreshold` (USB 3, 네트워크 8) | teleop 명령 주기는 USB 100 ms / 네트워크 200 ms 기본. Dead-man hold 가 1 초 끊기면 자동 정지. |
| **C-5**: 한 번에 한 mode | StrategyState 의 `Kicking` 같은 단계 도중 사용자 입력이 깨면 위험 | 모드 전환은 항상 `Idle/Cradle` 경유. Pilot 화면에 항상 큰 정지 버튼. |

---

## 2. 목표 & 비목표

### 2.1 목표 (in-scope, v1)

| # | 목표 | 측정 기준 |
|---|---|---|
| **G1** | Manual Pilot 으로 8 보행 프리셋 + 4 액션 모션 실 송출 | `WalkPreset.ALL` 8개 + page 1(stand) / 4(wave) / 12(right\_kick) / 15(sit\_down) 4개 → 12 버튼이 connected 상태에서 동작 |
| **G2** | Ball-Follow mode 닫힌 루프 | 로봇 카메라 MJPEG 구독 → 매 100 ms blob → centroid offset → `WalkCommand` 자동 → `StrategyState` 전이 |
| **G3** | 4-layer 안전 게이트 | Cradle 체크박스 / max-duration counter / IMU roll watchdog / Dead-man hold 모두 fail 시 자동 stop |
| **G4** | Dead-man-hold UX | 사용자가 “이동” 버튼에서 손 떼면 (mouseUp / keyUp) 1 초 이내 `enabled=false` |
| **G5** | 같은 명령 채널 `TeleopChannel` | Manual / Ball-follow / Conversation 가 같은 `send(walkCmd, motionSlot)` 호출 — 단일 진입점 |
| **G6** | 시뮬 미리보기 우선 | `Bus == nil` 이어도 sim 으로 가상 조종 — “먼저 화면에서 익히기” |
| **G7** | 키보드 + 가상 D-pad | W/A/S/D + 화살표 + 가상 버튼 — 셋 중 어느 것이든 같은 채널로 |

### 2.2 비목표 (out-of-scope, v1 에서 명시 제외)

- **NB-1**: 외부 USB 게임패드 (Xbox / DualShock / Joy-Con) 지원. **v2 후보**.
- **NB-2**: 카메라 stream Mac 측 재인코딩·녹화. v1 은 SwiftUI `WebKit` `WKWebView` 로 MJPEG iframe 만 표시. 비전 분석은 forge-core 가 별도 frame fetch.
- **NB-3**: 다중 로봇 동시 조종. v1 은 한 `ConnectionStore` 인스턴스만 — 한 번에 한 다윈.
- **NB-4**: 음성 조종. `Conversation` (⌘5) 가 이미 자연어 처리. teleop 은 손/키보드만.
- **NB-5**: 실 IK 기반 임의 (x, y, a) 송출. C3 가 풀린 후 v2 에서 슬라이더 풀-스윙 허용.
- **NB-6**: 골 인식 / 자동 슛 결정. Ball-Follow 은 “공만 추적” — 차는 결정은 사용자가 버튼 누름. (`StrategyState::Kicking` 자동 진입은 사용자가 토글한 supervised auto-kick 모드에서만.)

---

## 3. 사용자 스토리 — 4 페르소나

### Persona α — Hobbyist Operator (가상 D-pad)
1. 로봇 cradle 거치, USB or 이더넷 직결.
2. ⌘8 → 원격 조종 진입. 좌측에 큰 D-pad ↑↓←→ / 회전 ↶↷ / 동작 (인사·차기·앉기·일어서기) 4 버튼. 우측에 SceneKit 3D 미러 + 카메라 MJPEG view.
3. ↑ 클릭 holding → 로봇 “보통 속도” 전진. release → 1초 내 정지.
4. “인사” 클릭 → `forge motion play --slot 4` 송출. 진행 중에는 D-pad disable.

### Persona β — Researcher (키보드 power-user)
1. W/A/S/D 로 평행이동, Q/E 로 회전. Shift 누르면 fast 모드, Space 로 즉시 정지.
2. 1..4 숫자키로 모션 슬롯 트리거 (preset 매핑 GUI 에서 재정의 가능).
3. 우측 텔레메트리: 전압 / 평균 온도 / IMU roll-pitch 실시간 + sparkline.

### Persona γ — Ball-Follow Demo
1. 로봇 cradle 거치 + 주황색 공 1 m 앞.
2. ⌘8 → mode 토글 “공 팔로우”.
3. 화면 중앙: 카메라 MJPEG 위에 blob centroid 십자선 + “FOLLOW / IDLE / LOST” 라벨.
4. 사용자가 “Auto-Walk” 토글 ON → centroid offset 이 임계 초과면 `WalkCommand`{turn_left/right} 자동, 가까워지면 sit. **차는 동작은 사용자가 별도 버튼 눌러 트리거** (NB-6).

### Persona δ — Safety Reviewer
1. Pilot 진입 시 cradle 거치 체크박스 + “주변 50 cm 빈 공간 확인” 체크박스 두 개. 둘 다 OFF 면 모든 이동 명령 disable.
2. `WalkPreset::Jog` 또는 페이지 12(`right_kick`) 처럼 HighRisk → 5초 카운트다운 + “위험 인지” 확인.
3. IMU roll > 25° 자동 stop → 사용자에게 토스트 “기울어짐 감지 — 정지”.

---

## 4. 시스템 아키텍처

### 4.1 상위 데이터 흐름

```
                ┌────────────────────────────────────────────────┐
                │              SwiftUI RemotePilotView           │
                │  ┌─────────┐  ┌────────────────┐  ┌──────────┐ │
   사용자 입력 ─┼─►│ Virtual │  │ Camera (MJPEG  │  │ Action   │ │
  (마우스/키보드)│  │  D-pad  │  │  + blob HUD)   │  │ Bar      │ │
                │  └────┬────┘  └────────┬───────┘  └─────┬────┘ │
                │       ▼                ▼                ▼      │
                │  ┌────────────────────────────────────────┐    │
                │  │         TeleopChannel (actor)          │    │
                │  │  - currentMode {.manual, .ballFollow}  │    │
                │  │  - dead-man hold timer (1 s)           │    │
                │  │  - safety gates (cradle, IMU, dur)     │    │
                │  └───┬──────────────────────┬─────────────┘    │
                └──────┼──────────────────────┼──────────────────┘
                       │                      │
                       ▼                      ▼
              ┌────────────────┐    ┌─────────────────────┐
              │ ConnectionStore│    │ BallFollowEngine    │
              │   .bus / EP    │    │ - frame.fetch 100ms │
              └────────┬───────┘    │ - vision::detect_blob│
                       │            │ - centroid→cmd      │
                       ▼            │ - StrategyState     │
              ┌────────────────┐    └──────────┬──────────┘
              │ Bus (USB / TCP)│               │
              │ Sync R/W       │◄──────────────┘
              └────────┬───────┘
                       │
                       ▼
                  Darwin Robot
```

### 4.2 새로 추가되는 컴포넌트 (4 개 + 1 화면)

| 컴포넌트 | 위치 | 책임 |
|---|---|---|
| **`TeleopCommand`** (Rust) | `forge-core/src/teleop/command.rs` | `enum {Walk(WalkCommand), Motion(slot), Stop}` + 안전 등급 + max-duration. JSON serde. |
| **`TeleopChannel`** (Swift) | `app/ui/.../ForgeCore/Teleop.swift` | actor — `send(TeleopCommand)` 단일 진입점. dead-man hold / gate 평가 / `Bus` 호출. |
| **`BallFollowEngine`** (Swift) | `app/ui/.../DarwinForgeUI/Remote/BallFollow.swift` | MJPEG frame fetch (`URLSession` chunked) → `forge-ffi` blob → `WalkCommand` 생성 → `TeleopChannel.send`. |
| **`PilotSafetyGate`** (Swift) | `app/ui/.../DarwinForgeUI/Remote/PilotSafetyGate.swift` | 4-layer 게이트 (`@Published var armed: Bool`). cradle / clearance / IMU / dead-man. |
| **`RemotePilotView`** (Swift) | `app/ui/.../DarwinForgeUI/Remote/RemotePilotView.swift` | 화면. ⌘8 으로 진입. RootView `Section.pilot` 추가. |

### 4.3 명령 송신 주기 (수치 근거)

- **Walk 명령**: USB 100 ms, 네트워크 200 ms (= `ConnectionStore.pollPeriodNs` 동일). 더 빠르면 watchdog false-positive, 더 느리면 응답성 저하.
- **공 팔로우 frame**: 100 ms (10 Hz). `vision_demo` MJPEG 가 ~15 fps 이므로 frame skip 자연 발생.
- **Motion slot 트리거**: 단발. `forge motion play` 가 step duration 만큼 blocking — 그 동안 walk 명령은 `WalkCommand::default()` (enabled=false) 로 idle.
- **Dead-man hold**: 1 초. 마지막 사용자 입력에서 1 초 경과 → `Walk(enabled=false)` 자동.

### 4.4 안전 게이트 4 계층 (각 계층의 차단 시점)

| 계층 | 위치 | 차단 조건 | 동작 |
|---|---|---|---|
| **L1: UI Arming** | `PilotSafetyGate.armed` | cradle 체크 + clearance 체크 둘 다 ON | OFF 면 모든 이동 버튼 disable + 회색 |
| **L2: 등급 confirm** | `WalkPreset.requires_risk_confirmation()` / `SafetyClass::HighRisk` | HighRisk 명령 + `confirm_risk=false` | Alert → 사용자 확인 |
| **L3: Watchdog timer** | `TeleopChannel.deadmanTimer` | `now - lastInputAt > 1s` | `Walk(enabled=false)` 자동 송출 |
| **L4: Telemetry guard** | `BallFollowEngine` 의 IMU 구독 + duration | IMU \|roll\| > 25° / IMU \|pitch\| > 30° / preset.max\_duration\_secs 초과 | `stop()` + 사용자 토스트 |

⌘⇧. (E-stop) 은 L0 — 어느 계층보다 빠르게 `bus.emergencyStop()` 을 trigger.

---

## 5. 인터페이스 명세

### 5.1 Rust `forge-core::teleop` (신규 모듈)

```rust
// forge-core/src/teleop/mod.rs
pub mod command;
pub mod gate;
pub mod ballfollow;

pub use command::TeleopCommand;
pub use gate::{SafetyGate, GateReason};
pub use ballfollow::{BallFollowConfig, BallFollowDecision};
```

```rust
// teleop/command.rs
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum TeleopCommand {
    /// 보행 명령 — `WalkPreset` 또는 임의 (x, y, a) (v2 후 unlock).
    Walk { command: WalkCommand, period_ms: u32, max_duration_secs: u32 },
    /// 모션 페이지 slot 트리거 — `forge motion play` 와 동일.
    Motion { slot: u8, confirm_risk: bool },
    /// 정지 — Walk(enabled=false) + 모든 시퀀스 abort.
    Stop,
}

impl TeleopCommand {
    pub fn safety(&self) -> SafetyClass { ... }
    pub fn max_duration_secs(&self) -> u32 { ... }
}
```

```rust
// teleop/gate.rs
pub struct SafetyGate {
    pub cradle_checked: bool,
    pub clearance_checked: bool,
    pub last_input_at: Instant,
    pub deadman_timeout: Duration,
}

impl SafetyGate {
    /// 명령을 통과시킬지 결정. 차단되면 GateReason 반환.
    pub fn allow(&self, cmd: &TeleopCommand, imu: Option<ImuSample>) -> Result<(), GateReason> { ... }
}

pub enum GateReason {
    NotArmed,                        // L1
    RiskNotConfirmed,                // L2
    DeadmanTimeout,                  // L3
    ImuOutOfRange { roll: f32, pitch: f32 },  // L4
    DurationExceeded { secs: u32 },  // L4
}
```

```rust
// teleop/ballfollow.rs
pub struct BallFollowConfig {
    pub hsv: HsvRange,                 // 기본 ROBOCUP_BALL
    pub close_pixel_threshold: u32,    // 1000 (strategy::is_close_enough 와 동일)
    pub turn_dead_zone_px: f32,        // 30 (centroid x 의 무시 영역)
    pub max_turn_rate: f64,            // 0.15 rad/cycle
    pub forward_amplitude: f64,        // 0.020
}

impl BallFollowConfig {
    /// frame → 결정. StrategyState 와 `TeleopCommand` 둘 다 반환.
    pub fn decide(&self, frame: &Frame, prev_state: StrategyState, since_kick_ms: u32)
                  -> BallFollowDecision { ... }
}

pub struct BallFollowDecision {
    pub state: StrategyState,
    pub command: TeleopCommand,
    pub blob: BlobResult,
}
```

### 5.2 Swift `TeleopChannel` (actor)

```swift
public actor TeleopChannel {
    public enum Mode: Sendable { case manual, ballFollow }

    private let store: ConnectionStore
    private var mode: Mode = .manual
    private var lastInputAt: Date = .now
    private var sessionStart: Date?
    private var gate = SafetyGate()
    private var deadmanTask: Task<Void, Never>?

    public func setMode(_ m: Mode) async { ... }
    public func arm(cradle: Bool, clearance: Bool) async { ... }
    public func disarm() async { ... }

    /// 단일 진입점. Manual UI / BallFollow 둘 다 이걸 호출.
    public func send(_ cmd: TeleopCommand) async throws {
        try gate.allow(cmd: cmd, imu: store.lastImu)
        try await dispatch(cmd)
        lastInputAt = .now
        scheduleDeadman()
    }

    private func dispatch(_ cmd: TeleopCommand) async throws { ... }
    private func scheduleDeadman() { ... }   // 1 s 후 Walk(enabled:false)
}
```

### 5.3 SwiftUI `RemotePilotView`

```swift
public struct RemotePilotView: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject var pilot = TeleopChannel.shared
    @StateObject var ballFollow = BallFollowEngine()
    @State var mode: TeleopChannel.Mode = .manual
    @State var cradleChecked = false
    @State var clearanceChecked = false

    public var body: some View {
        DFPageScaffold("원격 조종", subtitle: "가상 조종기 + 공 팔로우",
                       icon: "gamecontroller.fill", tint: DFColor.accent) {
            HSplit(
                left: { armingPanel; modeSwitcher; manualOrBallControls; telemetryStrip },
                right: { sceneAndCamera }
            )
        }
        .onKeyPress { handleKey($0) }    // W/A/S/D/Q/E/Space/1..4
    }
}
```

### 5.4 RootView 통합

`RootView.Section` 에 `case pilot` 추가:

```swift
case pilot          // ⌘8, icon: "gamecontroller.fill", tint: DFColor.accent
```

`sidebar` 의 `Section.allCases` iteration 으로 자동 노출. `globalShortcuts` 에 `Button("Section 8")` 추가.

---

## 6. UI 레이아웃 — `RemotePilotView` (1280×800 기준)

```
┌─ ⌘8 원격 조종 ───────────────────────────────────────────────────────────────┐
│ ◄ 사이드바      │  좌측 540 px                  │  우측 (남는 공간)            │
│                 │ ┌── 1. 안전 ARM (필수) ─────┐│┌── A. 카메라 + Blob HUD ───┐│
│                 │ │ ☐ 거치대 거치 완료          │││ MJPEG :8080 stream       ││
│                 │ │ ☐ 주변 50 cm 빈 공간        │││ ┌─ centroid (180, 95) ─┐ ││
│                 │ │ [ ARM ] (둘 다 ✓ 시 활성)   │││ │  ●  blob pixels: 312 │ ││
│                 │ └────────────────────────────┘││└──────────────────────┘ ││
│                 │ ┌── 2. 모드 ───────────────┐  ││                          ││
│                 │ │ ⦿ 수동 조종  ◯ 공 팔로우 │  │└──────────────────────────┘│
│                 │ └──────────────────────────┘  │┌── B. 3D 미러 + 발 trail ─┐│
│                 │ ┌── 3. 가상 D-pad ─────────┐  ││ SceneKit RobotScene3D    ││
│                 │ │       [ ↑ ]              │  ││ + WalkEngine sim trail   ││
│                 │ │  [ ← ] [⏹] [ → ]          │  │└──────────────────────────┘│
│                 │ │       [ ↓ ]              │  │┌── C. 텔레메트리 ─────────┐│
│                 │ │  [ ↶ ] [속도▾][ ↷ ]       │  ││ V 11.7  T 38°C  IMU ☑    ││
│                 │ └──────────────────────────┘  ││ Phase: PHASE2 (DSP) 280ms││
│                 │ ┌── 4. 액션 ───────────────┐  ││ Cmd:  x=+0.02  a=0       ││
│                 │ │ [👋 인사] [⚽ 차기]       │  ││ Session: 12 s / max 30 s ││
│                 │ │ [🪑 앉기] [🧍 일어서기]  │  ││ [E-stop ⌘⇧.]              ││
│                 │ └──────────────────────────┘  │└──────────────────────────┘│
└──────────────────────────────────────────────────────────────────────────────┘
```

### 6.1 가상 D-pad — 명령 매핑

| 위젯 | 누르는 동안 | 떼면 | 비고 |
|---|---|---|---|
| ↑ | `Walk{x=+0.025, y=0, a=0, enabled=true}` (NormalWalk preset) | dead-man 1 s 후 stop | shift+↑ = FastWalk |
| ↓ | `x=-0.020` 후진 | 동일 | |
| ←/→ | `y=±0.020` 평행이동 | 동일 | |
| ↶/↷ | `a=±0.10` 회전 (TurnLeft/Right preset) | 동일 | |
| ⏹ | `Stop` 즉시 | — | Space 키 동일 |
| 속도 dropdown | 기본 “보통” / 빠르게 / 천천히 | UI state 만, 송출은 다음 입력부터 | |

### 6.2 Action 버튼 — `forge motion play` 매핑

| 버튼 | slot | SafetyClass | confirm? |
|---|---|---|---|
| 일어서기 (Stand) | 1 | Safe | × |
| 인사 (Hi) | 4 | Safe | × |
| 차기 (Right Kick) | 12 | Caution | × (cradle 확인만) |
| 앉기 (Sit Down) | 15 | Caution | × |

각 버튼은 누른 순간 한 번만 송출. 진행 중에는 모든 D-pad disable + 상단에 “모션 재생 중: Right Kick · 1.4 s” 진행 바.

### 6.3 키보드 매핑 (Persona β)

| 키 | 동작 |
|---|---|
| W / A / S / D | 전진 / 좌평행 / 후진 / 우평행 (hold) |
| Q / E | 좌회전 / 우회전 |
| Space | 즉시 정지 |
| Shift (modifier) | 보폭 ×1.4 (FastWalk) |
| 1..4 | 액션 버튼 4개 |
| ESC | 모드 → Cradle Idle |
| ⌘⇧. | E-Stop (글로벌 단축키 그대로) |

---

## 7. Ball-Follow Mode — 상세 알고리즘

### 7.1 frame 수집

- 로봇 `vision_demo` MJPEG: `http://<host>:8080/?action=stream`.
- Mac UI 는 `URLSession` `dataTask` 로 multipart/x-mixed-replace 구독 → `--myboundary` 로 frame split → 각 frame 을 `UIImage` (macOS `NSImage`) → CGImage → Frame buffer (RGB).
- 그 외 100 ms 마다 ad-hoc `?action=snapshot` JPEG 한 장 fetch (fallback, 더 단순).

### 7.2 frame → 결정 (Rust `BallFollowConfig::decide`)

```
1. detect_blob(frame, hsv_orange) -> BlobResult
2. if !blob.found() OR pixel_count < 50:
       state = LookingForBall
       command = Walk{ a=+0.15, enabled=true }   // 좌로 천천히 회전 = scanning
3. else if pixel_count > close_pixel_threshold (1000):
       state = Kicking
       command = Stop                            // 사용자 supervision — 차는 건 수동 트리거
4. else:
       state = ApproachingBall
       cx_norm = (blob.centroid_x - frame.width/2) / (frame.width/2)  // [-1, +1]
       turn = cx_norm * max_turn_rate (0.15)
       fwd  = forward_amplitude (0.020) * (1 - |cx_norm|)
       command = Walk{ x=fwd, a=turn, enabled=true }
5. return BallFollowDecision { state, command, blob }
```

“dead zone”: `|cx_norm| < 0.10` → `turn = 0` (떨림 방지).

### 7.3 사용자 supervision 옵션

| 토글 | 효과 |
|---|---|
| **Auto-Walk** (기본 ON) | step 2~4 의 `command` 자동 `TeleopChannel.send` |
| **Auto-Kick** (기본 OFF, HighRisk) | step 3 의 `Kicking` 상태 진입 시 `Motion{slot=12, confirm_risk=true}` 자동 트리거. confirm 다이얼로그 1 회 |
| **Auto-Track-Head** (v2 후보) | head pan/tilt (joint id 19/20) 으로 centroid 추적 — v1 비목표 |

### 7.4 LOST 처리

- 5 초 이상 `LookingForBall` 지속 → 자동 stop + 토스트 “공을 찾을 수 없습니다”.
- `pixel_count` 가 직전 frame 의 50% 이하로 급감 → 다음 frame 까지 1 회 grace.

---

## 8. 안전 게이트 — 결정 트리

```
사용자가 D-pad 또는 키보드 입력
        │
        ▼
[L0] ⌘⇧.  ───► bus.emergencyStop() 즉시. UI status .error. session 종료.
        │
        ▼ (E-stop 아님)
[L1] PilotSafetyGate.armed?
   ├── NO  → 모든 명령 무시. 빨간 토스트 "ARM 필요".
   └── YES
        │
        ▼
[L2] cmd.safety == HighRisk && !cmd.confirmRisk
   ├── YES → confirm 알림 → 사용자가 OK 시 다시 send. 취소 시 무시.
   └── NO
        │
        ▼
[L3] now - gate.lastInputAt > 1s?
   ├── YES → 자동 Stop 송출 + L3 deadmanTimer reset.
   └── NO
        │
        ▼
[L4a] IMU.roll.abs() > 25° || IMU.pitch.abs() > 30°
   ├── YES → Stop + 토스트 "기울어짐 감지".
   └── NO
        │
        ▼
[L4b] sessionDuration > preset.max_duration_secs
   ├── YES → Stop + 토스트 "최대 시간 초과".
   └── NO → Bus.send(cmd) (USB 100ms / 네트워크 200ms 캐덴스)
```

---

## 9. 구현 단계 (Sprint 15 — 5 일 추정)

### Day 1: forge-core::teleop 신규 모듈
- `command.rs` (`TeleopCommand` + 단위 테스트 6)
- `gate.rs` (`SafetyGate` + 4 gate reason + 단위 테스트 10)
- `ballfollow.rs` (`BallFollowConfig::decide` + scanning/approach/close 3 분기 + 단위 테스트 8)
- forge-ffi 노출 (`fc_teleop_*`, `fc_ballfollow_decide`)

### Day 2: Swift `TeleopChannel` actor + `PilotSafetyGate`
- actor 단일 진입점 `send(_:)`
- deadmanTask 스케줄러 (1 초 cancel + reschedule)
- IMU 구독 (기존 LiveTelemetry 의 `imuRoll`, `imuPitch` 가 노출돼 있어야 함 — 없으면 보강)
- 단위 테스트: 4 gate fail 케이스 / dead-man / arming.

### Day 3: SwiftUI `RemotePilotView` + 가상 D-pad + 액션 4 버튼
- arming panel + cradle/clearance 체크박스
- D-pad ↑↓←→ (mouseDown/mouseUp), 회전 ↶↷, Stop ⏹
- 4 액션 버튼 (slot 1, 4, 12, 15)
- 키보드 W/A/S/D/Q/E/Space/1..4 + Shift 모디파이어
- 텔레메트리 strip (V / T / IMU / Phase / Session duration)
- E-stop 큰 버튼 + ⌘⇧. 글로벌 단축키 그대로
- RootView `Section.pilot` 등록 + ⌘8

### Day 4: 카메라 MJPEG + BallFollowEngine
- `MjpegStream.swift` URLSession multipart 구독자
- snapshot fallback (`?action=snapshot`) — 더 단순한 1차 implementation
- `BallFollowEngine` — frame 받으면 FFI `fc_ballfollow_decide` 호출 → `TeleopChannel.send`
- 카메라 view 위에 centroid 십자선 + state 라벨 overlay
- Auto-Walk 토글 + Auto-Kick 토글 (HighRisk confirm)

### Day 5: 통합 테스트 + 안전 검증 + 문서
- 모드 전환 race condition 테스트 (manual↔ball)
- dead-man hold E2E
- IMU 시뮬 (LoopbackBus 가 가상 IMU 주입) → L4 차단 확인
- vision\_demo OFF 일 때 명확한 안내 (`forge connect` + `vision_demo` 가 동시 ttyUSB0 못 잡음)
- 가이드: `docs/handoff/teleop-v1-walkthrough.md`

---

## 10. 테스트 전략

### 10.1 Rust forge-core
- `TeleopCommand::safety()` 매핑 일치 — 기존 `WalkSafety` / `SafetyClass` 와 cross-table.
- `SafetyGate::allow()` — 4 reason 각각 차단 + arming/deadman/IMU/duration 회귀.
- `BallFollowConfig::decide()` — 3 분기 (looking / approach / close) + dead zone + LOST detection.
- 결정론적: 같은 frame + 같은 prev_state → 같은 decision (random 없음).

### 10.2 Swift
- `TeleopChannel.send` mock Bus — 송출된 payload 검증.
- dead-man timer — 시간 진행 모킹 (XCTest async wait) → 1.05 s 후 Stop 송출 확인.
- `RemotePilotView` smoke — arming OFF 면 모든 버튼 disabled, ON 시 enabled.

### 10.3 Hardware-in-the-loop (Mac + cradle)
- 시나리오 1: cradle 거치 → arm → 전진 1 s → release → 1 s 이내 stop.
- 시나리오 2: cradle 거치 → 공 1 m 앞 → Ball-Follow ON → 5 cycle (~ 5 s) 안에 centroid 가 화면 중앙으로 이동.
- 시나리오 3: 인공적으로 IMU roll 30° 기울임 (cradle 비틀기) → 즉시 stop.
- 시나리오 4: 네트워크 연결 끊고 4 초 → dead-man + watchdog 모두 트리거 → status .error.

---

## 11. 미해결 사항 (Open Questions)

| OQ | 설명 | 결정 시점 |
|---|---|---|
| **OQ-1** | C3 해결 (실 IK) 전, FastWalk / Jog 같은 변형 preset 이 진짜로 실 로봇에서 안전한가? | Sprint 14 walk-lab 실험 결과 후 |
| **OQ-2** | MJPEG → CGImage → Frame 변환을 매 100 ms 마다 메인 스레드에서 하면 비싼가? GPU offload 가 필요한가? | 1차 implementation 후 measure |
| **OQ-3** | Ball-Follow 의 HSV 범위가 형광등 / 자연광 차이에 robust 한가? Lab 환경 시연만으로 v1 충분? | Day 4 실측 후 |
| **OQ-4** | 외부 USB 게임패드 지원 v2 — GameController.framework 가 macOS 14+ 만 — Sonoma 이하 사용자가 있나? | v2 PRD |
| **OQ-5** | 두 명이 같은 로봇을 다른 Mac 에서 동시에 조종하면? (5530 TCP 는 multi-client?) — 거버넌스 필요? | Sprint 15 후 |

---

## 12. 부록 — 기존 코드와의 매핑 표

| 새 기능 | 재사용하는 기존 자산 | 변경 필요? |
|---|---|---|
| Bus 송출 | `ConnectionStore.bus`, `Bus.write` | × (그대로) |
| Walk 명령 sim | `WalkEngine.set_command`, `set_period_ms` | × |
| Walk 명령 실송출 | `WalkLab` 의 “로봇에 적용” 로직 (현재 `forEachLeg sync write`) | sharedHelper 로 추출 권장 |
| 모션 트리거 | `forge motion play --slot N --engage` 의 CLI 핸들러 → ffi 로 노출 필요 | + `fc_motion_play(slot, engage)` ffi (v1 신규) |
| 안전 등급 | `WalkSafety`, `SafetyClass`, `precheck_motion` | × |
| E-Stop | `ConnectionStore.emergencyStop()` ⌘⇧. | × |
| 텔레메트리 | `ConnectionStore.lastTelemetry` (voltage / temp) | + IMU roll/pitch 노출 필요 (없으면 LiveTelemetry 보강) |
| 카메라 (보기) | `ConnectionDashboard` 의 `urlString` 8080 표시 | + `MjpegStream` 신규 (frame 단위 분석) |
| HSV blob | `vision::detect_blob`, `HsvRange::ROBOCUP_BALL` | × |
| Strategy FSM | `StrategyState`, `is_close_enough` | × (재사용 — 단 close threshold 는 별도 BallFollowConfig 로 노출) |
| Remote shell | `RemoteShellView` (⌘6) | × — Pilot 은 별 화면 (⌘8). 서로 독립 |

---

## 13. 결정 근거 요약 (논리적 근거 = Logic Basis)

1. **왜 별도 화면 (⌘8) 인가** — `RemoteShellView` (⌘6) 는 텍스트 명령 채널 (SSH/SMB) 이라 인터랙션 모델이 본질적으로 다르다. 같은 화면에 묶으면 “셸 vs 조종” 사용자 모드 혼동.
2. **왜 두 모드뿐 (manual / ball-follow) 인가** — 사용자 요청 그대로. 더 늘리면 v1 scope 폭증. 자연어 조종은 `Conversation` (⌘5) 이 이미 담당.
3. **왜 임의 (x, y, a) 슬라이더 → 실송출 금지인가** — BLOCKER C3 (실 IK 부재). 안전 검증된 5 preset 만 실송출. 슬라이더는 sim 미리보기만.
4. **왜 dead-man hold 가 필요한가** — `WalkEngine.tick` 은 자체 stop 이 없다. enabled=true 가 계속이면 무한 반복. 네트워크 끊김 시 로봇이 끝없이 전진할 위험. 1 초 hold 가 사용자 의도 부재 신호.
5. **왜 Auto-Kick 이 기본 OFF 인가** — `StrategyState::Kicking` 의 페이지 12 (right_kick) 는 SafetyClass::Caution 이다. 게다가 ROBOTIS 골 기준이 아니라 우리가 임의 정한 “close enough” (pixel_count > 1000) 트리거이므로 false positive 확률이 높다 — 사용자 supervision 이 안전.
6. **왜 MJPEG snapshot 폴링 우선인가** — multipart/x-mixed-replace 구독은 macOS URLSession 에서 까다롭다. 1차 implementation 은 `?action=snapshot` 100 ms 폴링이 단순+안정. fps 가 모자라면 v2 에서 streaming 으로.
7. **왜 forge-core (Rust) 에 teleop 모듈을 두는가** — Manual / Ball-Follow / 미래의 Conversation teleop 가 같은 SafetyGate / TeleopCommand 를 공유해야 한다. Swift 에 중복 구현 시 안전 게이트 회귀가 위험.
8. **왜 ⌘8 인가** — 1..5 는 기본 메뉴, 6 은 Remote Shell, 7 은 Expert. 8 은 자연스러운 다음. 9, 0 은 미래 확장 (multi-robot, replay).

---

## 14. 참고

- **ROBOTIS-OP2** `op2_walking_module/config/param.yaml` — `period_time = 600 ms`, `foot_height = 0.04 m`, `dsp_ratio = 0.1`. v1 manual 조종의 walk 파라미터 기본값.
- **ROBOTIS framework** `~/Framework/Linux/project/vision_demo` — 8080 MJPEG. 자체적으로 HSV thresholding 도 함 (`Color` filter UI). v2 에서 그 결과를 직접 구독하는 옵션도 가능.
- **`docs/walk-lab/V1_DESIGN.md`** — 8 preset 정의 + 안전 등급. v1 manual D-pad 가 그대로 재사용.
- **`docs/architecture/walking-engine.md`** — phase 정의 + IK 기대 동작.
- **`docs/HARDWARE_VERIFICATION_PROTOCOL.md`** G3 단계 — `forge motion play --engage` 검증 절차 — v1 의 액션 4 버튼이 그 절차를 GUI 로 wrap.
- **`docs/inspiration/05-llm-robotics-frameworks/README.md`** — LLM orchestrator 패턴 — v2 에서 Conversation ↔ teleop 연결의 reference.
- **`docs/DESIGN_CONVERSATIONAL_UX.md`** §1X NEO — Autonomous + Expert 두 모드 패턴 — v1 의 Manual / Ball-Follow 토글의 reference.
