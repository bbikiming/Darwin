# STPA Analysis — DarwinForge 2026-05-24

> Systems-Theoretic Process Analysis (Leveson, *Engineering a Safer World*, MIT Press 2012).
> 본 문서는 V286-1 의 Hazard 8건 (H1-H8) 과 V282-5 의 CRITICAL 잔존 결함을
> STPA framework 로 재정리한 사이클 V287-4 산출물.

| 항목 | 값 |
|---|---|
| 작성일 | 2026-05-24 (KST) |
| 사이클 | V287-4 |
| 방법론 | STPA (Leveson MIT, 2012) |
| 대상 | DarwinForge macOS app + ROBOTIS-OP2 robot |
| 인용 | V286-1 hazard 분석 보고, V282-5 critic 보고 |
| 관련 ADR | ADR-001 (Harness DI), ADR-002 (Wave 4) |

---

## 1. System Definition

### 1.1 System Boundary

DarwinForge 는 ROBOTIS-OP2 휴머노이드 robot 의 교육용 제어 SwiftUI macOS app.
boundary 는 다음을 포함:

- **In-scope**: DarwinForge app (UI / ConnectionStore / IntentDispatcher / WalkLabSession / WalkCycleEngine), FFI Bus (Swift ↔ Dynamixel C SDK), USB-Dynamixel 통신, robot motor 20 dof.
- **Out-of-scope**: robot 외부 환경 물체, 사용자 신체 제어, OS 커널.

### 1.2 Stakeholders

| Stakeholder | 이해관계 |
|---|---|
| 운영자 (operator) | 안전한 조작, 직관적 UI feedback |
| 운영자 주변 인원 | robot fall / 충돌로부터 보호 |
| Robot 본체 | motor 과부하 / fall damage 회피 |
| 교육기관 | 장비 보존, 사고 책임 회피 |
| 개발자 (DarwinForge maintainer) | 안전 결함 audit trail |

### 1.3 Losses (L1-L4)

STPA 의 "Loss" 는 stakeholder 가 수용 불가능한 결과.

| Loss ID | 정의 | Severity | 관련 ISO 13482 risk class |
|---|---|---|---|
| **L1** | 사용자 또는 주변인 부상 (robot fall onto person, joint pinch) | Catastrophic | Class A (life-threat) |
| **L2** | Robot 자기 손상 (motor 과부하, fall 으로 frame 손상) | Major | Class B (asset) |
| **L3** | 환경 손상 (object 충돌, 작업대 흠집) | Moderate | Class C (property) |
| **L4** | 데이터 손실 (telemetry 미저장, audit trail 결손) | Minor | Class D (operational) |

### 1.4 System-level Hazards (H1-H8)

V286-1 에서 식별한 8건 — STPA 의 "System Hazard" = system state + worst-case environment → loss 로 이어지는 조건.

| Hazard | 정의 | Loss 매핑 |
|---|---|---|
| **H1** | E-Stop 명령이 dxlPower OFF 로 전파 실패 (IntentDispatcher chain 단절) | L1, L2 |
| **H2** | Joint write limit 초과 (writeJointPosition wrapper 우회) | L1, L2 |
| **H3** | IMU stale >200ms 상태에서 walk 진행 (fall 감지 무력화) | L1, L2 |
| **H4** | dxlPower OFF 후 wrapper 우회 write 잔존 (zombie command) | L1, L2 |
| **H5** | Bus disconnect 시 motor coast (safe state 부재) | L1, L2 |
| **H6** | WalkLab scene preview → 실 motor 누출 (sim 의도 실제 실행) | L1, L2, L3 |
| **H7** | Reconnection race → stale command 발화 | L1, L2 |
| **H8** | Low battery 시 stand-up → 낙상 | L1, L2 |

---

## 2. Control Structure

### 2.1 Hierarchical Control Diagram (mermaid)

