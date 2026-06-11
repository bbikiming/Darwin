# 구현 착수 프롬프트 모음 (Implementation Prompts)

> 2026-06-11 · 미착수 설계의 세션별 착수 단위 12개. **권장 실행 순서대로 정렬** —
> 각 블록을 새 Claude Code 세션에 그대로 붙여넣으면 된다. 전제가 있는 프롬프트는
> 전제 완료 후 실행할 것. 완료된 프롬프트는 체크박스를 갱신한다.
>
> 공통 규칙(모든 프롬프트에 이미 내장됨): 증거 기반 완료(테스트/빌드 실행 결과 제시),
> Swift 테스트 serial 실행, E-STOP 경로 무스로틀, 실기 단계 전 정지·보고,
> 완료 시 docs/design/README.md 현황 표 갱신.

---

## [ ] P1 — RG G01 호환성 프로브 (H0) · 로봇 전원 필요 · 읽기 전용

```
docs/design/handheld-direct-pilot-upgrade.md 의 Wave H0 을 수행해줘.

목표: RG G01 을 로봇 등 USB 에 꽂았을 때(유선 USB-C 와 2.4G 동글 각각) 로봇 커널이
어떻게 인식하는지 판정하고, H1 구현에 쓸 축/버튼 코드 테이블을 확정한다.

작업:
1. firmware-patches/tools/probe-gamepad.sh 작성 — lsusb, dmesg tail, /proc/bus/input/devices,
   /dev/input/ 목록, 이벤트 레이트 측정(문서 §4 H0 의 스크립트 골격 참조).
2. 실행 경로는 둘 중 가능한 것: (a) 로봇 SSH 직접(유선 192.168.123.1, 무선 192.168.0.33),
   (b) df-inbox 채널(SMB ~/.df_inbox 에 .sh 투하 → 2s 내 자동 실행 → .out 회수,
   docs/design/handheld-direct-pilot-upgrade.md §1.3 참조).
3. 판정 매트릭스(§4 H0): D-input event 노드 생성 여부 → XInput 이면
   echo <VID> <PID> > /sys/bus/usb/drivers/xpad/new_id 시도 → 동글 동일 절차.
4. 결과를 docs/reports/2026-MM-DD-rgg01-usb-probe.md 로 기록: VID/PID, 바인딩 드라이버,
   event 노드, 축 범위(EVIOCGABS), 버튼 코드 → H1 용 코드 테이블 초안 포함.

제약: 로봇 파일 수정·데몬 재시작 금지(읽기 전용). 로봇이 walklab 데모 구동 중이어도
무해해야 함. 보고서 커밋: docs(report) 스코프.
```

## [ ] P2 — 3D 뷰포트 W2: 화면별 환경 프리셋 + 셰이더 그리드 · 독립

```
docs/design/3d-viewport-enhancement.md 의 Wave 2 를 구현해줘. W0(분할)·W1(PBR/IBL)은
이미 머지됨(커밋 b941f54·2a58777) — 문서의 §4 설계를 현재 코드 구조
(Visualization/Scene/SceneStage.swift, ProceduralEnvironmentMap.swift, Rigs/RigMaterials.swift)
위에 적용한다. 라이브 튜닝 패널(9a32f8d)과의 충돌 여부를 먼저 확인할 것.

범위: ① ScenePreset 5종(.studio/.teach/.walkLab/.motion/.cockpit) + SceneEnvironmentSpec
값 테이블(§4 2-A 표의 초기값) + RobotScene3D.init(preset:) 주입 → 각 화면 호출부 1줄.
② fwidth 기반 AA 그리드 셰이더(GridFloorMaterial.swift) — SCNFloor world xz 좌표 수급이
리스크이며 실패 시 40×40m SCNPlane 폴백(문서 명시 권장 경로). 실린더 그리드는
legacyGrid() 로 보존. Cockpit 그리드(58노드)도 teal 파라미터로 교체.

성능 계약(위반 금지): 30fps, isFullyIdle tick skip, 0-alloc 풀, wantsHDR=false,
헤드리스 renderImage/writePNG 회귀 금지. SceneExposureTests 통과 유지.
검증: preset 5종 × 대표 포즈 스냅샷 생성·기록, swift test 전체 통과(serial), 빌드/테스트
결과 증거 제시. 완료 시 docs/design/README.md 현황 표 갱신.
커밋: feat(ui): Wave 2 — … 형식, 웨이브 내 커밋 분할 자유.
```

