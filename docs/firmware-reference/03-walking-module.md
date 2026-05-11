# 03 — Walking Module (ROBOTIS-OP2 Factory Firmware)

> **출처**: ROBOTIS-OP2 공식 복구 이미지 (2015-03-26), `/firmware-backups/sda1-rootfs/robotis/`
> **목적**: 공장 출하 walking 엔진을 1:1 해부하여 Darwin 포팅 `walk/params.rs` 의 기본값을 검증한다.
> **상호 참조**: [walking-algorithm-design.md](../architecture/walking-algorithm-design.md), [walking-engine.md](../architecture/walking-engine.md)

---

## TL;DR

- 공장 walking 엔진은 `Robot::Walking` 싱글턴(`Framework/include/Walking.h` + `Framework/src/motion/modules/Walking.cpp`)으로, **폐형식(closed-form) sinusoidal ZMP 보행 + 6-DOF 다리 IK** 를 사용한다 — 정확히 **30,234 바이트 한 파일**에 전체 구현이 들어 있다.
- 모든 발 끝점·골반 sway·팔 스윙은 단일 함수 `wsin(t, T, φ, A, A_shift) = A·sin(2π·t/T − φ) + A_shift` 의 조합이며, 위상은 PHASE0~PHASE3(SSP_L → DSP1 → SSP_R → DSP2) 의 4-상 구조를 따른다. IMU 균형 보정은 `Process()` 의 마지막에서 좌·우 자이로(`FB_GYRO`, `RL_GYRO`) × `BALANCE_*_GAIN` 으로 hip-roll, knee, ankle-pitch, ankle-roll 모터값에 직접 더한다.
- 공장 튜닝 값 두 세트가 발견된다: (1) C++ 생성자 기본값 `Walking::Walking()` (가장 권위적, 출하 시), (2) `tutorial/action_script/config.ini` 의 `[Walking Config]` 섹션. **Darwin `WalkParams::default()` 는 (1)과 거의 일치하지만 일부 값에 차이가 있다** — 특히 `hip_pitch_offset_deg = 13.0` (Darwin) vs `60.0` (action_script ini) 의 차이는 IK 출력에 직접 영향한다.

---

## 1. Source files

### 1.1 `robotis/Framework/include/Walking.h` (160 lines)

**경로**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Walking.h`

**역할**: `Robot::Walking` 싱글턴 클래스 선언. 공용 파라미터 31개 + 내부 위상·sway 상태 ~30개를 정의한다.

**공용 메서드** (`MotionModule` 인터페이스 + 자체 메서드):
```cpp
class Walking : public MotionModule {
public:
    enum { PHASE0 = 0, PHASE1 = 1, PHASE2 = 2, PHASE3 = 3 };

    int GetCurrentPhase()  { return m_Phase; }
    double GetBodySwingY() { return m_Body_Swing_Y; }
    double GetBodySwingZ() { return m_Body_Swing_Z; }

    static Walking* GetInstance() { return m_UniqueInstance; }
    void Initialize();           // reset state + run Process() once
    void Start();                // m_Ctrl_Running = true
    void Stop();                 // m_Ctrl_Running = false  (정지는 다음 PHASE0/2 경계에서)
    void Process();              // 8ms 마다 호출 — 메인 루프
    bool IsRunning();
    void LoadINISettings(minIni* ini);     // [Walking Config] 섹션 로드
    void SaveINISettings(minIni* ini);
};
```

**공용 튜닝 파라미터 (31개)** — `Walking.h:106-137`:
```cpp
// Walking initial pose (자세 오프셋)
double X_OFFSET, Y_OFFSET, Z_OFFSET;
double A_OFFSET, P_OFFSET, R_OFFSET;        // a=yaw, p=pitch, r=roll

// Walking control
double PERIOD_TIME;                          // 한 사이클 ms
double DSP_RATIO;                            // double-support 비율
double STEP_FB_RATIO;                        // X step / X swap 비율
double X_MOVE_AMPLITUDE, Y_MOVE_AMPLITUDE,
       Z_MOVE_AMPLITUDE, A_MOVE_AMPLITUDE;   // 입력 명령
bool   A_MOVE_AIM_ON;

// Balance control
bool   BALANCE_ENABLE;
double BALANCE_KNEE_GAIN, BALANCE_ANKLE_PITCH_GAIN;
double BALANCE_HIP_ROLL_GAIN, BALANCE_ANKLE_ROLL_GAIN;
double Y_SWAP_AMPLITUDE, Z_SWAP_AMPLITUDE;
double ARM_SWING_GAIN;
double PELVIS_OFFSET;
double HIP_PITCH_OFFSET;
int    P_GAIN, I_GAIN, D_GAIN;               // MX-28 12 다리 관절 공통
```

**비공개 내부 메서드**:
```cpp
double wsin(double t, double period, double period_shift, double mag, double mag_shift);
bool   computeIK(double *out, double x, double y, double z, double a, double b, double c);
void   update_param_time();      // m_PeriodTime, SSP/DSP 시작/종료 시각 계산
void   update_param_move();      // 각 축 swap/move amplitude·shift 계산
void   update_param_balance();   // X/Y/Z/R/P/A offset → 내부 단위 환산
```

---

### 1.2 `robotis/Framework/src/motion/modules/Walking.cpp` (624 lines, 30 234 bytes)

**경로**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/modules/Walking.cpp`

