# PRD — Remote Pilot v1: 원격 조종 스튜디오 (단일 설계 + 단계별 활성화)

> **상태**: Design Frozen v3 — 구현 준비 완료
> **작성일**: 2026-05-12 (초안 → audit → reality-check → 본 v3 최종)
> **전략**: 옵션 A 의 설계 일관성 + 옵션 B 의 점진 검증 = **"한 번 설계, 단계별 활성화"**
> **대상 스프린트**: Sprint 15 (v1.0) → Sprint 16 (v1.1) → Sprint 17 (v1.5) → Sprint 18+ (v2)
> **연관 문서**:
> - `docs/prd/teleop-v1-audit.md` (공식 자료 충실도 점검)
> - `docs/prd/teleop-v1-reality-check.md` (격차 분석 — 본 PRD 가 반영함)

---

## 0. 핵심 전략 — 옵션 A + B 하이브리드

### 0.1 채택한 옵션 A 의 안정 강점 (4가지)

| # | 강점 | 본 PRD 의 반영 |
|---|---|---|
| **A1** | 설계 일관성 — 모든 컴포넌트가 같은 의도 | **단일 PRD 가 v1.0~v1.5 전 영역 명세**. UI 레이아웃·디자인 시스템·게이트·상태 머신 한 번에 동결 |
| **A2** | 기술 부채 0 — v1.0 의 임시 코드를 v1.1 에서 제거할 일 없음 | **활성화 플래그 (`PilotFeatureFlags`) 기반** — 같은 코드, 같은 컴포넌트가 단계별로 enable 됨 |
| **A3** | 사용자 학습 한 번 — UI 가 단계 사이 변하지 않음 | **v1.0 부터 v1.5 의 최종 화면 레이아웃**. 비활성 기능은 "준비 중" 배지 + 이유 표시 |
| **A4** | HIL 셋업 한 번 — 테스트 인프라 동일 | **HIL 시나리오 6 개**를 단계별로 단위화. 셋업·픽스처는 v1.0 에 다 갖춤 |

### 0.2 보존한 옵션 B 의 안정 검증 (3가지)

| # | 강점 | 본 PRD 의 반영 |
|---|---|---|
| **B1** | 단계별 HIL 검증 — 각 PR 가 실 로봇에서 통과 | v1.0/v1.1/v1.5 각각 HIL 시나리오 통과해야 머지 |
| **B2** | 버그 격리 — bisect 용이 | 각 단계가 기존 검증된 모듈만 활성. 새 모듈 1~2개씩만 진입 |
| **B3** | 하드웨어 손상 risk 최소 | v1.0 은 검증된 `precheck_motion` + `TorqueRamper` 경로만. 신규 walk/head SYNC_WRITE 는 v1.1 이후 |

### 0.3 단일 설계 원칙

본 PRD 는 **최종 v1.5 의 UI 와 아키텍처를 한 번에 명세**. v1.0/v1.1/v1.5 는 같은 코드의 점진적 활성화이며, **UI 레이아웃·디자인 시스템·게이트 정책·상태 머신은 v1.0 부터 최종 형태**. 변하는 것은 **`PilotFeatureFlags`** 한 곳뿐:

```swift
public struct PilotFeatureFlags {
    public var actionBarMain: Bool         // v1.0 활성
    public var actionBarMore: Bool         // v1.5 활성
    public var imuTelemetry: Bool          // v1.1 활성
    public var autoRecovery: Bool          // v1.1 활성
    public var headTracking: Bool          // v1.1 활성
    public var ballFollow: Bool            // v1.5 활성
    public var camera: Bool                // v1.5 활성 (mjpg-streamer 셋업 후)
    public var hsvTuning: Bool             // v1.5 활성
    public var bridgeNetwork: Bool         // v1.5 활성 (forge-bridge 셋업 후)
    public var dpadRealMotor: Bool         // v2 활성 (BLOCKER C3 해결 후)
    public var pageChain: Bool             // v1.5 활성
    public var mp3Playback: Bool           // v2 활성 (협의 후)
}
```

비활성 기능은 UI 에 **"준비 중" 배지** 로 표시 + tooltip 에 "어느 단계에 활성, 왜 대기 중" 명시 → 사용자가 진행 단계를 자연스럽게 이해.

---

## 1. 단계별 활성화 매트릭스

