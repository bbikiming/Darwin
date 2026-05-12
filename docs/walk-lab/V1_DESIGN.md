# Walk Lab v1 — 걷기 테스트 & 보완 도구 설계

> DarwinForge SwiftUI 앱의 **Walk Lab 섹션** (⌘4) 기획 + 구현 가이드.
> 비전문가도 클릭 한 번으로 "천천히 걷기" / "빠르게 걷기" / "달리기"를
> 안전하게 시도하고, 결과를 즉시 시각 피드백 받을 수 있는 도구.
>
> 작성 근거:
> - 기존 `WalkSimView.swift` (sin파 시뮬, 실 모터 명령 X)
> - `forge-core::walk::engine` (BLOCKER C3 — stub 상태, 실 IK 부재)
> - ROBOTIS-OP2 `op2_walking_module/config/param.yaml` (period_time=600ms 등)
> - `docs/harness/v2-mac-ui-handoff.md` (Connection / Temp pill / 안전 게이트)

---

## 1. 사용 시나리오 — "어떻게 보이고 어떻게 동작하나"

### 시나리오 A: 비전문가 빠른 체험
```
1. 사용자가 ⌘4 → Walk Lab 진입.
2. 사이드바에 "보행 모드" 8개 큰 버튼.
3. 로봇 cradle에 거치된 상태 확인 메시지 (체크박스 1개).
4. "천천히 걷기" 버튼 클릭.
5. 우측에 즉시 시각화 — 발 trail, IMU gauge, 모터 온도 그래프.
6. 좌측 사이드바에서 "정지" 클릭 또는 ESC.
```

### 시나리오 B: 파라미터 튜닝
```
1. 프리셋 클릭 → "고급" 토글 켜기.
2. 슬라이더 4개 등장: 보폭(x) / 좌우(y) / 회전(a) / 사이클 주기.
3. 슬라이더 조작하면 즉시 발 trail 갱신 (sim).
4. "실 로봇에 적용" 버튼 → confirm 다이얼로그 → 송출.
5. 동작 보고 다시 슬라이더 미세 조정.
```

### 시나리오 C: 안전 데모
```
1. "달리기" 클릭.
2. confirm_risk 다이얼로그: 정비 스탠드 거치 + 주변 공간 + 위험 인식 3 체크.
3. 모두 체크 → "위험 감수하고 실행".
4. 5초 카운트다운 (취소 가능).
5. 시작 → 60초 자동 cool-down (또는 IMU roll > 30° 시 자동 stop).
6. 끝나면 trace 저장 → 분석 보기.
```

---

## 2. 8개 보행 프리셋 — 한눈에

> 모든 파라미터는 ROBOTIS-OP2 `param.yaml` 기본값 (period 600ms / foot_height 0.04m / dsp_ratio 0.1) 기준 변형.

| Preset | 한국어 | 보폭 x (m/cycle) | 좌우 y | 회전 a (rad/cycle) | period (ms) | Safety | 권장 시간 |
|--------|--------|------------------:|-------:|---:|---:|--------|----------|
| `idle` | 정지 | 0 | 0 | 0 | — | Safe | ∞ |
| `march` | 제자리 걸음 | 0 | 0 | 0 (foot 들리기만) | 600 | Safe | 30 s |
| `slowWalk` | 천천히 걷기 | 0.015 | 0 | 0 | 600 | Safe | 60 s |
| `normalWalk` | 보통 속도 | 0.025 | 0 | 0 | 600 | Safe | 60 s |
| `fastWalk` | 빠르게 걷기 | 0.035 | 0 | 0 | 500 | **Caution** | 30 s |
| `jog` | 달리기 | 0.040 | 0 | 0 | 450 | **HighRisk** | 15 s + confirm |
| `turnLeft` | 좌회전 | 0.010 | 0 | +0.10 | 600 | Caution | 30 s |
| `turnRight` | 우회전 | 0.010 | 0 | -0.10 | 600 | Caution | 30 s |

`fastWalk` / `jog`는 period 단축 — ROBOTIS 원본은 600ms 고정이므로 **신규
파라미터 탐색**임을 명시. 위험. 

