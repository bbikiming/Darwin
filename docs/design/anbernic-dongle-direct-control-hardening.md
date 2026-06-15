# Anbernic RG G01 동글 직결 조종 — 안정성·반응성 업그레이드 플랜

- 일시: 2026-06-14
- 입력: 감사(`docs/reports/2026-06-14-anbernic-dongle-direct-control-audit.md`) + 코드 대조검증 + 외부표준/레이턴시 근거 + 4-렌즈 적대적 검수
- 범위(경로 체인): RG G01 2.4G 동글 → 로봇 USB → `GamepadPilot` → `WalkLabBrokerage` → ROBOTIS `Walking`
- 주요 파일: `firmware-patches/walklab-brokerage/{GamepadPilot.h,GamepadPilot.cpp,WalkLabBrokerage.cpp,WalkLabTransport.h,WalkLabTransport.cpp,tests/test_gamepad.cpp,tests/test_transport.cpp}`

> ✅ **구현 상태 (2026-06-14)** — Batch A/B/C 의 **호스트 테스트 가능·안전한 코드 전부 구현
> 완료**(host green: test_gamepad 257 · test_transport 188, 0 failures). 구현 보고서:
> `docs/reports/2026-06-14-anbernic-control-hardening-implementation.md`.
> - **완료(코드+호스트테스트)**: A1 ForceDisarm+재ARM 중립게이트, A2 노드소멸 단일 안전상태
>   +신선창 정렬(컴파일타임 불변식), B2 측보 정규화+구조적 불변식, B3 ARM idle timeout+TEL2
>   armed 노출. 매핑 함수·디코더·페일세이프·gait 수학·TEL2 포맷 전수 호스트 검증.
> - **완료(코드, 로봇빌드 게이트)**: A1 ForceDisarm 2경로 배선(TriggerEstopImmediate +
>   Switch/Mac flag-latch), B1-1단계 sleep(패드 present 시 20ms), TEL2 call-site. WalkLabBrokerage.cpp
>   는 Robot:: 프레임워크 의존이라 호스트 미컴파일 — 인스펙션 검증 + 온보드 빌드 게이트.
> - **보류(설계 판단)**: B1-2단계 eventfd/ppoll wake(1단계로 운동수행 임계 충족 — reader 루프
>   select() 무검증 변경 회피, 측정 후 재평가). C1 침묵임계 실측·단절매트릭스·M2M p95(실기 의존).
>   TEL2 armed UI 표시(Swift 콕핏 HUD — 별도 surface). 상세는 §7 + 구현 보고서.

---

## 0. 한줄 결론 + 방향 판정

**결론: 감사가 짚은 4개 핵심 결함(P0-1 sleep 지연·P0-2 외부 E-STOP이 ARM 미해제·P0-3 노드소멸 LB 분기·P1-1 측보 정규화)은 코드와 100% 정합하며 전부 채택한다. 단 P0-2·P0-3의 "권장 수정 범위"는 적대적 검수에서 불완전(Switch/Mac flag-only 경로 누락·active_source 게이트 결합 결함·auto-getup 확대 회귀)으로 판명되어 범위를 확대/수정해 시행한다. P0-1 최소안은 worst를 100→~20ms로 "축소"할 뿐 "제거"가 아니므로 2단계(eventfd wake)를 명세에 포함한다.**

**방향 판정 (냉정):** 옳다. 동글 직결은 카메라 홉이 없는 순수 입력→구동(M2M, motion-to-motion) 경로이며, 텔레오퍼레이션 문헌의 광범위한 합의는 (a) 100ms 초과 시 페이스·협응 강하게 저하, (b) sub-100ms에서 이미 운동수행 저하가 시작, (c) 50ms 이하가 고반응 동적 과제 가능 구간임을 보인다. 감사의 목표 **idle 첫 입력 p95≤40ms / worst≤60ms**는 이 M2M 구간에 대해 "보수적이고 타당"하다(인지 임계 200~300ms가 아니라 **운동수행 임계 ≤75ms, 이상 ≤50ms**를 적용해야 함 — JND가 수 ms대라 idle↔active 분기로 인한 ~80ms 지연 점프(지터) 자체가 절대지연 못지않게 해롭다). 안전 의미론 측면에서도 방향이 표준과 일치한다: ISO 13850:2015 §4.1.4–4.1.5("reset/해제는 재기동을 **허용**만 하고 그 자체로 재기동 금지", §4.1.2 latch 유지)는 P0-2를 직접 뒷받침하고, IEC 62745:2017(무선제어 link-loss는 **신호 부재 자체**가 정지 결정 — 마지막 버튼 상태 무관, ATS 상한 0.5s)는 P0-3를 직접 뒷받침하며, ISO 10218-1 Annex C + ISO/TS 15066(enabling-device 정석=hold-to-run)은 P1-3의 위계를 정한다. **단 ISO 10218/15066/3691-4/62745는 산업·협동·무인운반차 대상으로 DARwIn(비상업 호비 로봇, RG G01에 3-position 하드웨어 없음)에 법적 강제는 아니다 — best-practice/정석으로 적용하고 완화 여지를 명시한다.**

목표값은 **M2M(입력→구동) 예산**으로 명시 라벨링한다. 카메라 8080 MJPEG(~8fps≈125ms 프레임간격) 시각 피드백은 별도 **G2G(glass-to-glass) 예산**으로 분리 추적하며 M2M 예산에 합산하지 않는다.

---

## 1. 검증으로 확정/번복된 사실 요약표