**역할**: walking 엔진 전체 구현. 생성자 기본값, INI 로드/세이브, 발 궤적 생성, 다리 IK, IMU 균형 보정, 모터 출력까지 모두 들어있다.

**핵심 인용 1 — 생성자 (공장 출하 기본값)** — `Walking.cpp:23-78`:
```cpp
Walking::Walking() {
    X_OFFSET = -10;             // mm
    Y_OFFSET = 5;
    Z_OFFSET = 20;
    R_OFFSET = 0; P_OFFSET = 0; A_OFFSET = 0;
    HIP_PITCH_OFFSET = 13.0;    // deg
    PERIOD_TIME = 600;          // ms
    DSP_RATIO = 0.1;
    STEP_FB_RATIO = 0.28;
    Z_MOVE_AMPLITUDE = 40;
    Y_SWAP_AMPLITUDE = 20.0;
    Z_SWAP_AMPLITUDE = 5;
    PELVIS_OFFSET = 3.0;
    ARM_SWING_GAIN = 1.5;
    BALANCE_KNEE_GAIN = 0.3;
    BALANCE_ANKLE_PITCH_GAIN = 0.9;
    BALANCE_HIP_ROLL_GAIN = 0.5;
    BALANCE_ANKLE_ROLL_GAIN = 1.0;

    P_GAIN = JointData::P_GAIN_DEFAULT;   // 32
    I_GAIN = JointData::I_GAIN_DEFAULT;   // 0
    D_GAIN = JointData::D_GAIN_DEFAULT;   // 0

    X_MOVE_AMPLITUDE = 0;
    Y_MOVE_AMPLITUDE = 0;
    A_MOVE_AMPLITUDE = 0;
    A_MOVE_AIM_ON = false;
    BALANCE_ENABLE = true;
    /* ... 팔 시작 자세, EXTRASOFT slope, P_GAIN=8 for 팔 ... */
}
```

**핵심 인용 2 — `wsin()` 단일 sinusoid** — `Walking.cpp:149-152`:
```cpp
double Walking::wsin(double time, double period,
                     double period_shift, double mag, double mag_shift) {
    return mag * sin(2 * 3.141592 / period * time - period_shift) + mag_shift;
}
```

**핵심 인용 3 — `update_param_time()` 4-상 시각 계산** — `Walking.cpp:233-260`:
```cpp
m_PeriodTime = PERIOD_TIME;
m_DSP_Ratio = DSP_RATIO;
m_SSP_Ratio = 1 - DSP_RATIO;

m_X_Swap_PeriodTime = m_PeriodTime / 2;
m_X_Move_PeriodTime = m_PeriodTime * m_SSP_Ratio;
m_Y_Swap_PeriodTime = m_PeriodTime;
m_Y_Move_PeriodTime = m_PeriodTime * m_SSP_Ratio;
m_Z_Swap_PeriodTime = m_PeriodTime / 2;
m_Z_Move_PeriodTime = m_PeriodTime * m_SSP_Ratio / 2;
m_A_Move_PeriodTime = m_PeriodTime * m_SSP_Ratio;

m_SSP_Time          = m_PeriodTime * m_SSP_Ratio;
m_SSP_Time_Start_L  = (1 - m_SSP_Ratio) * m_PeriodTime / 4;
m_SSP_Time_End_L    = (1 + m_SSP_Ratio) * m_PeriodTime / 4;
m_SSP_Time_Start_R  = (3 - m_SSP_Ratio) * m_PeriodTime / 4;
m_SSP_Time_End_R    = (3 + m_SSP_Ratio) * m_PeriodTime / 4;
```

**핵심 인용 4 — endpoint 합성 + IK 호출** — `Walking.cpp:499-510, 544-550`:
```cpp
ep[0] = x_swap + x_move_r + m_X_Offset;
ep[1] = y_swap + y_move_r - m_Y_Offset / 2;
ep[2] = z_swap + z_move_r + m_Z_Offset;
ep[3] = a_swap + a_move_r - m_R_Offset / 2;
ep[4] = b_swap + b_move_r + m_P_Offset;
ep[5] = c_swap + c_move_r - m_A_Offset / 2;
// (ep[6..11] = 좌발 동일 패턴)

if ((computeIK(&angle[0], ep[0], ep[1], ep[2], ep[3], ep[4], ep[5]) == 1)
 && (computeIK(&angle[6], ep[6], ep[7], ep[8], ep[9], ep[10], ep[11]) == 1)) {
    for(int i=0; i<12; i++)
        angle[i] *= 180.0 / PI;
}
```

