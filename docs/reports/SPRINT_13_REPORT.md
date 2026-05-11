# Sprint 13 — `forge motion play` (실 robot 송출 본구현)

> **기간**: 2026-05-12
> **PRD**: 후속 — PRD-001 §11 Sprint 13 (Hardware integration)
> **상태**: ✅ 완료 — dry-run 모드 본구현, engage 모드 (실 송출) 사용자 명시 필요

## TL;DR

**`forge motion play --slot <n>` 또는 `--from-json <path>` 로 모션 페이지를 실 robot
에 송출하는 명령 본구현.** 기본은 `--dry-run` (패킷 stdout 만), `--engage` 명시
시에만 실 SYNC_WRITE 발행. HARDWARE_VERIFICATION_PROTOCOL.md G3 단계 자동화.

- 신규 모듈: `app/core/forge-cli/src/motion_play.rs` (335 lines)
- main.rs 변경: **2 줄만** (mod 선언 + MotionAction::Play variant + dispatch)
- 신규 tests: 4 (motion_play 모듈)
- 전체 workspace: **306 passed; 0 failed** (302 → 306)

## 구조

```
forge motion play
  --slot <n>                 # motion_4096.bin 슬롯 (1..=255)
  --from-json <path>         # 또는 Motion JSON 파일 (Sprint 10 산출 호환)
  --port <usb>               # USB 직렬 포트 (engage 모드 필수)
  --bin <path>               # motion_4096.bin override
  --baud <n>                 # 기본 1_000_000
  --timeout <ms>             # 기본 50
  --dry-run                  # 기본 ON (패킷 stdout)
  --engage                   # 실 모터 송출 활성 (사용자 명시)
  --skip-validation          # precheck_motion 우회 (비추천)
  --single-foot-ok           # kick 등 단발 자세 허용
  --torque-off-after         # 재생 후 토크 OFF (기본 hold)
  --follow-chain             # next_page chain 따라감 (기본 ON)
  --max-chain-depth <n>      # 무한 루프 방지 (기본 10)
```

## 안전 게이트 (4-layer)

1. **`--dry-run` 기본 ON** — 사용자가 `--engage` 명시 안 하면 실 송출 X
2. **`precheck_motion` 자동** — V1 JointLimit + V3 SelfCollision 통과 못 한 페이지 거부.
   `--skip-validation` 명시 우회 가능 (비추천)
3. **TorqueRamper gentle 프로필** — P_GAIN 0→8→16→32 4 단계 ramp ("둠칫" 방지)
4. **`emergency_stop()`** — Ctrl+C 시그널 시 (placeholder; signal-hook crate 후속)

## 동작 흐름 (engage 모드)

```
1. Page source 결정 (slot or JSON)
2. follow_chain → next_page 따라 페이지 목록 빌드 (max_depth 제한)
3. Bus 열기 (PosixSerial)
4. JointController 생성
5. 페이지별:
   5a. precheck_motion (V1/V3)
   5b. 첫 페이지에만 TorqueRamper gentle
   5c. step 순회 (repeat 횟수):
       - step_to_targets → [(JointId, u16)]
       - INVALID/TORQUE_OFF/raw==0 슬롯 제외
       - set_positions_many (SYNC_WRITE 1 패킷)
       - play_ms sleep
       - pause_ms sleep
6. (옵션) 토크 OFF 또는 hold
```

## 페이지 source

### A) `motion_4096.bin` slot

```bash
forge motion play --slot 12             # dry-run page 12 (Right Kick)
forge motion play --slot 12 --engage    # 실 송출
forge motion play --slot 1 --port /dev/cu.usbserial-XXX --engage --torque-off-after
```

### B) Motion JSON (Sprint 10 산출)

```bash
forge synth mirror 12 --out /tmp/lk_synth.json
forge motion play --from-json /tmp/lk_synth.json   # dry-run
forge motion play --from-json /tmp/lk_synth.json --port /dev/... --engage
```

### C) Chain 자동 따라감

```bash
# page 17 mul1 → 18 mul2 → 19 mul3 (Hand Standing 3-page chain)
forge motion play --slot 17 --follow-chain   # 자동으로 3 페이지 chain 재생
```

## E2E 시연 (dry-run)