> ⚠️ BLOCKER C3: 현 `walk::engine`은 단순 sin파 stub. `op2_walking_module.cpp::computeLegAngle`의 13× wSin + IK 미구현. 본 프리셋들은 **시뮬에서만 검증** 가능, 실 모터 송출은 IK 완성 후.

---

## 3. GUI 컴포넌트 — 직관 우선

```
┌────────────────────────────────────────────────────────────────┐
│ Sidebar (좁음, 240pt)        │ Detail (넓음)                    │
├──────────────────────────────┼──────────────────────────────────┤
│                              │                                  │
│ 🚶 보행 모드                  │  ┌─── 3D Foot Trail ────────┐   │
│                              │  │                            │   │
│  ⏸  정지            ESC      │  │   (Webots 스타일 발 자취)  │   │
│  🚶  제자리 걸음              │  │                            │   │
│  🐢  천천히 걷기              │  └────────────────────────────┘   │
│  🚶‍♂️ 보통 속도               │                                  │
│  🏃  빠르게 걷기   ⚠️         │  ┌─── IMU Gauge ─────────────┐   │
│  💨  달리기       ⚠️⚠️        │  │  Roll  ─── 12°  (녹색)     │   │
│  ↪️  좌회전                   │  │  Pitch ─── -3°  (녹색)     │   │
│  ↩️  우회전                   │  └────────────────────────────┘   │
│                              │                                  │
│ ─────────────────            │  ┌─── Foot Targets ──────────┐   │
│ ⚙️  고급 (토글)               │  │  L:  +0.025  +0.020  -0.015 │   │
│                              │  │  R:  -0.025  -0.020  -0.020 │   │
│  [고급 켜짐 시 슬라이더 4개]   │  │  Phase: PHASE1 (lift)      │   │
│   보폭 x   ━━●━━━━            │  └────────────────────────────┘   │
│   좌우 y   ━●━━━━━            │                                  │
│   회전 a   ━━━●━━━            │  ┌─── Motor Temperature ─────┐   │
│   period   ━━━━●━━            │  │  ▁▂▃▃▄▄▅▆▆▇  max 47°C ✓  │   │
│                              │  │  (16 모터 sparkline)        │   │
│ ─────────────────            │  └────────────────────────────┘   │
│ 📊 세션 기록                  │                                  │
│  · slowWalk × 45s            │  ┌─── 액션 바 ───────────────┐   │
│  · normalWalk × 30s          │  │ [▶ 실 로봇에 적용]  [⏸ 정지] │   │
│  · jog × (취소)              │  │ [💾 trace 저장]   [📊 분석] │   │
│                              │  └────────────────────────────┘   │
└──────────────────────────────┴──────────────────────────────────┘
```

### 핵심 컴포넌트

| 컴포넌트 | 역할 | 구현 힌트 |
|----------|------|----------|
| **PresetButton** | 큰 아이콘 + 한국어 + 위험도 배지 | SwiftUI `Button` + `Label` + `StatusPill` 조합 |
| **FootTrailView** | 좌·우 발 궤적 2D top-down + 30 sample 색 변화 | `Canvas` API |
| **IMUGauge** | Roll / Pitch 게이지 (반원 또는 horizontal) | `GeometryReader` + `Path` |
| **FootTargetsCard** | 6 자리 숫자 monospaced + Phase 배지 | 기존 `WalkSimView`의 trace 테이블 단순화 |
| **MotorTempSparkline** | 16 모터 max 온도 시간축 | `Swift Charts` LineMark |
| **SafetyConfirmDialog** | HighRisk 프리셋 시 3-체크박스 | `.alert(...)` 또는 `.sheet` modal |
| **CountdownOverlay** | 실 송출 직전 5초 카운트다운 | `Timer.publish(every:)` + 큰 숫자 |
| **SessionRecorderRow** | "slowWalk × 45s" 누적 기록 | sidebar 하단 `List` |

---

## 4. 안전 게이트 — 4겹

### L1 — Cradle confirmation
- 위치: Walk Lab 진입 시 단 한 번, 그 다음 닫기 전까지 캐시
- "정비 스탠드에 거치하셨나요?" 체크박스
- 미체크 시 모든 프리셋 disabled (회색 처리)