```mermaid
graph TD
    Operator["사용자 (operator)"] -->|click / hotkey| App["DarwinForge App (SwiftUI)"]
    App -->|UserIntent| ID["IntentDispatcher"]
    ID -->|.emergencyStop()| CS["ConnectionStore (@Observable)"]
    ID -->|.startWalk() / .stopWalk()| WLS["WalkLabSession"]
    WLS -->|gait phase| WCE["WalkCycleEngine"]
    WCE -->|setPosition| CS
    CS -->|writeJointPosition wrapper| Bus["FFI Bus (DynamixelBridge)"]
    Bus -->|FFI write| DXL["Dynamixel Joints (20 dof)"]
    DXL -->|sensor read| Bus
    Bus -->|telemetry packet| CS
    CS -->|@Observable state| UI["WalkLabView / JointControlView"]
    UI -->|visual feedback| Operator
    DXL -->|IMU 50Hz| Bus
    Bus -->|imuSample| WCE
    WCE -->|fall detect| WLS
    WLS -->|emergencyStop trigger| CS

    classDef control fill:#fff3cd,stroke:#d39e00
    classDef actuator fill:#f8d7da,stroke:#dc3545
    classDef sensor fill:#d4edda,stroke:#28a745
    class ID,CS,WLS,WCE control
    class Bus,DXL actuator
    class UI sensor
```

### 2.2 Control Loops (3 layer)

| Layer | Controller | Controlled Process | Feedback | Period |
|---|---|---|---|---|
| **L1: User Intent** | Operator → IntentDispatcher | App state machine | UI render | event-driven |
| **L2: Session** | WalkLabSession → WalkCycleEngine | gait phase | IMU + joint pos | 50 Hz |
| **L3: Actuation** | ConnectionStore → FFI Bus | Dynamixel joints | telemetry read | 50 Hz |

### 2.3 Control Action 인벤토리

8개 주요 Control Action 식별 (UCA 분석 대상):

| CA-ID | Control Action | Controller | Controlled Process |
|---|---|---|---|
| CA-1 | `emergencyStop()` | IntentDispatcher | ConnectionStore.dxlPower |
| CA-2 | `writeJointPosition(joint, value)` | WalkCycleEngine | Dynamixel joint |
| CA-3 | gait phase update | WalkCycleEngine | WalkLabSession state |
| CA-4 | `writeJointPosition` after dxlPower OFF | WalkCycleEngine | Dynamixel joint |
| CA-5 | `dxlPower(false)` on bus disconnect | ConnectionStore | Dynamixel power |
| CA-6 | scene preview render | WalkLabSceneSection | sim view (intent) / motor (leak) |
| CA-7 | reconnect + command flush | ConnectionStore | FFI Bus |
| CA-8 | walking start (preflight bypass) | IntentDispatcher | WalkLabSession |

---

## 3. Unsafe Control Actions (UCA) — 8개 매핑

STPA UCA 4분류 (Leveson 2012, ch.8):

- **Not-provided**: CA 가 필요했으나 발화되지 않음
- **Provided-wrong**: CA 가 잘못된 값으로 발화됨
- **Wrong-time**: CA 가 너무 빠르거나 늦게 발화됨
- **Wrong-duration**: CA 가 너무 짧거나 길게 적용됨

### 3.1 UCA 매핑 표

| UCA ID | Control Action | UCA Type | Hazard | V282-5 CRITICAL 매핑 |
|---|---|---|---|---|
| **UCA-1** | `emergencyStop()` | not-provided | H1 | **C1** (IntentDispatcher e-stop chain 단절) |
| **UCA-2** | `writeJointPosition` | provided-wrong | H2 | — (joint limit clamp 부재, V288 신규) |
| **UCA-3** | gait phase update | wrong-time | H3 | — (IMU stale walk 진행, V283-2 trail) |
| **UCA-4** | `writeJointPosition` after OFF | wrong-duration | H4 | **C2** (WalkCycleEngine gate 우회) |
| **UCA-5** | `dxlPower(false)` on disconnect | not-provided | H5 | — (motor coast risk) |
| **UCA-6** | scene preview render | provided-wrong | H6 | — (sim 의도 실제 누출) |
| **UCA-7** | reconnect + command | wrong-time | H7 | — (race condition) |
| **UCA-8** | walking start | provided-wrong | H8 | — (low battery preflight 미적용) |

