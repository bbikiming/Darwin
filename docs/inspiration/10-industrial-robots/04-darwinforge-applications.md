# 04. DarwinForge 적용 후보 — 산업 표준 → 데스크탑 휴머노이드

> 앞 세 문서 (`01-cobot-vendors.md`, `02-safety-standards.md`,
> `03-ux-patterns.md`) 에서 도출한 패턴 중 **DarwinForge 코드베이스에
> 직접 옮길 수 있는 것**만 추려 우선순위와 구현 스케치를 정리.
>
> 출처 URL 필수, 미확인 항목은 "확인 필요". 학술 인용 [Author Year].

## 0) 적용 우선순위 (★★★ → ★)

| 항목 | 산업 출처 | 우리 코드 위치 | 분기 |
|------|-----------|----------------|------|
| **PL 등급 UI 뱃지** | ISO 13849-1 PLd | SwiftUI `SafetyBadge` (신설) | Q1 |
| **Pose Capture (Direct teach)** | UR Free-drive / KUKA Hand-guiding | `PoseCaptureView` + `forge-core::capture` | Q1 |
| **3-position enabling 메타포** | KUKA smartPAD | `EnablingSwitchModifier` (SwiftUI) | Q1 |
| **모드 토글 T1 / T2 / AUT** | KUKA Mode Selector | 우상단 `ModeSelector` | Q2 |
| **Skill Block 시각화** | Doosan DART-Studio | `MotionTimeline` 노드 | Q2 |
| **Safety-rated monitored stop (SS1/SS2)** | IEC 61800-5-2 | `forge-core::safety::ss_stop` | Q2 |
| **Safety Bubble (ISO 13855)** | UR SafeMove / ABB SafeMove4 | SceneKit 가상 영역 | Q3 |
| **Black Box 사후 로그 (L6)** | UR Dashboard / FANUC Diagnostics | `~/Library/Logs/DarwinForge/incidents/` | Q3 |
| **L0 전원 차단 메타포** | ISO 13850 §5.4 | App Quit 시 SYNC_WRITE Torque OFF | Q1 |

(출처: 본 문서 §1~§9에서 인용)

---

## 1) PL 등급 UI 뱃지 ★★★

### 동기

산업 cobot은 펜던트 어디서나 "지금 PLd, Cat 3, ISO 10218 적합" 뱃지를 보여준다. 사용자가 "지금 어떤 안전 모드?" 즉답.

DarwinForge는 SW only 라 공식 PL 인증 어렵지만, "PLd 동등 설계" 자기 선언 가능 (이미 5계층으로 사실상 만족).

### SwiftUI 구현 스케치

```swift
struct SafetyBadge: View {
    let mode: SafetyMode  // .sim / .real
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mode == .sim ? .green : .blue)
                .frame(width: 8, height: 8)
            Text(mode == .sim ? "PLd 동등 (시뮬)" : "PLd 동등 (실)")
                .font(.caption.weight(.semibold))
            Text("Cat 3 / ISO 13849-1")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Material.thin, in: Capsule())
    }
}
```

배치: 우상단, E-Stop 버튼과 같은 toolbar 라인. **한국어 라벨 = "PLd 동등 (시뮬)"** 토스 해요체 친화.

