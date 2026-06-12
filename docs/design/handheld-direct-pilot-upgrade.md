# 핸드헬드 직결 파일럿 — RG G01 2.4G 동글 직결 + Switch 무선 최적화 설계 (Handheld Direct Pilot)

> 2026-06-11 · Switch 무선 경로(실기 검증 2026-06-07) 전수 독해 + RG G01 매핑 자산 +
> 로봇 커널 입력 능력(01-system-os.md) 교차 검증 결과.
> 목표: **RG G01 의 2.4G 동글을 로봇 등 USB 에 꽂아** 조종하는 신규 경로의 설계와, 같은
> 계열인 Switch 무선 경로의 최적화. 명령 계약·브로커리지는
> `docs/design/walklab-onboard-teleop-upgrade.md`(O-Wave)와 합류한다.
> **2026-06-11 갱신**: 사용자 결정으로 기본 연결을 USB-C 유선 → **2.4G 동글**로 승격.
> 유선은 계측·디버그·동글 장애 시 폴백으로 강등(코드 경로는 동일 — evdev).

## 0. 결론 요약

핸드헬드 조종은 이제 토폴로지 3종이 된다. RG G01 직결은 **네트워크 스택 자체가 없어지는**
경로라서, 구현되면 전 조종 경로 중 최저 지연이 된다:

| 토폴로지 | 입력→파라미터 적용(현재) | 동일(업그레이드 후) | 상태 |
|---|---|---|---|
| Mac 콕핏 (유선 bus/SSH) | bus ~100–150ms / SSH 0.4–1.5s | bus ≤60ms(D1) / SSH ≤120ms(O1) | 설계 완료(D/O-Wave) |
| **Switch 무선** (Wi-Fi SSH) | **RTT p50 227ms·p95 664ms 실측** + send 5Hz | UDP 전환 시 ~30ms+RTT | **실기 검증 완료** |
| **RG G01 로봇 직결** (2.4G 동글 → USB HID) | — (신규) | **라디오 ~2–5ms + USB 8ms + 루프 20ms ≈ ~35ms**, E-STOP 로컬 ~수 ms | 본 문서 · 유선 USB-C 는 폴백 |

핵심 근거 3가지:

1. **로봇이 게임패드를 읽을 수 있다**: 커널 3.2.66-op2 에 `JOYDEV=m`·`EVDEV=y`·`USB_HID=m`·
   `JOYSTICK_XPAD=m`·`HIDRAW=y` 탑재 확인(`docs/firmware-reference/01-system-os.md:42-73`).
   온보드 직결 타당성 검토도 기존재(`docs/reports/gamepad-direct-control-feasibility.md:178-248`).
2. **입력→명령 변환 코드가 두 벌이나 이미 있다**: Switch 의 Python mapper
   (`tools/switch-pilot/.../mapping.py:23-116` — 데드존 0.12·drive_curve 1.35·
   **intensity→period/foot 게이트 스케줄링**)와 콕핏의 RG G01 프리셋
   (`ControllerBindingProfile.swift:184-230` — LT/RT=머리팬·B=estop·Y=복구·X=볼트랙·
   LB=데드맨·RB=터보). 직결 데몬은 이 의미론의 C++ 이식이지 신규 발명이 아니다.
3. **명령 합류 지점이 이미 설계돼 있다**: O1 브로커리지 v2 의 latest-wins 슬롯에
   "local 소스"를 하나 더 꽂는 구조 — Walking 125Hz 엔진은 무변경.

리스크 1순위는 **동글 수신기의 인식 모드 불확실성**(XInput 전용이면 구형 xpad 가 VID/PID 를
몰라 바인딩 실패 가능)과 **링크 단절 거동 불명**(패드 전원 OFF/거리 이탈 시 release 이벤트를
내는지 — failsafe 설계의 입력) — H0 프로브가 첫 단계이고, D-input(범용 HID)·xpad `new_id`·
유선 USB-C 3중 폴백을 둔다.

## 1. 현재 자산 — 검증된 사실

### 1.1 Switch 무선 경로 (실기 검증 2026-06-07, Switch 192.168.0.25 → 로봇 192.168.0.33)

