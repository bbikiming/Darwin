# DarwinForge 자이로 기반 보행 보정 시스템 — 외부 검수 요청

> 외부 LLM (GPT, Claude, Gemini 등) 에게 그대로 붙여 넣어 사용하기 위한 프롬프트입니다. 코드 인용 + 실측 데이터 + 시도한 fix history 모두 포함.

---

## 1. 컨텍스트

**프로젝트**: DarwinForge — 한국 ROBOTIS DARwIn-OP / OP2 휴머노이드 로봇을 macOS SwiftUI 앱에서 제어. Rust workspace (`forge-core`, `forge-ffi`) + Swift package (`DarwinForgeUI`) 구조.

**문제**: 보행 (WalkLab) 중 자이로 (IMU) 기반 실시간 자세 보정이 작동 안 함. 사용자 보고:
- "자이로 값을 시각화는 잘 하는데 실제로 모션 보정이 안 되는 것 같다"
- "오히려 더 뒤뚱거린다"
- "여러 fix 적용했지만 여전히 보행이 불안정"

**현재 적용 알고리즘**:
- BalanceCorrector (ROBOTIS Walking.cpp::sensoryFeedback 포팅) — 4 관절 그룹 (hipRoll/knee/anklePitch/ankleRoll) 에 IMU error 비례 delta
- LPF (Low-pass filter, alpha 0.5) + sway deadband (보행 중 2.5°)
- 5단계 사용자 강도 조절 슬라이더 (0 꺼짐 ~ 4 최대 x2.0)
- 데이터 로깅 (JSONL, 50ms tick) + 자동 분석 + 자동 튜닝 추천

---

## 2. 시스템 구조

### 2.1 파일 트리 (핵심)

```
DarwinForge/
├── app/core/
│   ├── forge-core/src/
│   │   ├── controller/cm.rs              # CM-730/740 IMU FFI (10-bit ADC, 부호 정정 v1.7)
│   │   └── walk/params.rs                # ROBOTIS gain default (hipRoll=0.5, knee=0.3, anklePitch=0.9, ankleRoll=1.0)
│   └── forge-ffi/src/lib.rs              # FfiImuRaw struct (u16 raw)
│
└── app/ui/DarwinForge/Sources/
    ├── ForgeCore/
    │   ├── Bus.swift                      # ImuRaw struct (UInt16, rollDeg/pitchDeg/gyroDps accessors)
    │   ├── ImuFilter.swift                # Complementary filter (5Hz polling, tau=0.5s)
    │   └── ForgeError.swift               # FFI error codes
    │
    └── DarwinForgeUI/WalkLab/
        ├── WalkLabSession.swift           # 메인 보행 세션 — tick (50ms) loop, balance corrector apply
        ├── BalanceCorrector.swift         # IMU error → 8 관절 delta 식 (부호 매핑)
        ├── WalkMotionLibrary.swift        # 6 phase keyframe walking page 합성
        ├── WalkLabSession+Types.swift     # BalanceState enum (normal/caution/warning/danger/emergency)
        ├── Components/
        │   ├── CircularGyroMeter.swift    # 원형 자이로 시각화 (g-meter)
        │   ├── GyroCorrectorControls.swift # 5단계 강도 슬라이더 + AutoTunerCard
        │   └── FallPreventionMonitor.swift # 안전 monitoring dashboard
        └── Learning/                      # v1.9 학습 시스템
            ├── WalkSessionSample.swift    # 한 tick (50ms) 데이터 schema
            ├── WalkSessionLogger.swift    # JSONL writer
            ├── WalkSessionAnalyzer.swift  # mean tilt, oscillation, correlation 분석
            ├── WalkSessionAutoTuner.swift # 자동 강도 조정 권고
            └── WalkDataView.swift         # session list + Apple Charts visualization
```

### 2.2 데이터 흐름

