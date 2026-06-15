# 안베르닉 동글 햅틱(진동) 피드백 — 구현·실기 성공 사례

- **일시**: 2026-06-15 (사용자 입회)
- **대상**: DARwIn-OP2 + 안베르닉 RG G01 2.4G 동글(XInput 045e:028e) + GamepadPilot 온보드 직결 파일럿
- **결과**: **성공** — 낙상·최대속도·킥 3개 조종 이벤트에 진동 피드백 매핑, 실기 입회 확인("아주 좋아")
- **커밋**: `34f9667` feat(walklab): 안베르닉 동글 햅틱(진동) 피드백 (브랜치 `claude/robotis-darwin-op-setup-oyzTi`, 푸시됨)
- **변경 파일**: `firmware-patches/walklab-brokerage/` 의 GamepadPilot.{cpp,h} · WalkLabBrokerage.{cpp,h} · BrokerageActions.h · balltrack.ini · tests/test_brokerage_actions.cpp

---

## 0. 결론 (한 줄)

안베르닉 동글이 force feedback(FF_RUMBLE)을 노출함을 확인하고 실기 rumble 테스트로 물리 진동을
검증한 뒤, **낙상(최강·2초)·최대 전진속도 도달(강·450ms 주기 반복)·킥(최강·1초)** 3개 이벤트에
진동을 매핑했다. 진동은 **로봇 USB-로컬 동작**이라 Mac↔로봇 무선/SSH 통신·텔레메트리·E-STOP
레이턴시에 **영향이 없다**.

---

## 1. 요구사항 (사용자)

조종 중 다음 상황에서 컨트롤러 진동:

| # | 이벤트 | 진동 (최종) |
|---|--------|-------------|
| 1 | 로봇이 넘어졌을 때 | **강하게·길게** — 최강(양모터 100%)·2초 |
| 2 | 최대 (전진) 속도 도달 | **약→강하게** + 유지하는 동안 **주기 반복** — 양모터 80%·200ms 펄스를 450ms마다 |
| 3 | 킥 모션 순간 | **강하게·짧게→1초** — 최강(양모터 100%)·1초 |

추가 제약(사용자 질의): **레이턴시·통신 지연이 없어야 함.**

> 초기엔 "최대 회전 도달"도 후보였으나 최종 요청에서 제외(전진 최대속도만). 강도/길이/반복은
> 1차 배포 후 사용자 피드백("더 세게·반복·킥 1초·낙상 2초")으로 조정.

---

## 2. Force Feedback 발견 + 실기 검증

### 2-1. capability 확인 (read-only)

동글의 evdev capability(`/proc/bus/input/devices`)에 force feedback 비트가 선언돼 있었다:

```
N: Name="Microsoft X-Box 360 pad"
B: EV=20000b
B: FF=1 7030000 0 0      ← force feedback 지원 선언
H: Handlers=event8 js0
```

xpad 드라이버가 XInput 045e:028e 패드에 FF_RUMBLE 을 제공한다. 단, **동글이 FF 를 물리 패드
모터로 릴레이하는지는 미검증**이라 "선언 ≠ 실제 진동" 이므로 실기 테스트가 선결 과제였다.

### 2-2. 권한 — ACL 발견 (sudo 불요)

event 노드 권한이 `crw-rw----+`(ACL `+`)였고 `getfacl` 결과:

```
user:robotis:rw-     ← robotis 가 sudo 없이 O_RDWR 가능
```

덕분에 **데모(root) 방해 없이, sudo 없이** 독립 FF 테스트가 가능했다(evdev 는 다중 open 허용 —
테스트 fd 는 별도 effect 업로드/재생, 데모의 읽기 fd 와 무간섭).

### 2-3. 일회성 rumble 테스트

`/tmp/ff_test.cpp`(robotis 컴파일·실행) — event8 을 O_RDWR 로 열어 FF_RUMBLE effect 업로드 +
1초 재생:

```c
struct ff_effect e; e.type = FF_RUMBLE; e.id = -1;
e.u.rumble.strong_magnitude = 0xFFFF; e.u.rumble.weak_magnitude = 0xFFFF;
e.replay.length = 1000;
ioctl(fd, EVIOCSFF, &e);                 // 업로드(id 할당)
struct input_event play; play.type = EV_FF; play.code = e.id; play.value = 1;
write(fd, &play, sizeof(play));          // 재생
```

결과: 업로드·재생 무에러 + **물리 패드 진동 확인**. → FF 사용 가능 확정, 본 구현 착수.

---