**핵심 인용 5 — IMU 균형 보정 (BALANCE_ENABLE)** — `Walking.cpp:571-599`:
```cpp
if(BALANCE_ENABLE == true) {
    double rlGyroErr = MotionStatus::RL_GYRO;
    double fbGyroErr = MotionStatus::FB_GYRO;
#ifdef MX28_1024
    outValue[1]  += (int)(dir[1]  * rlGyroErr * BALANCE_HIP_ROLL_GAIN);    // R_HIP_ROLL
    outValue[7]  += (int)(dir[7]  * rlGyroErr * BALANCE_HIP_ROLL_GAIN);    // L_HIP_ROLL
    outValue[3]  -= (int)(dir[3]  * fbGyroErr * BALANCE_KNEE_GAIN);        // R_KNEE
    outValue[9]  -= (int)(dir[9]  * fbGyroErr * BALANCE_KNEE_GAIN);
    outValue[4]  -= (int)(dir[4]  * fbGyroErr * BALANCE_ANKLE_PITCH_GAIN); // R_ANKLE_PITCH
    outValue[10] -= (int)(dir[10] * fbGyroErr * BALANCE_ANKLE_PITCH_GAIN);
    outValue[5]  -= (int)(dir[5]  * rlGyroErr * BALANCE_ANKLE_ROLL_GAIN);  // R_ANKLE_ROLL
    outValue[11] -= (int)(dir[11] * rlGyroErr * BALANCE_ANKLE_ROLL_GAIN);
#else
    // MX28 4096 res: 게인을 ×4 한다
    outValue[1] += (int)(dir[1] * rlGyroErr * BALANCE_HIP_ROLL_GAIN*4);
    /* ...동일 패턴, gain*4 ... */
#endif
}
```

---

### 1.3 `robotis/Linux/project/walk_tuner/main.cpp` (185 lines)

**경로**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/walk_tuner/main.cpp`

**역할**: 워킹 파라미터 인터랙티브 튜닝 도구. `../../../Data/config.ini` 의 `[Walking Config]` 섹션을 읽어 `Walking::GetInstance()` 에 적용하고, 화살표키로 값을 조절 후 `save` 명령으로 동일 위치에 다시 기록한다.

**핵심 인용 — 부트시퀀스** — `main.cpp:46-66`:
```cpp
#define INI_FILE_PATH "../../../Data/config.ini"
// ...
minIni* ini = new minIni(INI_FILE_PATH);
// Motion Manager 초기화 (CM730 핸드셰이크)
if(MotionManager::GetInstance()->Initialize(&cm730) == false) return 0;
MotionManager::GetInstance()->LoadINISettings(ini);
Walking::GetInstance()->LoadINISettings(ini);          // <<< [Walking Config] 로드

MotionManager::GetInstance()->AddModule((MotionModule*)Walking::GetInstance());
LinuxMotionTimer *motion_timer = new LinuxMotionTimer(MotionManager::GetInstance());
motion_timer->Start();                                  // 8ms RT 타이머 시작
DrawIntro(&cm730);
MotionManager::GetInstance()->SetEnable(true);
```

런타임 ini 파일(`robotis/Data/config.ini`)은 **현재 백업본에는 존재하지 않는다** — 공장 출하 시 사용자가 walk_tuner 로 생성/저장하도록 의도된 듯. 따라서 **C++ 생성자 기본값이 사실상 출하 walking 튜닝**이다.

---

### 1.4 `robotis/Linux/project/walk_tuner/cmd_process.cpp` (TUI)

**경로**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/walk_tuner/cmd_process.cpp`

**역할**: ncurses TUI. 28개 행에 27개 walking 파라미터 + 1개 명령행을 표시한다. 화살표키 이동 + `[`/`]` 감/증 + `{`/`}` ×10 단계로 조정.

**대표 TUI 라벨** — `cmd_process.cpp:201-228`:
```
Walking Mode(on/off)         X offset(mm)              Y offset(mm)
Z offset(mm)                 Roll(x) offset(degree)    Pitch(y) offset(degree)
Yaw(z) offset(degree)        Hip pitch offset(degree)  Auto balance(on/off)
Period time(msec)            DSP ratio                 Step forward/back ratio
Step forward/back(mm)        Step right/left(mm)       Step direction(degree)
Turning aim(on/off)          Foot height(mm)           Swing right/left(mm)
Swing top/down(mm)           Pelvis offset(degree)     Arm swing gain
Balance knee gain            Balance ankle pitch gain  Balance hip roll gain
Balance ankle roll gain      P gain                    I gain                    D gain
```

---

## 2. Algorithm (inferred from source)

### 2.1 Family

폐형식(closed-form) **sinusoidal ZMP gait** + 다리 6-DOF 해석적 역기구학(IK).

- **궤적 생성기**: 모든 6축(좌·우 발 X/Y/Z + 3 자세각) 이 `wsin()` 의 다중 호출 조합이다 → `Walking.cpp:149-152, 421-489`.
- **IK**: hip-yaw → ankle-roll까지 닫힌 해석해(`Walking.cpp:154-231`). knee 는 `acos((R² − T² − C²) / (2·T·C))` 의 cosine law로 직접 구한다.
- **상태 추적**: 시간 `m_Time ∈ [0, PERIOD_TIME)`. 매 호출마다 +8 ms.

### 2.2 4-Phase model

`m_Time` 을 기준으로 PHASE0~PHASE3 사이를 순회:

```
시간:    0 ────── SSP_Start_L ─ SSP_End_L ──── SSP_Start_R ─ SSP_End_R ─── PERIOD_TIME
phase:   PHASE0           PHASE1                    PHASE2                  PHASE3
의미:    DSP2→SSP_L      SSP_L                     DSP1→SSP_R              SSP_R
                                                     (= phase 시작 시 m_Time = m_Phase_Time2)
```

- `m_Phase_Time1 = (SSP_End_L + SSP_Start_L) / 2`         # SSP_L 중심
- `m_Phase_Time2 = (SSP_Start_R + SSP_End_L) / 2`         # DSP 중심
- `m_Phase_Time3 = (SSP_End_R + SSP_Start_R) / 2`         # SSP_R 중심