| 기능 | v1.0 | v1.1 | v1.5 | v2 | 활성화 조건 |
|---|:---:|:---:|:---:|:---:|---|
| **Action Bar 메인 7 페이지** (1·4·9·12·13·15·23) | ✅ | ✅ | ✅ | ✅ | — |
| **Action Bar "+ 더 보기" 9 페이지** | 🔒 | 🔒 | ✅ | ✅ | UI 검증 후 |
| **D-pad sim 미리보기** (SceneKit foot trail) | ✅ | ✅ | ✅ | ✅ | — |
| **D-pad 실 모터 송출** | 🔒 | 🔒 | 🔒 | ✅ | **BLOCKER C3 (실 IK) 해결** |
| **IMU 텔레메트리 표시** | 🔒 | ✅ | ✅ | ✅ | CmController::read_imu() 추가 |
| **자동 낙상 복구** (page 10/11) | 🔒 | ✅ | ✅ | ✅ | IMU read + FallRecoveryCoordinator |
| **Head 추적** (joint 19/20 PID) | 🔒 | ✅ | ✅ | ✅ | HeadJointController + HeadTracker |
| **Ball-Follow 모드** (head 추적만, walk OFF) | 🔒 | ✅ | ✅ | ✅ | v1.1 의 head 추적 |
| **Ball-Follow walk 자동 송출** | 🔒 | 🔒 | ✅(sim) | ✅(실) | sim: 즉시, 실: BLOCKER C3 후 |
| **카메라 view** (MJPEG snapshot) | 🔒 | 🔒 | ✅ | ✅ | robot-side mjpg-streamer 셋업 |
| **HSV 튜닝 패널** | 🔒 | 🔒 | ✅ | ✅ | 카메라 view 활성화 후 |
| **TCP 5530 forge-bridge** | 🔒 | 🔒 | ✅ | ✅ | robot-side 데몬 셋업 + 가이드 |
| **Page chain 자동 재생** | 🔒 | 🔒 | ✅ | ✅ | 사용자 의사 모달 검증 |
| **mp3 동기 재생** | 🔒 | 🔒 | 🔒 | ✅ | 라이선스 결정 + robot/Mac 분기 |
| **자동복구 ARM/deadman 우회 정책** | 🔒 | ✅ | ✅ | ✅ | 게이트 정책 명세 (§7 reality-check C8) |
| **emergencyStop motion cancellation** | ✅ | ✅ | ✅ | ✅ | v1.0 부터 (Task.cancel + bus stop) |
| **ARM dxl_power + torque ramp** | ✅ | ✅ | ✅ | ✅ | v1.0 부터 (안전 기초) |

🔒 = 비활성. UI 에 표시되지만 "준비 중" 배지 + tooltip 으로 이유 명시.

---

## 2. 단계별 목표 & HIL 통과 기준

### 2.1 Sprint 15 — v1.0 (3~4일)

> **목표**: 사용자가 ⌘8 으로 Pilot 화면에 진입해, ARM 후 Action Bar 의 7 페이지를 실 로봇에 정확히 송출할 수 있다. D-pad 는 sim 미리보기만, 나머지 기능은 "준비 중" 배지로 노출.

#### HIL 시나리오 v1.0 (4 개)

| # | 시나리오 | 통과 기준 |
|---:|---|---|
| 1 | ⌘8 진입 → ARM 슬라이더 → walkready (page 9) 자동 호출 | walkready 자세 도달 + 토스트 "준비 완료" |
| 2 | "감사 인사" (page 4) 클릭 | 3.6 s 진행링 + 실 모터 동작 + 토크 ramp 정상 |
| 3 | "오른발 차기" (page 12) 클릭 → HighRisk confirm → 확인 | 1.7 s 차기 동작 + 모터 손상 없음 |
| 4 | 차기 진행 중 ⌘⇧. (E-stop) | 즉시 모터 토크 OFF + motion task cancel + 다음 step 송출 X |

#### v1.0 필수 신규 작업 (3~4일)

| Day | 작업 |
|---|---|
| 1 | forge-core: `motion::play::MotionPlayer` 추출 (motion_play.rs → 라이브러리) + `precheck_motion` integration + Task cancellation 지원 |
| 2 | forge-ffi: `fc_motion_play_slot(handle, slot, dry_run, confirm_risk)` + `fc_motion_play_cancel` + cbindgen 헤더 |
| 3 | Swift: `MotionCatalog` (sidecar TOML 파싱 또는 hardcode 16 페이지) + `TeleopChannel` 기초 (ARM/Motion/Stop 만, deadman/IMU 없음) + `PilotSafetyGate` 기초 (armed 만) |
| 4 | Swift: `RemotePilotView` 최종 UI 스캐폴드 (v1.5 레이아웃 그대로) + `PilotFeatureFlags` + 모든 컴포넌트 시각 (D-pad/카메라/HUD 등 비활성 상태로 표시) + 비활성 컴포넌트 "준비 중" 배지 + `PilotActionBar` 7 페이지 실 동작 + ARM 시퀀스 (dxl_power + TorqueRamper + walkready) + emergencyStop motion cancellation + RootView ⌘8 |

### 2.2 Sprint 16 — v1.1 (3일, IMU + Head 추적)

> **목표**: IMU 읽기 + 자동 낙상 복구 + Head joint 19/20 PID 추적 활성화. Ball-Follow 모드의 head 추적 부분 활성 (walk 는 여전히 OFF). 카메라 없이도 검증 가능 (BlobResult 모의 입력).

#### HIL 시나리오 v1.1 (2 개)

