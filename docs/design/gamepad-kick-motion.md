# 게임패드 킥 모션 매핑 — 기획 · 구현 플랜

> 작성 2026-06-13 · 대상: 안베르닉 RG G01(2.4G 동글) → DARwIn-OP 온보드 직결 파일럿
> 상태: **설계(HARD-GATE) — 승인 전 코드 미작성**
> 선행 조사: 본 문서 §0 (게임패드 입력 / 온보드 보행·모션 통합 / 킥 자산 / 안전 게이트 5영역 병렬 조사)

---

## 결론 먼저

**LB = 왼발 킥(Action page 13), RB = 오른발 킥(Action page 12).** 둘 다 **온보드 C++**
(`WalkLabBrokerage`/`GamepadPilot`)에 구현한다. Mac/Rust 경로는 손대지 않는다. 킥 실행은
이미 **실기에서 검증된 getup 모듈 스왑 상태머신**(`WalkLabBrokerage.cpp:188-275`)을 그대로
복제하되 페이지만 10/11 → 12/13 으로 바꾸면 된다.

**터보(RB ×1.3)는 제거** (사용자 결정 2026-06-13 — §3). F10b의 LT/RT 아날로그 턴 +
풀스틱 스트라이드 도입으로 ×1.3 부스트는 사실상 중복이라 매핑을 단순화한다.

| 항목 | 결론 | 근거 |
|---|---|---|
| 어디에 구현? | **온보드 C++ 단독** | Action 모듈이 이미 8ms마다 `Process()` 도는 `MotionManager`에 등록됨. Mac/Rust 플레이어는 블로킹·dry-run·USB 왕복 — 게임패드 즉발 모델과 충돌 |
| 킥 페이지 | **RIGHT=12, LEFT=13** (HIGH 확신) | demo `main.cpp:271/276`, Rust `library.rs:169-177`, `test_fixtures.rs`, `decode_motion.rs` 4중 교차검증 |
| 실행 알고리즘 | getup 상태머신 복제 (page 10/11 → 12/13) | `CheckAndRecoverFall`(cpp:188-275)이 walk↔action 배타를 이미 해결, 프로덕션 검증됨 |
| 검출 경로 | 읽기 스레드 = 즉시 플래그만, supervisor = 블로킹 스왑 | E-STOP 응답성 보존(읽기 스레드 1~2s 블로킹 금지) |
| 안전 게이트 | ARM 필수 + STANDUP 필수 + estop 중 금지 + 킥 중 auto-getup 억제 | F9 `ACK≠서보기록` 교훈 + getup 패턴 |
| **필수 부수 수정** | `TriggerEstopImmediate`에 `action->Stop()` 추가 | 현재 E-STOP은 Walking만 멈춤 — 킥 중 B 누르면 모션 1~2s 계속됨 |

---

## 0. 기존 소스코드·알고리즘 파악

### 0.1 두 개의 완전히 분리된 실행 경로 (가장 중요한 사실)

```
┌─ 온보드 (로봇 위, C++) ─────────────────────────────┐   ┌─ Mac (Rust/Swift) ───────────┐
│ demo 바이너리 (ROBOTIS Framework)                    │   │ forge-core/motion/player.rs   │
│  ├ MotionManager (8ms tick)                          │   │  fc_motion_play_slot (FFI)    │
│  │   ├ Walking  (보행 모듈)                           │   │  - 블로킹                      │
│  │   ├ Action   (모션 페이지 플레이어, page 0~255)    │   │  - dry-run 기본               │
│  │   └ Head                                           │   │  - USB serial 로 페이지 송출  │
│  └ WalkLabBrokerage (supervisor 루프, 20~100ms)      │   │                               │
│      └ GamepadPilot (읽기 스레드, evdev)             │   │  ← 인터랙티브 저작/재생 전용  │
│          RG G01 동글 → walk/head 명령                │   │     게임패드 킥과 무관        │
└──────────────────────────────────────────────────────┘   └───────────────────────────────┘
```

**판정**: 게임패드 킥은 **왼쪽(온보드 C++)에만** 산다. 이유 3가지(독립 검증):

1. **Action 모듈이 이미 가용**. demo `main.cpp:103` 에서 모드 분기 *이전에*
   `MotionManager::AddModule(Action::GetInstance())` 호출 → `Action::Process()`가 온디바이스
   8ms마다 돈다. getup이 프로덕션에서 `Action::Start(10/11)`로 이미 이걸 쓴다.
