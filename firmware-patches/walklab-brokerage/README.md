# WalkLab Brokerage — robot-side C++ patch

**Target**: ROBOTIS-OP2 `demo-pilot` binary (DarwinForge patched fork)
**Companion**: Mac DarwinForge v1.11.5+ — `WalkingEngine.robotisOnboard` 모드

> **2026-06-08 추가** — **후면 패널 버튼으로 WalkLab 모드 진입 가능**.
> DarwinForge/Switch 연결 없이 로봇만으로:
>   1. 부팅 후 `rc.local` 이 데모 자동 실행 (READY 상태)
>   2. 후면 **MODE** 버튼 6회 누름 → LED `0x07`(R+G+B 모두 ON) 점등 = `WALKLAB` 모드
>   3. 후면 **START** 버튼 → walk-ready 자세 + gyro calibration → WalkLab 진입
>   4. 후면 **MODE** 버튼 다시 누름 → `walking->Stop()` 정중한 정지 + READY 복귀
>
> 자동기동(`/tmp/df-pilot-mode == "walklab"`) 경로는 **유지** — DarwinForge 원클릭
> 트리거도 그대로 작동. 부팅 자동 연결 세팅(`/etc/rc.local`,
> `/etc/network/interfaces`, sshd) 은 일체 건드리지 않음.

## 동기

DarwinForge WalkLab 의 Mac sparse keyframe 보행 (~10Hz 등가) 은 architecture 한계로
실 robot 안정 보행 불가. Ball tracker 는 robot-side `Walking::GetInstance()` 의 8ms /
125Hz 루프 사용해 안정. WalkLab 도 **동일 robot-side 엔진을 사용**하되 Mac UI 의 명령
(stride / period / hipPitch / turn) 을 받아 적용하는 brokerage 모드 추가.

## 동작 흐름

```
[Mac DarwinForge]              [robot demo-pilot]
       │                              │
       ├── SSH ──► echo "walklab"     │
       │           > /tmp/df-pilot-   │
       │             mode             │
       │                              ├── main() startup
       │                              ├── read /tmp/df-pilot-mode
       │                              ├── if "walklab" → WalkLabBrokerageMode
       │                              │   (this patch 추가)
       │                              │
       ├── SSH ──► printf "..." \     │
       │           > /tmp/df-walklab- │
       │             cmd              │
       │                              ├── 5Hz polling loop:
       │                              │   ├── read /tmp/df-walklab-cmd
       │                              │   ├── sscanf 7필드
       │                              │   ├── Walking::GetInstance()->
       │                              │   │   X_MOVE_AMPLITUDE = x_mm
       │                              │   │   Y_MOVE_AMPLITUDE = y_mm
       │                              │   │   A_MOVE_AMPLITUDE = a_deg
       │                              │   │   PERIOD_TIME = period_ms
       │                              │   │   Z_MOVE_AMPLITUDE = foot_mm
       │                              │   │   HIP_PITCH_OFFSET = hip_pitch_deg
       │                              │   └── if enabled → Start() else Stop()
       │                              │
       └── SSH ──► killall demo-pilot │
                   rm /tmp/df-pilot-  │
                     mode             │
```

## 명령 line format (Mac → robot)

```
enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg
```

예: `1 28.00 0.00 0.00 600 40 13.00`

- **enabled** (int, 0 / 1): walking 활성/비활성. 0 → `Walking::Stop()`.
- **x_mm** (float): 전후 stride (mm/cycle). `X_MOVE_AMPLITUDE`.
- **y_mm** (float): 좌우 side step. `Y_MOVE_AMPLITUDE`.
- **a_deg** (float): yaw 회전 (°/cycle). `A_MOVE_AMPLITUDE`.
- **period_ms** (float, but int-like): 한 cycle 주기. `PERIOD_TIME`.
- **foot_mm** (float): 발 들기 높이. `Z_MOVE_AMPLITUDE`.
- **hip_pitch_deg** (float): hip pitch trim. `HIP_PITCH_OFFSET`. ROBOTIS 원본 13.0.

