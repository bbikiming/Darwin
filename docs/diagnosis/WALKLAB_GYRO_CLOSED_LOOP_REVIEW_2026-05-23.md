# WalkLab 자이로 보정 closed-loop 정밀 리뷰

- 작성일: 2026-05-23
- 사이클: 158 (사용자 명시 요청)
- 대상: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/**`
- 목적: 자이로 기반 보행 보정 시스템 이 **실 robot 에서 제대로 걷도록 수정/보정 하는가** 솔직 점검.

---

## 0. 한 줄 결론

**부분만 작동**. Mac sparse engine 은 closed-loop 가 구성됐으나 **IMU 가 5Hz 라 ROBOTIS 권장 125Hz 의 1/25 속도**. 빠른 자세 변화에 대응 못 함. Onboard mode 는 자이로 보정 자체가 Mac 측에서 robot 으로 전달 안 됨 (송신 schema 누락). 시뮬 외 실 보행 검증 데이터 없음.

---

## 1. 시스템 구성 (현재 상태)

### 1.1 Engine 2 종

```
WalkingEngine (enum):
  case macSparseKeyframe      — Mac 가 keyframe pose 합성, bus.setPosition 송출
  case robotisOnboard         — Mac 가 WalkingEngineCommand 만 송출, robot daemon 이 walk 합성
```

### 1.2 Closed-loop path (Mac sparse engine, 실 robot)

```
[robot IMU]
  ↓ bus.readImu() — runImuLoop (ConnectionStore.swift:1408)
  ↓ 200ms (5Hz) period
[ConnectionStore.imuFilter / lastImuRaw]
  ↓ WalkLabSession+SensorUpdates 가 push (5Hz)
[session.imuRollDeg / imuPitchDeg / lastImuSampleAt]
  ↓
[applyBalanceCorrectionIfEnabled(to: pose)] — WalkLabSession+BalanceCorrection.swift:69
  ↓ freshness gate (250ms~500ms decay)
  ↓ algorithmMode 분기 (off / robotisPControl / hybridBA / observeOnly)
  ↓ ramp + scale
[corrected pose]
  ↓
[runContinuousWalk.sendStep] — WalkLabSession+WalkCycleEngine.swift:90
  ↓ bus.setPosition(joint, raw) (변경된 joint 만)
[실 motor]
```

### 1.3 Onboard mode path

```
[Mac UI slider 변경]
  ↓
[currentWalkingEngineCommand(enabled:)] — WalkLabSession.swift:2083
  ↓ 7 field: enabled, xMm, yMm, aDeg, periodMs, footHeightMm, hipPitchOffsetDeg
[WalkLabOnboardBridge.send] (SSH file write)
  ↓
[robot-side patched demo daemon] (Walking.cpp 의 자체 sensoryFeedback @125Hz)
  ↓
[실 motor]

⚠️ Mac 측 balanceGain / enableBalanceCorrection / correctorIntensityLevel /
   balanceCorrector 결과 — Onboard mode 에서 **전혀 송출 안 됨**.
```

---

## 2. 핵심 발견 (P0 — 보행 신뢰성 직접 영향)

### 2.1 IMU polling 5Hz 가 자이로 보정 closed-loop 에 부족

- **위치**: `ConnectionStore.swift:1392` `runImuLoop(periodNs: 200_000_000)` (200ms = 5Hz)
- **사이클 64**: 종전 50Hz → 5Hz "perf optimization" — UI 자이로 게이지 표시용으로는 충분.
- **문제**:
  - `applyBalanceCorrectionIfEnabled` 의 freshness gate 가 250ms~500ms 감쇠 (line 111-113).
  - 5Hz IMU 의 worst case sample age = 200ms (다음 sample 직전) — 250ms gate 와 **50ms 마진**.
  - bus jitter / serial latency / cpu contention → 실제로는 250ms 빈번히 초과 → 보정 0 으로 감쇠.
  - ROBOTIS 권장 `sensoryFeedback` = **125Hz** (8ms). **현재 5Hz = 25배 느림**.
- **영향**:
  - 0.5초 이상 자세 변화 (slow drift) 는 보정 가능.
  - 0.1초 이내 fast oscillation (실제 낙상 trigger) 은 보정 미흡.
  - "걷다가 흔들리면 즉각 보정" 이 코드상 보장 안 됨.
- **권고**:
  - IMU loop 를 walk 활성 중 50Hz (20ms) 또는 25Hz (40ms) 로 동적 증속.
  - idle 시 5Hz 유지 (perf).
  - 또는 `runContinuousWalk` 의 sendStep 직전 즉시 IMU re-read.

### 2.2 Onboard mode 의 자이로 보정 송신 schema 부재

- **위치**: `WalkingEngine.swift:83` `WalkingEngineCommand` struct.
- **현재 필드**: `enabled, xMm, yMm, aDeg, periodMs, footHeightMm, hipPitchOffsetDeg` (7개).
- **누락 필드**:
  - `balanceGain` (Mac UI slider 0..5)
  - `enableBalanceCorrection` (Mac UI toggle)
  - `correctorIntensityLevel` (Mac UI 5단계 slider)
- **문제**:
  - 사용자가 Onboard mode 에서 자이로 보정 slider 조정 → 시각만 변경 → **robot 반응 동일**.
  - "사이클 145 ApplyScope docstring" 추가 + UI badge `.disabledOnboard` 로 사용자 안내는 됐으나, 실 robot 의 보정 수준은 robot-side daemon 의 hardcoded 값.
- **영향**:
  - Onboard mode 사용자는 Mac UI 의 자이로 보정 조정이 의미 없음.
  - Mac sparse mode 만 자이로 보정 가능 — 사용자 선택 강제.
- **권고**:
  - `WalkingEngineCommand` 에 3 필드 추가 + robot-side patch sscanf 확장.
  - 또는 Onboard mode 의 자이로 보정 UI 를 read-only 로 강제 + 문서 보강.

### 2.3 freshness gate 가 보정 자체 차단 (5Hz IMU + bus jitter 시 자주)

- **위치**: `WalkLabSession+BalanceCorrection.swift:103-119`
- **로직**:
  - age ≥ 500ms: corrections = 0, apply 차단
  - 250 < age < 500: linear decay (1.0 → 0.0)
  - bus connected + lastImuSampleAt nil: 차단
- **문제**:
  - 5Hz IMU 의 max age = 200ms — 정상 동작은 OK.
  - 단, robot disconnect / reconnect / IMU read fail 1회만 발생해도 → 다음 IMU sample 까지 보정 0.
  - 사용자 입장에서 "보정 ON 인데 안 움직임" — silent.
- **권고**:
  - 보정 0 으로 떨어졌을 때 UI / log 에 명시 (현재 lastCorrectionApplied=false 만 internal).
  - HUD 에 "🟠 자이로 stale — 보정 일시 차단" 표시.

### 2.4 IMU normalization 부분 적용 (pitch 만)

- **위치**: `WalkLabSession+BalanceCorrection.swift:128-135`
- **로직**:
  ```swift
  let normalizedImuPitchDeg = config.pitchInputConvention == .imuRaw
      ? imuPitchDeg : -imuPitchDeg
  let normalizedImuRollDeg = imuRollDeg  // 정규화 안 됨
  ```
- **문제**:
  - pitch 는 부호 정규화 옵션 있음 (v1.11.3 P1.1).
  - roll 은 raw 사용 — robot 의 roll 부호가 ROBOTIS Walking.cpp 와 다르면 보정 방향 반대.
- **영향**:
  - 실 robot 에서 좌우 흔들림 보정이 반대 방향으로 적용될 가능성.
  - 시뮬에서는 검증 안 됨 (시뮬은 합성 IMU 라 부호 일치).
- **권고**:
  - roll 도 정규화 옵션 추가 (`rollInputConvention`).
  - 또는 실 robot 1회 검증 후 적절한 부호 hardcode.

---

## 3. P1 — UX / 신뢰성 (보행 자체는 동작하나 사용자 오해 가능)

### 3.1 Mac sparse engine 의 step 주기가 IMU 주기보다 빨라 보정 중복

- **현상**: 50ms walk tick × 4 = 200ms IMU 주기 → 같은 IMU 값으로 4 step 보정.
- **결과**: 보정이 4 step 동안 동일 — discrete step → 부드럽지 않음.
- **권고**: IMU LPF 또는 sample interpolation (구현 있음, 사용 점검 필요).

### 3.2 balanceCorrector 의 ramp 가 IMU stale gate 보다 우선 적용

- **위치**: `WalkLabSession+BalanceCorrection.swift:198` `let effectiveScale = ramp * freshnessGate`
- **문제**: corrector ON 직후 1초 ramp 가 진행 중인데 IMU 가 stale → ramp 효과 미반영.
- **결과**: 사용자가 "보정 켰는데 작동 시점" 인지 어려움.

### 3.3 자이로 보정 결과가 trial outcome 에 반영되지 않음

- **확인 필요**: `applyBalanceCorrectionIfEnabled` 가 `lastCorrections` / `lastCorrectionApplied` 만 set — `WalkTrialOutcome` 의 metric 에 보정 효과 (peak roll/pitch 감소, fall 차단 횟수) 가 포함되는지.
- **권고**: trial outcome 에 "보정 활성/비활성 시 peak abs roll/pitch 비교" 필드 추가.

---

## 4. P2 — 향후 개선 (실 robot 검증 후 결정)

### 4.1 GyroCorrector / BalanceCorrector / FallPredictor 의 책임 중복

- 3 컴포넌트가 IMU 를 각자 소비하며 corrections 계산. 책임 매핑이 docstring 에 있으나 코드상 일부 중첩.

### 4.2 Walking engine 의 시간 동기 (Mac sparse vs Onboard)

- Mac sparse: tickDtSec 50ms.
- Onboard: WalkingEngineCommand 가 periodMs 전달.
- 두 path 의 timing 동기 검증 안 됨.

---

## 5. 시뮬 vs 실 robot 검증 상태

| 영역 | 시뮬 검증 | 실 robot 검증 |
|---|---|---|
| Mac sparse engine 보행 cycle | ✓ (1325 swift tests) | ⚠️ 부분 (handoff doc 있음, 영구 보장 X) |
| applyBalanceCorrectionIfEnabled 분기 | ✓ | ✗ |
| IMU freshness gate | ✓ (시뮬 합성 IMU) | ✗ |
| Onboard mode brokering | ✓ (mock SSH) | ⚠️ patch 필요 |
| 보정 효과 (peak roll/pitch 감소) | ✗ | ✗ |

---

## 6. 우선순위 권고

### P0 즉시 (다음 cycles)

1. **IMU 동적 polling rate** — walk 활성 중 50Hz (20ms), idle 시 5Hz. (cycle 159)
2. **자이로 stale UI 신호** — HUD 에 "보정 차단 중" 명시. (cycle 160)
3. **roll 부호 정규화 옵션** — `rollInputConvention` 신규. (cycle 161)
4. **Onboard mode 자이로 schema 송신** — WalkingEngineCommand 확장. (cycle 162)

### P1 (다음 sprint)

5. trial outcome 에 보정 효과 metric 추가. (cycle 163)
6. corrector ramp + freshness gate 우선순위 명시. (cycle 164)
7. 실 robot smoke test scenario (handoff doc). (cycle 165+)

### P2 (장기)

8. GyroCorrector / BalanceCorrector / FallPredictor 책임 통합.
9. Mac sparse vs Onboard timing 동기 검증.

---

## 7. 결론

현재 "자이로 기반 보행 보정" 시스템 은 **구조는 잘 갖춰졌으나 실제 동작 효과가 제한적**:

- ✓ 정확한 closed-loop 설계 (IMU → corrector → bus.setPosition).
- ✓ 안전 gate (freshness, ramp, mode 분기) 충실.
- ✗ IMU 속도가 ROBOTIS 권장의 1/25 — 실 보행 빠른 보정 불가.
- ✗ Onboard mode 는 Mac 측 자이로 보정 입력 무효.
- ✗ 실 robot 에서 보정 효과 측정 없음.

→ cycle 159+ 에서 P0 4건 즉시 처리 → 50Hz IMU + UI stale 신호 + roll 부호 + Onboard schema.