| # | 시나리오 | 통과 기준 |
|---:|---|---|
| 5 | cradle 비틀어 pitch 60° | 5초 내 page 10 (또는 11) 자동 호출 + 토스트 "낙상 감지" |
| 6 | 모의 blob (Mac 측 테스트 frame) → head 추적 | head pan/tilt 가 blob 위치로 PID 수렴 (오차 < 5°, 1초 이내) |

#### v1.1 필수 신규 작업 (3일)

| Day | 작업 |
|---|---|
| 1 | forge-core: `controller::cm::CmController::read_imu() → ImuSample` 신규 + raw → rad/s, m/s² 변환 + `ComplementaryFilter` 통합 |
| 2 | forge-core: `teleop::pid` + `teleop::head_tracker` + ffi `fc_bus_read_imu_filtered`, `fc_head_tracker_*` |
| 3 | Swift: `HeadJointController` + `FallRecoveryCoordinator` + IMU `ConnectionStore.lastImuRoll/Pitch` 노출 + UI 활성화 토글 (`flags.imuTelemetry`, `autoRecovery`, `headTracking` ON) + PilotHudStrip 인공수평선 활성 + Mode Picker Ball-Follow 진입 시 head 추적만 작동 |

### 2.3 Sprint 17 — v1.5 (5일, 카메라 + Ball-Follow + Bridge)

> **목표**: robot-side mjpg-streamer + forge-bridge 셋업 가이드 + 카메라 view + HSV 튜닝 + Ball-Follow walk (sim 만, 실 모터 송출 X) + "+ 더 보기" 9 페이지.

#### HIL 시나리오 v1.5 (외부 셋업 의존, sim 검증)

| # | 시나리오 | 통과 기준 |
|---:|---|---|
| 7 | robot 측 셋업 가이드 → mjpg-streamer + forge-bridge 설치 | 카메라 view + TCP 5530 모두 동작 |
| 8 | 카메라 view + 공 1m → Ball-Follow ON (auto-walk sim) | head 추적 + sim WalkEngine 의 발 trail 가 회전 표시 + 차기 (page 12/13 실송출) auto-kick 확인 |

#### v1.5 필수 신규 작업 (5일)

| Day | 작업 |
|---|---|
| 1 | forge-core: `teleop::ballfollow` (head 기반 walk decision + 좌/우 차기 자동) + ffi + 통합 테스트 |
| 2 | Swift: `BallFollowEngine` + `MjpegSnapshot` + 카메라 view 활성화 (`flags.camera, ballFollow` ON) |
| 3 | Swift: `HsvTuningPanel` 활성 + 4 preset + UserDefaults + 미리보기 (1Hz outline) |
| 4 | Robot-side: mjpg-streamer 셋업 스크립트 + forge-bridge socat init.d 스크립트 + 한국어 가이드 (`docs/handoff/teleop-robot-setup.md`) + RemoteShell QuickAction 갱신 |
| 5 | Swift: PilotActionBar "+ 더 보기" 시트 활성 (`flags.actionBarMore` ON) + chain 자동 재생 (`flags.pageChain` ON) + HIL 시나리오 7/8 통과 |

### 2.4 Sprint 18+ — v2 (BLOCKER C3 해결 후)

> **목표**: 실 IK 완성 → D-pad 실 모터 송출 + Ball-Follow walk 실 송출. **선결 조건**: ROBOTIS-OP2 `op2_walking_module` IK Rust 포팅 또는 robot-side `walk_demo` TCP 호출.

이 단계의 PRD 는 v2 의 BLOCKER C3 결정 후 별도 작성.

---

## 3. 최종 UI 레이아웃 (v1.0 부터 그대로)

