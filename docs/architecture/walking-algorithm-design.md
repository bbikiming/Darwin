# Walking Algorithm Design — DARwIn-OP / WalkLab 구현 명세

> **목적**: 본 문서는 WalkLab의 걷기 모션을 **3D 모델과 실기에서 동일하게 동작**시키기 위한
> 알고리즘 설계 명세서다.
>
> **출처**:
> - UPenn DARwIn-OP Software Tutorial PDF (Stephen McGill, Seung-Joon Yi) — p.21–31
> - ROBOTIS `op2_walking_module` (Apache 2.0) — `research/robotis-official/ROBOTIS-OP2/`
> - Ha et al. 2011 "Development of Open Humanoid Platform DARwIn-OP"
>
> **상호 참조**: [walking-engine.md](walking-engine.md)(개요), [joint-conventions.md](joint-conventions.md),
> [op1-vs-op2-matrix.md](op1-vs-op2-matrix.md), [sensor-stack.md](sensor-stack.md).
>
> **본 문서의 위치**: 구현 명세 (코드 인터페이스, 수식, 의사코드까지 포함). 개념 개요는
> `walking-engine.md` 참조.

---

## § 0  한눈에 보기 (TL;DR)

**결론**: 걷기는 **3 단계 파이프라인**이다 — (1) 발 궤적 생성 → (2) 골반/본체 sway 생성 →
(3) 다리 6관절 역기구학(IK). 결과를 `RobotPose`로 모아 **3D 뷰와 실기에 동일하게** 적용한다.

**현재 상태**: (1)만 부분 구현, (2)·(3)이 누락되어 워크 랩의 3D 모델이 정자세에서 움직이지 않는다.

```
[WalkLab UI: x, y, a, enabled]
        │
        ▼
[WalkEngine.tick(dt)]  ─── ① 발 궤적 + ② 골반 궤적
        │
        ▼
[Kinematics.legIK()]   ─── ③ 발 자세 → 6 관절각 × 2 (좌/우)
        │
        ▼
[RobotPose.fromWalkSolution()]
        │            (+ 팔 스윙, + IMU 균형 보정)
        │
   ┌────┴────┐
   ▼         ▼
[3D 뷰]   [BusActor.setPositions() → 실기]
```

**파이프라인 단절 진단** (현재 코드):

| # | 위치 | 현상 |
|---|---|---|
| 1 | [WalkLab.swift:31, 52](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Walk/WalkLab.swift) | `pose: .walkReady` 고정 — 3D 모델이 워크 포즈를 받지 못함 |
| 2 | [Kinematics.swift](../../app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift) | Leg IK 함수 부재 (raw↔rad 변환만 존재) |
| 3 | [engine.rs:113-141](../../app/core/forge-core/src/walk/engine.rs) | phase 무관 sin파, 골반 궤적 미계산 |

본 문서는 위 3 단절을 모두 메꾸는 알고리즘과 코드 인터페이스를 정의한다.

---

## § 1  좌표계 & 단위 규칙

모든 부호 오류를 막기 위해 **반드시 먼저 합의**해야 하는 규칙.

### 1.1 좌표계
| 축 | 방향 |
|---|---|
| 원점 | 골반 중앙 (두 hip yaw 축의 중점, 지면에 투영) |
| X | **전방** (+), 후방 (−) |
| Y | **좌측** (+), 우측 (−) — 로봇 시점 |
| Z | **상방** (+), 하방 (−) |

### 1.2 단위
| 양 | 단위 | 코드 표기 |
|---|---|---|
| 각도 (내부) | rad | `Double` |
| 각도 (UI) | deg | `Double` (`degLimits`) |
| 길이 | m | `Double` |
| 시간 (사이클) | ms | `period_time_ms: f64` |
| 시간 (dt) | s | `Duration::as_secs_f64()` |

### 1.3 관절 부호 컨벤션
- "오른팔을 앞으로 들면 shoulder pitch가 +" 형태로 통일
- 좌우 거울 관절은 [Kinematics.swift:139-150](../../app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift:139) 의
  `mirrorSignFlip`을 참조
- 회전 축: Pitch=Y, Roll=X, Yaw=Z — [Kinematics.swift:66-85](../../app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift:66) 에 이미 정의

### 1.4 Z=0의 의미
- Z=0은 **지면**. 직립 시 골반은 Z = `leg_length` ≈ 0.2195 m 위에 있다.
- IK 입력에서 발 위치의 Z는 음수 (골반 아래 발이 있음).
- `z_offset` 파라미터는 **추가로** 발이 더 들리는 양 (직립 자세에서 무릎을 살짝 굽힘).

```
           ┌─────┐
           │ COB │ (Center of Body)
           └──┬──┘
              │
              ▼
       ┌──────────┐
       │   골반   │  ← 원점, Z = leg_length
       └──┬───┬──┘
          │   │
       (L)│   │(R)
          │   │       ← 다리 (6-DOF each)
          ▼   ▼
       ┌───┐ ┌───┐
       │L발│ │R발│   ← Z = z_offset (정자세) 또는 swing 시 Z 변화
       └───┘ └───┘
       ──────────  Z=0 (지면)
```

---

## § 2  워크 파라미터 사전

**원천**: [`op2_walking_module/config/param.yaml`](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/config/param.yaml),
이미 [params.rs](../../app/core/forge-core/src/walk/params.rs)에 1:1 포팅됨.

