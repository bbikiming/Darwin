# 콕핏 조종 — 레이턴시/비효율 고도화 설계 (Cockpit Latency Hardening)

> 2026-06-11 · 멀티에이전트 코드 리뷰(서브시스템 정밀 독해 6 + 적대적 검증 2-vote) 결과.
> 이슈 후보 58건 → **확정 35건 · 기각 22건(실재하나 임팩트 낮음) · 이견 1건**.
> 본 문서는 확정 이슈에 대한 설계만 다룬다. 구현 전 각 항목은 별도 PR 로 분할한다.

## 0. 결론 요약

체감 레이턴시의 지배 항목은 코드 4곳에 집중돼 있다:

1. **안전(critical)**: 게임패드/DJI E-STOP 이 하드웨어 정지 체인에 미배선 — HUD 깜빡임만 발생.
2. **온보드(SSH) 경로**: 명령 1회 = 신규 `ssh` subprocess + 인라인 ACK 폴(≤1.5s 점유) →
   실효 송출률 ~4–8Hz, 입력→로봇 유선 250–600ms.
3. **RunLoop `.default` 모드 타이머**: 메뉴/리사이즈 트래킹 중 30Hz 시뮬·입력·E-STOP 감지 전면 동결
   → stale 보행 명령이 수 초 지속.
4. **bus(USB/TCP) 경로**: 보행 핫루프·포즈 송출이 관절별 개별 write(+status 왕복)
   — 이미 구현돼 있는 SYNC_WRITE(`setPositions`) 미사용, 그리고 MainActor 동기 FFI 블로킹.

권장 순서는 §4 의 Wave 0→3. Wave 0(안전 배선 + `.common` 모드 + periodMs 정합)은 각각 독립
1일 미만 패치이고, Wave 1(PersistentSSHChannel 허브)이 가장 큰 공사이자 가장 큰 체감 개선이다.

## 1. 현재 아키텍처 (확인된 데이터플로)

```
[입력]                          [시뮬/상태 — 전부 MainActor]            [실모터]
게임패드 30Hz 폴(legacy) ─┐
프로파일 드라이버 30Hz ───┤   CockpitState.apply()                 ┌─ bus 모드: freeform task 가
  (가상패드만, 실패드 미배선)│     └ lastCommand (@Published, 즉시)   │   phase(80–117ms)마다 MainActor 홉
DJI HID ≤100Hz(이벤트) ───┼─▶ 30Hz Timer integrate()              │   → SYNC_WRITE 1패킷 (leg)
키보드(auto-repeat+모니터)─┤     └ EMA α=0.25 → motorCommand       │   ※ 단 WalkCycleEngine/pose 경로는
마우스 가상스틱 60–120Hz ─┘   .onChange(motorCommand)              │     관절별 개별 write — 비일관
                              → dispatchRealMotorIfAllowed ────────┤
                              → WalkLabSession.pilotApplyFreeform  └─ 온보드 모드: OnboardSendQueue
                                                                       (1-in-flight, 코얼레싱 없음)
[텔레메트리] SSH cat 폴 5Hz(UDP 정상이어도 상시) + UDP push           → 명령마다 신규 ssh exec
[카메라] MJPEG .unbounded 스트림, 프레임 스킵 없음                      + 원격 50ms-grep ACK 폴 ≤1.5s
[모바일] WebSocket relay — walk 프레임 conflation 없음                 → 로봇 데몬 100ms 파일 폴
```

측정 근거가 없는 추정치(유선 100–250ms/명령 등)는 §6 계측 도입 후 실측으로 대체한다.

## 2. 확정 이슈 카탈로그 (35건)

### P0 — 안전 (즉시, 각각 독립 패치)

| # | 이슈 | 위치 | 심각도 |
|---|------|------|--------|
| S1 | 컨트롤러(게임패드/드라이버/DJI) E-STOP·복구가 하드웨어 정지 체인 미배선 — `emergencyAt` 소비자 0 | `CockpitControllerDriver.swift:107` | critical |
| S2 | 컨트롤러 끊김 failsafe 미구현 — stale 비-zero 스틱 명령 무기한 잔존 | `CockpitControllerDriver.swift:141` | high |
| S3 | 모바일 E-STOP 이 `accepted` 네트워크 송신을 await 한 뒤 torque-off — TX 포화 시 정지가 인질 | `MobileRelayServer.swift:655` | high |
| S4 | E-STOP 이 `Bus.serialLock` 뒤에서 대기 가능 — 타임아웃 중 read 가 200ms–수초 지연 | `Bus.swift:304` | high |
| S5 | 온보드 E-STOP 이 공유 ControlMaster SSH 에 의존 — WiFi stall 시 ~4–9s 지연 가능 | `ConnectionStore.swift:1529` | high |