```
[Switch] evdev 폴 10ms → ControllerMapper(데드존 0.12 → drive_curve 1.35 → 클램프)
  → 안전 정산(E-STOP > ARM > STOP, main.py:469-496) → gate_motion
  → SshControlClient: ControlMaster(-o ControlPersist=30, uid 포함 경로) +
    atomic write 14-token, send_hz=5(200ms)                    ssh_control_client.py:119-369
  → 로봇 brokerage 100ms 폴 → Walking
[E-STOP] touch /tmp/df-walklab-estop + 900ms heartbeat 재계약   main.py:289-303
[텔레메트리] cat 폴 1Hz → 배터리/자이로/낙상 화면 표시
[봉인] L1 부팅(hekate)~L4 전원버튼 STOP, systemd watchdog       tools/switch-appliance/
```

- 실측(2026-06-02, `docs/reports/2026-06-02-wireless-control-verification.md`): 752건 송신,
  **RTT p50 227ms / p95 664ms / max 3.8s**, 순단 ~14s 1회 자동 회복.
- 주목: Switch mapper 의 **intensity^0.7 → period 560–700·foot 18–48 스케줄링**
  (`ssh_control_client.py:278-302`)은 온보드 O2-5 게이트 스케줄링의 선행 구현이다.

### 1.2 RG G01 (콕핏 자산)

- Xbox 레이아웃 + 중앙 IPS 스크린, **USB-C 유선 / 2.4G 동글 / BT** 3모드
  (`docs/reports/cockpit-controller-keymapping-design.md`).
- 콕핏 프리셋 "Xbox / RG G01 (기본)" 확정: 축 0/1=이동, 2=턴, 3=머리틸트, LT/RT=머리팬,
  B=E-STOP·Y=복구(안전, unbound 불가), X=볼트랙, LB=데드맨(기본 ON), RB=터보,
  failsafe=.freeze→stop (`ControllerBindingProfile.swift:184-230`).

### 1.3 로봇 수용 능력

- USB: NM10/ICH7 — UHCI×4 + EHCI×1, 현재 ttyUSB0(CM-740)·UVC 카메라 사용. HID 트래픽은
  대역 무시 가능 수준.
- 입력 스택: `joydev`·`evdev`·`usbhid`·`xpad`(Xbox360 세대)·`hidraw`·`uinput` 확인.
  주의: 2015년형 xpad 는 최신 패드 VID/PID 미등재 — **D-input 모드가 1순위**, XInput 만
  지원 시 `echo <VID> <PID> > /sys/bus/usb/drivers/xpad/new_id` 표준 메커니즘으로 바인딩.
- 원격 실행 채널: df-inbox watcher(SMB `.sh` 자동 실행, 2s)가 영구 등록돼 있어 **프로브를
  Mac 에서 원격 수행 가능**(`RobotSetupCommand.swift:1272-1314`).

## 2. 토폴로지 결정 — RG G01 연결 3트랙

| 트랙 | 연결 | 인식 경로 | 판정 |
|---|---|---|---|
| **A. 2.4G 동글 (기본 — 사용자 결정 2026-06-11)** | 동글만 로봇 USB | 동글이 HID 로 enumerate (대개 범용 D-input) | **1순위** — 본 설계 기본. 케이블 스내그 원천 제거 |
| A'. USB-C 유선 | 로봇 등 USB 포트 | D-input→evdev / XInput→xpad new_id | **폴백·계측용** — 같은 코드 경로(evdev). 동글 장애·페어링 불가·정밀 지연 측정 시 |
| B. BT 페어링 | 로봇 BT 어댑터 | BT_HIDP | 비권장 — 커널 3.2 BT 스택에 최신 패드 페어링 신뢰성 낮음 |
| C. G01 을 컴퓨터로(네트워크 가젯) | USB 네트워킹 | G01 OS 에 파일럿 앱 | 조사 항목으로만 — G01 OS/개발 환경 불명, Switch 가 이미 이 역할 |