```
┌─────────────┐   12 byte burst read   ┌──────────────┐   FFI u16    ┌──────────────┐
│ CM-740 IMU  │ ────────────────────→  │   cm.rs      │ ──────────→  │  Bus.swift    │
│ (10-bit ADC)│                        │ (raw + tilt) │              │  (ImuRaw)     │
└─────────────┘                        └──────────────┘              └───────┬──────┘
                                                                              │ 5Hz polling
                                                                              ▼
┌──────────────────┐     매 50ms tick   ┌──────────────────────────┐  imuFilter
│ WalkLabSession   │ ←────────────────  │ ConnectionStore.imuFilter│  (5Hz CF)
│ - imuRollDeg     │                    │ (complementary filter)   │
│ - imuPitchDeg    │                    └──────────────────────────┘
└────────┬─────────┘
         │ applyBalanceCorrectionIfEnabled(to: pose)
         ▼
┌─────────────────────────────────────┐
│ 1) LPF (alpha 0.5)                  │
│ 2) Deadband (보행 시 2.5°)          │
│ 3) BalanceCorrector.apply()         │
│    → 8 관절 delta                    │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────┐
│ runContinuousWalk → transformPose   │
│  → bus.setPosition (Dynamixel TTL)  │
└─────────────────────────────────────┘
```

---

## 3. 알고리즘 상세

### 3.1 IMU 정정 (v1.7, 2026-05-17)

**Rust cm.rs (확정)**:
- ROBOTIS-OP v1.6.0 official firmware oracle 확인 결과:
  - `CM730::MakeWord` (CM730.cpp:666-675) — **unsigned u16** zero-extend
  - `MotionManager.cpp:73-74` — `m_FBGyroCenter = m_RLGyroCenter = 512`
  - `MotionStatus.h:27-28` — `FALLEN_F_LIMIT = 390, FALLEN_B_LIMIT = 580` (10-bit ADC 0..1023)
  - `MotionManager.cpp:246-249` — `RL_ACCEL = ReadWord(P_ACCEL_X_L)`, `FB_ACCEL = ReadWord(P_ACCEL_Y_L)`

```rust
// cm.rs (정정 후)
pub struct ImuRaw {
    pub gyro_x: u16, pub gyro_y: u16, pub gyro_z: u16,
    pub accel_x: u16, pub accel_y: u16, pub accel_z: u16,
}

impl ImuRaw {
    pub const ADC_CENTER: u16 = 512;

    pub fn roll_degrees(&self) -> f32 {
        let ax = self.accel_x as f32 - 512.0;  // RL (좌우)
        let ay = self.accel_y as f32 - 512.0;
        let az = self.accel_z as f32 - 512.0;
        let denom = (ay.powi(2) + az.powi(2)).sqrt();
        if denom < 1.0 { 0.0 } else { ax.atan2(denom) * 180.0 / PI }
    }

    pub fn pitch_degrees(&self) -> f32 {
        let ax = self.accel_x as f32 - 512.0;
        let ay = self.accel_y as f32 - 512.0;  // FB (앞뒤)
        let az = self.accel_z as f32 - 512.0;
        let denom = (ax.powi(2) + az.powi(2)).sqrt();
        if denom < 1.0 { 0.0 } else { ay.atan2(denom) * 180.0 / PI }
    }
}
```

**검증**: 직립 시 0°, 좌 30° tilt → roll +30°, 앞 30° tilt → pitch +30° (단위 테스트 통과).

### 3.2 BalanceCorrector 부호 매핑

ROBOTIS Walking.cpp 의 `sensoryFeedback` (line 886-908) 식을 doc + URDF + walkReady 패턴 cross-check 후 정정:

```swift
// BalanceCorrector.swift (line 110-170)
public func corrections(rollErrDeg: Double, pitchErrDeg: Double) -> Corrections {
    let m = 0.3 * intensity  // internal_gain × intensity
    
    // Lateral (좌우 CoP shift) — R/L 동일 부호:
    let hipRollBoth     = -m * rollErrDeg * 0.5   // imuRoll + → hipRoll - (왼쪽 lean 회복)
    let ankleRollBoth   = -m * rollErrDeg * 1.0   // 동일 방향, 더 강함
    
    // Sagittal (앞뒤 recovery) — R/L mirror:
    let kneeR           = +m * pitchErrDeg * 0.3   // imuPitch + → R knee + (R 굽힘)
    let kneeL           = -m * pitchErrDeg * 0.3   // L mirror
    let anklePitchR     = +m * pitchErrDeg * 0.9
    let anklePitchL     = -m * pitchErrDeg * 0.9
    
    return Corrections(
        rHipRoll: clamp(hipRollBoth),    lHipRoll: clamp(hipRollBoth),
        rKnee: clamp(kneeR),             lKnee: clamp(kneeL),
        rAnklePitch: clamp(anklePitchR), lAnklePitch: clamp(anklePitchL),
        rAnkleRoll: clamp(ankleRollBoth), lAnkleRoll: clamp(ankleRollBoth)
    )
}

// clamp: ±15°
```