### P1 — 체감 레이턴시 지배항

| # | 이슈 | 위치 | 심각도 |
|---|------|------|--------|
| L1 | SSH 명령마다 신규 subprocess spawn (ControlMaster 는 핸드셰이크만 절약) | `SSHShell.swift:252` | high |
| L2 | 조종 명령 1건당 인라인 ACK 폴링이 SSH exec 를 ≤1.5s 점유 → 실효 4–8Hz | `RobotSetupCommand.swift:587` | high |
| L3 | 30Hz 시뮬/입력 타이머·IOKit 전부 `.default` 런루프 모드 — 트래킹 중 동결 | `CockpitState.swift:195`, `CockpitGameControllerWatcher.swift:51` | high |
| L4 | 프로파일 드라이버 런타임 미배선 — 실패드는 legacy 하드코딩, 매핑창 열림 시 30Hz 이중 주입 flapping | `PilotCockpitView.swift:974` | high |
| L5 | 보행 핫루프(WalkCycleEngine)가 관절별 개별 WRITE — SYNC_WRITE 구현돼 있는데 미사용 | `WalkLabSession+WalkCycleEngine.swift:129` | high |
| L6 | `applyPoseSmoothly` MainActor 동기 FFI — 컨텍스트 60 read + step당 40 write 가 메인스레드 정지 | `ConnectionStore.swift:1278` | high |
| L7 | 연결/재연결 MainActor 블로킹 — TCP connect ≤3s + snapshot 4왕복, 죽은 호스트면 ~10s UI 동결 | `ConnectionStore.swift:658` | high |

### P2 — 지터/낭비/정합 (23건, 발췌)

| # | 이슈 | 위치 |
|---|------|------|
| J1 | 유휴에도 틱당 ~8–10개 @Published 무조건 발행 → 1698줄 뷰트리 30Hz 상시 재렌더 | `CockpitState.swift:293` |
| J2 | 머리 디스패치: MainActor 동기 round-trip 2–4회, SYNC_WRITE 미사용 | `PilotCockpitView.swift:1162` |
| J3 | 콕핏 periodMs(600–850) vs `mobileFreeformClamp`(440–700) 불일치 — 스로틀 하반부 무효 | `CockpitState.swift:483` |
| J4 | `sendStep` 고정 sleep — write 시간·MainActor 홉 미보상, cadence 지터 | `WalkLabSession+MobileFreeform.swift:366` |
| J5 | `RemoteShell.history` @Published 무한 누적 + 명령당 3회 publish | `RemoteShell.swift:97` |
| J6 | UDP 정상이어도 SSH 폴러 5Hz 영구 동작 + 루프 드리프트(고정 200ms sleep) | `ConnectionStore.swift:1881`, `OnboardTelemetryPoller.swift:101` |
| J7 | 무선 고착: `switchToWalk` 가 직전 host 무조건 상속 — 유선(≈166×) 자동 재평가 없음 | `ConnectionStore.swift:1825` |
| J8 | `SSHShell.run` waitUntilExit 후 pipe read — 출력 64KB 초과 시 교착 | `SSHShell.swift:297` |
| J9 | MJPEG `.unbounded` + 프레임 스킵 없음 — 조종 영상이 점점 과거로 밀림(stale-view) | `MjpegStreamingClient.swift:230` |
| J10 | 모바일 walk 프레임 conflation 없음 — taskChain 에 stale stick 누적 (iOS 측 10Hz 스로틀 주석은 거짓) | `MobileRelayServer.swift:829` |
| J11 | TCP 경로 매 패킷 전 `drain_input` 고정 ~2ms 대기 | `tcp.rs:84` |
| J12 | `read_state` 관절당 READ 3왕복 — burst read(addr 24..43, 20B)로 1/3 가능 | `control/mod.rs:149` |
| J13 | FTDI latency timer 미설정 — 기본 16ms 버퍼링이 모든 status 왕복에 가산 가능 | `posix.rs:50` |
| J14 | 키보드 250ms 자동해제 vs OS 초기 리피트 지연(~400–500ms) 경합 — hold 시작 stop-go 스터터 | `CockpitState.swift:575` |
| J15 | DJI watcher 가 pause 중에도 ~100Hz @Published 발행 + prevActions 매번 재구성 | `DJIVirtualJoystickWatcher.swift:146` |
| J16 | 레거시 RC 브리지: 보행 중 amplitude 변경마다 220ms 디바운스 후 `startWalk` 재호출 | `WalkLabSession.swift:1556` |
| J17 | 폴러·조종 명령·e-stop 이 동일 RemoteShell/MainActor 직렬화 지점 공유 | `RemoteShell.swift:18` |