2. **Mac/Rust 플레이어는 부적합**. `fc_motion_play_slot`(`forge-ffi/src/lib.rs:1399-1566`)은
   **블로킹 + dry-run 기본 + USB serial 스트리밍**. 게임패드 킥을 여기로 보내면 트리거·취소
   양쪽에 USB 왕복 지연, supervisor 루프 스레드와 데드락 위험, dry-run 안전 게이트가
   즉발 모델과 충돌.
3. **CM730 시리얼 버스 공유·배타**. Mac이 킥을 쏘는 동안 온보드 Walking이 버스를 쥐면
   버스 경합. 온보드에서는 `Walking::Stop()→Action::Start()→복원`이 단일 `MotionManager`
   tick 소유자 안에서 끝나 경합이 없다.

> Rust 모션 플레이어(`motion/player.rs`, `forge-cli motion play --slot N`)는 **인터랙티브
> 저작·검증 도구로 그대로 유지**. 단, 구현 *전* 검증에 활용한다(§6 — `--slot 12 --dry-run
> --follow-chain`으로 온디바이스 바이너리의 page 12/13 디코드·체크섬 확인).

### 0.2 게임패드 입력 파이프라인 (`GamepadPilot.{h,cpp}`)

- **디코드**: `/dev/input/event*` → 16B evdev → `GamepadDecoder`가 EV_ABS/KEY 누적 →
  `EV_SYN` 커밋으로 `GamepadSnapshot`(정규화 축 + 버튼 bool 6개) 원자적 확정(`cpp:49-138`).
- **rising-edge 검출**(`ProcessEvent` cpp:388-432): `value==1 && !ButtonState(code)`로 눌림
  순간만 수집 → SYN 커밋 시 settle. A=ARM, Y=복구, X=볼트랙. **B는 예외**: rising 검사
  없이 `value==1`이면 무조건 즉시 `estop_cb` 발화(F9 스테일 면역).
- **콜백 패턴**(cpp:430-431): `m_estop_cb`/`m_recover_cb`는 **락 밖에서** 발화. 킥 콜백이
  복제할 정확한 패턴.
- **출력**: `MapGamepad`(cpp:224-262) → `GamepadWalkFields` → `BuildGamepadLine`이
  **v1 14-token 라인**(`cpp:264-272`, P9 형식 불변) → latest-wins 슬롯 → supervisor 소비.

현재 버튼 매핑(`GamepadPilot.h:58-68`):

| 버튼 | code | 현재 기능 |
|---|---|---|
| A | 304 | ARM (이동 게이트) |
| B | 305 | **E-STOP** (rising 무시, 즉발) |
| X | 307 | 볼트랙 토글 |
| Y | 308 | 복구 (estop flag 해제 + ARM + 소프트 토크 램프) |
| **LB** | **310** | **미사용** (F10 데드맨 해제, `GP_DEADMAN_REQUIRED=false`) ← 킥 후보 |
| **RB** | **311** | **터보 ×1.3** (`MapGamepad` cpp:231-235) ← 킥 후보(터보 제거 후 점유) |
| BACK/START/HOME/THUMBL/THUMBR | 314~318 | **전부 예약(미사용)** |
| LS | — | 이동/횡 |
| RS | — | 헤드 레이트(F10) |
| LT/RT | — | 좌/우회전 아날로그(F10) |

### 0.3 온보드 보행↔모션 모듈 스왑 (getup = 복제 템플릿)

`CheckAndRecoverFall`(`WalkLabBrokerage.cpp:188-275`)이 walk↔action 배타를 이미 해결.
**킥이 그대로 복제할 5단계** (cpp:230-273):

```cpp
// 1) 보행 중단 + 완전 정지 대기 (telemetry 계속, e-stop 즉시 반응)
walking->Stop();  walking_active = false;
while (walking->IsRunning()) {
    if (EstopRequested()) { /* bail */ return true; }
    WriteTelemetry(...);  usleep(8000);   // 공식 demo 와 동일 8ms
}
// 2) body joint 을 Action 모듈에 인계
Robot::Action* action = Robot::Action::GetInstance();
if (!action) { /* skip, 정지 유지 */ return true; }
action->m_Joint.SetEnableBody(true, true);
// 3) 모션 재생 — Start() false 면 모듈 busy, 재시도 (estop bail)
while (action->Start(page) == false) { if (EstopRequested()) {...} usleep(8000); }
// 4) 완료 대기 (estop → action->Stop())
while (action->IsRunning()) { if (EstopRequested()) { action->Stop(); ... } usleep(8000); }
// 5) joint 을 Head/Walking 으로 반납 — ★F9: Walking::Start()는 enable 복구 안 함★
Robot::Head::GetInstance()->m_Joint.SetEnableHeadOnly(true, true);
walking->m_Joint.SetEnableBodyWithoutHead(true, true);
```