v1.0 사용자가 보는 화면. v1.5 까지 레이아웃 동일, 컴포넌트만 점진 활성.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ toolbar: ⬤ Connected V11.7 T38° ARM🔒→🔓 MODE 🕹/🎯 │ ⌘K E-STOP🔴            │
├───────────────────────────────────┬──────────────────────────────────────────────┤
│ LEFT PANEL (360 px)               │ RIGHT PANEL (fill)                           │
│                                   │ ┌──────────────────────────────────┐         │
│ 1. ARM 슬라이더                   │ │ A. CAMERA + AR HUD               │         │
│                                   │ │   v1.0/v1.1: 회색 placeholder    │         │
│ 2. MODE 토글                      │ │     + "카메라 v1.5 활성" 배지    │         │
│   - Manual (활성)                 │ │     + [로봇 셋업 가이드] 링크    │         │
│   - Ball-Follow                   │ │   v1.5: MJPEG + AR overlay       │         │
│     ↳ v1.0: "v1.1 활성" 배지      │ └──────────────────────────────────┘         │
│     ↳ v1.1: head 추적만           │ ┌──────────────────────────────────┐         │
│     ↳ v1.5: walk + 차기 자동      │ │ B. 3D 로봇 뷰 + foot trail (sim) │         │
│                                   │ │   v1.0 부터 활성                  │         │
│ 3. SPEED GAUGE (sim)              │ └──────────────────────────────────┘         │
│   v1.0: sim 미리보기              │ ┌──────────────────────────────────┐         │
│   v2: 실 모터 송출                │ │ C. HUD STRIP                     │         │
│                                   │ │   v1.0: V·T·세션·E-stop          │         │
│ 4. D-PAD                          │ │     IMU: "v1.1 활성" placeholder │         │
│   v1.0: sim 만, "v2 활성" 라벨   │ │     자동복구: "v1.1 활성"        │         │
│   v2: 실 모터 송출                │ │   v1.1+: IMU 인공수평선 + 자동복구토글│      │
│                                   │ └──────────────────────────────────┘         │
│ 5. ACTION BAR                     │                                              │
│   v1.0: 7 메인 페이지 실 송출 ✅  │                                              │
│   v1.5: + 더 보기 9 페이지        │                                              │
└───────────────────────────────────┴──────────────────────────────────────────────┘
```

### 3.1 "준비 중" 배지 디자인

비활성 컴포넌트는 회색 overlay + 우상단 작은 배지 + tap → tooltip:

```
┌──────────────────────────────────┐
│  ╔═════════════════════════════╗ │ ◀── 회색 overlay (opacity 0.4)
│  ║  [컴포넌트 시각 (회색)]    ║ │
│  ║                              ║ │
│  ║   🔒 v1.1 활성 예정         ║ │ ◀── 중앙 배지 (DFColor.warning)
│  ║   (탭 → 자세히)             ║ │
│  ╚═════════════════════════════╝ │
└──────────────────────────────────┘
```

탭 → sheet 모달:
- **무엇이**: "공 자동 추적 + 자동 낙상 복구"
- **왜 대기**: "로봇의 자이로 센서를 읽는 코드가 v1.1 에서 추가됩니다"
- **언제**: "Sprint 16 — 약 1주 후"
- **지금 할 수 있는 것**: "Action Bar 의 7가지 동작 + sim 미리보기"

이 패턴으로 **사용자가 v1.0 의 한계를 정직히 인지** + **v1.1/v1.5 를 자연스럽게 기대**.

---

## 4. 컴포넌트 — 단일 설계 (v1.0 부터 v1.5 까지 동일 코드)

### 4.1 `PilotFeatureFlags` (`Remote/PilotFeatureFlags.swift`)

```swift
public struct PilotFeatureFlags: Sendable, Equatable {
    public var actionBarMain: Bool
    public var actionBarMore: Bool
    public var imuTelemetry: Bool
    public var autoRecovery: Bool
    public var headTracking: Bool
    public var ballFollow: Bool
    public var camera: Bool
    public var hsvTuning: Bool
    public var bridgeNetwork: Bool
    public var dpadRealMotor: Bool
    public var pageChain: Bool
    public var mp3Playback: Bool

    /// v1.0 default — Action Bar 메인 만 활성, 나머지 OFF.
    public static let v1_0: PilotFeatureFlags = .init(
        actionBarMain: true,
        actionBarMore: false,
        imuTelemetry: false,
        autoRecovery: false,
        headTracking: false,
        ballFollow: false,
        camera: false,
        hsvTuning: false,
        bridgeNetwork: false,
        dpadRealMotor: false,
        pageChain: false,
        mp3Playback: false
    )

    public static let v1_1: PilotFeatureFlags = {
        var f = v1_0
        f.imuTelemetry = true
        f.autoRecovery = true
        f.headTracking = true
        f.ballFollow = true     // head 추적만, walk OFF (engine 내부 자체 분기)
        return f
    }()

    public static let v1_5: PilotFeatureFlags = {
        var f = v1_1
        f.actionBarMore = true
        f.camera = true
        f.hsvTuning = true
        f.bridgeNetwork = true
        f.pageChain = true
        return f
    }()

    public static let v2: PilotFeatureFlags = {
        var f = v1_5
        f.dpadRealMotor = true
        return f
    }()

    /// 빌드 시점 결정 — UserDefaults override 가능 (개발자 / 베타).
    public static let active: PilotFeatureFlags = {
        if let raw = UserDefaults.standard.string(forKey: "df.pilot.featureLevel") {
            switch raw {
            case "v1.0": return .v1_0
            case "v1.1": return .v1_1
            case "v1.5": return .v1_5
            case "v2":   return .v2
            default: break
            }
        }
        return .v1_0   // ← v1.0 빌드 시 default
    }()
}
```

빌드 변경: `Active = .v1_1` 로 한 줄만 변경 → v1.1 빌드. 새 코드 작성 없이 활성화.

### 4.2 `ComingSoonOverlay` (`Remote/ComingSoonOverlay.swift`)

```swift
public struct ComingSoonOverlay: ViewModifier {
    public let stage: String           // "v1.1" / "v1.5" / "v2"
    public let title: String           // "공 자동 추적"
    public let why: String             // "자이로 센서 코드 v1.1 추가 예정"
    public let when: String            // "Sprint 16 (1주 후)"
    public let alternative: String?    // "지금: Action Bar 의 7가지"
    @State private var showSheet = false

