# RG G01 2.4G 동글 USB 프로브 — Wave H0 실측 보고

> 2026-06-12 · 실기 DARwIn-OP2 (kernel 3.2.66-op2, i686) · 무선 192.168.0.33 경유 SSH 직접 실행
> 설계: `docs/design/handheld-direct-pilot-upgrade.md` §4 Wave H0
> 도구: `firmware-patches/tools/probe-gamepad.sh` (신설 — evtest 미설치 환경용 python2 ioctl 프로브)
> 원시 출력 발췌는 부록 A. 멀티에이전트 교차 리뷰(31건) 반영판.

## 0. 결론 — Track A (2.4G 동글) 확정

**동글은 XInput(Xbox360 클론, `045e:028e`)으로 enumerate 되지만, 이 VID/PID 는 2015년형
xpad 가 네이티브로 아는 정식 Xbox360 ID 라서 `new_id` 조작 없이 자동 바인딩됐다**
(부록 A.1). 설계의 리스크 1순위(xpad 미인식)는 기우였다.

링크 단절(graceful — 전원 버튼 OFF 1회 실측) 시:

1. **커널 input core 가 눌린 버튼의 release 를 합성**하고 (데드맨 해제 신호),
2. **~1ms 뒤 USB 노드가 소멸**한다 (ENODEV).

