# PRD — Remote Pilot v1: 원격 조종 스튜디오 (공식 ROBOTIS 데모 충실 버전)

> **상태**: Design Frozen v2 — 구현 준비 완료
> **작성일**: 2026-05-12 (초안 v1) / **갱신**: 2026-05-12 (v2 — 공식 자료 audit 반영)
> **대상 스프린트**: Sprint 15 (`forge-core::teleop` + `RemotePilotView`) — **7일**
> **선행 의존**: Sprint 1 Bus · Sprint 5 Walk · Sprint 6 Vision/Strategy · Sprint 8 Safety · Phase B Catalog · Phase D connect
> **공식 출처**: ROBOTIS-OP2 `op2_walking_module` · `motion_4096.bin` (256 페이지) · `BallFollower.cpp` 표준 알고리즘 · `StatusCheck.cpp` (자동 복구) · `VisionMode.cpp` (페이지 매핑) · `Action.h` (PAGEHEADER 포맷)
> **연관 문서**: `docs/prd/teleop-v1-audit.md` (충실도 점검)

---

## 0. 핵심 원칙 — "공식 데모는 완벽하다, 그대로 실행한다"

본 PRD 의 절대 원칙:

1. **`motion_4096.bin` 페이지 데이터는 단 1 byte 도 수정하지 않는다.** ROBOTIS 가 손으로 튜닝한 모션이며, byte-identical round-trip 검증 완료 (Phase B).
2. **페이지 ID, raw_name, mp3 동기, duration_ms 는 공식 카탈로그를 그대로 따른다.** UI 라벨은 sidecar `display_name` 채택.
3. **공식 BallFollower 알고리즘**: head 가 1차 추적자, walk 가 head 각도를 따라간다.
4. **공식 StatusCheck 자동 복구**: 자이로 fall detection → page 10/11 자동 트리거.
5. **공식 walking_param_ 인터페이스**: `x_move_amplitude`, `y_move_amplitude`, `a_move_amplitude` + PHASE0..3 의 의미를 1:1 유지.

---

## 1. TL;DR

**다윈 로봇을 진짜 게임 컨트롤러처럼 조종하는 전용 화면 (⌘8). 공식 ROBOTIS 데모의 모션 16 페이지 + BallFollower 알고리즘을 그대로 실행할 수 있는 macOS 네이티브 GUI.** 두 모드 — (a) **수동 Pilot**: 가상 D-pad + 키보드로 X/Y/A amplitude 송출 + 7 개 데모 페이지 트리거, (b) **공 팔로우**: 공식 BallFollower 패턴 (head PID 추적 → head 각도 → walk amplitude → 좌/우 차기 자동 선택). 자이로 낙상 감지 시 page 10/11 자동 복구. 모든 페이지는 ROBOTIS sidecar `display_name` + mp3 라벨로 노출.

---

## 2. 배경 & 현황

### 2.1 기존 자산

| 레이어 | 모듈 | 상태 |
|---|---|---|
| **연결** | `Bus`(USB / TCP 5530), `ConnectionStore`, watchdog | ✅ 완성 |
| **걷기** | `WalkEngine`, `WalkPreset` 8종, `WalkSafety` | ✅ sim 완성 (실 IK = BLOCKER C3) |
| **모션 카탈로그** | `motion_4096.bin` 16 페이지 (Phase B `Library::with_official_catalog`) | ✅ byte-identical |
| **모션 송출** | `forge motion play --slot N --engage` | ✅ 완성 |
| **비전** | `vision::detect_blob`, `HsvRange::ROBOCUP_BALL` | ✅ Rust 완성 |
| **전략 FSM** | `StrategyState` 5단계 | ✅ 완성 |
| **카메라** | `vision_demo` MJPEG `:8080` snapshot | ✅ 로봇 측 |
| **안전** | `precheck_motion`, `TorqueRamper`, ⌘⇧. | ✅ 완성 |
| **디자인 시스템** | `DFColor`, `DFNeon`, `DFAnimation`, `GlassNeon`, `KoreanUX` | ✅ 완성 |

### 2.2 v1 (초안) 대비 v2 변경 사항 (audit 반영)

| 항목 | v1 (초안) | v2 (본 PRD) | 근거 |
|---|---|---|---|
| 모션 액션 버튼 | 4개 | **7개 + "+더 보기" 시트** | 공식 가용 페이지 활용 |
| 모션 라벨 | "서기 (Stand)" | "기본 자세 (init)" + sidecar `display_name` | 공식 sidecar 채택 |
| Ball-Follow | image centroid → walk | **head PID 추적 → head 각도 → walk** | 공식 BallFollower 패턴 |
| 차기 | 항상 page 12 | **head pan 부호로 page 12/13 자동 선택** | 공식 BallFollower 패턴 |
| 낙상 처리 | Stop 만 | **page 10/11 자동 복구** | 공식 StatusCheck.cpp |
| 보행 anchor | 없음 | **ARM 후 walkready (page 9) 자동 호출** | 공식 SoccerMode 시작 anchor |
| HSV 튜닝 | 하드코드 | **사용자 슬라이더 + preset 4종** | 공식 color_finder.ini 패턴 |
| Sprint 일정 | 5일 | **7일** | 추가 작업 정산 |

---

## 3. 목표 & 비목표

### 3.1 v2 목표

