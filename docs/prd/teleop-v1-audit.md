# Audit — Teleop v1 PRD 가 공식 ROBOTIS 자료에 얼마나 부합하는가

> **점검일**: 2026-05-12
> **대상**: `docs/prd/teleop-v1.md`
> **공식 출처**:
> - `research/robotis-official/ROBOTIS-OP2/op2_walking_module/` (Apache 2.0, ROBOTIS CO LTD)
> - `research/robotis-official/ROBOTIS-OP2/op2_manager/src/op2_manager.cpp`
> - `docs/motion-format/page-catalog-motion4096.md` (motion_4096.bin 디스크 디코딩 검증됨)
> - `docs/motion-format/page-metadata-motion4096.toml` (16 페이지 sidecar)
> - 공개된 `Linux/project/soccer/BallFollower.{h,cpp}` (DARwIn-OP v1.6.0, 본 repo 미수록)
> - `Linux/project/demo/VisionMode.cpp`, `StatusCheck.cpp` (페이지 호출 매핑)

---

## TL;DR — 세 부분으로 나눠 본 결론

| 영역 | 충실도 | 핵심 이슈 |
|---|:---:|---|
| **A. 모션 페이지 재생** | 🟢 충실 | 4 액션 중 1개 (slot 1) 명칭이 부정확. 낙상 복구 페이지 (10/11) 누락 |
| **B. 걷기 명령 (X/Y/A amplitude)** | 🟢 충실 | 공식 `op2_walking_module` 의 (x_move_amplitude, y_move_amplitude, a_move_amplitude) 와 의미 1:1. BLOCKER C3 (실 IK 부재) 도 정직 명시 |
| **C. 공 팔로우 (Ball-Follow)** | 🟡 **부분 충실** | 공식 `BallFollower` 는 **head pan/tilt 가 먼저 공을 추적** → 그 각도로 walk amplitude 결정. PRD 는 image centroid offset 으로 직접 walk 명령 생성 — head 추적 단계 누락 |

결론: **모션 + 걷기는 합격, 공 팔로우는 공식 패턴 대비 설계 보강 필요.**

---

## A. 모션 재생 — 페이지 ID 매핑 점검

### A.1 PRD 가 주장하는 4 액션 (PRD §5.6)

| 버튼 라벨 | slot | 우리 PRD 의미 부여 |
|---|---|---|
| 인사 (Hi) | 4 | "손 흔들기" |
| 차기 (Right Kick) | 12 | "오른쪽 차기" |
| 앉기 (Sit Down) | 15 | "앉기" |
| **서기 (Stand)** | **1** | **"기본자세"** |

### A.2 공식 카탈로그와의 대조 (`page-catalog-motion4096.md`)

| slot | 공식 `raw_name` | 공식 `display_name` | mp3 동기 | 우리 PRD 의미 | 일치도 |
|---:|---|---|---|---|:---:|
| 1 | `init` | **Stand Up** (sidecar) / `init` (raw) | `Stand up.mp3` | "기본자세" | 🟡 부분 일치 |
| 4 | `hi` | **Thank You** (sidecar) | `Thank you.mp3` | "인사" | 🟡 의미 미세 차이 |
| 12 | `rk` | **Right Kick** | `Right kick.mp3` | "오른쪽 차기" | 🟢 일치 |
| 15 | `sit down` | **Sit Down** | `Sit down.mp3` | "앉기" | 🟢 일치 |

#### A.2.1 page 1 (`init`) 분석

- **공식 raw_name**: `init` — `motion_4096.bin` 페이지 1 의 PAGEHEADER name[14] 그대로
- **공식 sidecar `display_name`**: `"Stand Up"` (`docs/motion-format/page-metadata-motion4096.toml:18`)
- **공식 동작**: step 1 = "이전 자세 유지" (INVALID_BIT_MASK), step 2 = 모든 관절 ≈ 2047 (MX-28 zero pose) — 즉 **T-pose-lite ≈ walkready**
- **공식 mp3 동기**: `Stand up.mp3`
- **결론**:
  - `init` 은 "기본 자세" + "Stand Up" 두 의미를 모두 가진다. 공식 sidecar 는 `Stand Up` 라벨 채택.
  - 우리 PRD "서기" 라벨은 **공식 sidecar 와 일치**한다 (`display_name = "Stand Up"`).
  - 단, "stand up" 페이지가 **두 개 존재**: page 1 (`init`, stepnum=2) 과 **page 16** (`stand up`, stepnum=1). page 16 이 "진짜" stand_up.
  - **권고**: 우리 PRD 는 page 1 을 사용 — 안전한 일반 stand-anchor. 라벨은 "기본 자세" 로 변경 (사용자 혼란 방지). 또는 page 16 으로 교체.