핵심 점프 포인트(`Walking.cpp:389-417`): `m_Time` 이 phase 경계 ± TIME_UNIT/2 범위에 들어오면 `update_param_time/move/balance` 를 재호출하고, `m_Ctrl_Running == false` 이고 입력 명령이 0 이면 `m_Real_Running = false` 로 정지한다 — **정지 시점은 양다리가 지면에 있는 순간(DSP)만으로 제한**된다.

### 2.3 Endpoint composition

각 발의 (x, y, z, roll, pitch, yaw) 6개 좌표를 다음 합으로 만든다 — `Walking.cpp:421-510`:

```
x_swap = wsin(t, T/2, π,   X_SWAP_AMP,    0)               # X 본체 sway
y_swap = wsin(t, T,   0,   Y_SWAP_AMP,    0)               # Y 본체 sway
z_swap = wsin(t, T/2, 3π/2, Z_SWAP_AMP,   Z_SWAP_AMP)      # 본체 위아래 보핑

x_move_{r,l} = ±wsin(t, T_ssp, π/2 + ..., X_MOVE_AMP, 0)   # 발이 앞뒤로 진행
y_move_{r,l} = ±wsin(t, T_ssp, π/2 + ..., Y_MOVE_AMP, Y_AMP_SHIFT)
z_move_{r,l} =  wsin(t, T_ssp/2, π/2 + ..., Z_MOVE_AMP, Z_AMP_SHIFT)   # 발이 위로 들리는 곡선
c_move_{r,l} = ±wsin(t, T_ssp, π/2 + ..., A_MOVE_AMP, A_AMP_SHIFT)     # yaw

# 합성 (오른발 예시)
ep[0..5] = (x_swap + x_move_r + X_OFFSET,
            y_swap + y_move_r - Y_OFFSET/2,
            z_swap + z_move_r + Z_OFFSET,
            a_swap + a_move_r - R_OFFSET/2,
            b_swap + b_move_r + P_OFFSET,
            c_swap + c_move_r - A_OFFSET/2)
```

좌발은 X/Y 부호가 +, Y_OFFSET 부호도 + (`Walking.cpp:505-510`).

### 2.4 Inverse Kinematics

`computeIK()` 는 hip 위치에서 발끝까지의 동차 변환 `Tad` 를 만들고, **6 개 조인트각을 닫힌 해석해**로 푼다:

1. **Knee**: `_Rac = |Tad.translation|`; `knee = acos((R² − THIGH² − CALF²) / (2·THIGH·CALF))`.
2. **Ankle Roll**: `Tda = Tad⁻¹` 에서 `_k, _l` 계산 → `acos(_m)`.
3. **Hip Yaw, Hip Roll, Hip Pitch, Ankle Pitch**: `Tac = Tad · Tdc⁻¹` 에서 atan2 로 추출.

링크 길이는 `Kinematics::{LEG_LENGTH, THIGH_LENGTH, CALF_LENGTH, ANKLE_LENGTH}` 상수에서 가져온다.

### 2.5 Pelvis offset (골반 보정)

`Walking.cpp:257-258, 451-452, 477-478`:
- `m_Pelvis_Offset = PELVIS_OFFSET × MX28::RATIO_ANGLE2VALUE` (deg → raw counts)
- `m_Pelvis_Swing  = m_Pelvis_Offset × 0.35`
- SSP_L 동안 좌 hip-roll 에 `+Pelvis_Swing/2`, 우 hip-roll 에 `−Pelvis_Offset/2` 가 추가됨 — 이는 IK 출력 다음에 모터 raw 값에 직접 가산되는 후처리.

### 2.6 Arm swing

`Walking.cpp:526-535`:
```cpp
if(m_X_Move_Amplitude == 0) {
    angle[12] = 0;  angle[13] = 0;
} else {
    angle[12] = wsin(m_Time, m_PeriodTime, PI * 1.5, -m_X_Move_Amplitude * m_Arm_Swing_Gain, 0);
    angle[13] = wsin(m_Time, m_PeriodTime, PI * 1.5,  m_X_Move_Amplitude * m_Arm_Swing_Gain, 0);
}
```
오른팔과 왼팔이 X step amplitude 에 비례하며 정확히 180° 위상차로 흔들린다.

### 2.7 HIP_PITCH_OFFSET application

`Walking.cpp:564-565`:
```cpp
else if(i == 2 || i == 8) // R_HIP_PITCH or L_HIP_PITCH
    offset -= (double)dir[i] * HIP_PITCH_OFFSET * MX28::RATIO_ANGLE2VALUE;
```
즉, `HIP_PITCH_OFFSET (deg)` 은 IK 결과에 더해지는 **정적 자세 보정** — 본체를 약간 앞으로 기울이는 효과. **deg 단위**로 들어오며 모터 raw counts 로 변환된다.

---

## 3. Factory walking parameters (CRITICAL)

### 3.1 Source A — C++ 생성자 기본값 (사실상 출하 walking 튜닝)

`Walking.cpp:23-78` 에서 추출 (단위 표기는 `Walking.h` + Walking.cpp 의 update_param_* 변환에서 추론):