| 파라미터 (Rust) | 단위 | 디폴트 | UPenn 대응 (p.29) | 의미 | 권장 범위 |
|---|---|---|---|---|---|
| `period_time_ms` | ms | 600 | (없음, 암시) | 한 사이클 시간 | 400–800 |
| `dsp_ratio` | (0–1) | 0.1 | (없음) | 양발 지지 (DSP) 비율 | 0.05–0.30 |
| `step_forward_back_ratio` | (0–1) | 0.28 | (없음) | 전후 스텝 보간 | 0.20–0.40 |
| `foot_height` | m | 0.04 | `stepHeight=0.020` | 발 들리는 최대 높이 | 0.02–0.06 |
| `z_offset` | m | 0.020 | (bodyHeight 보완) | 정자세 무릎 굽힘 양 | 0.01–0.04 |
| `y_offset` | m | 0.005 | `footY/2` 일부 | 좌우 디딤 오프셋 | 0.00–0.04 |
| `x_offset` | m | −0.010 | `supportX` | 전후 디딤 오프셋 | −0.03–0.03 |
| `swing_right_left` | m | 0.020 | (CoM sway) | 본체 좌우 흔들기 (y_swap) | 0.01–0.04 |
| `swing_top_down` | m | 0.005 | (CoM bob) | 본체 상하 흔들기 (z_swap) | 0.00–0.01 |
| `hip_pitch_offset` | deg → rad | 13° | `bodyTilt≈7°` | 정자세 hip 굽힘 보정 | 0–20 |
| `pelvis_offset` | deg → rad | 3° | (없음) | 골반 회전 보정 | 0–5 |
| `arm_swing_gain` | (배율) | 1.5 | (CoG 보상) | 팔 카운터 스윙 | 1.0–2.5 |
| `balance_hip_roll_gain` | (게인) | 0.5 | proprio/inertial | IMU roll → hip_roll | 0–1.5 |
| `balance_knee_gain` | (게인) | 0.3 | | IMU pitch → knee | 0–1.5 |
| `balance_ankle_roll_gain` | (게인) | 1.0 | | IMU roll → ankle_roll | 0–1.5 |
| `balance_ankle_pitch_gain` | (게인) | 0.9 | | IMU pitch → ankle_pitch | 0–1.5 |
| `p_gain` / `i_gain` / `d_gain` | (0–254) | 32 / 0 / 0 | (MX-28T PID) | 서보 게인 | (그대로) |

---

## § 3  Phase 엔진

### 3.1 4 Phase 정의
**원본**: [params.rs:88-108](../../app/core/forge-core/src/walk/params.rs:88), [engine.rs:84-108](../../app/core/forge-core/src/walk/engine.rs:84).

```
PHASE0 ─── idle (enabled = false)

       ┌── ssp/2·T ──┐── dsp·T ──┐── ssp/2·T ──┐
       │             │           │             │
PHASE1 ████          │           │             │  오른발 swing (왼발 stance)
       │  PHASE2     ████████████│             │  양발 지지 (DSP)
       │             │  PHASE3   │             ████  왼발 swing (오른발 stance)
       │             │           │             │
       0           t1=ssp/2·T  t2=t1+dsp·T   T = period_time_ms
       │           │             │             │
       └─── 1 cycle T = period_time_ms ─────────┘

   ssp_ratio = 1 − dsp_ratio
```

### 3.2 시간 변수 (ROBOTIS 원본 명명 보존)
[op2_walking_module.cpp:320-347](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp)에서:

```
l_ssp_start = (1 − ssp_ratio) · T / 4   ← 왼발 swing 시작 (Phase 1 시작)
l_ssp_end   = (1 + ssp_ratio) · T / 4   ← 왼발 swing 종료 (Phase 2 시작)
r_ssp_start = (3 − ssp_ratio) · T / 4   ← 오른발 swing 시작 (Phase 3 시작)
r_ssp_end   = (3 + ssp_ratio) · T / 4   ← 오른발 swing 종료 (Phase 0)

x_swap_period = T / 2
x_move_period = T · ssp_ratio
y_swap_period = T
y_move_period = T · ssp_ratio
z_swap_period = T / 2
z_move_period = T · ssp_ratio / 2
a_move_period = T · ssp_ratio
```

> 주의: ROBOTIS 원본은 두 시간 스케일(`swap` = 본체 sway, `move` = 발 stepping)을 분리하여
> 본체와 발에 서로 다른 주기와 위상을 부여한다. 본 명세는 이를 그대로 따른다.

### 3.3 정규화 시간
- `τ = elapsed_ms / period_time_ms ∈ [0, 1)`
- 한 사이클이 끝나면 `elapsed_ms` 를 wrap 한다 ([engine.rs:90-92](../../app/core/forge-core/src/walk/engine.rs:90)).

---

## § 4  단계 1 — 발 궤적 생성

### 4.1 현재 결함
[engine.rs:113-141](../../app/core/forge-core/src/walk/engine.rs:113)은 phase에 **무관하게** 두 발이
모두 sin파를 따라 진동한다. 결과적으로 두 발이 동시에 떠올라 균형이 무너진다.

### 4.2 ROBOTIS 원본 방식 (개선 목표)
**참조**: [op2_walking_module.cpp:631-820](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:631) `computeLegAngle()`.

핵심 함수:
```
wSin(time, period, period_shift, mag, mag_shift) = mag · sin(2π · time / period − period_shift) + mag_shift
```

좌발의 movement (z, swing):
```
z_left = wSin(time_in_l_ssp, z_move_period, z_shift, foot_height/2, foot_height/2 + z_offset)
         단, time ∈ [l_ssp_start, l_ssp_end] 인 동안만; 그 외에는 z = z_offset (stance)
```

x, y, yaw 도 동일 패턴 — 각자의 period/shift/amplitude로 wSin.

### 4.3 명세 (수식)
**입력**: `WalkCommand { x: x_amp, y: y_amp, a: a_amp, enabled }`, `WalkParams`, `t = elapsed_ms`.