| # | 목표 | 측정 기준 |
|---|---|---|
| **G1** | 게임 조종기 경험 | 처음 사용자가 3 초 안에 D-pad 발견 + 클릭 |
| **G2** | 공식 데모 페이지 충실 재생 | 페이지 1/4/9/10/11/12/13/15/24/27/38/54 12 페이지 송출 (모두 `motion_4096.bin` byte-identical) |
| **G3** | 공식 BallFollower 충실 재현 | head pan/tilt PID + 각도 기반 walk + 좌/우 차기 자동 |
| **G4** | 자동 낙상 복구 | pitch > 50° 시 page 10 또는 11 자동 호출 |
| **G5** | 4-layer 안전 게이트 | ARM / 등급 confirm / dead-man 1s / IMU·duration |
| **G6** | 애니메이션 품질 | 모든 전환에 `DFAnimation` spring |
| **G7** | 시뮬 미리보기 | `Bus == nil` 에서도 화면 동작 (head/walk sim) |
| **G8** | mp3 동기 표시 | 각 액션 버튼 tooltip 에 공식 mp3 파일명 표시 |

### 3.2 v2 비목표 (out-of-scope)

- USB 게임패드 (GameController.framework)
- MJPEG streaming (snapshot 폴링만)
- Goal/field 인식 (ball 만)
- 음성 명령 (Conversation ⌘5)
- 다중 로봇 동시 조종
- 좌/우 패스 (page 70/71) v1 — v1.1 후보
- 페이지 chain 자동 재생 (page 24→25, 38→39, 41..47) — v1.1 후보

---

## 4. 화면 아키텍처

`RemotePilotView` 세 영역:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ toolbar: ⬤ Connected V11.7 T38° ARM🔒→🔓 MODE 🕹/🎯 │ ⌘K E-STOP🔴            │
├───────────────────────────────────┬──────────────────────────────────────────────┤
│ LEFT PANEL (360 px, fixed)        │ RIGHT PANEL (fill)                           │
│                                   │ ┌──────────────────────────────────┐         │
│ 1. ARM 슬라이더 (밀어서 잠금 해제)│ │ A. CAMERA + AR HUD               │         │
│                                   │ │   - blob 십자선 (centroid)        │         │
│ 2. MODE 토글 (Manual / Ball-Follow)│ │   - head 십자선 (현재 head 시선)  │         │
│                                   │ │   - 상태 배지 + FSM dots          │         │
│ 3. SPEED GAUGE (3색 arc)          │ │   - HSV 튜닝 슬라이더 (접힘)      │         │
│                                   │ └──────────────────────────────────┘         │
│ 4. D-PAD (7존 + Hold Ring)        │ ┌──────────────────────────────────┐         │
│                                   │ │ B. 3D 로봇 뷰 + foot trail        │         │
│ 5. ACTION BAR 7 버튼 + "+ 더 보기"│ │    (head 회전도 sim)              │         │
│                                   │ └──────────────────────────────────┘         │
│                                   │ ┌──────────────────────────────────┐         │
│                                   │ │ C. HUD STRIP (계기판)            │         │
│                                   │ │    배터리·온도·IMU 수평선·세션   │         │
│                                   │ │    + "🔁 자동복구" 토글           │         │
│                                   │ └──────────────────────────────────┘         │
└───────────────────────────────────┴──────────────────────────────────────────────┘
```

---

## 5. 공식 데모 모션 — Action Bar 매핑 (v2 핵심)

### 5.1 v2 의 정확한 페이지 매핑 (sidecar `display_name` + mp3 + safety)

**모든 페이지 데이터는 `motion_4096.bin` byte-identical. 우리는 호출만 한다.**

| Order | slot | 공식 raw_name | UI 라벨 (sidecar `display_name`) | safety | mp3 동기 | duration | confirm? | 키 |
|---:|---:|---|---|---|---|---:|---|---|
| 1 | **1** | `init` | 기본 자세 (Stand Up) | Safe | `Stand up.mp3` | 2.0 s | × | 1 |
| 2 | **4** | `hi` | 감사 인사 (Thank You) | Safe | `Thank you.mp3` | 3.6 s | × | 2 |
| 3 | **15** | `sit down` | 앉기 (Sit Down) | Safe | `Sit down.mp3` | 1.0 s | × | 3 |
| 4 | **12** | `rk` | 오른발 차기 (Right Kick) | **HighRisk** | `Right kick.mp3` | 1.7 s | ✓ | 4 |
| 5 | **13** | `lk` | 왼발 차기 (Left Kick) | **HighRisk** | `Left kick.mp3` | 1.7 s | ✓ | 5 |
| 6 | **9** | `walkready` | 보행 자세 (Walk Ready) | Safe | (none) | 1.0 s | × | 6 |
| 7 | **23** | `d1` | 출발! (Yes Go) | Safe | `Yes go.mp3` | 3.0 s | × | 7 |

**"+ 더 보기" 시트 (Action Bar 우측 ⋯ 버튼 → 모달):**

| slot | raw_name | UI 라벨 | safety | mp3 | duration | 용도 |
|---:|---|---|---|---|---:|---|
| **2** | `ok` | 끄덕임 (Yes) | Safe | `Yes.mp3` | 2.6 s | 긍정 응답 |
| **3** | `no` | 가로젓기 (No) | Safe | `No.mp3` | 2.6 s | 부정 응답 |
| **10** | `f up` | 앞 일어서기 (Get Up Front) | Caution | (none) | 3.2 s | 수동 복구 |
| **11** | `b up` | 뒤 일어서기 (Get Up Back) | Caution | (none) | 4.2 s | 수동 복구 |
| **16** | `stand up` | 일어서기 (Stand Up exact) | Safe | (none) | 1.0 s | 단일 step stand |
| **24** | `d2` | 감탄 (Wow) | Safe | `Wow.mp3` | 3.6 s | VisionMode BLUE 페이지 |
| **27** | `d3` | 실수 (Oops) | Safe | (none) | 3.2 s | VisionMode RGB |
| **38** | `d2` | 손 흔들기 (Bye Bye) | Safe | (none) | 3.6 s | VisionMode RED+YELLOW |
| **54** | `int` | 박수 요청 (Clap Please) | Safe | (none) | 2.0 s | VisionMode RED+BLUE |

> **모든 라벨은 `docs/motion-format/page-metadata-motion4096.toml` 의 `display_name` 필드 그대로.** UI 코드는 toml 을 빌드 타임에 Swift struct 로 generate (또는 런타임 파싱).

### 5.2 Action Bar 버튼 UX

7 버튼 가로 스크롤 (또는 두 줄 4+3). 각 버튼:

```
┌─────────────────────────┐
│ 🦶  오른발 차기          │   ← 한국어 display_name
│ ━━━━━━━━━━━━━━━░░░       │   ← 진행 링 (재생 중)
│ rk · 1.7s · ⚠️           │   ← raw_name · duration · HighRisk 마크
└─────────────────────────┘
```

- **idle**: `DFColor.forge.opacity(0.12)` 배경. Safe = forge / Caution = warning / HighRisk = danger 외곽.
- **playing**: 진행 링 (stroke 3pt) + 내부 dim + 모든 D-pad/모드토글 disable.
- **cooldown**: 0.8 s 체크 아이콘 → fade.
- **HighRisk** (page 12/13): 외곽 `DFColor.danger` + ⚠ 아이콘 → 클릭 시 Alert "오른발 차기를 진행할까요? cradle 거치 + 주변 빈 공간 확인".
- **tooltip (hover 500ms)**:
  ```
  raw_name: rk
  mp3 sync: Right kick.mp3
  duration: 1.7 s (7 step × pause+time)
  safety: HighRisk
  source: motion_4096.bin page 12
  ```

### 5.3 페이지 재생 정확성 보장

- `forge motion play --slot N` 호출. `--engage` flag 로 실 모터 송출.
- 내부적으로:
  1. `precheck_motion(slot, confirm_risk)` — 안전 클래스 확인
  2. `TorqueRamper` gentle (P-gain 0→8→16→32) — 모터 보호
  3. step 별 timing 정확 (`pause + time` × 8 ms)
  4. `INVALID_BIT_MASK` (0x4000) / `TORQUE_OFF_BIT_MASK` (0x2000) 비트 그대로 처리
- **page chain 자동 재생** (next != 0): page 24→25, 38→39 등. v1 에서는 첫 페이지만 재생. v1.1 에서 chain 지원.

---

## 6. Ball-Follow — 공식 BallFollower 알고리즘 충실 재현 (v2 핵심)

### 6.1 공식 BallFollower 알고리즘 (DARwIn-OP `Linux/project/soccer/`)

```
매 frame (~30 ms):
  1. ColorFinder::FindColor(image, profile) → ball_x, ball_y (pixel)
  2. Head::MoveTracking(ball_x, ball_y) — PID 로 머리가 공을 추적
  3. pan_angle, tilt_angle = Head::GetAngle()
  4. walk command (head 각도 기반):
     a_move_amplitude = K_a * pan_angle
     x_move_amplitude = K_x * (KICK_TILT_THRESHOLD - tilt_angle).max(0)
  5. kick 결정:
     if |pan_angle| < KICK_PAN_DEADZONE
        AND tilt_angle > KICK_TILT_THRESHOLD
        AND ball_size > MIN_KICK_SIZE:
          Walking::Stop()
          Action::Play(pan_angle > 0 ? 12 : 13)   // 좌/우 자동
