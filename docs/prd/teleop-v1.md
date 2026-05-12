# PRD — Remote Pilot v1: 원격 조종 스튜디오

> **상태**: Design Frozen — 구현 준비 완료
> **작성일**: 2026-05-12 (초안) / **갱신**: 2026-05-12 (UI/UX v2 — 게임 조종기 품질)
> **대상 스프린트**: Sprint 15 (`forge-core::teleop` + `RemotePilotView`)
> **선행 의존**: Sprint 1 Bus · Sprint 5 Walk · Sprint 6 Vision/Strategy · Sprint 8 Safety · Phase B Catalog · Phase D connect

---

## 0. TL;DR

**다윈 로봇을 진짜 게임 컨트롤러처럼 조종하는 전용 화면 (⌘8).** macOS 앱 안에 콘솔 게임기 수준의 조종 경험을 구현한다. 두 모드 — (a) **수동 Pilot**: 가상 D-pad + 키보드로 전진·후진·회전·동작 트리거, (b) **공 팔로우**: 카메라 영상 위 AR HUD + 자율 추적 루프 — 가 하나의 게임 HUD 화면에 공존한다. 모든 상태 변화는 부드러운 애니메이션으로 나타나고, 현재 로봇 상태는 레이싱 게임 계기판 스타일로 실시간 노출된다.

---

## 1. 배경 & 현황

### 1.1 기존 자산 (Sprint 1~13, Phase A/B/D)

| 레이어 | 모듈 | 상태 |
|---|---|---|
| **연결** | `Bus`(USB / TCP 5530) + `ConnectionStore`(watchdog) | ✅ 완성 |
| **걷기** | `WalkEngine`, `WalkPreset` 8종, `WalkSafety` | ✅ sim 완성 (실 IK = BLOCKER C3) |
| **모션** | `motion_4096.bin` 16 페이지, `forge motion play --engage` | ✅ 완성 |
| **비전** | `vision::detect_blob`, `HsvRange::ROBOCUP_BALL` | ✅ Rust 완성 |
| **전략 FSM** | `StrategyState` 5단계 | ✅ 완성 |
| **카메라** | `vision_demo` MJPEG `:8080/?action=snapshot` | ✅ 로봇 측 |
| **안전** | `precheck_motion`, `TorqueRamper`, `emergencyStop()` ⌘⇧. | ✅ 완성 |
| **원격 셸** | `RemoteShellView` ⌘6 (SSH/SMB 텍스트 채널) | ✅ 완성 (별도 유지) |
| **디자인 시스템** | `DFColor`, `DFNeon`, `DFAnimation`, `GlassNeon`, `KoreanUX` | ✅ 완성 |

### 1.2 사용자 요구

> *"가상의 조종기를 통해 로봇을 앞뒤로 조종하거나 공을 팔로우하는 원격 조종기 역할을 하는 메뉴를 — 사용성 있고 게임 같은 퀄리티로"*

요구 분해:
1. **별도 메뉴** — 기존 셸(⌘6) 과 분리된 전용 조종 화면
2. **게임 품질** — 일반 설정 화면이 아니라 실제 게임 컨트롤러 앱 수준의 인터랙션
3. **앞뒤 조종** — 전진·후진·회전·평행이동 + 동작 트리거
4. **공 팔로우** — 자율 루프, 사용자는 supervision
5. **사용성** — 처음 쓰는 사람도 보자마자 이해 (학습 없이 바로 조종)

### 1.3 핵심 제약 (논리적 근거)

| 제약 ID | 내용 | 설계 반영 |
|---|---|---|
| **C1** | 실 IK 미완성 (BLOCKER C3) | 슬라이더 풀-스윙 실송출 금지. 사전 검증된 `WalkPreset` 5종 + 모션 4종 만 실송출 |
| **C2** | `vision_demo` & `forge-bridge` 동시 `ttyUSB0` 불가 | Pilot 진입 시 자동 충돌 감지 + 안내 |
| **C3** | 네트워크 jitter (watchdog 임계 8회) | 명령 주기 USB 100ms / 네트워크 200ms |
| **C4** | `WalkEngine.enabled=true` 가 자체 stop 없음 | dead-man hold (사용자가 손 떼면 1 s 후 자동 정지) |
| **C5** | `SafetyClass::HighRisk` 모션은 confirm 필수 | Jog / 오른쪽 차기(page 12)는 confirm 다이얼로그 |

---

## 2. 목표 & 비목표

### 2.1 v1 목표

| # | 목표 | 성공 기준 |
|---|---|---|
| **G1** | 게임 조종기 경험 | 처음 사용자가 3 초 안에 D-pad 를 발견하고 클릭 |
| **G2** | Manual Pilot 8 프리셋 + 4 액션 | connected 상태에서 12 버튼 모두 동작 |
| **G3** | Ball-Follow 루프 | 공 배치 후 5 사이클 (~5 s) 내 로봇이 방향 전환 |
| **G4** | 4-layer 안전 게이트 | 테스트 시나리오 4건 모두 통과 |
| **G5** | 애니메이션 품질 | 모든 상태 전환에 `DFAnimation` 기반 spring 애니메이션 |
| **G6** | 시뮬 미리보기 | `Bus == nil` 에서도 화면이 온전히 동작 (sim 발 trail 등) |

### 2.2 비목표 (v1 제외, v2 후보)