- **블로킹**: getup은 supervisor 루프를 ~1~2s 블로킹한다. 킥도 동일 — 허용 가능하고 일관됨.
- **호출 위치**: `Run()` 루프 `cpp:1025` 에서 `CheckAndRecoverFall(...)` 호출 → 킥은
  바로 그 뒤에 `CheckAndExecuteKick(...)` 추가.
- **모션 자산**: `Action::LoadFile(motion_4096.bin)`은 brokerage 진입 *전* demo 초기화
  (`main.cpp:123`)가 이미 수행 — getup이 이에 의존해 동작 중이므로 킥도 동일 전제 성립.

### 0.4 킥 자산 (ROBOTIS Action 시스템)

- **파일**: `motion_4096.bin` (256 페이지 × 512B = 128KB). 온디바이스
  `/robotis/Data/motion_4096.bin` 에 탑재(백업: `firmware-backups/sda1-rootfs/robotis/Data/`).
- **페이지**: `Start(int page)` — 페이지 오프셋 = `page × 512`. PRE→MAIN→POST→PAUSE
  보간, slope[31] 컴플라이언스, step[7] 관절 타깃.
- **킥 페이지** (4중 검증): **RIGHT KICK = 12, LEFT KICK = 13**.
  - demo `main.cpp:271` `Start(12) // RIGHT`, `:276` `Start(13) // LEFT`
  - Rust `library.rs:169-177`: id=12 'Right Kick', id=13 'Left Kick', 둘 다 `SafetyClass::HighRisk`
  - ⚠️ **비대칭 주의**: `follower.KickBall==-1 → RIGHT → 12`, `==+1 → LEFT → 13`.
    "left=12" 로 가정하지 말 것. 본 설계는 페이지 매핑을 **brokerage 한 곳**에만 둠
    (`KICK_PAGE_RIGHT=12`, `KICK_PAGE_LEFT=13` 상수)으로 비대칭 실수 차단.
- **사운드**: `Right kick.mp3`/`Left kick.mp3` 존재하나 **Action이 자동 재생 안 함**.
  필요 시 `LinuxActionScript::PlayMP3()` 수동 호출 — MVP 범위 제외(§7 후속).

### 0.5 안전 불변식 (기존)

- **E-STOP(B) 최우선·상시·즉발**: 모든 중재·게이트보다 먼저(`cpp:393-400`), ≤2ms flag.
  현재 `TriggerEstopImmediate`(cpp:613-617)는 **Walking만 멈춤** — Action은 안 멈춤(킥 위험).
- **ARM(A) 이동 게이트**: `m_armed` 래치 상태, `MapGamepad`가 이동을 게이트(cpp:240).
- **F9 교훈 `ACK≠서보기록`**: `MotionManager::Process`는 `GetEnable(id)==true`일 때만 서보
  기록 → 킥 후 반드시 `SetEnableHeadOnly`+`SetEnableBodyWithoutHead` 명시 호출. ACK·
  `Walking::Start()` 에 의존 금지.
- **낙상 debounce**: `FALL_DEBOUNCE_POLLS=6`(~600ms). 킥 착지 순간 transient가 FALLEN을
  스칠 수 있음 → 킥 창에서 auto-getup 억제 필요.
- **3티어 failsafe**: ①release ②ENODEV ③침묵≥1.5s → walk amplitude 슬루-제로. 킥은
  블로킹 Action이라 amplitude 슬루에 면역(별개 채널).

---

## 1. 기획 (제품·UX)

### 1.1 사용자 시나리오

> 패드로 로봇을 걷게 하다가, 공 앞에서 **RB를 톡 누르면 오른발 킥**, **LB를 누르면 왼발
> 킥**. 킥이 끝나면 로봇은 안정 스탠스로 서 있고, 스틱을 다시 밀면 보행 재개.

직관적 매핑: **왼쪽 어깨 버튼 = 왼발, 오른쪽 어깨 버튼 = 오른발**. 플레이어 기대와 일치.

### 1.2 동작 규약