| ID | 감사 주장 | 검증 판정 | 외부근거 | 검수에서 추가/번복 | 플랜 반영 |
|---|---|---|---|---|---|
| P0-1 | idle 첫입력 worst ~100ms (`sleep_ms=(walking_active\|\|local_fresh)?20:100`, `local_fresh`=HasControl≤1s) | **confirmed (high)** — 코드/상수 정확. CommandSlot에 wake 프리미티브 없어 구조적 보장된 지연 | 운동수행 임계 sub-100ms / 짧은폴 20ms는 worst를 주기로 한정 / eventfd wake로 μs급 | 최소안(a)은 100→~20ms "축소"일 뿐 "제거" 아님 → eventfd 2단계 필요. EINTR/shutdown_fd/balltrack 분기 미명세 | **채택, 2단계 구조** |
| P0-1 주석 | F11 주석 "첫 스틱 50ms→10ms" 의도 | **partially-correct** — 코드 주석엔 "→10ms" 없음("평균 50ms·최대 100ms"). "50→10ms"는 bringup 보고서(`2026-06-13-rgg01-bringup.md §4`) 표현 | — | 출처를 "F11 코멘트"→"F11 보고서"로 정정. 핵심관찰(20ms-when-fresh가 >1s 유휴 후 첫 이벤트 못 덮음)은 유효 | **출처 정정** |
| P0-2 | 외부 E-STOP이 `m_armed` 미해제. `TriggerEstopImmediate`는 물리정지+flag latch만. `ForceDisarm()` 추가 권장 | **confirmed (high)** — `m_armed=false`는 reader-thread B경로/AdoptDevice/HandleNodeLost 3곳뿐. ForceDisarm 심볼 부재. `m_mtx` thread-safe 기반 존재 | ISO 13850 reset≠restart 직접 뒷받침 | **권장 위치 불완전**: `TriggerEstopImmediate`는 UDP/B만 공유. Switch/Mac flag-only 정지는 supervisor L1154-1161 직접수행(미경유) → **flag-latch 블록에도 배선 필수**. auto-getup 확대(89행)는 회귀 → **제외**. 재ARM 직후 잔여스틱 재보행 차단 필요 | **채택, 범위 확대 + 재ARM 가드** |
| P0-3 | `HandleNodeLost`의 `!btn_lb`→enabled=0 즉시정지 라인. 버튼이 단절 정지방식 결정. 라인 미발행·②티어 슬루가 소유 권장 | **confirmed (high)** — codex P1 의도설계지만 LB-conditional이 정지방식 가름. 단순화 시 기존 테스트 2개(L540·L570-571) 깨짐 → 동시개정 필수 | IEC 62745 신호부재가 정지결정·버튼무관 직접 뒷받침. stop category 0/1 어휘 | **P1-2와 결합 결함**: 목표0 슬루가 `m_active_source==SRC_LOCAL` 게이트(L1325-1327)에 묶여, UDP/파일 선점 후 LB-held 노드소멸 시 stop라인 미발행+tier2 미발화 → latch된 보행이 WD_STOP(2.5s)까지 지속. node-lost 정지완료를 watchdog 2.5s에 위임 금지 | **채택, P1-2와 묶음 + 빠른 ramp 보장** |
| P1-1 | `GpGaitSchedule`이 y도 `GP_MAX_STRIDE_MM`(38)로 정규화. 풀스틱 측보 28/38=0.7368 과소. `yi=fabs(y)/GP_MAX_SIDE_MM` | **confirmed (high)** — 산수 재현 정확(586.9ms/35.8mm vs 560/40). 대각선 입력 무해(진폭 불변·clamp). GateSchedule은 이미 `ENVELOPE_Y_MAX`(28) 사용 | 비대칭 진폭은 축별 max로 정규화가 정석(Capture Steps/NimbRo). 측방 ZMP 마진 narrow-base로 sagittal보다 작음 | 진폭(28mm) 불변·foot는 기존 forward와 동일한 40mm로만 상향 → IK/낙상 신규위험 거의 없음("2단계 32 보류"와 무관). 기존 블렌드 테스트(L333-335)는 부등식이라 변화 둔감 → RED→GREEN 단언 신규 필요. L337 인자 y=38 도메인밖 정정 | **채택, low 등급** |
| P1-2 | `MaybeRefresh` 1.5s vs `HasControl` 1.0s 불일치. 1.0~1.5s 구간 pilot은 offer하나 supervisor drain만·UDP/파일 선점 | **confirmed (high)** — 상수 차이(1000 vs 1500) 정확. drain-only + UDP/파일 게이트(`!local_control`) | — | 2차효과: 선점 시 `m_active_source` 플립으로 local slew-zero failsafe 경로(L1326)도 무장해제 | **채택, P0-3와 묶음** |
| P1-3 | 데드맨 제거 후 ARM 무기한. `GP_ARM_IDLE_TIMEOUT_MS`/hold-to-drive, TEL2 armed 노출 | **confirmed (high)** — disarm 트리거는 estop edge뿐. idle-timeout 상수 부재. TEL2 armed 토큰 부재 | enabling-device 정석=hold-to-run(3-position). idle-timeout은 **완화책**(표준 등가물 아님). TEL2 armed 노출은 IEC 60204-1 §10.3 관찰가능성으로 **동반 필수** | idle-timeout이 킥(LB/RB는 `m_armed` 게이트) 셋업/정지대기 중 오발 disarm로 킥 조용히 폐기. 모든 입력축을 idle 활동으로 카운트 필요. 값은 실측 후 확정 | **채택, 완화책 명시 + 입력축 확장 + TEL2 동반** |
| P1-4 | `GP_SILENCE_SLEW_MS=1500` 설계값. 정속 직진 침묵 분포 미측정 | **confirmed (high)** — 경계는 호스트 핀(2599 NONE/2600 SLEW). 분포는 실기 계측 영역 | `max*2` 휴리스틱 위험. p999×안전계수 하한 + 검출지연 상한 양측제약. rule of three(3/n). IEC 62745 0.5s 대비 1500ms는 저하감지용 | 60초×6모드는 침묵임계 확정에 통계적 불충분. 정속 hold는 수 분~10분 장기측정 + 꼬리표본≥100 필요. node-lost 빠른경로와 위상분리 | **채택, 측정프로토콜 전면강화** |
| DOC | `handheld-direct-pilot-upgrade.md`(EVIOCGKEY/LB데드맨/RB터보/콕핏1:1), `implementation-prompts.md` P7 H1, `GamepadPilot.h` 상단주석 | **partially-correct** — 코드는 F12에서 폐기 완료(테스트 확인). 문서 본문/리스크표/P7-H1/헤더주석은 stale. `anbernic-gait-upgrade.md`는 outdated 아님(코드와 동기) | — | P7은 H2 최신·H1만 outdated(완료프롬프트라 우선순위 낮음). 헤더주석은 본문이 이탈 충실문서화 | **§6 문서정리** |