단, 이 둘은 독립된 2중 방어가 아니라 **단일 사건(USB disconnect → input unregister)의
두 증상**이다 — 동글이 패드 단절을 USB 분리로 전환해 주는 한 결정적으로 동작하지만,
동글이 버스에 남는 단절 모드가 존재한다면 둘 다 동시에 침묵한다. **거리 이탈·배터리
탈락 같은 비정상 RF 단절은 미측정**이므로(§8 잔여), 설계의 최악 케이스("노드 유지 +
무신호")는 "graceful 단절에서는 발생하지 않음"까지만 확정한다. H2 failsafe 3티어
(1.5s 보수 추정)는 보험이 아니라 **동글이 USB 분리를 일으키지 않는 모든 케이스의
1차 방어**로 유지해야 한다.

| 판정 항목 | 결과 |
|---|---|
| 동글 인식 모드 | XInput (`045e:028e` 클론) — D-input 아님 (A.1) |
| 드라이버 바인딩 | **xpad 자동 바인딩** (new_id 불요) → `event8` + `js0` (A.1) |
| 모듈 핫플러그 | usbhid·xpad·joydev·ff_memless 전부 자동 modprobe (A.1) |
| 이벤트 레이트 | **SYN ~422/s** (축 ~790/s) — 기대 상한 250Hz 의 ~1.7배 (A.3) |
| 링크 단절 (전원 OFF, n=1) | release 합성 → ENODEV (간격 ~1ms). **단 OFF→release 지연은 미측정(≲2s 추정)** (§5) |
| 재연결 | 패드 재전원 → 자동 복귀, USB 재enumerate 기점 ~1.3s (n=1, -71 재시도 1회) (A.4) |
| Wi-Fi 공존 | 48MB scp 부하 1회 측정에서 저하 미관측 (442 vs 422 SYN/s — 인적 입력 변동 범위 내) (A.3) |
| 패드 절전 | 무입력 **~10분**(9.5~11.6분 구간, n=1)에 자동 OFF — 노드 소멸 실측 (§5-2, A.5) |
| 유선 USB-C 폴백 | **불발** — enumerate 자체 없음, 미측정 종결 (§6) |

## 1. 실행 환경·방법

- 로봇: walklab 데모 구동 중(root, `/robotis/Linux/project/demo/demo`) — 프로브와 충돌
  없음, 데모는 event 노드를 grab 하지 않음.
- 채널: **SSH 직접** (`robotis@192.168.0.33`, identity 절대경로
  `/Users/bbikiming/.ssh/id_rsa_darwin`, OpenSSH 5.9 호환 `+ssh-rsa` 옵션).
  **주의 — df-inbox watcher 는 이 로봇에 미등록 상태였다** (프로세스·`~/.df_inbox`·
  `/etc/init.d/df-inbox` 모두 부재). 설계 §1.3 의 "영구 등록" 전제는 현 시점 거짓.
  또한 watcher 스크립트는 `su - robotis` 로 실행되므로 등록돼 있었어도 아래 권한
  문제는 동일했다.
- 권한: `/dev/input/event*` 는 `root:root 0640` — **robotis 계정으로 이벤트를 읽을 수
  없다.** 프로브는 sudo 로 실행(읽기 전용 — 영구 변경 없음). **H1 함의: GamepadPilot 은
  root 로 도는 brokerage(데모 주입) 안에 있으므로 문제없으나, 사용자 공간 테스트
  도구는 sudo 가 필요하다.**
- 영구 변경: 없음. xpad new_id 도 불필요해 미사용. /tmp 산출물은 시험 후 제거.
- 한계 고지: 물리 조작(동글 삽입·패드 전원·스틱/버튼 시퀀스)은 구두 프로토콜로
  지시했고 로그에는 값만 남는다 — **부호↔물리방향 대응은 조작 프로토콜 기반**이며,
  단절·절전·재연결은 각 1회 시행(n=1)이다.

## 2. USB enumerate — 동글의 2모드

베이스라인(동글 없음): RT2870 Wi-Fi · Logitech C905 카메라 · FTDI(CM-740) 뿐 (A.1).

동글 삽입 후 dmesg 로 확인된 **동글의 두 가지 USB 인격**:

| 패드 링크 상태 | USB 정체 | 바인딩 | 노드 |
|---|---|---|---|
| 미링크 (패드 OFF/절전) | `1A34:F517` "Receiver Update" | usbhid (generic) | hiddev0/hidraw0 만 — **input 노드 없음** |
| 링크 (패드 ON) | `045e:028e` "Xbox360 Controller" (클론) | **xpad** | `input: Microsoft X-Box 360 pad` → `event8` + `js0` |

패드 링크가 서거나 끊길 때 동글이 **USB 버스에서 분리 후 재enumerate** 하며 인격을
전환한다 — 링크 성립(A.1 1303s)·절전 단절(A.5 3328s)·재전원(A.4 2460s)에서 각각 실측.
따라서 **"evdev 노드 존재 ⇒ 패드 링크 생존"** 이 graceful 단절에서 성립하되, 단절이
노드에 반영되기까지 **최대 ~2s(미측정 추정)의 지연 창**이 있고, 비정상 단절(거리
이탈·배터리 탈락)에서의 거동은 미측정이다 (§8).

- 인터페이스 디스크립터: `class=ff sub=5d proto=01` (XInput 시그니처, A.1).
- full-speed (12Mbps, UHCI bus2) — "not running at top speed" 경고는 무해.
- 럼블(FF) 지원: `Registered led device: xpad0`, ff_memless 자동 로드 (A.1).
- dmesg 이력의 841s→1027s→1100s Receiver Update 재출현은 시험 초기 동글 수동
  재삽입으로 추정 (조작 기록 없음).

## 3. H1 코드 테이블 (확정)

장치 매칭: 이름 `"Microsoft X-Box 360 pad"` + VID/PID `045e:028e` (EVIOCGID 실측, A.2).
구조체: i686 에서 `struct input_event` = **16 bytes** (timeval 8 + type 2 + code 2 + value 4) — 실측 디코드 검증.

### 축 (EVIOCGABS — 부록 A.2 원문)

| 물리 컨트롤 | evdev 축 | code | 범위 (EVIOCGABS) | fuzz/flat | 부호·실관측 비고 |
|---|---|---|---|---|---|
| 왼스틱 X (이동/횡) | `ABS_X` | 0 | −32768..32767 | 16/128 | 풀레인지 이벤트 실관측. 오른쪽=+ 는 표준 가정 — **H1 브링업 시 확인** |
| 왼스틱 Y (이동) | `ABS_Y` | 1 | −32768..32767 | 16/128 | 아래=+ (조작 프로토콜 실측, A.3) |
| 오른스틱 X (턴) | `ABS_RX` | 3 | −32768..32767 | 16/128 | 오른쪽=+ (조작 프로토콜 실측). 풀레인지 실관측 |
| 오른스틱 Y (머리틸트) | `ABS_RY` | 4 | −32768..32767 | 16/128 | 아래=+ (조작 프로토콜 실측). 음끝값(−32768)은 이벤트 미관측 — 캡 값 |
| LT (머리팬 좌) | `ABS_Z` | 2 | 0..255 | 0/0 | 0→255 풀레인지 이벤트 실관측 |
| RT (머리팬 우) | `ABS_RZ` | 5 | 0..255 | 0/0 | 0→255 풀레인지 이벤트 실관측 |
| D패드 X | `ABS_HAT0X` | 16 | −1..1 | 0/0 | 오른쪽=+1 실관측. **좌(−1) 미관측** — 캡 값 |
| D패드 Y | `ABS_HAT0Y` | 17 | −1..1 | 0/0 | 아래=+1 실관측. **상(−1) 미관측** — 캡 값 |

flat=128(≈0.4%)·fuzz=16 은 kernel 3.2 xpad 의 `input_set_abs_params` 기본값과 일치 —
H1 데드존(통일안 0.10)이 훨씬 크므로 실무 영향 없음.

### 버튼 (KEY — 9버튼 + D패드 우/하 실측, 스틱클릭·D패드 좌/상 미실측)

| 물리 버튼 | evdev | code | 실측 | 콕핏 의미론 (H1 매핑) |
|---|---|---|---|---|
| A | `BTN_A`(SOUTH) | 304 | ✓ | ARM (H2) |
| B | `BTN_B`(EAST) | 305 | ✓ | **E-STOP** (rising edge, 데드맨 무시) |
| X | `BTN_X`(NORTH) | 307 | ✓ | 볼트랙 토글 |
| Y | `BTN_Y`(WEST) | 308 | ✓ | 복구 |
| LB | `BTN_TL` | 310 | ✓ | **데드맨** (기본 ON) |
| RB | `BTN_TR` | 311 | ✓ | 터보 |
| Back | `BTN_SELECT` | 314 | ✓ | — |
| Start | `BTN_START` | 315 | ✓ | — |
| Home | `BTN_MODE` | 316 | ✓ | (Switch 패리티상 E-STOP 후보 — H2 결정) |
| 왼스틱 클릭 | `BTN_THUMBL` | 317 | 캡만 | — |
| 오른스틱 클릭 | `BTN_THUMBR` | 318 | 캡만 | — |

**H1 주의**: `BTN_TL2/TR2`(312/313) 없음 — **트리거는 순수 아날로그**(ABS_Z/RZ, 이벤트
0건 실측 교차확인). 머리팬 매핑은 아날로그 임계(예: >64) 또는 비례 제어로 구현.

## 4. 이벤트 레이트·지연 특성

| 측정 | 값 | 출처 |
|---|---|---|
| rate 12s (시퀀스 후 연속 스틱 입력) | **SYN 422.2/s · ABS 790.5/s** (2축 환산 ~395/축) | A.3 |
| rate 15s + Wi-Fi 48MB scp 부하 | **SYN 442.1/s · ABS 793.6/s** | A.3 |
| watch (왼스틱 원그리기, 활동 초당 버킷) | 축당 피크 ~470–490 ev/s | circles 캡처 |

- 리포트 레이트 ~420–440Hz ≈ bInterval 2ms 급 — 기대 상한(250Hz)의 ~1.7배.
  50Hz 샘플러(H1) 기준 충분 이상.
- 부하 비교는 1회 측정이며 +5% 차이는 인적 입력 강도 변동(런간 ~20%) 범위 내 —
  "저하 미관측(근거리)" 까지만 판정 (§5-3).
- 타임스탬프는 사용자공간 수신 시각 기준(ms 급 해상도) — 커널 timeval 아님.
- 커널 3.2 HID 드랍/지터 리스크(설계 §7): 관측되지 않음.
- 카메라(EHCI bus1)·CM-740(UHCI bus3)·동글(UHCI bus2)이 서로 다른 호스트 컨트롤러 —
  **구조 논거**(동시 부하 실측은 카메라 스트리밍 비활성 상태). 카메라 MJPEG 활성
  동시 측정은 H1 검증 항목으로 이관.

## 5. 동글 전용 측정 ① 링크 단절 거동 (failsafe 설계 입력)

실측 시나리오(n=1): LB(데드맨) 홀드 유지 중 패드 전원 길게 눌러 OFF → 15s 대기 → 재전원.

```
[ +2.742] EV_KEY BTN_TL(LB) value=1          ← 데드맨 홀드 시작
[ +3.1 .. +17.7] POLL node=OK held=BTN_TL    ← EVIOCGKEY 0.5s 폴 — 홀드 추적
[+17.992] EV_KEY BTN_TL(LB) value=0          ← ★ release 합성 (커널 input core 의 unregister 시 keyup)
[+17.993] READ_ERROR [Errno 19] No such device ← ★ ~1ms 뒤 노드 소멸 (ENODEV)
```

재전원: Receiver Update 분리 → 일시 `error -71` 재시도 1회 → **USB 재enumerate 기점
~1.3s 에 X-Box 360 pad 재등록** (`input8`→`input9`, 노드 번호는 `event8` 재사용 — A.4).

**H1/H2 함의 (failsafe 티어 재해석)**:

1. **release 합성의 주체는 커널 input core** (device unregister 시 눌린 키 일괄
   keyup — 표준 동작, +17.992/+17.993 의 1ms 간격이 이 경로와 정합). 동글 고유 기능이
   아니므로 **동글 물리 뽑힘에도 동일하게 적용**된다(유선 분리와 동일 메커니즘).
2. **1티어(release)와 2티어(노드 소멸)는 공통원인(USB disconnect)의 파생 신호** —
   중복 방어가 아니다. 동글이 단절을 USB 분리로 전환하지 않는 모드(비정상 RF 단절에서
   미검증)에서는 둘 다 동시에 침묵한다.
3. **전원 OFF→release 의 지연 창은 미측정** — 사용자 길게-누름(~3s)과 겹쳐 분리 불가,
   **≲2s 로 추정**. 이 창 동안 노드는 살아 있고 이벤트만 침묵한다.
4. **EVIOCGKEY 폴은 패드 생존 판정이 아니다 (실측 반증)**: 단절 직전(+17.754)까지
   stale `held=BTN_TL` 을 계속 반환했다 — EVIOCGKEY 는 노드가 살아있는 한 커널 캐시
   상태를 돌려준다. **설계 H1-1 의 "EVIOCGKEY 1s 상태 폴 병행 = 패드 생존 판정"
   가정은 성립하지 않는다** (노드 생존 판정으로만 유효). 3티어(보수 추정 창)의
   트리거는 EVIOCGKEY 성공이 아니라 "마지막 *이벤트* 수신 경과"로 정의해야 하며,
   정적 데드맨 홀드(이벤트 무발생)와 단절을 구분할 수 없는 문제는 **주기적 강제
   신호가 없는 한 1.5s 창의 본질적 한계**로 남는다 → 설계 피드백.
5. **노드 경로/번호 불변 가정 금지**: input 번호는 증가(8→9), event 노드 번호
   재사용은 우연. H1 은 이름+VID/PID 재스캔으로 재획득 (설계 H1-1 1s 재스캔 유효).
   open fd 는 ENODEV 를 즉시 돌려주므로 읽기 스레드는 ENODEV → 재스캔 루프로 전이.
6. 재획득 후 ARM 재요구(H2-3)와 결합하면 "재전원 → 자동 재획득 → A 로 재 ARM"
   흐름이 성립한다.

## 5-2. 동글 전용 측정 ② 패드 절전 타임아웃

무입력 방치 실측(n=1): **약 10분에 자동 절전** (watcher 가동 구간만으로 ≥573s 확정,
watcher 시작 전 불확정 idle ≤2분 포함 시 **9.5~11.6분 구간**, A.5).

- dmesg: uptime 3328.0s `usb 2-2: USB disconnect` → 3328.4s **"Receiver Update"
  인격으로 재enumerate 실측** (A.5) — 절전도 USB 분리로 나타난다.
- **노드 소멸은 실측, release 합성은 추론**: 절전 시험은 무입력 방치라 눌린 버튼이
  없어 release 합성은 원리적으로 관측 불가. USB disconnect → input unregister 경로가
  전원 OFF 와 동일하므로 커널이 release 를 합성할 것으로 추론(§5-1 메커니즘).
- **데드맨 홀드 keep-alive 여부: 미측정** (사용자 결정으로 생략 — 12분 홀드 필요).
  운용상 완화: 조종 중엔 스틱 입력이 연속 발생해 절전 도달이 어렵고, 절전돼도
  graceful 단절 신호가 발생한다. 단 "LB 만 정적 홀드 + 스틱 무입력 10분" 시나리오가
  운용에 존재한다면 H1 전 측정 권장 (§8).
- H2 설계 §4-2 의 "절전이 1.5s 추정 창보다 짧으면 임계 재조정" 조건은 10분급이므로
  **해당 없음** 판정.

## 5-3. 동글 전용 측정 ③ 2.4GHz Wi-Fi 공존

로봇 wlan0(192.168.0.33) SSH 세션 + **48MB scp 전송 부하**(12MB×4)를 동시 인가한
상태에서 연속 스틱 입력 레이트 측정 → SYN 442.1/s (베이스라인 422.2/s, A.3),
READ gap 미발생. **1회 측정에서 저하 미관측(근거리)** — 인적 입력 변동이 차이보다
크므로 "간섭 없음 확정"이 아니라 "시연 거리 기준 문제 징후 없음" 판정.

## 6. 유선 USB-C 폴백 (1회 절차) — 불발, 미측정 종결

동글 제거 후 USB-C 케이블로 패드↔로봇 직결을 1회 시도:

- 커널: **USB 버스에 어떤 전기적 이벤트도 없음** (실패 enumerate 조차 미발생).
- 패드 스크린: "페어링 안 됨" + XInput 모드 표시 — 패드가 유선 연결을 데이터
  모드로 전환하지 않음.
- 원인 미분리 (충전 전용 케이블 vs 패드 유선-데이터 모드 설정). **사용자 결정:
  동글 경로가 명확히 동작하므로 유선 폴백은 추후로 미룸.**

**설계 함의**: Track A'(유선 폴백)는 현 시점 **가용하지 않다**. 동글 장애 시의
폴백은 당분간 Mac 콕핏/Switch 경로다. 유선을 살리려면 데이터 지원 케이블 확보 +
패드 유선 모드 확인이 선행돼야 한다 (H1 차단 요소는 아님 — 코드 경로는 동일 evdev).

## 7. H0 판정 매트릭스 결과 (설계 §4 대비)

| 분기 | 설계 예상 | 실측 |
|---|---|---|
| ① 동글이 D-input event 노드 생성 | 1순위 희망 | 아니오 — XInput 이었으나 **xpad 네이티브 ID 라 동급 결과** |
| ② XInput → xpad new_id 시도 | 폴백 | **불필요** (자동 바인딩) |
| ③ 유선 USB-C 동일 절차 | 폴백 확보 | 불발 — §6 |
| ④ 전부 실패 → Track C | 최후 | 도달 안 함 |

## 8. 잔여·후속

- [ ] **거리 이탈/배터리 탈락 단절 시험** (설계 §4 측정① 의 절반 — 미이행):
  패드를 들고 이탈하거나 차폐(금속 상자)로 비정상 RF 단절을 모사 — 동글이 이때도
  USB 분리를 일으키는지, 노드 유지 시간이 얼마인지. **H2 failsafe 3티어 임계의
  직접 입력**이므로 H1 실기 검증과 묶어 수행 권장.
- [ ] H1 브링업 시 **전 축 부호 + D패드 4방(−1 포함) + 스틱클릭(317/318)** 일괄 확인
  (방향 라벨링 포함 재실측 — 현 표는 조작 프로토콜 기반).
- [ ] 데드맨 홀드의 절전 keep-alive 여부 — 미측정 (12분 홀드 1회로 측정 가능).
  "정적 홀드 + 무입력 10분" 운용 시나리오가 실재하면 H1 전 측정.
- [ ] 카메라 MJPEG 스트리밍 활성 상태에서의 동시 레이트 측정 (H1 검증 항목 합류).
- [ ] 유선 USB-C 데이터 케이블 확보 후 §6 재시도 (낮은 우선순위).
- [ ] (운영) df-inbox watcher 가 미등록 상태 — 설계 §1.3 전제 복구는 별도 작업
  (마스터 셋업 재실행, `RobotSetupCommand.swift:1272` — 사용자 sudo 필요).
- [ ] 패드 충전 체크리스트(H2-4 운용 수칙)에 "절전 ~10분(9.5~11.6분, n=1)" 명시.
- [ ] (설계 피드백) H1-1 의 "EVIOCGKEY 폴 = 패드 생존 판정" 가정 정정 — §5 함의 4.

## 부록 A — 원시 출력 발췌 (세션 캡처)

### A.1 detect — enumerate·바인딩·모듈 (동글 삽입, 패드 ON)

```
=== lsusb diff (new devices) ===
> Bus 002 Device 004: ID 045e:028e Microsoft Corp. Xbox360 Controller

=== dmesg ===
[  841.624779] generic-usb 0003:1A34:F517.0001: hiddev0,hidraw0: USB HID v1.11
               Device [Receiver Update] on usb-0000:00:1d.0-2/input0   ← 패드 미링크 인격
[  841.624864] usbcore: registered new interface driver usbhid
[ 1303.099482] usb 2-2: new full-speed USB device number 4 using uhci_hcd
[ 1303.279233] usb 2-2: not running at top speed; connect to a high speed hub
[ 1303.370110] Registered led device: xpad0
[ 1303.370426] input: Microsoft X-Box 360 pad as /devices/pci0000:00/0000:00:1d.0/
               usb2/2-2/2-2:1.0/input/input8
[ 1303.370658] usbcore: registered new interface driver xpad

=== /dev/input diff ===           === USB interface class ===
> event8                          /sys/bus/usb/devices/2-2:1.0  class=ff sub=5d proto=01 driver=xpad
> js0

=== input modules (삽입 전 lsmod 에 없던 것) ===
joydev 17124 / xpad 17713 / ff_memless 12838 (by xpad) / usbhid 41556 / hid 81375

=== /proc/bus/input/devices (해당 블록) ===
I: Bus=0003 Vendor=045e Product=028e Version=0110
N: Name="Microsoft X-Box 360 pad"
H: Handlers=event8 js0
B: EV=20000b  B: KEY=7cdb0000 ...  B: ABS=3003f  B: FF=1 7030000
```

### A.2 caps event8 — EVIOCGID·EVIOCGABS·KEY 비트맵 전문

```
name    : Microsoft X-Box 360 pad
id      : bus=0x0003 vendor=0x045e product=0x028e version=0x0110
ev types: SYN KEY ABS FF
--- ABS axes (value/min/max/fuzz/flat/res) ---
ABS_X        code=0   value=0  min=-32768  max=32767  fuzz=16   flat=128  res=0
ABS_Y        code=1   value=0  min=-32768  max=32767  fuzz=16   flat=128  res=0
ABS_Z        code=2   value=0  min=0       max=255    fuzz=0    flat=0    res=0
ABS_RX       code=3   value=0  min=-32768  max=32767  fuzz=16   flat=128  res=0
ABS_RY       code=4   value=0  min=-32768  max=32767  fuzz=16   flat=128  res=0
ABS_RZ       code=5   value=0  min=0       max=255    fuzz=0    flat=0    res=0
ABS_HAT0X    code=16  value=0  min=-1      max=1      fuzz=0    flat=0    res=0
ABS_HAT0Y    code=17  value=0  min=-1      max=1      fuzz=0    flat=0    res=0
--- KEY codes (11) ---
304 305 307 308 310 311 314 315 316 317 318
```

### A.3 rate — 베이스라인 vs Wi-Fi 부하 / 부호 확인

```
# 베이스라인 (rate 12s, 연속 스틱 입력):
elapsed=12.00s total=14553 events  rate=1212.7 ev/s
  EV_SYN    5067  (422.2/s)
  EV_ABS    9486  (790.5/s)

# Wi-Fi 48MB scp 부하 중 (rate 15s):
elapsed=15.00s total=18537 events  rate=1235.8 ev/s
  EV_SYN    6632  (442.1/s)
  EV_ABS   11905  (793.6/s)

# 왼스틱 아래 2s 유지 (부하 시험 선두, watch):
[  +0.045] EV_ABS ABS_Y value=32576   ← 아래=+ 확인 (조작 프로토콜 기반)
```

### A.4 재전원 재enumerate (전원 OFF → 재전원)

```
[ 2460.033352] usb 2-2: USB disconnect, device number 5      ← Receiver Update 분리
[ 2460.240927] usb 2-2: new full-speed USB device number 6 using uhci_hcd
[ 2460.753112] usb 2-2: device not accepting address 6, error -71
[ 2460.804177] hub 2-0:1.0: unable to enumerate USB device on port 2
[ 2461.215437] usb 2-2: new full-speed USB device number 8 using uhci_hcd
[ 2461.368031] Registered led device: xpad1
[ 2461.368613] input: Microsoft X-Box 360 pad as .../input/input9   ← event8 재사용, js0 재생성
```

### A.5 절전 — watcher + dmesg

```
# watcher (5s 폴, /dev/input/event8 존재 감시):
watch_start_uptime=2755
NODE_GONE uptime=3336 elapsed=581s        ← 폴 granularity 5s

# dmesg (정밀 시각):
[ 3328.014004] usb 2-2: USB disconnect, device number 8       ← 절전 = USB 분리
[ 3328.236509] usb 2-2: new full-speed USB device number 9 using uhci_hcd
[ 3328.392067] generic-usb 0003:1A34:F517.0004: hiddev0,hidraw0: ... [Receiver Update]
                                                               ← 미링크 인격 복귀 실측
```

### A.6 시험 종료 — 동글 재장착 최종 확인

```
[ 4049.818736] usb 2-2: new full-speed USB device number 13 using uhci_hcd
[ 4049.972208] Registered led device: xpad3
[ 4049.972768] input: Microsoft X-Box 360 pad as .../input/input11   ← event8+js0 재생성
```