---

## 4. Loss Scenarios

각 UCA 에 대한 "왜 발생하는가" 분석 (STPA Step 4, Causal Scenarios).

### UCA-1 — emergencyStop() not-provided

- **시나리오**: 사용자가 E-Stop 버튼을 누름 → JointControlView 가 IntentDispatcher.emergencyStop() 호출 → IntentDispatcher 가 ConnectionStore.emergencyStop() 미호출 → WalkLabSession 의 8단계 chain (walkCycleTask cancel → setPosition halt → dxlPower OFF → recovery flag) 미발화 → walkCycleTask 잔존 → recovery 시 setPosition 재개.
- **Root cause**: IntentDispatcher 의 e-stop handler 가 store 의 SSoT API 를 우회하고 자체 dxlPower 만 호출. V282-5 critic 의 C1 finding 직접 매핑.
- **Mitigation**: V283-3 commit (`fix(safety): 283-3 — JointControlView E-Stop bypass → store.emergencyStop() chain`) — 단, IntentDispatcher 본체는 다음 cycle.

### UCA-2 — writeJointPosition provided-wrong

- **시나리오**: WalkCycleEngine 이 gait planner 의 IK 결과를 writeJointPosition 으로 전달 → 입력 값이 joint 의 mechanical limit (예: knee 0-150°) 을 초과 → Dynamixel 이 limit clamp 미수행하면 stall current → motor over-heat → 손상.
- **Root cause**: writeJointPosition wrapper 에 per-joint min/max clamp 부재. (V283-4 의 dxlPower gate 는 적용되었으나 value clamp 는 별도 task.)
- **Mitigation 권고**: writeJointPosition 내부에서 `JointLimits.clamp(joint, value)` 호출 추가.

### UCA-3 — gait phase update wrong-time

- **시나리오**: IMU sample 이 last update 후 200ms 이상 stale → fall 감지 알고리즘이 직전 값으로 평가 → 실제로 robot 이 기울어진 상태인데 walk 계속 진행 → 낙상.
- **Root cause**: WalkCycleEngine 의 step 함수가 IMU age 검증 없이 phase advance.
- **Mitigation**: V283-2 에서 5s threshold 도입 시도, 그러나 200ms 가 더 엄격함. V287-2 의 ZMP gate 와 함께 freeze 감지 필요.

### UCA-4 — writeJointPosition after OFF wrong-duration

- **시나리오**: E-Stop 으로 dxlPower OFF 발화 → 그러나 WalkCycleEngine 의 `bus.setPosition` 직접 경로가 wrapper 우회 → OFF 후에도 일정 시간 setPosition 명령 발화 → motor 가 잠시 다시 on → coast vs hold 불일치.
- **Root cause**: WalkCycleEngine 이 store.writeJointPosition (gate 보유) 가 아니라 bus.setPosition (gate 없음) 사용. V282-5 의 C2 finding 직접 매핑.
- **Mitigation 권고**: WalkCycleEngine 의 bus.setPosition 모든 호출을 store.writeJointPosition 으로 교체.

### UCA-5 — dxlPower OFF on disconnect not-provided

- **시나리오**: USB 케이블 분리 또는 bus error → ConnectionStore 가 disconnect 상태로 전환 → 그러나 dxlPower 는 마지막 ON 값 유지 → 재연결 시 motor 가 갑자기 부팅 시 위치로 coast → 사용자 부상.
- **Root cause**: disconnect handler 가 자동 safe state (dxlPower OFF) 미적용.
- **Mitigation 권고**: disconnect detection 시 dxlPower(false) 강제.

### UCA-6 — scene preview provided-wrong