**번복/제외 항목(감사를 맹신하지 않음):**
- **(제외) auto-getup·자동 fall-recovery에 ForceDisarm 확대(감사 89행)** — 검수 high. auto-getup은 operator가 estop을 누른 게 아닌데 ARM이 조용히 풀려 킥/이동이 죽고, 재ARM 순간 잔여스틱 재보행 위험까지 생긴다. 낙상 후 무장유지가 위험하면 "낙상 후 첫 재보행은 새 enabled=1 필요"(이미 `last_stat` 캡처 L1209-1214로 구현)로 충분. **ForceDisarm은 operator/외부시스템이 명시적으로 정지를 의도한 경로(B·UDP·Switch/Mac flag)에만.**
- **(수정) P0-2 권장 위치** — `TriggerEstopImmediate`에만 넣으면 Switch/Mac flag-only 경로가 누락되어 감사가 든 바로 그 시나리오를 못 막는 자기모순. **flag-detected 정지 블록에도 배선.**
- **(수정) P0-3 "전면 슬루"** — 방향 채택하되 정지완료를 watchdog 2.5s에 위임 금지. node-lost는 즉시검출이므로 ramp도 빨라야(≤0.5s, IEC 62745 ATS 기준).
- **(정정) P1-4 `max*2`** — 표본의존 단일값이라 안정 백분위 아님. `p999×안전계수` 하한 + `검출지연 상한`으로 재정식화.

---

## 2. Batch 상세 (우선순위/배치 재정렬)

배치 원칙은 유지(A 안전 의미론 → B 반응성 → C 문서/실기게이트)하되, 검증·검수에 맞춰 **결합 결함을 한 PR로 묶고**, **호스트 검증 불가 항목은 실기 게이트로 분리**한다. 모든 코드는 **C++03 / POSIX**(`GamepadPilot.h:15` 제약). 불변성 원칙은 적용 불가 영역(임베디드 가변 상태 머신)이나, 상태 전이는 단일 책임 함수로 격리한다.

### Batch A — 안전 의미론 (P0-2 + P0-3/P1-2)

#### A1. ForceDisarm — 외부 E-STOP이 ARM 해제 + latch (P0-2)

- **(a) 무엇을:** `GamepadPilot::ForceDisarm()` thread-safe 신규 추가. 모든 **명시적** E-STOP 경로(UDP·Gamepad-B·Switch/Mac flag)가 `m_armed=false`로 latch. flag clear(=reset)는 재기동을 "허용"만 하고, 재보행은 새 A ARM(=의도적 start)을 거쳐야 함(ISO 13850 reset≠restart). **재ARM 직후 잔여/중립아닌 스틱으로 즉시 재보행 차단**(재ARM 후 첫 enabled=1은 중립→이동 신규 전이 요구).
- **(b) 어느 파일/함수:**
  - `GamepadPilot.h` — `public: void ForceDisarm();` 선언 + 재진입 불변식 주석.
  - `GamepadPilot.cpp` — `ForceDisarm()` 정의: `pthread_mutex_lock(&m_mtx); m_armed=false; m_rearm_requires_neutral_transition=true; pthread_mutex_unlock(&m_mtx);`. 재ARM 게이트는 `SettleArmed`/`MapGamepad`의 enabled 산출에 "중립 경유 플래그"를 반영.
  - `WalkLabBrokerage.cpp:746-769` `TriggerEstopImmediate()` — 본문에 `m_gamepad.ForceDisarm();` 추가(UDP/B 커버).
  - `WalkLabBrokerage.cpp:1154-1161` **flag-detected 정지 블록(estop_latched 진입 시점)** — `m_gamepad.ForceDisarm();` 추가(Switch/Mac flag-only 커버). **이 위치가 검수 high 핵심.**
- **(c) 왜:** ISO 13850:2015 §4.1.2/§4.1.4-4.1.5 — E-STOP latch 유지, reset이 재기동을 허용만. 현재는 flag 해제 순간 armed 잔존 → 잔여스틱/이벤트로 즉시 재보행(capturability/안전 critical). `m_mtx`로 `m_armed` 일관보호(`GamepadPilot.h:291`)되어 ForceDisarm 자체는 저위험.
- **(d) 리스크/회귀 가드:**
  - **재진입 데드락:** `TriggerEstopImmediate`가 reader-thread(B경로 `GamepadEstopTrampoline`)에서도 호출됨. 현재 estop_cb는 `ProcessEvent` unlock **후** 발화(L447-449)라 안전하나, ForceDisarm이 `m_mtx`를 잡으므로 "콜백은 락 밖에서만 호출" 불변식을 `GamepadPilot.h` 주석으로 고정. non-recursive mutex 가정 명시.
  - **킥 무력화 회귀:** 킥(LB/RB)은 `m_armed` 게이트(`GamepadPilot.cpp:436`). 명시적 E-STOP 후 disarm은 의도된 안전동작이므로 OK. **단 auto-getup 확대는 제외**(위 §1 번복).
  - **재ARM 잔여스틱:** ForceDisarm만으로는 reset≠restart의 절반만 충족. 재ARM 가드(중립 경유 요구) 미동반 시 A 누르는 순간 즉시 보행.
- **(e) 검증:**
  - 호스트 테스트(신규): `test_pilot_forcedisarm_clears_armed`(ForceDisarm 후 `ArmedForTest()==false`), `test_pilot_external_estop_no_walk_until_rearm`(ForceDisarm 후 held-stick 이벤트로 `TakeCommand` 라인 enabled=0), `test_pilot_rearm_requires_neutral`(재ARM 직후 치우친 스틱→enabled=0, 중립 경유 후 이동→enabled=1), `test_pilot_forcedisarm_reentrancy`(estop_cb 락 밖 호출 경로에서 데드락 없이 완료).
  - **실기 게이트(호스트 검증 불가 — Robot:: 의존):** Switch E-STOP(flag-only) 후 G01 스틱 유지 상태에서 Y/flag clear만으로 **재보행 안 함** 확인. UDP E-STOP·B버튼 동일. **host green만으로 완료 선언 금지.**
  - 목표 수치: 4개 명시적 E-STOP 경로(B/UDP/Switch flag/Mac flag) 전수에서 재ARM 전 이동라인 0건.

#### A2. 노드소멸 단일 안전상태 — LB 분기 제거 + 빠른 controlled-stop (P0-3 + P1-2)

