# Handoff — Remote Pilot v1.0 (Sprint 15)

> **상태**: UI 스캐폴드 완성 + 7 Action Bar 페이지 송출 (pose 기반)
> **빌드**: Swift 85 tests pass / Rust 83 tests pass / 회귀 0
> **진입**: ⌘8 — 사이드바 "원격 조종"
> **연관**: `docs/prd/teleop-v1.md` (v3 단일 설계), `docs/prd/teleop-v1.0-impl-prompt.md`

---

## 사용 흐름

1. **앱 실행** → 사이드바에서 **원격 조종 (⌘8)** 클릭.
2. 미연결 상태면 상단에 "시뮬 모드 — 실 로봇 연결 안 됨" 배너. 동작 버튼은 시각 미리보기만.
3. **ARM 슬라이더**를 우측으로 80% 끌면:
   - CM dxl_power ON
   - 모든 관절 torque ON
   - **보행 자세 (page 9 = walkready)** 자동 호출
   - 토스트: "준비 완료 — 동작 버튼을 눌러보세요"
4. **Action Bar 7 버튼** (또는 키 1..7) 으로 모션 송출:
   | 키 | 슬롯 | 라벨 | 안전 |
   |---|---|---|---|
   | 1 | 1 | 기본 자세 (init / Stand Up) | 안전 |
   | 2 | 4 | 감사 인사 (hi / Thank You) | 안전 |
   | 3 | 15 | 앉기 (sit down / Sit Down) | 안전 |
   | 4 | 12 | 오른발 차기 (rk / Right Kick) | **위험** — confirm 필수 |
   | 5 | 13 | 왼발 차기 (lk / Left Kick) | **위험** — confirm 필수 |
   | 6 | 9 | 보행 자세 (walkready) | 안전 |
   | 7 | 23 | 출발! (d1 / Yes Go) | 안전 |
5. **HighRisk (4·5)** 클릭 → "위험 동작 확인" alert → "확인 후 실행" 통과해야 송출.
6. **⌘⇧.** — 어떤 상태에서도 즉시 토크 OFF + motion task cancel + UI flash red.
7. **ESC** — DISARM (ARM 해제, motion task 취소).

## 비활성 컴포넌트 (ComingSoonOverlay)

각각 클릭하면 sheet 로 "무엇 / 왜 대기 / 언제 / 지금 할 수 있는 것" 안내:

| 컴포넌트 | 활성 단계 | 대기 사유 |
|---|---|---|
| Ball-Follow 모드 | v1.1 / v1.5 | head 추적 코드 → v1.5 카메라 + walk 자동 |
| D-pad 실 모터 송출 | v2 | BLOCKER C3 (실 IK) 해결 |
| 카메라 view | v1.5 | robot-side mjpg-streamer 셋업 |
| IMU 텔레메트리 | v1.1 | `CmController::read_imu()` 추가 |
| 자동 낙상 복구 | v1.1 | IMU + FallRecoveryCoordinator |
| "+ 더 보기" 9 페이지 | v1.5 | 메인 7 안정화 후 |

---

## v1.0 의 PRD 대비 적응 (중요)

본 PR 은 **`docs/prd/teleop-v1.0-impl-prompt.md` 의 UI 스코프 (Day 3-4) 만**
구현합니다. PRD 의 Day 1-2 (Rust forge-core motion player 라이브러리 + FFI)
는 별도 PR 로 미루었습니다.

### 미구현 (별도 PR 예정)

- `forge-core/src/motion/player.rs` — `MotionPlayer` struct
  - **이유**: PRD 는 "검증된 `forge motion play` 의 로직만 라이브러리로 추출"
    이라고 가정하지만, **현재 코드에 `forge motion play` CLI 가 존재하지 않습니다.**
    `forge-cli/src/main.rs` 의 `MotionAction` 은 import/export/inspect 만 제공.
  - **추가로 누락**: `precheck_motion`, `TorqueRamper`, `safety/torque_ramp.rs` 모두 존재하지 않음.
  - **선결 작업**: motion_4096.bin 페이지 디코더 + step interpolation + SYNC_WRITE
    goal_position 송출 경로 + cancellation 을 forge-core 에 구현.
- `forge-ffi` 의 `fc_motion_play_slot` / `fc_motion_play_cancel`
  — Day 1 결과물 의존.

### 대신 채택한 방식

v1.0 Action Bar 버튼은 motion_4096.bin 의 **raw step (4-step bow 등) 시간곡선
대신**, 각 페이지의 **최종 도달 자세 (target pose)** 를 `ConnectionStore.applyPoseSmoothly(_:)`
의 검증된 안전 경로로 송출합니다:

- voltage / load / 한계 / split 검증 통과
- TorqueRamper 효과는 단계별 분할 + moving_speed 로 부드러운 이동
- watchdog (load critical → e-stop) 살아있음
- cancellation 살아있음

각 슬롯 → pose 매핑은 `MotionCatalog.v1TargetPoseID` 에 명시:

| 슬롯 | v1 target pose |
|---:|---|
| 1 (init)        | `idle`              |
| 4 (hi)          | `bow_60`            |
| 9 (walkready)   | `walk_ready`        |
| 12 (rk)         | `kick_forward_right`|
| 13 (lk)         | `nil` — PoseLibrary mirror 없음, v1.5 raw step 활성 시 채워짐 |
| 15 (sit down)   | `sit_chair`         |
| 23 (d1 yes_go)  | `hands_up`          |