```

### 6.2 우리 구현 — 4 stage closed loop

```
loop (period = 100 ms):

  [Stage 1] Frame fetch
     MjpegSnapshot.fetch(host) → Frame (RGB)

  [Stage 2] Blob detect
     detect_blob(frame, config.hsv) → BlobResult { pixel_count, centroid_x, centroid_y }
     if !blob.found(): state = LookingForBall; head_scan(); continue

  [Stage 3] Head tracking (HeadTracker PID)
     err_x = (centroid_x - frame.w/2) / (frame.w/2)   // [-1, +1]
     err_y = (centroid_y - frame.h/2) / (frame.h/2)
     pan_delta_deg  = pan_pid.update(err_x, dt)       // negative err_x → 좌로 head 회전
     tilt_delta_deg = tilt_pid.update(err_y, dt)
     joint.set(HeadPan,  current_pan  + pan_delta_deg)
     joint.set(HeadTilt, current_tilt + tilt_delta_deg)
     read back current head angles

  [Stage 4] Walk + Kick decision (공식 패턴)
     pan  = head_pan_deg     // joint 19 현재 각도
     tilt = head_tilt_deg    // joint 20 현재 각도

     if |pan| < 5° AND tilt > 30° AND pixel_count > 1000:
         state = Kicking
         walk = Stop
         if autoKick: Action::Play(pan > 0 ? 12 : 13)
                       // else: 사용자에게 "차기 준비됨 - 클릭" prompt
     else:
         state = ApproachingBall
         a_amp = -0.10 * (pan / 90.0)              // 머리 우측 → body 우회전
         x_amp = 0.025 * ((30.0 - tilt) / 30.0).max(0.0)   // tilt 0° = max forward, 30°+ = 0
         walk = WalkCommand { x_amp, y_amp: 0, a_amp, enabled: true }
         TeleopChannel.send(walk)