이견 1건: `OnboardSendQueue` 1-in-flight 무코얼레싱(stop 우선순위 없음) — Wave 1 의
`SendPolicy.latestWins` 도입으로 자연 해소되므로 별도 추적 불필요.

기각 22건(예: 디스패치 핫패스 JSON recorder, EMA 시정수 자체, TeleopChannel arm 개별 토크 등)은
"코드상 실재하나 실효 임팩트 낮음" 판정 — 필요 시 검증 노트 원본 참조.

## 3. E2E 레이턴시 버짓 (목표 SLO)

| 경로 | 목표 | 비고 |
|------|------|------|
| A. 입력 → 시뮬 화면 반영 | p50 ≤ 25ms · p95 ≤ 50ms | `.common` 적용 전제. 폴 샘플링 33ms + integrate 5ms + 1프레임 |
| B. 입력 → 실로봇 적용 (freeform) | 유선 p50 ≤ 100ms · p95 ≤ 150ms / 무선 p95 ≤ 400ms | Wave 1 후. phase 양자화(playMs floor 80ms)가 구조적 하한 |
| C. E-STOP → torque-off | **최악 기준** bus ≤ 60ms / 온보드 유선 ≤ 300ms / 무선 stall ≤ 1s (UDP 병행) | 현행 무선 stall ~4–9s. 데드맨 ≤6s 는 최후 방어선 유지 |
| D. 머리 조종 (bus 직결) | 입력 → write 완료 p95 ≤ 70ms | 50ms 스로틀 + SYNC_WRITE 1패킷 |

경로 C 는 평균이 아니라 worst-case 로만 판정하며, E-STOP 경로에 스로틀·배칭류 "최적화"는 금지.
회귀 임계: 버짓의 120% 2회 연속 (도입 첫 주는 관측만, 이후 임계 확정).

## 4. 로드맵 — 4 Wave

### Wave 0 (독립 · 즉시 · 병렬 가능, 각 1일 미만)

1. **S1 — 컨트롤러 E-STOP 배선** (`PilotCockpitView`): 기존 `ballTrackingToggleAt` 패턴 미러링.
   ```swift
   .onChange(of: cockpit.emergencyAt) { _, v in if v != nil { cockpitEmergencyStop() } }
   .onChange(of: cockpit.recoveryAt)  { _, v in if v != nil { cockpitRecover() } }
   ```
   드라이버 E-STOP edge 에서 `state.release()` 추가. 후속 명령 차단은 기존
   `dispatchRealMotorIfAllowed` 게이트가 담당(드라이버 측 latch 불요). 모든 입력원(버튼·키·
   게임패드·DJI)을 `triggerEmergency()` 단일 진입점으로 통일하는 리팩토링은 별도 커밋.
2. **S2 — disconnect failsafe**: `CockpitState.inputSourceLost()`(이동·머리 zero 주입) 신설,
   드라이버 `handleConnectionChange(false)`/legacy watcher `bind(nil)`/DJI onDisconnect 3경로 배선.
   `profile.failsafe` 기본값 `.freeze → .stop` 변경. zero 주입은 기존 디스패치 체인을 타므로
   auto-disarm(dwell 2s)이 자연 발동.