| Key                       | Value           | Unit          |
|---------------------------|-----------------|---------------|
| X_OFFSET                  | -10             | mm            |
| Y_OFFSET                  | 5               | mm            |
| Z_OFFSET                  | 20              | mm            |
| R_OFFSET (roll)           | 0               | deg           |
| P_OFFSET (pitch)          | 0               | deg           |
| A_OFFSET (yaw)            | 0               | deg           |
| HIP_PITCH_OFFSET          | 13.0            | deg           |
| PERIOD_TIME               | 600             | ms            |
| DSP_RATIO                 | 0.1             | —             |
| STEP_FB_RATIO             | 0.28            | —             |
| Z_MOVE_AMPLITUDE          | 40              | mm (foot lift)|
| Y_SWAP_AMPLITUDE          | 20.0            | mm            |
| Z_SWAP_AMPLITUDE          | 5               | mm            |
| PELVIS_OFFSET             | 3.0             | deg           |
| ARM_SWING_GAIN            | 1.5             | —             |
| BALANCE_KNEE_GAIN         | 0.3             | —             |
| BALANCE_ANKLE_PITCH_GAIN  | 0.9             | —             |
| BALANCE_HIP_ROLL_GAIN     | 0.5             | —             |
| BALANCE_ANKLE_ROLL_GAIN   | 1.0             | —             |
| P_GAIN                    | 32              | counts        |
| I_GAIN                    | 0               | counts        |
| D_GAIN                    | 0               | counts        |
| X_MOVE_AMPLITUDE          | 0 (initial)     | mm            |
| Y_MOVE_AMPLITUDE          | 0 (initial)     | mm            |
| A_MOVE_AMPLITUDE          | 0 (initial)     | deg           |
| A_MOVE_AIM_ON             | false           | bool          |
| BALANCE_ENABLE            | true            | bool          |

### 3.2 Source B — `tutorial/action_script/config.ini` (대안 튜닝 셋)

**경로**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/config.ini`

이 ini 가 백업본 안에서 **유일하게 `[Walking Config]` 섹션을 포함**한다 — verbatim 인용:

```ini
[Walking Config]
x_offset                    = 0.0;
y_offset                    = 5.0;
z_offset                    = 10.0;
a_offset                    = 0.0;
p_offset                    = 0.0;
r_offset                    = 0.0;
period_time                 = 600.0;
dsp_ratio                   = 0.1;
z_move_amplitude            = 35.0;
balance_knee_gain           = 0.2;
balance_ankle_pitch_gain    = 0.6;
balance_hip_roll_gain       = 0.6;
balance_ankle_roll_gain     = 1.2;
y_swap_amplitude            = 19.0;
z_swap_amplitude            = 6.0;
arm_swing_gain              = 0.8;
pelvis_offset               = 10;
hip_pitch_offset            = 60;
```

**주의**: 이 ini 의 키 이름 일부는 `LoadINISettings()` 가 인식하는 이름과 다르다 — `LoadINISettings` 는 `pitch_offset` / `roll_offset` / `yaw_offset` / `foot_height` / `swing_right_left` / `swing_top_down` 을 읽지만 (`Walking.cpp:92-110`), 이 ini는 `p_offset`/`r_offset`/`a_offset`/`z_move_amplitude` 를 쓴다. **즉 이 ini 의 일부 키들은 LoadINISettings 가 인식하지 못해 무시된다** — 결과적으로 action_script 는 일부 파라미터가 ini, 일부는 C++ 기본값을 쓰는 하이브리드가 된다.

실제로 읽힐 값 (LoadINISettings 가 인식하는 키만 추림):
- `x_offset = 0.0`, `y_offset = 5.0`, `z_offset = 10.0` ← 인식됨 (3.1 의 -10/5/20 을 0/5/10 으로 덮어씀)
- `period_time = 600.0`, `dsp_ratio = 0.1` ← 인식됨 (변경 없음)
- `balance_*_gain` 4개 ← 인식됨 (0.2/0.6/0.6/1.2 로 덮어씀)
- `arm_swing_gain = 0.8` ← 인식됨 (1.5 → 0.8)
- `pelvis_offset = 10`, `hip_pitch_offset = 60` ← 인식됨
- `p_offset / r_offset / a_offset` ← **무시됨** (생성자 0 유지)
- `z_move_amplitude = 35.0` ← **무시됨** (`foot_height` 가 정답 키). 생성자 40 유지
- `y_swap_amplitude / z_swap_amplitude` ← **무시됨** (`swing_right_left`, `swing_top_down` 이 정답 키). 생성자 20/5 유지

**결론**: 이 ini 는 데모용으로 보수적으로 튜닝됐지만 키 이름 오류 때문에 부분만 적용된다. 신뢰성 있는 출하 walking 튜닝은 **3.1 의 C++ 생성자 값**이다.

### 3.3 Source C — `robotis/Data/config.ini` (runtime, 부재)

`walk_tuner/main.cpp:13` 의 `#define INI_FILE_PATH "../../../Data/config.ini"` 이 가리키는 메인 런타임 ini 는 **백업본에 존재하지 않는다** (`/firmware-backups/sda1-rootfs/robotis/Data/` 에는 mp3 와 motion_{1024,4096}.bin 만 있음). 출하 이미지에서 사용자가 처음 부팅 후 walk_tuner 로 `save` 했을 때 생성되는 파일로 보인다.

---

## 4. Diff table vs `app/core/forge-core/src/walk/params.rs`