- **(a) 무엇을:** `HandleNodeLost`의 `!btn_lb` 게이트 enabled=0 라인 발행을 **제거**, node lost는 PollFailsafe ②티어 슬루(controlled stop, IEC 60204-1 cat-1)가 **단일 소유**. 동시에 **P1-2의 1.0~1.5s 선점 창을 닫아** active_source 플립으로 tier2가 무장해제되는 결합 결함 제거. node-lost는 즉시검출이므로 ramp를 가속해 **진폭 0 도달 ≤0.5s 보장**(watchdog 2.5s에 위임 금지).
- **(b) 어느 파일/함수:**
  - `GamepadPilot.cpp:497-505` — `HandleNodeLost`: `m_armed=false`는 유지하되 `!m_snap.btn_lb` 분기의 `OfferCurrentLocked`(L503-505) 제거. node lost는 라인 미발행.
  - `GamepadPilot.h:129/132` — `GP_LOCAL_FRESH_MS`(1000)와 `GP_SILENCE_SLEW_MS`(1500) 정합: HasControl 창을 refresh 창과 정렬(`GP_LOCAL_FRESH_MS = GP_SILENCE_SLEW_MS = 1500`로 단일화). **또는** HasControl을 `m_last_offer_ms` 기반(refresh가 active offer 중이면 control 유지)으로 변경. 정합을 `static_assert`로 컴파일타임 강제.
  - `WalkLabBrokerage.cpp:1325-1327` — local slew-zero failsafe의 `m_active_source==SRC_LOCAL` 게이트가 선점 후 무장해제되지 않도록, node-lost 슬루는 active_source 무관하게 발화(또는 node-lost 감지 시 source를 SRC_LOCAL로 강제).
  - `WalkLabTransport.cpp` `SlewToward`/슬루 상수 — node-lost 전용 가속 ramp(0.5s 내 진폭 0) 경로.
- **(c) 왜:** IEC 62745:2017 — 무선 link-loss 시 정지는 **운전자 마지막 버튼 상태가 아니라 신호 부재 자체**가 결정. 현재 `!btn_lb`(구 데드맨 시절 LB) 분기는 표준 위반 패턴. ATS 상한 0.5s 대비 WD_STOP 2.5s는 5배 길어 전진 보행 중 단절 시 토크 유지가 위험(낙상 임박 자세에서 "걷던 관성+무명령").
- **(d) 리스크/회귀 가드:**
  - **기존 테스트 2개 깨짐(예상됨, 회귀가 잡힘):** `test_pilot_tier1_release_then_enodev`(L540 `c.enabled==0` 단언), `test_pilot_tier2_enodev_without_release`(L570-571 최종라인 발행 단언). 이 둘은 **동시 개정 필수**(라인 미발행 단언으로 수정). `test_pilot_tier2_enodev_deadman_held`(L593 라인 미발행)는 이미 제안방향과 일치 → 불변.
  - **graceful 단절 즉시정지 상실:** 스틱 중립에서 끊긴 케이스는 진폭 0 근처라 슬루든 즉시든 물리차 작음. 전진 중 끊김은 양쪽 다 슬루가 안전.
  - **stop category 라벨:** node-lost 슬루=cat-1(제어정지), 외부/B E-STOP=cat-0(즉시). 보행체 낙상 트레이드오프로 E-STOP을 cat-1(짧은 제어정지 후 토크차단)로 둘 경우 리스크평가 근거를 §실기보고에 기록.
- **(e) 검증:**
  - 호스트 테스트(개정+신규): `test_pilot_tier1_release_then_enodev`/`test_pilot_tier2_enodev_without_release` 라인 미발행으로 개정, `test_pilot_node_lost_button_independent`(btn_lb=0/1 양쪽에서 동일하게 라인 미발행), `test_local_fresh_silence_alignment`(`static_assert(GP_LOCAL_FRESH_MS==GP_SILENCE_SLEW_MS)` 또는 정합 단언), `test_supervisor_sim_preempt_window`(1.0~1.5s 창에서 UDP 선점 후 node-lost해도 slew-zero 발화 — supervisor 시뮬 harness 신규).
  - **실기 게이트:** 전진 풀스틱 보행 중 동글 뽑기 → 즉시 Stop이 아니라 **ramp-down 확인 + ramp 완료시간 측정(목표 ≤0.5s)**. LB held/release 양쪽에서 동일 거동.
  - 목표 수치: node-lost 후 진폭 0 도달 ≤0.5s(p95), 1.0~1.5s 선점창에서 continued-walk 0건.

### Batch B — 반응성 (P0-1, P1-1, P1-3)

#### B1. supervisor sleep — idle 첫입력 지연 제거 (P0-1, 2단계)

- **(a) 무엇을:**
  - **1단계(즉효):** `DevicePresent()` 또는 `m_armed`이면 유휴에도 20ms 루프 유지. worst 100→~20ms 축소.
  - **2단계(eventfd wake):** `GamepadPilot.OfferCurrentLocked()` 끝에 wake fd(self-pipe 또는 eventfd)에 write, supervisor sleep을 `ppoll({wake_fd}, timeout=20ms)`로 교체. wake-before-wait 유실 0(카운터/잔존바이트 흡수), worst를 컨텍스트 스위치(수십 μs)로. **idle↔active 지연 지터 제거.**
- **(b) 어느 파일/함수:**
  - 1단계: `WalkLabBrokerage.cpp:1409-1417` — `sleep_ms` 산출에 `m_gamepad.DevicePresent()` 또는 armed 조건 추가(`DevicePresent`는 `GamepadPilot.cpp:358-363`에 이미 존재, 신규 API 불요).
  - 2단계: `GamepadPilot.{h,cpp}` — wake fd 멤버 + `OfferCurrentLocked` 끝 non-blocking write(EAGAIN=성공 처리). `WalkLabBrokerage.cpp` supervisor 루프 — `ppoll`/`poll` 하이브리드(이벤트 wake로 즉시성, 20ms 타임아웃으로 주기 거버너/슬루/refresh-drain 보장). 전용 **shutdown_fd**를 poll 집합에 추가.
