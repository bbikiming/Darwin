# Anbernic RG G01 동글 직결 조종 — 현행 로직 (Single Source of Truth)

> 2026-06-14 19:51 KST 작성. **이 문서가 현행 조종계의 단일 출처**다. 구 설계
> (`handheld-direct-pilot-upgrade.md` H0/P7)는 폐기 배너 참조 — F10/F12 + 2026-06-14
> 하드닝/튜닝/볼추종/D-패드로 대체됨. 코드 출처: `firmware-patches/walklab-brokerage/`
> (`GamepadPilot.{h,cpp}`, `WalkLabBrokerage.{h,cpp}`, `WalkLabTransport.{h,cpp}`).
> 전체 인계는 `docs/handoff/2026-06-14-darwinforge-full-handoff.md`.

---

## 0. 배포 현황 (현재 상황 — ★조치 필요)

**현재 HEAD = `8cdc282`(D-패드 모션). 워킹트리 clean. 로봇은 OFF — 도달 불가
(유선 123.1·무선 0.33 timeout, Mac 유선 IP 소실).**

| 작업 | 커밋 | 호스트 | 로봇 배포 | 실기 검증 |
|---|---|---|---|---|
| 하드닝 Batch A/B/C | `1c7f35c` | GREEN | 세션 중 배포(14:37) | ✗ |
| 회전 24°→28° · 측보 28→32mm | `423e7f0`·`58866f9` | GREEN | 세션 중 배포 | 일부 실주행 관찰 |
| 트리거 연속 회전(offer 기준) | `ef65c02` | GREEN | 세션 중 배포 | 사용자 실주행 OK |
| 볼-추종 자동 보행 + 추적끊김 수정 | `c67fd4a`·`7c89d22` | GREEN | 세션 중 배포(14:37, pid 4420) | 사용자 실주행 |
| **D-패드 모션(서기/앉기/패스)** | **`8cdc282`** | **GREEN** | **✗ 미배포(로봇 OFF)** | **✗** |

- **확실히 미배포 = D-패드(`8cdc282`)**. 이전 작업은 14:37에 배포·재기동(pid 4420 실행
  확인)했으나 이후 로봇 OFF. 핸드오프 문서는 보수적으로 "전부 미검증"으로 기록(B-FLD2).
- **권장: 로봇 재연결 시 6파일 전부 재배포해 디스크를 HEAD(`8cdc282`)에 일치**시킨다
  (부분 배포·구바이너리 혼입 방지). 호스트 검증 = test_gamepad 279 · test_transport 188, 0 fail.

**배포 절차** (메모리 `robot-onboard-deploy-mechanics`):
```sh
cd ~/Documents/vibe_coding/Darwin/firmware-patches/walklab-brokerage
PATH=/usr/bin:$PATH /usr/bin/scp GamepadPilot.{cpp,h} WalkLabBrokerage.{cpp,h} \
   WalkLabTransport.{cpp,h} darwin:/robotis/Linux/project/demo/
PATH=/usr/bin:$PATH /usr/bin/ssh darwin \
   'cd /robotis/Linux/project/demo && bash install-onboard.sh 2>&1 | grep -E "빌드 완료|error"'
# 재기동(★바닥에 놓고 — sit/stand는 바닥 모션):
PATH=/usr/bin:$PATH /usr/bin/ssh darwin \
   'echo walklab >/tmp/df-pilot-mode; sudo -n killall demo; sleep 1.5; \
    cd /robotis/Linux/project/demo && nohup sudo -n ./demo >/tmp/df-demo.log 2>&1 &'
```
- **배포는 디스크만 갱신 — 재기동해야 적용**("터미널서 배포했는데 안 됨"의 흔한 원인=구 바이너리).
- `/usr/bin/ssh` 필수(homebrew ssh는 UseKeychain 거부). 로그인 = `robotis@192.168.123.1`(alias `darwin`).
- `install-onboard.sh`는 sudo 불요(demo 디렉터리 robotis 소유, rc.local 훅 이미 설치면 스킵).
- **온보드 재빌드 = 브로커리지(로봇 전용, 호스트 미컴파일) g++ 4.6.3 컴파일 검증 게이트.**

