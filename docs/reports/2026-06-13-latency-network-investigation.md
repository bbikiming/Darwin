# DarwinForge 텔레옵 레이턴시·네트워크 효율 — 통합 조사 보고 (2026-06-13)

> 브랜치 `claude/robotis-darwin-op-setup-oyzTi` 현행 코드 대비 전수 재검증. 직전 설계문서 `docs/design/cockpit-latency-hardening.md`(2026-06-11)의 35건을 fixed/open/stale/new-since로 분류하고, 실측·추정을 구분해 단일 우선순위 로드맵으로 합성한다. 이것은 **조사**이며 구현이 아니다.

## 1. 결론 요약 (먼저)

직전 35건 문서의 **P0/P1 대부분은 이미 출하됐다** — bus SYNC_WRITE(보행 핫루프 step당 12왕복 36-72ms → 1패킷), 콕핏 게임패드/키보드/DJI E-STOP→하드웨어 토크오프 배선(S1 critical), RunLoop `.common` 모드 타이머(L3). 따라서 이들은 재권고하지 않는다.

남은 **진짜 병목**은 네 갈래로 모인다:
1. **온보드 SSH 명령 경로**가 여전히 명령당 신규 `ssh` 프로세스 + 인라인 최대 1.5s grep ACK 폴 → 실효 4-8Hz, 입력→로봇 250-600ms(추정).
2. 그 대체재인 **O1 UDP 명령·E-STOP·상주SSH 스택이 펌웨어엔 완비됐으나 Mac이 채널 핸드셰이크를 절대 안 써서 100% 미배선 dead code**.
3. 활동 세션 중 **유선(192.168.123.1, 측정 166x 빠름)↔무선 재프로브 부재** → 폴러 무선 고착.
4. **온보드 입력→로봇적용 폐루프 계측이 라이브에 0배선** → 모든 레이턴시 수치가 추정.

**핵심 범위 보정**: 실기 주 조종 경로인 **온보드 Anbernic GamepadPilot은 `/dev/input` 직읽기로 네트워크 hop이 0**이며 F11로 supervisor 20ms까지 단축돼 **이미 최저 레이턴시**다. 네트워크 개선은 **Mac 콕핏/모바일 릴레이 경로**에 집중한다.

**권고 순서**: 계측 먼저(추정→실측) → 무선고착 재프로브(저위험·고효과) → E-STOP UDP 병렬 버스트(안전 바닥, fail-safe) → UDP/상주SSH 명령 경로(HIL 검증 게이트 후).

**안전 불변식(비협상)**: `WD_SLEW_ZERO(600ms)`/`WD_STOP(2500ms)`는 **토크 유지·E-STOP만 컷**이며 **from_stream(UDP슬롯) 전용**(`WalkLabTransport.h:184-199`). 어떤 수정도 이 워치독 의미를 약화하면 안 된다.

## 2. 현행 아키텍처 (경로별)

입력→모터는 **세 갈래 명령 경로**, 로봇→화면은 **네 갈래 피드백 경로**로 흐른다.

- **(A) 온보드-게임패드-로컬** `GamepadPilot.cpp` (로봇 전용, 네트워크 0 hop): RG G01 동글을 `/dev/input`에서 직읽기, `GP_REFRESH_MS=50ms` 로컬 재공급, supervisor가 20ms로 픽업·적용. **이것이 가장 빠른 경로**이며 실기 주 조종 경로. 최신 커밋 `ea5bbb9`가 이 경로를 계속 고도화 중.
- **(B) Mac-온보드-SSH** `WalkLabOnboardBridge` + `RobotSetupCommand`: 45ms streamLoop이나 `OnboardSendQueue` 1-in-flight 직렬화 + 명령당 신규 ssh + 인라인 최대 1.5s grep ACK(`RobotSetupCommand.swift:610`). 실효 4-8Hz. **O1 UDP 패스트레인은 펌웨어 완비(`CmdUdpLoop` `WalkLabBrokerage.cpp:887`)·Swift 정의 완비이나 라이브 미배선**(핸드셰이크 미작성 → `m_transport_running=false` 영속).
- **(C) Mac-bus-USB** `PilotCockpitView` + `WalkLabSession+*`: **대부분 수정됨**. 보행 핫루프 SYNC_WRITE 1패킷(`WalkLabSession+WalkCycleEngine.swift:157`), writeHeadPose SYNC_WRITE, 입력타이머 `.common` 모드. D1 50Hz dense는 의도적 flag-off.
- **(D) 텔레메트리 다운링크**: TEL2 30Hz UDP push(~140B, port 17371) + 파일 TEL v1 5Hz 폴백. SSH-cat 폴러 J6 적응형(UDP 신선 시 5Hz→1Hz). 카메라 MJPEG 프레임 코얼레싱 `bufferingNewest(1)`(J9).
- **(E) 모바일 WebSocket**: 터치 경로 10Hz latest-wins(정상). **게임패드 경로 30Hz 무throttle**(`ExternalControllerAdapter.swift:64,125`) + 릴레이 직렬 taskChain await per-frame, 서버측 컨플레이션 슬롯 없음.