| 상태 | LB/RB 입력 시 동작 |
|---|---|
| ARM + STANDUP(정지/보행 중) | 보행 정중히 정지 → 해당 발 킥 → 안정 스탠스 idle. **이후 보행은 스틱 재입력 필요** (getup과 동일 — 킥 후 자동 보행 재개 안 함) |
| **미ARM** | **무시** (disarmed 상태에서 킥 금지 — 사고 방지) |
| E-STOP 래치 중 | 무시 (복구(Y) 전까지 모든 모션 금지) |
| 낙상(FALLEN) | 무시 (getup이 우선) |
| 킥 진행 중 재입력 | 무시 (쿨다운 — 현재 킥 완료까지) |
| 킥 중 **E-STOP(B)** | **즉시 `action->Stop()` + 토크 OFF** (필수 수정) |

### 1.3 안전 설계 원칙

1. **ARM 필수**: 맨버튼 킥 금지. `m_armed==true`(이동 허용과 동일 게이트)에서만 발화.
   고토크 HighRisk 모션의 오발 방지. 기존 버튼 철학(B=상시, A=게이트, Y=복구)과 일관.
2. **읽기 스레드 비블로킹**: 킥 콜백은 **플래그만 세팅하고 즉시 반환**. 블로킹 스왑은
   supervisor가 수행 → E-STOP 응답성(읽기 스레드) 보존. (estop_cb/recover_cb처럼 가볍게.)
3. **rising-edge + SYN 커밋 only**: A/Y와 동일 → 멀티프레임 눌림에 중복 발화 없음(무료 debounce).
4. **estop이 동률 우선**: 같은 SYN에 estop+킥이면 estop 승(킥 억제) — `SettleArmed` 패턴 준수.
5. **킥 창 auto-getup 억제**: 킥 동안+직후 짧은 settle 동안 `m_fall_count` 리셋 → 착지
   transient가 getup을 오발하지 않게.
6. **킥 후 명시적 재enable**(F9): `SetEnableHeadOnly`+`SetEnableBodyWithoutHead`. ACK 의존 금지.

---

## 2. 구현 아키텍처

### 2.1 검출(읽기 스레드) ↔ 실행(supervisor 스레드) 분리

```
[게임패드 읽기 스레드]                         [supervisor 루프 스레드]
ProcessEvent (LB/RB rising, m_armed 시)          Run() 루프 @1025 부근:
  → SYN 커밋 시 m_kick_cb(ctx, side) 발화          CheckAndRecoverFall(...)   // 기존
       (락 밖, 즉시 반환)                          CheckAndExecuteKick(...)   // 신규 ★
            │                                          ├ m_pending_kick_side 확인
            ▼                                          ├ 게이트: !estop && STANDUP && armed
   GamepadKickTrampoline(self, side)                   ├ getup 5단계 복제 (page 12/13)
     → 뮤텍스 가드 m_pending_kick_side = side          └ auto-getup 억제 + 플래그 클리어
       (즉시 반환 — 블로킹 금지!)
```

**핵심**: 킥 *검출*(읽기 스레드, 즉시)과 킥 *실행*(supervisor, 블로킹 1~2s)을 분리.
읽기 스레드를 절대 블로킹하지 않아야 E-STOP(B)이 킥 중에도 즉시 반응.

### 2.2 스레드 안전

`m_pending_kick_side`(-1=없음, 0=LEFT, 1=RIGHT)는 읽기 스레드(write)·supervisor(read/clear)
양쪽 접촉 → 기존 `m_mtx`/pthread 뮤텍스 규율로 가드(작은 임계구역). estop flag 파일 경로보다
가벼움 — 1회성 의도 신호이므로 인메모리 가드면 충분.

---

## 3. 터보(RB) 제거 — 결정됨 (2026-06-13)

**사용자 결정: 터보 제거.** RB가 현재 터보(×1.3, `MapGamepad` cpp:231-235)인데, LB·RB
둘 다 킥에 쓰려면 비워야 한다. F10b에서 LT/RT 아날로그 턴 + 풀스틱 스트라이드를 도입해
×1.3 부스트는 사실상 중복 → 단순화를 위해 제거한다.

구현:
- `MapGamepad`(cpp:231-235)의 `if (s.btn_rb) { ... ×GP_TURBO_SCALE ... }` 블록 **삭제**.
- `GP_TURBO_SCALE` 상수 제거(또는 미사용 표기). RB는 이제 오른발 킥 전용.
- 기존 `test_mapping_turbo`(test_gamepad.cpp:222-247) → 터보 제거 검증으로 대체.