**Darwin defaults 출처**: `/Users/bbikiming/Documents/vibe_coding/Darwin/app/core/forge-core/src/walk/params.rs:60-85`

> **단위 변환 주의**: Darwin 은 **SI 단위(m, rad)** 를 사용, 펌웨어는 **mm, deg**. 비교 시 환산.
> - `x_offset: -0.010 m` (Darwin) = `-10 mm` (firmware) → 일치
> - `hip_pitch_offset_deg` 은 양쪽 다 deg 라 동일 단위

| Parameter | Factory C++ ctor (Walking.cpp:23-78) | action_script ini (효과적용 후) | Darwin (params.rs:60-85) | Match? | Notes |
|---|---|---|---|---|---|
| **x_offset** | -10 mm | 0 mm (덮어씀) | -0.010 m = -10 mm | OK vs ctor | action_script 은 데모용으로 0 사용 |
| **y_offset** | 5 mm | 5 mm | 0.005 m = 5 mm | OK | 모두 일치 |
| **z_offset** | 20 mm | 10 mm (덮어씀) | 0.020 m = 20 mm | OK vs ctor | action_script 은 보수적 |
| **roll_offset** | 0 deg | 0 (무시) | 0.0 rad = 0 | OK | |
| **pitch_offset** | 0 deg | 0 (무시) | 0.0 rad = 0 | OK | |
| **yaw_offset** | 0 deg | 0 (무시) | 0.0 rad = 0 | OK | |
| **hip_pitch_offset_deg** | 13.0 deg | 60 (덮어씀) | 13.0 deg | OK vs ctor | **action_script 의 60 deg 는 walk_tuner 키 매핑상 인식됨 — 데모는 더 깊은 무릎-앞숙임 자세를 쓴다** |
| **period_time_ms** | 600 ms | 600 ms | 600.0 ms | OK | 모두 일치 |
| **dsp_ratio** | 0.1 | 0.1 | 0.1 | OK | 모두 일치 |
| **step_forward_back_ratio** | 0.28 | (ini 키 없음 — ctor 유지) | 0.28 | OK | 모두 일치 |
| **foot_height** (Z_MOVE_AMPLITUDE) | 40 mm | 40 mm (z_move_amplitude 무시됨) | 0.04 m = 40 mm | OK | |
| **swing_right_left** (Y_SWAP_AMPLITUDE) | 20.0 mm | 20.0 mm (무시) | 0.020 m = 20 mm | OK | |
| **swing_top_down** (Z_SWAP_AMPLITUDE) | 5 mm | 5 mm (무시) | 0.005 m = 5 mm | OK | |
| **pelvis_offset_deg** | 3.0 deg | 10 deg (덮어씀) | 3.0 deg | OK vs ctor | |
| **arm_swing_gain** | 1.5 | 0.8 (덮어씀) | 1.5 | OK vs ctor | |
| **balance_hip_roll_gain** | 0.5 | 0.6 (덮어씀) | 0.5 | OK vs ctor | |
| **balance_knee_gain** | 0.3 | 0.2 (덮어씀) | 0.3 | OK vs ctor | |
| **balance_ankle_roll_gain** | 1.0 | 1.2 (덮어씀) | 1.0 | OK vs ctor | |
| **balance_ankle_pitch_gain** | 0.9 | 0.6 (덮어씀) | 0.9 | OK vs ctor | |
| **p_gain** | 32 | (ini 키 없음) | 32 | OK | |
| **i_gain** | 0 | (ini 키 없음) | 0 | OK | |
| **d_gain** | 0 | (ini 키 없음) | 0 | OK | |
| `X_MOVE_AMPLITUDE` (runtime input) | 0 | — | (없음 — 별도 runtime input) | — | UI 입력. params 가 아님 |
| `Y_MOVE_AMPLITUDE` (runtime input) | 0 | — | (없음) | — | UI 입력 |
| `A_MOVE_AMPLITUDE` (runtime input) | 0 | — | (없음) | — | UI 입력 |
| `A_MOVE_AIM_ON` (mode flag) | false | — | (없음 — to be added) | (missing in Darwin) | Aim-mode turn yaw 부호 반전 — Darwin 에 누락 |
| `BALANCE_ENABLE` (runtime flag) | true | — | (없음 — 별도 IMU enable flag) | — | imu.rs 에 별도로 다뤄야 함 |

### 4.1 핵심 결론

1. **Darwin `WalkParams::default()` 는 C++ 생성자(Source A)와 100% 일치한다.** 모든 22 개 튜닝 파라미터에 부합한다. (단위 변환은 정확하게 적용됨: m↔mm, rad↔deg)
2. action_script ini (Source B) 는 데모용 보수적 튜닝이며, 일부 키 이름 오류로 부분 적용된다. Darwin 은 이 셋이 아닌 **출하 기본값**을 따라야 한다 — 옳은 선택.
3. **Darwin 에 누락된 항목 1개**: `A_MOVE_AIM_ON` (turn-aim mode flag). 보행 중 회전 시 발 끝점 yaw 방향 결정에 영향 (Walking.cpp:282-297). 향후 Darwin 에 추가 필요.
4. **Darwin 에 누락된 자세 기준 데이터**: 팔 초기 자세값 — `R_SHOULDER_PITCH = -48.345`, `L_SHOULDER_PITCH = 41.313`, `R_SHOULDER_ROLL = -17.873`, `L_SHOULDER_ROLL = 17.580`, `R_ELBOW = 29.300`, `L_ELBOW = -29.593` (`Walking.cpp:55-60`) — walking 자세의 기초 자세. WalkParams 의 외부에 살아도 되지만 Walking 클래스 초기 자세에는 들어가야 한다.