---

## 1. 조작 매핑 (RG G01 2.4G 동글 → 로봇 USB 직결)

| 입력 | 기능 | 상세 |
|---|---|---|
| **왼스틱(LS)** | 이동 | ly=전진(위)/후진, lx=좌/우횡. 데드존 0.10 · 곡선 1.35. 최대 전진 38mm · 측보 32mm |
| **오른스틱(RS)** | 머리 레이트 제어 | rx=팬, ry=틸트. 풀스틱 팬 150°/s·틸트 85°/s, 한계 팬±70°·틸트±35°. 입력 0이면 직전 각 hold |
| **LT / RT** | 좌 / 우 회전 | RT−LT 아날로그 차분. 데드존 0.02 · 곡선 0.65(저압 부스트). 최대 28°. **연속 회전**(홀드 중 끊김 없음) |
| **A** | ARM | 이동·모션 단일 게이트(데드맨 없음). 무입력 15s 시 auto-disarm |
| **B** | E-STOP | rising 즉시(데드맨 무시) → 정지+토크OFF+flag+ForceDisarm |
| **X** | 볼트랙(머리만) 토글 | 명령라인 balltrack=1. 머리만 공 추적 |
| **Y** | 복구 | estop flag 해제 + ARM(소프트 토크 램프). |
| **LB / RB** | 왼발 / 오른발 킥 | ARM 게이트. page 13 / 12 |
| **START** | 볼-추종 자동보행 토글 | balltrack=2. ARM 필요. 공 향해 자동 보행(머리+몸). 자동킥 없음(추종만) |
| **D-패드 위** | 일어서기(stand up) | ARM+STANDUP. page 16 |
| **D-패드 아래** | 앉기(sit down) | ARM+STANDUP. page 15 → 앉음 상태(m_sitting) |
| **D-패드 좌 / 우** | lPASS / rPASS | ARM+STANDUP. page 71 / 70 |
| BACK·HOME·스틱클릭 | 예약 | 미배선 |

부호(실측): ly 위=전진, lx 우=우횡(−Y), RT=우회전(−A), RS 우=−pan/위=+tilt.
D-패드 표준(HAT0Y 위=−1·아래=+1, HAT0X 좌=−1·우=+1) — 실기서 반대면 `GP_DPAD_*` 반전.

---

## 2. 보행 파라미터 (거버너 = 전 클라이언트 공유 최종 클램프)

| 축 | 값 | 상수 | 비고 |
|---|---|---|---|
| 전진 stride | 38mm | `GP_MAX_STRIDE_MM` | UI 클램프, 최종은 거버너 |
| 측보 | **32mm** | `ENVELOPE_Y_MAX`=`GP_MAX_SIDE_MM` | 실기튜닝(22→28→32). ★IK-freeze 근접, 풀스틱 측보 거동 관찰 |
| 회전 | **28°** | `ENVELOPE_A_MAX`=`GP_MAX_TURN_DEG` | 실기튜닝(12→18→24→28). 발 yaw~14°(무스컬프 천장) |
| period | 560~700ms | `GP_GAIT_PERIOD_*` | 강도 종속(풀스틱 560 최속) |
| 슬루/래치 | DX 8·DY 7·DA 6 | `SLEW_D*_MAX` | co-arrival 동기화 슬루(직선 전이) |

- **불변식**: `GP_MAX_SIDE_MM==ENVELOPE_Y_MAX`, `GP_MAX_TURN_DEG==ENVELOPE_A_MAX` —
  구조적으로 동일 정의(한쪽만 바꿔도 발산 불가).
- **측보 정규화(B2/P1-1)**: 강도 = `|y|/GP_MAX_SIDE_MM`(축별 max) — 순수 측보 풀스틱이
  강도 1.0(최속·최대 발높이). 종전 `/38` 과소평가 수정.
- **결합강도 L2**: 복합 stride(전진+측보+회전)는 sqrt 합으로 케이던스↑·발높이↑.
- **gate-on-y(P6)**: 측보도 발 클리어런스(Z_MOVE)·sway(Y_SWAP) boost — IK-freeze 완화.
- **엔벨로프 예산** `ENVELOPE_SUM_MAX=1.25`(L1) — 3축 동시최대 시 비율 축소(방향 보존).