- **(c) 왜:** sub-100ms에서 이미 운동수행 저하. 짧은폴은 worst를 주기로 한정, eventfd wake는 μs급(IPC 벤치 signal 14.8 대비 eventfd 9.7, User-IPI=1.0 정규화). JND 수 ms대 → 지터 제거가 절대지연 못지않게 중요. **이식성:** 호스트 단위테스트(macOS)에서 동일 코드 검증하려면 self-pipe, 온보드 단독이면 eventfd. **eventfd ratelimit/지연 wakeup 옵션은 실시간 부적합 — 절대 사용 금지.**
- **(d) 리스크/회귀 가드:**
  - **EINTR:** `ppoll`이 시그널로 깨면 `continue`(재진입). 미명세 항목이므로 명시.
  - **graceful shutdown:** 종료를 또 하나의 wakeup 이벤트로 — shutdown_fd에 1회 write → supervisor가 한 주기(20ms) 내 깨어 **disarm+목표0 슬루 후 join**(부분 정리 상태로 join 금지). 폴링 플래그 단독 종료 금지.
  - **balltrack 분기:** balltrack ON이면 supervisor가 sleep을 건너뛰고 카메라 페이스(~30fps)로 돈다(`WalkLabBrokerage.cpp:1409 if(!m_balltrack_enabled)`). poll 분기와 카메라 페이스 분기의 상호배제를 명세. **즉 "보행+카메라+20ms idle 누적"은 동시 성립하지 않으므로 발열 우려는 balltrack OFF·미조종 좁은 구간 한정.**
  - **CPU:** 1단계 20ms idle 추가부하는 balltrack OFF·미조종 구간 한정(보행 중은 이미 20ms). load avg ~0.8-0.9 감당 가능.
- **(e) 검증:**
  - 호스트 테스트: `test_wake_before_wait_no_loss`(reader가 supervisor보다 먼저 wake fd에 write한 레이스를 인위 생성 → 카운터/잔존바이트로 흡수 확인), `test_shutdown_wake_drains`(shutdown_fd write → 한 주기 내 disarm+슬루0 후 join 타임아웃 테스트). **단 supervisor sleep cadence 자체는 Robot:: 의존이라 순수 호스트 harness 밖.**
  - **실기 측정:** §4 프로토콜로 idle 첫입력 M2M(evdev 커널 타임스탬프 → ApplyCommandLine, 동일 CLOCK_MONOTONIC) p50/p95/p99/max + 지터(p99-p50). balltrack ON/OFF 분리로 20ms idle 단독 기여분 격리.
  - 목표 수치: **idle 첫입력 M2M p95≤40ms, worst(p99 또는 max)≤60ms.** 1단계로 예산 충족, 2단계로 지터/CPU 추가 최적화.

#### B2. 측보 gait 강도 정규화 (P1-1)

- **(a) 무엇을:** `GpGaitSchedule`의 `yi`를 `GP_MAX_STRIDE_MM`(38)→`GP_MAX_SIDE_MM`(28)로 정규화. 순수 측보 풀스틱이 intensity 1.0(최속/최대 foot)로. **진폭(out->y=28mm)은 불변** — period/foot 스케줄만 보정. 불변식 `GP_MAX_SIDE_MM==ENVELOPE_Y_MAX`, `GP_MAX_TURN_DEG==ENVELOPE_A_MAX`를 `static_assert`로 컴파일타임 강제.
- **(b) 어느 파일/함수:** `GamepadPilot.cpp:198` `double yi = fabs(y_mm) / GP_MAX_SIDE_MM;`. `GamepadPilot.h`/`WalkLabTransport.h` 경계에 `static_assert`(별도 컴파일 단위라 공유 헤더 또는 빌드타임 체크).
- **(c) 왜:** 비대칭 진폭은 축별 max로 정규화가 정석(Capture Steps/NimbRo omnidirectional). GateSchedule은 이미 `ENVELOPE_Y_MAX`(28) 사용 → 두 경로 논리 일관. 측방 ZMP 마진이 narrow-base로 sagittal보다 작아, 측보 과소평가는 가장 취약한 축에서 foot clearance/속도를 깎음 → 발 끌림/측방 안정성 저하.
- **(d) 리스크/회귀 가드:**
  - 진폭 불변(28mm) — `out->y`는 MapGamepad에서 확정·`GovernEnvelope`가 `ENVELOPE_Y_MAX`로 최종 클램프. **"2단계 32로 올린다"는 오독 차단**(메모리 `anbernic-gait-upgrade` 2단계 보류와 무관).
  - foot 35.8→40mm는 기존 forward 풀스틱 foot이자 default(`GP_GAIT_FOOT_DEFAULT=40`) — 새 IK 영역 아님.
  - 대각선 입력: 풀스틱은 clamp 1.0이라 불변, 중간 대각선은 측 성분이 정당하게 강화(의도된 보정). `inten>1.0` clamp(L204)가 과부스트 방지.
  - **실보행 측방:** narrow-base ZMP는 실기 확인 필요(온스탠드 무해해도).
- **(e) 검증:**
  - 호스트 테스트(신규, RED→GREEN): `GpGaitSchedule(0, GP_MAX_SIDE_MM, 0, 1, ...)` → `CHECK_DEQ(period, GP_GAIT_PERIOD_MIN_MS)` (순수 풀-횡=강도 1.0=최속), `CHECK_DEQ(foot, GP_GAIT_FOOT_MAX_MM)`. **기존 블렌드 테스트 L337의 y 인자 `GP_MAX_STRIDE_MM`(38)→`GP_MAX_SIDE_MM`(28) 도메인 정정.** 기존 부등식 테스트(L333-335)는 변화 둔감하므로 등식 단언 추가.
  - 실기: 순수 측보 풀스틱에서 측방 낙상/발 끌림 없는지 크래들 외 실기 1회(측방 ZMP가 핵심 우려, foot 40mm 자체는 forward와 동일이라 IK 신규위험 낮음).
  - 목표 수치: 순수 측보 풀스틱 period=560ms·foot=40mm(전진 풀스틱과 동일 강도).

#### B3. ARM idle timeout + TEL2 armed 노출 (P1-3, 완화책)