```

### 6.3 LookingForBall — 능동 scan

공이 안 보일 때:
- **head scan**: 좌→우→좌 sweep (pan ±45°, 1Hz)
- 동시에 body 도 천천히 좌회전 (a_amp = 0.10, x = 0) — head 가 cover 못 한 영역 보강
- 5 s 동안 미발견 → LOST 상태로 전환 + 자동 stop

### 6.4 LOST 처리

- LOST 5s 초과 → 화면 dim + "공을 찾을 수 없어요" 모달 + "수동 모드로 전환할까요?" 옵션

### 6.5 v1 안전 토글

| 토글 | 기본 | 효과 |
|---|---|---|
| **Auto-Walk** | ON | Stage 4 의 walk command 자동 송출 |
| **Auto-Kick** | OFF (HighRisk confirm 필수) | Kicking 상태 진입 시 자동 page 12/13. OFF 면 화면에 "차기 준비됨 - 클릭" 큰 버튼 |
| **Auto-Recovery** | ON | 낙상 시 page 10/11 자동 — §7 |

---

## 7. 낙상 자동 복구 — 공식 StatusCheck.cpp 패턴

### 7.1 공식 패턴

```cpp
// Linux/project/demo/StatusCheck.cpp:35-37
if (gyroFB < -fallThreshold) Action::GetInstance()->Start(10);   // f up
if (gyroFB > +fallThreshold) Action::GetInstance()->Start(11);   // b up
```

### 7.2 우리 게이트 분기 (PRD §8 갱신)

```
L4a (IMU watchdog 갱신):

  case |imu.pitch| > 50° AND Auto-Recovery 토글 ON:
    Walking::Stop()
    if pitch > 0:   Action::Play(10)   // 앞 낙상 → "앞 일어서기"
    else:           Action::Play(11)   // 뒤 낙상 → "뒤 일어서기"
    Show toast "낙상 감지 — 자동 복구 시작"

  case |imu.pitch| > 50° AND Auto-Recovery 토글 OFF:
    Walking::Stop()
    Show modal: "낙상 감지 — 어느 방향?"
       [⬆ 앞 일어서기 (page 10)]
       [⬇ 뒤 일어서기 (page 11)]
       [닫기]

  case 25° < |imu.roll| OR 30° < |imu.pitch| ≤ 50°:
    Walking::Stop()
    Show toast "기울어짐 감지 — 정지"
```

### 7.3 Auto-Recovery 토글 UI

HUD Strip 우측에 작은 토글:

```
[ 🔁 자동복구 ●ON ]
```

ON 기본. 비활성화 시 "수동 확인 필요 — 낙상 시 모달 표시" tooltip.

---

## 8. ARM → walkready 자동 호출 (공식 anchor 충실)

### 8.1 공식 패턴

ROBOTIS SoccerMode 시작 시 `Action::Play(9)` (walkready) 호출 후 walking 시작.

### 8.2 우리 ARM 시퀀스

ARM 슬라이더 완료 직후 (Bus 연결됨 + cradle/clearance 확인):

```
ARM 완료
  ↓
[1] Toast: "보행 자세로 전환 중…"
[2] forge motion play --slot 9 --engage   // page 9 walkready
[3] 1초 대기 (duration_ms 까지)
[4] Toast: "준비 완료" (success)
[5] D-pad + Action Bar 활성화
```

ARM OFF (disarm) 시: 마지막 명령이 Walking 이면 `Stop` 송출. 별도 page 호출 없음 (사용자가 명시적으로 sit down 누르도록).

---

## 9. HSV 튜닝 UI (v2 추가)

### 9.1 카메라 view 우하단 floating panel

```
[ 🟠 공 색상 ▾ ]
   ├─ 주황 (RoboCup 표준)  ← 기본
   ├─ 빨강
   ├─ 노랑 (RoboCup 골)
   ├─ 파랑
   └─ 사용자 정의...
       h_min ━━●━━━━━━━━━━━━ 0°
       h_max ━━━━━━●━━━━━━━ 30°
       s_min ━━━━━━━━━━●━━━ 0.50
       v_min ━━━━━━━━━●━━━━ 0.40

   [실시간 미리보기: blob 매칭 표시]
```

### 9.2 데이터 모델

`BallFollowConfig.hsv: HsvRange` 를 `@Published` 로 노출. 사용자 변경 시 즉시 다음 frame 부터 반영.

색 preset 4종 (`HsvRange::ROBOCUP_BALL` 외):
- `RED_CARD` (h: 350~10 wrap, s 0.5, v 0.4)
- `ROBOCUP_GOAL_YELLOW` (h: 40~70, s 0.4, v 0.4) — 기존
- `BLUE_CARD` (h: 200~240, s 0.5, v 0.4)

사용자 정의는 UserDefaults 저장 (`PilotHsvUserProfile`).

---

## 10. 디자인 시스템 — Pilot 전용 토큰

기존 `DFColor` / `DFNeon` / `DFAnimation` 사용 + `PilotTokens.swift` 신규.

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
    // v2 신규
    static let safetySafe     = DFColor.success
    static let safetyCaution  = DFColor.warning
    static let safetyHighRisk = DFColor.danger
    static let headReticle    = DFColor.info       // head 시선 십자선 (blob 십자선과 구분)
    static let ballReticle    = DFColor.forge
}

enum PilotAnim {
    static let dpadPress = Animation.spring(response: 0.12, dampingFraction: 0.7)
    static let stateChange = Animation.spring(response: 0.35, dampingFraction: 0.75)
    static let gauge = Animation.easeOut(duration: 0.22)
    static let motionProgress = Animation.linear
    static let modeSwitch = Animation.easeInOut(duration: 0.30)
    static let lockPop = Animation.spring(response: 0.25, dampingFraction: 0.5)
    static let blobTrack = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.85)
    static let headTrack = Animation.interactiveSpring(response: 0.2, dampingFraction: 0.85)  // v2
    static let fallRecovery = Animation.easeInOut(duration: 0.4)  // v2
}
```

---

## 11. 컴포넌트 상세 — v2 변경 부분만

(D-pad, Speed Gauge, Phase Bar, HUD Strip 의 설계는 v1 그대로 — 본 PRD v1 §5.3 ~ §5.8 참조.)

