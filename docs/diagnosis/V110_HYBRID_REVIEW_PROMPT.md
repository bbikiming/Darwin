# DarwinForge v1.10 Hybrid B+A 자이로 보정 — 간략 검수 요청

> GPT/Claude/Gemini 등에 복사-붙여넣기용. 변경 내용 + 알고리즘 확인 + 위험 평가.

---

## 1. 컨텍스트 (1줄)

ROBOTIS DARwIn-OP humanoid robot 의 walking balance corrector — sparse keyframe (10Hz step) + 5Hz IMU 환경에서 종전 P-control 이 oscillation 유발해 사용자 보고 "더 뒤뚱거림". 시뮬 + 데이터 분석 후 **Hybrid B+A** algorithm 적용.

---

## 2. v1.10 변경 요약

| 항목 | 종전 (v1.9.x) | 신규 (v1.10) |
|---|---|---|
| Algorithm | P-control + LPF + deadband | **Hybrid B+A** (slow EMA + phase-locked residual) |
| Default intensity level | 2 (×1.0 ROBOTIS) | **3 (×1.5)** — random search 최적 |
| `anklePitchGain` | 0.9 | **1.5** — sagittal 회복 강화 |
| `ankleRollGain` | 1.0 | **0.5** — lateral 안정성 |
| IMU polling | runTelemetryLoop 안 (200ms, 89.8% duplicate) | **전용 50ms Task** (20Hz) |
| `correctorIntensityLevel` init | didSet 호출 안 됨 → corrector 그대로 default | init 에서 `makeCorrector(level:)` 명시 호출 |

---

## 3. Hybrid B+A 알고리즘 (핵심 식)

```
입력: imuRollDeg, imuPitchDeg, elapsedMs (walking cycle 시작부터 ms),
     periodMs (walking cycle period), state (caller-side EMA state)

# B (Slow drift): 사용자 robot 의 chronic pitch bias (-12.89° 측정) 자동 보정
α = 1 - exp(-0.2 / 10.0)  # ≈ 0.02 (5Hz IMU, tau 10s)
state.pitchEma = α × imuPitchDeg + (1-α) × state.pitchEma
state.rollEma  = α × imuRollDeg  + (1-α) × state.rollEma
slowPitchDelta = -1.0 × state.pitchEma  # drift 반대
slowRollDelta  = -1.0 × state.rollEma

# A (Phase-locked): walking 의 의도된 sway (5° × sin) 제거
if periodMs > 0:
    expectedPitch = 5.0° × sin(2π × elapsedMs / periodMs)
else:
    expectedPitch = 0
expectedRoll = 0  # ROBOTIS 가정: lateral 평균 0
residualPitch = (imuPitchDeg - state.pitchEma) - expectedPitch
residualRoll  = (imuRollDeg  - state.rollEma)  - expectedRoll
fastPitchDelta = -0.27 × residualPitch  # ROBOTIS internal_gain × anklePitchGain
fastRollDelta  = -0.27 × residualRoll

# Combined → ROBOTIS sensoryFeedback 식
effective_pitch_err = slowPitchDelta + fastPitchDelta
effective_roll_err  = slowRollDelta  + fastRollDelta
corrections = BalanceCorrector.corrections(effective_*_err)

# corrections 는 8 관절 (R/L hipRoll/knee/anklePitch/ankleRoll) delta
# 각 delta ±15° clamp + ramp 0..1초 점진 적용
```

### Hybrid Disabled fallback
`balanceCorrector.enableHybrid = false` 시 → slow = 0, fast = imu (기존 P-control 등가)

### State stale guard
`now - state.lastUpdateAt > 5s` → EMA reset (이전 stale data 누적 방지)

---

## 4. 코드 위치 (review 대상)

```
/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/
  ├── BalanceCorrector.swift          (line 60-100: 신규 hybrid fields, 285-405: hybridCorrections + state)
  ├── WalkLabSession.swift            (line 137: intensity default 3,
  │                                    line 437: init makeCorrector,
  │                                    line 1530-1600: applyBalanceCorrectionIfEnabled hybrid 호출)

/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Sources/DarwinForgeUI/
  └── ConnectionStore.swift           (line 1114-1170: startTelemetry + imuPollTask + runImuLoop)

/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Tests/DarwinForgeUITests/
  └── WalkLabFallPreventionTests.swift (line 535-625: 5 신규 hybrid 테스트)
```

---

## 5. 시뮬 예측 효과 (재확인)

| Metric | P-current | Hybrid B+A |
|---|---|---|
| mean signed pitch | −8.98° | **−0.20°** (45배 개선) |
| mean \|pitch\| | 9.02° | 3.98° |
| max tilt | 16.08° | 13.27° |
| recovery | 0.05s | 0.00s |
| osc RMS | 4.38 | 4.57 (수용 가능) |

근거: 1,613 walking samples × 21 sessions LIPM simulation + 350 trial parameter search.

---

## 6. 검증 상태

- ✅ Swift test **349/349 pass** (5 hybrid 테스트 신규 + 기존 11건 v1.10 값 업데이트)
- ✅ Build OK (Swift 5.10, macOS 14+)
- ✅ Install + 실행 중
- ⏳ 실 robot 검증 대기 — 새 session 데이터 분석 예정

---

## 7. 검수 질문 (간략)

### Critical
1. **Hybrid B+A 식 자체 정확한가?** Slow EMA + phase-locked residual 결합이 control theory 적으로 타당? 특히 EMA tau 10s + fast gain 0.27 의 조합이 어떤 시스템 dynamics 에서 stable 한가?

2. **expected_pitch = 5° × sin(2π × t / period)** 의 amplitude 가 사용자 robot 의 실제 sway (slowWalk peak 5-8°) 와 일치하는가? robot 별 calibration 필요한가?

3. **State stale 5초 reset** 이 chronic drift 추적과 충돌 가능? 보행 일시 정지 후 재시작 시 EMA 가 갑자기 reset → 새로 chronic drift 학습 시간 (10s) 필요.

### Major
4. **`enableHybrid = true` default** — backward compatibility 측면에서 위험? legacy P-control 사용자는 토글 X 시 자동 hybrid 로 전환.

5. **anklePitchGain 0.9 → 1.5** — sagittal 회복력 1.67배. 사용자 robot 의 mass distribution 변화 (예: arm 들고 보행) 에서 over-correction 위험?

6. **IMU 전용 50ms Task** — USB-TTL half-duplex 에서 joint read + IMU read 동시 시 packet collision 위험. Bus 가 mutex 보호한다고 가정 — 확인 필요?

### Architecture
7. **Long-term**: Robot-side 125Hz Rust loop (Agent 5 권고) 대비 이 Mac-side hybrid 의 한계는? 어느 시점에 architectural pivot 필요?

---

## 8. 관련 문서 (필요 시 참조)

- 종합 진단: `docs/diagnosis/GYRO_BALANCE_ROOT_CAUSE_REPORT.md`
- 시뮬 + experimental matrix: `docs/diagnosis/GYRO_BALANCE_SIMULATION_REPORT.md`
- v1.10 구현 plan: `docs/plan/HYBRID_BALANCE_PLAN.md`
- ROBOTIS oracle: `DARwIn-OP_ROBOTIS_v1.6.0/Framework/src/motion/modules/Walking.cpp:570-600`

**핵심 요청**: 알고리즘의 control-theory 정합성 + Mac-side 5Hz IMU 환경의 fundamental 한계 안에서 hybrid B+A 가 진짜 효과적인지 정직 평가.