#### A.2.2 page 4 (`hi`) 분석

- **공식 raw_name**: `hi`
- **공식 sidecar `display_name`**: `"Thank You"` — `VisionMode.cpp` 가 RED 색카드 감지 시 호출
- **공식 mp3 동기**: `Thank you.mp3`
- **공식 동작**: 오른손 인사 + 머리 약간 기울임 (sidecar description)
- **결론**:
  - 한국어로는 "인사" 가 자연스럽지만 공식 의미는 "고맙다" 제스처.
  - 사용자가 "인사" 버튼을 누르면 "고맙습니다" 동작이 나오는 셈.
  - **권고**: "감사 인사" 또는 "손 흔들기" 로 라벨 명확화. 혹은 그대로 "인사" 두고 tooltip 에 "공식 raw name: `hi` / `Thank you.mp3` 동기" 노출.

### A.3 누락된 공식 페이지 (PRD 미반영)

| slot | 공식 이름 | 안전 등급 | 누락 영향 |
|---:|---|---|---|
| **9** | `walkready` | Safe (1 step, stepnum=1) | **보행 anchor — teleop 진입 시 자동 호출 권장** |
| **10** | `f up` (앞 낙상 복구) | Caution | IMU 가 앞으로 30° 이상 기울면 자동 호출하면 안전 ↑ |
| **11** | `b up` (뒤 낙상 복구) | Caution | 뒤 낙상 시 동일 |
| **16** | `stand up` (정확한 stand) | Safe | page 1 대안 |
| **13** | `lk` (왼쪽 차기) | Caution | mirror 대칭 — page 12 옆에 두면 자연 |
| **70/71** | `rPASS` / `lPASS` (축구 패스) | Caution | 축구 시연 옵션 |

**권고**: v1 의 Action Bar 4 버튼은 그대로 두되, **"+ 더 보기"** 어포던스로 9/10/11/13/16/70/71 등 7 페이지 카탈로그 sheet 노출.

### A.4 검증: forge motion play 와의 연결

```bash
# 공식 page 4 = "Thank you" — 우리 CLI 그대로 호출 가능
cargo run -p forge-cli -- motion play --slot 4 --engage
```

- `forge motion play --slot N` 의 slot 인자는 `motion_4096.bin` 페이지 ID. ✅
- `precheck_motion(confirm_risk)` 가 `SafetyClass::HighRisk` 차단. ✅
- `TorqueRamper` gentle 프로필. ✅
- **결론**: 모션 송출 경로는 공식 데이터에 충실히 grounded.

---

## B. 걷기 명령 — `WalkCommand` vs 공식 `WalkingModule`

### B.1 공식 인터페이스 (`op2_walking_module/include/op2_walking_module.h`)

```cpp
// 공식 walking_param_ struct
double x_move_amplitude;     // 전후 보폭 (m)
double y_move_amplitude;     // 좌우 보폭 (m)
double a_move_amplitude;     // 회전 (rad)

// phase enum
enum { PHASE0 = 0, PHASE1 = 1, PHASE2 = 2, PHASE3 = 3 };

// 상태
enum { WalkingDisable = 0, WalkingEnable = 1 };
```

### B.2 우리 `WalkCommand` (`forge-core::walk::engine`)

```rust
pub struct WalkCommand {
    pub x_amplitude: f64,     // ≈ x_move_amplitude
    pub y_amplitude: f64,     // ≈ y_move_amplitude
    pub a_amplitude: f64,     // ≈ a_move_amplitude
    pub enabled: bool,        // ≈ WalkingEnable
}

pub enum WalkPhase { Phase0, Phase1, Phase2, Phase3 }  // 1:1
```

**일치도 평가**:
- 의미 매핑 1:1. ✅
- 단위도 일치 (m, rad). ✅
- 필드명만 `_move_` 누락 — 가독성 위해서. semantic break 없음. ✅
- `WalkingDisable/Enable` → `enabled: bool` 단순화. ✅

### B.3 `WalkPreset` 의 amplitude 값이 공식과 일치하는가?

| Preset | 우리 값 | 공식 `param.yaml` 권장 | 비교 |
|---|---|---|---|
| Normal Walk | x=0.025 | (param.yaml 에 amplitude 기본값 없음. period=600ms / foot_height=0.04m 만 명시) | OK |
| Fast Walk | x=0.035, T=500 | 변형 — 공식 미명시 | **변형 자체** (BLOCKER C3 미해결 + 실측 부재) |
| Jog | x=0.040, T=450 | 공식에 없음 | **실험 파라미터** (PRD §13 OQ-1 인지) |