---

## 3. 안전 (데드맨 제거 후 ARM 단일 + 다층 페일세이프)

- **ARM 단일 게이트**: A로 무장. `GP_DEADMAN_REQUIRED=false`. 이동·킥·D-패드 모션 모두 ARM 필요.
- **ARM idle timeout** `GP_ARM_IDLE_TIMEOUT_MS=15000`: 의도적 입력(이동/턴/머리/버튼/D-패드)이
  15s 없으면 auto-disarm(거치 중 오접촉 차단). 데드맨 정석(hold-to-run)의 완화책.
- **E-STOP(B·UDP·Switch/Mac flag 전부)** → Walking 정지 + 토크OFF + flag latch + **ForceDisarm**
  (ARM 해제, ISO 13850 reset≠restart). flag 해제는 재기동을 "허용"만 — 재보행은 명시적 A 재ARM.
  **재ARM 중립 게이트**: 잔여 스틱으로 즉시 재보행 차단(중립 1회 경유 필요).
- **노드 소멸(ENODEV, ②티어)**: 즉시 슬루-제로(controlled stop, IEC 62745). **버튼 상태 무관 단일 거동.**
- **침묵(③티어)**: 마지막 *공급(offer)* 기준. 장치 보유 중 50ms 재공급 → 정적 홀드(트리거)도
  끊김 없음(연속 회전). 단절은 ②티어가 즉시, 정지-홀드는 idle timeout이 backstop.
- **신선창=침묵창 정렬** `GP_LOCAL_FRESH_MS==GP_SILENCE_SLEW_MS=1500`(컴파일타임 강제) — 선점 구간 제거.
- **자동 낙상복구(auto-getup)**: FALLEN(전/후) 디바운스 후 getup page 10/11. STANDUP이면 미발동.
- **앉음 상태(m_sitting)**: 앉으면 (1)보행 Start 차단(먼저 STAND), (2)STAND 외 D-패드/킥 차단.
  auto-getup은 **억제 안 함**(앉다 넘어지면 정상 복구). STAND/E-STOP/getup이 해제.
- **TEL2 관찰가능성**: armed·estop_latched 토큰 노출(IEC 60204-1 §10.3).

---

## 4. 모션 (공식 ROBOTIS Action 페이지, motion_4096.bin)

`walk↔action 모듈 스왑`(검증된 패턴)으로 재생 — **페이지 자체 속도 준수, 완료까지 대기,
E-STOP 즉시 반응**. 게이트: ARM + STANDUP(낙상 중 금지, getup 우선).

| 트리거 | 모션 | page | 게이트 |
|---|---|---|---|
| LB / RB | 왼발 / 오른발 킥 | 13 / 12 | ARM + STANDUP |
| D-패드 위 | stand up | 16 | ARM + STANDUP(앉음=직립이라 통과; 진짜 낙상엔 page16 대신 auto-getup) |
| D-패드 아래 | sit down | 15 | ARM + STANDUP → m_sitting |
| D-패드 좌 / 우 | lPASS / rPASS | 71 / 70 | ARM + STANDUP |
| (자동) | getup front / back | 10 / 11 | FALLEN(auto-getup) |

- 페이지 카탈로그: `motions/external/_catalog/op2-personal-assistant.csv`(getup/킥과 교차검증).
- **킥 안정화**: settle(`KICK_SETTLE_TICKS=37`×8ms≈296ms) 정적 유지 후 반납 + 사후 낙상판정.
  킥 중 능동 자이로 밸런스 불가(Action 개루프) — 공장 스냅 감속(steps2~4 72→144ms) 적용됨.
- **★sit/stand는 바닥 모션** — 크래들 거치보다 로봇을 바닥에 놓고 테스트.

---

## 5. 볼-추종 자동 보행 (싸커 데모 BallFollower 응용)