**ROBOTIS gain (params.rs)**:
```rust
balance_hip_roll_gain: 0.5,
balance_knee_gain: 0.3,
balance_ankle_pitch_gain: 0.9,
balance_ankle_roll_gain: 1.0,
internal_gain: -0.3
```

**의도**:
- 로봇이 오른쪽 5° 기울 (`imuRollDeg = +5`) → `hipRollBoth = -0.3 × 1.0 × 5 × 0.5 = -0.75°` (양 다리 모두), `ankleRollBoth = -1.5°` (양 다리 모두)
- → CoP 가 왼쪽으로 이동 → 회복

### 3.3 LPF + Deadband (v1.9.1)

```swift
// WalkLabSession.swift applyBalanceCorrectionIfEnabled
let isWalkingActive = (current != .idle)
let deadband: Double = isWalkingActive ? 2.5 : 1.0

// LPF — alpha 0.5 (time constant 100ms @ 50ms tick)
let alpha = 0.5
correctorFilteredRoll = alpha * imuRollDeg + (1 - alpha) * correctorFilteredRoll
correctorFilteredPitch = alpha * imuPitchDeg + (1 - alpha) * correctorFilteredPitch

// Deadband
let effRoll = abs(correctorFilteredRoll) > deadband
    ? correctorFilteredRoll - copysign(deadband, correctorFilteredRoll)
    : 0.0
let effPitch = abs(correctorFilteredPitch) > deadband
    ? correctorFilteredPitch - copysign(deadband, correctorFilteredPitch)
    : 0.0

let corrected = balanceCorrector.apply(
    to: pose, rollErrDeg: effRoll, pitchErrDeg: effPitch,
    enabled: true, secondsSinceEnable: ramp
)
```

### 3.4 Walking page 합성 (Sparse keyframe)

```swift
// WalkMotionLibrary.swift
// ROBOTIS Walking.cpp 의 phase-based trajectory 를 6 keyframe 으로 sample.
let samplePhases: [Double] = [0.03, 0.18, 0.42, 0.52, 0.68, 0.92]
let cycle = samplePhases.map { phase in
    let timeMs = phase * periodMs  // periodMs: slowWalk 800, normalWalk 600, fastWalk 450
    let pose = robotisWalkingApproxPose(timeMs: timeMs, tuning: tuning)
    return MotionStep(pose: pose, playMs: max(80, periodMs / 6), pauseMs: 0)
}
```

**효과적 sample rate**: 6 phase / cycle = 7.5 ~ 13 Hz (period 따라). ROBOTIS 원본은 **125 Hz** (8 ms loop) — **약 12배 sparse**.

### 3.5 Tick + transformPose + 실 송출

```swift
// WalkLabSession.swift
private func tick() {  // Timer 50ms
    updateImuFromRealOrSim()      // imuRollDeg/Pitch 갱신
    balanceState = BalanceState.from(maxTilt: max(abs(imuRollDeg), abs(imuPitchDeg)))
    appendSessionSampleIfLogging()  // 데이터 logging
    // ... emergency / threshold logic
}

// transformPose closure (cycle 시작 시 정의):
let transformPose: (RobotPose) -> RobotPose = { [weak self] pose in
    self?.applyBalanceCorrectionIfEnabled(to: pose) ?? pose
}

// runContinuousWalk (Task) — 매 step 마다:
let target = await transformPose(rawTarget)  // ← corrector 적용
for joint in target.changedJoints(from: previous) {
    try bus.setPosition(joint, raw: target.raw(joint))  // ← 실 robot 송출
}
```

---

## 4. 실 측정 데이터 (사용자 robot, 실 IMU)

### 4.1 데이터 저장 형식

JSONL, 50ms tick, `~/Library/Application Support/DarwinForge/sessions/`:

```json
{"t":793.7,"preset":"slowWalk","intensityLevel":2,
 "imuRollDeg":-1.65,"imuPitchDeg":-15.34,
 "correctorRollErrDeg":-1.58,"correctorPitchErrDeg":-15.49,
 "balanceState":"normal","imuSource":"real",
 "correctorDeltas":[0, 0, -0.23, +0.23, -0.7, +0.7, 0, 0],
 "batteryVolts":11.9,"motorAvgTemp":45.25}
```