### 11.1 PilotArmSlider — v2 흐름

ARM 완료 → spring bounce → **자동 walkready 호출** → 토스트 → D-pad fade in.

### 11.2 PilotActionBar — v2 7 버튼 + "+더 보기"

기본 7 버튼은 §5.1 표 순서. 우측에 ⋯ 버튼 → 모달 시트에 9 추가 페이지. 각 버튼은 sidecar 데이터 그대로 표시.

### 11.3 PilotCameraView — v2 head 십자선 추가

```
┌─ MJPEG frame ────────────────────────────┐
│                                          │
│      ╋ (head 시선 십자선, DFColor.info)  │
│      :                                   │
│      :  ╋ (blob 십자선, DFColor.forge)  │
│      :                                   │
│  [LOOKING / APPROACHING / LOCKED ON]    │
│                                          │
│  HSV 튜닝 panel (접힘/펼침 토글)         │
└──────────────────────────────────────────┘
```

- **head 십자선**: 현재 joint 19/20 각도 → 카메라 frame 의 가상 시선 위치. PilotAnim.headTrack 으로 부드럽게 이동.
- **blob 십자선**: detect_blob centroid. PilotAnim.blobTrack 으로 이동.
- 두 십자선 사이의 거리 = head PID 의 추적 오차. 시각화로 사용자가 PID 튜닝 직관 가능.
- LOCKED ON 시 두 십자선이 합쳐짐 + 외곽 ring pulse.

### 11.4 PilotHudStrip — v2 자동복구 토글 추가

기존 HUD strip 우측 (E-Stop 옆) 에 작은 토글 추가:

```
[ 🔁 자동복구 ●ON ]
```

- ON 기본. 토글 OFF 시 모달 안내: "낙상 시 수동 복구 필요. 정말 끄시겠어요?"

### 11.5 PilotHeadView (신규 컴포넌트)

3D 뷰의 head 부분을 강조하는 mini 시각화 (선택적):
- joint 19 (HeadPan) + 20 (HeadTilt) 각도 표시
- 그림으로 머리 회전 방향 화살표
- 카메라 view 우상단 mini-overlay 또는 별도 패널 (사용자 선택)

---

## 12. 아키텍처 — v2 신규 컴포넌트

### 12.1 forge-core::teleop (Rust) v2

```
forge-core/src/teleop/
├── mod.rs
├── command.rs              # TeleopCommand (v1 그대로)
├── gate.rs                 # SafetyGate + GateReason (v1 + 낙상 복구 분기 추가)
├── ballfollow.rs           # BallFollowConfig + decide() (v2 head 기반)
├── head_tracker.rs         # NEW v2 — PID head tracker
└── pid.rs                  # NEW v2 — 단순 PID 컨트롤러
```

#### 12.1.1 `HeadTracker` (신규)

```rust
pub struct HeadTracker {
    pub pan_pid:  PidController,       // Kp=0.4, Ki=0.0, Kd=0.05 (튜닝 가능)
    pub tilt_pid: PidController,
    pub pan_limits_deg:  (f32, f32),   // (-90.0, 90.0)
    pub tilt_limits_deg: (f32, f32),   // (-45.0, 45.0)
    pub frame_size: (u32, u32),         // (320, 240) default
}

pub struct HeadDelta {
    pub pan_delta_deg:  f32,
    pub tilt_delta_deg: f32,
}

impl HeadTracker {
    pub fn update(&mut self, blob: BlobResult, dt_secs: f32) -> HeadDelta { … }
    pub fn scan(&self, t_secs: f32) -> HeadDelta { … }  // looking-for-ball sweep
}
```

#### 12.1.2 `BallFollowConfig::decide` (v2 재작성)

```rust
pub struct BallFollowConfig {
    pub hsv: HsvRange,                  // 동적 변경 가능
    pub kick_tilt_threshold_deg: f32,   // 30.0
    pub kick_pan_deadzone_deg: f32,     // 5.0
    pub min_kick_pixel_count: u32,      // 1000
    pub forward_amp: f64,               // 0.025
    pub turn_amp_gain: f64,             // 0.10 / 90° = 0.00111 per deg
    pub auto_kick: bool,                // false (HighRisk)
}

pub struct BallFollowDecision {
    pub state: StrategyState,
    pub walk_cmd: TeleopCommand,        // Walk(...) or Stop
    pub head_delta: HeadDelta,          // 매 frame head 적용
    pub kick_slot: Option<u8>,          // Some(12) or Some(13) when ready
    pub blob: BlobResult,
}

impl BallFollowConfig {
    pub fn decide(
        &self,
        frame: &Frame,
        head_pan_deg: f32,
        head_tilt_deg: f32,
        head_tracker: &mut HeadTracker,
        prev_state: StrategyState,
    ) -> BallFollowDecision { … }
}
```

#### 12.1.3 `SafetyGate` (v2 낙상 복구 추가)

```rust
pub enum GateReason {
    NotArmed,
    RiskNotConfirmed,
    DeadmanTimeout,
    ImuTilted { roll: f32, pitch: f32 },            // 25° < ... < 50° (정지만)
    ImuFallen { pitch: f32, direction: FallDir },   // > 50° (자동 복구 권장)
    SessionExpired { max_secs: u32 },
}

pub enum FallDir { Forward, Backward }

impl SafetyGate {
    pub fn fall_recovery_page(&self, dir: FallDir) -> u8 {
        match dir { FallDir::Forward => 10, FallDir::Backward => 11 }
    }
}
```

### 12.2 Swift v2 컴포넌트 (v1 + 4개 신규)