## [ ] P3 — 전송 묶음: 레이턴시 W1 + 온보드 O0·O1 · 최대 체감 개선

```
docs/design/cockpit-latency-hardening.md 의 Wave 1 과
docs/design/walklab-onboard-teleop-upgrade.md 의 Wave O0·O1 을 구현해줘.
두 문서 §7 에서 한 묶음으로 설계됨(Mac 측 채널 ↔ 로봇 측 수신이 상호 짝).

커밋 순서:
1. O0 계측: ① Mac 파서의 TEL 토큰 수 검증을 "정확히 11" → "≥11" 로 완화(선배포, 
   OnboardTelemetry.swift), ② 브로커리지 WriteTelemetry 에 {last_cmd_id} {loop_ms} 2토큰
   append, ③ Connection/RobotClockSync.swift 신설(ACK 의 로봇 ts 로 클럭 오프셋 EWMA),
   ④ PilotLatencyTracer 에 ackReceived 로봇 시각 보강. 벤치 기준선 기록.
2. W1 Mac 측: actor OnboardCommandChannel(Connection/) — PersistentSSHChannel(상주 ssh 1개,
   stdin 줄단위, stdout sentinel __DF_DONE_<id>_<exit>__, 실패 시 기존 SSHShell.run 폴백),
   SendPolicy(.latestWins(key:)/.ordered), sendEmergencyStopNow(큐 우회),
   UDP E-STOP 병행(17372, "DF-ESTOP v1 <token> <ts>" ×3연발 0/50/100ms, 토큰은 세션 시작
   시 SSH 프로비저닝). 기능 플래그 df.onboard.persistentChannel.
3. O1 로봇 측(firmware-patches/walklab-brokerage/): transport 스레드 3개(stdin 리더,
   UDP 명령 리스너 17374 — latest-wins 슬롯+seq 단조, UDP E-STOP 리스너 17372 — 수신 즉시
   Walking::Stop()+토크OFF), supervisor 루프 walking 시 20ms, 워치독 티어
   (600ms 진폭→0 슬루 / 2.5s Stop / 토크 유지), ACK 즉시 회신, 파일 폴 폴백 영구 보존
   (활성 시 250ms 완화). 호스트 빌드 단위 테스트(tests/ 신설, Robot:: 스텁, plain Makefile).

불변식: E-STOP 경로에 스로틀·배칭·추가 비동기 홉 금지(제거 방향만). 코얼레싱은 freeform
tuning 류만, estop/모드전환은 .ordered. 파일 경로 폴백 영구 보존. 정지 시퀀스의 DSP
게이팅(Walking.cpp) 무변경. docs/ssh-parity-contract.md 개정을 프로토콜 변경과 동일 커밋에.

검증: swift test(serial)·cargo test·호스트 C++ 테스트 전부 실행해 증거 제시.
LatencyBudgetRegressionTests(레이턴시 문서 §6) 신설. **로봇 실기 배포·검증
(demoBuildPatched 재빌드, 실효율 ≥20Hz·E-STOP p95 ≤60ms 벤치)은 코드 완성 후 멈추고
사용자에게 절차를 보고** — 실기는 크래들+다리 토크 해제+배터리 차단 전제.
완료 시 docs/design/README.md 갱신. 커밋 스코프: connection / firmware.
```

## [ ] P4 — 온보드 O2: 거버너 + 명령 의미론 v2 · 전제 P3