**좌발 swing 동안** (`l_ssp_start ≤ t ≤ l_ssp_end`):
```
τ_l = (t − l_ssp_start) / (l_ssp_end − l_ssp_start)   // 0..1 내 swing 정규 시간

left.z   = z_offset + foot_height · sin(π · τ_l)
left.x   = x_offset + ½·x_amp · (1 − cos(π · τ_l))     // 0 → x_amp
left.y   = y_offset + ½·y_amp · (1 − cos(π · τ_l))
left.yaw =           ½·a_amp · (1 − cos(π · τ_l))
```

**우발은 stance** 동안:
```
right.z = z_offset                                      // 발 평지 유지
right.x = stance 반대 방향 보상 (위 left.x 의 −½ 적용 효과를 통한 본체 전진)
right.y = -y_offset
```

**오른발 swing 동안** (`r_ssp_start ≤ t ≤ r_ssp_end`)도 좌우만 바꿔 대칭.

**Phase 2 (DSP)** 동안:
```
left.z = right.z = z_offset    // 두 발 모두 평지
```

### 4.4 옴니디렉셔널 워킹 (UPenn p.24)
사용자 명령 `(vx, vy, vω)`는 **한 사이클 동안의 누적 이동**을 의미. 다음 사이클의 다음 발 위치를
```
target_torso(n) = target_torso(n−1) + (vx, vy, vω)
next_step_position = target_torso(n) ± footY/2 (좌우 적용)
```
로 누적하여 계산. 이는 옴니 워킹(전진+회전+측면 동시)을 자연스럽게 지원한다.

### 4.5 의사코드
```rust
fn foot_targets(p: &WalkParams, cmd: WalkCommand, t_ms: f64) -> FootTargets {
    let T = p.period_time_ms;
    let ssp = 1.0 - p.dsp_ratio;
    let l_start = (1.0 - ssp) * T / 4.0;
    let l_end   = (1.0 + ssp) * T / 4.0;
    let r_start = (3.0 - ssp) * T / 4.0;
    let r_end   = (3.0 + ssp) * T / 4.0;

    let (l_swing, tau_l) = if t_ms >= l_start && t_ms <= l_end {
        (true, (t_ms - l_start) / (l_end - l_start))
    } else { (false, 0.0) };
    let (r_swing, tau_r) = if t_ms >= r_start && t_ms <= r_end {
        (true, (t_ms - r_start) / (r_end - r_start))
    } else { (false, 0.0) };

    let left = FootPose {
        xyz: [
            p.x_offset + if l_swing { 0.5*cmd.x*(1.0 - (PI*tau_l).cos()) } else { /* stance compensation */ },
            p.y_offset + if l_swing { 0.5*cmd.y*(1.0 - (PI*tau_l).cos()) } else { 0.0 },
            -p.z_offset + if l_swing { p.foot_height * (PI*tau_l).sin() } else { 0.0 },
        ],
        rpy: [
            0.0, 0.0,
            if l_swing { 0.5*cmd.a*(1.0 - (PI*tau_l).cos()) } else { 0.0 },
        ],
    };
    // right 도 대칭으로 구성
    FootTargets { left, right }
}
```

### 4.6 API 변경 (`FootTargets` 확장)
현재 [engine.rs:50-56](../../app/core/forge-core/src/walk/engine.rs:50):
```rust
pub struct FootTargets {
    pub left: [f64; 3],    // 위치만
    pub right: [f64; 3],
}
```
**변경 후**:
```rust
pub struct FootPose {
    pub xyz: [f64; 3],   // 골반 좌표계 위치 (m)
    pub rpy: [f64; 3],   // roll, pitch, yaw (rad)
}
pub struct FootTargets {
    pub left: FootPose,
    pub right: FootPose,
}
```
**이유**: ankle pitch/roll IK 입력으로 발의 자세(rpy)가 필요. 현재는 위치만 있어 IK 계산 불가능.

---

## § 5  단계 2 — 본체(골반) 궤적 & ZMP 휴리스틱

### 5.1 UPenn 가이드 발췌 (p.23)
> "Calculate body trajectory to satisfy ZMP criterion"
>
> Stationary walking: CoG ∈ 지지다각형.
> Dynamic walking: **ZMP ∈ 지지다각형**, CoG는 벗어나도 됨.

본 명세는 LIPM MPC 같은 **동적** 워킹 대신 ROBOTIS의 **closed-form 좌우 sway** 방식을 채택한다.
DARwIn-OP의 작은 풋프린트와 안정적 무게 분포에 잘 맞는다.

### 5.2 골반 좌우 sway (y_swap)
[op2_walking_module.cpp:633-650](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:633) `Pose3D swap` 변수.

```
y_pelvis(t) = swing_right_left · sin(2π · t / y_swap_period_ms − π/2)
            = -swing_right_left · cos(2π · t / T)        // 사이클 시작에 y=-swing, 중간에 y=+swing
```
- 좌발 swing 중에는 골반이 **오른발(stance) 쪽**으로 이동 → ZMP 오른발 안에 유지
- 오른발 swing 중에는 반대

### 5.3 골반 상하 bob (z_swap)
```
z_pelvis(t) = -swing_top_down · cos(2π · t / z_swap_period_ms − π/2)
            = -swing_top_down · sin(2π · t / (T/2))     // 사이클당 2회 진동
```
- 사이클당 2번 (양 발 swing 마다)
- 자연스러운 "걷는 듯한" 출렁임

### 5.4 골반 회전 (pelvis_offset_deg)
회전 명령(`a_amp ≠ 0`)이 있을 때:
```
swap.yaw = wSin(t, T, 0, pelvis_offset_rad · 0.35, 0)     // 0.35는 ROBOTIS 매직 상수 (p.346)
```
좌우 hip yaw에 반대 부호로 약간 보태어 정면 회전이 자연스럽게 보이도록 한다.

### 5.5 본체 자세 (roll, pitch)
- `bodyTilt = 7°` (UPenn p.29) — 골반을 약간 앞으로 기울여 CoG를 발등 위로
- `pitch_offset` 파라미터로 통합 — 정자세 hip pitch에 더한다.