## Patch 적용 절차

```bash
# robot 측 SSH 접속 후
cd ~/Framework/Linux/project/demo
patch -p1 < walklab-brokerage.patch
# 볼 트래킹 config 설치 — WalkLabBrokerage 가 런타임에 절대경로로 읽음.
# 없으면 ColorFinder 기본값(공 색 불일치) + 카메라 미설정 → 볼 트래킹 실패.
# 이미 튜닝본이 있으면 보존(덮어쓰지 말 것).
cp balltrack.ini /robotis/Linux/project/demo/balltrack.ini   # = BALLCOLOR_INI
make clean && make
# /tmp 권한 확인 — sudo 없이 write 가능해야 함
ls -la /tmp/df-pilot-mode 2>/dev/null || true
```

> **권장**: 위 수동 patch 대신 `install-onboard.sh` 를 쓰면 main.cpp/Makefile patch +
> `balltrack.ini` 설치(튜닝본 보존)를 멱등하게 처리한다. 자세한 절차는 `INTEGRATION.md`.

## 검증

```bash
# robot 측에서
echo "walklab" > /tmp/df-pilot-mode
echo "1 20.00 0.00 0.00 700 35 13.00" > /tmp/df-walklab-cmd
sudo ./demo-pilot &
# → 로봇이 stride 20mm / period 700ms 로 보행 시작

# 정지
echo "0 0 0 0 0 0 13" > /tmp/df-walklab-cmd
# 또는
sudo killall demo-pilot
```

## 현황 — Wave O0·O1·O2 (walklab-onboard-teleop-upgrade) + H1·H2 (handheld-direct-pilot)

| Wave | 내용 | 상태 |
|---|---|---|
| O0 | 클럭 오프셋·TEL last_cmd_id/loop_ms·벤치 절차 | 구현 완료 (74fca94) |
| O1 | 이벤트 구동 UDP 전송·latest-wins 슬롯·워치독 티어 | 구현 완료 (ad287e4) |
| **O2** | **프로토콜 v2(twist SI)·결합 엔벨로프 거버너·래치 슬루·밸런스 결선·게이트 스케줄** | **구현 완료 (호스트 테스트 통과) — 실기 벤치 대기** |
| **H1+H2** | **RG G01 동글 직결 GamepadPilot + 소스 중재·3티어 failsafe** | **실기 브링업 완료 (2026-06-13 입회, 호스트 163 checks)** — 잔여 게이트 `docs/reports/2026-06-13-rgg01-bringup.md` §5 |

**실기 F9~F11 (2026-06-13 브링업 — 아래 H1 요약 중 데드맨/우스틱/트리거 매핑은 F10 으로 대체됨)**:
- **F9 — estop 복구 관절 재enable (P1 결함 수정)**: 복구 후 ACK 정상·물리 무반응 —
  `Walking::Start()` 는 joint enable 을 복구하지 않는다(MotionManager 는 enable==true 만
  서보 기록). 재무장 분기에서 getup 반납 패턴으로 직접 재enable + stale cmd 가드(한 쌍).
  동반: B E-STOP 스테일 면역(value==1 무조건 발화 — release 유실 영구 침묵 차단),
  SYN_DROPPED 디코더 리셋, stdout 라인버퍼링·unlink 결과 로그(관측성).
- **F10/F10b — 매핑 리디자인 (사용자 피드백, 콕핏 패리티 의도적 이탈)**: 데드맨(LB)
  해제(`GP_DEADMAN_REQUIRED=false` — 이동 게이트는 ARM 단일, 단절 보호는 ②/③티어) ·
  우스틱 = 헤드 레이트 제어(곡선 1.7 · 팬 150°/s·틸트 85°/s · dt 적분+±70/±35 클램프 ·
  놓으면 유지) · LT/RT = 좌/우회전 아날로그(데드존 0.02 · 저압 부스트 ^0.65) ·
  Y 복구 소프트 토크 램프(`SoftTorqueRearm` — Torque Limit 300→1023, ~0.6s, 스냅 제거).