    public func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(DFOpacity.disabled)
                .allowsHitTesting(false)
                .grayscale(0.8)
            VStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text("\(stage) 활성 예정").font(DFFont.bodyEmph)
                Text(title).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text("탭하면 자세히").font(DFFont.caption).foregroundStyle(DFColor.accent)
            }
            .padding(DFSpace.md)
            .background(DFColor.warning.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            .onTapGesture { showSheet = true }
        }
        .sheet(isPresented: $showSheet) { detailSheet }
    }

    @ViewBuilder var detailSheet: some View { … }
}

public extension View {
    func comingSoon(_ stage: String, title: String, why: String, when: String,
                    alternative: String? = nil) -> some View { … }
}
```

각 비활성 컴포넌트는 이 modifier 만 붙이면 됨:

```swift
PilotDpad(...)
    .comingSoon("v2", title: "실 로봇 보행 조종",
                why: "걷기 IK 알고리즘 (BLOCKER C3) 구현 후 활성화",
                when: "BLOCKER C3 해결 후 Sprint 18+",
                alternative: "지금: 화면의 발 trail 시뮬레이션은 동작합니다")
```

### 4.3 컴포넌트 활성 매트릭스

| 컴포넌트 | 활성 조건 | v1.0 표시 |
|---|---|---|
| `PilotArmSlider` | 항상 | 정상 동작 |
| `PilotModePicker` | 항상 | Manual 만 선택 가능 — Ball-Follow 는 disable + comingSoon("v1.1") |
| `PilotDpad` (sim part) | 항상 | 정상 sim 미리보기 (sceneKit foot trail) |
| `PilotDpad` (실 모터 송출) | `flags.dpadRealMotor` | comingSoon("v2") |
| `PilotSpeedGauge` | 항상 | sim 만 — 실 송출 비활성 |
| `PilotActionBar` 메인 7 | `flags.actionBarMain` | 정상 동작 |
| `PilotActionBar` + 더보기 | `flags.actionBarMore` | comingSoon("v1.5") |
| `PilotCameraView` | `flags.camera` | comingSoon("v1.5") + [로봇 셋업 가이드] 링크 |
| `HsvTuningPanel` | `flags.hsvTuning` | camera 와 같이 hidden |
| `PilotHudStrip` IMU 부분 | `flags.imuTelemetry` | "IMU v1.1" placeholder |
| `PilotHudStrip` 자동복구 토글 | `flags.autoRecovery` | comingSoon("v1.1") |
| Network endpoint UI | `flags.bridgeNetwork` | "TCP 연결 v1.5 셋업 후" 배너 |

---

## 5. v1.0 — 안전 우선 설계 (가장 작게, 가장 검증된)

### 5.1 v1.0 의 좁은 범위

- **실 모터 송출 경로**: `forge motion play` (CLI 검증 완료) → ffi 추출 → Swift 호출
- **검증된 안전**: `precheck_motion` + `TorqueRamper` + `emergency_stop()` 다 기존
- **신규 코드 최소**: motion 라이브러리 추출 + ffi 5개 + Swift 컴포넌트 8개 + 한 번의 통합

### 5.2 v1.0 의 ARM 시퀀스 (최종 형태 — v1.0 부터 적용)

```
ARM 슬라이더 drag 완료
  ↓