- **시나리오**: WalkLab scene preview 가 sim only 의도 → 그러나 sceneSection 의 binding 이 실제 ConnectionStore 의 writeJointPosition 으로 leak → 사용자가 "preview" 클릭 시 실제 motor 가 움직임.
- **Root cause**: scene preview path 의 명시적 sim-vs-real 분리 부재.
- **Mitigation 권고**: scene preview API 에 `simOnly: true` enforce, 실 bus write 차단 assertion.

### UCA-7 — reconnect + command wrong-time

- **시나리오**: bus 일시 disconnect → 큐에 명령 누적 → reconnect 직후 누적 명령이 한꺼번에 발화 → robot 이 갑작스러운 큰 움직임.
- **Root cause**: reconnect 시 command queue flush 부재 + race condition (reconnect lock 없음).
- **Mitigation 권고**: reconnect lock + queue flush 명시.

### UCA-8 — walking start provided-wrong

- **시나리오**: 배터리 잔량 <15% 인 상태에서 사용자가 walk 시작 → motor 가 stand-up phase 에서 brown-out → drop.
- **Root cause**: V264-1 의 battery preflight 가 L0 (warning) 만 표시, L1 (block) 미강제.
- **Mitigation 권고**: low battery threshold 미만 시 walk start API 가 throw.

---

## 5. Mitigation 매핑 (현재 적용 + 권고)

| UCA | 현재 적용 (commit) | V287-x 권고 |
|---|---|---|
| UCA-1 | V283-3 (JointControlView E-Stop bypass fix) | IntentDispatcher → store.emergencyStop() chain 본체 완성 |
| UCA-2 | (미적용) | writeJointPosition 의 per-joint min/max clamp 추가 |
| UCA-3 | IMU stale 5s threshold (V283-2 부분 적용) | 200ms threshold + ZMP gate (V287-2) + freeze 감지 |
| UCA-4 | dxlPower gate (V283-4) | WalkCycleEngine 의 bus.setPosition → store.writeJointPosition 교체 |
| UCA-5 | reconnect logic 일부 | dxlPower OFF on disconnect (auto safe state) 강제 |
| UCA-6 | (미적용) | scene preview = sim only enforce + assertion |
| UCA-7 | recovery state machine 일부 | reconnect lock + command queue flush 명시 |
| UCA-8 | battery preflight (V264-1 L0 warning) | low battery threshold → start API throw |

---

## 6. STPA Step 5 — Verification 권고

각 mitigation 에 대한 testable assertion:

- **UCA-1**: `IntentDispatcherTests.emergencyStop_calls_store_emergencyStop` (V283-3 에 일부 존재)
- **UCA-2**: `WriteJointPositionTests.value_clamped_to_joint_limit`
- **UCA-3**: `WalkCycleEngineTests.phase_not_advanced_when_imu_stale_200ms`
- **UCA-4**: `WalkCycleEngineTests.bus_setPosition_calls_replaced_with_store_writeJointPosition`
- **UCA-5**: `ConnectionStoreTests.disconnect_forces_dxlPower_false`
- **UCA-6**: `WalkLabSceneTests.preview_never_calls_real_bus_write`
- **UCA-7**: `ConnectionStoreTests.reconnect_flushes_command_queue`
- **UCA-8**: `IntentDispatcherTests.startWalk_throws_when_battery_below_threshold`

---

## 7. 참조

- Leveson, N. G. *Engineering a Safer World: Systems Thinking Applied to Safety*. MIT Press, 2012.
- ISO 13482:2014 — *Robots and robotic devices — Safety requirements for personal care robots*.
- NPR 7150.2D — *NASA Software Engineering Requirements* (Class C, 60% baseline).
- V286-1 보고: hazard 8건 식별 (in-cycle artifact).
- V282-5 critic 보고: CRITICAL C1 (IntentDispatcher chain), C2 (WalkCycleEngine gate).
- V283-3 commit `34c5b22`: `fix(safety): 283-3 — JointControlView E-Stop bypass → store.emergencyStop() chain`
- V283-4 commit `0dd6f1a`: `fix(safety): 283-4 — dxlPower OFF gate (writeJointPosition wrapper + 8 unit tests)`