```
docs/design/walklab-onboard-teleop-upgrade.md 의 Wave O2 를 구현해줘 (O0·O1 머지 전제).

범위(§4 O2): ① V2 프로토콜(twist SI 밀리단위 정수: vx_mms/vy_mms/wz_mrad_s + seq/t_tx,
v1 14토큰 sscanf 분기 영구 수용 — 기존 backward-compat 패턴 답습), 변환 X_MOVE≈vx·T/2
(보정계수 k_x 는 벤치 후 확정 — TODO 상수로). ② Mac EMA α 0.25→0.5 완화(시뮬 표시용은
유지), 셰이핑을 로봇 supervisor 의 래치 단위 슬루로 이관(|ΔX|≤8mm·|ΔY|≤6mm·|ΔA|≤4°·
|ΔT|≤60ms — 헤더 상수 집결). ③ 결합 엔벨로프 거버너: |x|/x_max+|y|/y_max+|a|/a_max ≤1.15
스케일다운 + period 종속 x_max 테이블(700→40, 600→38, 500→32, 440→28mm 초기값).
④ 죽은 토큰 결선: benable→BALANCE_ENABLE, blevel(0..3)→게인 ×{0,0.5,1.0,1.5}
(WalkLabBrokerage.cpp ParseAndApply — 현재 612행 부근에서 소비만 하고 미적용 상태).
⑤ 속도 비례 게이트 스케줄(Z_MOVE +5mm·Y_SWAP +2mm·HIP_PITCH +1.5°, flags 비트로 OFF).

주의: 이 거버너는 Switch(stride 50mm 무클램프 통과)·핸드헬드 계열 전체의 안전 전제 —
로봇이 최종 클램프를 소유한다. 거버너/슬루 상수는 docs/design/bus-direct-teleop-upgrade.md
D1 과 공유될 단일 정의(브로커리지 헤더)로.

검증: 변환식·거버너 경계·슬루 단위 테스트(호스트 빌드), Mac 측 serializer 테스트,
swift test(serial) 증거 제시. ssh-parity-contract.md 개정 동일 커밋. 실기 벤치(스텝 응답
정착 시간 ≥30% 단축 확인)는 멈추고 사용자 보고. README 현황 갱신.
```

## [x] P5 — bus D0: J4 deadline + J13 FTDI + 계측 · 독립·즉시 ✅ (2026-06-11)

```
docs/design/bus-direct-teleop-upgrade.md 의 Wave D0 을 구현해줘.
(레이턴시 문서 §5.6 J4 와 J13 의 집행 + bus 경로 계측. D1 의 선행 필수 단계.)

범위: ① J4 — WalkLabSession+MobileFreeform.swift / WalkCycleEngine 의 고정 sleep 을
deadline 기반으로: nextStepAt = max(nextStepAt + stepMs, now) 후 Task.sleep(until:) —
write 소요·MainActor 홉 자동 보상. phase floor 80ms 유지. E-STOP/cancel 체크는 step 경계
그대로. ② J13 — app/core/forge-core/src/serial/posix.rs 에 macOS IOSSDATALAT ioctl 로
FTDI latency 1ms(미지원 어댑터 no-op). FFI 시그니처 변경 시 make headers.
③ PilotLatencyTracer 에 bus 마크(stepScheduled→syncWriteDone→imuRead) + step 지터
히스토그램, HUD 디버그 1Hz.

검증: cargo test + swift test(serial) 증거, 지터 단위 테스트(LoopbackTransport 목),
합격선: step 지터 p95 ≤ ±10ms(시뮬 측정). 실기 USB IMU read p95 ≤3ms 확인은 사용자 보고.
커밋: feat(serial)/feat(walklab). README 현황 갱신.
```

## [ ] P6 — bus D1+D2: 50Hz 연속 스트리밍 + 밸런스 50Hz + FSR 관측 · 전제 P4·P5