[1] CM 보드 dxl_power = 1 (모터 전원 ON)
[2] 모든 관절 TorqueRamper gentle (P_GAIN 0→8→16→32, ~400ms)
[3] Toast "보행 자세로 전환 중…"
[4] forge motion play page 9 (walkready) — confirm_risk=false (Safe)
[5] duration_ms (~1s) 대기 + 진행 ring
[6] Toast "준비 완료 — 동작 버튼을 눌러보세요"
[7] PilotActionBar 활성화 (이미 ON 이었음, opacity 정상화)
```

DISARM:
1. 진행 중인 motion task `Task.cancel()`
2. Walking::Stop (사실상 set_command(enabled: false) — v1.0 에는 영향 X, v2 에 의미)
3. CM dxl_power = 0 (선택 — 사용자가 sit 후 disarm 시 모터 자유)
4. ARM 슬라이더 thumb 원위치

### 5.3 v1.0 의 E-Stop (최종 형태)

```swift
public func emergencyStop() async {
    // 1. UI 즉시 빨간 flash
    flashRed()

    // 2. 진행 중인 모든 motion task 취소
    currentMotionTask?.cancel()
    deadmanTask?.cancel()

    // 3. Bus 토크 OFF + P_GAIN 0 (기존 `bus.emergencyStop()`)
    try? store.bus?.emergencyStop()

    // 4. 모든 상태 .Stop 으로 강제
    currentCmd = .Stop
    pilotSafetyGate.disarm()

    // 5. 시뮬 모드로 격리 (실수 재실행 방지)
    dispatcher.mode = .simulation

    // 6. 사용자 토스트
    toast("긴급 정지 — 모터 토크 OFF. ARM 다시 해주세요.")
}
```

⌘⇧. 글로벌 단축키 (RootView 기존 그대로) 가 NotificationCenter 로 `TeleopChannel.emergencyStop()` 호출.

### 5.4 v1.0 의 4-layer 안전 게이트 (간소화)

v1.0 의 SafetyGate 는 **L0 + L1 + L2 만** (deadman/IMU 는 v1.1).

```
L0: ⌘⇧. → emergencyStop()
L1: !armed → 명령 무시
L2: cmd.safety == .highRisk && !confirmRisk → Alert
```

L3 (deadman) 은 Walk 명령 전용 — v1.0 은 Walk 미사용이라 OFF 자연스러움.
L4 (IMU) 는 v1.1 활성. v1.0 에서는 "준비 중" 배지로 UI 노출.

---

## 6. 디자인 시스템 — v1.0 부터 최종 형태

기존 `DFColor`, `DFNeon`, `DFAnimation` + `KoreanUX` 그대로 사용.

신규 `PilotTokens.swift` (이전 PRD v2 §10 동일):

```swift
enum PilotColor {
    static let dpadActive  = DFNeon.electric
    static let dpadIdle    = DFColor.elev2
    static let speedSafe   = DFColor.success
    static let speedCaution = DFColor.warning
    static let speedDanger = DFColor.danger
    static let stateIdle      = DFColor.textSecondary
    static let stateLooking   = DFColor.warning
    static let stateApproach  = DFNeon.electric
    static let stateLockedOn  = DFColor.success
    static let stateLost      = DFColor.danger
    static let holdCharging   = DFColor.warning
    static let holdFull       = DFColor.danger
    static let safetySafe     = DFColor.success
    static let safetyCaution  = DFColor.warning
    static let safetyHighRisk = DFColor.danger
    static let headReticle    = DFColor.info
    static let ballReticle    = DFColor.forge
    // v3 신규 — comingSoon 배지 색
    static let comingSoon     = DFColor.warning
}

enum PilotAnim {
    static let dpadPress       = Animation.spring(response: 0.12, dampingFraction: 0.7)
    static let stateChange     = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let gauge           = Animation.easeOut(duration: 0.22)
    static let motionProgress  = Animation.linear
    static let modeSwitch      = Animation.easeInOut(duration: 0.30)
    static let lockPop         = Animation.spring(response: 0.25, dampingFraction: 0.5)
    static let blobTrack       = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.85)
    static let headTrack       = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.85)
    static let fallRecovery    = Animation.easeInOut(duration: 0.4)
    static let flashRed        = Animation.easeOut(duration: 0.3)   // v3 신규 — E-stop flash
}
```

---

## 7. 공식 데모 모션 — Action Bar 매핑 (v1.0 부터 완성)

**모션 데이터는 `motion_4096.bin` byte-identical. 호출만 한다.**

### 7.1 Action Bar 메인 7 페이지 (v1.0 활성)

| Order | slot | raw_name | UI 라벨 (`display_name`) | safety | mp3 | duration | confirm? | 키 |
|---:|---:|---|---|---|---|---:|---|---|
| 1 | **1** | `init` | 기본 자세 (Stand Up) | Safe | Stand up.mp3 | 2.0 s | × | 1 |
| 2 | **4** | `hi` | 감사 인사 (Thank You) | Safe | Thank you.mp3 | 3.6 s | × | 2 |
| 3 | **15** | `sit down` | 앉기 (Sit Down) | Safe | Sit down.mp3 | 1.0 s | × | 3 |
| 4 | **12** | `rk` | 오른발 차기 (Right Kick) | **HighRisk** | Right kick.mp3 | 1.7 s | ✓ | 4 |
| 5 | **13** | `lk` | 왼발 차기 (Left Kick) | **HighRisk** | Left kick.mp3 | 1.7 s | ✓ | 5 |
| 6 | **9** | `walkready` | 보행 자세 (Walk Ready) | Safe | — | 1.0 s | × | 6 |
| 7 | **23** | `d1` | 출발! (Yes Go) | Safe | Yes go.mp3 | 3.0 s | × | 7 |

### 7.2 + 더 보기 9 페이지 (v1.5 활성)

| slot | raw_name | UI 라벨 | safety | mp3 | duration |
|---:|---|---|---|---|---:|
| 2 | `ok` | 끄덕임 (Yes) | Safe | Yes.mp3 | 2.6 s |
| 3 | `no` | 가로젓기 (No) | Safe | No.mp3 | 2.6 s |
| 10 | `f up` | 앞 일어서기 (Get Up Front) | Caution | — | 3.2 s |
| 11 | `b up` | 뒤 일어서기 (Get Up Back) | Caution | — | 4.2 s |
| 16 | `stand up` | 일어서기 (Stand Up exact) | Safe | — | 1.0 s |
| 24 | `d2` | 감탄 (Wow) | Safe | Wow.mp3 | 3.6 s |
| 27 | `d3` | 실수 (Oops) | Safe | — | 3.2 s |
| 38 | `d2` | 손 흔들기 (Bye Bye) | Safe | — | 3.6 s |
| 54 | `int` | 박수 요청 (Clap Please) | Safe | — | 2.0 s |

> 모든 라벨은 `docs/motion-format/page-metadata-motion4096.toml` 의 `display_name` 직접 인용.

### 7.3 mp3 동기 (v2 활성)

v1.0~v1.5 는 **tooltip 에 mp3 파일명 표시만** ("v2 활성" 배지 옆). 실 재생은 v2 에서 robot/Mac 분기 결정 후.

---

## 8. Ball-Follow — v1.1 head 추적 + v1.5 walk 자동 (단일 설계)

### 8.1 v1.1: head 추적만

- 카메라 frame 입력은 **Mac 측 테스트 frame** (UI 의 "테스트 frame 주입" 버튼) 또는 v1.5 의 실 MJPEG
- `HeadTracker` PID 가 blob → head pan/tilt SYNC_WRITE
- walk 명령 송출 X (`flags.ballFollowWalk = false`)
- 사용자는 head 가 따라가는 모습 확인 + PID 튜닝 (Kp/Ki/Kd UserDefaults 슬라이더)

### 8.2 v1.5: 카메라 + walk + 좌/우 차기

- v1.1 의 head 추적 그대로
- + 카메라 MJPEG (`flags.camera = true`)
- + `BallFollowEngine.autoWalk` 활성 (sim 만, 실 모터 X — BLOCKER C3)
- + auto_kick 토글 — page 12/13 자동 (head pan 부호 기준)

### 8.3 v2: walk 실 모터 송출

BLOCKER C3 해결 후 `flags.dpadRealMotor = true` + Ball-Follow walk 도 실 송출.

---

## 9. 안전 게이트 — 단일 정책 (모든 단계 동일)

| Layer | 조건 | v1.0 | v1.1 | v1.5 | v2 |
|---|---|:---:|:---:|:---:|:---:|
| L0 | E-stop ⌘⇧. | ✅ | ✅ | ✅ | ✅ |
| L1 | armed | ✅ | ✅ | ✅ | ✅ |
| L2 | HighRisk + !confirm | ✅ | ✅ | ✅ | ✅ |
| L3 | deadman 1s (Walk only) | — | — | ✅ (sim) | ✅ (실) |
| L4a | IMU pitch > 50° → page 10/11 | — | ✅ | ✅ | ✅ |
| L4b | IMU 25° < tilt < 50° → Stop | — | ✅ | ✅ | ✅ |
| L4c | session > max_duration | — | ✅ | ✅ | ✅ |

### 9.1 자동복구 exemption 정책 (reality-check C8 해결)

```
낙상 자동복구 (page 10/11) 호출 시:
  L0 (E-stop): 항상 적용. E-stop 누르면 복구 취소.
  L1 (armed): UNARM 상태에서도 자동 복구 가능 — 사용자 안전.
              단, 명시적 disarm 한 사용자에게 토스트 "복구 중 — disarm 무시됨".
  L2 (HighRisk): page 10/11 = Caution → 무관.
  L3 (deadman): 자동 복구는 Walk 아님 → 무관.