| 파일 | 책임 | v1/v2 |
|---|---|:---:|
| `PilotTokens.swift` | PilotColor + PilotAnim (v2 토큰 추가) | v1+v2 |
| `TeleopChannel.swift` | 단일 진입점 actor | v1 |
| `PilotSafetyGate.swift` | armed, IMU, session, **낙상 분기** | v1+v2 |
| `BallFollowEngine.swift` | snapshot → blob → **head update** → walk decide | **v2 재작성** |
| `MjpegSnapshot.swift` | 100ms JPEG 폴링 | v1 |
| `HeadJointController.swift` | **NEW v2** — joint 19/20 SYNC_WRITE 헬퍼 | v2 |
| `MotionCatalog.swift` | **NEW v2** — `page-metadata-motion4096.toml` 파싱 → Swift struct | v2 |
| `FallRecoveryCoordinator.swift` | **NEW v2** — IMU pitch > 50° → page 10/11 자동 | v2 |
| `HsvTuningPanel.swift` | **NEW v2** — h/s/v 슬라이더 + preset 4종 | v2 |
| `RemotePilotView.swift` | 최상위 | v1 |
| `PilotArmSlider.swift` | 슬라이더 + **walkready 자동 호출** | v1+v2 |
| `PilotModePicker.swift` | 세그먼트 피커 | v1 |
| `PilotDpad.swift` | 7존 + Hold Ring | v1 |
| `PilotSpeedGauge.swift` | Arc + Phase | v1 |
| `PilotActionBar.swift` | **v2 7버튼 + 더보기 시트** | v1+v2 |
| `PilotCameraView.swift` | **v2 head 십자선 + HSV 패널 + LOCKED 합쳐짐** | v1+v2 |
| `TargetReticle.swift` | 4 L 코너 + 중앙 점 | v1 |
| `PilotHudStrip.swift` | **v2 자동복구 토글 추가** | v1+v2 |

### 12.3 MotionCatalog (신규) — sidecar toml 의 Swift 사용

```swift
public struct MotionPageMetadata: Sendable, Codable {
    public let slot: UInt8
    public let rawName: String           // "rk"
    public let displayName: String       // "Right Kick"
    public let displayNameKo: String     // "오른발 차기" (PRD §5.1 매핑)
    public let safetyClass: SafetyClass
    public let durationMs: UInt32
    public let mp3Sync: String?          // "Right kick.mp3"
    public let bodyRegions: [BodyRegion]
}

public enum MotionCatalog {
    /// `motion-format/page-metadata-motion4096.toml` 파싱 결과.
    /// Sprint 15 Day 1 에 build-script 로 generate (TOMLDecoder 또는 hardcode).
    public static let all: [MotionPageMetadata] = …

    public static func find(slot: UInt8) -> MotionPageMetadata? { … }
    public static let actionBarMain: [UInt8] = [1, 4, 15, 12, 13, 9, 23]
    public static let actionBarMore: [UInt8] = [2, 3, 10, 11, 16, 24, 27, 38, 54]
}
```

### 12.4 TeleopChannel v2 — Motion 분기에 mp3 동기 옵션

```swift
case .Motion(let slot, let confirm):
    let meta = MotionCatalog.find(slot: slot)
    guard !confirm || gate.confirmRisk else { throw GateError.riskNotConfirmed }
    try await store.playMotionSlot(slot)
    if let mp3 = meta?.mp3Sync, audioEnabled {
        AudioPlayer.shared.play(mp3)   // v1.1 후보 — v1 은 옵션 OFF
    }
```

> **v1 은 mp3 재생 비활성**. UI 에 라벨만 표시 (시각 보조). v1.1 에서 robot 측 또는 Mac 측 sync 결정.

### 12.5 FallRecoveryCoordinator (신규)

```swift
@MainActor
public final class FallRecoveryCoordinator: ObservableObject {
    @Published public var autoRecovery: Bool = true
    @Published public var lastRecoveryAt: Date?

    private let channel: TeleopChannel
    private let store: ConnectionStore

    public func observeImu() async {
        // ConnectionStore.$lastImuPitch 구독
        // |pitch| > 50° + autoRecovery==true → triggerRecovery(direction)
    }

    public func triggerRecovery(_ dir: FallDir) async {
        try? await channel.send(.Stop)
        let slot: UInt8 = (dir == .forward) ? 10 : 11
        try? await channel.send(.Motion(slot: slot, confirmRisk: true))
        // confirmRisk: true 자동 — 낙상은 즉시 복구 필요
        lastRecoveryAt = Date()
    }
}
```

### 12.6 HeadJointController (신규)

```swift
public final class HeadJointController {
    private weak var bus: Bus?

    /// SYNC_WRITE — joint 19 (HeadPan), 20 (HeadTilt) 동시.
    public func write(pan deg: Float, tilt deg: Float) throws { … }

    /// 현재 각도 read.
    public func read() throws -> (panDeg: Float, tiltDeg: Float) { … }

    /// 안전 범위 clamp: pan ±90°, tilt ±45°.
    public static func clamp(pan: Float, tilt: Float) -> (Float, Float) { … }
}
```

---

## 13. 안전 게이트 v2 — 결정 트리 (낙상 복구 포함)