3. **S3 — 모바일 E-STOP 순서 역전**: `handleEstop` 에서 `sendCommandAccepted` 를
   fire-and-forget `Task` 로 분리 — torque-off 가 첫 실행 라인이 되게.
4. **L3 — RunLoop `.common`**: `CockpitTimers.repeating(_:_:)` 유틸 신설
   (`Timer` 생성 후 `RunLoop.main.add(t, forMode: .common)`, 콜백은 `MainActor.assumeIsolated`).
   적용 5곳: CockpitState integrator, ControllerDriver, GameControllerWatcher, DJI mock/진단.
   DJI HID 는 `IOHIDManagerScheduleWithRunLoop` mode 를 `commonModes` 로. legacy watcher 의
   B 버튼은 `pressedChangedHandler` 이벤트 등록으로 폴링 양자화(평균 16.7ms)도 제거.
5. **J3 — periodMs 정합**: 콕핏 throttle→periodMs 매핑 범위를 실모터 clamp(440–700)와 일치.
   화면(walkAnimator)·게이지·실모터가 동일 값을 쓰는 기존 불변식 유지(§5.6).
6. **계측(§6) Tracer 골격** 을 이 Wave 에 함께 — 이후 Wave 효과를 수치로 확인하고 진행.

### Wave 1 (전송 계층 허브 — 온보드 경로)

신설 `actor OnboardCommandChannel` (Connection/):

```swift
actor OnboardCommandChannel {
  enum Transport { case persistentSSH(Process)   // ssh host 'exec sh -s' 상주 + stdin 줄단위
                   case udp(NWConnection) }       // E-STOP 병행 채널 (17372)
  func send(_ cmd: OnboardCommand, policy: SendPolicy) async throws -> Ack?
  // SendPolicy: .latestWins(key:) — 같은 key 의 미송신 명령 대체 (freeform tuning)
  //             .ordered        — estop/모드전환: conflation 금지, 순서 보존
  func sendEmergencyStopNow()    // 큐 우회, 양 transport fire-and-forget
}
```

구성 요소(상세 §5.4):
- **PersistentSSHChannel**: 상주 ssh 1개, stdin 으로 명령, stdout sentinel
  (`__DF_DONE_<id>_<exit>__`)로 응답 구분. 명령당 fork/exec 0. 실패 시 기존 `SSHShell.run` 폴백.
- **ACK 분리(fire-and-confirm)**: write 는 즉시 반환(`WROTE_<id>` 만 확인), ACK 는 500ms 배치
  confirm 루프 — 자동폴백 카운터는 기존 로직과 공유. 단발 명령(모드 전환)은 동기 ACK 유지.
- **UDP E-STOP 병행(S5)**: 페이로드 `DF-ESTOP v1 <token> <unixMillis>` ×3연발(0/50/100ms),
  토큰은 세션 시작 시 SSH 로 로봇에 프로비저닝. 로봇 측 리스너는 기존 flag-poll 메커니즘 재사용.
  SSH 확인 경로(`bypassMux: ControlMaster=no`)와 *병행* 발사 — 먼저 닿는 쪽 승리, SSH 가 확인 책임.
- 로봇 데몬에 `--stdin` 모드 추가(파일 폴 제거, 읽는 즉시 적용+ack). 기능 플래그
  `df.onboard.persistentChannel` 로 공존 기간 운용.

이 Wave 로 L1·L2·J5(범위 축소)·J17·이견 1건이 함께 닫힌다. 채널 단절 시 로봇 데드맨을
stdin EOF 즉시-정지로 강화.

### Wave 2 (시리얼/bus 계층 — Wave 1 과 병렬 가능)

순서: (a) **L5 SYNC_WRITE 전환** → (b) **J11+J12** Rust 최적화 → (c) **L6/L7/J2 SerialIOActor**
→ (d) **S4 E-STOP 락 선점**. (a)가 락 점유를 12배 줄여 (d)의 긴급도가 내려가므로 (a) 먼저.
상세 §5.2–5.3.

### Wave 3 (MainActor/뷰 정리 — Wave 1·2 효과 측정 후)

J1 @Published 변화-가드, J5 RemoteShell silent send+링버퍼, J6 적응형 폴러, J7 유선 probe 배너,
J8 파이프 선행 드레인, J9 MJPEG 코얼레싱, J10 모바일 conflation, J14 키보드 타이머,
J15 DJI 발행 다이어트, J16 RC 브리지 freeform 통일, L4 드라이버 일원화.