> THUMBL/THUMBR 등 예약 버튼은 그대로 후속 확장용으로 남긴다.

---

## 4. 변경 파일 (예상 5~7개)

| 파일 | 변경 | 규모 |
|---|---|---|
| `GamepadPilot.h` | 킥 콜백 typedef+포인터+`Start()` 파라미터 / `m_pending_{left,right}_kick_edge` / LB·RB 시맨틱 주석 / `GP_TURBO_SCALE` 제거 | S |
| `GamepadPilot.cpp` | `ProcessEvent` LB/RB rising-edge(ARM 가드) + SYN 커밋 시 킥 콜백 발화 / `MapGamepad` 터보 블록 삭제 / 생성자 init | M |
| `WalkLabBrokerage.h` | `KICK_PAGE_RIGHT=12`/`KICK_PAGE_LEFT=13`, `m_pending_kick_side`+뮤텍스, `CheckAndExecuteKick()` 선언, `GamepadKickTrampoline` 선언, 킥 창 getup 억제 멤버 | S |
| `WalkLabBrokerage.cpp` | `CheckAndExecuteKick()` 구현(getup 복제) / `Run()@1025` 호출 / `m_gamepad.Start()`에 킥 콜백 배선 / **`TriggerEstopImmediate`에 `action->Stop()` 추가** / MODE·SIGTERM 종료 경로에도 `action->Stop()` | M |
| `tests/test_gamepad.cpp` | 킥 rising-edge/ARM 게이트/estop 동률/터보 제거/debounce 테스트 | M |
| `README.md` | F12 킥 매핑 문서화 | S |
| `docs/reports/2026-06-13-...-kick.md` | (실기 후) 브링업 보고서 | — |

---

## 5. 구현 단계 (TDD)

### Phase K1 — 게임패드 검출 (호스트 테스트 가능, 하드웨어 불요)
1. **RED**: `test_gamepad.cpp`에 추가
   - `test_pilot_kick_left/right`: LB/RB rising + armed → 킥 콜백 1회(side 정확)
   - `test_pilot_kick_disarmed`: 미armed → 콜백 0회
   - `test_pilot_kick_estop_wins`: 같은 SYN estop+킥 → estop만, 킥 억제
   - `test_pilot_kick_debounce`: 멀티프레임 홀드 → 1회만
   - `test_mapping_turbo_removed`: RB 입력해도 fwd/side/turn 스케일 불변(터보 제거 확인)
2. **GREEN**: `GamepadPilot.{h,cpp}` 콜백·edge·터보 제거 구현
3. 검증: `cd firmware-patches/walklab-brokerage && make -f tests/Makefile`(호스트) 전수 통과

### Phase K2 — 온보드 킥 실행 (컴파일만 호스트, 동작은 실기)
1. `WalkLabBrokerage.{h,cpp}`에 `CheckAndExecuteKick()` — getup 5단계 복제, page 12/13,
   게이트(`!EstopRequested() && MotionStatus::STANDUP && armed && side>=0 && !m_fall_count_active`)
2. `Run()@1025` 호출 + 킥 콜백 배선 + `TriggerEstopImmediate`에 `action->Stop()` 추가
3. 킥 창 동안 `m_fall_count=0` 억제 + 완료 후 짧은 settle
4. 검증: brokerage가 ROBOTIS 트리에서 컴파일(INTEGRATION.md 경로). 동작은 K3.

### Phase K3 — 실기 브링업 (입회 필수, 메모리 robot-session-contention 준수)
요람 거치 → 다리 토크 OFF 시작 → §6 체크리스트 순서대로. 보고서 `docs/reports/`.

---

## 6. 구현 전 필수 검증 (코딩 착수 전)

1. **온디바이스 page 12/13 디코드·체크섬** — `Action::LoadPage`는 체크섬 실패 시 조용히
   `ResetPage()`(무동작 포즈)로 degrade. 실기 바이너리로
   `forge-cli motion play --slot 12 --dry-run --follow-chain` + `--slot 13` 으로 이름·7스텝·
   next_page 확인.
2. **`Action::LoadFile`가 walklab 부트 경로에서 실제 실행되는지** — `main.cpp:123` LoadFile이
   `ShouldRunWalkLabBrokerage()` 분기 *전* 실행되는지 주입된 실제 `main.cpp`로 확인(.patch
   아님). getup 동작 = 강한 방증이나 확인.