- USB 게임패드 (GameController.framework) 지원
- 카메라 MJPEG 스트리밍 (→ v1 은 snapshot 폴링)
- Head pan/tilt 자동 추적 (joint 19/20)
- 음성 명령 (→ Conversation ⌘5)
- 다중 로봇 동시 조종

---

## 3. 화면 아키텍처 — 전체 구조

`RemotePilotView` 는 **세 영역** 으로 구성된다.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│  toolbar: ⬤ Connected  V 11.7  T 38°C  ARM 🔒→🔓  MODE ← → │ ⌘K  E-STOP 🔴  │
├───────────────────────────────────┬──────────────────────────────────────────────┤
│  LEFT PANEL (360 px, fixed)       │  RIGHT PANEL (fill)                          │
│                                   │ ┌──────────────────────────┐                 │
│  ╔═══════════════════════════╗    │ │  A  CAMERA + AR HUD      │                 │
│  ║  PILOT HUD (메인 조종)    ║    │ │  (공 팔로우 모드 시 활성) │                 │
│  ║                           ║    │ └──────────────────────────┘                 │
│  ║  [속도 계기판]  [phase]  ║    │ ┌──────────────────────────┐                 │
│  ║                           ║    │ │  B  3D 로봇 뷰 + foot    │                 │
│  ║       D - P A D           ║    │ │    trail (WalkEngine sim) │                 │
│  ║   ↑                       ║    │ └──────────────────────────┘                 │
│  ║ ← ◉ →  ↶  ↷              ║    │ ┌──────────────────────────┐                 │
│  ║   ↓                       ║    │ │  C  HUD STRIP (게임 계기판)│                │
│  ║                           ║    │ │  배터리·온도·IMU·세션타이머│                │
│  ╚═══════════════════════════╝    │ └──────────────────────────┘                 │
│                                   │                                               │
│  ACTION BAR                       │                                               │
│  [👋 인사] [⚽ 차기] [🪑 앉기] [🧍 서기]                                        │
│                                   │                                               │
└───────────────────────────────────┴──────────────────────────────────────────────┘
```

---

## 4. 디자인 시스템 확장 — Pilot 전용 토큰

기존 `DFColor` / `DFNeon` / `DFAnimation` 을 그대로 사용하되, Pilot 화면 전용 확장을 `PilotTokens.swift` 에 추가한다.

```swift
// Sources/DarwinForgeUI/Remote/PilotTokens.swift

enum PilotColor {
    // D-pad 활성 상태 — DFNeon.electric 기반
    static let dpadActive  = DFNeon.electric              // #19 8CDA — 누르는 동안
    static let dpadIdle    = DFColor.elev2                // 평상시

    // 속도 계기판 arc
    static let speedSafe   = DFColor.success              // 0~50%
    static let speedCaution = DFColor.warning             // 50~80%
    static let speedDanger = DFColor.danger               // 80~100%

    // 공 팔로우 상태 배지
    static let stateIdle      = DFColor.textSecondary
    static let stateLooking   = DFColor.warning
    static let stateApproach  = DFNeon.electric
    static let stateLockedOn  = DFColor.success           // 가까워짐
    static let stateLost      = DFColor.danger

    // Dead-man hold 충전 링 색
    static let holdCharging   = DFColor.warning
    static let holdFull       = DFColor.danger            // 1 s 충전 완료 → 정지
}

enum PilotAnim {
    // D-pad 누름/뗌 — 빠른 spring
    static let dpadPress = Animation.spring(response: 0.12, dampingFraction: 0.7)
    // 상태 배지 전환 — 느린 spring
    static let stateChange = Animation.spring(response: 0.35, dampingFraction: 0.75)
    // 속도 게이지 arc 스윕 — easeOut 0.22s
    static let gauge = Animation.easeOut(duration: 0.22)
    // Action 버튼 진행 링 — linear (duration = 모션 총 시간)
    static let motionProgress = Animation.linear
    // 모드 전환 페이드 — 0.3 s
    static let modeSwitch = Animation.easeInOut(duration: 0.30)
    // 잠금/해제 아이콘 wiggle (arm 시)
    static let lockPop = Animation.spring(response: 0.25, dampingFraction: 0.5)
    // Blob 십자선 위치 보간 — 부드러운 추적
    static let blobTrack = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.85)
}
```

---

## 5. 컴포넌트 명세 — 상세 인터랙션

### 5.1 ARM 토글 (안전 잠금)

**기존 PRD 체크박스 → 물리 잠금 슬라이더로 교체.** iOS "밀어서 잠금 해제" 패턴.

```
비활성: ┌─────────────────────────────────────────┐
        │  🔒  거치대 거치 + 빈 공간 확인 후 밀기  →  │
        └─────────────────────────────────────────┘
           thumb 이 오른쪽 끝까지 오면 ARM 완료:
활성:   ┌─────────────────────────────────────────┐
        │                        🔓  ARM 완료     │
        └─────────────────────────────────────────┘