```

---

## 10. 외부 의존 — 단계별 셋업 가이드

### 10.1 v1.0 의존 (이미 셋업)

- USB 케이블 + Mac USB-Serial 드라이버 (CH340/FTDI/SiLab)
- ROBOTIS framework 의 `motion_4096.bin` (robot 측 `/Data/`)
- 로봇 측 `walk_demo` 등이 ttyUSB0 점유 안 하도록 — RemoteShell `darwin-stop` QuickAction

### 10.2 v1.1 의존 (신규)

- CM-730/740 펌웨어 IMU 레지스터 (38~48) — 표준 펌웨어 모두 지원 ✅
- 추가 셋업 없음 — Mac 측 코드만 추가

### 10.3 v1.5 의존 (robot 측 사전 셋업 필요)

신규 가이드 `docs/handoff/teleop-robot-setup.md`:

```bash
# 1. mjpg-streamer 설치 (Ubuntu 12.04~14.04 기준)
sudo apt-get install libjpeg8-dev imagemagick
git clone https://github.com/jacksonliam/mjpg-streamer.git
cd mjpg-streamer/mjpg-streamer-experimental
make
sudo make install

# 2. 부팅 시 자동 시작
sudo cat > /etc/init.d/mjpg-streamer << 'EOF'
#!/bin/bash
mjpg_streamer -i "input_uvc.so -d /dev/video0 -r 320x240 -f 15" \
              -o "output_http.so -p 8080" &
EOF
sudo chmod +x /etc/init.d/mjpg-streamer
sudo update-rc.d mjpg-streamer defaults

# 3. forge-bridge socat 설치
sudo apt-get install socat
sudo cat > /etc/init.d/forge-bridge << 'EOF'
#!/bin/bash
socat tcp-listen:5530,reuseaddr,fork file:/dev/ttyUSB0,raw,echo=0 &
EOF
sudo chmod +x /etc/init.d/forge-bridge
sudo update-rc.d forge-bridge defaults