### 5.6 출력 구조
```rust
pub struct BodyPose {
    pub pelvis_xyz: [f64; 3],  // 본체 sway (x, y, z)
    pub pelvis_rpy: [f64; 3],  // roll, pitch, yaw
}
```
`WalkEngine.tick()` 결과로 `(FootTargets, BodyPose)` 쌍을 반환.

---

## § 6  단계 3 — 다리 역기구학 (Leg IK)

**가장 중요한 누락 부분.** 본 절의 알고리즘은 ROBOTIS-OP2의 검증된 closed-form IK
([op2_walking_module.cpp:237-318](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:237) `WalkingModule::computeIK`)
를 그대로 포팅한다.

### 6.1 다리 구조 (6-DOF)
관절 체인 (골반에서 발로):
```
[Pelvis]
    │
HipYaw   (Z 축 회전)
    │
HipRoll  (X 축 회전)
    │
HipPitch (Y 축 회전) ──┐
    │                  │ thigh (대퇴) L_THIGH = 0.093 m
Knee     (Y 축 회전) ──┤
    │                  │ calf (정강이) L_CALF = 0.093 m
AnklePitch (Y 축 회전) ┤
    │                  │ ankle (발목) L_ANKLE = 0.0335 m
AnkleRoll  (X 축 회전) ┘
    │
[Foot]
```

### 6.2 링크 길이 (ROBOTIS-OP2 공식 값)
[op2_walking_module.cpp:240-243](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:240) 에서:
```cpp
double thigh_length = 93.0 * 0.001;      // 0.093 m
double calf_length  = 93.0 * 0.001;      // 0.093 m
double ankle_length = 33.5 * 0.001;      // 0.0335 m
double leg_length   = 219.5 * 0.001;     // 0.2195 m (thigh + calf + ankle)
```

**Swift 표현**:
```swift
public extension Kinematics {
    public enum LegLink {
        public static let thigh: Double = 0.093    // 대퇴 (hip pitch → knee)
        public static let calf:  Double = 0.093    // 정강이 (knee → ankle pitch)
        public static let ankle: Double = 0.0335   // 발목 (ankle pitch → 발바닥)
        public static let total: Double = 0.2195   // = thigh + calf + ankle
    }
}
```

### 6.3 IK 알고리즘 (ROBOTIS-OP2 검증된 closed-form)
**입력**: 발 자세 `(pos_x, pos_y, pos_z, ori_roll, ori_pitch, ori_yaw)` (골반 좌표계)
**출력**: 6 관절각 `[hip_yaw, hip_roll, hip_pitch, knee, ankle_pitch, ankle_roll]` (rad)

#### 단계 1 — 발 자세 변환 행렬
```
T_ad = T(pos_x, pos_y, pos_z) · R(roll, pitch, yaw)
```

#### 단계 2 — Ankle pitch 축 위치 벡터
```
vector = [
    pos_x + T_ad[0,2] · ankle_length,
    pos_y + T_ad[1,2] · ankle_length,
    pos_z − leg_length + T_ad[2,2] · ankle_length
]
```
(발에서 ankle 길이만큼 z축 방향으로 끌어올린 위치 = ankle pitch joint 위치)

#### 단계 3 — Knee (코사인 법칙)
```
r_ac = ‖vector‖
knee = acos((r_ac² − thigh_length² − calf_length²) / (2 · thigh_length · calf_length))
```
**도달 불가**: `acos` 인수가 [−1, 1] 밖이면 `NaN` → IK 실패, `nil` 반환.

#### 단계 4 — Ankle Roll
```
T_da = T_ad⁻¹
tda_y = T_da[1,3]
tda_z = T_da[2,3]
value_k = √(tda_y² + tda_z²)
value_l = √(tda_y² + (tda_z − ankle_length)²)
value_m = clamp((value_k² − value_l² − ankle_length²) / (2 · value_l · ankle_length), −1, 1)

ankle_roll = sign(tda_y) · acos(value_m)   // tda_y 부호로 분기
```

#### 단계 5 — Hip Yaw
```
T_cd = T(0, 0, −ankle_length) · R(ankle_roll, 0, 0)
T_dc = T_cd⁻¹
T_ac = T_ad · T_dc

hip_yaw = atan2(−T_ac[0,1], T_ac[1,1])
```

#### 단계 6 — Hip Roll
```
hip_roll = atan2(
    T_ac[2,1],
    −T_ac[0,1] · sin(hip_yaw) + T_ac[1,1] · cos(hip_yaw)
)
```

#### 단계 7 — Hip Pitch + Ankle Pitch (한 번에)
```
theta = atan2(
    T_ac[0,2] · cos(hip_yaw) + T_ac[1,2] · sin(hip_yaw),
    T_ac[0,0] · cos(hip_yaw) + T_ac[1,0] · sin(hip_yaw)
)

value_k = sin(knee) · calf_length
value_l = −thigh_length − cos(knee) · calf_length
value_m = cos(hip_yaw) · vector.x + sin(hip_yaw) · vector.y
value_n = cos(hip_roll) · vector.z
        + sin(hip_yaw)  · sin(hip_roll) · vector.x
        − cos(hip_yaw)  · sin(hip_roll) · vector.y
value_s = (value_k · value_n + value_l · value_m) / (value_k² + value_l²)
value_c = (value_n − value_k · value_s) / value_l

hip_pitch    = atan2(value_s, value_c)
ankle_pitch  = theta − knee − hip_pitch
```

### 6.4 관절 한계 처리
이미 정의된 [Kinematics.swift:42-56](../../app/ui/DarwinForge/Sources/ForgeCore/Kinematics.swift:42)
`JointID.degreeLimits`를 적용. 한계 초과 시 다음 전략:

1. **Soft clamp** (권장): 관절각을 한계 안으로 클램프하고 UI 경고 표시
2. **Hard fail**: `nil` 반환하여 호출자가 발 위치를 reachable boundary로 조정

본 명세는 1번을 디폴트로 채택한다 (워크 중단보다 다소 부정확한 자세가 낫다).

### 6.5 API 정의 (Swift)
```swift
public extension Kinematics {
    public enum LegLink {
        public static let thigh: Double = 0.093
        public static let calf:  Double = 0.093
        public static let ankle: Double = 0.0335
        public static let total: Double = 0.2195
    }

    /// 발 자세 → 다리 6관절각.
    /// - Parameters:
    ///   - foot: 골반 좌표계에서의 발 자세 (xyz, rpy)
    ///   - isLeft: 왼쪽 다리이면 true (좌우 부호 처리)
    /// - Returns: 6관절각 dict, 또는 도달 불가 시 nil
    public static func legIK(
        foot: FootPose,
        isLeft: Bool
    ) -> [JointID: Double]? {
        // 위 § 6.3 알고리즘 그대로 구현
        // 결과 dict 키: .hipYaw, .hipRoll, .hipPitch, .knee, .anklePitch, .ankleRoll
        // (좌/우 prefix는 isLeft 로 결정)
    }

    /// 다리 6관절각 → 발 자세 (FK, IK 검증용).
    public static func legFK(
        angles: [JointID: Double],
        isLeft: Bool
    ) -> FootPose
}
```

### 6.6 검증 — IK 라운드트립
```swift
// FK ∘ IK = identity (오차 < 1e-3 rad)
let angles = [..random 6 valid joint angles..]
let foot = Kinematics.legFK(angles: angles, isLeft: true)
let solved = Kinematics.legIK(foot: foot, isLeft: true)!
for (jid, a) in angles {
    XCTAssertEqual(solved[jid]!, a, accuracy: 1e-3)
}
```

---

## § 7  단계 4 — 팔 스윙 (CoG 보상)

**원본**: [op2_walking_module.cpp:869-884](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:869).

```rust
if x_move_amplitude == 0 {
    arm_right = 0
    arm_left  = 0
} else {
    arm_right = wSin(t, T, 3π/2, −x_move_amplitude · arm_swing_gain · 1000, 0)
                · direction["r_sho_pitch"] · DEG2RAD
    arm_left  = wSin(t, T, 3π/2, +x_move_amplitude · arm_swing_gain · 1000, 0)
                · direction["l_sho_pitch"] · DEG2RAD
}
```
- 두 팔은 **서로 반대 위상** (좌우 부호 반대)
- `· 1000`은 m → mm 변환 (각도가 mm 단위 mag에서 deg로 환산되는 ROBOTIS 컨벤션)
- 회전 명령만 있고 전진(x) 없으면 팔은 스윙 안 함

**elbow**: 정자세 elbow (약 45°) 유지.

---

## § 8  단계 5 — 능동적 안정화 (Active Stabilization)

### 8.1 UPenn p.27
두 가지 피드백:
- **Proprioceptive**: 관절 위치 오차 → 다음 사이클 보정
- **Inertial**: IMU roll/pitch → 관절 직접 보정

본 명세는 inertial을 우선 구현 (proprio는 별도 사이클).

### 8.2 IMU 피드백 공식
**원본**: [op2_walking_module.cpp:886-913](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:886) `sensoryFeedback()`.

```
internal_gain = -0.3     // ROBOTIS 매직 상수

hip_roll_R   += dir["r_hip_roll"] · internal_gain · rl_gyro_err · balance_hip_roll_gain
hip_roll_L   += dir["l_hip_roll"] · internal_gain · rl_gyro_err · balance_hip_roll_gain

knee_R       += -dir["r_knee"]    · internal_gain · fb_gyro_err · balance_knee_gain
knee_L       += -dir["l_knee"]    · internal_gain · fb_gyro_err · balance_knee_gain

ankle_pitch_R += -dir["r_ank_pitch"] · internal_gain · fb_gyro_err · balance_ankle_pitch_gain
ankle_pitch_L += -dir["l_ank_pitch"] · internal_gain · fb_gyro_err · balance_ankle_pitch_gain

ankle_roll_R  += -dir["r_ank_roll"]  · internal_gain · rl_gyro_err · balance_ankle_roll_gain
ankle_roll_L  += -dir["l_ank_roll"]  · internal_gain · rl_gyro_err · balance_ankle_roll_gain
```
여기서:
- `rl_gyro_err`: 측면 자이로 오차 (= IMU roll 추정값 − 목표 roll)
- `fb_gyro_err`: 전후 자이로 오차 (= IMU pitch 추정값 − 목표 pitch)
- `dir[joint]`: 관절 회전 방향 부호 (좌우 다름)

### 8.3 IMU 입력 파이프라인
- CM-740/CM-730 → GYRO + ACCEL → `ComplementaryFilter` → body roll/pitch (저장소에 이미 존재 가능)
- 8 ms 주기로 BULK_READ
- 1차 LPF (cutoff 5–10 Hz)로 잡음 억제

### 8.4 폴오버 감지 (옵션)
- `|imu_pitch| > 60°` 또는 ACCEL Z축 < 임계 → 워킹 중단, standup state 전환
- UPenn p.33–38 Motion FSM의 fall/standup 상태와 연동

---

## § 9  렌더링 & 하드웨어 파이프라인 통합

### 9.1 현재 문제
[WalkLab.swift:31, 52](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Walk/WalkLab.swift:31)이
`pose: .walkReady`를 **고정**으로 전달 → 3D 모델이 워킹 포즈를 받지 못한다.