```

- thumb 을 오른쪽으로 drag 해야만 ARM (실수 클릭 방지)
- ARM 완료 시: 잠금 아이콘 0.4 s spring bounce (`PilotAnim.lockPop`)
- ARM 완료 시: D-pad 와 Action Bar 가 `.dfDisabled(false)` + opacity 1.0 으로 fade in
- DISARM 은 잠금 아이콘 단순 탭 → 즉시 (`PilotAnim.dpadPress`)
- 아이콘: `lock.fill` → `lock.open.fill` (SF Symbols)
- 배경 그라데이션: 비활성 `DFColor.elev2`, 활성 `DFColor.success.opacity(0.15)`
- "왜 해야 하나" 아이콘 (?) 탭 → sheet: 거치대·공간 안전 안내 (KoreanUX.Safety 기반)

### 5.2 모드 토글 (Manual ↔ Ball-Follow)

**커스텀 세그먼트 피커 — 선택 thumb 이 animate 이동.**

```
[ 🕹 수동 조종 | 🎯 공 팔로우 ]
     ▲ 선택 thumb 이 slide
```

- 전환 시 우측 패널 레이아웃이 `PilotAnim.modeSwitch` 로 크로스페이드
- Manual 모드: 우측 = 3D 로봇 뷰 (메인) + 카메라 썸네일 (mini)
- Ball-Follow 모드: 우측 = 카메라 (메인, 전체 채움) + 3D 뷰 (mini)
- 모드 전환 중 1 프레임 간 `Stop` 명령 자동 송출 (race 방지)

### 5.3 D-pad 컴포넌트 (`PilotDpad`)

**5-way 방향 + 2 회전 = 7 존. 단순 그리드가 아니라 컨트롤러 감각.**

```
레이아웃 (정사각 220×220):
         ┌───────┐
         │  ↑    │  35×35, corner-radius 8
    ┌────┤  위   ├────┐
    │ ← │       │ → │
    │ 좌 │  ◉   │ 우 │  중앙 정지 — 원형 56 pt (ISO 13850 e-stop 기준)
    └────┤  아래 ├────┘
         │  ↓    │
         └───────┘
   [ ↶ 좌회전 ]  [ 우회전 ↷ ]   ← D-pad 아래 행, 104×36 각각
```

**인터랙션 디테일:**
- `mouseDown` / `.keyDown` → 버튼 scale(0.88) + `PilotColor.dpadActive` 채움 + `PilotAnim.dpadPress`
- `mouseUp` / `.keyUp` → scale(1.0) + `PilotColor.dpadIdle` + dead-man 1 s 타이머 시작
- 중앙 ◉ 버튼: 상시 접근 가능 (ARM 여부 무관). `DFColor.danger` 배경.
- 누르는 동안: **Hold Ring** (회색 원 외곽 → 1 s 후 `PilotColor.holdDanger` 로 채워지는 진행 링). 다 채워지면 dead-man 강제 stop.
- Shift 누르며 방향 → 버튼 라벨이 "↑" → "↑↑" 로 애니메이션 변경 (FastWalk)

**키 매핑표:**

| 키 | 방향 | Hold Shift |
|---|---|---|
| W / ↑ | 전진 (NormalWalk) | 빠르게 (FastWalk) |
| S / ↓ | 후진 | — |
| A / ← | 좌평행 | — |
| D / → | 우평행 | — |
| Q | 좌회전 | — |
| E | 우회전 | — |
| Space / ◉ | 즉시 정지 | — |
| 1..4 | 액션 버튼 | — |
| ESC | DISARM | — |

**WalkPreset 매핑:**

| D-pad 방향 | 기본 preset | Shift preset | period |
|---|---|---|---|
| ↑ 전진 | `NormalWalk` (x=0.025) | `FastWalk` (x=0.035, T=500) | 600/500 ms |
| ↓ 후진 | x=-0.020 | x=-0.030 | 600 ms |
| ← 좌평행 | y=+0.020 | y=+0.030 | 600 ms |
| → 우평행 | y=-0.020 | y=-0.030 | 600 ms |
| ↶ 좌회전 | `TurnLeft` (a=+0.10) | a=+0.15 (Caution) | 600 ms |
| ↷ 우회전 | `TurnRight` (a=-0.10) | a=-0.15 (Caution) | 600 ms |

### 5.4 속도 계기판 (`PilotSpeedGauge`)

**레이싱 게임 arc 게이지 — D-pad 가 눌릴 때 0 → max 로 스윕.**

```
      90°
   ┌──╱──┐
   │  ↑  │   arc: -130° ~ +130° (260° sweep)
   │     │   0% = 왼쪽 시작 / 100% = 오른쪽 끝
   └─────┘
     0..100% 텍스트 (현재 보폭 비율)
```

- **색상 구간**: 0~50% `DFColor.success`, 50~80% `DFColor.warning`, 80~100% `DFColor.danger`
- **애니메이션**: `PilotAnim.gauge` (easeOut 0.22 s) — 버튼 누름/뗌에 부드럽게 반응
- **arc 두께**: 6pt. 미충전 부분은 `DFColor.elev2`.
- **중앙 텍스트**: `"NormalWalk"` / `"FastWalk"` 등 한국어 프리셋 이름 (9pt caption)
- **아래 숫자**: `+2.5 cm/step` — 실제 `x_amplitude * 100 * 100` cm 표기

### 5.5 Walk Phase 인디케이터 (`PilotPhaseBar`)

**4분할 세그먼트 바 — 현재 phase 가 순서대로 점등. 걸음 리듬 시각화.**

```
PHASE0 ● ─ ─ ─   (정지 = 첫 세그먼트만 켜짐)
PHASE1 ● ■ ─ ─   (왼발 들기)
PHASE2 ● ■ ■ ─   (양발 지지)
PHASE3 ● ■ ■ ■   (오른발 들기)
```

- 각 세그먼트: 36×8 pt, corner-radius 4
- 활성: `DFNeon.electric`, 비활성: `DFColor.elev2`
- 전환: `PilotAnim.gauge` 로 색상 보간
- 아래 캡션: `"PHASE2 · 280 ms"` (경과 ms)

### 5.6 Action Bar (`PilotActionBar`)

**4개 큰 버튼 — 누르면 진행 링이 모션 재생 시간 동안 채워짐.**

```
┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  ●●●●●●●●●   │  │               │  │               │  │               │
│    👋 인사    │  │  ⚽ 차기      │  │  🪑 앉기     │  │  🧍 서기     │
│  page 4 · 2s │  │  page 12 · 3s │  │  page 15 · 2s│  │  page 1 · 2s │
└───────────────┘  └───────────────┘  └───────────────┘  └───────────────┘
     ↑ 진행 중 (progress ring + percent)