동글(A) 기본의 운영 의미: 보행 중 케이블 스내그가 원천 제거되고 시연 동선이 자유로워진다.
대신 유선에는 없던 고려 3가지가 생긴다 — ① **링크 단절 거동**: 동글은 패드 전원 OFF/거리
이탈에도 USB 노드가 사라지지 않으므로 "노드 소멸 = 분리" 가정이 깨진다. 단절 시 동글이
버튼 release 이벤트를 합성하는지 H0 에서 실측해 failsafe(§4 H2)를 그 거동에 맞춘다.
② **패드 절전**: 무입력 자동 전원 OFF 타임아웃을 H0 에서 측정 — 데드맨 홀드 중에도 꺼지는지
확인. ③ **2.4GHz 공존**: 로봇 Wi-Fi(SSH·텔레메트리)와 같은 대역 — 시연 환경에서 동시 사용
간섭을 H0 에서 확인(동글 자체 주파수 호핑이 일반적이라 근거리에선 문제없을 가능성 높음).
유선(A')은 코드 변경 0 으로 전환 가능하므로 정밀 계측·동글 트러블슈팅 시 사용.

## 3. 갭 분석 (조종 계열 전체)

| # | 갭 | 현재 | 영향 |
|---|---|---|---|
| HG1 | 로봇에 입력 소스 없음 | brokerage 는 파일(+O1 예정 UDP)만 소비 | G01 직결 불가 — H1 의 본체 |
| HG2 | Switch 송출률 | send_hz=5(200ms) + SSH exec | 무선 지연의 절반은 자초 — O1 UDP 클라이언트로 해소 |
| HG3 | E-STOP heartbeat 의존 | estop 파일 + 900ms 재계약 | 순단 중 estop 유실 가능성(파일은 남으나 재계약 실패 로그) — UDP ×3연발(O1)로 보강 |
| HG4 | 매핑 수치 3벌 분산 | 콕핏 38/22/12 vs Switch 50/26/18 vs 데몬 클램프 | 기기마다 조종감 상이, 거버너 부재 구간(switch 50mm!) — O2 거버너가 로봇에서 최종 클램프 필수 |
| HG5 | 소스 중재 부재 | Mac/Switch/G01 동시 입력 시 정의 없음 | 명령 충돌 — H2 중재 규칙 |
| HG6 | 텔레메트리 소비 불균형 | Switch 1Hz cat 폴 | O4 TEL2 UDP 30Hz 로 통일 |

## 4. 업그레이드 로드맵 — 4 Wave

### Wave H0 — 호환성 프로브 (S) — 모든 분기의 입구

df-inbox 채널로 원격 실행하는 프로브 스크립트(`firmware-patches/tools/probe-gamepad.sh` 신설):

```sh
lsusb; dmesg | tail -40                          # VID/PID·바인딩 드라이버 확인
ls -l /dev/input/ ; cat /proc/bus/input/devices   # event*/js* 노드와 이름
# evtest 미설치 대비 — od 로 이벤트 레이트 측정(16byte/24byte 구조체 카운트)
timeout 3 od -An -tx1 /dev/input/eventN | wc -c
```

- 판정 매트릭스(**동글 우선**): ① 2.4G 동글이 D-input event 노드 생성 → Track A 확정
  ② XInput 만 → `xpad new_id` 시도 후 재판정 ③ 유선 USB-C 동일 절차(폴백 확보)
  ④ 전부 실패 → Track C 조사로 전환.
- 측정(공통): 축 이벤트 레이트(기대 125–250Hz), 16bit 축 범위(EVIOCGABS), 버튼 코드 →
  **G01 전용 코드 테이블**을 H1 의 상수로 확정.
- 측정(**동글 전용 — failsafe 설계 입력**):
  1. **링크 단절 거동**: 데드맨(LB) 홀드 중 패드 전원 OFF / 거리 이탈 — 동글이 release
     이벤트를 합성하는지, USB 노드가 유지되는지, 재연결 시 자동 복귀하는지.
  2. **패드 절전 타임아웃**: 무입력 자동 OFF 까지 시간, 데드맨 홀드(정적 입력)가 keep-alive
     로 인정되는지.
  3. **2.4GHz 공존**: 로봇 Wi-Fi SSH 세션 + 동글 입력 동시 구동 시 이벤트 드랍/지연 여부.
- (d) 검증 = 프로브 결과를 `docs/reports/` 에 기록. (e) S / 리스크 없음(읽기 전용).

### Wave H1 — 온보드 게임패드 입력 소스 (M~L) — "직결"의 본체

`firmware-patches/walklab-brokerage/` 에 `GamepadPilot.{h,cpp}` 신설(C++03, ~400줄):

1. **장치 스캔/핫플러그**: `/dev/input/event*` 글롭 → 이름/VID 매칭(H0 테이블), 1s 주기
   재스캔(동글/유선 분리 감지 겸용) — switch-pilot `input_linux.py:211-375` 로직의 C 이식.
   **동글 주의**: 패드 전원 OFF/거리 이탈에도 동글의 event 노드는 유지될 수 있음 —
   노드 존재 ≠ 패드 생존. 패드 생존 판정은 H0 실측 거동(단절 시 release 합성 여부) +
   **EVIOCGKEY 1s 상태 폴**(이벤트 무관하게 현재 키 상태 ioctl — 비용 µs 단위)을 병행.
2. **읽기 스레드**: blocking `read()`(O1 transport 스레드 모델과 동형 — 폴링 0).
   축 정규화: EVIOCGABS 실측 범위 → [−1,1].
3. **매핑(의미론 = 콕핏 RG G01 프리셋과 1:1)**: LS=이동/횡, RS X=턴·Y=머리틸트,
   LT/RT=머리팬, B=E-STOP(rising edge, 데드맨 무시) · Y=복구 · X=볼트랙 토글,
   LB=데드맨(이동/턴 게이트, 머리·안전 비게이트), RB=터보.
   성형 수치는 **3벌 통일안**(§5 패리티 표): 데드존 0.10, drive_curve 1.35,
   stride/side/turn 클램프는 로봇 거버너(O2-3)가 최종 소유.
4. **게이트 스케줄링**: switch-pilot 의 intensity^0.7 → period/foot 식 채택(검증된 조종감)
   — O2-5 와 같은 테이블 상수 공유.
5. **명령 합류**: O1 의 latest-wins 슬롯에 `source=local` 로 주입 — 적용은 기존 supervisor
   단일 지점. **O1 미구현 상태에서도 동작하도록** 1차 버전은 ParseAndApply 와 동급의 적용
   함수를 직접 호출(가드: E-STOP·낙상·MODE 버튼 체크는 기존 Run() 흐름 재사용).
6. **E-STOP 로컬화**: B 버튼 → 읽기 스레드에서 즉시 `Walking::Stop()`+토크 OFF
   (네트워크·파일 경유 0) — 로봇 측 지연 ~수 ms. estop 파일도 set(다른 클라이언트 가시성).
- (a) 변경: brokerage(+`GamepadPilot`), main.cpp 주입 블록은 무변경(brokerage 내부 확장).
- (d) 검증: 크래들에서 ① 축→파라미터 단위 테스트(호스트 빌드 스텁) ② E-STOP 버튼→
  walking=0 TEL 전환 ≤20ms ③ USB 분리→§H2 failsafe ④ 10분 조종 CPU 점유(<5% 기대).
- (e) M~L / 리스크 중 — 구형 커널 HID 양자화·이벤트 드랍은 H0 실측으로 조기 판정.

### Wave H2 — 소스 중재 + 안전 의미론 (S~M)

1. **소스 우선순위**: `E-STOP(모든 소스, 항상) > local 게임패드(최근 입력 ≤1s) > 네트워크
   (Mac/Switch)`. local 활성 중 네트워크 walk 명령은 무시하되 **estop·복구·모드 전환은 전
   소스 상시 유효**. TEL2 에 `active_source` 필드 추가(누가 조종 중인지 가시화).
2. **분리 failsafe (동글 기준 3중)**: ① 동글이 단절 시 release 를 합성하면(H0 실측) 데드맨
   해제가 즉시 이동 게이트를 잠금 — 1차 방어. ② EVIOCGKEY 폴 실패/노드 소멸(동글 뽑힘·유선
   분리) → `inputSourceLost` 즉시 제자리 슬루. ③ 단절 시 이벤트가 그냥 멈추는 동글이면
   "데드맨 마지막 확인 ≥1.5s 경과" 를 단절로 간주(보수적 추정) → O1 워치독 티어
   (600ms 제자리 → 2.5s 정지) 합류. **패드 절전(H0 측정값)이 1.5s 추정 창보다 짧으면
   임계 재조정.**
3. **ARM 절차**: 콕핏과 동일 의미론 — 데드맨(LB) 홀드 없이는 이동 0. 부팅 직후 자동
   walklab 진입 시 G01 이 꽂혀 있어도 **A 버튼 ARM 전에는 게이트 잠금**(switch-pilot
   settle_safety_state 규칙 이식, `main.py:469-496`).
4. **운용 수칙**: 기본은 동글(케이블 프리). 유선(A') 사용 시에만 등판 스트레인 릴리프 적용.
   시연 전 체크: 패드 충전 상태·페어링 확인·E-STOP 리허설 — 문서화.

### Wave H3 — Switch 무선 경로 최적화 (S~M, O1 의존)

> **구현 완료 (2026-06-12, `ae23e5c` · P10)** — 코드/테스트 완료, 실기(무선 실효율·
> E-STOP) 별도 세션 대기. `tools/switch-pilot` SshControlClient + `df_udp`(신규)에 §G
> UDP 패스트패스 소비: 핸드셰이크/DFCMD 20Hz/ACK·RTT/DF-ESTOP ×3연발+SSH touch
> 병행/TEL2 30Hz 수신, `transport=auto` 폴백(ACK 무응답 1.5s→SSH 5Hz). 단위 +24,
> 풀 스위트 237/237. 항목 ③ 단서: estop 재발화 간격은 900ms 유지(estop=로봇 래치,
> edge 가 ×3연발+touch 발화; 워치독 정합은 20Hz 명령 스트림이 충족) — 실기에서 재평가.

1. **O1 UDP 클라이언트**: SshControlClient 에 UDP transport 추가(V2 프로토콜, seq+토큰) —
   send_hz 5→**20**, E-STOP UDP ×3연발+SSH 병행(기존 파일 경로는 폴백 유지).
   기대: 명령 지연 200ms+RTT → ~50ms+RTT(무선 RTT 는 환경 의존이라 잔존).
2. **텔레메트리**: 1Hz cat 폴 → TEL2 UDP 수신(O4) — Switch 화면에 위상·배터리·낙상 실시간.
3. **heartbeat 재설계**: estop 재계약 900ms → UDP keepalive 250ms(워치독 티어와 정합).
- (e) S~M / 리스크 낮음(클라이언트 측 가산, 로봇 측은 O1 산출물 소비).

## 5. 매핑 패리티 표 — "한 가지 조종 문법" (3벌 통일안)

| 항목 | 콕핏(Mac) 현재 | Switch 현재 | **통일안(전 기기)** |
|---|---|---|---|
| 데드존 | 0.10 | 0.12 | **0.10** |
| 곡선 | expo 0(선형, 축튜닝 옵션) | drive_curve 1.35 | **1.35 지수곡선** |
| stride 클램프 | 38mm | **50mm(거버너 없음!)** | UI 38mm + **로봇 거버너 최종 클램프(O2-3)** |
| side / turn | 22mm / 12° | 26mm / 18° | 22mm / 12° (거버너 동일) |
| 게이트 스케줄 | 없음(period 수동) | intensity^0.7→period 560-700·foot 18-48 | **채택, O2-5 테이블 공유** |
| E-STOP | B(즉시) | Home(즉시)+파일 | B/Home rising edge — 전 소스 상시 |
| 데드맨 | LB 기본 ON | ZL/ZR | LB(또는 ZL) 기본 ON |

Switch 의 stride 50mm 는 로봇 측 거버너 부재 상태의 위험 요소 — **O2-3(로봇 최종 클램프)이
이 계열 전체의 전제 안전판**임을 명시한다.

## 6. 레이턴시 버짓 (목표)

| 경로 | 분해 | 목표 |
|---|---|---|
| G01 직결(동글): 입력→파라미터 적용 | 2.4G 라디오 ~2–5ms + USB HID 폴 ~8ms + 슬롯→supervisor ≤20ms | **p95 ≤ 40ms** (유선 폴백 ≤35ms) |
| G01 직결: E-STOP→torque-off | 버튼 edge → 즉시 Stop | **p95 ≤ 20ms** |
| G01 직결: 입력→진폭 래치 | + 반주기(≤300ms@600) | ≤ 350ms (구조 하한, O2 와 동일) |
| Switch(H3 후): 입력→적용 | 매핑 ~0 + UDP 1패킷 + RTT + 슬롯 | ~50ms + 무선 RTT |

## 7. 검증 프로토콜·리스크

- 실기 게이트: 크래들 → March → 평지 저속 → 시연. 매 단계 E-STOP(G01 B 버튼) 리허설.
- 합동 시나리오 테스트: ① G01 조종 중 Switch 에서 estop → 즉시 정지(소스 중재) ② **패드
  전원 OFF(데드맨 홀드 중)** + 동글 뽑기 — 각각 failsafe 티어 진입 확인 ③ Mac 콕핏 관전
  모드에서 TEL2 active_source 표시 확인 ④ 패드 재전원 → 자동 재획득(ARM 은 다시 요구).
- 리스크 표:

| 리스크 | 완화 |
|---|---|
| 동글이 XInput 전용 + xpad 미인식 | H0 에서 new_id → 실패 시 D-input 펌웨어 설정 탐색 → 유선(A') 폴백, 최후 Track C |
| **동글 링크 단절 시 무신호**(release 미합성) | H0 실측으로 거동 확정 → 3중 failsafe(§4 H2-2): 데드맨 release / EVIOCGKEY 폴 / 1.5s 보수 추정 |
| **패드 절전·배터리 방전**(보행 중 전원 OFF) | H0 절전 타임아웃 실측 → failsafe 창 재조정, 시연 전 충전 체크리스트 |
| 2.4GHz 간섭(로봇 Wi-Fi 공존) | H0 동시 구동 확인 — 문제 시 로봇 SSH 를 유선(123.1)으로, 동글은 근거리 유지 |
| 커널 3.2 HID 이벤트 드랍/지터 | H0 레이트 실측 — 60Hz 미만이면 보간 없이 그대로(슬루가 흡수) |
| 케이블 스내그(유선 폴백 사용 시에만) | 등판 스트레인 릴리프 + 분리 failsafe |
| 소스 중재 버그(이중 조종) | active_source 단일 변수 + 단위 테스트(호스트 빌드) |
| EHCI 대역(카메라 동시) | HID interrupt 전송은 µ단위 — 영향 없음(프로브에서 동시 구동 확인) |

## 8. 타 문서와의 분담·착수 순서

| 주제 | 본 문서 | 관련 |
|---|---|---|
| latest-wins 슬롯·워치독 티어·UDP 프로토콜 | H1/H3 이 소비 | walklab-onboard-teleop-upgrade O1 |
| 거버너·게이트 스케줄 테이블 | §5 패리티의 전제 | O2-3·O2-5 (상수 공유) |
| TEL2(active_source 필드 추가) | H2 가 요구 | O4 |
| 콕핏 매핑 의미론 | H1 이 이식 | ControllerBindingProfile(.xbox 프리셋) |
| Switch 클라이언트 | H3 | tools/switch-pilot (O1 클라이언트화) |

권장 순서: **H0(즉시, 읽기 전용) → H1(O1 과 병행 가능, 1차는 독립 동작) → H2 → H3(O1 후)**.
H0 는 로봇 전원만 있으면 df-inbox 로 오늘이라도 실행 가능하다.

```sh
# H0 프로브 (Mac 에서): SMB df-inbox 에 probe-gamepad.sh 투하 → .out 회수
# H1 호스트 빌드: firmware-patches/walklab-brokerage/tests/ 스텁 빌드 (로봇 toolchain 불요)
# 실기 배포: 기존 demoBuildPatched 채널 재사용 (RobotSetupCommand.swift:932-1034)
```