## 3. 기존 35건 재검증 (fixed / open / stale)

| 분류 | 항목 | 상태 |
|---|---|---|
| **fixed** | L5 bus per-joint→SYNC_WRITE | ✅ `WalkLabSession+WalkCycleEngine.swift:117-157`, `control/mod.rs set_positions_many` |
| **fixed** | J12 read_state 3왕복→1 | ✅ `control/mod.rs:175` |
| **fixed** | S1 콕핏 E-STOP→하드웨어 토크오프 | ✅ `PilotCockpitView.swift:206-216` 단일 진입점 |
| **fixed** | L3 RunLoop `.common` 모드 | ✅ `CockpitTimers.swift:24` |
| **fixed** | J6 텔레메트리 폴러 적응형 백오프 | ✅ `OnboardTelemetryPoller.swift:72-79` |
| **fixed** | J9 카메라 프레임 코얼레싱 | ✅ `MjpegStreamingClient.swift bufferingNewest(1)` |
| **fixed** | J11/J13 drain peek·FTDI 레이턴시타이머 | ✅ `tcp.rs:85`, `posix.rs:82` |
| **open** | CP-1/NST-1 온보드 SSH 명령 4-8Hz | ⬜ `RobotSetupCommand.swift:610` 불변 |
| **open** | CP-4/NST-2 온보드 E-STOP SSH 단일(무선 5s) | ⬜ `ConnectionStore.swift:1703-1709`, 병렬 UDP 없음 |
| **open** | NST-3 유선/무선 활동 중 재프로브 | ⬜ 연결시점만(OneClickConnect) |
| **new-since** | CP-2/NST-4 O1 UDP 스택 dead code | ⬜ `walkLabWriteChannelHandshake` 호출처 0 |
| **new-since** | CP-3 PersistentSSHChannel 미배선 | ⬜ `df.onboard.persistentChannel` 미read |
| **new-since** | MR-1 온보드 폐루프 계측 0샘플 | ⬜ `.inputSampled` 미호출, `OnboardCommandChannel(` 테스트전용 |
| **new-since** | MR-5 E-STOP 물리완료 미계측 | ⬜ flag 생성 ≤2ms만 실측 |
| **stale** | CP-5 D1 dense default-off | ⚠️ SYNC_WRITE라 패킷수 아닌 cadence granularity 문제 |
| **stale** | TP3 30Hz @Published 폭주 | ⚠️ 메커니즘 실재, 영향 미증명(Instruments 부재) |
| **low/이미해결** | TP2 1Hz SSH 폴 잔여, TP5 raw-chunk unbounded, TP6 state-dependent cadence, CP-6/CP-7, MR-4/MR-7 | — 실재하나 저영향, 우선순위 제외 |

## 4. 병목 TOP-7 (근거·실측/추정)

1. **[ESTIMATED, MEASURED 배선사실]** O1 UDP 패스트레인 dead code (CP-2/NST-4 enabler). 현재 0ms이나 CP-1·CP-4·MR-1 완화의 유일 경로를 막는 최상위 enabler. `walkLabWriteChannelHandshake`(`RobotSetupCommand.swift:650`) 호출처 0, 펌웨어 `RefreshHandshake`(`WalkLabBrokerage.cpp:914-955`)는 토큰 없으면 UDP 스레드 미시작.
2. **[MEASURED]** 유선/무선 재프로브 부재. 166x 곱셈적 악화. NetworkProbe는 연결시점만(`OneClickConnect.swift:201/274/443`).
3. **[ESTIMATED]** 온보드 SSH 4-8Hz. 연속변화 입력에만 물림(고정 스틱 ~0.67cmd/s, Anbernic 로컬 무관). `RobotSetupCommand.swift:610`.
4. **[ESTIMATED 최악, 안전]** 온보드 E-STOP SSH 단일. 무선 stall 시 from_stream-게이트 워치독으로 ~5s 토크유지 보행. `ConnectionStore.swift:1703-1709`, `WalkLabTransport.h:184-199`.
5. **[MEASURED 부재]** 온보드 폐루프 계측 0배선. 250-600ms 전부 추정. `.inputSampled` 미호출, seq_applied SRC_UDP 전용(`WalkLabBrokerage.cpp:1267`).
6. **[ESTIMATED]** 모바일 게임패드 30Hz 무throttle + 컨플레이션 부재. Mac→로봇 3x 명령률. `ExternalControllerAdapter.swift:64,125`, `MobileRelayServer.swift:824-837`.
7. **[ESTIMATED 미증명]** 30Hz @Published 폭주. `ConnectionStore.swift:2174/2180-2185`, `PilotCockpitView.swift:166`.