- **(a) 무엇을:** `GP_ARM_IDLE_TIMEOUT_MS`(무입력 N초 후 auto-disarm) — **단, enabling-device 정석은 hold-to-run이고 idle-timeout은 완화책임을 명시**. idle 판정에 **모든 입력축**(이동·턴·머리·트리거·버튼) 활동 카운트. 값은 실측(§4) 후 확정, 그 전엔 보수적 ≥15s. TEL2에 `armed`/`estop-latched`/`active-source` 별도 필드 노출(IEC 60204-1 §10.3 관찰가능성, **동반 필수**). 재ARM 직후 잔여스틱 재보행 차단(A1과 한 쌍).
- **(b) 어느 파일/함수:** `GamepadPilot.h` — `GP_ARM_IDLE_TIMEOUT_MS` 상수 + `m_last_activity_ms`(모든 축 갱신). `GamepadPilot.cpp` — `PollFailsafe`/신규 `TickForTest` 경로에서 timeout 경과 시 `m_armed=false`. `WalkLabBrokerage.cpp:1678-1680` TEL2 — `armed`/`estop_latched` 토큰 추가.
- **(c) 왜:** ARM 무기한 유지는 데드맨 제거의 직접 귀결 — 유휴 중 우발 스틱 입력에 즉시 재보행. ISO 10218-1 Annex C/ISO/TS 15066 정석은 hold-to-run이나 RG G01에 3-position 없음 → idle-timeout이 약식 등가. armed는 "위험 동작 가능" 상태라 표준상 관찰 대상(TEL2/UI에 red/amber).
- **(d) 리스크/회귀 가드:**
  - **킥 오발 폐기:** 킥(LB/RB)은 `m_armed` 게이트(`GamepadPilot.cpp:436`). 이동축만 idle로 보면 킥 셋업 중 disarm → 킥 조용히 폐기(로그 미약). **모든 입력축 카운트로 차단.**
  - **값 근거 부재:** P1-4 분포 미측정 상태에서 짧은 값(3-5s)은 정상 휴지 오발, 긴 값(30s)은 안전이득 소멸. **실측 후 확정, 미확정 표기.**
  - 재ARM 직후 잔여스틱: A1 재ARM 가드와 공유.
- **(e) 검증:**
  - 호스트 테스트: `test_pilot_arm_idle_timeout`(ARM 후 N초 무입력 → `TickForTest`로 `m_armed=false` 전이), `test_pilot_kick_setup_not_idle`(킥 버튼 입력이 idle 타이머 리셋 → disarm 안 됨), `test_tel2_exposes_armed`(TEL2 문자열에 armed/estop_latched 토큰).
  - 실기: idle gap p99·정속 침묵 분포(§4) 측정 후 timeout 값 확정. TEL2 armed가 Mac/Switch/Ally UI에 red/amber로 표시되는지.
  - 목표 수치: timeout 값 = idle gap p99 + 안전마진(실측 후). 잔여위험(거치 중 스틱 오접촉 부분만 차단) 리스크평가 기록.

### Batch C — 문서/실기 게이트 (P1-4 측정 + 문서정리)

#### C1. 침묵 임계 측정·확정 프로토콜 (P1-4)

- **(a) 무엇을:** `GP_SILENCE_SLEW_MS` 확정용 측정. **정속 직진 hold를 수 분~10분 장기측정**(이벤트 침묵 모드, 갭 p999/max). 6모드(forward/side/turn full/half) 60초는 이벤트율 측정용으로 유지하되 침묵임계 근거로 사용 금지. 임계 = `max(정상 p999 × 안전계수 1.5~2, 검출요구 상한 미만)` 양측제약. 충돌 시 임계로 불가 → P1-3(idle-timeout/hold-to-drive)로 보강. ③티어 침묵(저하감지)과 node-lost 빠른경로(link-loss, IEC 62745 0.5s)를 위상 분리.
- **(b)/(c)/(d)/(e):** §4 측정 프로토콜 참조. node-lost heartbeat/EPOLLHUP 빠른경로가 진짜 link-loss 검출 담당, ③티어는 비상정지급 아님 명시.

#### C2. 문서 정리 (DOC)

- §6 참조. `handheld-direct-pilot-upgrade.md` 본문/리스크표 stale 정정, `implementation-prompts.md` P7-H1 정정(우선순위 낮음, 완료프롬프트), `GamepadPilot.h` 상단주석 1문장 보강. `anbernic-gait-upgrade.md`는 정정 불요(코드 동기).

---

## 3. 테스트 계획 (TDD)

**베이스라인:** `test_transport` 187 checks / `test_gamepad` 216 checks, 0 failures (재현 확인). 빌드: `cd firmware-patches/walklab-brokerage/tests && make clean && make` (Apple clang `-std=c++03 -Wall -Wextra -O0 -g -pthread`). 각 변경은 RED(실패 테스트 먼저)→GREEN.

| 작업 | 신규/개정 테스트 | RED 단언 | 비고 |
|---|---|---|---|
| A1 ForceDisarm | `test_pilot_forcedisarm_clears_armed` (신규) | ForceDisarm 후 `ArmedForTest()==false` | thread-safe |
| A1 외부estop | `test_pilot_external_estop_no_walk_until_rearm` (신규) | ForceDisarm 후 held-stick 라인 enabled=0 | reset≠restart 절반 |
| A1 재ARM | `test_pilot_rearm_requires_neutral` (신규) | 재ARM 직후 치우친 스틱→enabled=0, 중립경유 후→enabled=1 | reset≠restart 완성 |
| A1 재진입 | `test_pilot_forcedisarm_reentrancy` (신규) | estop_cb 락 밖 호출 경로 데드락 없음 | 콜백 unlock-후 불변식 |
| A2 node-lost | `test_pilot_tier1_release_then_enodev` (개정) | L540 `c.enabled==0` → **라인 미발행**으로 변경 | 회귀 잡힘 |
| A2 node-lost | `test_pilot_tier2_enodev_without_release` (개정) | L570-571 발행단언 → 미발행 | 회귀 잡힘 |
| A2 버튼무관 | `test_pilot_node_lost_button_independent` (신규) | btn_lb=0/1 양쪽 라인 미발행 동일 | IEC 62745 |
| A2 정합 | `test_local_fresh_silence_alignment` (신규) | `static_assert(GP_LOCAL_FRESH_MS==GP_SILENCE_SLEW_MS)` | 컴파일타임 |
| A2 선점창 | `test_supervisor_sim_preempt_window` (신규 harness) | UDP 선점 후 node-lost도 slew-zero 발화 | supervisor 시뮬 |
| B1 wake유실 | `test_wake_before_wait_no_loss` (신규) | reader 먼저 wake → 카운터 흡수 | self-pipe 이식성 |
| B1 종료 | `test_shutdown_wake_drains` (신규) | shutdown_fd write → 한 주기 내 disarm+슬루0 후 join | 타임아웃 테스트 |
| B2 측보 | `GpGaitSchedule(0,GP_MAX_SIDE_MM,0,1)` 단언 (신규) | `period==560 && foot==40` | RED→GREEN |
| B2 도메인 | 블렌드 테스트 L337 (개정) | y 인자 38→28 정정 | 도메인밖 수정 |
| B3 idle | `test_pilot_arm_idle_timeout` (신규) | N초 무입력 → `m_armed=false` | TickForTest |
| B3 킥보호 | `test_pilot_kick_setup_not_idle` (신규) | 킥 버튼이 idle 타이머 리셋 | 모든 축 카운트 |
| B3 TEL2 | `test_tel2_exposes_armed` (신규) | TEL2 문자열에 armed/estop_latched 토큰 | 관찰가능성 |

