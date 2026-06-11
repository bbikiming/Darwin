# WalkLab 온보드 텔레옵 — 로봇 측 코드·알고리즘 업그레이드 설계 (Onboard Teleop Upgrade)

> 2026-06-11 · 로봇 온보드 코드(브로커리지 835줄 + ROBOTIS Walking 624줄) 전수 독해 +
> Mac 송수신 경로 추적 + 펌웨어 백업 소스 교차 검증 결과.
> 본 문서는 **로봇에서 돌아가는 코드와 명령/텔레메트리 계약**의 업그레이드를 다룬다.
> Mac 측 전송 계층(SSH 채널·RunLoop·bus)은 `docs/design/cockpit-latency-hardening.md` 가
> 관장하며, 양 문서의 분담·합류 지점은 §7 에 명시한다. 모든 사실 진술에 파일:줄 앵커를 단다.

## 0. 결론 요약

조종 시뮬에서 로봇을 연결하면 로봇에서는 **패치된 demo-pilot 프로세스 안의
`WalkLabBrokerage` 루프(100ms 파일 폴링)** 가 돌고, 실제 보행은 ROBOTIS Framework 의
**`Walking` 모듈(8ms/125Hz, 사인 합성 ZMP 게이트 + 해석적 IK + 자이로 P 밸런스)** 이 생성한다.
브로커리지는 게이트를 계산하지 않고 Walking 의 공개 파라미터(X/Y/A 진폭, 주기 등)만 바꾼다.

"빠릿하지 않음"의 원인은 알고리즘이 아니라 **명령이 게이트에 도달하기까지의 단계별 대기 합**이다:

1. **전송**: Mac 이 명령 1건마다 SSH subprocess + 인라인 ACK 폴(≤1.5s 점유) → 실효 4–8Hz
   (cockpit-latency-hardening L1/L2). 로봇은 100ms 파일 폴링으로 수신.
2. **이중 스무딩**: Mac 의 EMA(α=0.25@30Hz)와 로봇의 위상 경계 래칭이 직렬로 겹침.
3. **위상 래칭**: Walking 은 X/Y/A 진폭을 **PHASE1/PHASE3(스윙 중간) 경계에서만** 채택
   (`Walking.cpp:389-416`) — 기본 주기 600ms 에서 명령→게이트 반영이 평균 +150ms, 최악 +300ms.
4. **죽은 제어 채널**: 명령의 balance 토큰(bgain/benable/blevel)은 로봇이 **파싱만 하고
   버린다**(`WalkLabBrokerage.cpp:612-613` 주석 "현재 미적용") — Mac UI 의 밸런스 조절이 무효.
5. **피드백 부재**: 밸런스는 자이로 raw P 제어뿐(`Walking.cpp:571-600`). FSR 은 8ms 벌크리드에
   **이미 들어오는데**(`CM730.cpp:417-429`) 게이트에도 텔레메트리에도 안 쓴다. 텔레메트리(10필드,
   5–10Hz)에는 위상·실제 래치값·FSR 이 없어 Mac 이 로봇 상태를 "추정"만 한다.

업그레이드는 5개 웨이브: **O0 계측 → O1 이벤트 구동 전송+워치독 → O2 명령 의미론 v2+거버너 →
O3 밸런스 피드백(FSR/IMU) → O4 텔레메트리 v2**. O1 까지만으로 명령 실효율 4–8Hz → 20–30Hz,
E-STOP 로봇 측 바닥 100ms → ~5ms 가 된다. O2·O3 이 "역동적이고 안정적인" 부분을 담당한다.

## 1. 현재 아키텍처 — 검증된 사실

### 1.1 실행 주체 (로봇, OP2 온보드 PC: Atom N2600 · Ubuntu EOL)

연결 시퀀스(Mac → 로봇): `walkLabRobotisStart`(`Connection/RobotSetupCommand.swift:325-510`)가
forge-bridge(socat) 종료 → `/tmp/df-pilot-mode = "walklab"` 기록 → 패치된 `demo-pilot` 를
nohup 기동. demo-pilot 의 main.cpp 주입 블록(같은 파일 772-906행이 소스 문자열 보유)이
모드 파일을 읽고: LED/MP3 → `MotionManager::Reinitialize` → walk-ready(Action page 9) →
**자이로 캘리브레이션(정지 필요, ≤3s)** → `Walking::Initialize` → `WalkLabBrokerage().Run(&cm730)`
무한 루프 진입.

두 개의 제어 평면이 동시에 돈다:

| 평면 | 주기 | 책임 | 앵커 |
|---|---|---|---|
| `LinuxMotionTimer` RT 스레드 | **8ms (125Hz)**, SCHED_RR | CM730 BULK_READ(서보+IMU+FSR) → `Walking::Process()` → SYNC_WRITE | `MotionModule::TIME_UNIT`, `firmware-backups/.../LinuxMotionTimer.cpp` |
| `WalkLabBrokerage::Run()` 메인 스레드 | **100ms** (`POLL_INTERVAL_MS`, 볼트래킹 시 카메라 30fps 페이스) | 명령 파일 폴 → Walking 파라미터 쓰기, E-STOP 플래그 폴, 낙상 자동복구, 텔레메트리 송신 | `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp:414-590` |

### 1.2 Walking 게이트 알고리즘 (`firmware-backups/.../Framework/src/motion/modules/Walking.cpp`)

- **궤적**: 모든 끝점이 단일 함수 `wsin(t, T, φ, A, A0)`(149-152행)의 합 — 폐형식 사인 ZMP.
  본체 sway(x/y/z_swap) + 발 stepping(x/y/z_move)을 합성해 발 6축 끝점 생성.
- **위상**: 4-phase 상태기 — PHASE0(DSP) → PHASE1(좌발 스윙 중간) → PHASE2(DSP) → PHASE3(우발
  스윙 중간). 파라미터 래칭(371-417행):
  - `update_param_time()`(주기·DSP비·오프셋): PHASE0/PHASE2 — 반주기마다
  - `update_param_move()`(X/Y/A 진폭): **PHASE1/PHASE3 — 반주기마다** (391·415행)
  - `update_param_balance()`(게인): **매 8ms tick**(418행)
  - 정지는 DSP 에서 진폭이 0일 때만 `m_Real_Running=false`(377-387행) — 안전한 설계, 유지 대상.
