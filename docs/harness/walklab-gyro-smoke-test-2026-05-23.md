# WalkLab 자이로 closed-loop 실 robot smoke test 시나리오

- 작성일: 2026-05-23
- 사이클: 170
- 대상: cycles 158-169 의 자이로 closed-loop 변경 (Mac sparse + Onboard schema + UI signals)
- 목적: 실 ROBOTIS DARwIn-OP2 에서 step-by-step 검증

---

## 0. 사전 준비

### 0.1 hardware

- ROBOTIS DARwIn-OP2 (CM-740 + 20 dynamixel MX-28).
- 정비 스탠드 (낙상 위험 차단 필수).
- USB serial 케이블 (Mac ↔ CM-740 sub-controller).
- 전원 — fully charged battery 또는 외부 power.

### 0.2 software

- DarwinForge.app — branch `claude/robotis-darwin-op-setup-oyzTi`, cycle 170 이상.
- ROBOTIS demo daemon — Onboard mode 사용 시.
  - **중요**: cycle 162 의 `WalkingEngineCommand` 가 10 필드 송신 — daemon 이 v1 (sscanf 7 필드)
    이면 trailing 3 필드 (balance) silent ignore. v2 patch 적용 권장.

### 0.3 안전 체크리스트

- [ ] robot 정비 스탠드 거치 — 발 지면 미접촉.
- [ ] 비상정지 keyboard `Space` 또는 button 확인.
- [ ] 사용자 위치 — robot 측면 1m 이상.
- [ ] 충돌 가능 물체 50cm 이내 제거.

---

## 1. Mac sparse engine smoke test (cycle 159-161)

### 1.1 IMU fast polling (cycle 159)

**검증 목적**: walk 활성 시 IMU 가 20Hz (50ms) 로 polling 되는가.

**Steps**:
1. DarwinForge 실행 → Connect 탭 → USB serial port 선택 → Connect 클릭.
2. Status: "Connected" + heartbeat 1Hz 확인.
3. Telemetry 탭 → IMU section 확인. polling rate "5 Hz" 표시.
4. WalkLab 탭 → Engine = Mac sparse → preset = "march" → Start.
5. Telemetry 탭 → IMU section 새로고침 → polling rate "20 Hz" 변경 확인.
6. Harness Inspector 탭 → events 에서 `imu.poll_rate_changed` event 검색:
   - `fast_mode: true, period_ms: 50` 1건 + 종료 시 `false, 200` 1건.

**예상**:
- walk 활성 중: 20Hz × ~보행 시간(s) sample 누적.
- 종료 후: 5Hz 복원.

**실패 시**:
- 20Hz 전환 안 됨 → `store.imuFastPollActive` 가 true 되는 path 확인.
- bus error 다수 → USB serial latency 한계 — 30Hz 로 낮춤 검토.

### 1.2 freshness state HUD signal (cycle 160 + 167)

**검증 목적**: IMU stale 시 사용자가 inline badge 로 인지.

**Steps**:
1. Mac sparse 모드 + balance corrector ON (correctorIntensityLevel 2).
2. preset = "slowWalk" → Start (정비 스탠드 위 발 떠 있는 상태).
3. WalkLab 우측 inline status row 관찰 — algorithm 라벨 옆 freshnessBadge 가 정상 시 미표시.
4. USB serial 케이블 잠깐 단선 (또는 bus 강제 reset) → IMU read fail.
5. 3-5초 안에 inline badge 등장:
   - 250-500ms stale: 🟠 "IMU 지연 — 보정 감쇠" (orange).
   - 500ms+ stale: 🔴 "IMU 차단 — 보정 정지" (red).
6. 케이블 재연결 → IMU recover → badge 사라짐 (.normal).

**예상**:
- badge 색상 + label 정확.
- VoiceOver 가 "자이로 보정 IMU 차단 — 보정 정지" 읽음.

### 1.3 roll 부호 정규화 (cycle 161)

**검증 목적**: roll 입력 부호 정규화 옵션이 실 robot 에 정확히 적용.