```

**버튼 상태 3종:**

| 상태 | 외관 | 설명 |
|---|---|---|
| **idle** | `DFColor.forge.opacity(0.12)` 배경 + forge 테두리 | 클릭 대기 |
| **playing** | 원형 progress ring (stroke 3pt, `DFColor.forge`) + 내부 흐릿하게 | 모션 재생 중. D-pad 전체 disable |
| **cooldown** | 0.8 s 회색 dim + 체크 아이콘 → fade out → idle 복귀 | 완료 직후 시각 피드백 |

- `WalkSafety.HighRisk` 버튼 (Jog, page 12): 버튼 테두리 `DFColor.danger` + 소형 `⚠` 아이콘 → 클릭 시 Alert
- 동작 중에는 D-pad 와 모드 토글 `allowsHitTesting(false)`
- 키 단축키: 1(인사) / 2(차기) / 3(앉기) / 4(서기)

**Action 매핑:**

| 버튼 | slot | 한국어 | SafetyClass | duration |
|---|---|---|---|---|
| 인사 | 4 | "손 흔들기" | Safe | ~2.1 s |
| 차기 | 12 | "오른쪽 차기" | Caution | ~3.0 s |
| 앉기 | 15 | "앉기" | Caution | ~2.0 s |
| 서기 | 1 | "기본자세" | Safe | ~2.0 s |

### 5.7 카메라 + AR HUD (`PilotCameraView`)

**Ball-Follow 모드 시 카메라 영상 위에 AR 오버레이 렌더링.**

```
┌──────────────────────────────────────────────────────┐
│  ┌─────── MJPEG frame (NSImage) ───────────────────┐  │
│  │                                                  │  │
│  │         ┌──────────────────────────┐            │  │
│  │         │   [APPROACHING] ●        │            │  │
│  │         └──────────────────────────┘            │  │
│  │                                                  │  │
│  │              ╋ (blob centroid 십자선)            │  │
│  │           ┌──────────────────────────┐          │  │
│  │           │  💚  blob 312px · 34%    │          │  │
│  │           └──────────────────────────┘          │  │
│  │                                                  │  │
│  │  LOOKING  APPROACH  LOCK-ON  COOLDOWN  IDLE     │  │
│  └─────────────────────────────────────────────────┘  │
│  [ 🟠 공 색상: 주황 ▾ ]  [  100 ms 폴링 · snapshot ]  │
└──────────────────────────────────────────────────────┘
```

**오버레이 요소:**

1. **상태 배지** (화면 상단 중앙):
   - `IDLE` — 회색 pill
   - `LOOKING…` — 노란 pill + 점멸 (1Hz, opacity 0.5↔1.0 pulse)
   - `APPROACHING ●` — `DFNeon.electric` pill + 중앙 채워지는 원
   - `LOCKED ON 🎯` — `DFColor.success` pill + 실선 외곽 테두리 pulse
   - `LOST ✕` — `DFColor.danger` pill + 0.4 s 흔들림 (shake animation)

2. **Blob 십자선** (`TargetReticle`):
   - 4개 L자 코너 + 중앙 점. 합치면 십자선 모양.
   - `PilotAnim.blobTrack` 으로 centroid 위치 부드럽게 이동
   - LOCKED ON 상태: 코너 4개가 안쪽으로 수축 (scale 0.7, animated)
   - LOST 상태: 코너 fade out → 점만 남음

3. **Blob 정보 pill** (십자선 아래):
   - `"🟠 312 px · 34%"` — 픽셀 수 + 프레임 대비 비율
   - `"1.1 m ≈"` — pixel_count → 거리 추정 (MVP 단순 역비례: 1000px ≈ 0.5m)

4. **FSM progress bar** (화면 하단):
   - 5 단계 점 (IDLE / LOOK / APPROACH / LOCK / COOL)
   - 현재 단계가 채워짐. 전환 시 `PilotAnim.stateChange` 보간

5. **Auto-Walk 토글** (우하단 mini):
   - 켜짐: 초록 `⬤ Auto-Walk ON` — 자동 WalkCommand 송출
   - 꺼짐: 회색 `⬤ Auto-Walk OFF` — 카메라만 보기, 조종은 수동

### 5.8 게임 HUD Strip (`PilotHudStrip`)

**화면 하단 띠 — 레이싱 게임 계기판 스타일.**

```
┌──────────────────────────────────────────────────────────────────┐
│ 🔋 11.7V  ▓▓▓▓▓▓▓▓░░  │  🌡 38°C  ▓▓▓▓░░░░  │  IMU  ━━━━━━━━━━━ │
│                           │ roll +2°  pitch -1° │ ═══◉═══          │
│ Session ⏱ 00:12 / 01:00 ━━━━━━━━━━━━━░ 12/60s  │ [E-STOP ⌘⇧.] 🔴  │
└──────────────────────────────────────────────────────────────────┘
```

**각 계기:**

1. **배터리 바**: `DFColor.success`(≥11.1V) → `warning`(≥9.5V) → `danger`(<9.5V). 8 세그먼트 블록 바. 0.1V 변화 시 `DFAnimation.standard` 로 부드럽게 업데이트.

2. **온도 바**: 0~80°C 범위. 60°C 이상에서 빨간 pulse. 8 세그먼트.

3. **IMU 롤/피치 지시기** (인공수평선 스타일):
   - 작은 직사각형(80×20 pt) 안에 가운데 선 (지평선) + 이동하는 ◉ (로봇 기울기)
   - roll ±30° 범위 매핑. 범위 초과 시 `DFColor.danger` + pulse
   - 아래: `"roll +2.1° pitch -0.8°"` 숫자 텍스트

4. **세션 타이머**:
   - `⏱ 00:12 / 01:00` — 경과 / 최대 (`preset.max_duration_secs`)
   - 진행 바: 가득 차면 `DFColor.danger` 로 전환 + 10초 전부터 pulse
   - 완료 시 자동 Stop + 토스트

5. **E-Stop 버튼**: 항상 우측. 56pt (ISO 13850). `DFColor.danger`.

---

## 6. 화면 상태 머신

```
            ┌───────────────────────────────────────────────────────┐
            │               RemotePilotView 상태                    │
            └───────────────────────────────────────────────────────┘
                     │ onAppear
                     ▼
            ┌─────────────────┐
            │  SIM_READY      │  Bus == nil. 시뮬 모드. 모든 UI 표시.
            │  (D-pad 회색)   │  "연결하면 실제 로봇에 적용" 배너.
            └────────┬────────┘
                     │ Bus 연결
                     ▼
            ┌─────────────────┐
            │  UNARMED        │  ARM 슬라이더 대기.
            │  (D-pad disable)│  실 로봇 명령 차단.
            └────────┬────────┘
                     │ ARM 슬라이더 완료
                     ▼
            ┌─────────────────┐
            │  READY (Manual) │◄─────────────────────────────┐
            │  (D-pad 활성)   │                              │
            └──┬──────────────┘                              │
               │ D-pad 눌림           Motion 완료            │
               ▼                              ▲              │
            ┌──────────────────┐  ┌──────────┴────────┐     │
            │  WALKING          │  │  MOTION_PLAYING   │     │
            │  D-pad hold       │  │  D-pad disabled   │     │
            └──┬───────────────┘  └───────────────────┘     │
               │ 손 뗌 / dead-man   Action 버튼 누름         │
               ▼                                             │
            ┌─────────────────┐  모드 전환                   │
            │  STOPPING        ├─────────────────────────────┘
            │  (1s fade stop)  │
            └────────┬─────────┘
                     │ enabled=false 송출
                     ▼
                  READY (복귀)

            [Ball-Follow 모드]
            READY → BALL_FOLLOWING (auto-walk on)
                  ↕  blob detect 루프
                  → LOOKING / APPROACHING / LOCKED_ON / LOST
            LOST 5s → READY + 토스트