`correctorDeltas` 순서: `[rHipRoll, lHipRoll, rKnee, lKnee, rAnklePitch, lAnklePitch, rAnkleRoll, lAnkleRoll]`

### 4.2 분석 결과 (Python으로 직접 분석)

#### slowWalk (99 samples, 실 robot)
```
imu roll  mean|x|: 2.8°,  peak: 8.6°
imu pitch mean|x|: 14.4°, peak: 18.6°  ← Pitch 매우 큼 (지속적으로 뒤로 누움)
filtered roll  peak: 5.5° (< deadband 6° 이전, < 2.5° 신규)
filtered pitch peak: 18.6°

CORRECTOR DELTAS (실측):
  R/L hipRoll  :  0% active  ❌ ALL ZERO       ← 전혀 작동 안 함 (deadband 큼)
  R/L ankleRoll:  0% active  ❌ ALL ZERO       ← 전혀 작동 안 함
  R/L knee     : 98% active, range [-2.28, +2.28]   ✓
  R/L anklePitch: 98% active, range [-6.83, +6.83]  ✓
```

#### march (77 samples)
```
imu roll  mean|x|: 9.4°, peak: 26.2°
filtered roll peak: 18.7°

CORRECTOR DELTAS:
  R hipRoll  : 48% active, range [-1.91, +0.00]    ← 부호 한 방향만!
  L hipRoll  : 48% active, range [-1.91, +0.00]    ← 부호 한 방향만!
  R/L ankRoll: 48% active, range [-3.82, +0.00]    ← 부호 한 방향만!
  R knee     : 98% active, range [-1.73, +0.00]
  L knee     : 98% active, range [+0.00, +1.73]
```

**관찰된 이상 패턴**:
1. ❌ **slowWalk lateral 보정 0%** — deadband 6° (이전) / 2.5° (현재) 가 sway peak 5.5° 와 충돌
2. ❌ **march 의 lateral 부호 한 방향만** — `[-1.91, 0]` 음수만 (좌우 회복 양쪽 다 있어야 정상)
3. ⚠️ **pitch 지속 bias -14.4°** — 로봇이 보행 중 계속 뒤로 누운 자세로 인식. IMU mounting? 보행 자세 자체?

### 4.3 사용자 보고 증상
- "자이로 시각화는 잘 됨 (CircularGyroMeter 정상 작동)"
- "보정 강도 표준 (level 2) 인데 여전히 뒤뚱거림"
- "오히려 더 흔들리는 느낌"
- "march, slowWalk 둘 다 안정 안 됨"

---

## 5. 시도한 fix history

| 버전 | 변경 | 결과 |
|---|---|---|
| v1.6 | 초기 BalanceCorrector 포팅 (intensity 1.0, deadband 없음) | 보행 중 oscillation 유발 |
| v1.7 (2026-05-17) | cm.rs IMU u16 + 10-bit ADC + axis 정정 (RL=X, FB=Y) | 직립 시 false +52° tilt 해결 ✓ |
| v1.8 | Emergency threshold 15/22/28/30 → **25/35/45/50°** + 3-tick hysteresis | false-positive 정지 줄어듬 ✓ |
| v1.9 | LPF (alpha 0.3) + sway deadband **6°** | Lateral 100% 무력화 ❌ |
| v1.9.1 (현재) | LPF alpha 0.5 + deadband **2.5°** | slowWalk lateral 여전히 0% (peak 5.5° < deadband 2.5° 통과해야 작동인데...) |
| v1.9.2 | timestamp mismatch fix (UI 표시 문제) | 데이터 표시 OK |

**현재 추정**:
- Deadband 2.5° 면 slowWalk 의 5.5° peak 는 일부 통과해야 하는데 100% 0 → **LPF 가 너무 강해서** 5.5° → 1.6° 로 감쇠 → deadband 통과 못함
- LPF alpha 0.5 (50:50 blend) 도 5Hz sampling 에서 sway 1.5Hz 가 매우 감쇠
- march 의 부호 한 방향 = robot 이 한쪽으로만 누적 기울거나, IMU bias 또는 corrector 식이 의도와 다름

---

## 6. 핵심 질문 (검수자에게)