- **IK**: 해석적 6-DOF 다리 IK (cos 법칙 무릎 + atan2 체인), 링크 thigh/calf 0.093m + ankle 0.0335m.
- **밸런스**: `BALANCE_ENABLE` 시 자이로 raw 를 P 게인으로 hip-roll/knee/ankle-pitch/ankle-roll
  목표에 가산(571-600행). **MX-28 4096 빌드(#else 분기)는 게인 ×4**(588-598행) —
  LPF·적분·가속도 융합·FSR 없음. 출하 게인: knee 0.3 / ankle-pitch 0.9 / hip-roll 0.5 /
  ankle-roll 1.0, 주기 600ms, Z_MOVE 40mm, DSP 0.1 (생성자 23-78행).
- **팔 스윙**: X 진폭 비례 역위상(526-535행). **FSR**: `CM730::MakeBulkReadPacket` 이 FSR L/R 을
  PING 성공 시 벌크리드에 포함(`CM730.cpp:417-429`) — 즉 8ms 마다 수신 중이나 소비자 없음
  (MotionManager 는 디버그 로그에만 사용, `MotionManager.cpp:331-334`).

### 1.3 명령 경로 (콕핏 → 게이트)

```
[Mac]  CockpitState 30Hz integrate (EMA α=0.25)                CockpitState.swift:113·197
       └ clamp: stride ≤38mm·side ≤22mm·turn ≤12°             VirtualJoystickMapper.swift:70-75
       └ throttle→periodMs 440–700                             CockpitState.swift:507-521 (J3 정합 완료)
  → pilotApplyFreeform(stride,side,turn,period; foot 35, bgain 1.0, hip 13)
                                                               WalkLabSession+Pilot.swift:173-183
  → published tuning → WalkLabOnboardBridge.streamLoop 45ms(~22Hz 시도)
       + 150ms 디바운스 경로 + dedup(lastAckedLine)            WalkLabOnboardBridge.swift:96-181
  → OnboardSendQueue(actor, 1-in-flight, 코얼레싱 없음)        WalkLabOnboardBridge.swift:392
  → SSH 1회 = 신규 subprocess: rm ack; printf > cmd.tmp && mv; 30×(sleep 0.05; grep cmd_id ack)
                                                               RobotSetupCommand.swift:562-589
[로봇] Run() 이 stat() mtime(ns)+size 로 변경 감지(≤100ms)      WalkLabBrokerage.cpp:531-545
  → ParseAndApply: sscanf 14-token → 클램프(hip 0..20, head ±90/±45..65)
    → Walking::X/Y/A_MOVE_AMPLITUDE·PERIOD_TIME·Z_MOVE·HIP_PITCH_OFFSET 직접 대입
    → balance 3토큰은 소비만(612-613행, 미적용) → ACK 파일 "OK ts cmd_id line"
[게이트] PHASE1/PHASE3 경계에서 update_param_move 래치(≤반주기 대기) → 8ms tick 이 서보 구동
```

명령 라인(14토큰): `{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable}
{blevel} {headPan} {headTilt} {balltrack}` — 위치 기반, 버전 필드 없음, 단위 혼합(mm/deg/ms).

### 1.4 텔레메트리·안전 경로 (로봇 → Mac / 보호 동작)

- **텔레메트리**: `WriteTelemetry`(`WalkLabBrokerage.cpp:732-785`) — CM730 벌크리드 버퍼에서
  자이로3+가속3+전압 읽음(추가 버스 트래픽 0). `TEL {ts_ms} {gx gy gz ax ay az} {vdV}
  {walking01} {fallen}` 10필드. UDP push 매 루프(~10Hz, `/tmp/df-walklab-uplink` 의 타깃으로,
  lossy 무음) + 파일 200ms(5Hz, atomic rename). Mac 은 UDP 수신(`OnboardTelemetryUDPReceiver`)
  + SSH cat 5Hz 폴 병행(`OnboardTelemetryPoller.swift:55`, ts 전진 시만 fresh 판정).
  **없는 것: 위상, 실제 래치된 진폭, FSR/CoP, 적용된 cmd seq, 관절 상태.**
- **E-STOP**: 파일 플래그 존재 검사(`access()`, 138-139행)를 루프마다 — 로봇 측 바닥 ≤100ms
  (getup 중에는 8ms 단위로 검사, 202-231행 — 잘 돼 있음). latch/re-arm 구조(491-505행).
  Mac→로봇 전달은 SSH 의존(S5: WiFi stall 시 4–9s — 레이턴시 문서 관장).
- **워치독**: 명령 5s 무갱신 → `Walking::Stop()`(STALE_TIMEOUT_MS=5000). **텔레옵 기준 과도하게
  김** — 스틱을 놓아도(스트림이 멈추면) 5초간 마지막 명령으로 계속 걷는 시나리오는 Mac 쪽
  zero-주입 failsafe(S2)에만 의존.
- **낙상**: `MotionStatus::FALLEN` 600ms 지속 → getup 모션(page 10/11) 자동 재생(155-242행).
- **종료**: SIGTERM/SIGINT → `Walking::Stop()` + 전신 토크 OFF + `_exit(0)`(109-128행).
  MODE 버튼 → 루프 정상 탈출.

## 2. E2E 레이턴시 분해 (입력 → 게이트 반영, 온보드 모드)

| 구간 | 전형 | 최악 | 근거 |
|---|---|---|---|
| 입력 샘플링(30Hz) + EMA 수렴 | 33 + ~100ms | 33 + ~300ms | α=0.25, 레이턴시 문서 "0.3s ramp" |
| streamLoop 대기 | 22ms | 45ms | 45ms 주기 |
| OnboardSendQueue 직렬화(1-in-flight) | ~125–250ms | **~1.5s** | 직전 명령의 ACK 그렙 폴이 점유, 실효 4–8Hz |
| SSH subprocess + 네트워크 | 50–120ms | 수 s(무선 stall) | L1 |
| 로봇 파일 폴 | 50ms | 100ms | POLL_INTERVAL_MS |
| **위상 래칭(update_param_move)** | **150ms** | **300ms** | 반주기@600ms; period 440 이면 110/220ms |
| 게이트가 한 걸음으로 표현 | ~300ms | 600ms | 한 스텝 = 반주기 |
| **합계(걸음 변화 체감)** | **~0.7–1.0s** | **>2.5s** | |

E-STOP(온보드): Mac SSH 전달(가변, WiFi stall 4–9s 가능) + 로봇 폴 ≤100ms.
**개선 지렛대 순서 = 큐/전송(Mac, 레이턴시 문서 Wave 1) ≈ 로봇 수신(폴→이벤트) > 스무딩 일원화 >
래칭(구조적, 주기 단축과 예측 표시로 완화)** — 래칭 자체는 보행 안정성 장치이므로 제거하지 않는다.

## 3. 갭 분석 — 로봇공학·ROS 방법론 대조

ROS 를 로봇에 설치하자는 것이 아니다(Ubuntu 12/14 EOL + Atom N2600 + 구형 toolchain —
`unifiedSetup` 의 EOL 저장소 보정이 증거, `RobotSetupCommand.swift:16-80`). **방법론(계약·QoS·
계층화·진단)만 차용**한다.

| # | 영역 | 현재 | ROS/로봇공학 관행 | 영향 |
|---|---|---|---|---|
| G1 | 명령 전송 | 파일 폴링 IPC(100ms) + SSH exec/건 | 토픽 push(event-driven), QoS KEEP_LAST(1) | 수신 지연 ≤100ms + 실효 4–8Hz |
| G2 | 명령 의미론 | 14토큰 위치 기반, 버전 없음, mm/deg 혼합 | `geometry_msgs/Twist`(REP-103 SI) + 버전 계약 | 확장마다 양끝 동시 배포 강제(§C 사례), 단위 실수 위험 |
| G3 | 워치독 | 로봇 5s stale stop | `cmd_vel` timeout 0.2–0.5s + 단계적 감속 | 통신 두절 시 최대 5s 유령 보행(Mac failsafe 단일 방어) |
| G4 | E-STOP | 파일 플래그 100ms 폴 | 전용 채널·인터럽트성(서명된 datagram), 다중화 | 로봇 측 바닥 100ms + SSH 의존 |
| G5 | 스무딩 배치 | Mac EMA + 로봇 래치 직렬(이중) | 셰이핑은 한 곳: 로봇 측 slew/가속 제한(jerk-limit) | 반응 둔화 + Mac/로봇 상태 불일치 |
| G6 | 명령 한계 | Mac 클램프(38/22/12) + 로봇 hip 만 클램프 | 로봇이 최종 governor(결합 엔벨로프·가속 제한) 소유 | 임의 클라이언트(모바일/Switch)가 위험 명령 가능 |
| G7 | 밸런스 | 자이로 raw P 만, bgain/blevel **사문화** | 센서 융합(보완필터), CoP/ZMP 피드백, 게인 스케줄링 | 외란·고속에서 여유 없음, UI 밸런스 조절 무효 |
| G8 | 상태 추정 노출 | TEL 10필드(원시 ADC), 위상/래치값/FSR 없음 | joint_states/imu/diagnostics 토픽, 주기 ≥20Hz | Mac 은 로봇 상태를 추정으로 표시(디지털 트윈 불완전) |
| G9 | 수명주기 | progress 문자열 ad-hoc("walklab-active" 등) | lifecycle node 상태기(명시적 상태·전이·실패 보고) | 부분 실패(캘리브 실패 등) 진단 난해 |
| G10 | 시간/계측 | cmd_id ↔ "OK ts" 만, 클럭 오프셋 미사용 | 시간 동기 가정 명시 + 구간 계측(tracing) | E2E SLO 검증 불가(레이턴시 문서 §6 은 Mac 구간만) |

## 4. 업그레이드 로드맵 — 5 Wave

공통 원칙: ① 기존 파일 기반 경로는 **항상 폴백으로 보존**(이중 스택 공존), ② 프로토콜에 버전
토큰 도입 후 구버전 무중단, ③ E-STOP 경로에 스로틀·배칭 금지(레이턴시 문서 §7 승계),
④ 로봇 코드는 demo-pilot 패치 빌드 인프라(`demoBuildPatched`, `RobotSetupCommand.swift:932-1034`)
재사용 — 로봇에서 컴파일되므로 C++03/POSIX 범위 유지.

### Wave O0 — 계측과 재현 기반 (S) — 모든 후속 효과 측정의 전제

1. **클럭 오프셋 추정**: ACK 의 로봇 `ts_ms` 는 이미 존재(`OK {ts} {cmd_id}`). Mac 이
   `offset ≈ ts_robot − (t_tx+t_rx)/2` 를 EWMA 로 유지 — 신규 `Connection/RobotClockSync.swift`
   (~80줄). PilotLatencyTracer(레이턴시 문서 §6)의 `ackReceived` 마크에 robot-적용시각 보강.
2. **TEL v1.5(하위호환 토큰 추가)**: 브로커리지 `WriteTelemetry` 에 `{last_cmd_id} {loop_ms}`
   2토큰 append — Mac 파서(`OnboardTelemetry.swift:50-96`)는 "정확히 11토큰" 검증을 "≥11" 로
   완화(1줄). 명령 적용 시각이 텔레메트리로 폐루프 확인됨.
3. **벤치 절차 문서화**(§5): 스텝 응답(스틱 계단 입력 → 래치 확인까지), E-STOP worst-case,
   명령 실효율(ACK/s) — 전후 비교의 기준선 확보.

검증: TEL 토큰 추가 후 구버전 Mac(파서 완화 전)과의 비호환이 없는지 — 완화 커밋을 먼저 배포.
난이도 S / 리스크 낮음.

### Wave O1 — 이벤트 구동 전송 + 워치독 티어링 (L) — "빠릿"의 본체

**브로커리지 v2 스레딩 모델** (ros2_control 의 계층화 차용: transport / supervisor / 125Hz 엔진):

```
[transport 스레드들 — 이벤트 구동, 폴링 0]
  ① stdin 리더: persistent SSH 채널(레이턴시 문서 Wave 1 의 로봇 측 짝) — 줄 단위 명령
  ② UDP 명령 리스너: blocking recvfrom (포트 17374, 토큰 인증) — latest-wins 슬롯에 저장
  ③ UDP E-STOP 리스너: blocking recvfrom (포트 17372, "DF-ESTOP v1 {token}")
     → 수신 즉시 Walking::Stop() + SetEnableBody(false) — 로봇 측 지연 ~1–5ms
[supervisor 루프 — 기존 Run() 개편, walking_active 시 20ms / idle 100ms]
  최신 명령 슬롯 적용 → 워치독 → 낙상복구 → 텔레메트리 → (볼트래킹은 카메라 페이스 유지)
[125Hz Walking — 무변경]
```

- (a) 변경: `firmware-patches/walklab-brokerage/WalkLabBrokerage.{h,cpp}` 대규모 개편
  (+`pthread`), Mac 측은 레이턴시 문서 Wave 1 `OnboardCommandChannel` 에 UDP transport 추가
  (`Connection/`), `walkLabWriteUplink` 패턴으로 명령 채널 핸드셰이크(토큰·포트 프로비저닝).
- (b) 설계 수치:
  - **latest-wins 슬롯**: mutex 보호 1칸(=DDS KEEP_LAST depth 1). seq 단조 검사 — 역행 datagram
    폐기. E-STOP·모드 전환은 슬롯 우회 즉시 처리(=RELIABLE 의미, ×3 연발은 Mac 쪽 발사).
  - **ACK**: 수신 스레드가 즉시 UDP `ACK {seq} {t_rx}` 회신 + 파일 ACK 병행(SSH 폴백용). Mac 의
    30×50ms 인라인 그렙 폴(`RobotSetupCommand.swift:587`) 은 UDP 경로에서 소멸 — 실효율
    제한이 풀려 streamLoop 45ms(~22Hz)가 그대로 실효율이 된다. 30Hz 로 상향 여지.
  - **워치독 티어링**(G3): 마지막 유효 명령 후 **600ms → 진폭을 0 으로 슬루(제자리 걸음)**,
    **2.5s → `Walking::Stop()`**, 5s 기존 경로는 최후 방어로 유지. 토크는 유지(컷은 E-STOP 만).
    600ms = 22Hz 스트림 기준 13패킷 연속 유실 — 오탐 여유 충분. (ROS `cmd_vel` timeout 관행
    0.2–0.5s 를 보행 양자화에 맞춰 보수화.)
  - **파일 폴 폴백**: 유지하되 250ms 로 완화(UDP/stdin 활성 시), 비활성 감지 시 100ms 복귀.
- (c) 스레드 안전 명시: Walking 파라미터는 현재도 메인 스레드가 쓰고 125Hz 스레드가 읽는
  비동기 double 쓰기(기존 위험과 동일 클래스 — ROBOTIS demo 관례). v2 에서 파라미터 쓰기를
  supervisor 단일 지점으로 모아 현상 유지(transport 스레드는 슬롯에만 씀). E-STOP 스레드의
  `Walking::Stop()` 은 bool 플래그 set — `StatusCheck` 버튼 스레드와 동일 패턴.
- (d) 검증: ① 명령 실효율 ≥20Hz(ACK 카운트/s), ② 입력→로봇 적용(ACK t_rx 기준) 유선 p95
  ≤120ms, ③ E-STOP: UDP 발사→TEL walking=0 까지 유선 p95 ≤60ms(로봇 내부 ~5ms + RTT),
  ④ 케이블 뽑기 테스트: 600ms 내 제자리 걸음 전환 → 2.5s 정지, ⑤ 구버전 폴백: UDP 차단 시
  파일 경로로 자동 복귀. ⑥ E-STOP 회귀: 파일 플래그 경로 동작 불변.
- (e) 난이도 L / 리스크 중 — 최대 리스크는 로봇 측 스레드 도입. 완화: 스레드는 전부
  "수신→슬롯/플래그" 만 수행(로직 없음), 적용은 기존 단일 루프. 기능 플래그
  `df.onboard.udpCommand` 로 공존 운용.

### Wave O2 — 명령 의미론 v2 + 거버너 (M) — "역동"의 안전한 확장

1. **프로토콜 v2(twist 의미론, G2)**: `V2 {seq} {t_tx_ms} {flags} {vx_mms} {vy_mms} {wz_mrad_s}
   {period_ms} {foot_mm} {hip_cdeg} {blevel} {headPan_cdeg} {headTilt_cdeg}` —
   REP-103 SI 밀리단위 정수(부동소수 파싱 배제). 로봇이 변환 소유:
   `X_MOVE ≈ vx·T/2`(보행속도 v ≈ 2X/T 의 역, **실측 보정 계수 k_x 를 O0 벤치로 확정**),
   `A_MOVE ≈ wz·T/2`. v1 14토큰은 sscanf 분기로 영구 수용(기존 backward-compat 패턴 답습,
   `WalkLabBrokerage.cpp:617-627`). `docs/ssh-parity-contract.md` §A 개정 동반.
2. **스무딩 일원화(G5)**: Mac EMA α=0.25 → **0.5 로 완화**(표시용 시뮬은 기존 유지), 셰이핑
   책임을 로봇 supervisor 로 이관 — **래치 단위 슬루**: 인접 래치 간 |ΔX_MOVE| ≤ 8mm,
   |ΔY| ≤ 6mm, |ΔA| ≤ 4°, |ΔPERIOD| ≤ 60ms (가속 제한 = 첫걸음 capturability 보호).
   수치는 O0 벤치 후 확정하되 상한 상수로 고정.
3. **결합 엔벨로프 거버너(G6)**: 로봇이 최종 클램프 소유 —
   `|x|/x_max + |y|/y_max + |a|/a_max ≤ 1.15` 초과 시 비율 스케일다운 + period 종속
   `x_max` 스케줄(700ms→40mm, 600→38, 500→32, 440→28 — 초기값, 벤치로 갱신).
   Mac 클램프(38/22/12)는 UX 레이어로 유지(이중 방어).
4. **죽은 토큰 결선(G7 일부)**: `benable→BALANCE_ENABLE`, `blevel(0..3)→BALANCE_*_GAIN ×
   {0, 0.5, 1.0, 1.5}` 스케일 적용 — ParseAndApply 에 ~15줄. bgain(float)은 deprecated 로
   문서화(blevel 로 단일화).
5. **게인·게이트 스케줄링(역동성)**: |vx| 상위 30% 구간에서 Z_MOVE +5mm·Y_SWAP +2mm·
   HIP_PITCH +1.5° 자동 가산(선형 보간 테이블, supervisor 에서 래치 전 적용) — 고속 보행의
   발 클리어런스·측면 안정 확보. 기본 ON, `flags` 비트로 OFF 가능.

- (a) 변경: `WalkLabBrokerage.cpp`(ParseAndApply/supervisor), Mac `WalkingEngineCommand`
  serializer(`WalkLab/WalkingEngine.swift`), `CockpitState.swift` EMA 상수.
- (d) 검증: 변환식 단위 테스트(Mac/로봇 동형 구현 대조), 거버너 경계 테이블 테스트,
  스텝 응답 재측정(O0 대비 정착 시간 ≥30% 단축 목표), 슬루 동작 로그(TEL 래치값으로 확인).
- (e) 난이도 M / 리스크 중하 — 거버너·슬루는 보수적 초기값으로 시작, 크래들 검증 후 완화.

### Wave O3 — 밸런스 피드백: FSR/IMU (L · 실험 플래그) — "안정"의 본체

전제: FSR 데이터는 이미 8ms 벌크리드 버퍼에 있다(`CM730.cpp:417-429`) — **추가 버스 비용 0**.
모든 항목은 컴파일 타임 + 런타임 플래그로 게이트, 기본 OFF, 크래들 단계 검증.

1. **TEL 에 FSR/CoP 노출(G8, 선행)**: 브로커리지가 `m_BulkReadData[FSR::ID_*]` 에서 4+4 셀과
   CoP(x,y)를 읽어 TEL v2 필드로(O4 와 합류). FSR 미장착(OP1/PING 실패) 시 `-` 토큰.
   Mac 3D 오버레이(`docs/design/3d-viewport-enhancement.md` Wave 3 FSR 인디케이터)의 실데이터
   공급원 — 두 설계의 합류 지점.
2. **자이로 P 의 품질 개선**: `Walking.cpp` 패치 — ① 자이로 입력 1차 LPF(fc≈15Hz, 8ms 이산화
   α≈0.43) 옵션: raw ADC 노이즈로 인한 서보 떨림 감소, ② 게인 런타임 스케일(O2-4 의 blevel)
   배선. ×4 분기(588-598행)는 불변 — **이 패치는 #else(4096) 분기에만 적용**.
3. **CoP 기반 ankle 보정(실험)**: BALANCE 블록 확장 — CoP 종/횡 오차에 P 항을 ankle pitch/roll
   목표에 가산(초기 게인 0, 크래들에서 점증). 이론 근거: 발목 전략(ankle strategy)은 소외란
   영역에서 ZMP 를 지지면 중앙으로 회귀시킴 — 자이로(각속도)와 상보적인 위치 항.
   125Hz 컨텍스트(Walking::Process)에서 실행되므로 brokerage 주기와 무관.
4. **낙상 위험 지표(G8)**: supervisor 에서 기울기 추정(보완 필터 — `forge-core/walk/imu.rs` 의
   α=0.98 설계를 C++ 이식 ~40줄) + |기울기| 임계(예: 18°) 초과율을 TEL `risk` 필드로.
   Mac HUD 경고·햅틱과 자동 감속(거버너 스케일다운) 트리거 — **자동 개입은 감속까지만**,
   정지·자세 개입은 기존 낙상 처리(FALLEN/getup)에 위임.
5. **자이로 재캘리브레이션 명령**: v2 `flags` 비트 — 정지 상태에서 `ResetGyroCalibration`
   재실행(현재는 walklab 진입 시 1회뿐, 온도 드리프트 대응 불가).

- (a) 변경: `Walking.cpp`(패치 diff 는 `firmware-patches/` 에 보관, demoBuildPatched 가 적용),
  `WalkLabBrokerage.cpp`, Mac HUD.
- (d) 검증(순서 고정): ① 크래들+다리 토크 해제로 게이트 무부하 검증 → ② 제자리 걸음(March)
  에서 LPF on/off 서보 떨림 비교(전류/온도 READ) → ③ 평지 저속 → ④ 외란은 "기울임판"
  (수동 푸시 금지) 단계. 각 단계 E-STOP 리허설 선행. 게인별 결과를
  `docs/reports/` 에 기록(주기/진폭 ×게인 매트릭스).
- (e) 난이도 L / 리스크 중상 — Walking.cpp 는 검증된 코어. 완화: diff 최소(밸런스 블록 한정),
  원본 바이너리 백업·즉시 롤백 스크립트(`demo` 원본은 보존됨), 플래그 기본 OFF.

### Wave O4 — 텔레메트리 v2 + 디지털 트윈 정합 (M)

1. **TEL v2**: `TEL2 {ts} {seq_applied} {phase} {x_lat} {y_lat} {a_lat} {period_lat}
   {gx gy gz ax ay az} {fsr×8|-} {copx copy|-} {fallen} {risk} {vdV} {loop_p95_ms}` —
   UDP **30Hz**(supervisor 20ms 의 1.5배수, ~140B → 4.2KB/s), 파일은 5Hz 유지.
   위상·래치값 노출로 Mac 이 "명령 vs 실제 적용" 차이를 표시 가능(래칭 지연의 가시화 —
   콕핏 HUD 에 "적용 대기" 마이크로 인디케이터).
2. **Mac 수신**: `OnboardTelemetry` v2 파서 + `ingestOnboardTelemetry` 확장(레이턴시 문서 J6
   적응형 폴러와 정합 — UDP 신선 시 SSH 1Hz). 3D 뷰포트 오버레이(FSR/CoP/IMU 수평선)와 결선.
3. **시뮬 정합**: 콕핏 시뮬 보행 애니메이터가 TEL2 의 위상·래치값을 소비해 실로봇과 위상 동기
   (현재는 명령 기반 추정) — "화면=게이지=실모터" 불변식의 완성형.

- (d) 검증: 30Hz 수신율(패킷 카운터), HUD 위상 표시와 실로봇 보행 영상 프레임 대조,
  Wi-Fi 환경에서 손실률 측정(>20% 손실 시 SSH 폴 승격 동작).
- (e) 난이도 M / 리스크 낮음.

## 5. 검증 프로토콜 (증거 기반 완료 기준)

**벤치(로봇 무부하 — 크래들 + 다리 토크 해제 + 배터리 차단 스위치 상비, CLAUDE.md 안전 수칙):**

| 측정 | 방법 | O 이전 기대 | 합격선(이후) |
|---|---|---|---|
| 명령 실효율 | 10s 스틱 흔들기, 로봇 ACK 카운트/s | 4–8Hz | O1: ≥20Hz |
| 입력→로봇 적용 | tracer `inputSampled→ackReceived(t_rx)` p95 | 0.4–1.5s | O1: ≤120ms(유선) |
| 입력→래치 | TEL2 `x_lat` 변화 시각 − 입력 시각 | ~0.7–1.0s | O2: ≤350ms@period 500 |
| E-STOP→walking=0 | UDP 발사 시각 − TEL 플래그 전환 | ≤220ms(유선) | O1: p95 ≤60ms·최악 ≤150ms |
| 통신 두절 | 케이블 분리 | 최대 5s 유령 보행 | O1: 0.6s 제자리 → 2.5s 정지 |
| 서보 떨림 | March 중 전류/온도 READ 표본 | 기준선 | O3-2: LPF on 시 감소 확인 |

**단위/HIL**: 브로커리지 v2 의 파서·슬루·거버너·워치독은 `Robot::*` 를 스텁한 호스트 빌드로
단위 테스트(`firmware-patches/walklab-brokerage/tests/` 신설, plain Makefile — 로봇 toolchain
불요). Mac 측은 기존 Swift 테스트 관례(serial 실행) 준수.

**실기 단계 게이트**: 각 Wave 는 ①벤치 통과 → ②크래들 보행 → ③평지 저속 → ④콕핏 일상 조종
순으로만 승격. O3 항목은 ②에서 게인 0 시작.

## 6. 안전 불변식 (레이턴시 문서 §7 승계 + 추가)

- [ ] E-STOP 경로 스로틀·배칭·추가 홉 금지 — O1 의 E-STOP 스레드는 홉 *제거* 방향.
- [ ] 파일 기반 명령/E-STOP/텔레메트리 경로는 폴백으로 영구 보존(UDP 는 가산 채널).
- [ ] 정지 시퀀스의 DSP 게이팅(`Walking.cpp:375-411`) 무변경 — 즉시 정지는 E-STOP 전용.
- [ ] 워치독 티어의 토크 유지 원칙 — 토크 컷은 E-STOP·FALLEN 경로만.
- [ ] Walking.cpp 패치는 밸런스 블록 한정 + 플래그 게이트 + 원본 롤백 경로 상비.
- [ ] 프로토콜 변경은 `docs/ssh-parity-contract.md` 개정과 동일 커밋.
- [ ] 구형 펌웨어(미패치 demo) 공존: V2 미인식 → V1 폴백, NO_ACK 처리 경로 불변.

## 7. cockpit-latency-hardening.md 와의 분담·합류

| 주제 | 레이턴시 문서(Mac) | 본 문서(로봇+계약) |
|---|---|---|
| SSH 상주 채널 | Wave 1 `PersistentSSHChannel`·`OnboardCommandChannel` | O1 stdin 리더(로봇 측 짝) |
| UDP E-STOP | S5 — Mac 발사(×3연발)·토큰 프로비저닝 | O1 — 로봇 전용 리스너(폴 제거, ~5ms) |
| 코얼레싱 | `SendPolicy.latestWins`(Mac 큐) | O1 latest-wins 슬롯(로봇 수신) |
| 워치독 | S2 Mac 입력원 failsafe | O1 로봇 측 티어링(이중 방어 완성) |
| 계측 | §6 tracer(Mac 구간) | O0 로봇 적용 시각·클럭 오프셋(E2E 완성) |
| 텔레메트리 폴러 | J6 적응형 폴 | O4 TEL2 30Hz·내용 확장 |

권장 시퀀스: 레이턴시 문서 Wave 0–1 과 본 문서 O0–O1 을 **한 묶음**으로(상호 짝 구현),
이후 O2 → O4 → O3(실기 검증 비중 최대) 순. 3D 오버레이 문서 Wave 3(FSR/CoP)은 O3-1/O4 이후
실데이터 결선.

## 8. 착수 가이드

```sh
# 로봇 측 소스 빌드 검증(호스트): firmware-patches/walklab-brokerage/ — C++03, 외부 의존 pthread 만
# 배포는 앱 내 자동배포(demoBuildPatched)가 로봇에서 컴파일 — RobotSetupCommand.swift:932-1034
make doctor && bash scripts/build-mac.sh --swift
swift test --package-path app/ui/DarwinForge        # serial 필수
```

- 로봇 접속: 유선 `192.168.123.1`(무선 0.33 대비 ~166×, 메모리·CLAUDE.md), demo 로그
  `/tmp/df-demo.log`, 진행 상태 `/tmp/df-pilot-progress`.
- 프로토콜 상수의 단일 출처: Mac `DFConnectionConstants.swift`(포트) ↔ 브로커리지 헤더 —
  O1 에서 포트/토큰을 핸드셰이크 파일로 전달하므로 하드코딩 추가 금지.
- 모든 수치(슬루 한계·거버너 테이블·워치독 티어)는 브로커리지 헤더 상수로 집결 — O0 벤치
  결과로 갱신할 단일 지점.