# 4. 검증
curl http://localhost:8080/?action=snapshot -o /tmp/test.jpg && file /tmp/test.jpg
ss -lnt | grep :5530
```

Mac 측 RemoteShell `QuickAction` 신규 4개:
- `mjpg-streamer-install` (실행 시 위 4단계 자동)
- `mjpg-streamer-status` (5530/8080 확인)
- `forge-bridge-status`
- `vision-restart`

---

## 11. 테스트 전략

### 11.1 v1.0 테스트 (3~4일 안)

**Rust** (목표 +14):
- `motion::player::MotionPlayer` 추출 + cancellation 6 tests
- `teleop::command` (기존 PRD §7.1.1) 6 tests
- `teleop::gate` basic (L0/L1/L2 만) 2 tests

**Swift** (목표 +14):
- `MotionCatalog` (16 페이지 sidecar) 3 tests
- `TeleopChannel` (Motion / Stop / cancel) 5 tests
- `PilotSafetyGate` (armed 만) 2 tests
- `PilotArmSlider` (drag 완료 → walkready 호출) 2 tests
- `RemotePilotView` (Section.pilot 라우팅 + featureFlags 비활성 영역) 2 tests

**HIL**: 시나리오 1~4 (4건)

### 11.2 v1.1 테스트 (3일 안)

**Rust** (+18): `teleop::pid` 4 + `teleop::head_tracker` 6 + `teleop::gate` (L4a/b/c 추가) 8

**Swift** (+8): `HeadJointController` 3 + `FallRecoveryCoordinator` 3 + IMU ConnectionStore 2

**HIL**: 시나리오 5~6 (2건)

### 11.3 v1.5 테스트 (5일 안)

**Rust** (+10): `teleop::ballfollow` v2 head 기반 10

**Swift** (+12): `BallFollowEngine` 4 + `MjpegSnapshot` 2 + `HsvTuningPanel` 3 + `PilotCameraView` 3

**HIL**: 시나리오 7~8 (2건, 외부 셋업 가이드 통과 후)

### 11.4 누적 테스트

| 단계 | Rust | Swift | 누적 Rust | 누적 Swift |
|---|---:|---:|---:|---:|
| 기존 | — | — | 306 | 70 |
| v1.0 | +14 | +14 | **320** | **84** |
| v1.1 | +18 | +8 | **338** | **92** |
| v1.5 | +10 | +12 | **348** | **104** |

---

## 12. Sprint 일정 (최종)

| Sprint | 단계 | 기간 | 목표 | HIL |
|---|---|---|---|---|
| **15** | **v1.0** | **3~4일** | UI 스캐폴드 + Action Bar 메인 7 페이지 | 시나리오 1~4 |
| 16 | v1.1 | 3일 | IMU + 자동 복구 + Head 추적 | 시나리오 5~6 |
| 17 | v1.5 | 5일 | 카메라 + Ball-Follow walk(sim) + Bridge + 더보기 | 시나리오 7~8 |
| 18+ | v2 | BLOCKER C3 후 | D-pad 실 모터 + Ball-Follow 실 walk | 별도 |

총 11일 (v1.0 ~ v1.5) + BLOCKER C3 해결 후 v2.

각 Sprint 끝마다 머지 + 별도 PR. 한 Sprint 가 망하면 그 단계만 롤백, 나머지는 그대로.

---

## 13. 미해결 사항

| OQ | 내용 | 결정 시점 |
|---|---|---|
| OQ-1 | BLOCKER C3 해결 방향 (Rust IK 포팅 vs robot 측 walk_demo TCP) | Sprint 17 후 |
| OQ-2 | mp3 동기 — robot 측 aplay vs Mac 측 AVAudioPlayer | v2 결정 |
| OQ-3 | HeadTracker PID Kp/Ki/Kd 실측 튜닝 | v1.1 HIL 후 |
| OQ-4 | USB 게임패드 v2+ 지원 | v2 PRD |
| OQ-5 | 다중 Mac 동시 연결 TCP 거버넌스 | v1.5 후 |
| OQ-6 | mjpg-streamer 라이선스 (BSD-2-Clause OK) | v1.5 진입 전 확인 |

---

## 14. 부록 — 결정 일지

| 단계 | 결정 | 근거 |
|---|---|---|
| 초안 v1 | 5일 단순 PRD | 사용자 첫 요청 |
| Audit | 5 PATCH 권고 | 공식 BallFollower / StatusCheck 검증 |
| v2 | 10 PATCH 통합, 7일 | 공식 충실 재현 |
| Reality-check | 11 CRITICAL + 7 MAJOR | 코드 실제와 격차 확인 |
| **v3 (본 PRD)** | **단일 설계 + 단계별 활성화** | 옵션 A 의 일관성 + 옵션 B 의 검증 안정성 |

---

*"한 번 설계하고, 단계별로 활성화한다." — v1.0 부터 사용자가 최종 화면을 보고, 비활성 기능에는 정직하게 '준비 중' 배지를 단다. 신뢰는 정직에서, 안정성은 점진에서.*