### Critical
1. **BalanceCorrector 부호 매핑이 ROBOTIS Walking.cpp 와 진짜 호환인가?**
   - 우리 식: `hipRollBoth = -0.3 × intensity × rollErrDeg × 0.5` (양 다리 동일 부호)
   - ROBOTIS 원본: `balance[hip_roll] = +dir × -0.3 × (-imuRoll) × hip_roll_gain`
   - dir 매핑 (URDF axis) + (-imuRoll) → goal 차이 계산을 우리가 정확히 derive 했나?
   - march session 의 R hipRoll `[-1.91, 0]` 부호 한 방향이 정상인가?

2. **Sparse keyframe (10Hz) 환경에서 IMU-based balance corrector 가 가능한가?**
   - ROBOTIS 원본은 8ms (125Hz) tight loop. 우리는 6 phase × 100ms playMs.
   - 우리 corrector 는 매 50ms tick (20Hz) 으로 IMU 보고 → transformPose 가 매 step (10Hz) pose 변환.
   - **이 sample rate 에서 LPF + deadband + ROBOTIS gain 식이 정말 작동 가능한가?**
   - 아니면 sparse keyframe 자체를 phase-aware 로 만들어야 하나?

3. **사용자 실 robot 의 pitch 지속 bias -14.4° 의 의미는?**
   - 직립 상태에서도 IMU 가 pitch -14° 보고 = robot 이 실제로 뒤로 누움?
   - 아니면 IMU mounting 또는 axis convention 이 여전히 잘못 되어 있나?
   - 우리 cm.rs roll/pitch_degrees 식이 ROBOTIS DARwIn-OP 의 CM-740 mounting 과 정확히 일치하는가?

### Major
4. **LPF + deadband 가 진짜 정답인가?** 더 나은 접근:
   - Notch filter (walking frequency 1.5Hz 만 제거)?
   - Phase-locked correction (walking cycle 의 expected tilt 와 비교)?
   - Kalman filter?
   - 또는 corrector 를 완전히 다른 알고리즘 (ZMP control 등) 으로?

5. **5단계 사용자 강도 슬라이더 (0..2.0x intensity) 의 정당성**:
   - ROBOTIS default (1.0x) 가 robot 의 100Hz+ loop 에 맞춰진 값. 10Hz sparse 우리 시스템에서 1.0x 가 적절한가?
   - 0.1x 또는 그 이하부터 시작해야 한다는 주장 (critic agent) 도 있었음.

6. **march 보행에서 R hipRoll = -1.91° 만 적용되는 패턴**:
   - 한쪽 방향만 보정 = 의도된 lateral CoP shift 의 일부분만 작동?
   - 또는 IMU 가 항상 한쪽으로만 보고 (robot 이 한쪽으로만 기울)?

### Architecture
7. **데이터 로깅 + 자동 튜닝 시스템 (v1.9 Learning module)** 이 학습 알고리즘으로 적절한가?
   - 현재: oscillation score (zero-crossing rate) + correlation (`-imu_roll vs hip_roll_delta`)
   - 권고 logic: oscillation 높음 + tilt 낮음 → 한 단계 낮춤
   - **이 algorithm 으로 진짜 효과 평가 가능한가?** 더 정확한 metric 은?

---

## 7. 환경 정보

- macOS 14+, Swift 5.10, Rust stable
- Robot: ROBOTIS DARwIn-OP / OP2 (사용자 보고 사항으로는 CM-740 controller, 20 모터 MX-28T)
- IMU: 추정 L3G4200D + ADXL345 계열, 10-bit ADC (raw 0..1023, center 512)
- USB-TTL 통신, baud 1Mbaud, polling 5Hz
- 보행 cycle: 6 phase keyframe @ 600ms (normalWalk) period

---

## 8. 첨부 데이터 (sample)