3. **RG G01 evdev 코드** — 실패드에 `evtest`로 LB=`BTN_TL`(310)·RB=`BTN_TR`(311) 확인.
   (.xbox 프리셋명이지만 물리 패드는 안베르닉.)
4. **MotionStatus STANDUP/FALLEN 의미** — 저속 보행이 비STANDUP으로 읽혀 정당한 킥을
   막는지 / 킥 와인드업 포즈가 FALLEN으로 읽히는지 실측. STANDUP 필수 vs `!FALLEN` 결정.
5. **게임패드 보행에서 `walking->IsRunning()`이 실제 false 도달** — getup 루프가 의존하는
   8ms 폴 윈도가 게임패드 구동 보행에서도 신뢰 도달하는지(낙상 경로만 검증됨).
6. **LB 재점유 안전** — `WalkLabBrokerage.{h,cpp}`에 LB 가정·`GP_DEADMAN_REQUIRED=true` 복원
   계획 없는지. 데드맨 복원 가능성 있으면 LB에 킥 금지(의도와 게이팅 버튼 분리).

---

## 7. 교차 리스크 & 완화

| 리스크 | 완화 |
|---|---|
| **E-STOP이 Action 안 멈춤** | `TriggerEstopImmediate`+MODE/SIGTERM 종료에 `if(action&&action->IsRunning()) action->Stop()` 추가 (Phase K2 필수) |
| **F9 ACK≠서보** | 킥 후 `SetEnableHeadOnly`+`SetEnableBodyWithoutHead` 명시. `Walking::Start()` 의존 금지 |
| **킥 착지 transient→오발 getup** | 킥 창+직후 settle `m_fall_count=0`. 킥 중엔 `CheckAndRecoverFall` 진입 전 가드 |
| **읽기 스레드 블로킹** | 킥 콜백은 플래그만. 실행은 supervisor. (블로킹하면 E-STOP 1~2s 먹통 — 치명) |
| **서보 알람 래치(F8)** | 하드킥이 hip/knee 과부하→Torque Limit=0 래치 가능. 킥 후 알람 시 `SweepServoShutdown` 호출 검토 |
| **page 12/13 비대칭** | 매핑을 brokerage 상수 1곳(`KICK_PAGE_RIGHT=12`/`LEFT=13`)에만 |
| **v1 14-token 형식 불변(P9)** | 명령라인 토큰 추가 금지. **콜백 경로**로 우회(프로토콜 무변경) |

후속(MVP 외): 킥 사운드 동기(`PlayMP3`), 킥 세기 조절, 더 많은 모션(getup variant·인사 등)
동일 패턴 확장, Mac 앱 텔레메트리에 킥 상태 표시.

---

## 8. 증거 기반 완료 기준

- [ ] Phase K1 호스트 테스트 전수 통과(출력 첨부)
- [ ] brokerage ROBOTIS 트리 컴파일 0 error
- [ ] §6 검증 6항 각각 증거(evtest 로그·`--dry-run` 디코드 출력·실측)
- [ ] 실기: disarmed 킥 거부 / armed 킥 발화 / 킥중 estop→Action 정지 / 낙상중 킥 무시 /
      킥후 보행 재개 정상 — 각 영상·로그
- [ ] README F12 갱신, 브링업 보고서

---

### 부록 A — 핵심 참조 위치

| 무엇 | 위치 |
|---|---|
| getup 상태머신(복제 템플릿) | `WalkLabBrokerage.cpp:188-275` |
| Run() 킥 호출 지점 | `WalkLabBrokerage.cpp:1025` (CheckAndRecoverFall 직후) |
| E-STOP 공유 헬퍼(Action::Stop 추가 대상) | `WalkLabBrokerage.cpp:613-617` |
| 게임패드 콜백 배선 | `WalkLabBrokerage.cpp:932-934` |
| ProcessEvent rising-edge/콜백 | `GamepadPilot.cpp:388-432` |
| MapGamepad 터보 블록(삭제 대상) | `GamepadPilot.cpp:231-235` |
| 버튼 상수 | `GamepadPilot.h:58-68` |
| 킥 페이지 트리거(레퍼런스) | `DARwIn-OP_ROBOTIS_v1.6.0/Linux/project/demo/main.cpp:271,276` |
| 킥 카탈로그(Rust 검증) | `app/core/forge-core/src/motion/library.rs:169-177` |
| F9/F10 교훈 | `docs/reports/2026-06-13-rgg01-bringup.md` |