## 5. 테마별 설계 상세

### 5.1 안전 — E-STOP 4중 보강

- **S1/S2**: Wave 0 참조. 핵심 불변식 — onChange 는 같은 MainActor 틱 내 동기 전파(홉 추가 0),
  디바운스 없음. `suspendInjection`(매핑창) 중에도 E-STOP resolve·발화는 통과시킨다(필수 구현 노트).
- **S3**: actor 직렬화 특성상 accepted TX 는 `port.emergencyStop` 의 첫 await suspension 사이에
  실행 — iOS "즉시 표시" UX 유지하며 순서 보장만 해제.
- **S4 — Bus E-STOP 패스트패스**: forge-core `Bus` 에 `estop_requested: AtomicBool` 추가.
  Swift `emergencyStop()` 이 락 획득 *전에* `fc_bus_request_estop_preempt()` 호출 → recv 루프가
  read_exact 슬라이스(50ms)마다 플래그 체크해 `EstopPreempted` 로 조기 abort → 락 해제 →
  e-stop 이 정상 락 획득 후 torque-off 송출. abort 잔여 바이트는 송출 전 input flush 1회.
  백그라운드 리더는 `EstopPreempted` 를 무음 skip 으로 분류. 최악 대기 200–250ms → ~50ms.
  3계층(Rust/FFI/Swift) 변경 + `make headers` 필요.
- **S5**: Wave 1 UDP 병행 채널 참조. spoofing 은 토큰으로 차단(피해가 있어도 '불필요 정지' = fail-safe).

### 5.2 시리얼/FFI — SYNC_WRITE 일원화 + 메인액터 탈출

- **L5 — 보행 핫루프**: `sendStep` 의 관절별 write 루프를 `bus.setPositions(changedTargets)`
  1패킷으로. per-joint status 상실은 N step 마다 하체 대표관절 라운드로빈 PING liveness 로 대체
  — 기존 안전 임계(`lowerBodyDistinctFailureThreshold` 등) 분기는 입력 신호원만 교체.
  prologue/exit 의 setMovingSpeed 20회는 `fc_joint_set_moving_speeds_many` FFI 신설로 1패킷.
  TCP 경로 step당 12왕복 36–72ms → <8ms 목표.
- **L6 — applyPoseSmoothly**: 버스 I/O 만 `nonisolated static` 함수로 추출해 `Task.detached`
  실행, 카운터는 `struct ApsStepOutcome` 값 반환으로 MainActor 집계(불변성 원칙).
  transport 오류는 하체 전체 실패로 보수적 매핑해 기존 분기 우선순위 보존.
  watchdog 의 `checkCriticalLoad → bus.emergencyStop` 직호출 경로 불변.
  호출처(TeleopChannel/PilotDpad/IntentDispatcher 등) 시그니처 불변 — 무수정.
- **L7 — 연결 비블로킹화**: `openBusAndSnapshot(endpoint:) async` detached 헬퍼.
  기존 generation 가드가 stale 결과 폐기. USB endpoint 는 동시 open 충돌 방지 위해 직렬화.
- **J2 — 머리 SYNC_WRITE**: `ConnectionStore.writeHeadPose(panRaw:tiltRaw:freshSession:)` —
  `headDispatchTask` cancel 코얼레싱 + detached 에서 `setPositions` 1패킷.
  50ms 스로틀·보행 중 pendingHead 버퍼 분기는 유지.
- **J11**: `drain_input` 을 nonblocking peek 으로 — 빈 버퍼면 즉시 반환(수십 µs),
  stale byte 감지 시에만 기존 2ms grace drain (misalignment 방어 보존).
- **J12**: `read_state` 를 addr 24..43 단일 20B READ 로 (3왕복 → 1). FFI/Swift 무변경.
  BULK_READ 일괄화는 CM-730 펌웨어 실기 검증 후 별도 PR.
- **J13**: macOS `IOSSDATALAT` ioctl 로 FTDI latency 1ms 설정(미지원 어댑터는 no-op).
- **락 경합 상한**: `fc_bus_set_io_timeout` 신설 — 보행 시작 시 read timeout 200→50ms,
  종료 시 복원. 직렬화 락 자체(v1.11 안전장치)는 절대 제거하지 않음.