```
docs/design/bus-direct-teleop-upgrade.md 의 Wave D1 과 D2 를 구현해줘 (D0 머지 전제,
거버너/슬루 상수는 O2 산출물과 공유).

D1(§4): runContinuousWalk 에 시간 기반 모드 신설 — 고정 6 키프레임 대신 매 step 에서
robotisWalkingApproxPose(timeMs: (now−cycleStart) mod period) 직접 평가, step 20ms 고정.
changedJoints 필터 유지. 진폭 래칭을 Walking.cpp 의미론(스윙 중간 경계 X/Y/A, DSP 경계
period)으로 — tuning 래치 객체(WalkMotionLibrary 에 단일 정의). playMs≥80 하한은 키프레임
모드 전용으로 남기고 시간 모드는 period≥440 클램프. liveness PING 은 스텝 수→시간 기준
(1Hz). 기능 플래그 df.walklab.denseStreaming(기본 off). 진동 시 후퇴용 step 30ms 상수화.

D2(§4): 보행 중 IMU 폴 50ms→20ms(ConnectionStore.swift:2700 동적 증속 분기 확장),
applyBalanceCorrectionIfEnabled 를 step(20ms)마다. 자이로 입력 1차 LPF(fc≈15Hz) 추가
(온보드 O3-2 와 동일 상수). FSR 10Hz READ(ID 111/112) → FsrReading 으로 HUD/3D 오버레이
공급(제어 미개입). 낙상 감지 윈도 재계산(50Hz 입력 기준).

핵심 검증(필수): 동치 테스트 — 같은 tuning·같은 시각에서 키프레임 모드 6 포즈와 시간
기반 모드 포즈 일치(궤적 회귀 0 증명). 래칭 경계 단위 테스트. swift test(serial) 증거.
버스 예산 확인 로그(SYNC_WRITE+IMU+FSR ≈5–6% @1Mbps). 실기(직진 5m 드리프트·서보 온도
10분·진동 여부)는 멈추고 사용자 보고 — 크래들 게이트 절차 포함. README 갱신.
```

## [ ] P7 — handheld H1+H2: 온보드 GamepadPilot + 소스 중재 · 전제 P1(권장 P3·P4)

```
docs/design/handheld-direct-pilot-upgrade.md 의 Wave H1 과 H2 를 구현해줘.
H0 프로브 보고서(docs/reports/ 의 rgg01-usb-probe)를 먼저 읽고 축/버튼 코드 테이블 상수를
그 결과로 채울 것. O1 이 머지돼 있으면 latest-wins 슬롯에 source=local 로 합류, 아니면
1차 버전은 ParseAndApply 동급 적용 함수 직접 호출(문서 §4 H1-5 명시).

H1: firmware-patches/walklab-brokerage/GamepadPilot.{h,cpp} 신설(C++03, pthread).
/dev/input/event* 스캔+1s 재스캔(핫플러그/분리 겸용 — switch-pilot input_linux.py:211-375
로직의 C 이식), blocking read 스레드, EVIOCGABS 정규화. 매핑은 콕핏 RG G01 프리셋과 1:1
(ControllerBindingProfile.swift:184-230): LS=이동/횡, RS X=턴·Y=머리틸트, LT/RT=머리팬,
B=E-STOP(rising edge, 읽기 스레드에서 즉시 Walking::Stop+토크OFF+estop 파일 set),
Y=복구, X=볼트랙, LB=데드맨(이동/턴만 게이트), RB=터보. 성형: 데드존 0.10, 곡선 1.35,
intensity^0.7→period/foot 스케줄(switch-pilot ssh_control_client.py:278-302 식 채택).
클램프는 로봇 거버너(O2)가 최종 — 없으면 임시로 38/22/12 하드 클램프.

H2: 소스 우선순위 E-STOP(전 소스 상시) > local(최근 입력 ≤1s) > 네트워크. ARM 의미론
(A 버튼 ARM 전 이동 게이트 잠금 — switch-pilot main.py:469-496 settle 규칙 이식),
USB 분리/5s 무수신 → inputSourceLost → 워치독 티어(즉시 제자리 슬루). TEL 에
active_source 토큰 추가(Mac 파서 ≥11 완화 전제).

검증: 호스트 빌드 단위 테스트(매핑·정산·중재 — Robot:: 스텁), 증거 제시. 실기(크래들에서
E-STOP ≤20ms·분리 failsafe·10분 CPU)는 멈추고 사용자 보고. 케이블 스트레인 릴리프/동글
권장 사항을 보고에 포함. README 갱신. 커밋: feat(firmware).
```

## [ ] P8 — 온보드 O3: 밸런스 피드백(FSR/IMU) · 전제 P3·P4 · 실기 비중 최대