```

---

## 7. 아키텍처 — 신규 컴포넌트

### 7.1 forge-core::teleop (Rust)

```
forge-core/src/teleop/
├── mod.rs           — pub 재수출
├── command.rs       — TeleopCommand enum + safety() + max_duration_secs()
├── gate.rs          — SafetyGate struct + GateReason enum
└── ballfollow.rs    — BallFollowConfig + decide() → BallFollowDecision
```

#### `TeleopCommand`

```rust
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum TeleopCommand {
    Walk {
        command: WalkCommand,
        period_ms: u32,
        max_duration_secs: u32,
    },
    Motion { slot: u8, confirm_risk: bool },
    Stop,
}
```

#### `SafetyGate`

```rust
pub struct SafetyGate {
    pub armed: bool,
    pub last_input_at: Instant,
    pub deadman_timeout_ms: u64,   // 1000
    pub max_imu_roll_deg: f32,     // 25.0
    pub max_imu_pitch_deg: f32,    // 30.0
    pub session_start: Option<Instant>,
}

pub enum GateReason {
    NotArmed,
    RiskNotConfirmed,
    DeadmanTimeout,
    ImuOutOfRange { roll: f32, pitch: f32 },
    SessionExpired { max_secs: u32 },
}
```

#### `BallFollowConfig::decide`

```rust
impl BallFollowConfig {
    pub fn decide(
        &self,
        frame: &Frame,
        prev_state: StrategyState,
        since_kick_ms: u32,
    ) -> BallFollowDecision {
        let blob = detect_blob(frame, self.hsv);
        let input = StrategyInput { ball: blob, since_kick_ms, abort: false };
        let state  = prev_state.next(input);
        let command = self.state_to_command(state, &blob);
        BallFollowDecision { state, command, blob }
    }