## 3. ROBOTIS 프레임워크 관절 소유권 모델 (배경 — 안전 분석에 필수)

진동 자체는 단순하나, 같은 시기 SIT 결함 디버깅으로 파악한 소유권 모델이 트리거 안전성의 전제다:

- `JointData::SetEnable(id, enable, exclusive)` — `enable && exclusive` 면
  `MotionManager::SetJointDisable(id)` 로 **타 모든 모듈의 해당 관절을 disable**(배타 소유).
- `MotionManager::Process()`(8ms) — 각 모듈의 `m_Joint.GetEnable(id)==true` 인 관절만 서보에 SyncWrite.
- 진동은 관절 소유권과 **무관** — `write(fd, EV_FF)` 는 입력 장치로의 출력 리포트이지 모터 제어가
  아니므로 Walking/Action 소유권 흐름에 영향을 주지 않는다.

---

## 4. 구현 상세

### 4-1. FF 인프라 — `GamepadPilot`

- **장치 열기**: `ScanAndOpenGamepad()` 가 `O_RDWR | O_NONBLOCK` 시도 → 실패 시
  `O_RDONLY | O_NONBLOCK` 폴백(진동만 비활성·입력 정상). FF write 에 쓰기 권한 필요.
- **`Rumble(strong_pct, weak_pct, duration_ms)`**:
  - 직전 effect 제거(`EVIOCRMFF`) → 새 FF_RUMBLE effect 업로드(`EVIOCSFF`) → `EV_FF` play write.
  - `m_mtx` 짧게 보유(드문 이벤트), **non-blocking write**(O_NONBLOCK), 실패 무시(graceful).
  - `#ifdef __linux__` 가드 — 호스트(macOS) 빌드에선 무동작 스텁(`#else (void)...`).
  - 입력 클램프(0..100%, 1..5000ms), effect 슬롯 누수 방지(직전 제거).
- **`SetHapticsEnabled(bool)`** — on/off 토글(thread-safe).
- 재연결(`AdoptDevice`) 시 `m_ff_id=-1` 리셋(새 fd 의 effect 는 Rumble 이 lazy 재업로드).

### 4-2. 트리거 — `WalkLabBrokerage`

| 트리거 | 코드 위치 | 발화 |
|--------|-----------|------|
| 낙상 | `CheckAndRecoverFall` "FALL detected" | `Rumble(100,100,2000)` — 낙상 확정 1회(getup 완료 후 카운터 리셋 → 다음 낙상 재발화) |
| 최대 전진속도 | `WriteShapedCommand` → supervisor 루프 | 캡 도달 상태 기록 후, 루프가 `now_ms` 로 **450ms마다 `Rumble(80,80,200)`** 반복(유지 중). 이탈/정지 시 타이머 리셋(재도달 즉시) |
| 킥 | `CheckAndExecuteKick` Action Start 직전 | 킥(LEFT/RIGHT)에만 `Rumble(100,100,1000)` — SIT/STAND/PASS 제외 |

- **최대속도 "주기 반복" 설계**: 사용자가 스틱을 계속 밀고 있는 만큼 반복돼야 하므로, 단순 엣지
  1회가 아니라 — `WriteShapedCommand` 가 `m_at_speed_cap`(적용된 전진 보폭 `sx` vs period 종속
  `EnvelopeXMax(sp)` 캡 도달)만 기록하고, **supervisor 루프(매 ~20ms, `now_ms` 가용)** 가
  `m_at_speed_cap && walking_active` 면 `HAPTIC_SPEED_REPEAT_MS(=450ms)` 주기로 반복 발화.
  캡 이탈/정지 시 `m_last_speed_rumble_ms=0` 리셋 → 재도달 시 즉시 발화.
- **설정**: `balltrack.ini [Haptics] enabled`(기본 1). Run() 진입 시 1회 로드 → `SetHapticsEnabled`.
  `enabled=0` 이면 진동 전면 비활성(재빌드 불요).

### 4-3. 순수 결정 로직 — `BrokerageActions.h` (호스트 테스트 가능)

진동 write 는 로봇 전용이지만 "언제 울릴지" 판정은 Robot:: 의존 0 으로 추출:

- `AtForwardSpeedCap(applied_x, x_max)` — 전진 보폭이 캡 도달(0.5mm 여유).
- `RisingEdge(prev, now)` — 상승 엣지(엣지 발화용 헬퍼).

---

## 5. 레이턴시 / 통신 영향 분석 — **없음**