[WalkLab.swift:280-290](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Walk/WalkLab.swift:280) `walkPoseFromSample()`은
mock 구현(hip pitch에 sin파만 더함)으로, **하드웨어 경로에서만 사용**되고 3D 뷰와 분리되어 있다.

### 9.2 수정안 — 단일 진실의 원천 (Single Source of Truth)
```swift
// WalkLab.swift 수정 핵심
@State private var currentWalkPose: RobotPose = .walkReady

// timer 콜백 안에서:
let sample = engine.tick(dtMs: 8)               // 8ms 권장 (Hz=125)
let (footTargets, bodyPose) = engine.solve()    // ① ② 단계

// ③ 다리 IK
guard
    let lAngles = Kinematics.legIK(foot: footTargets.left,  isLeft: true),
    let rAngles = Kinematics.legIK(foot: footTargets.right, isLeft: false)
else { /* unreachable — UI 경고 */ return }

// 팔 스윙 + 균형 보정 + RobotPose 빌드
let pose = RobotPose.fromWalkSolution(
    legL: lAngles, legR: rAngles,
    body: bodyPose,
    armPhase: sample.elapsedMs,
    params: engine.params,
    imuRoll: store.imu.roll, imuPitch: store.imu.pitch    // 있으면
)

currentWalkPose = pose                          // 3D 자동 업데이트 (SwiftUI 반응성)
if sendToHardware, let bus = store.bus {
    bus.setPositions(pose.legJointMap())        // 하드웨어 SYNC_WRITE
}
```

```swift
// RobotScene3D 호출은:
RobotScene3D(pose: currentWalkPose, footTrace: trace, ...)
//                  ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑   .walkReady 대신 동적 포즈
```

### 9.3 프레임율
| 위치 | 권장 |
|---|---|
| 워크 엔진 tick | **8 ms (125 Hz)** — MX-28T BULK_READ 주기와 일치 |
| 하드웨어 SYNC_WRITE | 8 ms (위와 동일 cycle에서 직접 전송) |
| 3D 렌더 | **60 fps (16.7 ms)** Display Link 기반, pose 변경 시 SwiftUI가 자동 보간 |
| 사용자 입력 (슬라이더) | 즉시 반영, 사이클 중간에 amplitude만 부드럽게 보간 |

8 ms가 부담스러우면 16 ms (60 Hz)도 가능. 현재의 50 ms는 너무 느려 자연스러운 sway가 안 보임.

---

## § 10  데이터 구조 & API 변경 요약

| # | 위치 | 종류 | 변경 |
|---|---|---|---|
| 1 | `forge-core::walk::engine` `FootTargets` | 확장 | `[f64;3]` → `FootPose { xyz, rpy }` 포함 |
| 2 | `forge-core::walk::engine` `BodyPose` | 신규 | `pelvis_xyz`, `pelvis_rpy` 출력 |
| 3 | `forge-core::walk::engine::foot_targets` | 수정 | phase 분기 swing/stance 분리 (§ 4) |
| 4 | `ForgeCore::Kinematics::LegLink` | 신규 | 링크 길이 상수 4개 (§ 6.2) |
| 5 | `ForgeCore::Kinematics::legIK` | 신규 | closed-form 6-DOF IK (§ 6.3) |
| 6 | `ForgeCore::Kinematics::legFK` | 신규 (검증용) | FK 라운드트립 테스트 |
| 7 | `ForgeCore::RobotPose::fromWalkSolution` | 신규 | leg + body + arm + balance를 RobotPose로 |
| 8 | `ForgeCore::WalkEngine::tick` (Swift wrapper) | 확장 | `WalkSample { footTargets, bodyPose, phase, elapsedMs }` |
| 9 | `DarwinForgeUI::WalkLab` 3D 뷰 | 교체 | `pose: .walkReady` → `pose: currentWalkPose` |
| 10 | `DarwinForgeUI::WalkLab` timer | 교체 | mock `walkPoseFromSample` 제거, 통합 파이프라인 호출 |
| 11 | `DarwinForgeUI::WalkLab` 파라미터 UI | 추가 | foot_height/period/dsp_ratio 슬라이더 노출 (옵션) |
| 12 | `ForgeCore::BusActor::setPositions` | 그대로 사용 | 이미 batch SYNC_WRITE 지원 |
| 13 | `ForgeCore::Imu` → walk pipeline | 연결 | roll/pitch → § 8.2 보정식에 주입 |

---

## § 11  구현 단계 (Phase A → F)

각 단계는 독립 PR. **TDD 우선** — 단위 테스트 작성 후 구현.

### Phase A — Leg IK (기반)
**산출물**:
- `Kinematics.LegLink` 상수
- `Kinematics.legIK(foot:isLeft:)` (§ 6.3 알고리즘)
- `Kinematics.legFK(angles:isLeft:)` (검증용)

**테스트**:
- `Tests/ForgeCoreTests/KinematicsLegIKTests.swift` (신규)
- IK 라운드트립: `legIK(legFK(angles)) ≈ angles` (정밀도 1e-3 rad)
- 알려진 `.walkReady` 포즈가 IK 결과와 일치
- 도달 불가 (다리 길이 초과) → `nil`

**측정 가능 완료 기준**: 위 3가지 테스트 모두 통과.

### Phase B — 발 궤적 phase 분기 + BodyPose
**산출물**:
- [engine.rs](../../app/core/forge-core/src/walk/engine.rs)의 `foot_targets()` 를 § 4.3, § 4.5 명세로 교체
- `BodyPose` 구조체 + `body_pose(t)` 함수 (§ 5.2–5.4)
- `WalkEngine.tick()` 반환을 `(FootTargets, BodyPose)`로 확장

**테스트**:
- `Tests/ForgeCoreTests/FootTrajectoryTests.swift` (신규)
- PHASE1에서 좌발만 z>0, 우발 z=−z_offset
- PHASE2에서 두 발 모두 z=−z_offset
- swing→stance 전이 시 위치/속도 연속 (불연속 < 1mm)
- 골반 sway가 swing 발과 반대 방향