    fn state_to_command(&self, state: StrategyState, blob: &BlobResult) -> TeleopCommand {
        match state {
            StrategyState::LookingForBall =>
                TeleopCommand::Walk { command: WalkCommand { a_amplitude: 0.15, enabled: true, .. }, .. },
            StrategyState::ApproachingBall => {
                let cx_norm = (blob.centroid_x - frame_w/2.0) / (frame_w/2.0);
                TeleopCommand::Walk { command: WalkCommand {
                    x_amplitude: self.forward_amplitude * (1.0 - cx_norm.abs()),
                    a_amplitude:  cx_norm * self.max_turn_rate,
                    enabled: true,
                    .. }, .. }
            },
            StrategyState::Kicking =>
                TeleopCommand::Stop,  // 사용자 수동 차기 (auto-kick OFF 기본)
            _ => TeleopCommand::Stop,
        }
    }
}
```

### 7.2 Swift 컴포넌트 목록

| 파일 | 책임 |
|---|---|
| `Remote/PilotTokens.swift` | `PilotColor`, `PilotAnim` enum |
| `Remote/TeleopChannel.swift` | actor — 단일 `send(_:)` 진입점, dead-man timer, gate 평가 |
| `Remote/PilotSafetyGate.swift` | `@Observable` — armed, IMU 구독, session timer |
| `Remote/BallFollowEngine.swift` | `@Observable` — snapshot 폴링, FFI `fc_ballfollow_decide`, state |
| `Remote/MjpegSnapshot.swift` | URLSession 기반 100 ms JPEG 폴링 → NSImage |
| `Remote/RemotePilotView.swift` | 최상위 화면 |
| `Remote/PilotArmSlider.swift` | 밀어서 ARM 슬라이더 컴포넌트 |
| `Remote/PilotModePicker.swift` | 애니메이션 세그먼트 피커 (Manual / Ball-Follow) |
| `Remote/PilotDpad.swift` | D-pad 7 존 + Hold Ring |
| `Remote/PilotSpeedGauge.swift` | Arc 속도계 + phase 바 |
| `Remote/PilotActionBar.swift` | 4 Action 버튼 + progress ring |
| `Remote/PilotCameraView.swift` | NSImage 표시 + AR HUD overlay |
| `Remote/TargetReticle.swift` | 십자선 + LOCKED ON 애니메이션 |
| `Remote/PilotHudStrip.swift` | 배터리·온도·IMU 인공수평선·세션 타이머·E-Stop |

### 7.3 TeleopChannel (actor 핵심)

```swift
@MainActor
public final class TeleopChannel: ObservableObject {
    public enum Mode: Sendable { case manual, ballFollow }
    @Published public private(set) var mode: Mode = .manual
    @Published public private(set) var currentCmd: TeleopCommand = .Stop
    @Published public private(set) var isDeadmanActive: Bool = false

    private let store: ConnectionStore
    private var deadmanTask: Task<Void, Never>?
    private var sendCadenceNs: UInt64 { store.activeEndpoint?.isNetwork == true ? 200_000_000 : 100_000_000 }

    public func send(_ cmd: TeleopCommand) async throws {
        // 1) Gate check
        try gate.allow(cmd: cmd, imu: store.lastImu)
        // 2) Dispatch
        switch cmd {
        case .Walk(let wc, let pm, _):
            if let bus = store.bus {
                engine.setCommand(x: wc.x_amplitude, y: wc.y_amplitude,
                                  a: wc.a_amplitude, enabled: wc.enabled)
                engine.setPeriodMs(Double(pm))
                // walk → leg joints sync write (실 IK 완성 후 unlock)
                // v1: IK 없으므로 WalkPreset 사전 검증된 경우에만 실송출
                try bus.applyWalkPreset(…)
            }
        case .Motion(let slot, let confirm):
            guard !confirm || gate.confirmRisk else { throw GateError.riskNotConfirmed }
            try await store.playMotionSlot(slot)
        case .Stop:
            store.bus?.stopWalk()
        }
        currentCmd = cmd
        resetDeadman()
    }

    private func resetDeadman() {
        deadmanTask?.cancel()
        deadmanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isDeadmanActive = true
            try? await self?.send(.Stop)
        }
    }
}
```

---

## 8. 안전 게이트 — 결정 트리 (갱신)

```
사용자 입력 / Ball-Follow 결정
        │
  [L0] ⌘⇧. 어디서나 → emergencyStop() 즉시. 화면 전체 빨간 flash 0.3s.
        │
  [L1] gate.armed == false
        → 명령 무시. ARM 슬라이더 wiggle 애니메이션.
        │
  [L2] cmd.safety == .highRisk && !confirmRisk
        → Alert: "위험 동작 확인" → 확인 시 재시도 / 닫기 시 무시.
        │
  [L3] now - lastInputAt > 1 s (deadman)
        → Walk(enabled: false) 자동. D-pad Hold Ring 빨간 flash.
        │
  [L4a] |imu.roll| > 25° || |imu.pitch| > 30°
        → Stop + 토스트 "기울어짐 감지 — 정지했어요"
        │
  [L4b] sessionElapsed > preset.max_duration_secs
        → Stop + 타이머 카운트다운 종료 토스트.
        │
  → Bus.send(cmd)   캐덴스: USB 100ms / 네트워크 200ms