- **F11 — 레이턴시**: 패드 입력 신선(≤1s) 시 유휴 supervisor 루프 100→20ms(첫 입력 소비
  평균 50→10ms), estop hold 폴 100→20ms(복구 감지 평균 50→10ms). 패드 유휴 시 100ms 유지.

**H1+H2 요약** (`GamepadPilot.{h,cpp}` 신설 — H0 실측 `docs/reports/2026-06-12-rgg01-usb-probe.md` 기반):
- **획득**: `/dev/input/event*` 스캔 → EVIOCGNAME(`Microsoft X-Box 360 pad`)+EVIOCGID
  (045e:028e) 매칭, 미발견/소실 시 1s 재스캔(핫플러그 겸용). 노드 번호 불변 가정 금지.
- **읽기**: select(50ms)+read 16B 단위, EV_ABS/KEY 누적 → EV_SYN 커밋(축 일관성).
  정적 홀드(이벤트 0) 중엔 50ms 재공급으로 스트림 워치독(600/2500ms) 정합.
- **매핑**(콕핏 RG G01 프리셋 1:1): LS=이동/횡, RS X=턴·Y=머리틸트, LT/RT=머리팬
  (RT−LT 차분 비례 — 트리거는 순수 아날로그), B=E-STOP, Y=복구(estop flag 해제),
  X=볼트랙, LB=데드맨(이동/턴만 게이트), RB=터보(×1.3), A=ARM. 데드존 0.10·곡선
  1.35·intensity^0.7→period 700–560/foot 18–40 스케줄.
- **적용 경로**: 자체 latest-wins 슬롯 → supervisor 가 v1 14토큰 라인으로 소비
  (`ApplyCommandLine` 단일 지점 — 거버너가 최종 클램프). **E-STOP 만 예외**: 읽기
  스레드에서 즉시 `TriggerEstopImmediate()`(Walking::Stop+토크OFF+flag, UDP estop
  와 공유 헬퍼).
- **중재(H2)**: E-STOP(전 소스 상시) > local(최근 입력 ≤1s) > 네트워크(UDP/파일).
  local 신선 창에는 네트워크 walk 명령 폐기(estop·복구는 별도 경로 — 상시 유효).
  TEL2 `active_source` = local/udp/file.
- **failsafe 3티어**: ① release 합성→데드맨 해제(즉시 enabled=0) ② ENODEV/노드
  소멸→disarm+제자리 슬루+재스캔(재획득 후 재 ARM 필수) ③ 이벤트 침묵 ≥1.5s(초기값)
  →제자리 슬루(disarm 아님 — 오발 비용=완만한 정지). EVIOCGKEY 생존 폴은 H0 실측
  반증으로 폐기. 빌드 게이트 `-DDF_NO_GAMEPAD_PILOT`(기본 ON — 패드 미연결 시 무동작).

**O2 요약** (상세 계약 `docs/ssh-parity-contract.md` §G.8):
- 명령 두 방언 — v1(14토큰, 영구) + **v2 twist**(`V2 seq t_tx flags vx_mms vy_mms wz_mrad_s
  period foot hip_cdeg blevel pan_cdeg tilt_cdeg`, REP-103 SI 정수). 로봇이 변환 소유
  (`X≈k_x·vx·T/2`, `k_x` 초기 1.0 — **벤치로 확정 TODO**).