### Phase C — 파이프라인 통합 (시각화)
**산출물**:
- `RobotPose.fromWalkSolution()` 빌더 추가
- [WalkLab.swift:31, 52](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Walk/WalkLab.swift:31) 3D 뷰 입력 교체
- [WalkLab.swift:280-290](../../app/ui/DarwinForge/Sources/DarwinForgeUI/Walk/WalkLab.swift:280) mock 제거,
  통합 파이프라인 호출
- 타이머 주기 8 ms (또는 16 ms) 로 변경

**검증**: **시각** — WalkLab에서 "앞으로 빠르게" 클릭 시:
- 3D 모델의 두 다리가 교대로 swing 호 그림
- 골반이 stance 발 쪽으로 좌우 sway
- 1 사이클(600 ms) 동안 1걸음 완료가 육안으로 보임

### Phase D — 팔 스윙 + 골반 sway 보완
**산출물**:
- § 7 팔 스윙 식을 `fromWalkSolution` 안에서 적용
- 골반 sway를 IK 입력 발 좌표에 보정 (`foot.y -= body.pelvis_xyz.y`)
- `pelvis_offset` 회전 보정 (§ 5.4)

**검증**: **시각** — 워크 시 두 팔이 다리와 반대 위상으로 흔들림, 좌우 균형이 자연스러움.

### Phase E — IMU 균형 보정 (하드웨어 의존)
**산출물**:
- `Imu` 모듈에서 roll/pitch 추정값 노출
- § 8.2 보정식 적용 (`sendToHardware = true` 일 때만)
- 폴오버 감지 (옵션)

**검증**: **실기 (안전 매다는 상태)**:
- 정지 워킹 시 좌우 sway가 자연스러움
- 손으로 살짝 밀면 균형 복원
- 60° 기울어지면 워크 중단

### Phase F — UI 파라미터 노출 + 튜닝
**산출물**:
- WalkLab에 슬라이더 추가: `foot_height`, `period_time_ms`, `swing_right_left`, `dsp_ratio`
- 프리셋 저장/로드 (.json) — `~/Library/Application Support/DarwinForge/walk_presets/`

**검증**: 비전문가가 슬라이더만으로 보폭/속도 조절 가능.

---

## § 12  검증 계획 (Test Plan)

### 12.1 단위 테스트
| 테스트 | 파일 (신규) | 통과 조건 |
|---|---|---|
| IK 라운드트립 | `KinematicsLegIKTests.swift` | FK ∘ IK = identity (< 1e-3 rad) |
| IK 도달 불가 | 위 같은 파일 | r > thigh+calf 입력 시 nil |
| IK NaN 처리 | 위 같은 파일 | acos 인수 [−1, 1] 클램프 |
| Phase 경계 | `WalkPhaseTests.swift` | l_ssp_start/end 등 ROBOTIS 식 정확 |
| 발 궤적 연속성 | `FootTrajectoryTests.swift` | swing→stance 위치/속도 연속 |
| 골반 sway 위상 | `BodyPoseTests.swift` | swing 발과 반대 방향 |
| 균형 게인 | `BalanceGainTests.swift` | IMU=0 → 보정 0; IMU>0 → 정해진 부호 |

### 12.2 시각 검증 (3D 모델)
WalkLab "앞으로 빠르게" 클릭 후 다음이 모두 보여야 함:
- [ ] 좌우 다리가 약 600 ms 주기로 교대로 들렸다 내려놓음
- [ ] 들리는 발은 호(arc)를 그리며 약 4 cm 들림
- [ ] 골반이 stance 발 쪽으로 좌우 약 2 cm sway
- [ ] 두 팔이 다리와 반대 위상으로 흔들림
- [ ] 회전 명령(a≠0) 시 발 yaw 회전 보임

### 12.3 하드웨어 검증 (실기)
**안전**: 천장 잭에 매달거나 책상 가장자리에 두 손으로 보조.

- [ ] 정지 sway만 (vx=0, vy=0, a=0): 좌우 흔들림 자연스러움
- [ ] 전진 (vx=0.02 m/cycle): 실제 전진, 1 cycle = 2 cm
- [ ] 측면 (vy=0.02): 게걸음
- [ ] 회전 (a=0.1 rad/cycle): 그 자리 회전
- [ ] 외란 (살짝 밀기): 균형 복원
- [ ] 60° 기울임: 워크 중단

---

## § 13  위험 요소 & 완화

| # | 위험 | 영향 | 완화 |
|---|---|---|---|
| 1 | IK 부호 오류로 다리가 거꾸로 굽힘 | 모델/실기 파손 | FK 라운드트립 + `.walkReady` 비교 테스트 |
| 2 | 좌표계 혼동 (Y 좌측 vs 우측) | 좌우 반대로 걷기 | § 1 명시, 모든 API에 단위/축 주석 |
| 3 | 링크 길이 OP1 vs OP2 차이 | IK 부정확 | `op1-vs-op2-matrix.md` 참조, 모델 자동 감지 |
| 4 | 실기 발 미끄러짐 | 넘어짐 | foot_height 낮춤 + 보폭 작게 시작 |
| 5 | IMU 잡음 → sway 불안정 | 진동 | 1차 LPF (cutoff 5–10 Hz) |
| 6 | 8 ms 제어 주기 → Swift Task overhead | 프레임 드롭 | Rust core 에서 사이클당 N 샘플 미리 계산 |
| 7 | IK 도달 불가 (한계 초과) | 워크 중단 | 발 위치를 reachable boundary로 클램프 (§ 6.4) |
| 8 | 사용자가 너무 큰 amplitude 입력 | 균형 손실 | UI 슬라이더 범위를 안전 한계로 |