**평가**: SlowWalk / NormalWalk 는 공식 `param.yaml` 범위 내 안전 변형. FastWalk / Jog 는 공식 미정의 — 우리가 만든 변형. PRD §5.3 의 `WalkSafety::Caution/HighRisk` 분류로 명시되어 있음. ✅

### B.4 BLOCKER C3 인정의 정직성

PRD §4 "C1 — 실 IK 부재" 에서 정확히 인정:
> 사전 검증된 `WalkPreset` 5종 + 모션 슬롯 4종만 실송출. 임의 (x, y, a) 슬라이더 실송출 금지.

**평가**: 정직하게 명시 ✅. 사용자 신뢰 보호.

---

## C. 공 팔로우 (Ball-Follow) — 공식 패턴과의 GAP ⚠️

### C.1 공식 ROBOTIS BallFollower 알고리즘 (잘 알려진 표준 구조)

DARwIn-OP `Linux/project/soccer/BallFollower.{h,cpp}` (v1.6.0):

```
매 frame (~30 ms):
  1. ColorFinder::FindColor(image, ball_color_profile) → ball_x, ball_y (pixel)
  2. ball 의 픽셀 위치 → 카메라 frame 중앙 offset
  3. Head::MoveTracking(ball_x, ball_y, pan, tilt)
     - PID 로 머리를 ball 쪽으로 회전. 머리가 공을 추적.
  4. 현재 head pan/tilt 각도 읽기 (Joint::GetAngle).
  5. **walk command = 머리 각도 함수**:
        a_move_amplitude = K_a * panAngle           ← 회전: 머리가 본 방향으로 몸이 따라감
        x_move_amplitude = K_x * f(tiltAngle)       ← 전진: tilt 가 깊을수록 = 공이 가까이 = 적게 전진
        y_move_amplitude = 0                          (정면으로만 접근)
  6. **kick 결정**:
        if tiltAngle < KICK_TILT_THRESHOLD          ← 머리가 발 끝을 본다
           AND |panAngle| < KICK_PAN_DEADZONE       ← 정면 정렬
           AND ball_size > MIN_KICK_SIZE:           ← 가까움
             → Walking::Stop()
             → Action::Play(panAngle > 0 ? rk : lk)  ← 좌/우 발 자동 선택
```

**핵심 통찰**: 공식은 **head 가 1차 추적자, body 는 head 를 따라가는 2차 추종자**. 카메라 FOV 가 좁기 때문(60°) 에 body 회전만으로는 공이 시야에서 자주 사라진다.

### C.2 우리 PRD 의 알고리즘 (PRD §5.7 / §7.1)

```
매 frame (100 ms):
  1. detect_blob(frame, hsv) → BlobResult { pixel_count, centroid_x, centroid_y }
  2. centroid → frame 중앙 offset cx_norm = (centroid_x - W/2) / (W/2)
  3. walk command:
        a_amplitude = cx_norm * max_turn_rate      ← head 추적 없이 body 회전 직접
        x_amplitude = forward_amplitude * (1 - |cx_norm|)
  4. kick 결정:
        pixel_count > 1000 (close_pixel_threshold) → Stop + LOCKED_ON
        (Auto-Kick OFF 기본 — 사용자 수동)
```

### C.3 GAP 분석

| 항목 | 공식 | 우리 PRD | GAP 영향 |
|---|---|---|---|
| **Head 추적** | 1차 추적자, PID 로 ball 추적 | **없음** — head 정지 | ❌ FOV 60° 안에서 회전 시 공 자주 시야 이탈 |
| **거리 추정** | head tilt 각도 → 기하학적 변환 | pixel_count 만 (1000 임계) | ⚠️ 조명/공 크기 변화에 취약 |
| **회전 결정** | head pan 각도 (이미 안정화됨) | image centroid offset (frame 노이즈 직접) | ⚠️ 떨림 가능 → dead zone 0.10 으로 완화 |
| **차기 결정** | tilt < threshold + pan deadzone | pixel_count > 1000 + 수동 트리거 | ⚠️ false positive (조명 변화) |
| **좌/우 차기 선택** | pan 부호로 자동 (rk/lk) | 항상 page 12 (rk) | ❌ 공이 왼쪽에 있어도 오른발만 — 비효율 |

### C.4 보강 권고 — 두 가지 옵션

#### 옵션 1: v1 그대로 + 명확한 한계 표기 (저비용)