- **셰이핑은 로봇이 소유**(단일 적용 지점 `ApplyCommandLine`, v1/v2·전 클라이언트 공통):
  ① 결합 엔벨로프 거버너(`|x|/x_max+|y|/y_max+|a|/a_max≤1.15`, period 종속 x_max
  700→40/600→38/500→32/440→28mm) — **로봇이 최종 클램프 소유**(Switch 무클램프 포함),
  ② 래치 단위 슬루(|ΔX|≤8·|ΔY|≤6mm·|ΔA|≤4°·|ΔT|≤60ms), ③ 속도 비례 게이트 스케줄
  (|x|/x_max>0.7 시 Z_MOVE+5·Y_SWAP+2mm·HIP+1.5° 가산, flags 0x08=OFF).
- **밸런스 결선**: `blevel(0..3)→게인 ×{0,.5,1,1.5}`. `BALANCE_ENABLE`은 **blevel 단일
  소스**(배율>0)로 구동 — `benable` 직결 시 배포 Mac 기본값(0)이 매 명령마다 자이로 밸런스를
  꺼 낙상 회귀가 되므로 의도적 비채택. `bgain`/`benable` deprecated.
- 모든 거버너/슬루/게이트/twist-k 상수는 `WalkLabTransport.h` 단일 정의 —
  `bus-direct-teleop-upgrade.md` D1 과 공유. 순수 로직 호스트 테스트
  `tests/test_transport.cpp` **125 checks** (O1 63 → O2 125), Mac serializer 왕복은
  `WalkLabO2TwistSerializerTests`.

## 안전 고려

- **명령 파일 권한**: `/tmp/df-walklab-cmd` 가 0666 (Mac SSH user write 가능)
- **sscanf 실패 시**: 이전 명령 유지 (silent ignore — 잘못된 line 으로 robot 폭주 방지)
- **명령 stale**: Mac 측에서 5초 이상 명령 갱신 없으면 자동 stop (이 patch 가 timestamp 추적;
  O1 워치독 티어가 600ms 제자리/2.5s 정지로 선행, 5s 는 최후 방어)
- **hip_pitch_deg clamp**: robot 측에서 `[0, 20]` 범위로 clamp 적용
- **최종 클램프는 로봇 소유**(O2 거버너): 임의 클라이언트(모바일/Switch/핸드헬드)의 위험
  명령도 결합 엔벨로프·슬루로 로봇이 직접 제한 — Mac 클램프는 UX 레이어(이중 방어)
- **서보 알람 셧다운 자동 복원 (실기 F8, 2026-06-12)**: MX-28 과부하/과열 셧다운은
  Torque Limit(addr 34)을 0 으로 강제(빨간 LED·무토크) — 전원 재투입 또는 재기록 전까지
  getup/estop 해제로도 복구 불가(실기: 보행 벤치 후 양 발목 피치 ID15/16, err=0x20).
  `SweepServoShutdown`이 **walklab 기동 시·복구(estop 해제 재무장) 시** 전 서보(1..20)의
  Torque Limit/온도를 스윕해, 래치(tl==0)이고 온도 ≤65°C 면 1023 복원 + 재확인 로그.
  과열/온도 미상이면 보류(냉각 후 복구 재시도). 쓰기는 Torque Limit 한정 — 토크 enable
  불변(자세 점프 없음). 판정 `ServoGuardDecide`는 순수 함수(호스트 테스트 17 checks).

## TODO (robot-side 실 적용 전 검증 필요)

- [ ] DARwIn-OP_ROBOTIS_v1.6.0 / Framework Walking.cpp 의 X/Y/A_MOVE_AMPLITUDE 실시간 변경 가능 여부 (period 중간 변경 시 cycle 불안정 가능)
- [ ] PERIOD_TIME 변경 시 walking phase 리셋 필요한가?
- [ ] HIP_PITCH_OFFSET 변경 시 즉시 적용 vs 다음 cycle?
- [ ] /tmp/df-walklab-cmd 동시 접근 (race condition) — flock 또는 atomic rename
- [ ] robot 측 user 권한 + sudo 필요 여부