## 5. 네트워크 효율 개선 (별도)

- **유선/무선 자동선택**: probe-and-prompt 배너(무음 자동전환 금지 — Switch 123.1 timeout 오발·세션 단절 방지). 측정 166x win.
- **SSH 재사용**: per-command fork/exec → PersistentSSHChannel 상주 `ssh exec sh -s` + stdout sentinel. 실효 4-8Hz→버스 포화.
- **UDP 패킷 명령**: N ssh exec/s → 연결형 UDP(~60-120B) latest-wins. 펌웨어 `CmdUdpLoop`(cmd_port 17374) 기존.
- **UDP E-STOP 버스트**: SSH 단일 → 3연발(0/50/100ms, estop_port 17372) 병렬, fail-safe. SSH/killall/하드웨어 레그 전부 유지.
- **컨플레이션**: iOS 게임패드 10Hz latest-wins + 릴레이 서버측 walk 슬롯. estop/stop ordered 제외.
- **SYNC_WRITE**: 완료(직결 한정, 온보드 무관) — 'done'으로만.
- **텔레메트리**: 30Hz TEL2 UDP(~4.2KB/s, 추가 버스 0). 잔여 미세: UDP 신선 시 파일 write 스킵, wire-seq 손실계측→SSH 승격.

## 6. 우선순위 로드맵 (impact × effort, 보수·안전 우선)

- **Wave 0 — 계측 부트스트랩(추정→실측, 재작성 前 필수, 읽기전용)**: §6 JSON append + 디버그 busTracer ON(S/low) · 입력 hop 마크 결선(S/low) · seq_applied 라이브 SSH 폐루프(M/low, from_stream 불변) · GamepadPilot evdev→offer + loop_ms 분포(M/med).
- **Wave 1 — 무손해 네트워크 효율**: 유선 재프로브 배너(S/low) · iOS 10Hz throttle + 릴레이 컨플레이션(M/med) · @Published 변경게이트(S/low, 측정 後 win 주장).
- **Wave 2 — 안전 바닥(E-STOP 패스트레인, fail-safe)**: 병렬 UDP E-STOP 버스트(S/low) · sendEmergencyStopNow nonisolated화(S/low, 선행) · E-STOP 물리완료 echo(M/med, 비블로킹).
- **Wave 3 — 온보드 throughput(HIL 게이트 後, 최대 win·최고 위험)**: DFCMD/E-STOP UDP 라이브 송출(L/high) · PersistentSSHChannel 채택(M/med, UDP 불확실 시 우선) · D1 50Hz default-on(S/med, 진동 검증 後).

## 7. 계측 계획 (대규모 재작성 前 추정→실측)

Wave 0를 모든 big rewrite 前에 착수한다. 온보드 명령 RTT(seq 탑재+TEL2 차분, 유선/무선·held vs 연속변화별 p50/p95), 입력 hop 분해(.inputSampled 등 결선), ssh fork vs grep-poll 지배요소 판정(Wave 3 UDP-vs-상주SSH 선택 근거), E-STOP 물리완료 echo(경로 C SLO), Anbernic 로컬 자체계측(0 hop), TEL2 손실/Hz(>20% 승격 캘리브), §6 JSON 영속화 + CI를 라이브 경로로, loop_ms CLOCK_MONOTONIC 통일 검토.

## 8. 리스크

워치독 600/2500ms 토크유지·from_stream 전용 의미 절대 미약화(2500ms를 토크컷으로 '고치면' capturability 파괴) · seq_applied 파일경로 전진은 from_stream/m_last_seq/티어 미변경 · Wave 2/3 前 sendEmergencyStopNow nonisolated 필수 · UDP 전방명령 HW 미검증(SSH dedup 폴백·local_control·from_stream graceful degrade 검증) · D1 default-on은 진동 HIL 後·레이턴시와 분리 · 컨플레이션은 stop 미드롭 테스트 · @Published 게이트는 latch-age 소비자 확인·Instruments 前 win 미주장 · Anbernic 0 hop 경로에 NST-1/CP-1 이중계산 금지.