### L2 — Preset SafetyClass
- `Safe` / `Caution` / `HighRisk` 3-tier
- `Caution` 버튼은 노란 외곽선 + 30s 자동 stop
- `HighRisk` 버튼은 빨간 외곽선 + `confirm_risk=true` 다이얼로그 + 15s 자동 stop

### L3 — Live IMU monitoring
- 50 Hz로 roll/pitch 폴링
- |roll| > 30° 또는 |pitch| > 30° 도달 → **자동 emergency_stop**
- UI 상단에 빨간 banner: "균형 잃음 감지 — 자동 정지됨"

### L4 — Motor temperature
- 5초 주기 BULK_READ
- 60°C 도달 시 자동 stop + LiPo 분리 권고 다이얼로그
- (이미 v2-mac-ui-handoff.md §3.2와 동일)

### L0 — 항상 가능
- ESC / ⌘⇧. — 즉시 emergency_stop (기존 단축키)

---

## 5. SwiftUI 구현 — 파일 구조 (사용자 Mac 추가)

본 컨테이너가 `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/` 디렉토리에
스켈레톤만 제공. 사용자가 Mac에서 디자인 시스템 (`DFColor`, `DFSpace`)에
맞춰 보강:

```
WalkLab/
├── WalkLabView.swift            # 메인 — RootView Section.walk 케이스에 연결
├── WalkLabSession.swift         # ObservableObject (현재 프리셋 / IMU / 온도 / 기록)
├── WalkPresetCatalog.swift      # 8 프리셋 정의 (Swift)
├── Components/
│   ├── PresetButton.swift       # 큰 버튼
│   ├── FootTrailCanvas.swift    # 2D top-down trail
│   ├── IMUGauge.swift           # roll/pitch 게이지
│   ├── MotorTempSparkline.swift # Swift Charts
│   └── SafetyConfirmDialog.swift
└── Adapters/
    └── WalkLabBridge.swift      # Rust FFI 호출 wrapper (fc_walk_* 사용)
```

### 핵심 Swift 시그니처 (스켈레톤만)

```swift
// WalkPresetCatalog.swift
public enum WalkPreset: String, CaseIterable, Identifiable {
    case idle, march, slowWalk, normalWalk, fastWalk, jog, turnLeft, turnRight

    public var id: String { rawValue }
    public var label: String { /* 한국어 */ }
    public var icon: String { /* SF Symbol */ }
    public var safety: SafetyClass { /* Safe/Caution/HighRisk */ }
    public var command: WalkCommand { /* (x, y, a, period_ms, enabled) */ }
    public var maxDurationSec: Int { /* 자동 stop */ }
}

@MainActor
public final class WalkLabSession: ObservableObject {
    @Published public var current: WalkPreset = .idle
    @Published public var advanced: Bool = false
    @Published public var customCommand: WalkCommand = .zero
    @Published public var imu: (roll: Double, pitch: Double) = (0, 0)
    @Published public var maxMotorTemp: UInt8 = 0
    @Published public var history: [WalkLabRecord] = []
    @Published public var cradleConfirmed: Bool = false
    @Published public var balanceLost: Bool = false
    
    public func apply(_ preset: WalkPreset, dryRun: Bool = true) async { ... }
    public func stop() { ... }
    public func emergencyStop() { ... }
}
```

---

## 6. Rust 측 — `forge-core::walk::preset` 모듈

본 PR로 추가. 8 프리셋 정의 + safety class + clamp 로직 + 단위 테스트.

```rust
// app/core/forge-core/src/walk/preset.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum WalkPreset {
    Idle, March, SlowWalk, NormalWalk, FastWalk, Jog, TurnLeft, TurnRight,
}

impl WalkPreset {
    pub fn command(self) -> WalkCommand { ... }
    pub fn period_ms(self) -> u32 { ... }
    pub fn safety(self) -> WalkSafety { ... }
    pub fn max_duration_secs(self) -> u32 { ... }
    /// Caution / HighRisk 경고 메시지 (UI 표시용)
    pub fn warning(self) -> Option<&'static str> { ... }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkSafety { Safe, Caution, HighRisk }
```