### 5.3 입력 — 단일 writer 원칙

- **L4 — 드라이버 일원화**: `GCControllerSource` 런타임 배선으로 실패드도 프로파일 경로
  (데드존/expo/데드맨/터보)로 통일. 매핑창 열림 시 `injectionSuspended` 로 단일 writer 보장
  (suspend 진입 시 `inputSourceLost()` 1회). legacy watcher 는 한 릴리스 deprecated 보존 후 제거.
  주의: `.xbox` 데드맨 기본 ON 이 실패드에 처음 집행 — 릴리스 노트/HUD 안내 필요.
- **J14 — 키보드**: 백스톱 250→800ms(keyUp 유실 대비용일 뿐 — 정상 해제는 monitor 담당),
  monitor keyDown 으로 타이머 재무장, 이미 hold 중인 키의 auto-repeat 는 발행 생략.
- **J15 — DJI**: pause 가드 선행, UI 용 @Published 는 15Hz throttle 분리, prevActions 캐시,
  동일 스틱값(0.005 양자화) 재주입 생략. E-STOP 류 버튼 액션은 코얼레싱 제외.

### 5.4 네트워크/텔레메트리

- **L1 — PersistentSSHChannel**: §4 Wave 1. `RemoteShell.send` 내부에서 채널 ready 시 사용,
  실패 시 기존 spawn 경로 동기 폴백(E-STOP 에 추가 대기 없음). 대출력 명령(배포 로그)은 기존 경로.
- **L2 — fire-and-confirm**: §4 Wave 1. ACK 배치 확인 지연(≤1s)은 텔레메트리 stale
  watchdog(1.5s)이 별도 안전망.
- **J5**: `sendSilently`(history 미기록·무발행, harness 기록 유지) + history 500건 링버퍼
  (index 갱신은 UUID 기반으로 교체). `activeChannel` 도 값 변경 시에만 set.
- **J6**: deadline 기반 폴 루프(`ContinuousClock`, 드리프트 제거) + UDP 신선(<0.75s) 시
  1Hz 백오프 — UDP 단절 시 1사이클 내 5Hz 복귀라 stale 강등 플랩 없음.
  `ingestOnboardTelemetry` 에 `source: .sshPoll|.udpPush` 분리 필요.
- **J7**: 자동 전환이 아닌 **probe-and-prompt** — 무선 연결 중 60s 주기로 유선(123.1)
  reachability probe, 가용 시 배너 "유선으로 전환(166×)" 원클릭 제안. 마법사의
  'silent fallback 금지' 정책 보존.
- **J8**: `readabilityHandler` 기반 PipeCollector(NSLock)로 자식 생존 중 지속 드레인 —
  64KB 교착 제거, 타임아웃 시 부분 출력도 보존.
- **J9**: MJPEG 프레임 코얼레싱 — 버퍼에 다음 완성 프레임이 있으면 이전 것 drop, 최신 1장만
  디코드. 표시 지연 상한 ≈ 1 프레임 처리시간. `droppedFrameCount` 관측 추가.
  "낮은 fps 의 현재 영상 > 높은 fps 의 과거 영상" — 텔레옵 안전 개선.
- **J10**: iOS `ExternalControllerAdapter` 에 터치 경로와 동형의 latest-wins 10Hz 송출 루프
  (거짓 주석 정정 포함) + Mac relay 측 walk 타입 server-side conflation(슬롯 1개).
  `pilot.estop/stop` priority bypass 는 conflation 명시 제외.

### 5.5 시뮬/렌더

- **J1 — 2단계**: ① `setIfChanged(keyPath:value:)` 가드로 integrate() 의 무조건 대입 전부 교체
  + peak 감쇠 버그(`peakHoldUntil` nil 미리셋 → 영구 발행) 동시 수정. 디스패치는 이미 .onChange 가
  dedupe 하므로 의미 불변. ② 측정 후 필요 시에만 30Hz 표시값을 `CockpitSimReadout` 으로 분리
  (HUD/SceneView 만 구독) — 회귀 면적이 커서 ①의 Instruments 측정이 정당화할 때만.

