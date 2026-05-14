# Pilot v1.5+ — 4가지 잔여 refinement 통합 기획

**작성일**: 2026-05-14
**범위**: Sprint 18 Phase E (현재 라운드)
**기반**: Codex 권고 (2026-05-14) — 우선순위 2 > 4 > 1 > 3 의 후속 정밀화

---

## 0. 기획 원칙

1. **정직성 우선** — "작동하는 척" 금지. 실 검증 안 된 값/scale 은 사용자 화면에 명시.
2. **점진 활성** — 큰 robot-side 작업은 v1.6 sprint 로 분리, v1.5 에서는 Mac-only minimal viable.
3. **튜닝 노출** — 추정 값은 expert UI 로 사용자가 직접 검증/조정.
4. **공식 source provenance** — ROBOTIS source 와의 일치 / 불일치를 코드에서 문서화.

---

## 1. 항목 1 — PD gain expert panel UI

### 현재 상태
- `PilotHeadTracker` 의 kp/kd/deadband/maxStepDeg/lostTargetHoldFrames 가 `@Published` 로 노출.
- 그러나 UI 슬라이더 없음 — 사용자가 만질 수 없음.

### 기획

**A. UI 위치**: `PilotCameraView` 의 head tracking 토글 옆에 작은 "조정" 버튼. 클릭 → sheet 로 `PilotHeadTrackerSettingsSheet` 표시.

**B. 시트 구성** (`PilotHeadTrackerSettingsSheet.swift` 신규):
- 헤더: "head 추적 PD 조정" + 부제 "ROBOTIS-derived seed (Camera.h FOV 58°/46°)"
- 5개 슬라이더:
  - **Kp (proportional)**: 0.05 ~ 0.80, step 0.01, default 0.32
  - **Kd (derivative)**: 0.00 ~ 0.50, step 0.01, default 0.18
  - **Deadband (정규화)**: 0.00 ~ 0.15, step 0.01, default 0.04
  - **Max step (°/tick)**: 1 ~ 15, step 0.5, default 5.0
  - **Lost-target hold (frames)**: 1 ~ 10, step 1, default 3
- 각 슬라이더 옆에 짧은 설명 (한 줄) + 현재 vs 기본값 표시
- "기본값으로 초기화" 버튼
- "마지막 처리" / "마지막 skip 사유" 라이브 표시 (PD 디버깅)
- "닫기" + ESC

**C. 안전성**:
- Kp 가 0.5+ 면 황색 경고 ("진동 위험")
- Kp + maxStepDeg 곱이 4° 초과면 황색
- 즉시 반영 — 사용자가 슬라이더 움직이는 동안 다음 detection 부터 적용

**D. UserDefaults 보존 (선택)**:
- v1.5 에선 process 종료 시 reset 으로 단순화 — 사용자가 매번 만지지 않을 것
- 또는 `@AppStorage` 기반 5개 키. 일단 미적용 — 사용자가 fine-tune 한 값은 expert 가 매번 입력하는 방식이 안전

### 예상 작업
- 신규 파일 1개 (Sheet) ~150 줄
- `PilotCameraView` 에 버튼 1개 추가 + sheet 바인딩
- 테스트 — 게인 범위 검증

---

## 2. 항목 2 — IMU raw scale 검증 UI

### 현재 상태
- `cm.rs` 의 `read_imu()` 는 register 38-49 (12 byte) read 후 i16 little-endian 으로 decode.
- 변환: gyro ±2000 dps / 32767, accel ±2g / 32767.
- **검증 안 됨**: ROBOTIS legacy code 의 `MotionStatus::FB_GYRO = (high << 8) | low` 와 우리 i16 littleEndian 이 같은 결과를 주는지 불확실.
- 실 로봇 측정 없으면 정확도 불명.

### 기획

**A. raw 값 노출** (`PilotImuRawDiagnosticsSheet.swift` 신규):
- Mac UI 시트 — "IMU 진단" 버튼 (PilotHudStrip 의 imuBlock 옆 또는 PilotDiagnosticsPanel 내 expert)
- 표시:
  - Gyro X/Y/Z: raw (i16) + 변환된 °/s
  - Accel X/Y/Z: raw (i16) + 변환된 g
  - 우리 변환식 (코드 그대로 표시 — 사용자가 확인 가능)
  - 마지막 통신 시각 / failure count