FFI export (forge-ffi에 추가 후보):
```rust
// app/core/forge-ffi/src/lib.rs
#[no_mangle]
pub unsafe extern "C" fn fc_walk_apply_preset(
    handle: *mut FcWalk,
    preset: u8,  // 0..7
) -> c_int { ... }
```

---

## 7. 구현 우선순위 (P0~P2)

| Tier | 작업 | 위치 | 비고 |
|------|------|------|------|
| **P0** | `WalkPreset` Rust enum + 단위 테스트 | `walk/preset.rs` | 이 PR |
| **P0** | `WalkLabView` SwiftUI 스켈레톤 | `DarwinForgeUI/WalkLab/` | 이 PR (Mac 컴파일 검증 위임) |
| **P0** | 8 PresetButton + cradle confirm | 위 | 이 PR |
| **P1** | FootTrailCanvas (2D top-down) | 위 | Mac에서 — 기존 `WalkSimView` trace 재활용 가능 |
| **P1** | IMUGauge (반원 게이지) | 위 | `forge-core::walk::imu::ComplementaryFilter` 출력 사용 |
| **P1** | MotorTempSparkline (Swift Charts) | 위 | 5s 폴링 |
| **P1** | SafetyConfirmDialog (HighRisk) | 위 | `confirm_risk=true` 다이얼로그 |
| **P2** | 실 모터 송출 활성화 | `WalkLabBridge` + Rust 실 IK | **walk::engine C3 해결 후** |
| **P2** | 자동 stop (IMU balance / temp 60°C) | `WalkLabSession.onUpdate` | L3/L4 게이트 |
| **P2** | Session recording → JSON export | `WalkLabRecord` | 데이터 누적 — 향후 RL fine-tune |
| **P3** | "분석 보기" — phase별 deviation 그래프 | 별도 view | 트레이스 분석 |

---

## 8. 의존성 / 전제

- ✅ `forge-core::walk::WalkParams` + `WalkCommand` + `WalkEngine::tick/foot_targets`
- ✅ `forge-core::walk::imu::ComplementaryFilter` (roll/pitch 추정)
- ✅ `fc_walk_new / fc_walk_set_command / fc_walk_tick` FFI 함수
- ⚠️ `walk::engine` 자체는 stub (C3) — 실 모터 송출은 IK 완성 후
- ✅ ESC / ⌘⇧. emergency_stop (이미 존재)
- ⏳ 모터 BULK_READ 16 ID로 온도 수집 (현재 단일 READ만 있음 — `JointController::read_state` 16번 호출 또는 BULK_READ 신설)

---

## 9. 검증 시나리오 (Mac에서)

```sh
# 1. 빌드
make app

# 2. 앱 실행 + Walk Lab 진입 (⌘4)
make run

# 3. UI 체크리스트
#  - cradle confirm 체크박스 동작
#  - 8 프리셋 버튼 클릭 → 시뮬 (실 모터 X) 동작 확인
#  - foot trail 실시간 갱신
#  - HighRisk 프리셋 (jog) → confirm 다이얼로그
#  - ESC → 모든 시뮬 정지
```

---

## 10. 향후 확장 (Sprint 14+)

- **음악 동기 보행** — BPM 추출 (Spot Choreographer 패턴 — `docs/inspiration/04-motion-authoring-uis/02-spot-choreographer-deep-dive.md`)
- **인간 시범 → 보행** — Mixamo / ARKit Body Tracking retarget (`docs/inspiration/13-llm-datasets/`)
- **RL fine-tune** — Isaac Lab + ONNX 추론 (`docs/inspiration/08-game-engines/isaac-lab.md`)
- **음성 명령** — "더 빠르게" / "왼쪽으로" → preset switch (`docs/inspiration/15-voice-ui-deep-dive/`)
- **3D pose preview** — SceneKit + URDF (`docs/inspiration/07-uiux-patterns/3d-pose-visualization.md`)

## 출처

- ROBOTIS-OP2 `param.yaml` (period_time 600 ms 등)
- `forge-core::walk::engine` (현재 stub — BLOCKER C3)
- `docs/inspiration/03-humanoid-platforms/04-motion-authoring-uis/02-spot-choreographer-deep-dive.md` (BPM 동기)
- `docs/harness/v2-mac-ui-handoff.md` (Temp pill 60°C 임계)