### 5.6 dispatch 보완 설계 (워크플로 누락분 — 본 문서에서 직접 설계)

- **J3 — periodMs 정합**: `CockpitState` 의 throttle→periodMs derive 식의 출력 범위를
  `WalkMotionLibrary.mobileFreeformClamp` 의 실효 범위(440–700ms)와 단일 상수원
  (`WalkMotionLibrary.freeformPeriodRange`)으로 통일. 시뮬 walkAnimator·속도 게이지·실모터가
  같은 값을 쓰는 기존 불변식("화면=게이지=실모터") 유지. 검증: 스로틀 0..1 전 구간에서
  derive 값 ∈ clamp 범위 단위 테스트 + 게이지 표시 속도와 dispatch 값 동등성 테스트.
- **J4 — sendStep deadline 타이밍**: 고정 `sleep(playMs)` 를 deadline 기반으로 교체 —
  `nextStepAt = max(nextStepAt + playMs, now)` 후 `Task.sleep(until:)`. write 소요·MainActor 홉
  시간이 자동 보상돼 cadence 지터 제거. phase floor 80ms 는 유지(보행 안정성 파라미터).
  E-STOP/cancel 체크 포인트는 step 경계 그대로.
- **J16 — RC 브리지 freeform 통일**: 레거시 `pilotApplyAmplitude`(220ms 디바운스 후 `startWalk`
  전체 재시작) 경로를 `pilotApplyFreeform` 의 tuning 갱신 경로로 위임 — 보행 재시작 없이
  파라미터만 갱신. 콕핏이 이미 freeform 경로를 쓰므로 잔존 호출처(MobileRelay 구버전 프로토콜)만
  마이그레이션 후 amplitude 경로 deprecated.

## 6. 레이턴시 계측 — PilotLatencyTracer

신설 `Pilot/Instrumentation/PilotLatencyTracer.swift` (~250줄):

- `mark(_ point: Point, seq: UInt32)` — lock-free ring buffer(4096) + `mach_absolute_time`,
  **할당·포맷팅·락 0** (계측이 대상을 오염시키지 않음). `os_signpost` 병행 발행.
- 지점 7개: `inputSampled → stateIntegrated → dispatchDecided → channelEnqueued → channelSent
  → ackReceived → simRendered`. `seq` 는 입력 이벤트 correlation id — dispatch payload 에 실려
  로봇 ack 에 echo.
- **E-STOP 전용 mark 2개는 `enabled` 무시하고 항상 기록** — 안전 회귀 상시 감시.
- 회귀 게이트: `LatencyBudgetRegressionTests` — 가상 컨트롤러로 300 이벤트 주입 +
  LoopbackTransport(고정 5ms 목) → input→channelSent p95 가 코드-경로 버짓 초과 시 실패.
  CI(macos-14) 매 PR. 네트워크 변동 배제를 위해 임계 2배 마진.
- 노출: HUD 디버그 오버레이 1Hz(p95 input→sent), 세션 종료 시
  `~/Library/Application Support/DarwinForge/latency/` JSON 1줄 append.

## 7. 안전 불변식 체크리스트 (전 항목 공통)

- [ ] E-STOP 경로에 디바운스/스로틀/추가 비동기 홉 금지 — 본 설계의 모든 E-STOP 변경은
      홉 *제거* 또는 병행 채널 *추가* 방향만.
- [ ] 코얼레싱(latest-wins)은 freeform tuning 류에만 — estop·모드전환은 `.ordered` 강제.
- [ ] 보행↔관절편집 모드 배타는 기존 모드 스위처가 계속 관장 — 전송 계층은 운반만.
- [ ] PilotSafetyGate/ARM 게이트 로직 미접촉 (E-STOP 은 게이트 우회 — 정지는 항상 허용).
- [ ] Bus 직렬화 락(v1.11) 제거 금지 — 보유 시간 상한만 축소.
- [ ] Swift 테스트는 직렬 실행 전제 (UserDefaults 공유 키) — 신규 키 `df.latency.*`,
      `df.onboard.persistentChannel`, `df.walklab.asyncAck` 동일 주의.
- [ ] 실기 검증 시 하드웨어 안전 수칙: 크래들 거치 + 다리 토크 해제 + 배터리 차단 스위치.