```

---

## 9. 마이크로 인터랙션 & 애니메이션 목록

| 이벤트 | 애니메이션 | 지속 |
|---|---|---|
| ARM 슬라이더 완료 | 잠금 아이콘 bounce + D-pad fade in | 0.4 s spring |
| D-pad 버튼 누름 | scale 0.88 + 색상 → `PilotColor.dpadActive` | 0.12 s spring |
| D-pad 버튼 뗌 | scale 1.0 + 색상 복귀 | 0.18 s spring |
| dead-man hold ring 충전 | 원형 progress 0→1 (1 s) | 1.0 s linear |
| dead-man 완료 → Stop | ring flash red + D-pad fade dim | 0.3 s |
| 속도 계기판 호 스윕 | 0→N% arc | 0.22 s easeOut |
| Phase 세그먼트 전환 | 색상 보간 | 0.22 s easeOut |
| Action 버튼 누름 | progress ring 채워짐 (모션 duration) | N s linear |
| Action 완료 | 체크 아이콘 pop + 0.8 s cooldown | 0.25 s spring |
| 모드 전환 | 오른쪽 패널 크로스페이드 | 0.30 s easeInOut |
| Blob 십자선 이동 | interactiveSpring 보간 | —  |
| LOOKING 상태 배지 | pulse (opacity 0.5↔1.0) | 0.6 s repeat |
| LOCKED ON 배지 | 외곽 pulse + 십자선 수축 | 0.5 s spring |
| LOST 배지 | 수평 shake 3회 | 0.4 s |
| IMU 범위 초과 | 화면 상단 빨간 flash + shake | 0.4 s |
| 배터리 < 9.5V | 배터리 아이콘 pulse | 1 s repeat |
| 세션 마지막 10 s | 타이머 텍스트 orange → red | 0.5 s easeIn |
| E-Stop 클릭 | 전체 화면 빨간 flash + scale 0.95 | 0.3 s |

---

## 10. 빈 상태 & 에러 상태 처리

| 상황 | 화면 표현 |
|---|---|
| **Bus == nil (sim 모드)** | D-pad 동작하나 "시뮬 모드 — 실 로봇 연결 안 됨" 상단 배너 (DFColor.info) |
| **ARM 전** | D-pad + Action 회색 overlay + "안전 확인 후 밀어서 시작" 라벨 |
| **vision\_demo 충돌** | 상단 경고 배너 "vision\_demo 가 ttyUSB0 점유 중. QuickAction 으로 중지하세요" + 링크 → RemoteShellView |
| **카메라 오프라인** | PilotCameraView 에 "카메라 오프라인 — vision\_demo 시작 필요" 텍스트 + 버튼 |
| **LOST 5s 초과** | 전체 화면 dim + "공을 찾을 수 없어요. 수동 모드로 전환할까요?" 오버레이 |
| **Bus drop (watchdog)** | D-pad 즉시 disable + 빨간 배너 "연결 끊김 — 재연결 중" + ConnectionStore 재연결 시도 |

---

## 11. 접근성 (Accessibility)

- 모든 D-pad 버튼: `accessibilityLabel("전진")`, `accessibilityHint("누르는 동안 로봇이 앞으로 걸어요")`
- E-Stop: `accessibilityLabel("긴급 정지")` — VoiceOver 최우선
- 색상 단독 정보 사용 금지 — 모든 상태 배지에 텍스트 라벨 병기
- reduce-motion: 모든 애니메이션 → `DFAnimation.fast` 축소 (`@Environment(\.accessibilityReduceMotion)`)

---

## 12. RootView 통합 변경

```swift
// RootView.swift 변경 3곳:

// 1. Section 추가
private enum Section: String, CaseIterable {
    case studio, teach, motion, walk, conversation, remote, pilot, expert
    //                                                       ^^^^^^ 신규
    var label: String { /* … case .pilot: return "원격 조종" */ }
    var icon: String  { /* … case .pilot: return "gamecontroller.fill" */ }
    var shortcut: String { /* … case .pilot: return "⌘8" */ }
    var tint: Color { /* … case .pilot: return DFNeon.electric */ }
}

// 2. detail switch
case .pilot:
    RemotePilotView()

// 3. globalShortcuts
Button("Section 8") { section = .pilot }
    .keyboardShortcut("8", modifiers: .command)
    .opacity(0).frame(width: 0, height: 0)
