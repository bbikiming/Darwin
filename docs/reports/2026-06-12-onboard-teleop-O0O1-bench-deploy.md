# Onboard Teleop O0·O1 + Latency W1 — 벤치/배포 절차 (P3)

> 2026-06-12 · P3 구현(코드+테스트) 완료. 본 문서는 ① O0 벤치 기준선 측정 절차,
> ② 실기 배포 절차(demoBuildPatched), ③ 합격선 벤치를 정의한다. **코드는 완성·검증됐고
> 실기 배포·벤치 전에 멈춘 상태** — 아래 절차는 크래들 안전 수칙 하에서 수행한다.

## 0. 안전 전제 (CLAUDE.md / 설계 §6)

- 크래들(maintenance stand) 거치 + **다리 토크 해제** + **배터리 차단 스위치 상비**.
- 각 단계 전 E-STOP 리허설 1회(UDP 버스트 + 파일 플래그 양 경로).
- 워치독/거버너 상수는 보수값으로 시작, 단계 통과 후에만 완화.

## 1. 구현 범위 (이번 커밋에서 완료된 것)

| 항목 | 위치 | 검증 |
|---|---|---|
| O0 — TEL `≥11` + `{last_cmd_id} {loop_ms}` | `OnboardTelemetry.swift`, 브로커리지 `WriteTelemetry` | swift `OnboardTelemetryO0Tests` 7건 |
| O0 — 클럭 오프셋 EWMA | `Connection/RobotClockSync.swift` | swift `RobotClockSyncTests` 6건 |
| O0 — tracer ackReceived/7지점 mark | `PilotLatencyTracer.swift` | swift `PilotLatencyTracerTests` (+6건) |
| W1 — OnboardCommandChannel(actor) + PersistentSSHChannel + UDP E-STOP + SendPolicy | `Connection/OnboardCommandChannel.swift`, `OnboardCommandWire.swift` | swift `OnboardCommandWireTests` 12건 · `LatencyBudgetRegressionTests` 3건 |
| O1 — 순수 transport 로직(슬롯·워치독·파서) | `firmware-patches/walklab-brokerage/WalkLabTransport.{h,cpp}` | 호스트 C++ `tests/` 58 checks |
| O1 — 브로커리지 UDP 리스너 + supervisor 20ms + 워치독 티어 | `WalkLabBrokerage.{h,cpp}` | 호스트(순수 부분) + 실기(통합) |
| 핸드셰이크/포트 단일 출처 | `DFConnectionConstants`(17372/17374) ↔ `/tmp/df-walklab-channel` | `walkLabWriteChannelHandshake` |

**테스트 증거(이번 세션 실행):** 호스트 C++ `make -C firmware-patches/walklab-brokerage/tests`
→ `58 checks, 0 failures`. `cargo test --workspace` → 382 passed. 타깃 `swift test`
(O0/O1/W1 5개 스위트) → 41 passed, 0 failures. `swift build` → 0 errors.

## 2. 실기 배포 절차 (멈춤 지점 — 사용자 수행)

> 로봇 온보드 PC 에서 컴파일된다(Atom N2600, C++03). 새 파일 2개(WalkLabTransport.cpp/.h)가
> 추가됐으므로 **소스 복사 + 재빌드**가 필요하다.

1. **소스 동기화(SMB `~/.df_inbox` 또는 SCP)** — demo 폴더(`/robotis/Linux/project/demo/`)로:
   `WalkLabBrokerage.cpp`, `WalkLabBrokerage.h`, `WalkLabTransport.cpp`, `WalkLabTransport.h`,
   `install-onboard.sh`, `Makefile.patch`, `balltrack.ini`.
2. **재빌드**: `bash install-onboard.sh` — OBJECTS 에 `WalkLabTransport.o` 자동 추가(멱등),
   `demo`(=demo-pilot) 재컴파일. 빌드 로그 `build.log` tail 확인(0 errors).
   - 앱 내 자동배포 경로(`demoBuildPatched`, `RobotSetupCommand.swift:932-1034`)도 동일 효과 —
     단, **새 파일 2개가 배포 대상에 포함되는지 확인** 필요(install-onboard 의 존재 검사 목록은
     이미 갱신됨).
3. **핸드셰이크 프로비저닝(선택 — UDP transport 활성)**: Mac 세션 시작 시
   `RobotSetupCommand.walkLabWriteChannelHandshake(token:…)` 로 `/tmp/df-walklab-channel` 기록.
   없으면 파일 폴 단독으로 동작(폴백 영구 보존 — 기능 저하 없음). 기능 플래그
   `df.onboard.persistentChannel` 로 Mac 상주 SSH 경로 공존 운용.
4. **회귀 확인(배포 직후, 무부하)**: walklab 진입 → TEL 라인에 12·13번째 토큰
   (`last_cmd_id`/`loop_ms`)이 붙는지, 구버전 Mac 파서도 깨지지 않는지(≥11 완화 선배포 전제).

## 3. 벤치 — 기준선(O 이전) + 합격선(이후) (설계 §5)

| 측정 | 방법 | O 이전 기대 | 합격선 |
|---|---|---|---|
| 명령 실효율 | 10s 스틱 흔들기, 로봇 ACK 카운트/s | 4–8Hz | **O1: ≥20Hz** |
| 입력→로봇 적용 | tracer `inputSampled→ackReceived(t_rx)` p95 | 0.4–1.5s | O1: ≤120ms(유선) |
| E-STOP→walking=0 | UDP 발사 시각 − TEL walking 플래그 전환 | ≤220ms(유선) | **O1: p95 ≤60ms·최악 ≤150ms** |
| 통신 두절 | 케이블 분리 | 최대 5s 유령 보행 | **O1: 0.6s 제자리 → 2.5s 정지**(워치독 티어) |
| loop 주기 | TEL `loop_ms` 표본 | ~100ms | 보행 중 ~20ms |

E-STOP·워치독은 평균이 아니라 worst-case 로 판정. 도입 첫 주는 관측만(임계 미적용).

## 4. 멈춤 사유 / 다음 단계

- **로봇 미연결** 상태이므로 §2 배포·§3 벤치는 미수행. 본 커밋은 코드·호스트/Mac 단위
  테스트까지 완결.
- 다음: 사용자가 로봇 전원 + 크래들 거치 후 §2 배포 → §3 벤치(특히 ≥20Hz·E-STOP p95 ≤60ms)
  → 합격 시 P4(O2 거버너) 착수. 벤치 결과를 본 문서 §3 표에 실측치로 채운다.