- **START 토글**(balltrack=2). X(머리만)와 독립. ARM 필요.
- `ProcessBallTracking`(머리 추적) 직후 `BallFollower::Process(tracker.ball_position)`가
  Head 각도로 공을 향해 Walking X/A_MOVE 직접 구동(거버너/슬루 우회, 싸커 데모와 동일).
- **사용자 선택: 추종만**(자동 킥 없음 — KickBall 무시, 킥은 LB/RB 수동).
- 보행 중엔 정적 추적 휴리스틱(검증 게이트·한계각 탈출) 비활성(시야 흔들림 = 정당한 공 점프).
- 안전: ARM 필요, E-STOP/워치독/STALE 정지 시 추종 해제(재개=START 재토글).

---

## 6. 아키텍처 (데이터 흐름)

```
RG G01 동글 → /dev/input/eventN
  └ GamepadPilot(reader thread): evdev 16B 디코드 → 매핑/성형 → 14-token 명령 라인
      · 슬롯 offer(source=local, latest-wins)  · E-STOP(B)·킥(LB/RB)·D-패드·복구(Y)는 콜백
  명령 라인: "gp{seq} {en} {x} {y} {a} {period} {foot} {hip} 1.0 0 2 {pan} {tilt} {balltrack}"
            (balltrack 0=off·1=머리·2=추종; P9 토큰 불변)
  └ WalkLabBrokerage(supervisor 루프 ~20ms):
      · 명령 적용: 거버너 → co-arrival 슬루 → gate-on-y → Walking 진폭(WriteShapedCommand)
      · 모션: CheckAndExecuteKick(킥+D-패드 일반화) / CheckAndRecoverFall(getup)
      · 볼트랙/추종: ProcessBallTracking + ProcessBallFollow
      · TEL2(UDP 30Hz): 위상·래치 진폭·IMU·FSR·armed·estop_latched·loop_ms
      · E-STOP: TriggerEstopImmediate(공유) + flag-detected 블록(Switch/Mac)
  └ Robot:: 프레임워크: Walking(보행) / Action(모션 페이지) / Head(추적) — MotionManager 8ms tick
```

- GamepadPilot 순수 로직(디코드/매핑/성형/settle/failsafe)은 Robot:: 의존 0 → 호스트 단위 테스트.
- 브로커리지는 Robot:: 의존 → 로봇 g++ 빌드만(호스트 미컴파일) → 온보드 빌드가 컴파일 게이트.

---

## 7. 검증 상태 + 잔여 게이트

- **호스트 GREEN**: test_gamepad 279 · test_transport 188, 0 failures(`-std=c++03 -Wall -Wextra` 무경고).
  적대적 cpp 리뷰 통과(볼-추종·D-패드 각 HIGH 2건 반영).
- **로봇 빌드**: 하드닝~볼추종은 온보드 빌드 통과(14:37). **D-패드는 미배포 → 온보드 빌드 미검증.**
- **실기 게이트(B-FLD2, 미통과)**: 외부 E-STOP 후 재보행불가 통합검증, idle 첫입력 M2M p95≤40ms,
  침묵임계 `GP_SILENCE_SLEW_MS` 실측, 단절 매트릭스 4종(전원OFF·거리이탈·배터리탈락·동글뽑기),
  측보 32mm IK-freeze 관찰, sit/stand 바닥 거동. → `2026-06-14-anbernic-control-hardening-implementation.md` §3.

---

## 8. 관련 문서

- **설계/감사**: `anbernic-dongle-direct-control-hardening.md`(하드닝 플랜),
  `2026-06-14-anbernic-dongle-direct-control-audit.md`(14-에이전트 감사),
  `2026-06-14-anbernic-control-hardening-implementation.md`(구현 보고서 + 실기 게이트).
- **튜닝**: `anbernic-gait-upgrade.md`(P0~P6 게이트), `controller-mapping-uiux.md`.
- **구 설계(폐기 배너)**: `handheld-direct-pilot-upgrade.md`(H0/P7 — EVIOCGKEY/데드맨/터보/1:1 폐기).
- **인계**: `docs/handoff/2026-06-14-darwinforge-full-handoff.md`(전체), `BLOCKERS.md`(B-FLD2).
- **배포 메커닉**: 메모리 `robot-onboard-deploy-mechanics`.
