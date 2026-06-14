# Anbernic RG G01 동글 직결 조종 하드닝 — 구현 보고서

- 일시: 2026-06-14
- 설계: `docs/design/anbernic-dongle-direct-control-hardening.md`
- 감사: `docs/reports/2026-06-14-anbernic-dongle-direct-control-audit.md`
- 범위: `firmware-patches/walklab-brokerage/` (온보드 C++03/POSIX 브로커리지·파일럿)

## 0. 결론

Batch A/B/C 의 **호스트 테스트 가능하고 안전한 코드는 전부 구현·검증 완료**. 증거:

```
firmware-patches/walklab-brokerage/tests $ make
=== 188 checks, 0 failures ===   (test_transport — 187→188, FormatTel2 armed)
==  257 checks, 0 failures ==    (test_gamepad  — 216→257, +41 하드닝 단언)
```

`-std=c++03 -Wall -Wextra` 무경고. 회귀 0(기존 단언 전수 통과, 변경분만 재작성).

방향 판정(감사 재검증): 감사 4핵심 결함 전부 코드와 일치(confirmed). 외부표준이 지지 —
ISO 13850(reset≠restart)→A1, IEC 62745(link-loss 버튼무관)→A2, ISO 10218/15066(enabling-device
정석=hold-to-run, idle-timeout 은 완화책)→B3. 단 감사 **3건은 적대적 검수로 정정**해 시행:
(1) ForceDisarm 위치를 Switch/Mac flag-latch 경로까지 확대, (2) P0-3↔P1-2 결합 결함은
active_source 게이트를 건드리지 않고 **신선창 정렬**로 근본 차단(게이트 제거는 "유휴 패드가
네트워크 보행을 멈추는" 회귀라 거부), (3) auto-getup 으로의 ForceDisarm 확대 제외(회귀).

## 1. 구현 항목과 증거

### Batch A — 안전 의미론

| 항목 | 변경 | 파일·함수 | 검증 |
|---|---|---|---|
| **A1** ForceDisarm | 외부 E-STOP 이 GamepadPilot ARM 도 latch-해제(thread-safe) + 재ARM 중립 게이트(잔여 스틱 즉시 재보행 차단) | `GamepadPilot.{h,cpp}`: `ForceDisarm()`·`Armed()`·`m_rearm_requires_neutral`·`OfferCurrentLocked` 게이트·B경로 latch | host: `test_pilot_forcedisarm_clears_armed`·`_external_estop_no_walk_until_rearm`·`_rearm_requires_neutral`·`_reentrancy` |
| **A1** 배선 | 모든 명시적 E-STOP 경로가 ForceDisarm 호출 | `WalkLabBrokerage.cpp`: `TriggerEstopImmediate`(UDP/B) + **flag-latch 진입(Switch/Mac flag-only)** | 인스펙션 + 로봇빌드 게이트(host 미컴파일) |
| **A2** 노드소멸 단일 안전상태 | 버튼(LB) 조건 stop-line 발행 제거 — 모든 노드 소멸은 ②티어 슬루가 정지 단일 소유 | `GamepadPilot.cpp`: `HandleNodeLost` | host: `test_pilot_node_lost_button_independent`·tier1/tier2 재작성·`_button_held` |
| **A2** 신선창 정렬(P1-2) | `GP_LOCAL_FRESH_MS`=`GP_SILENCE_SLEW_MS`(1500) 단일화 — 1.0~1.5s 선점 구간 제거. 컴파일타임 typedef-assert | `GamepadPilot.h` + `WalkLabBrokerage.cpp` active_source 게이트 주석 | host: `test_local_fresh_silence_alignment` + 정렬 단언 |

### Batch B — 반응성

| 항목 | 변경 | 파일·함수 | 검증 |
|---|---|---|---|
| **B1-1단계** sleep | 패드 연결(DevicePresent) 시 유휴도 20ms — idle 첫입력 worst 100→~20ms | `WalkLabBrokerage.cpp` sleep_ms | 인스펙션 + 로봇빌드 게이트(M2M p95 는 실기 측정) |
| **B2** 측보 정규화(P1-1) | `GpGaitSchedule` yi 분모 `GP_MAX_STRIDE_MM`(38)→`GP_MAX_SIDE_MM`(28) — 순수 좌우 풀스틱 강도 0.7368→1.0. 진폭 불변(스케줄만) | `GamepadPilot.cpp` + `GamepadPilot.h` 구조적 불변식(`GP_MAX_SIDE_MM`=`ENVELOPE_Y_MAX`) | host: `test_gait_schedule` 순수측보 full/half 단언 + 도메인 정정 |
| **B3** ARM idle timeout | 무입력(이동/턴/머리/버튼) ≥15s → auto-disarm(+중립게이트). 데드맨 완화책 | `GamepadPilot.{h,cpp}`: `GP_ARM_IDLE_TIMEOUT_MS`·`m_last_activity_ms`·`MaybeRefresh` | host: `test_pilot_arm_idle_timeout`·`_kick_setup_not_idle` |
| **B3** TEL2 armed | `FormatTel2` 말미에 `{armed} {estop_latched}` append(forward-compat — 파서 `count>=N` 관용) | `WalkLabTransport.{h,cpp}` + `WalkLabBrokerage.cpp` call-site(`Armed()`/`EstopRequested()`) | host: `test_format_tel2_*` 3종 갱신 + armed 토큰 단언 |

### Batch C — 문서/측정

| 항목 | 변경 | 검증 |
|---|---|---|
| **C2** 문서 정리 | `handheld-direct-pilot-upgrade.md` 현행화 배너(EVIOCGKEY/데드맨/터보/1:1 폐기), `implementation-prompts.md` P7 매핑 폐기 주석, `GamepadPilot.h` 헤더주석 정정 | 인스펙션. `anbernic-gait-upgrade.md` 는 코드와 동기(변경 불요) |
| **C1** 측정 프로토콜 | 설계 §4 에 M2M(evdev 커널 타임스탬프→ApplyCommandLine)·CO 보정·N≥200·p999·rule-of-three·단절 4종 ≥20회 정의 | **실기 의존**(코드 측정 계측은 로봇 빌드 — 미실행) |

## 2. 핵심 설계 판단(감사·플랜 대비 정련)

1. **active_source 게이트 보존(A2)**: 감사/검수는 "node-lost 슬루를 active_source 무관 발화"
   를 제안했으나, 그 게이트는 "유휴 패드가 Mac/Switch 네트워크 보행을 정지"시키는 회귀를
   막는 의도적 설계다. **신선창을 1500ms 로 정렬**하면 신선 중 UDP/파일이 게이트아웃되어
   active_source 가 SRC_LOCAL 을 유지 → 신선 중 노드 소멸은 항상 `local_fs_slew=true`. 즉
   게이트를 건드리지 않고 결합 결함을 근본 차단. (플랜 §7 이 예견한 정련.)

2. **idle-timeout 활동 모델(B3)**: 활동은 `ProcessEvent` SYN 커밋의 의도적 입력(이동의도·
   머리 데드존밖·버튼 보유)에서만 갱신 — 스틱 데드존 노이즈는 제외(거치 중 드리프트로 무장
   유지 안 됨). 정속 hold(이벤트 침묵)는 1.5s 에 ③티어가 이미 슬루-제로하므로, 15s
   idle-timeout 발화 시점에 로봇이 "능동 보행 중"인 경우는 없다(false-disarm-while-driving 회피).

3. **재ARM 중립 게이트(A1)**: `ForceDisarm`/B-estop 후 `m_rearm_requires_neutral` 설정 —
   재ARM(A) 해도 스틱이 중립을 한 번 거치기 전엔 `enabled` 억제. 머리/킥은 비영향(킥은
   fresh 버튼 rising 필요라 잔여 위험 없음). ISO 13850 "reset 은 재기동 허용만" 의 완성.

## 3. 호스트 검증 불가(실기/로봇빌드 게이트) — 미완 항목

다음은 **코드 미작성이 아니라 이 환경에서 검증 불가**라 실기 게이트로 분리:

- **A1 통합**: `m_gamepad.ForceDisarm()` 의 TriggerEstopImmediate/flag-latch 배선은
  `WalkLabBrokerage.cpp`(Robot:: 의존)라 호스트 미컴파일. **로봇 온보드 빌드 + 실기 게이트**:
  Switch E-STOP(flag-only) 후 G01 스틱 유지 → Y/flag clear 만으로 재보행 안 함. UDP/B 동일.
- **B1**: supervisor sleep cadence·M2M 레이턴시(idle 첫입력 p95≤40ms/worst≤60ms)는 실기 측정.
- **C1**: `GP_SILENCE_SLEW_MS` 확정용 정속 hold 장기측정(p999/max)·단절 매트릭스 4종(≥20회)·
  stop category 라벨 리스크평가. (설계 §4 프로토콜 — 코드 계측 미배선.)
- **B1-2단계(eventfd/ppoll wake)**: 1단계가 운동수행 임계를 충족하므로 보류 — reader 루프
  select() 무검증 변경(EINTR/shutdown_fd/balltrack 분기)은 안전 임계라 측정 후 재평가.
- **TEL2 armed UI 표시**: 펌웨어 노출은 완료, Swift 콕핏 HUD 색규약(IEC 60204-1 §10.3) 표시는
  별도 surface(`app/ui` CockpitHUD) — 파서는 forward-compat 라 무중단.

## 4. 완료 판정(증거 기반)

- [x] host: `make -C firmware-patches/walklab-brokerage/tests` green — **445 checks, 0 failures**
- [x] A1 ForceDisarm + 재ARM 중립 게이트(4 테스트) · 2경로 배선(인스펙션)
- [x] A2 노드소멸 버튼무관 단일 거동 · 신선창 정렬(컴파일타임 불변식 + 런타임 테스트)
- [x] B2 순수 측보 풀스틱 period 560·foot 40(전진 풀스틱 동일) · 구조적 불변식
- [x] B3 ARM idle timeout · 킥셋업 비-idle · TEL2 armed 노출
- [x] C2 문서 폐기전제 배너/주석(EVIOCGKEY/데드맨/터보/1:1)
- [ ] **실기 게이트(미완 — HW 의존)**: M2M p95, 외부 E-STOP 재보행 불가 통합검증, 침묵임계 확정,
      단절 매트릭스, stop category 리스크평가 → §3 참조

본 보고서는 코드/호스트 단계 완료를 기록한다. "동글 직결 조종이 충분히 안정적·빠릿하다"는
최종 선언은 §3 실기 게이트 통과 후에만 가능하다(증거 기반 완료 원칙).