---

## 5. IMU feedback integration

### 5.1 IMU 읽기 경로

**위치**: `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/MotionManager.cpp:246-247`

```cpp
MotionStatus::FB_GYRO = m_CM730->m_BulkReadData[CM730::ID_CM].ReadWord(CM730::P_GYRO_Y_L) - m_FBGyroCenter;
MotionStatus::RL_GYRO = m_CM730->m_BulkReadData[CM730::ID_CM].ReadWord(CM730::P_GYRO_X_L) - m_RLGyroCenter;
```

- `FB_GYRO` = forward/backward gyro (= GYRO_Y) — pitch rate
- `RL_GYRO` = right/left gyro (= GYRO_X) — roll rate
- 각각 자이로 바이어스(`m_FBGyroCenter`, `m_RLGyroCenter`) 를 뺀 raw counts 값 (전역 정수, MotionStatus.cpp:13-14 에 정의)

### 5.2 적용 위치

`Walking::Process()` 마지막 단계 (`Walking.cpp:571-599`). IK 가 결과로 만든 `outValue[0..11]` 12 개 raw counts 에 다음을 가산:

| Joint slot | Gain × Gyro | 적용 부호 |
|---|---|---|
| outValue[1] R_HIP_ROLL | `RL_GYRO × BALANCE_HIP_ROLL_GAIN` | += dir[1] × (...) |
| outValue[7] L_HIP_ROLL | `RL_GYRO × BALANCE_HIP_ROLL_GAIN` | += dir[7] × (...) |
| outValue[3] R_KNEE | `FB_GYRO × BALANCE_KNEE_GAIN` | -= dir[3] × (...) |
| outValue[9] L_KNEE | `FB_GYRO × BALANCE_KNEE_GAIN` | -= dir[9] × (...) |
| outValue[4] R_ANKLE_PITCH | `FB_GYRO × BALANCE_ANKLE_PITCH_GAIN` | -= dir[4] × (...) |
| outValue[10] L_ANKLE_PITCH | `FB_GYRO × BALANCE_ANKLE_PITCH_GAIN` | -= dir[10] × (...) |
| outValue[5] R_ANKLE_ROLL | `RL_GYRO × BALANCE_ANKLE_ROLL_GAIN` | -= dir[5] × (...) |
| outValue[11] L_ANKLE_ROLL | `RL_GYRO × BALANCE_ANKLE_ROLL_GAIN` | -= dir[11] × (...) |

**MX-28 4096 해상도** 빌드(`#else` 브랜치) 일 때는 게인을 **×4 곱한다**. 1024 해상도(기존 op1) 빌드는 그대로. Darwin 은 4096 해상도(OP2) 타겟이므로 **유효 게인은 위 값의 4배**가 정답.

### 5.3 Update frequency

**8 ms** (= MotionModule::TIME_UNIT, `MotionModule.h:24`).
- `LinuxMotionTimer` 가 `pthread_create` + `SCHED_RR` + `priority=31` 실시간 스레드를 띄우고, `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, ...)` 으로 절대시각 기준으로 정확히 8ms 간격 호출 (`LinuxMotionTimer.cpp:23-50`).
- 8 ms × 125 cycles/s = **125 Hz** 보행 loop.
- `PERIOD_TIME = 600 ms` 기본값에서는 한 보행 사이클당 75 회 `Process()` 호출.

### 5.4 결정적/비결정적 관찰

- IMU 읽기는 **bulk read** 패킷에서 추출 — `MotionManager::Process()` 가 매 8ms 마다 CM730 한 패킷으로 12 모터의 위치 + IMU(gyro X/Y/Z, accel X/Y/Z) 를 같이 가져온다.
- accel(`FB_ACCEL`, `RL_ACCEL`) 은 `Walking.cpp` 에서 사용되지 않음. balance feedback 은 **자이로 단일 소스**.
- 따라서 Darwin 의 IMU 보정도 **자이로 적분 없이 raw 자이로 P 제어 그대로** 가 출하 명세에 부합.

---

## 6. What this means for Darwin

### 6.1 채택 권고 (Darwin 기본값 = 출하 명세)

- 현재 `WalkParams::default()` 는 출하 명세 100% 충실. **유지**.
- IMU 보정도 **자이로 raw × gain** 의 단순 P 제어를 유지. 임의의 LPF / 적분 / 칼만 추가는 출하 명세를 벗어남.
- balance gain 들 (0.5/0.3/1.0/0.9) 은 **MX-28 4096 해상도 빌드에서 ×4 적용** 필요 — 이 부분이 Darwin 포팅에서 누락됐는지 확인 필요(아래 6.3 참조).

### 6.2 추가 필요 항목 (params.rs 에 누락)