**Steps**:
1. Mac sparse + balance ON + algorithm = "robotisPControl".
2. WalkLab 의 BalanceExperiment expert disclosure → rollInputConvention 옵션 확인:
   - .imuRaw (default).
   - .negateLeftIsNegative.
3. robot 을 손으로 살짝 왼쪽 (CCW) 기울임. WalkLab 의 imuRollDeg 값 측정:
   - +5° 이상 → 코드 컨벤션 일치 (.imuRaw 유지).
   - -5° 이상 → 부호 반대 (.negateLeftIsNegative 로 전환).
4. preset = "march" → balance corrector 적용 확인. 좌측 기울임 시 robot 이 우측으로 보정.
5. 보정 방향이 반대면 .negateLeftIsNegative 토글 + 재시도.

**예상**:
- corrector 가 robot 기울기 방향과 반대 (자세 회복) 로 ankle/hip roll 보정.
- lastCorrections.rHipRoll / lAnkleRoll 값이 의도 방향.

---

## 2. Onboard mode smoke test (cycle 162 + 164 + 168 + 169)

### 2.1 schema 확장 송신 (cycle 162)

**검증 목적**: Mac 가 10 필드 송신 + robot daemon 이 balance 필드 적용.

**Steps**:
1. WalkLab 탭 → Engine = "robotisOnboard" → autoOnboardBrokering = ON.
2. preset = "march" → Start.
3. robot 측 `/tmp/walking_engine_command` (또는 daemon 의 input file) 확인:
   ```bash
   ssh robotis@<robot_ip> cat /tmp/walking_engine_command
   ```
4. 출력 확인 — 10 space-separated 필드:
   ```
   1 28.00 0.00 0.00 600 40 13.00 1.00 0 2
   ```
   - 8: balanceGain (1.00 default)
   - 9: balanceEnable (0 = false, balance OFF)
   - 10: correctorIntensityLevel (2 default)
5. WalkLab UI 의 enableBalanceCorrection = ON → balanceGain = 1.5 → correctorIntensityLevel = 3.
6. 다시 file 확인 — `1 28.00 ... 13.00 1.50 1 3` 변경 확인.

**예상**:
- balanceGain / balanceEnable / correctorIntensityLevel 변경 시 file 즉시 갱신.
- robot daemon 이 v2 patch 라면 robot 측 Walking::GetInstance() 값 변경.

**실패 시**:
- v1 daemon (7 필드 sscanf) → trailing 무시. 다음 section schema warning 으로 사용자 안내.

### 2.2 schema warning banner UI (cycle 168 + 169)

**검증 목적**: 옛 daemon silent failure 차단 UI.

**Steps**:
1. Onboard mode + balance ON 진입.
2. OnboardHealthIndicator 카드 안에 warning banner 표시 확인:
   - ⚠ 아이콘 + "daemon v2 미확인 — balance 미적용 가능".
   - "v2 확인" 버튼 (orange borderedProminent).
3. SSH 통해 daemon source 확인:
   ```bash
   ssh robotis@<robot_ip> grep "sscanf" /path/to/demo/Brokerage.cpp
   ```
   - 7 필드 → v1 (예: `%d %f %f %f %f %f %f`).
   - 10 필드 → v2 (예: `%d %f %f %f %f %f %f %f %d %d`).
4. v2 확인됨 → "v2 확인" 버튼 클릭 → banner 사라짐.
5. session.onboardBalanceSchemaVerified == true 확인.

**예상**:
- banner 정확히 표시 / dismiss.
- 사용자가 실수로 v1 daemon 인데 verified 토글 → 다음 보행 시 robot 무동작 (의도된 결과).

---

## 3. 보정 효과 metric 수집 (cycle 163-165)

### 3.1 단일 trial finalize

**검증 목적**: TrialOutcome.correctionEffectMetric 가 채워짐.