```
사용자 입력 / Ball-Follow 결정
        │
  [L0] ⌘⇧. 어디서나 → emergencyStop() 즉시. 화면 전체 빨간 flash 0.3s.
        │
  [L1] gate.armed == false
        → 명령 무시. ARM 슬라이더 wiggle.
        │
  [L2] cmd.safety == .highRisk && !confirmRisk
        → Alert: "위험 동작 확인" → 확인 시 재시도.
        │
  [L3] now - lastInputAt > 1s (deadman, Walk 명령 only)
        → Walk(enabled: false) 자동. Hold Ring 빨간 flash.
        │
  [L4a] |imu.pitch| > 50° (확실히 쓰러짐):
        if autoRecovery:
           → Walking::Stop + Action::Play(pitch>0 ? 10 : 11)
           → 토스트 "낙상 감지 — 자동 복구 시작"
        else:
           → Walking::Stop + 모달 "낙상 감지 — 어느 방향?"
        │
  [L4b] 25° < |imu.roll| OR 30° < |imu.pitch| ≤ 50° (위험 기울임):
        → Walking::Stop + 토스트 "기울어짐 감지 — 정지"
        │
  [L4c] sessionElapsed > preset.max_duration_secs:
        → Stop + 타이머 종료 토스트.
        │
  → Bus.send(cmd)   캐덴스: USB 100ms / 네트워크 200ms
```

---

## 14. 화면 상태 머신 v2

```
            onAppear
                │
                ▼
        ┌───────────────┐
        │  SIM_READY    │  Bus == nil. 시뮬 모드.
        └───────┬───────┘
                │ Bus 연결
                ▼
        ┌───────────────┐
        │  UNARMED      │  ARM 슬라이더 대기.
        └───────┬───────┘
                │ ARM 슬라이더 완료
                ▼
        ┌───────────────────────┐
        │  ARMING (walkready)   │  page 9 자동 호출 중 (~1s).
        └───────────┬───────────┘
                    │ Motion::Done
                    ▼
        ┌───────────────────────┐
        │  READY (Manual)       │◄────────────────────────────────┐
        └──┬────────────────────┘                                 │
           │ D-pad 눌림           Action 완료 / Recovery 완료    │
           ▼                                          ▲           │
    ┌────────────────┐   Action 버튼     ┌────────────┴────────┐ │
    │ WALKING        │◄─────────────────►│  MOTION_PLAYING     │ │
    └──┬─────────────┘                   └─────────────────────┘ │
       │ dead-man              IMU pitch > 50°                    │
       ▼                              │                           │
    ┌────────────────┐                ▼                           │
    │ STOPPING       │       ┌────────────────────┐               │
    └────────────────┘       │ FALL_RECOVERY      │               │
                             │ (page 10 또는 11)  │               │
                             └────────┬───────────┘               │
                                      │ Motion::Done              │
                                      └───────────────────────────┘

[Ball-Follow 모드 — 별도 평행 상태 머신]
READY → BALL_FOLLOWING (head 추적 + walk 자동)
       ↕ blob detect 루프
       LOOKING / APPROACHING / LOCKED_ON / KICKING(수동) / LOST
LOST 5s → READY + 모달
KICKING (auto_kick ON 한정) → MOTION_PLAYING(page 12 or 13) → BALL_FOLLOWING
```

---

## 15. 테스트 전략 v2

### 15.1 Rust forge-core::teleop (목표 36+)

| 파일 | 테스트 | 기준 |
|---|---|---|
| `command.rs` | 6 | TeleopCommand JSON / safety 매핑 |
| `gate.rs` | **14** (v1 10 + 4 신규) | L1~L4c 차단 + 통과 + **낙상 분기 2종 (forward/backward)** |
| `ballfollow.rs` | **10** (v1 8 + 2 신규) | head 기반 walk 결정 + 좌/우 kick 자동 선택 |
| `head_tracker.rs` | **6** (신규) | PID 수렴 / clamp / scan sweep |
| `pid.rs` | **4** (신규) | Kp/Ki/Kd 단위 테스트 |

### 15.2 Swift (목표 24+)

| 컴포넌트 | 테스트 |
|---|---|
| `TeleopChannel` | dead-man / gate fail / motion play |
| `PilotSafetyGate` | arm/disarm / IMU thresholds / **fall direction** |
| `BallFollowEngine` | head loop / state transitions / auto-kick |
| `HeadJointController` | SYNC_WRITE 시뮬 / clamp |
| `MotionCatalog` | 16 페이지 sidecar 파싱 정확 + `actionBarMain` 7 + `actionBarMore` 9 = 16 |
| `FallRecoveryCoordinator` | pitch > 50° → page 10/11 / autoRecovery OFF → 모달 |
| `HsvTuningPanel` | 슬라이더 변경 → BallFollowConfig.hsv 갱신 |
| `PilotArmSlider` | drag 완료 → walkready 호출 |

### 15.3 Hardware-in-the-loop (실기기 6 시나리오)

| # | 시나리오 | 통과 기준 |
|---:|---|---|
| 1 | ARM → walkready 자동 → D-pad 전진 1s → release | walkready 진입 확인 + 1s 내 정지 |
| 2 | 공 1m 배치 → Ball-Follow ON | head 가 먼저 추적, 5 사이클 내 body 방향 전환 |
| 3 | 공이 우측에 → LOCKED ON | head pan > 5° 시 page 13 (Left Kick) 자동 (auto_kick ON) |
| 4 | cradle 비틀어 pitch 60° | page 10 (또는 11) 자동 호출 |
| 5 | 네트워크 끊김 4s | dead-man + watchdog → .error |
| 6 | Action Bar "감사 인사" (page 4) | duration 3.6s 동안 진행링 + raw_name "hi" tooltip 표시 |

---

## 16. Sprint 15 구현 단계 (v2 — 7일)