---

## § 14  참고 자료

### 14.1 1차 출처
- **PDF**: `~/Downloads/DARwIn-OP_UPenn_Tutorial.pdf` (Stephen McGill & Seung-Joon Yi, UPenn)
  - p.21–31: Locomotion (walk basics, ZMP, foot trajectory, IK, params)
  - p.27: Active stabilization (proprio + inertial)
  - p.29: Walk parameter set (Config.lua)
- **ROBOTIS 코드** (Apache 2.0):
  - [`research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp`](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp)
    - `computeIK()` (line 237) — closed-form 다리 IK (§ 6.3)
    - `computeLegAngle()` (line 631) — 발 궤적 + IK 호출 (§ 4)
    - `sensoryFeedback()` (line 886) — IMU 균형 보정 (§ 8.2)
    - `computeArmAngle()` (line 869) — 팔 스윙 (§ 7)
  - [`op2_kinematics_dynamics.cpp`](../../research/robotis-official/ROBOTIS-OP2/op2_kinematics_dynamics/src/op2_kinematics_dynamics.cpp) — Jacobian 기반 generic IK (참고만, 워킹은 closed-form 사용)
  - [`op2_walking_parameter.h`](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/include/op2_walking_module/op2_walking_parameter.h) — 파라미터 enum/struct

### 14.2 학술 자료
- Ha et al. 2011 "Development of Open Humanoid Platform DARwIn-OP" — `research/papers/REFERENCES.bib`
- DARwIn-OP Kinematics PDF: `research/robotis-official/ROBOTIS-OP-Series-Data/ROBOTIS-OP, ROBOTIS-OP2/Hardware/Mechanics/DARwIn-OP_Kinematics.pdf` (링크 치수 도면)

### 14.3 본 저장소 상호 참조
- [walking-engine.md](walking-engine.md) — 본 문서의 개요판
- [joint-conventions.md](joint-conventions.md) — 관절 ID/부호 규칙
- [op1-vs-op2-matrix.md](op1-vs-op2-matrix.md) — OP1/OP2 하드웨어 차이
- [sensor-stack.md](sensor-stack.md) — IMU/Bus 스택
- [../motion-format/](../motion-format/) — 모션 파일 포맷 (워크는 모션과 다르지만 RobotPose 공유)

---

## § 15  라이선스 노트

- ROBOTIS-OP2 `op2_walking_module`: Apache 2.0
  - 알고리즘과 파라미터는 자유롭게 차용 가능
  - 단, Cargo 메타데이터 (`forge-core/Cargo.toml`) 와 Swift 패키지 NOTICE에 출처 표기 필수
- UPenn 슬라이드: 학술 강의 자료
  - 본 문서는 알고리즘 텍스트만 인용 (이미지/슬라이드 자체는 미수록)
- 본 명세 문서: 저장소 라이선스를 따른다 (`LICENSE` 참조)

---

## 부록 A — 의사코드 (전체 파이프라인)

```python
# 8 ms 마다 호출 (125 Hz 워크 사이클)
def walk_tick(dt_ms, params, cmd, imu):
    # 1. 시간 진행
    elapsed_ms = (elapsed_ms + dt_ms) % params.period_time_ms
    t = elapsed_ms

    # 2. 발 궤적 (§ 4)
    foot_l, foot_r = foot_targets(params, cmd, t)

    # 3. 본체 sway (§ 5)
    body = body_pose(params, t)

    # 4. 골반 sway를 발 좌표에 보정 (단계 D)
    foot_l.xyz[1] -= body.pelvis_xyz[1]
    foot_r.xyz[1] -= body.pelvis_xyz[1]

    # 5. 다리 IK (§ 6)
    leg_l = leg_ik(foot_l, is_left=True)
    leg_r = leg_ik(foot_r, is_left=False)
    if leg_l is None or leg_r is None:
        warn("foot pose unreachable")
        return None

    # 6. 팔 스윙 (§ 7)
    arm_r, arm_l = arm_swing(cmd, params, t)

    # 7. IMU 균형 보정 (§ 8)
    if params.balance_enable and imu is not None:
        leg_l, leg_r = apply_balance(leg_l, leg_r, imu, params)

    # 8. RobotPose 빌드
    pose = RobotPose(
        l_leg=leg_l, r_leg=leg_r,
        l_arm=arm_l, r_arm=arm_r,
        head=walk_ready.head
    )

    # 9. 출력
    update_3d_view(pose)
    if send_to_hardware:
        bus.set_positions(pose.leg_joints)

    return pose
```

---

## 부록 B — `wSin` 함수 명세

ROBOTIS 워킹 모듈의 핵심 sinusoid 생성기 ([op2_walking_module.cpp:230](../../research/robotis-official/ROBOTIS-OP2/op2_walking_module/src/op2_walking_module.cpp:230)):

```rust
/// 시간 `t` 시점의 sinusoid 값.
/// 출처: ROBOTIS op2_walking_module.cpp `WalkingModule::wSin`.
pub fn w_sin(t: f64, period: f64, phase_shift: f64, mag: f64, mag_shift: f64) -> f64 {
    mag * (2.0 * PI * t / period - phase_shift).sin() + mag_shift
}
```

- `t`: 현재 시간 (ms)
- `period`: 주기 (ms)
- `phase_shift`: 위상 offset (rad)
- `mag`: 진폭
- `mag_shift`: DC offset

모든 발/본체 궤적이 이 한 함수의 합/곱으로 생성된다.

---

**문서 끝.** 본 명세를 따라 § 11의 Phase A → F를 순차 구현하면 워크 랩의 3D 모델이
실제로 걷는 모습을 보이게 된다. 후속 단계는 사용자 지시 시 Phase A의 단위 테스트 작성부터
TDD로 진행한다.