```
docs/design/walklab-onboard-teleop-upgrade.md 의 Wave O3 을 구현해줘 (O0·O1·O2 머지 전제).
모든 항목은 컴파일+런타임 플래그 게이트, 기본 OFF — 코드·테스트 완성 후 실기 튜닝 전에
반드시 멈추고 사용자에게 단계 절차(§5 크래들→March→평지→기울임판)를 보고할 것.

범위(§4 O3): ① TEL 에 FSR 4+4 셀+CoP 노출(브로커리지가 m_BulkReadData[FSR::ID_*] read —
8ms 벌크리드에 이미 포함돼 추가 버스 비용 0, CM730.cpp:417-429 근거. FSR 미장착 시 "-").
② Walking.cpp 패치(diff 는 firmware-patches/ 보관, demoBuildPatched 적용): 자이로 입력
1차 LPF(fc≈15Hz, 8ms 이산화 α≈0.43) 옵션 + blevel 게인 스케일 배선. ×4 분기(#else 4096)
에만 적용, 원본 바이너리 백업+롤백 스크립트 동봉. ③ CoP 기반 ankle 보정(실험): BALANCE
블록에 CoP 오차 P 항(초기 게인 0). ④ 낙상 위험 지표: 보완 필터(forge-core walk/imu.rs 의
α=0.98 설계 C 이식 ~40줄) → TEL risk 필드, 임계 초과 시 거버너 자동 감속(개입은 감속까지만).
⑤ 자이로 재캘리브레이션 명령(V2 flags 비트, 정지 상태 가드).

불변식: Walking.cpp 변경은 밸런스 블록 한정. 정지 DSP 게이팅 무변경. 토크 컷은
E-STOP/FALLEN 경로만. 검증: 호스트 단위 테스트(LPF·CoP 부호·risk 계산), 패치 diff 리뷰
용이성(최소 diff), 증거 제시. README 갱신. 커밋: feat(firmware).
```

## [ ] P9 — 온보드 O4: 텔레메트리 v2 (TEL2 30Hz) · 전제 P3

```
docs/design/walklab-onboard-teleop-upgrade.md 의 Wave O4 를 구현해줘 (O0·O1 머지 전제,
O3 의 FSR 필드는 머지돼 있으면 포함, 아니면 "-" 자리 확보만).

범위(§4 O4): ① TEL2 포맷 — TEL2 {ts} {seq_applied} {phase} {x_lat y_lat a_lat period_lat}
{gx gy gz ax ay az} {fsr×8|-} {copx copy|-} {fallen} {risk} {vdV} {loop_p95_ms} — UDP 30Hz
(supervisor 20ms 기반), 파일은 5Hz 유지(TEL v1 병행 기간 운용). ② Mac: OnboardTelemetry v2
파서+ingestOnboardTelemetry 확장, 레이턴시 문서 J6(적응형 폴러 — UDP 신선 시 SSH 1Hz)을
이 커밋에서 함께 집행. ③ 콕핏 HUD 에 "명령 vs 래치값" 차이 마이크로 인디케이터 + 시뮬
walkAnimator 가 TEL2 위상 소비(화면=게이지=실모터 불변식의 완성). ④ active_source 필드
(H2 가 요구 — 자리 확보).

검증: 파서 단위 테스트(v1/v2/결손 토큰), swift test(serial) 증거, Wi-Fi 손실률 >20% 시
SSH 폴 승격 동작 테스트(목 주입). 실기 30Hz 수신율 확인은 사용자 보고. README 갱신.
```

## [ ] P10 — handheld H3: Switch 클라이언트 O1-UDP 화 · 전제 P3(권장 P9)

```
docs/design/handheld-direct-pilot-upgrade.md 의 Wave H3 을 구현해줘 (O1 머지 전제).

범위: tools/switch-pilot 의 SshControlClient 에 UDP transport 추가 — V2 프로토콜(seq+토큰,
포트는 O1 핸드셰이크 파일 계약과 동일), send_hz 5→20, E-STOP UDP ×3연발(0/50/100ms)+SSH
병행(기존 파일 touch 경로 폴백 유지), estop heartbeat 900ms→UDP keepalive 250ms(로봇
워치독 티어와 정합). 텔레메트리는 TEL2 UDP 수신(P9 머지 시) — cat 폴은 폴백 강등.
config.json 스키마에 transport 선택 추가(기본 auto: UDP 시도→SSH 폴백).

주의: Switch 측 stride 50mm 클램프는 그대로 두되(거버너가 로봇에서 최종 클램프 — O2 전제),
config 기본값을 38mm 로 하향하고 주석으로 근거 기재(매핑 패리티 표 §5).

검증: Python 단위 테스트(기존 스타일 따름 — 패킷 직렬화/seq/폴백 전환), 호스트에서 UDP
루프백 목 테스트. 실기(Switch→로봇 무선 실효율·estop)는 사용자 보고. README 갱신.
커밋: feat(switch).
```