(출처: ISO 13849-1:2023 §4.5 PL 정의 — https://www.iso.org/standard/85931.html ; UR PolyScope Safety Configuration UI 캡처는 공개 문서에서 확인 가능 — https://www.universal-robots.com/articles/ur/polyscope/safety-system/)

> ★ DarwinForge 적용:
> - 1주 분량 작업. 즉시 적용 가능.

---

## 2) Pose Capture (Direct teach) — DARwIn-OP 근사 ★★★

### 산업 출처

- UR **Free-drive** (펜던트 후면 dead-man 버튼) — `01-cobot-vendors.md` §1
- KUKA **Hand-guiding** (LBR iiwa 7축 토크 센서) — `01-cobot-vendors.md` §4
- Doosan **Direct teach** (단말 버튼) — `01-cobot-vendors.md` §6

### DARwIn-OP 한계

force-torque 센서 없음. 대신:

1. **Dynamixel `present_position` (Reg 132)** — 50 Hz 폴링 가능, 정확도 0.088°.
2. **Dynamixel `present_load` (Reg 126)** — signed 11-bit, 외력 추정값. 노이즈 큼 (±10% 분산 추정 — **확인 필요**: 실측 필요).
3. **Dynamixel `present_current` (Reg 144)** — MX-28에는 없음, MX-28-AT 또는 MX-28-T (XM430-W350) 만 가능. **확인 필요**: 표준 DARwIn-OP의 어느 펌웨어 / HW 변형.

### 구현 흐름

```
사용자: "이 자세 캡처해 줘"
   ↓
SwiftUI: PoseCaptureView 등장
   ↓
사용자: Space 키 hold (Free-drive 메타포)
   ↓
forge-core::capture::start():
   - 모든 모터 SYNC_WRITE torque_enable = 0
   - 50 Hz로 present_position 폴링 시작
   - present_load EWMA (α=0.3) → "외력 감지" UI 시각화
   ↓
사용자: 로봇 팔을 잡고 자세 잡음
   ↓
사용자: Space 떼기
   ↓
forge-core::capture::end():
   - 현재 present_position 스냅샷 (20개 관절)
   - SYNC_WRITE torque_enable = 1 (자세 락)
   ↓
SwiftUI: ToolCallCard "이 자세를 'Wave' 라는 이름으로 저장할까요?"
   ↓
사용자: 승인 (HITL L4)
   ↓
SwiftData: Motion(name: "Wave", joints: [...]) 저장
```

### 안전 고려

**중요**: DARwIn-OP는 토크 OFF 시 무릎이 풀려 **앉음 자세로 천천히 무너짐** (정적 안정성 확보됨). 그러나:

- **선 자세에서 토크 OFF 금지** — 머리부터 떨어질 수 있음. UI에서 "캡처 모드 진입 전 자동 무릎 꿇기" 자세 권장.
- **양 다리 일제히 토크 OFF 금지** — 한쪽씩 단계적 OFF.

(출처: ROBOTIS DARwIn-OP 매뉴얼 — https://emanual.robotis.com/docs/en/platform/op/getting_started/ ; Dynamixel MX-28 메모리 맵 — https://emanual.robotis.com/docs/en/dxl/mx/mx-28/ ; [Ha 2011] Ha et al. "Development of Open Humanoid Platform DARwIn-OP", *SICE Annual Conference*. https://ieeexplore.ieee.org/document/6060523)

> ★ DarwinForge 적용:
> - **2주 분량**. `forge-core::capture` Rust crate 신설.
> - **확인 필요**: 어느 자세에서 토크 OFF가 안전한지 휴머노이드 안정성 매트릭스 작성. 학술적으로 ZMP 기반.

---

## 3) 3-position Enabling Switch — 메타포 ★★★

### 산업 출처

KUKA smartPAD 좌·우측 인에이블 스위치. 놓음 / 중간 / 꽉 누름 = OFF / ON / OFF (panic grip 가정). ISO 10218-1:2025 §5.7.4 권장.

### macOS 키보드 매핑

| 산업 산식 | DarwinForge 매핑 | 비고 |
|-----------|------------------|------|
| 놓음 | (수정자 키 없음) | Speed Override = 0 (정지) |
| 중간 | `⌘` 단독 hold | Speed Override = 25% (안전 저속) |
| 꽉 누름 | `⌘ + Shift` hold | Speed Override = 100% (정상) |
| panic grip 시뮬 | `⌘ + Shift + Esc` | Speed Override = 0 + E-Stop 발사 |

### SwiftUI 구현 스케치

```swift
struct EnablingSwitchModifier: ViewModifier {
    @State private var modifiers: NSEvent.ModifierFlags = []
    @Environment(\.speedOverride) private var speedOverride

    func body(content: Content) -> some View {
        content
            .onContinuousHover { _ in /* idle */ }
            .onAppear {
                NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    modifiers = event.modifierFlags
                    let mode: SpeedMode = switch (modifiers.contains(.command),
                                                   modifiers.contains(.shift)) {
                        case (true, true): .normal       // 100%
                        case (true, false): .slow        // 25%
                        default: .stopped                // 0%
                    }
                    speedOverride.update(mode)
                    return event
                }
            }
    }
}
```

### 한국어 UX 라벨

- ⌘ + Shift hold 표시: **"정상 속도"**
- ⌘ 단독 hold 표시: **"안전 저속"**
- 무수정자: **"대기 (정지)"**

(출처: ISO 10218-1:2025 §5.7.4 ; KUKA smartPAD 매뉴얼 — https://www.kuka.com/en-de/products/robot-systems/software/system-software/kuka_smarthmi ; [Wakita 2008] Wakita "Three-position switch", *IEEE Robotics & Automation Magazine*. **확인 필요**: 정확한 인용)

> ★ DarwinForge 적용:
> - **3일 분량**. SwiftUI `@Environment` 키 추가 + `IntentDispatcher`에 speed override 적용.
> - **이미 5계층 모델의 L4 HITL 자연 확장**.

---

## 4) Operating Mode Selector (T1 / T2 / AUT) ★★★

### 산업 출처

KUKA Mode Selector (펜던트 우상단 회전형) — `03-ux-patterns.md` §4.

### DarwinForge 매핑

| 산업 모드 | DarwinForge 모드 | 한국어 라벨 | 동작 |
|-----------|------------------|-------------|------|
| **T1** Test 1 (≤ 250 mm/s) | **시연 모드** | "시연 (저속)" | Speed × 0.25, HITL 강제 |
| **T2** Test 2 (full speed, manual) | **정상 모드** | "정상" | Speed × 1.0, HITL 권장 |
| **AUT** Automatic | **자동 모드** | "자동" | Speed × 1.0, HITL 일부 자동 승인 |

UI 위치: 우상단 toolbar, E-Stop 옆.

```
[E-Stop]  DarwinForge   [모드: 시연 ▾]  [PLd 동등]  [⌘+Shift 정상]  [27분]
```

### 시나리오 매핑 (사용자 청 요청)

#### 시연 모드 (Demo Mode)

- **대상**: 외부 시연, 처음 보는 사람.
- **Speed Override**: 25%.
- **HITL**: 모든 명령 강제 승인.
- **자동 음성**: "지금 시연 모드라 천천히 움직여요. ⌘+Shift 누르면 정상 속도가 돼요."

#### 교육 모드 (Education Mode)

- **대상**: 학생, 신입.
- **Speed Override**: 50%.
- **HITL**: 처음 5번은 강제 승인, 그 이후 자동 승인.
- **자동 학습 카드**: 명령 실행 후 "방금 어떤 도구가 호출됐는지" 설명 카드.

#### 안전 점검 모드 (Safety Check Mode)

- **대상**: 매주 1회 정기 점검 (KOSHA Guide M-91-2012 §7).
- **시퀀스**:
  1. 배터리 셀 전압 측정 (각 셀 3.7~4.2 V).
  2. 모터 ID 1~20 핑.
  3. IMU 가속·자이로 zero-rate 측정.
  4. CM-740 펌웨어 버전 확인.
  5. 모터 `present_temperature` ≥ 60°C 경고.
  6. 충돌 감지 임계값 검증.
- **결과**: 점검 보고서 PDF 자동 생성 → `~/Documents/DarwinForge/safety-checks/<date>.pdf`.

(출처: ISO 10218-1:2025 §5.4 Operating Modes ; KOSHA Guide M-91-2012 §7 — https://www.kosha.or.kr/ ; ROBOTIS Dynamixel 온도 한계 — https://emanual.robotis.com/docs/en/dxl/mx/mx-28/ )

> ★ DarwinForge 적용:
> - **모드 토글 = 1주 분량**.
> - **시나리오 시퀀스 = 2주 분량 (각 시나리오별 SwiftUI 흐름).**
> - **확인 필요**: KOSHA Guide M-91-2012 §7 정확한 체크리스트 항목 — 우리가 인용한 6개는 일반 휴머노이드용 추정. KOSHA 원문은 산업 매니퓰레이터 기준이라 일부 해석 적용 필요.

---

## 5) Safety-rated Monitored Stop (SS1 / SS2) ★★

### 산업 출처

- **SS1 (Safe Stop 1)** — 동력 차단 후 감속, 감속 완료 후 STO (Safe Torque Off). IEC 61800-5-2.
- **SS2 (Safe Stop 2)** — 동력 유지하면서 감속, 정지 후 자세 잠금 유지.

DarwinForge 현재 E-Stop = SS1 (모든 토크 OFF, 자세 풀림). **SS2 추가 후보**.

### 구현 스케치

```rust
// forge-core/src/safety/ss_stop.rs

pub enum StopCategory {
    Cat0_STO,   // 즉시 토크 OFF (현재 E-Stop)
    Cat1_SS1,   // 감속 후 토크 OFF
    Cat2_SS2,   // 감속 후 자세 잠금 (토크 ON 유지)
}

pub fn safe_stop(category: StopCategory, port: &mut SerialPort) -> Result<()> {
    match category {
        StopCategory::Cat0_STO => {
            // 모든 모터 SYNC_WRITE torque_enable = 0
            sync_write_torque_off(port)?;
        }
        StopCategory::Cat1_SS1 => {
            // 1) 모든 goal_position을 present_position으로 (즉시 정지)
            // 2) 100 ms 대기
            // 3) torque_enable = 0
            ramp_down_then_off(port, Duration::from_millis(100))?;
        }
        StopCategory::Cat2_SS2 => {
            // 1) 모든 goal_position을 present_position으로
            // 2) torque_enable 유지 (자세 락)
            ramp_down_lock(port)?;
        }
    }
    Ok(())
}
```

### 시나리오

- **시연 중 사람 손이 다가옴 → SS2** (자세 유지, 사람이 지나가면 자동 재가동)
- **배터리 부족 경고 → SS2** (자세 유지, 사용자가 충전기 연결할 시간)
- **물리 충돌 감지 → SS1** (감속 + 토크 OFF)
- **사용자 E-Stop → 즉시 STO** (현재 동작)

(출처: IEC 61800-5-2:2016 — https://webstore.iec.ch/publication/22810 ; UR Safety Functions — https://www.universal-robots.com/articles/ur/safety/safety-functions-and-safety-i-o-of-e-series/)

> ★ DarwinForge 적용:
> - **2주 분량**. `forge-core::safety::ss_stop` 모듈 추가.
> - **현재 fc_emergency_stop = Cat0** 유지하고, **신규 fc_safety_pause = Cat2** 추가.

---

## 6) Safety Bubble — ISO 13855 가상 안전 거리 ★

### 산업 출처

UR SafeMove / ABB SafeMove4 / Yaskawa FSU 모두 가상 cuboid 안전 영역. 인간이 침입 시 자동 감속.

### DarwinForge 적용

DARwIn-OP 자체가 작아 (45 cm) 사람과 직접 충돌 위험은 낮으나, **시연 중 어린이 손가락이 모터 사이에 끼는 사고 시나리오** 는 실재.

```
                Safety Bubble
              ┌────────────────┐
              │      ┌──┐      │  반경 R = K × T_react + C
              │      │🤖│      │     (K=2000mm/s, T=50ms, C=0)
              │      └──┘      │     = 100 mm
              │                │
              │   사람 손이    │  ← 100 mm 이내 진입 시
              │   여기 있으면  │     자동 감속 (Speed × 0.25)
              └────────────────┘
                       👋
```

향후 macOS Vision API (`VNDetectHumanHandPoseRequest`) 로 카메라 손 검출 시 자동 감속 가능. 현재 우리 카메라 미사용 — 시각화만 SceneKit으로.

(출처: ISO 13855:2010 — https://www.iso.org/standard/42205.html ; Apple Vision Hand Pose — https://developer.apple.com/documentation/vision/detecting_human_body_poses_in_images)

> ★ DarwinForge 적용:
> - **3주 분량 + Vision API 통합**.
> - **3순위 (장기)**.

---

## 7) Black Box Post-mortem (L6) ★★

### 산업 출처

- UR `dashboard server` (TCP 29999) — 마지막 충돌 사건 자동 보존.
- FANUC `iRPickTool` — 모터 전류 / 위치 12시간 ring buffer.
- Doosan `safety_log` — TÜV 인증 요건.

### DarwinForge 구현

```
~/Library/Logs/DarwinForge/
├── incidents/
│   └── 2026-05-10_14-23-07/
│       ├── telemetry.csv         # 직전 60 s, 50 Hz, 20 관절
│       ├── command_history.json  # 직전 50 Claude 호출
│       ├── system_state.json     # 배터리/펌웨어/온도
│       ├── stack_trace.txt       # Swift / Rust panic
│       └── user_consent.txt      # 익명 분석 동의 여부
└── current/
    └── current.log               # 일반 로그
```

자동 트리거:
- E-Stop 발사 시
- `forge-core::safety::SafetyGate` 거부 시
- App crash 시

사용자 옵션: "익명으로 분석에 도움 주기" (Sentry-style opt-in, 기본 OFF).

(출처: UR Dashboard Server — https://www.universal-robots.com/articles/ur/dashboard-server-cb-series-port-29999/ ; Sentry SDK — https://docs.sentry.io/)

> ★ DarwinForge 적용:
> - **2주 분량**. `forge-core::log::incident` 모듈 신설.
> - **GDPR / PII 검토 필요** (확인 필요).

---

## 8) L0 — 전원 차단 메타포 ★★★

### 산업 출처

ISO 13850 §5.4 — "Mains disconnection" — 펜스가 없어도 동력 완전 차단을 1차 비상 수단으로 권장.

### DarwinForge 적용

DarwinForge는 SW 라 직접 USB 전원 차단 불가. 그러나:

1. **앱 강제 종료 (`Cmd+Q` 또는 Force Quit)** → SIGTERM 시 `Drop` impl 에서 모든 모터 `torque_enable = 0` SYNC_WRITE 발사.
2. **USB 케이블 분리 시** → CM-740이 power off, 자세는 풀리지만 외부 (전원·USB hub) 가 차단된 상태라 가장 확실.
3. **사용자 매뉴얼 첫 페이지에 "1순위 비상 = 케이블 분리"** 명시.

### Rust 구현 (SIGTERM 핸들러)

```rust
// forge-core/src/lifecycle.rs

use signal_hook::{consts::SIGTERM, iterator::Signals};

pub fn install_l0_handler(port: Arc<Mutex<SerialPort>>) {
    std::thread::spawn(move || {
        let mut signals = Signals::new(&[SIGTERM]).unwrap();
        for _ in signals.forever() {
            let mut port = port.lock().unwrap();
            // 모든 모터 토크 OFF (best effort)
            let _ = sync_write_torque_off(&mut port);
            std::process::exit(0);
        }
    });
}
```

(출처: ISO 13850:2015 §5.4 — https://www.iso.org/standard/59970.html ; signal-hook crate — https://docs.rs/signal-hook/)

> ★ DarwinForge 적용:
> - **3일 분량**. 즉시.
> - **이미 부분 채택** — SwiftUI App `onDisappear` 에서 토크 OFF. SIGTERM 핸들러로 강건성 강화.

---

## 9) 종합 — 우리 5계층의 6계층 (또는 7계층) 진화

```
DarwinForge Safety Stack — 진화안:

  L0  Power Disconnect          ← 신규 (앱 종료/USB 분리)
  ───────────────────────────────
  L1  LLM Refusal               ← 기존 (Claude prompt)
  L2  Tool Whitelist            ← 기존 (Swift IntentDispatcher)
  L3  Safety Clip / PFL         ← 기존 (각도/속도 클램프)
  L4  HITL + Mode + Enabling    ← 기존 + 강화 (3-pos / T1·T2·AUT)
  L5  Hardware E-Stop (Cat-1)   ← 기존 (좌상단 빨강)
  ───────────────────────────────
  L6  Post-mortem Black Box     ← 신규 (incidents/ 로그)
```

각 계층 독립 채널. 단일 고장이 다른 계층 막지 않음 (ISO 13849-1 Cat 3 정신).

### 매트릭스 (산업 cobot ↔ DarwinForge)

| DarwinForge | 산업 출처 | 차용 우선순위 |
|-------------|-----------|---------------|
| **L0 Power** | ISO 13850 §5.4, 모든 cobot 메인 차단 | ★★★ Q1 |
| **L1 Refusal** | (LLM 영역, 산업 미존재) | (기존, 그대로) |
| **L2 Whitelist** | ISO 10218-2 §5.5 Restricted Space | (기존, 그대로) |
| **L3 Safety Clip** | ISO/TS 15066 §5.5 PFL + ISO 10218-1 §5.10.5 | (기존, 그대로) |
| **L4 HITL + Mode + Enabling** | ISO 10218-1:2025 §5.7.4 + KUKA smartPAD | ★★★ Q1 강화 |
| **L5 E-Stop (Cat-1)** | ISO 13850:2015 | (기존, 그대로) |
| **L6 Black Box** | UR Dashboard / FANUC iRPickTool / Doosan safety_log | ★★ Q3 |

(출처: 본 문서 §1~§8 인용 ; 학술 [Lasota 2017] "A Survey of Methods for Safe Human-Robot Interaction" — https://doi.org/10.1561/2300000052)

---

## 10) 시연 / 교육 / 안전 점검 시나리오 — 통합 예시

### 시연 시나리오 (5분 데모)

```
1. 사용자 앱 실행
   → L0 power-on, 모든 모터 torque OFF (안전 시작 자세)
2. UI: "지금 시연 모드입니다. ⌘+Shift hold 시 정상 속도가 돼요."
3. 사용자: "안녕 손 흔들어"
   → L1 통과 (안전 명령) → L2 (motion 도구 허용) → L3 (속도 25% 클립)
   → L4: ToolCallCard "fc_motion_play(page=23)" 표시
4. 사용자: ⌘+Shift hold 후 "실행" 탭
   → L5 (E-Stop 대기) → 모터 출력
5. 외부인이 갑자기 다가옴
   → 사용자 ESC 키 (L5 발사)
   → SS1 (감속 후 STO)
   → L6 자동 incident 로그 저장
```

### 교육 시나리오 (학교 수업)

```
1. 교사 준비:
   - 모드 = "교육 모드" (Speed × 0.5)
   - Skill Block 시각화 ON (DART-Studio 차용)
2. 학생: "춤춰"
   → LLM이 fc_motion_play(page=27) 출력
   → SwiftUI: Skill Block 시각화로 "[Move] Page=27 'Dance'" 카드
   → 학생이 카드를 보며 "어떤 도구가 호출됐는지" 학습
3. 학생: 카드의 페이지 번호 수정
   → 양방향 동기 → LLM 다음 호출에 반영
```

### 안전 점검 시나리오 (주간 점검)

```
1. 사용자: "안전 점검"
   → 시퀀스 자동:
      a. 배터리 셀 전압 (3.7~4.2 V)
      b. 모터 ID 1~20 핑
      c. IMU zero-rate (60 s 정지 측정)
      d. CM-740 펌웨어 버전 ≥ 4.0
      e. 모터 온도 < 60°C
2. 결과 PDF 자동 생성 (KOSHA Guide M-91-2012 §7 양식)
3. 이상 발견 시 → L6 incident 로그 + 사용자에게 음성 안내
```

(출처: KOSHA Guide M-91-2012 — https://www.kosha.or.kr/ ; ROBOTIS DARwIn-OP 매뉴얼 — https://emanual.robotis.com/docs/en/platform/op/getting_started/)

---

## 학술 인용

- [Ha 2011] Ha et al. "Development of Open Humanoid Platform DARwIn-OP", *SICE Annual Conference*. https://ieeexplore.ieee.org/document/6060523
- [Lasota 2017] Lasota et al. "A Survey of Methods for Safe Human-Robot Interaction", *Foundations and Trends in Robotics*. https://doi.org/10.1561/2300000052
- [Vasic 2013] Vasic and Billard "Safety issues in human-robot interactions", *IEEE ICRA*. https://doi.org/10.1109/ICRA.2013.6630576
- [Bai 2022] Bai et al. "Constitutional AI: Harmlessness from AI Feedback", *arXiv:2212.08073*. https://arxiv.org/abs/2212.08073

## 출처 종합

- ISO 13849-1:2023 — https://www.iso.org/standard/85931.html
- ISO 10218-1:2025 — https://www.iso.org/standard/73933.html
- ISO/TS 15066:2016 — https://www.iso.org/standard/62996.html
- ISO 13850:2015 — https://www.iso.org/standard/59970.html
- ISO 13855:2010 — https://www.iso.org/standard/42205.html
- IEC 61800-5-2:2016 — https://webstore.iec.ch/publication/22810
- KOSHA Guide M-91-2012 — https://www.kosha.or.kr/
- ROBOTIS DARwIn-OP — https://emanual.robotis.com/docs/en/platform/op/getting_started/
- Dynamixel MX-28 — https://emanual.robotis.com/docs/en/dxl/mx/mx-28/
- UR Dashboard Server — https://www.universal-robots.com/articles/ur/dashboard-server-cb-series-port-29999/
- KUKA smartPAD — https://www.kuka.com/en-de/products/robot-systems/software/system-software/kuka_smarthmi
- Doosan DART-Studio — https://www.doosanrobotics.com/en/products/dart-suite
- Apple Vision Hand Pose — https://developer.apple.com/documentation/vision/detecting_human_body_poses_in_images