### slowWalk JSONL 첫 10 samples
```jsonl
{"sessionId":"...","preset":"slowWalk","intensityLevelAtStart":2,"isRealRobot":true,"startTimeIso":"2026-05-17T11:29:00.152Z","appVersion":"1.0.0"}
{"t":50,"imuRollDeg":0.1,"imuPitchDeg":-12.3,"correctorRollErrDeg":0.05,"correctorPitchErrDeg":-11.8,"balanceState":"normal","correctorDeltas":[0,0,-0.18,0.18,-0.53,0.53,0,0],"imuSource":"real"}
{"t":100,"imuRollDeg":-0.5,"imuPitchDeg":-13.7,"correctorRollErrDeg":-0.22,"correctorPitchErrDeg":-12.7,"balanceState":"normal","correctorDeltas":[0,0,-0.19,0.19,-0.57,0.57,0,0],"imuSource":"real"}
...
{"t":793,"imuRollDeg":-1.65,"imuPitchDeg":-15.34,"correctorRollErrDeg":-1.58,"correctorPitchErrDeg":-15.49,"balanceState":"normal","correctorDeltas":[0,0,-0.23,0.23,-0.7,0.7,0,0],"imuSource":"real"}
```

### slowWalk summary.json
```json
{
  "preset": "slowWalk", "sampleCount": 263,
  "intensityLevelUsed": 2, "durationSec": 18.6,
  "meanAbsRoll": 10.16, "meanAbsPitch": 10.71,
  "peakAbsRoll": 27.76, "peakAbsPitch": 21.25,
  "rollStdev": 12.59, "pitchStdev": 6.73,
  "oscillationScore": 0,
  "correctorEffectivenessScore": 0.24,
  "recommendedIntensityLevel": 2,
  "recommendationReason": "안정적 (평균 tilt 10.7°, 진동 0.0Hz) — 현재 강도 유지"
}
```

⚠️ `correctorEffectivenessScore: 0.24` 가 권고 결정의 핵심 metric. 하지만 lateral 0% active 인데 effectiveness 0.24 가 정당한가?

---

## 9. 검수 요청 사항

1. **위 알고리즘 (cm.rs IMU + BalanceCorrector + LPF + deadband + sparse keyframe) 의 critical 결함을 찾아주세요.**
2. **데이터 패턴 (R/L hipRoll 부호 한 방향, lateral 0%, pitch bias -14°) 의 가장 가능성 높은 원인은 무엇인가요?**
3. **현재 sparse keyframe (10Hz) 환경에서 ROBOTIS 식 (125Hz 기준) balance corrector 가 작동 가능한지, 아니면 다른 알고리즘이 필요한지 판단해 주세요.**
4. **즉시 적용 가능한 fix 와 장기 architectural 변경을 분리해서 권고해 주세요.**
5. **데이터 로깅 + 자동 튜닝 시스템 (학습 알고리즘) 이 진짜 효과를 평가하는 metric 으로 적절한지 평가해 주세요.**

코드 인용 (line number 포함) + 수치 검증 + 명확한 결론. 추측보다는 데이터 기반.

---

## 부록 A: 빠른 코드 ref

전체 코드 분석을 위한 핵심 파일:

```bash
# Rust IMU read (oracle: ROBOTIS-OP v1.6.0)
/Users/bbikiming/Documents/vibe_coding/Darwin/app/core/forge-core/src/controller/cm.rs

# Swift 메인 보행 로직
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift

# BalanceCorrector 부호 식
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/BalanceCorrector.swift

# Walking page 합성 (sparse keyframe)
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkMotionLibrary.swift

# 데이터 logging + analyzer
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/

# ROBOTIS-OP v1.6.0 official firmware mirror (oracle)
/Users/bbikiming/Documents/vibe_coding/Darwin/DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/modules/Walking.cpp
/Users/bbikiming/Documents/vibe_coding/Darwin/DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/CM730.cpp
/Users/bbikiming/Documents/vibe_coding/Darwin/DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/MotionManager.cpp
```

## 부록 B: 실 측정 데이터 위치

```bash
~/Library/Application Support/DarwinForge/sessions/
├── 2026-05-17T11-28-42.991Z-march.jsonl       # 보행 sample 로그
├── 2026-05-17T11-28-42.991Z-march.summary.json # 분석 결과
└── ... (총 30 session retention, ~600KB / session)
```

JSONL 형식이라 `jq` / `pandas` 로 분석 가능:
```bash
jq -r '.imuRollDeg' session.jsonl | tail -n +2  # roll 시계열
```

---

**검수자께**: 이 시스템은 실 robot 에서 작동하지 않는 상황입니다. 위 데이터 + 코드를 바탕으로 정직한 진단과 명확한 fix path 를 제시해 주세요. 더 많은 session 데이터가 필요하면 알려주세요.