**Steps**:
1. WalkLab → preset = "slowWalk" → balance ON → 10초 보행 → Stop.
2. WalkTrial 자동 finalize.
3. Trial Library 탭 → 최근 trial detail → "보정 효과" section 확인:
   - "보정 활성 100% (200 sample)" (또는 mixed/비활성).
   - ON 구간 peak abs roll/pitch.
   - OFF 구간 peak abs (있다면).

**예상**:
- balance ON 으로 진행한 trial → correctionApplyRatio ≈ 1.0.
- balance OFF 로 진행한 trial → correctionApplyRatio ≈ 0.0.
- 보정 중간 toggle → mixed.

### 3.2 ON/OFF 비교 trial 2회

**검증 목적**: 보정 효과 정량 측정.

**Steps**:
1. trial-A: balance OFF + 10s march.
2. trial-B: balance ON + 10s march.
3. 두 trial 의 outcome.correctionEffectMetric 비교:
   - trial-A: uncorrectedPeakAbsRollDeg = X
   - trial-B: correctedPeakAbsRollDeg = Y
4. Y < X 이면 보정 효과 입증 (peak 흔들림 감소).

---

## 4. 회귀 검증

### 4.1 기존 기능 영향 없음

| 기능 | 확인 |
|---|---|
| Connect / Disconnect | ✓ 정상 |
| heartbeat (1Hz) | ✓ Telemetry 표시 |
| IMU 5Hz idle / 20Hz walk | ✓ 동적 전환 |
| Mac sparse 보행 cycle | ✓ runContinuousWalk 정상 |
| Onboard mode brokering | ✓ SSH file write 정상 |
| 비상정지 (Space) | ✓ torque OFF 즉시 |
| Trial 저장 + 라벨링 | ✓ outcome 모든 필드 + correctionEffectMetric |
| Recommender (rule/coord/pilot) | ✓ realRobotOnly 동작 |

### 4.2 telemetry events

- `imu.poll_rate_changed` (cycle 159) — walk start/stop 시 fast↔slow 전환 1회씩.
- `walklab.start` (기존) — preset + engine + mode payload.
- `balance.config_change` (기존) — balanceGain / enable 변경 시.
- `imu.stale` / `imu.recovered` (기존) — bus interrupt 시.

### 4.3 build + test

```bash
cd app/ui/DarwinForge
swift build  # 0 errors / 0 warnings
swift test   # 1337/0
```

---

## 5. 실패 시 fallback

| 증상 | 1차 대응 | 2차 대응 |
|---|---|---|
| 20Hz IMU bus error 누적 | imuFastPollActive=false 강제 (UI 토글) | bus 재연결 또는 5Hz 유지 |
| balanceCorrectionFreshness 영구 .blocked | robot 재부팅 + 케이블 재연결 | balance OFF + reboot |
| Onboard schema warning 영구 | daemon source 직접 확인 | v1 유지 시 Mac sparse 사용 |
| 보정 방향 반대 | rollInputConvention 토글 | pitch 부호 확인 + signConvention 재설정 |
| correctionEffectMetric 항상 nil | sample.correctionAppliedToRobot 확인 | session.lastCorrectionApplied path 추적 |

---

## 6. 결과 기록 위치

- 본 시나리오 실행 후 결과를 `docs/harness/walklab-gyro-smoke-test-results-YYYY-MM-DD.md` 형식으로 기록.
- 항목별 ✓ / ✗ + 실측 값 (IMU rate, peak roll, freshness 발생 빈도).
- 실패 시 telemetry export — Harness Inspector → "외부 분석용 JSON export" 사용.

---

## 7. 미해결 한계

- ROBOTIS 권장 sensoryFeedback 125Hz vs 현재 Mac 20Hz — bus level batching 필요.
- Onboard mode 의 robot-side v2 patch — Mac schema 만 준비, daemon 작업 (외부).
- 보정 ON/OFF 비교 동일 조건 보장 — 사용자 수동 (자동화 별도).
- 실 낙상 / 흔들림 시나리오 — 안전 시설 (mat / 손잡이) 필요.

본 smoke test 는 **단일 사용자 1회 검증** 기준. CI 자동화 별도.