| Day | 작업 | 완료 기준 |
|---|---|---|
| **1** | Rust: `teleop/pid.rs` + `head_tracker.rs` + `command.rs` + `gate.rs` (낙상 분기) + ffi | cargo test 30+ pass |
| **2** | Rust: `ballfollow.rs` (v2 head 기반) + 통합 테스트 | cargo test 36+ pass |
| **3** | Swift: `MotionCatalog` (sidecar 파싱) + `HeadJointController` + `TeleopChannel` + `PilotSafetyGate` + `BallFollowEngine` (v2) + `FallRecoveryCoordinator` | swift test 24+ pass |
| **4** | Swift UI: `PilotArmSlider` (walkready 호출) + `PilotModePicker` + `PilotDpad` + `PilotSpeedGauge` | swift build ✓ |
| **5** | Swift UI: `PilotActionBar` (7 + 더보기 시트) + `MotionCatalog` 표시 + tooltip | 7 페이지 송출 확인 |
| **6** | Swift UI: `PilotCameraView` (v2 head 십자선) + `HsvTuningPanel` + `TargetReticle` + `MjpegSnapshot` + Ball-Follow E2E | Ball-Follow HUD + head 추적 |
| **7** | `PilotHudStrip` (자동복구 토글) + `RemotePilotView` 통합 + RootView ⌘8 + 6 HIL 시나리오 검증 + 문서 | E2E 6 시나리오 통과 |

---

## 17. 미해결 사항 (Open Questions)

| OQ | 내용 | 결정 시점 |
|---|---|---|
| **OQ-1** | BLOCKER C3 해결 후 슬라이더 풀-스윙 허용 범위 | Sprint 14 walk-lab 후 |
| **OQ-2** | MJPEG snapshot → streaming 전환 | Day 6 measure 후 |
| **OQ-3** | HSV 범위 조명 robustness — v2 의 튜닝 UI 로 부분 완화 | Day 6 실측 후 |
| **OQ-4** | USB 게임패드 v2 지원 | v2 PRD |
| **OQ-5** | 두 Mac 동시 연결 TCP 거버넌스 | Sprint 15 후 |
| **OQ-6** | IMU roll/pitch ConnectionStore 노출 (CM-730/740 IMU 레지스터) | Day 1 착수 전 |
| **OQ-7 (신규 v2)** | HeadTracker PID Kp/Ki/Kd 실측 튜닝 — frame size, motor speed 의존 | Day 6 HIL |
| **OQ-8 (신규 v2)** | mp3 동기 — robot 측 mp3 player 사용 or Mac 측 재생? | v1.1 |
| **OQ-9 (신규 v2)** | Page chain (24→25, 38→39) 자동 재생 | v1.1 |

---

## 18. 부록 A — 공식 코드 매핑

| 우리 모듈 | 공식 출처 |
|---|---|
| `motion_4096.bin` 파서 | `Framework/include/Action.h` line 41-59 (PAGEHEADER) |
| 모션 timing | `pause + time` × 8 ms (Action.h 명세) |
| INVALID/TORQUE_OFF mask | `0x4000` / `0x2000` (Action.h) |
| WalkCommand | `op2_walking_module::walking_param_::*_move_amplitude` |
| WalkPhase | `WalkingModule::{PHASE0..3}` |
| BallFollower 알고리즘 | `Linux/project/soccer/BallFollower.{h,cpp}` |
| 자동 낙상 복구 | `Linux/project/demo/StatusCheck.cpp:35-37` |
| Color filter | `Linux/include/ColorFinder.h` |
| Head 추적 | `Linux/include/Head.h::MoveTracking` |
| Page → mp3 매핑 | `Linux/project/tutorial/action_script/script.asc` |
| VisionMode 페이지 매핑 | `Linux/project/demo/VisionMode.cpp` |
| 16 페이지 sidecar | `docs/motion-format/page-metadata-motion4096.toml` |

## 19. 부록 B — 라이선스 & 윤리

- `motion_4096.bin` 페이지 데이터는 ROBOTIS Apache 2.0. 우리는 **읽기만**, 수정 없음.
- ROBOTIS framework Apache 2.0 — 우리 forge-core 도 Apache 2.0.
- BallFollower 알고리즘은 공개된 표준 패턴 (논문 + ROS 패키지 다수에서 재현). 우리는 **알고리즘만 모방**, 코드 직접 복사 없음.
- mp3 파일 사용 시 ROBOTIS 의 별도 라이선스 확인 필요 (`Data/mp3/` directory). v1.1 결정.

---

## 20. v2 핵심 변경 요약 — 12개 PATCH

| # | v1 | v2 | 근거 |
|---|---|---|---|
| 1 | slot 1 라벨 "서기" | "기본 자세 (Stand Up)" sidecar `display_name` | sidecar toml |
| 2 | slot 4 라벨 "인사" | "감사 인사 (Thank You)" + mp3 tooltip | sidecar + script.asc |
| 3 | Action 4 버튼 | **7 버튼 + 더보기 9 페이지 = 16** | 공식 카탈로그 16 페이지 모두 |
| 4 | Ball-Follow centroid → walk | **head PID → 각도 → walk** | BallFollower.cpp |
| 5 | 차기 항상 page 12 | **head pan 부호로 12/13 자동** | BallFollower.cpp |
| 6 | 보행 anchor 없음 | **ARM 후 walkready (page 9) 자동** | SoccerMode |
| 7 | 낙상 시 Stop 만 | **pitch > 50° → page 10/11 자동 복구** | StatusCheck.cpp |
| 8 | HSV 하드코드 | **튜닝 UI + 4 preset + UserDefaults** | color_finder.ini |
| 9 | mp3 무시 | **UI tooltip 에 mp3 파일명 표시** | script.asc |
| 10 | head 미사용 | **HeadJointController + joint 19/20 PID** | Head.h |
| 11 | 카메라 view = blob 십자선 | **+ head 시선 십자선** (PID 오차 시각화) | 신규 UX |
| 12 | Sprint 5일 | **7일** | 추가 작업 정산 |

---

*공식 ROBOTIS 데모는 완벽하다. 우리는 그것을 그대로 실행하고, 게임 조종기 품질의 UI 를 입힐 뿐이다.*