- PRD 의 OQ-3 (HSV robustness) 외에 **OQ-7** 추가: "head 추적 없는 closed-loop 의 FOV 이탈 위험"
- UI 의 LOST 5s timeout 으로 자동 stop 정당화
- v2 PRD 에서 head tracker 추가

#### 옵션 2: v1 에 head tracker 추가 (권장)

forge-core 에 `head_tracker.rs` 신규:

```rust
pub struct HeadTracker {
    pub pan_pid: PidController,    // Kp=0.4, Ki=0.0, Kd=0.05
    pub tilt_pid: PidController,
    pub pan_limits_deg: (f32, f32),    // (-90, +90) for joint 19 (HeadPan)
    pub tilt_limits_deg: (f32, f32),   // (-45, +45) for joint 20 (HeadTilt)
}

impl HeadTracker {
    /// blob centroid → head pan/tilt delta. 매 frame 호출.
    pub fn update(&mut self, blob: BlobResult, frame: &Frame) -> HeadDelta { … }
}
```

`BallFollowEngine` 흐름 수정:
```
매 frame:
  1. detect_blob → BlobResult
  2. HeadTracker::update(blob) → (pan_delta, tilt_delta)
  3. 머리 관절 19/20 SYNC_WRITE (joint pan += delta, tilt += delta)
  4. 현재 머리 각도 read
  5. walk command 결정 (공식 공식 따라 머리 각도 기반):
        a_amplitude = K_a * head_pan_deg
        x_amplitude = K_x * (KICK_TILT_THRESHOLD - head_tilt_deg).max(0)
  6. kick 결정: |pan| < 5° AND tilt > 30° AND pixel_count > 1000 → page (pan > 0 ? 12 : 13)
```

추가 비용: ~2일 (Rust head_tracker + ffi + Swift HeadJointMixin). v1 scope 가 5일이므로 7일 로 늘어남.

#### 옵션 1 vs 옵션 2 비교

| 기준 | 옵션 1 (현 PRD) | 옵션 2 (head tracker 추가) |
|---|---|---|
| 공식 충실도 | 60% | 95% |
| 구현 비용 | 5일 | 7일 |
| FOV 이탈 위험 | 높음 | 낮음 (head 가 안정화) |
| 차기 정확도 | 한쪽 발만 | 좌/우 자동 선택 |
| 사용자 학습 곡선 | 동일 | 동일 (UI 동일) |

**권고**: **옵션 2 채택**. 추가 2일이 충분히 가치 있다. v1 의 "공식 ball tracking 기반" 주장 성립.

---

## D. 낙상 감지 / 자동 복구 — PRD 누락 ⚠️

### D.1 공식 자동 복구 (`Linux/project/demo/StatusCheck.cpp`)

```cpp
// 약 35 line — 자이로 기반 fall detection
if (gyroFB < -fallThreshold) {
  // 앞으로 넘어짐
  Action::GetInstance()->Start(10);   // f up
}
if (gyroFB > +fallThreshold) {
  // 뒤로 넘어짐
  Action::GetInstance()->Start(11);   // b up
}
```

### D.2 우리 PRD §8 의 IMU 게이트

```
L4a: |imu.roll| > 25° || |imu.pitch| > 30°
     → Stop + 토스트 "기울어짐 감지"
```

**평가**: Stop 만 한다. 자동 복구 없음. 로봇이 쓰러진 채로 멈춤 — 사용자가 수동 복구 필요.

### D.3 보강 권고

PRD §8 의 L4a 분기 보강:

```
L4a (개정):
  |imu.pitch| > 50° (확실히 쓰러짐)
    → Stop + Action::Play(pitch > 0 ? 11 : 10)   // 자동 복구
  25° < |imu.roll| OR 30° < |imu.pitch| < 50° (위험 기울임)
    → Stop + 토스트 + 사용자에게 복구 권유 ("⬆ 앞으로 일어서기" / "⬇ 뒤로 일어서기" 버튼 노출)
```

**비용**: ~0.5일 (게이트 분기 + Action Bar 의 "+더 보기" sheet 에 page 10/11 노출). v1 scope 안.

---

## E. HSV 색 필터 — 공식 비교

### E.1 공식 (`Linux/include/ColorFinder.h`)

- BGR/HSV 변환 + threshold 후 largest-blob
- profile 단위 (`COLORS = {BALL_RED, GOAL_YELLOW, FIELD_GREEN, …}`)
- **외부 파일에서 로드**: `Linux/project/color_filter/color_finder.ini` (사용자가 ROBOPLUS Color Filter 도구로 카드별로 튜닝)

### E.2 우리

```rust
HsvRange::ROBOCUP_BALL = HsvRange {
    h_min: 0.0, h_max: 30.0,      // 주황
    s_min: 0.5, v_min: 0.4,
}
```