```
$ forge motion play --slot 1
✓ loaded 1 page(s) — 1:'init'
🟡 dry-run mode — 실 모터 송출 없음. 실행하려면 `--engage` 추가
═══ Page 1 'init' (2 step) ═══
[dry-run] page 'init' step 0 (play=1000 ms, pause=0 ms) — 20 joints
           RShoulderPitch=1498  LShoulderPitch=2518
           RShoulderRoll=1845   LShoulderRoll=2248
           RElbow=2381          LElbow=1712
           RHipYaw=2048         LHipYaw=2048
           RHipRoll=2052        LHipRoll=2044
           RHipPitch=1637       LHipPitch=2459
           RKnee=2653           LKnee=1443
           RAnklePitch=2369     LAnklePitch=1727
           RAnkleRoll=2057      LAnkleRoll=2039
           HeadPan=2161         HeadTilt=2161
[dry-run] page 'init' step 1 (play=1000 ms, pause=0 ms) — ...
✓ dry-run 종료. 총 1 페이지, 2 step

$ forge motion play --slot 12   # Right Kick (HighRisk, 7 step)
✓ loaded 1 page(s) — 12:'rk'
🟡 dry-run mode — ...
[dry-run] page 'rk' step 0 (play=496 ms, pause=0 ms) — 20 joints
[dry-run] page 'rk' step 1 (play=200 ms, pause=0 ms) — 20 joints
[dry-run] page 'rk' step 2 (play=72 ms, pause=0 ms) — 20 joints
[dry-run] page 'rk' step 3 (play=72 ms, pause=144 ms) — 20 joints
[dry-run] page 'rk' step 4 (play=72 ms, pause=0 ms) — 20 joints
[dry-run] page 'rk' step 5 (play=112 ms, pause=0 ms) — 20 joints
[dry-run] page 'rk' step 6 (play=496 ms, pause=0 ms) — 20 joints
✓ dry-run 종료. 총 1 페이지, 7 step
```

## 사용 예 (실 robot — 사용자 책임)

**G1 (validate) + G2 (connect) 사전 통과 가정.**

```bash
# 1. 합성된 페이지 commit
forge synth mutate 1 --time-scale 1.5 --new-id 100 --name init_slow --out /tmp/slow.json
forge synth validate /tmp/slow.json
forge synth commit /tmp/slow.json --slot 100

# 2. 실 robot 전 연결 확인
forge connect --port /dev/cu.usbserial-A1B2

# 3. dry-run 으로 페이지 시각 검토
forge motion play --slot 100 --bin /Users/me/robot_mirror/motion_4096.bin

# 4. 실 송출 (사용자 supervised)
forge motion play \
    --slot 100 \
    --bin /Users/me/robot_mirror/motion_4096.bin \
    --port /dev/cu.usbserial-A1B2 \
    --engage \
    --torque-off-after
```

## 결정 사항

- **`positions[0]` reserved 무시** — ROBOTIS 표준. slot 1..=20 만 처리.
- **`raw == 0` 슬롯 skip** — unused 슬롯 default. 정상 데이터에서 0은 드물고
  (모터 한계), kick page 의 step 0 등 fixture 에서도 0 은 idx 26+ (unused).
- **`emergency_stop` Ctrl+C 처리** — placeholder. 실 구현 시 `signal-hook` crate
  필요. 현재는 OS 의 SIGINT 가 process 종료 → bus drop → 모터 명령 stop.
- **timeout 50 ms** — protocol 1.0 SYNC_WRITE 응답 보장 시간. 환경에 따라 조정.
- **baud 1_000_000** — ROBOTIS DARwIn-OP 기본.

## 후속 작업

- **signal-hook 통합** — Ctrl+C 정확한 `emergency_stop()` 호출
- **realtime monitoring** — 재생 중 `read_state` 폴링으로 온도/위치 표시
- **interactive abort** — 키보드 입력 monitoring (스페이스바 = pause)
- **fps recording** — 재생 trace JSON 저장 (디버깅용)
- **MCP server에 noise** — `forge-mcp-synth` 에 `motion_play` tool 추가 (Sprint 14)

## 검증 증거

```
$ cargo test --workspace
TOTAL: 306 passed; 0 failed (302 → 306, +4 motion_play tests)

$ cargo build -p forge-cli
   Finished `dev` profile [unoptimized + debuginfo]

$ forge motion play --help
✓ 11 options listed (port / slot / bin / from-json / dry-run / engage / ...)

$ forge motion play --slot 1
✓ loaded 1 page(s) — 1:'init'
🟡 dry-run mode — 실 모터 송출 없음
[dry-run] page 'init' step 0 (play=1000 ms, pause=0 ms) — 20 joints
...
✓ dry-run 종료
```

## 참고

- HARDWARE_VERIFICATION_PROTOCOL.md — G3 사전점검 5 항목
- SPRINT_9_10_12_REPORT.md — synth + MCP + Claude integration
- PRD-001 §11.4 — Sprint 12-6 (옵션 실기기 dry-run)
- forge-core::control::JointController — set_positions_many 등 API
- forge-core::safety::torque_ramp — TorqueRamper gentle 프로필