```

---

## 13. 테스트 전략

### 13.1 Rust forge-core::teleop 단위 테스트 (목표 24+)

| 파일 | 테스트 | 기준 |
|---|---|---|
| `command.rs` | 6 | `TeleopCommand::safety()` WalkPreset 매핑 일치 / JSON round-trip |
| `gate.rs` | 10 | L1~L4 각 reason 차단 + armed/deadman/imu/duration 4 pass |
| `ballfollow.rs` | 8 | LOOKING/APPROACH/LOCK_ON 3 분기 + dead zone + LOST + serde |

### 13.2 Swift 단위 테스트 (목표 18+)

| 파일 | 테스트 |
|---|---|
| `TeleopChannel` | send mock Bus payload / dead-man timer (1.05 s → Stop) / gate fail 4종 |
| `PilotSafetyGate` | arm/disarm 전환 / IMU threshold / session expiry |
| `BallFollowEngine` | state transitions / auto-walk on/off |
| `PilotArmSlider` | drag completion → armed / partial drag → not armed |
| `PilotDpad` | keyDown W/A/S/D/Q/E → correct WalkPreset |

### 13.3 Hardware-in-the-loop (실기기 4 시나리오)

| 시나리오 | 통과 기준 |
|---|---|
| cradle → arm → 전진 1s → release | 1s 이내 정지 |
| 공 1m 배치 → Ball-Follow ON | 5 사이클 내 방향 전환 |
| IMU 30° 기울임 (cradle 비틀기) | 즉시 정지 |
| 네트워크 끊김 4s | dead-man + watchdog 모두 → .error |

---

## 14. Sprint 15 구현 단계 (5일)

| Day | 작업 | 완료 기준 |
|---|---|---|
| **1** | `forge-core::teleop` 신규 모듈 + ffi | `cargo test` 24+ pass |
| **2** | `TeleopChannel` actor + `PilotSafetyGate` + `BallFollowEngine` | Swift 18+ tests pass |
| **3** | `PilotArmSlider` + `PilotModePicker` + `PilotDpad` + `PilotSpeedGauge` + `PilotPhaseBar` | swift build ✓, UI 표시 확인 |
| **4** | `PilotActionBar` + `PilotCameraView` + `TargetReticle` + `MjpegSnapshot` | Ball-Follow HUD 표시 확인 |
| **5** | `PilotHudStrip` + `RemotePilotView` 통합 + RootView ⌘8 + 마이크로 인터랙션 전체 | E2E 4 시나리오 통과 |

---

## 15. 미해결 사항 (Open Questions)

| OQ | 내용 | 결정 시점 |
|---|---|---|
| **OQ-1** | BLOCKER C3 해결 후 슬라이더 풀-스윙 허용 범위 | Sprint 14 walk-lab 실험 후 |
| **OQ-2** | MJPEG snapshot 100ms → streaming 전환 필요성 | Day 4 measure 후 |
| **OQ-3** | HSV 범위 형광등/자연광 robust 여부 | 실측 후 조정 |
| **OQ-4** | USB 게임패드 (GameController.framework) v2 지원 | v2 PRD |
| **OQ-5** | 두 Mac 동시 연결 시 TCP 세션 거버넌스 | Sprint 15 후 |
| **OQ-6** | IMU 센서가 `LiveTelemetry` 에 아직 없음 → `imuRoll`/`imuPitch` 보강 필요 | Day 2 착수 전 확인 |

---

## 부록 A — 기존 코드 재사용 매핑

| 기능 | 재사용 자산 | 변경 여부 |
|---|---|---|
| Bus 송출 | `ConnectionStore.bus`, `Bus.write` | × |
| Walk sim | `WalkEngine.setCommand`, `setPeriodMs` | × |
| Walk 실송출 | `WalkLab` 의 "로봇에 적용" 공유 헬퍼 추출 | 리팩토링 |
| Motion 트리거 | `motion_play.rs` → ffi `fc_motion_play(slot, engage)` 노출 필요 | + ffi |
| 안전 등급 | `WalkSafety`, `SafetyClass`, `precheck_motion` | × |
| E-Stop | `ConnectionStore.emergencyStop()` ⌘⇧. | × |
| 텔레메트리 | `ConnectionStore.lastTelemetry` | + IMU roll/pitch 추가 |
| 카메라 | 기존 `:8080` URL 참조 | + `MjpegSnapshot` 신규 |
| HSV blob | `vision::detect_blob`, `HsvRange` | × |
| FSM | `StrategyState.next` | × |
| 디자인 시스템 | `DFColor`, `DFNeon`, `DFAnimation`, `GlassNeon`, `KoreanUX` | + `PilotTokens` 신규 |
| Shell | `RemoteShellView` ⌘6 | × (독립 유지) |

---

## 부록 B — 논리적 근거 요약 (13 가지)

1. **별도 화면 ⌘8** — RemoteShell(텍스트 채널)과 인터랙션 모델이 근본적으로 다름
2. **ARM 슬라이더** — 체크박스는 실수 클릭 위험. 방향성 drag 가 의도 확인에 안전
3. **두 모드뿐** — 자연어 조종은 Conversation(⌘5) 이 담당. teleop 은 실시간 물리 조종만
4. **WalkPreset 5종 실송출** — C3(실 IK) 가 stub 인 동안 임의 (x,y,a) 실송출 금지
5. **dead-man hold** — WalkEngine 자체 stop 없음 + 네트워크 끊김 시 무한 전진 방지
6. **hold ring 시각화** — 사용자가 "언제 멈추나" 를 눈으로 확인 가능 (투명성)
7. **Auto-Kick 기본 OFF** — 픽셀 기반 close-enough (>1000px) 의 false positive 위험
8. **snapshot 폴링 1차** — multipart streaming 구현 복잡도 대비 v1 효과 동일
9. **Rust teleop 모듈** — Swift 중복 시 안전 게이트 분기 위험. 단일 소스
10. **Action bar progress ring** — 모션 재생 중 D-pad disable 을 사용자에게 명확히 표현
11. **LOCKED ON 시 Stop** — 차기는 사용자 확인 필수 (Auto-Kick OFF 기본)
12. **PilotTokens 별도 파일** — 기존 DFColor 오염 없이 Pilot 전용 확장
13. **⌘8** — ⌘1..5 기본·⌘6 셸·⌘7 Expert 다음 자연 슬롯

---

*참고: `docs/walk-lab/V1_DESIGN.md` (8 preset 정의) · `docs/prd/motion-synthesis-v1.md` (SafetyClass) · `docs/HARDWARE_VERIFICATION_PROTOCOL.md` (G3 forge motion play) · `docs/DESIGN_CONVERSATIONAL_UX.md` (1X NEO 두 모드 패턴)*