**B. 정지 자세 calibration**:
- 사용자가 로봇을 평평한 곳에 똑바로 세움
- "정지 측정 시작" 버튼 → 5초간 1Hz polling × 5 sample 평균
- 결과:
  - Gyro bias (정지 시 dps — 이상적으론 0)
  - Accel: roll/pitch 도 (이상적으로 0°/0°)
  - Accel Z 의 g 값 (이상적으로 1g — 1g 와의 편차로 scale 검증)
- 결과에 따라 진단:
  - Gyro bias > 1°/s → "drift 있음 — 가만히 있는데도 회전 감지. ROBOTIS 보정 필요"
  - |Accel Z - 1.0g| > 0.3g → "scale 불일치 의심 — Codex 권고: ROBOTIS legacy raw word 와 비교"
  - 0.5g < Accel Z < 1.5g → "scale OK"

**C. 코드 주석에 분석 문서화** — `cm.rs` 의 read_imu 위에:
```rust
//! ## ROBOTIS legacy 와의 차이 (검증 필요)
//!
//! ROBOTIS-OP2 `Framework/src/motion/MotionStatus.cpp` 의 IMU 읽기:
//!   FB_GYRO = (BulkRead[GYRO_X_H] << 8) | BulkRead[GYRO_X_L]
//!     → unsigned 16-bit composition.
//!   MotionStatus 가 이 값을 그대로 사용 (raw word, 보통 ~512 center).
//!
//! 우리 코드: i16::from_le_bytes — signed 16-bit little-endian.
//!   변환식: raw × 2000.0 / 32767 — MPU-6050 ±2000dps full scale 가정.
//!
//! **차이 발생 조건**:
//!   - ROBOTIS 펌웨어가 raw 16-bit signed 그대로 register 에 쓰는 경우 → 우리 코드 OK.
//!   - ROBOTIS 펌웨어가 10-bit ADC 결과를 0..1023 으로 register 에 쓰는 경우 → 우리 코드 wrong.
//!
//! 검증: `PilotImuRawDiagnosticsSheet` 의 "정지 측정" 으로 accel Z 가 ~1.0g (32767/2 ≈ 16384 raw)
//! 인지 확인. raw 값이 ~16384 ± 노이즈면 우리 변환 OK. raw 값이 ~512 면 ROBOTIS legacy 방식.
```

### 예상 작업
- 신규 파일 1개 (sheet) ~180 줄
- 코드 주석 +20 줄
- 테스트 — sheet 표시 + bias 계산 로직

---

## 3. 항목 3 — robot-side IMU loop (v1.6 minimal viable + 완전판 계획)

### 현재 상태
- Mac 측 1Hz polling → roll/pitch 정적 추정.
- ComplementaryFilter 가 `forge-core/walk/imu.rs` 에 있으나 미사용.
- Codex 권고: 1Hz polling 에선 gyro integration 의미 없음. 50-125Hz 가 필요.

### 기획

**v1.5 minimal viable (이번 라운드)**:

**A. polling 주기 1Hz → 5Hz** — Mac 측에서 `bus.readImu()` 호출 빈도 증가.
- `ConnectionStore.runTelemetryLoop` 에서 IMU 만 별도 sub-tick (200ms) 또는 전체 cadence 조정
- bus traffic: IMU 12 byte read ~1ms / call × 5/s = 5ms/s. 매우 작음.
- 단, board snapshot 은 1Hz 그대로 (불필요)
- 위험: forge-bridge 의 latency 가 5Hz read 를 못 따라가면 IMU 도 stale.

**B. Mac-side ComplementaryFilter 적용**:
- `ForgeCore` 에 `ImuFilter.swift` 신규 — `walk::imu::ComplementaryFilter` Swift 포팅
- 5Hz raw IMU sample → filter.update(sample, dt=0.2s)
- alpha = tau / (tau + dt) — tau=0.5s, dt=0.2s → alpha=0.71
- 5Hz × tau 0.5s → 2.5 cycle. Settling 가능하지만 빠른 동작 추적 어려움.
- `ConnectionStore.lastTelemetry.imuFiltered: (rollDeg, pitchDeg)?` 노출
- 사용자에게 정직 표시: "정적 (5Hz × τ=0.5s 필터)" vs 이상적 "100Hz 동적 추적"

**C. UI 라벨 분리** (`PilotHudStrip`):
- 기본 표시: filtered roll/pitch (5Hz × CF)
- expert 모드: raw accel-tilt + filtered + 차이 표시

**v1.6 완전판 (별도 sprint)**:

**구조 옵션**:

| 옵션 | 설명 | 작업량 | 위험 |
|---|---|---|---|
| **A. forge-bridge 통합** | socat 대신 우리 Rust daemon — IMU loop + bridge 통합 | 매우 큼 | 기존 master setup 호환성 |
| **B. 별도 robot-side Python script** | df-imu-loop.py 가 /dev/ttyUSB0 직접 read (forge-bridge OFF 시), file 에 filter 결과 작성 | 중간 | bus 점유 충돌 (forge-bridge 와 양립 불가) |
| **C. forge-bridge proxy + IMU register cache** | socat 가 IMU register read 만 가로채서 cache + filter, 다른 register 는 그대로 | 큼 | 복잡, 디버깅 어려움 |
| **D. ROBOTIS demo 의 MotionStatus 가져오기** | demo 모드일 때 demo 가 이미 filter 한 값 사용. 데몬이 /tmp/df-motion-status 에 작성 | 작음 | demo 모드일 때만 작동 |

**권고**: 옵션 A 가 정답이지만 매우 큰 작업. v1.6 sprint 로 분리 + 명세서:

```
docs/prd/v1.6-bridge-imu-loop.md (신규 PRD)
- forge-bridge 의 Rust 재작성
- 단일 데몬이 socat 역할 + 100Hz IMU loop + ComplementaryFilter 보유
- TCP 5530: 일반 dynamixel — 기존 protocol
- TCP 5531: 새 telemetry protocol (1Hz binary frame: filtered roll/pitch + raw + RTT)
- master setup 명령에 새 daemon 추가
```

### 예상 작업
- 신규 `ForgeCore/ImuFilter.swift` ~80 줄 (Swift CF 포팅)
- `ConnectionStore` polling 주기 조정 +10 줄
- `TelemetrySnapshot.imuFiltered` 필드 +5 줄
- `PilotHudStrip` 라벨 정리 +20 줄
- v1.6 PRD 문서 ~200 줄
- 테스트 — CF unit test

---

## 4. 항목 4 — HSV config endpoint v1.6 minimal viable

### 현재 상태
- `MultiColorVision` 의 default HSV 는 ROBOTIS main.cpp:65-90 인자.
- 사용자가 robot 측 `config.ini` 수정 시 Mac 과 불일치.
- `hsvTuning` flag = false (v1.5).

### 기획

**A. robot-side SSH read/write helper** (`RobotSetupCommand`):
- `readVisionConfig` — `~/Framework/Linux/project/demo/config.ini` 또는 `tutorial/camera/config.ini` 의 ORANGE/RED/YELLOW/BLUE 섹션 4개 read
- 출력 contract: TOML-like `DF_HSV_ORANGE=h=20,t=25,sl=0.30,vl=0.30` 한 줄씩
- `writeVisionConfig` — Mac 이 보낸 값으로 ini section update (sed `-i`)

**B. Mac-side HSV preset 관리** (`ForgeCore`):
- `VisionHsvPreset.swift` 신규 — 4 색 × 4 파라미터 + source (`.macDefault` / `.robotSynced` / `.modifiedLocally`)
- `@AppStorage` 로 사용자 변경 보존
- `MultiColorVision.detectAll(in:tags:preset:)` overload — preset 받아 default 대신 사용

**C. Mac UI 시트** (`PilotHsvTuningSheet.swift` 신규):
- PilotCameraView 의 trailing 또는 head tracking sheet 옆 "HSV 튜닝" 버튼
- 시트 안:
  - 4 색 탭: 주황/빨강/노랑/파랑
  - 각 탭: hue / hue tolerance / min sat / min value 슬라이더 4개 + 라이브 미리보기 (현재 카메라 frame 에 그 색만 마스킹)
  - 상단 source badge:
    - 🔵 "Mac default" — 기본값
    - 🟢 "로봇과 동기화" — robot ini 와 일치
    - 🟡 "로컬 수정됨" — Mac UI 에서만 수정
    - 🔴 "로봇과 다름" — robot ini 와 mismatch (loaded after edit)
  - 3 버튼:
    - **"로봇에서 불러오기"** — readVisionConfig → robot ini 값 반영 + source = robotSynced
    - **"로봇에 저장"** — writeVisionConfig → robot ini update. **경고**: "ROBOTIS demo 의 색 검출에도 영향. 정말 적용?"
    - **"Mac default 로 초기화"** — ROBOTIS 인자 그대로 복원

**D. v1.5 flag**:
- `hsvTuning = true` 활성 — UI 노출 가능
- 단, robot write 는 명시 confirm 거쳐야만 가능