**호스트 검증 불가(실기 게이트로 분리):** ForceDisarm→TriggerEstopImmediate/flag-latch 통합 배선, supervisor sleep cadence, 모든 M2M 레이턴시 — 전부 Robot:: 프레임워크 의존. **host green만으로 완료 선언 금지.**

---

## 4. 측정·벤치 프로토콜

**측정 정의(M2M, 온보드 단일 클럭 이점):** M2M = `t_apply − t_evdev`. `t_evdev`=reader가 evdev `EV_SYN(SYN_REPORT)` read 직후 `clock_gettime(CLOCK_MONOTONIC)`. `t_apply`=supervisor가 그 입력 파생 라인을 `ApplyCommandLine` 적용한 시각(동일 MONOTONIC). 같은 호스트라 클럭 오프셋 0 → 차값이 진짜 M2M(차량 텔레오퍼레이션의 μs급 GPS 동기 불필요). `input_event.time`은 REALTIME일 수 있으니 read 직후 별도 MONOTONIC 타임스탬프 채취. **폴 간격(20/100ms)에 의존하지 않게 커널 타임스탬프를 t0으로.**

**wakeup latency 분리:** `wakeup_latency = t_wake − t_offer`(t_offer=pilot이 슬롯 offer+wake한 시각, t_wake=supervisor가 poll/ppoll에서 깬 시각). P0-1 개선 핵심 지표.

**유휴 첫입력 시나리오 강제:** (a) 패드 중립 1.5~3초 유지(유휴 진입) → (b) 단일 스틱 플릭 1회 → (c) t_evdev~t_apply 기록 → (d) 중립 복귀 → 반복 **N≥200(가능시 1000)**. 유휴 대기 0.5/1.0/1.5/2.0s 변주(분기 영향 관측).

**통계:** 각 조건 p50/p95/p99/p999/max + 히스토그램(평균만 보면 worst 누락). **모든 백분위에 95% CI**(이항 순서통계 또는 BCa 부트스트랩) 동반, 점추정 단독 금지. **지터(p99-p50) 별도 보고**(JND 수 ms대). p99 추정에 p99 위 표본 ≥100개(권장), 최소 N≥60, 극단·우편향 N≥120.

**Coordinated Omission 보정:** supervisor 폴링 구조라 느려진 순간 다음 적용이 밀려 worst-case가 체계적 누락(낙관 편향). HdrHistogram/wrk2식 CO 보정(기대 폴간격 20ms 대비). **CO 미보정 시 `worst≤60ms` 통과는 거짓일 수 있음.**

**침묵 임계(GP_SILENCE_SLEW_MS) 확정:** 정속 직진 hold를 **수 분~10분 장기측정**(갭 p999/max 추정, 꼬리표본 ≥100). 6모드 60초는 이벤트율용. 임계 하한=`정상 p999 × 안전계수(1.5~2)`, 상한=`허용 검출지연 미만`. **`max*2` 휴리스틱 폐기**(표본의존 단일값). 단절 매트릭스 4종(전원OFF/거리이탈/배터리탈락/동글뽑기) 각 **≥20회**로 검출침묵시간 분포 측정 → 상한 결정. 두 제약 충돌 시 임계로 불가 → P1-3 보강. **오발 0건이면 rule of three(95% CI 상한 3/n) 함께 보고**(n=1 금지).

**stop category 라벨링(IEC 60204-1):** 외부/B E-STOP=cat-0(즉시), node-lost 슬루=cat-1(제어). 보행체 낙상 트레이드오프로 E-STOP을 cat-1로 두는 결정은 리스크평가 근거 문서화.

**환경 고정:** 10분 연속 조종 중 카메라 8080 MJPEG 동시부하 **ON/OFF 양 조건**(20ms idle 단독 기여 격리). load avg·CPU·loop_ms·active_source·armed 동시 인터리브 로깅. **무선/유선 경로 고착(166x) 배제** — 동글직결 단독 경로 격리 측정.

**G2G 분리:** 카메라→화면 시각피드백은 같은 클럭으로 못 잼(포토트랜지스터/화면캡처 동시캡처 또는 GPS/PTP 2노드). M2M p95 게이트에 G2G 섞지 말 것.

---

## 5. 증거기반 완료 판정 체크리스트

**Batch A (안전 의미론):**
- [ ] A1: `test_pilot_forcedisarm_clears_armed`/`_external_estop_no_walk_until_rearm`/`_rearm_requires_neutral`/`_reentrancy` 4개 통과(실행 출력 첨부)
- [ ] A1 실기: **4개 명시적 E-STOP 경로(B/UDP/Switch flag/Mac flag) 전수**에서 재ARM 전 이동라인 **0건**, 스틱 유지 상태 flag clear만으로 재보행 **안 함**(host 검증 불가 → 실기 필수)
- [ ] A2: 개정 테스트 2개 + `_button_independent`/`_local_fresh_silence_alignment`/`_supervisor_sim_preempt_window` 통과
- [ ] A2 실기: 전진 풀스틱 보행 중 동글뽑기 → ramp-down(즉시 Stop 아님), **진폭 0 도달 p95 ≤0.5s**, LB held/release 동일. 1.0~1.5s 선점창 continued-walk **0건**
- [ ] 전체 회귀: `test_transport`/`test_gamepad` 0 failures(개정 반영 후 신규 카운트 기록)

