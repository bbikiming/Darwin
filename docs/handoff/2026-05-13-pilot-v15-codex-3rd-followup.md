# Pilot v1.5 — Codex 3차 Follow-up Fix

**날짜**: 2026-05-13 (PR #21 후속 커밋)
**기반**: `docs/handoff/2026-05-13-walklab-pilot-no-motion-review.md` (Codex 작성 검수)

---

## 솔직한 결함 인정

Codex 의 3차 검수에서 지적된 7개 항목 중:

### PR #21 에서 안 고친 명백한 버그 3개 (내 회귀):

1. **armStage defer 버그 (P2)** — 내가 추가한 `.readyDegraded` / `.simReady` 가 함수 종료 시 `.idle` 로 되돌아감. defer 조건이 `.ready` 만 보존하던 v1.0 그대로.
2. **Action Bar enabled 로직 (P1)** — `gate.armed || !gate.armed` 는 v1.0 부터 무의미한 boolean 인데 PR 에서 안 고침.
3. **MotionCatalog tooltip (P0/A3)** — `source: motion_4096.bin page N` 이 raw chain 재생을 암시. 실제는 단일 PoseLibrary target 인데 사용자에게 명시 안 됨.

### PR #21 범위 밖이지만 사용자 보고와 통합된 격차 4개:

4. **WalkLab `runWalkCycle` silent failure (P0)** — 모든 write 가 `_ = try?` 로 swallow. torque OFF / 통신 실패 모두 "정상 종료" 처럼 보임.
5. **WalkLab cycle 시작 전 ARM 보장 없음 (P0)** — E-stop 후 dxl_power/torque ON 확인 안 함.
6. **D-pad 방향 무반응 (P1)** — `dpadRealMotor=false` 시 silently return → 사용자 "안 움직임" 인지.
7. **motion_4096.bin page chain 미구현 (P0)** — Sprint 16+ 별도 작업.

### 4가지 즉시 처리 가능 (이번 PR 추가 커밋), 1개 별도 PR:

- ✅ 본 follow-up: #1-6 처리
- ⏳ 별도 Sprint: #7 (motion_play 라이브러리 추출 + FFI + Swift wrapper)

---

## 본 follow-up 의 변경 (5 파일)

### `TeleopChannel.swift`
- `isTerminalReadyStage(_:)` 헬퍼 신규 — `.ready` / `.readyDegraded` / `.simReady` 화이트리스트
- `arm()` defer 가 화이트리스트로 변경 → readyDegraded/simReady 보존
- (다른 변경 없음)

### `PilotActionBar.swift`
- `@EnvironmentObject store: ConnectionStore` 추가
- `isSimMode` (bus == nil) 분기 도입
- `isEnabled` 로직 fix: `isSimMode || gate.armed` — 실 모드는 ARM 필수
- 패널 `subtitleText` 신규 — sim/ARM-needed/ARMed 명확 라벨
- `tooltip` 정직성: "source: motion_4096.bin page N" → "재생 방식: 단일 pose preview → PoseLibrary.xxx"

### `PilotDpad.swift`
- `dpadDirectionsActive` 계산 (flags + bus + ARM 종합)
- `directionUnavailableReason()` 헬퍼 — 비활성 사유 한국어 메시지
- 방향 zone 비활성 시 lock 오버레이 + opacity disabled visual
- `handlePress()` 가 비활성 zone 에서 silent return → 3초 toast 표시
- Stop 버튼은 항상 walkReady 시도하되, `.notConnected` 결과면 toast 로 sim 안내

### `WalkLabSession.swift`
- `WalkCycleResult` / `WalkPreflightFailure` 신규 struct (사용자 메시지 포함)
- `lastCycleResult`, `lastPreflightFailure` `@Published` 필드
- `preflightForWalkCycle(bus:)` 신규 — dxl_power ON + 모든 토크 ON + 하체 1개 실패 차단 + 상체 4개+ 차단
- `startWalkCycle()` 가 preflight 통과 시만 cycle 시작 (silent failure 차단)
- `runWalkCycle()` 가 `WalkCycleResult` 반환 (이전 `Void`)
  - 모든 `try?` 제거 — speed/position 실패 카운트 + 하체 fail set + sample error
  - **하체 position write 실패 1개 = 즉시 cycle 중단** (균형 위험)
  - 통신 절반 이상 실패 = bulk failure 중단
  - `lowerBodyJoints` set 파라미터로 주입 (Set 공유)

### `PilotTests.swift`
- **누락 commit 보완**: 이전 PR #21 에서 stage 안 한 test 변경 (`testFeatureFlagsProgressionMatrix` 재작성 + `testFeatureLevelEnumMaps` 신규) 포함

---

## 검증

```bash
cd app/ui/DarwinForge
swift build   # ✓ Build complete
swift test    # ✓ 159/159 passed (1 추가)
```

---

## Codex 검수 6개 P0/P1 vs 본 follow-up

| Codex 우선순위 | 항목 | 본 follow-up 처리 |
|:---:|---|---|
| P0 | WalkLab silent failure (try?) | ✅ 모든 try? 제거 + WalkCycleResult |
| P0 | WalkLab cycle 시작 전 ARM 보장 | ✅ preflightForWalkCycle |
| P0 | Remote Pilot raw page chain 미구현 | ⚠️ tooltip 정정만 — chain 구현은 별도 PR |
| P1 | D-pad 방향 silent return | ✅ disabled visual + toast |
| P1 | Action Bar ARM 전에도 enabled | ✅ isSimMode 또는 gate.armed 만 enabled |
| P1 | left kick / get-up 슬롯 nil | ✅ (이미 v1.5 에서 nil 유지, 라벨 보강) |
| P2 | readyDegraded defer 버그 | ✅ isTerminalReadyStage 화이트리스트 |

---

## 별도 작업 권고 (본 PR 후속)

### Sprint 16+ — Raw motion_4096.bin page chain 재생

- `app/core/forge-cli/src/motion_play.rs` → `forge-core::motion::player` 라이브러리 추출
- FFI: `fc_motion_play_slot(handle, slot, dry_run, confirm_risk)`, `fc_motion_play_cancel`, `fc_motion_play_is_running`
- Swift wrapper: `ConnectionStore.playMotionSlot(slot:confirmRisk:)`
- `TeleopChannel.sendMotion` 이 `v1TargetPoseID` fallback 대신 raw page chain 호출
- INVALID/TORQUE_OFF mask, pause/play timing, SYNC_WRITE 보존
- 활성화 가능: slot 10/11 get-up chain, slot 13 left kick mirror, pageChain feature

### 별도 작업 — IMU read + auto-recovery
- `CmController::read_imu() -> ImuSample` Rust 신규
- FFI + Swift 노출
- `flags.imuTelemetry` / `autoRecovery` 활성

### 별도 작업 — 카메라 + bridge
- robot-side mjpg-streamer 셋업 가이드
- `flags.camera` / `hsvTuning` 활성

---

## 사용자 검증 시나리오 (추가)

### 본 follow-up 검증

7. **WalkLab silent failure 차단** — torque OFF 후 (E-stop 후) WalkLab 프리셋 시작 → "보행 시작 차단 — 하체 토크 N개 실패" 표시
8. **D-pad 방향 비활성** — Pilot 화면 진입 → D-pad 방향 버튼 → 3초 toast "v1.5 에서 D-pad 실 송출 비활성"
9. **Action Bar ARM 전 비활성** — 로봇 연결 + ARM 슬라이더 안 잠근 상태 → Action Bar 7 버튼 회색 disabled
10. **시뮬 모드 Action Bar 활성** — 로봇 미연결 → ARM 슬라이더로 simReady → Action Bar 클릭 시 sim 미리보기 (정상 동작)
11. **readyDegraded 표시** — (가능하면) 상체 모터 1개 일시 연결 안 한 상태에서 ARM → "준비 (degraded) — 상체 일부 미응답" + readyDegraded stage
12. **WalkLab cycle 결과 toast** — 정상 보행 종료 → "보행 종료 — 시간 도달 (N step)" / 하체 실패 시 → "보행 중단 — 하체 위치쓰기 N개 실패"

---

## 안전 노트

본 follow-up 은 **사용자 UX 의 거짓 양성/silent failure 를 제거** 함. 실제 모션 재생의 fidelity 는 raw page chain 작업 (별도 Sprint) 까지 단일 pose preview 로 유지.

**여전히 검증 안 된 영역**:
- 실 로봇 HIL 시나리오 (사용자 Mac + DARwIn-OP)
- WalkLab preflight 의 false positive 가능성 (한 모터가 일시 통신 실패 후 retry 에 응답)
- D-pad lock 오버레이 시각 폭주 (overlay 위치가 cellSize 60% 지점)

머지 전 정비 스탠드 + 배터리 11V+ 환경에서 시나리오 1-12 수행 권장.