## [ ] P11 — 3D 뷰포트 W3: 로봇공학 오버레이 · W0 만 의존 · P9 후 실데이터

```
docs/design/3d-viewport-enhancement.md 의 Wave 3 을 구현해줘. 첫 커밋은 반드시
protocol RigSkeleton(MeshRig/DarwinOP2Rig 양쪽 채택 — 프리미티브 폴백 크래시 방지) 선행.

범위(§5): Visualization/Overlays/ 신설 — RobotOverlaySet(OptionSet+preset 기본값 매트릭스),
RobotOverlayLayer(노드 풀 소유, applyPose 경로에서만 갱신·자체 타이머 금지),
CoM+지지다각형(URDF 질량 가중 + 8점 convex hull + ZMPMonitor.Verdict 색),
관절축+한계아크(highlight 동기, pitch=green/roll=red/yaw=blue, 85%/95% 경고),
FSR 접지(발당 2×2 quad — 온보드 TEL2 또는 bus FsrReading, 미연결 시 sole y<0.005m 휴리스틱),
IMU 수평선(tiltNode 바깥), EE 궤적(160 풀·4mm 샘플링, Motion 전용),
한계 근접 경고(setEmissionState 단일 진입점 — warn95>warn85>highlight).
ViewportControls 에 오버레이 팝오버 토글.

성능 계약: 30fps/isFullyIdle/0-alloc 풀/자체 타이머 0. 검증: 오버레이별 헤드리스 스냅샷
(한계아크는 min/max/중앙 3포즈), ZMPMonitor 좌표 정합 테스트, Instruments 풀링 확인 절차
문서화, swift test(serial) 증거. README 갱신. 커밋: feat(ui).
```

## [ ] P12 — 3D 뷰포트 W4+W5: 디테일·카메라 연출 + 성능 검증 · 독립

```
docs/design/3d-viewport-enhancement.md 의 Wave 4 와 5 를 구현해줘.

W4(§6): ① MeshRig 머리 디테일 attachHeadDetails(to:) — LED 눈/이마 카메라/정수리 LED
이식(초기 좌표 ±0.021, 0.015, 0.048 부근에서 스냅샷 반복 튜닝). ② ViewCube 부드러운
전환 — instant:true→ease(전환용 smoothing 0.18, ≤0.4s), shortestAngleDelta 최단경로 보정
필수+단위 테스트, 1줄 롤백 가능 유지. ③ 턴테이블 turntableRadPerSec — isFullyIdle 조건에
!= 0 추가 필수(idle skip 충돌), 기본 off. ④ DOF 토글(fStop 5.6, Studio/Motion 옵트인,
스냅샷 renderer 제외). ⑤ Cockpit 체이스캠 — 카메라 scene root 직속+delegate 30Hz 위치
lerp 0.12/heading 0.08, 속도 비례 lean ≤2.5°+FOV 50→54 킥.

W5(§7): 성능 가드 통합 — IBL 캐시/shadow 1개/그리드 노드 감소/오버레이 풀링/idle CPU
전후 비교를 측정해 문서 §7 표에 실측치 기입, renderImage(pose:preset:overlays:) 시그니처
확장 회귀, SceneExposureTests CI 상시 확인, preset×포즈 스냅샷 기준선 갱신.

검증: swift test(serial) 증거 + 스냅샷 비교 기록. README 갱신. 커밋: feat(ui)/test(ui).
```

---

## 의존 요약

```
P1(즉시) ─────────────────────────────┐
P2(즉시) · P5(즉시)                    ▼
P3(전송 묶음) → P4(거버너) → P6(bus 50Hz) · P7(GamepadPilot) · P8(O3 밸런스)
                    └→ P9(TEL2) → P10(Switch UDP) · P11(3D 오버레이 실데이터)
P11(코드 자체는 즉시 가능) · P12(즉시)
```