**Batch B (반응성):**
- [ ] B1: `test_wake_before_wait_no_loss`/`test_shutdown_wake_drains` 통과
- [ ] B1 실기: **idle 첫입력 M2M p95 ≤40ms, worst(p99/max) ≤60ms**(N≥200, 95% CI, CO 보정, 지터 p99-p50 보고). balltrack ON/OFF 분리
- [ ] B2: 측보 단언(`period==560 && foot==40`) + 도메인 정정 통과
- [ ] B2 실기: 순수 측보 풀스틱 측방 낙상/발끌림 없음(크래들 외 1회)
- [ ] B3: `test_pilot_arm_idle_timeout`/`_kick_setup_not_idle`/`test_tel2_exposes_armed` 통과
- [ ] B3 실기: timeout 값 = idle gap p99 + 마진(실측 후 확정, 그 전 ≥15s 미확정 표기). TEL2 armed가 UI에 red/amber 표시

**Batch C (측정/문서):**
- [ ] C1: 정속 hold 장기측정(갭 p999/max, 꼬리표본 ≥100) + 단절 4종 각 ≥20회 → `GP_SILENCE_SLEW_MS` 양측제약 확정(또는 P1-3 보강 결정). rule of three 보고
- [ ] C1: 모든 정지경로 stop category(0/1) 라벨 + cat-1 트레이드오프 리스크평가 기록
- [ ] C2: 문서 정리 완료(§6 체크)

**금지:** "잘 작동할 것" 추측성 완료. **필수:** 테스트 통과 수·실기 측정 수치·CI를 증거로 제시. **host green ≠ 완료**(ForceDisarm 통합·레이턴시는 실기 게이트).

---

## 6. 문서 정리

- **`docs/design/handheld-direct-pilot-upgrade.md`** (본문 stale — 헤더 박스는 폐기 안내하나 원문 미수정):
  - L150 H1-1 "EVIOCGKEY 1s 상태 폴 병행" → 삭제(코드 `GamepadPilot.h:131` 생존판정 금지)
  - L153/L155/L66/L191 "콕핏 1:1·LB=데드맨·RB=터보" → F10/F12 의미론(데드맨 해제·LB/RB=킥·터보 제거)으로 정정
  - L248 리스크표 "EVIOCGKEY 폴" → "노드 소멸(ENODEV) 감지", L187 H2-2 동일
- **`docs/design/implementation-prompts.md`** P7 (우선순위 낮음 — 완료 프롬프트):
  - L214-216 H1 매핑 "LB=데드맨, RB=터보, A=ARM" → F10/F12 반영(H2 섹션 L222-241은 이미 최신)
- **`GamepadPilot.h`** 상단 헤더주석(L5-8) + 섹션표제(L77, L175): "콕핏 RG G01 프리셋 1:1" → "콕핏 1:1 (단 F10/F12로 데드맨 해제·LB/RB=킥·터보 제거 이탈)" 1문장 보강(본문은 이탈 충실문서화됨)
- **`docs/design/anbernic-gait-upgrade.md`**: 정정 불요(side28/turn18/SLEW_DA6/SUM1.25가 코드와 완전 일치, 2단계 32/20 보류도 일치)
- **신규 산출물:** 실기 측정 후 `docs/reports/2026-06-XX-dongle-direct-control-hardening.md`(M2M 히스토그램·CI·침묵분포·단절매트릭스·stop category 리스크평가)

---

## 7. 열린 질문 / 실기 의존 항목

1. **ForceDisarm 통합 경로 검증 불가성:** TriggerEstopImmediate→m_gamepad.ForceDisarm()·flag-latch 배선은 Robot:: 의존이라 호스트 harness 밖. **Batch A 완료는 실기 통합검증(Switch E-STOP 후 스틱 유지 재보행 불가) 없이는 선언 불가.**
2. **GP_SILENCE_SLEW_MS 확정 불가(측정 의존):** 정속 직진 침묵 분포 미측정. 정상 hold가 임계만큼 침묵 가능하면 임계로 해결 불가 → hold-to-drive/idle-timeout 필요. **임계 vs 검출지연 양측제약이 충돌하는지 실측 전엔 미정.**
3. **측방 ZMP 안정성(P1-1):** foot 40mm는 forward와 동일이라 IK 신규위험 낮으나, narrow-base 측방 ZMP 마진은 실보행 1회 확인 필요.
4. **eventfd vs self-pipe 선택:** 온보드 단독이면 eventfd, 호스트 테스트 이식성 필요하면 self-pipe. 1단계(20ms idle)로 예산 충족되면 2단계 우선순위 재평가.
5. **stop category cat-1 결정:** 보행체 E-STOP을 즉시 무전원(cat-0)으로 두면 낙상→손상. cat-1(짧은 제어정지 후 차단)이 정당하나 리스크평가 근거 문서화 의무.
6. **누락 사각지대(검수 completeness 렌즈, 본 플랜 범위 밖이나 추적 필요):**
   - 동글 절전(~10분 무입력)→USB 재열거(input 8→9)→재획득→재ARM 복구 경로 전체(실측 `2026-06-12-rgg01-usb-probe.md §5-2`). **5번째이자 가장 흔한 단절 트리거.**
   - 머리(헤드 팬/틸트)가 보행과 동일 라인·동일 게이트(local_control·100ms sleep·1.0~1.5s 선점창)를 맞음. head 레이트제어 dt 적분(`GamepadPilot.cpp:243-251`, dt cap 200ms)이 100ms stall 후 각도 점프(lurch) 유발 가능.
   - 다중 소스 우선순위가 "local 신선도 단일 임계의 이진 절벽"일 뿐 명시적 소유권 상태머신 부재 — P0-2/P1-2/P1-3 공통 근본원인.
   - `arm_edge`가 SYN_REPORT 커밋에서만 반영(`GamepadPilot.cpp:427-430`) → SYN 유실 시 이월/늦은 무장.
   - 배터리 voltage sag 게이트가 cm730 NULL 폴백에서 `vdV=0`(unknown)으로 무력화(`WalkLabBrokerage.cpp:1615`) — 동글직결 온보드 단독 경로 sag 보호 주체 불명.
   - 서보 과열 hot-skip 재ARM 시 torque 복원 보류 → "ACK≠물리거동"(F9 류) 재현 가능(킥/측보 반복 시).
7. **DARwIn 비강제성:** ISO 10218/15066/3691-4/62745는 산업·협동·무인운반차 대상 — 법적 강제 아님(best-practice 적용, 완화 여지 confidence와 함께 명시).