| 우려 | 분석 |
|------|------|
| 통신(텔레메트리/명령) 지연 | 진동 write 는 **로봇 USB-로컬**(`write(m_fd, EV_FF)`) — Mac↔로봇 무선/SSH 경로 미경유. 이 시스템의 실제 병목(무선+SSH, 유선 대비 ~166x)과 **완전 분리**. → 0 영향 |
| 입력 레이턴시 | 트리거는 전부 **supervisor 스레드**에서 감지(낙상/최대속도/킥) — 입력 reader 스레드와 분리. `m_mtx` 보유는 짧고(드문 이벤트) reader 는 select 밖에서만 잠금 |
| E-STOP 응답성 | 진동은 E-STOP 패스트레인에 **미배선**. estop 경로 불변 |
| write 폭주 | 엣지/주기 발화(낙상·킥 1회, 최대속도 450ms 주기)로 빈도 제한. non-blocking write |
| FF 미지원 폴백 | O_RDONLY 폴백·업로드 실패·미연결·`enabled=0` 이면 무동작(graceful, 입력 정상) |

---

## 6. 배포 / 검증

### 6-1. 호스트 단위 테스트
`make -C firmware-patches/walklab-brokerage/tests` → **514 checks / 0 failures**
(transport 188 + gamepad 279 + brokerage_actions 47). 햅틱 결정 로직(`AtForwardSpeedCap`·
`RisingEdge`) 엣지 케이스 포함. GamepadPilot.cpp(FF 코드, `#ifdef __linux__` 가드)도 호스트 빌드 정상.

### 6-2. 실기 배포 (무선 darwin-wifi = robotis@192.168.0.33)
유선(192.168.123.x)은 Mac USB-LAN 서브넷 불일치로 미사용 → 무선으로 진행.
1. `scp` 변경 소스 + balltrack.ini → `/robotis/Linux/project/demo/`
2. robotis `make`(sudo 불요, demo 디렉터리 robotis 소유) → `rc=0` 무경고
3. NOPASSWD sudo 로 walklab 재기동: `sudo killall demo` → `echo walklab>/tmp/df-pilot-mode` →
   `setsid sudo ./demo`. 로그: walklab-init→walk-ready→gyro-calibration→walklab-active→
   `device acquired: 045e:028e — ARM(A) required`.

### 6-3. 실기 입회 확인
A(ARM) 후 킥·최대속도 유지·낙상 유발 — 3개 진동 의도대로 동작, 사용자 확인("아주 좋아").
1차 배포(약/짧음) → 사용자 피드백 → 강화/반복/길이 조정 → 2차 배포 → 최종 확인.

---

## 7. 설정 / 운용

`/robotis/Linux/project/demo/balltrack.ini`:
```ini
[Haptics]
enabled = 1     ; 0 = 진동 전면 비활성(재빌드 불요, demo 재기동 시 반영)
```
강도/길이/주기는 코드 상수(트리거별):
- 낙상 `Rumble(100,100,2000)` · 킥 `Rumble(100,100,1000)` · 최대속도 `Rumble(80,80,200)` @ 450ms.
- 100% = 하드웨어 최대(0xFFFF) — 낙상·킥은 이미 최대치.

---

## 8. 한계 / 후속

- **강도 상한**: 낙상·킥은 양모터 100% = 물리 최대. 이 이상 강화 불가(모터 한계).
- **최대 회전(turn) 진동 미구현** — 사용자 최종 요청에서 제외. 동일 패턴으로 A_MOVE 캡에
  추가 가능(후속).
- **유선 경로 미사용** — Mac USB-LAN 이 로봇 eth0(192.168.123.1)와 다른 서브넷(192.168.50.1).
  유선 쓰려면 Mac en10 을 192.168.123.x 로 수동 설정 필요(무선은 정상).
- **무선 플래핑** — 배포 중 SSH 간헐 끊김 관측(재시도 로직으로 흡수). 측정/대량 전송은 유선 권장.

---

## 9. 관련 파일 / 커밋

- 커밋 `34f9667` — feat(walklab) 햅틱 피드백 (이 문서의 대상)
- 소스: `firmware-patches/walklab-brokerage/GamepadPilot.{cpp,h}`(Rumble/FF infra)·
  `WalkLabBrokerage.{cpp,h}`(3 트리거+config+루프 반복)·`BrokerageActions.h`(판정)·
  `tests/test_brokerage_actions.cpp`(514 checks)·`balltrack.ini`([Haptics])
- FF 테스트 원본: `/tmp/ff_test.cpp`(일회성, 미커밋 — 본 문서에 코어 인용)
- 배경: `docs/reports/2026-06-13-rgg01-bringup.md`(동글 매핑 실측)