| 누락 | 출하 위치 | 권고 |
|---|---|---|
| `A_MOVE_AIM_ON: bool` | Walking.cpp:282-297 | turn-aim mode 미구현. Darwin 에 추가 |
| 팔 초기 자세 6 개 (R/L SHOULDER P/R, R/L ELBOW) | Walking.cpp:55-60 | walking 시작 자세. WalkPose 별도 |
| 팔 P_GAIN = 8 (4 다리 P_GAIN 32 와 분리) | Walking.cpp:72-77 | 다리/팔/머리 슬로프와 게인이 분리됨 |
| EXTRASOFT slope 설정 (shoulder, elbow, head_pan) | Walking.cpp:64-70 | "soft" 응답 자세 — Darwin 도 보행 자세는 EXTRASOFT 가 자연스러움 |

### 6.3 Darwin 포팅 잠재 버그 (확인 필요)

1. **MX-28 해상도 분기**: 펌웨어는 `#ifdef MX28_1024` / `#else` 로 balance gain 을 ×4 또는 그대로 적용한다 (`Walking.cpp:575-599`). **Darwin engine.rs 가 이 ×4 보정을 적용하는지 확인 필요** — 누락 시 IMU 보정이 1/4 강도로 작동하여 보행이 흔들릴 수 있다.
2. **HIP_PITCH_OFFSET 단위**: Darwin params.rs 는 `hip_pitch_offset_deg: f64`. 펌웨어는 `HIP_PITCH_OFFSET × MX28::RATIO_ANGLE2VALUE` 로 raw counts 환산 후 모터값에 직접 가산. **Darwin engine.rs 가 deg→raw 환산을 정확히 수행하는지 확인 필요**.
3. **PELVIS_OFFSET 의 0.35 swing 배율**: `m_Pelvis_Swing = m_Pelvis_Offset × 0.35` (Walking.cpp:258). 이 magic number 0.35 가 Darwin 에 반영됐는지 확인 필요.
4. **정지 조건**: Walking 은 **DSP 구간(PHASE0 / PHASE2)** 에서만 `m_Real_Running = false` 로 갈 수 있다 (`Walking.cpp:374-388, 396-411`). 즉 `Stop()` 호출 후에도 즉시 멈추지 않고 다음 양다리 지면 시점까지 계속 걷는다. Darwin engine.rs 가 이 안전 정지 로직을 따르는지 확인 필요.
5. **phase 시각 점프**: PHASE2 진입 시 `m_Time = m_Phase_Time2` 로 강제 점프(`Walking.cpp:397`). 위상 정확성 보장용. Darwin 에 누락 시 walking이 점진적으로 phase drift 한다.

### 6.4 walking-algorithm-design.md 단절 진단 (재검증)

[walking-algorithm-design.md:45-51](../architecture/walking-algorithm-design.md#파이프라인-단절-진단) 의 진단 3 점:

| # | 단절 | 출하 펌웨어 대조 |
|---|---|---|
| 1 | WalkLab.swift 가 pose 를 walkReady 고정 | 펌웨어는 매 8ms `m_Joint.SetValue(...)` 로 갱신. UI 가 reactor 가 되어야 함 |
| 2 | Kinematics.swift Leg IK 부재 | 펌웨어는 `Walking::computeIK()` 79 lines (Walking.cpp:154-231) 직접 포팅 가능 |
| 3 | engine.rs phase 무관 sin파, 골반 미계산 | 펌웨어는 4-phase + endpoint composition 명확. 4-phase logic 도입 필수 |

세 단절 모두 펌웨어 코드에서 정확한 대응부가 존재한다 — 직접 이식만 하면 됨.

---

## 7. Evidence (cited paths)

1. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/Walking.h` — 클래스 정의, 31 공용 파라미터
2. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MotionModule.h` — TIME_UNIT = 8 ms
3. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/MotionStatus.h` — FB_GYRO, RL_GYRO 정의
4. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/include/JointData.h` — P_GAIN_DEFAULT = 32, I_GAIN_DEFAULT = 0, D_GAIN_DEFAULT = 0
5. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/modules/Walking.cpp` — 전체 구현 (624 lines): 생성자, wsin, computeIK, update_param_*, Process, IMU balance
6. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/MotionManager.cpp` — IMU 읽기 line 246-247
7. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Framework/src/motion/MotionStatus.cpp` - 전역 IMU 변수 초기값
8. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/build/LinuxMotionTimer.cpp` — RT 8 ms 타이머 구현 (priority 31, SCHED_RR, clock_nanosleep ABSTIME)
9. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/walk_tuner/main.cpp` — INI 로드, MotionTimer 시작 부트시퀀스
10. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/walk_tuner/cmd_process.h` — 27 TUI 행 enum
11. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/walk_tuner/cmd_process.cpp` — 인터랙티브 TUI, 파라미터 표시·증감 로직
12. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/demo/main.cpp` — Walking::LoadINISettings 호출 + AddModule
13. `/Users/bbikiming/Documents/vibe_coding/Darwin/firmware-backups/sda1-rootfs/robotis/Linux/project/tutorial/action_script/config.ini` — **유일하게 [Walking Config] 섹션을 가진 ini** (절 3.2 의 verbatim 인용)
14. `/Users/bbikiming/Documents/vibe_coding/Darwin/app/core/forge-core/src/walk/params.rs` — Darwin 측 WalkParams + Default 구현 (비교 대상)
15. `/Users/bbikiming/Documents/vibe_coding/Darwin/docs/architecture/walking-algorithm-design.md` — 알고리즘 설계 명세 (단절 진단)