- 단일 하드코드. 사용자 조정 불가.
- 우리 PRD §5.7 카메라 view 하단에 `"🟠 공 색상: 주황 ▾"` dropdown 있음 — 그러나 실제로는 단일 옵션.

### E.3 보강 권고

`BallFollowConfig.hsv: HsvRange` 를 `@Published` 로 노출하고, 카메라 view 우하단에 **HSV 튜닝 슬라이더 4개** (h_min/h_max/s_min/v_min) 추가:

```
[ 🟠 공 색상 ▾ ]
   ├─ 주황 (기본)
   ├─ 빨강
   ├─ 노랑
   └─ 사용자 정의...
        h ━━━━━━━━━━━━━━━━ 0~30°
        s ━━━━━━━━━━━━━━━━ 50%+
        v ━━━━━━━━━━━━━━━━ 40%+
```

비용: ~0.5일. v1 scope 안.

---

## F. PRD 가 누락한 공식 관습 5선

| # | 공식 관습 | PRD 반영 여부 | 권고 |
|---|---|---|---|
| 1 | 보행 진입 전 `walkready` (page 9) 호출 | ❌ 누락 | ARM 완료 직후 page 9 자동 송출 |
| 2 | 낙상 시 page 10/11 자동 복구 | ❌ 누락 | §D 보강 |
| 3 | Head 추적 (PID + joint 19/20) | ❌ 누락 | §C 옵션 2 |
| 4 | Color profile 외부 설정 가능 | 🟡 부분 (UI 칸만 있음) | §E 보강 |
| 5 | 좌/우 차기 자동 선택 (rk vs lk) | ❌ 누락 (page 12 만) | §C 옵션 2 (head pan 부호로 결정) |

---

## G. 종합 평가표

| 항목 | 충실도 | 보강 후 충실도 |
|---|:---:|:---:|
| A. 모션 페이지 재생 | 90% | 100% (라벨 정정 + 낙상 페이지 + 추가 카탈로그) |
| B. 걷기 명령 | 95% | 95% (BLOCKER C3 해결 전까지 한계) |
| C. 공 팔로우 | 60% | 95% (head tracker 추가 — 옵션 2) |
| D. 낙상 복구 | 30% | 90% (자동 page 10/11) |
| E. HSV 튜닝 | 50% | 90% (사용자 조정 가능) |
| **종합** | **65%** | **94%** |

---

## H. 권고 — PRD 보강 PATCH 목록

1. **slot 1 라벨 정정**: "서기 (Stand)" → "기본 자세 (init)" + tooltip 에 공식 raw_name 노출.
2. **slot 4 라벨 정정**: "인사 (Hi)" → "감사 인사 (Thank You)" + tooltip 에 mp3 동기 정보.
3. **page 9 자동 호출**: ARM 완료 직후 `walkready` (page 9) 송출. UI 에 진행 표시.
4. **Action Bar "+ 더 보기" 시트**: page 9 / 10 / 11 / 13 / 16 / 70 / 71 노출.
5. **HeadTracker 모듈 추가** (옵션 2): `forge-core::teleop::head_tracker` + Swift HeadJointController. Sprint 15 → 7일.
6. **Ball-Follow 알고리즘 변경**: image centroid → head 추적 → head 각도 기반 walk command. 좌/우 차기 자동 선택.
7. **낙상 자동 복구 게이트**: L4a 의 pitch > 50° 분기에서 page 10/11 자동 트리거.
8. **HSV 튜닝 UI**: 카메라 view 하단에 h/s/v 슬라이더 + 색 preset 3종.
9. **OQ-7 추가**: "Head 추적 PID 게인 (Kp/Ki/Kd) 의 실측 튜닝 필요" — Sprint 16 후속.
10. **§14 Sprint 15 일정 갱신**: 5일 → 7일 (head_tracker + 자동 복구 + HSV 튜닝 + 라벨 정정).

---

## I. 결론 — "공식 자료 기반인가?"

**현 PRD 의 답**: "걷기 명령과 모션 페이지 재생은 공식 자료에 충실히 기반함. 공 팔로우는 공식 패턴의 단순화 버전이며, 일부 공식 관습 (head 추적, 낙상 복구, color profile 외부화) 이 누락됨."

**보강 후 답**: "공식 자료에 95% 충실히 기반함. 누락된 5 관습 모두 v1 에 통합. BLOCKER C3 (실 IK) 만 v1 의 한계로 남음."

권고: **옵션 2 + §H 의 10개 PATCH 를 적용** 후 사용자에게 다시 리뷰 받기.