### 예상 작업
- 신규 `ForgeCore/VisionHsvPreset.swift` ~80 줄
- 신규 `Pilot/PilotHsvTuningSheet.swift` ~350 줄
- `RobotSetupCommand` +60 줄 (read/write 명령)
- `MultiColorVision.detectAll` overload +10 줄
- `MjpegSnapshotClient` 의 detection 호출이 preset 받음
- `PilotCameraView` 의 sheet 토글 +20 줄
- `PilotFeatureFlags.v1_5.hsvTuning = true`
- 테스트 — HSV preset 직렬화 + source badge 결정 + readVisionConfig 명령 marker

---

## 우선순위 + 구현 순서

이번 라운드 (Phase E):
1. **항목 1 — PD gain expert sheet** (작은 작업, 즉시 효과)
2. **항목 2 — IMU raw 진단 sheet + calibration** (작은 작업, scale 검증 가능)
3. **항목 3 v1.5 minimal viable** — 5Hz polling + Mac CF (Swift 포팅 + 필드 분리)
4. **항목 4 — HSV tuning sheet** (큰 작업이지만 한 라운드 가능)

별도 sprint (Phase F):
- 항목 3 v1.6 완전판 — forge-bridge Rust 재작성 (옵션 A)

---

## 통합 안전 정책 (모든 항목 공통)

1. **Expert UI 진입 시 명확한 안내** — "잘못된 값은 안 좋은 동작을 만들 수 있어요" 한 줄 + 기본값 reset 버튼
2. **변경 즉시 반영** + **변경 사항 로그** — 사용자가 무엇을 만졌는지 추적 가능
3. **Robot write 는 항상 confirm sheet** — HSV 저장이 ROBOTIS demo 에도 영향을 미친다는 사실 명시
4. **Source badge 일관성** — Mac default / 로봇 동기 / 로컬 수정 / 로봇과 다름 라벨이 모든 expert sheet 에서 동일

---

## 변경 파일 예상

```
신규:
  Pilot/PilotHeadTrackerSettingsSheet.swift     ~150줄  (항목 1)
  Pilot/PilotImuRawDiagnosticsSheet.swift       ~180줄  (항목 2)
  ForgeCore/ImuFilter.swift                     ~80줄   (항목 3 v1.5)
  ForgeCore/VisionHsvPreset.swift               ~80줄   (항목 4)
  Pilot/PilotHsvTuningSheet.swift               ~350줄  (항목 4)

수정:
  Pilot/PilotCameraView.swift                   +60줄   (3 sheet 트리거)
  Pilot/PilotHeadTracker.swift                  (변경 없음 — 기존 @Published bind)
  Pilot/PilotHudStrip.swift                     +20줄   (filter 표시 분리)
  ConnectionStore.swift                         +30줄   (IMU 5Hz + filter)
  ForgeCore/LiveTelemetry.swift                 +5줄    (imuFiltered 필드)
  ForgeCore/MultiColorVision.swift              +30줄   (preset overload)
  ForgeCore/Bus.swift                           (rust scale 주석)
  Connection/RobotSetupCommand.swift            +80줄   (HSV read/write 명령)
  Remote/QuickActions.swift                     +6줄    (HSV QuickAction)
  Pilot/PilotFeatureFlags.swift                 +1줄    (hsvTuning = true)
  controller/cm.rs (Rust)                       +25줄   (scale 분석 주석)
  Tests/PilotTests.swift                        +50줄   (4 항목 unit tests)

신규 문서:
  docs/handoff/2026-05-14-pilot-residual-refinement-plan.md (본 문서)
  docs/prd/v1.6-bridge-imu-loop.md                       (항목 3 v1.6 완전판)
```

총 +1100줄 정도. 한 라운드 가능.

---

## 위험 / 한계

1. **항목 3 의 5Hz Mac CF** 는 Codex 가 "1Hz 라 의미 없다" 라고 했지만 5Hz 면 tau=0.5s 와 같이 약 2.5 cycle settling. 빠르게 움직이는 robot 의 진짜 자세는 못 잡음. v1.5 한도 내 정직한 best-effort.
2. **항목 4 의 robot ini write** 는 ROBOTIS demo 의 색 검출도 바꿈. 사용자 confirm sheet 가 있지만 무심코 누르면 demo 모드 영향. 모든 write 작업 후 ROBOTIS demo 재시작이 필요할 수 있음.
3. **항목 2 의 정지 calibration** 가 사용자에게 "스케일이 잘못됐다" 라고 알려줘도 실제 정정은 Rust 코드 변경 + make mac 빌드 필요. 이번 라운드는 진단까지만.
4. **모든 expert UI 는 v1.5 flags ON 일 때만** — 사용자가 v1.0 으로 전환하면 사라짐. 의도된 동작.