**제약**: 슬롯 13 (왼발 차기) 는 `v1TargetPoseID = nil` 이라 v1.0 에서는
실 모터 송출 불가 — 버튼은 비활성 표시 + "v1.5 에서 활성" 메시지.
나머지 6 페이지는 v1.0 에서 정상 송출.

### 결과적 차이

| 항목 | PRD v1.0 의도 | 본 PR 실제 |
|---|---|---|
| 송출 데이터 | motion_4096.bin byte-identical step | 검증된 RobotPose 의 final 자세 |
| 시간 곡선 | 페이지의 step pause + time | applyPoseSmoothly 의 trapezoidal + split |
| 송출 가능한 슬롯 | 7 | 6 (13 = 왼발 차기 누락) |
| HighRisk confirm | ✓ | ✓ |
| E-stop motion cancel | ✓ | ✓ |
| ARM 시퀀스 (dxl_power + torque + walkready) | ✓ | ✓ |
| UI 레이아웃 (v1.5 최종 형태) | ✓ | ✓ |
| ComingSoonOverlay | ✓ | ✓ |

motion_4096.bin 디코더가 forge-core 에 추가되면 (Sprint 15 Day 1 의 PR
별도 작업), `TeleopChannel.sendMotion` 만 `applyPoseSmoothly` → `MotionPlayer.playPage`
로 교체하면 됨. UI 코드는 변경 없음. 단계별 활성화 매트릭스가 의도한 분리.

---

## HIL 시나리오 (실 로봇 검증 필요)

PRD §2.1 의 4 시나리오는 실 로봇 + cradle 거치 후 본인 (또는 robotis-platform-test 팀)
이 직접 수동 검증. 본 PR 은 UI + simulated 송출 경로 + 단위 테스트만 보장.

| # | 시나리오 | 통과 기준 | 검증 방법 |
|---:|---|---|---|
| 1 | ARM 슬라이더 → walkready 자동 | 자세 도달 + 토스트 "준비 완료" | ⌘8 → 슬라이더 80% 끌기 |
| 2 | "감사 인사" (key 2) → 3.6s 진행링 + 실 모터 | bow_60 자세 도달 | 버튼 클릭 또는 키 2 |
| 3 | "오른발 차기" (key 4) → HighRisk confirm | kick_forward_right 자세 도달 | 버튼 → "확인 후 실행" |
| 4 | 차기 진행 중 ⌘⇧. | 즉시 토크 OFF + 다음 step 송출 X | E-Stop 버튼 또는 ⌘⇧. |

본 PR 머지 후, 로봇 cradle 에 거치하고 4 시나리오 1회씩 검증해 PROGRESS.md 갱신.

---

## 신규 파일

```
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/
├── MotionCatalog.swift        (16 페이지 sidecar + 슬롯/poseID 매핑)
├── PilotFeatureFlags.swift    (v1.0/v1.1/v1.5/v2 활성화 matrix)
├── PilotTokens.swift          (PilotColor / PilotAnim)
├── ComingSoonOverlay.swift    (`.comingSoon(...)` modifier + 상세 sheet)
├── PilotSafetyGate.swift      (L0/L1/L2 gate)
├── TeleopChannel.swift        (ARM / motion / cancel / E-stop)
├── PilotArmSlider.swift       (drag-to-arm 슬라이더)
├── PilotActionBar.swift       (7 버튼 + ComingSoonOverlay "+ 더 보기")
├── PilotModePicker.swift      (Manual / Ball-Follow toggle)
├── PilotDpad.swift            (7-zone sim 미리보기)
├── PilotSpeedGauge.swift      (sim speed bar)
├── PilotCameraView.swift      (회색 placeholder + 셋업 가이드 시트)
├── PilotHudStrip.swift        (V·T·세션·IMU·자동복구·E-Stop)
└── RemotePilotView.swift      (최상위 — 좌 360px / 우 fill)

app/ui/DarwinForge/Tests/DarwinForgeUITests/
└── PilotTests.swift           (13 단위 테스트)

docs/handoff/
└── teleop-v1.0-walkthrough.md (본 문서)
```

`RootView.swift` — `Section.pilot` 추가, ⌘8 키 바인딩, `RemotePilotView()` 라우팅.

## 검증

```bash
# Rust workspace
cargo test --manifest-path app/core/Cargo.toml --workspace
# → 83 pass, 0 fail

# Swift package (vendor lib 재빌드 후)
bash scripts/build-mac.sh          # Rust → libforge_core.a + forge_core.h
cd app/ui/DarwinForge && swift test
# → 85 pass, 0 fail (기존 72 + 신규 13)
```

## 다음 PR (별도)

1. **Sprint 15 Day 1-2 (Rust)** — `forge-core::motion::player::MotionPlayer`
   + `fc_motion_play_slot` FFI + motion_4096.bin 페이지 step decoder.
   완료 시 `TeleopChannel.sendMotion` 1 줄 교체로 raw step 송출 활성.
2. **Sprint 16 (v1.1)** — IMU + 자동 낙상 복구 + Head 추적.
3. **Sprint 17 (v1.5)** — 카메라 + Ball-Follow walk(sim) + Bridge + 더보기.
4. **Sprint 18+ (v2)** — BLOCKER C3 해결 → D-pad 실 모터 + Ball-Follow 실.
