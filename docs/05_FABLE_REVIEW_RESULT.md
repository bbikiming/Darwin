# 05 — 리뷰 결과 기록부 (Fable Review Result)

> `04_REVIEW_CHECKLIST.md` 검수 결과의 누적 원장. 항목당 1절, 최신이 위.
> Fable = Claude(Fable 5) 검수, Codex = OpenAI Codex 교차 검수. 둘 중 하나 이상 필수.

## 기록 양식

```
## [P#] 제목 — 판정 (날짜)
- 구현 커밋: / 리뷰어: Fable | Codex | both
- A 안전: 통과/이슈 · B 계약: · C 품질: · D 절차:
- 발견 이슈: (심각도, 내용, 수정 커밋)
- 실기 보류 항목: (로봇 연결일 벤치로 이월된 것)
```

---

## [P4] 온보드 O2 — 거버너·twist v2·슬루·밸런스 결선 — **통과 (재검 완료)** (2026-06-12)

- 최종 커밋: `39a613b`(구현) + `54e6246`(교차 리뷰 수정 2건)
- **재검 결과 — 이슈 2건 모두 수정 확인**:
  - [HIGH] 루프 측 슬루 전진: supervisor 루프 블록(브로커리지 815-822) —
    `walking_active && !SlewAtTarget && SlewCadenceDue` 시 1스텝 전진 + 공용
    `WriteShapedCommand` 재적용(게이트 부스트를 보관된 m_tgt_foot/hip/flags 로 재계산 —
    명령 도착 경로와 일관). cadence 판정은 순수 함수 `SlewCadenceDue` 로 양쪽 공유,
    `SlewAtTarget`(ε=1e-6, valid 가드)이 워치독 0-동기화 시 자연 no-op ✓
  - [MEDIUM] Y_SWAP base: Run 진입 시 `walking->Y_SWAP_AMPLITUDE` 1회 캡처(632행,
    >0 가드 + DEFAULT 폴백) — config.ini 튜닝 보존 ✓
- 재검 독립 재실행: 호스트 C++ **142체크 0실패**(125→142, +17 — cadence/at-target/
  루프 진행 시나리오) · Swift 11/11 (풀 스위트 3,472/0 은 구현 세션 증거 인정)
- 계약 §G.8 개정 동일 커밋(+11줄) ✓
- 실기 이월: k_x/k_y/k_a 벤치 보정 + 스텝 응답 ≥30% 단축 확인 (로봇 연결일).
  Mac 송출 v1 유지(serializedLineV2 게이팅)는 배포 순서상 올바름.

### 1차 리뷰 기록 (조건부 — 수정 전, 이력 보존)

- 구현 커밋: `39a613b` · 리뷰어: **Fable 교차**(별도 세션)
- 증거(리뷰 세션 독립 재실행): 호스트 C++ **125체크 0실패**(63→125) ·
  `WalkLabO2TwistSerializerTests` 11/11 (풀 스위트 3,472/0 은 구현 세션 증거 인정)
- 잘된 점: 거버너가 **v1 방언에도 동일 적용**(853-857행 — Switch 50mm 본래 목적 충족),
  밸런스 게인을 BASE_* 헤더 상수 × 배율로 계산(누적 발산 구조적 차단), 구형 방언의
  blevel 기본 2(×1.0 — 밸런스 OFF 회귀 없음), 정지→보행 전환 시 슬루 0 재시드
  (첫걸음 capturability), 순수 로직 분리 관례 준수.
- **밸런스 결선 편차 — 검수 승인**: 프롬프트의 "benable→BALANCE_ENABLE" 직결 대신
  blevel 단일 소스(배율>0=ON). 근거 타당 — 배포 Mac benable 기본 0 직결 시 매 명령이
  밸런스를 꺼 종전 always-on 대비 **낙상 회귀**. 설계의 "blevel 단일화" 방향과 일치,
  계약 §G.8·코드 주석에 근거 명시 확인.
- **이슈 1 (HIGH — 머지 전 수정 필수)**: **루프 측 슬루 전진 부재** — `SlewToward` 가
  `ApplyCommandLine`(새 명령 도착 시)에서만 호출되고 `m_tgt_*` 는 저장만 됨(857행,
  루프 소비 0). 파일 경로 클라이언트(Mac 브리지 dedup·키보드 정확값)는 단발 명령 후
  재송신이 없어 **진폭이 첫 슬루 스텝(예: 0→38 명령 시 8mm)에 영구 고착**. UDP 스트림
  (연속 송신)에서만 정상 램프. 수정: supervisor 루프에 슬루 진행 블록 —
  `walking_active && 목표≠슬루현재 && half-period 경과` 시 SlewToward + 셰이핑 재적용
  (게이트 부스트 포함 — m_tgt_ 에 foot/hip/flags 보관 또는 적용 함수 분리).
  cadence 판정을 순수 함수로 빼 호스트 테스트 추가.
- **이슈 2 (MEDIUM — 수정 권고)**: `Y_SWAP_AMPLITUDE = 상수 20.0 + boost` 로 매 명령
  덮어씀(893행) — 로봇 config.ini 의 튜닝값이 20 과 다르면 실거동 변경. Walking 초기값을
  Run 진입 시 1회 캡처해 base 로 사용 권고.
- 실기 이월: k_x/k_y/k_a 벤치 보정, 스텝 응답 ≥30% 단축 확인. Mac 송출 v1 유지
  (serializedLineV2 게이팅)는 올바른 순서 — 미패치 로봇 오파싱 방지.

## [P11+P12] 머지 확정 (2026-06-12) — **3D 트랙 전 웨이브(W0~W5) 완료**

- P12 커밋: `62d18e6`(feat ① — W3 수렴 명시 포함, 검수 확인) · `26e9df4`(docs ②)
- P12 풀 스위트의 결정적 실패 1건은 **P3 귀책**(O0 ≥11 완화 vs 레거시 12토큰 거부 테스트
  — P12 세션의 "P9 귀책" 추정은 부정확하나 진단은 정확) → 검수 세션이 계약 결정
  (파서가 옳음, contract §A.3) 후 테스트 갱신 `ef559c0` (12토큰=lastCmdId 수용·14+ 무시).
- P11 머지: `b3906f9` — 충돌 5파일 해소(MeshRig=main 채택(superset 확인),
  ViewportControls/Studio/Motion=W3+W4 union(showCinematic+overlayStore 공존),
  README=union). 워크트리 /tmp/Darwin-p11 제거·브랜치 삭제.
- **머지 게이트: 풀 스위트 3,461 테스트 · 2 skip · 0 실패** (serial, 119s) + 빌드 clean.

## [P12] 3D W4+W5 — 카메라 연출 + 성능 검증 — **통과 (커밋 대기)** (2026-06-12)

- 구현: 메인 워크트리 미커밋(Visualization/·Pilot/Cockpit/ + 신규 SceneMath·
  CockpitChaseFollower + 테스트 3스위트) · 리뷰어: **Fable 교차**(별도 세션)
- **A 안전·성능: 통과** — 턴테이블 on 시 `isFullyIdle` 강제 false(InteractiveSceneView:342
  가드 + 회귀 테스트 명시 assert), DOF 는 `InteractiveSceneView` 전용이라 헤드리스
  렌더러 구조적 제외, Cockpit follower 는 renderer delegate(설계 명시 예외 — 원래 연속
  렌더), `shortestAngleDelta` 최단경로 보정(SceneMath).
- **B 계약: 통과** — follower 상수가 설계 §6 4-D 고정값 그대로(lerp 0.12/0.08 ·
  lean ≤2.5° · FOV 50→54 @0.3m/s 포화 · zoom 0.6~4.0), 순수 로직 분리로 헤드리스
  테스트 가능(설계 대비 개선). W5 §7 표에 실측치 기입(헤드리스 측정분 수치 +
  Instruments/.app 항목은 대기로 정직 표기).
- **C 품질: 통과** — 신규 테스트 20개(SceneMath·InteractiveSceneBehavior·
  CockpitChaseFollower) **리뷰 세션 직접 재실행 0 실패**.
- **D 절차: 커밋 대기** — README·설계 문서 갱신은 워크트리에 존재.
- **커밋 위생 비고(중요)**: 메인 워크트리의 MeshRig·DarwinOP2Rig·RigSkeleton.swift 는
  **P11 브랜치 48ba615 산출물과 바이트 수렴 + P12 추가분(MeshRig 머리 디테일 75줄)** 구조
  임을 diff 로 확인 — P12 커밋에 W3 선행분이 포함되는 것은 의도된 수렴(커밋 메시지에
  명시할 것). 이후 P11 머지 시 MeshRig 충돌은 **main 버전 채택**으로 해소(superset).
- 이월: 커밋 전 풀 스위트 1회(동시 편집 세션 종료로 간헐 실패 원인 소멸), Instruments
  풀링·GPU frame time 실측은 .app 실행 시.

## [P3] 전송 묶음 (W1+O0·O1) — **통과 (재검 완료)** (2026-06-12)

- 최종 커밋: `74fca94`(connection: O0 계측+W1 Mac 채널+Swift 5스위트) ·
  `ad287e4`(firmware: O0 TEL+O1 transport 통합+호스트 테스트+계약 §G) · `729b4f5`(docs)
- **재검 결과 — 1차 이슈 2건 모두 수정 확인**:
  - [HIGH] 워치독 소스 게이팅: `WatchdogDecision(elapsed, walking_active, from_stream)`
    순수 로직로 이관(WalkLabTransport.cpp:134-140 — `!from_stream → WD_NONE`),
    슬롯 적용 시 true(브로커리지 722행)·파일 적용 시 false(748행),
    신규 `test_watchdog_stream_only` 5체크(파일 소스 700ms/3s/way-stale 전부 미발화 +
    스트림 소스 600/2500ms 발화), 계약 §G.4:481 "Tiers are STREAM-SOURCE ONLY" 명시 ✓
  - [MEDIUM] 핸드셰이크: `RefreshHandshake(now_ms)`(브로커리지 509-542행) — 1s 스로틀·
    첫 루프 즉시 시도·늦은 도착 수용·mtime 변경 시 재기동(토큰 회전)·파일 삭제 시
    transport 정지(파일 폴 복귀), 계약 §G.1:457 세션 종료 clear 의무 ✓
  - [record] `sendEmergencyStopNow` nonisolated 전환 TODO(channel:83) ·
    WriteTelemetry 주석 실제 주기 정정(801행) ✓
- 재검 독립 재실행: 호스트 C++ **63체크 0실패**(58→63, +게이팅 5) · Swift 5스위트 **41/41**
- 실기 이월(로봇 연결일): demoBuildPatched 재빌드 배포 → 실효율 ≥20Hz ·
  E-STOP→walking=0 p95 ≤60ms · 케이블 분리 0.6s 제자리→2.5s 정지 벤치 (단, 워치독 티어는
  UDP 명령 송신기 도입(H3 등) 전까지 휴면 — 파일 경로는 5s STALE 만)

### 1차 리뷰 기록 (조건부 — 수정 전, 이력 보존)

- 구현: 메인 워크트리 미커밋(Connection/·WalkLab/·firmware-patches/ 19파일+계약 §G) ·
  리뷰어: **Fable 교차**(별도 세션)
- 증거(리뷰 세션 독립 재실행): Swift 5스위트 **41/41 통과** · 호스트 C++ **58체크 0실패**
  (구현 세션 보고와 일치. cargo 382는 구현 세션 증거 인정)
- 잘된 점: 스레드는 "수신→슬롯/정지"만(적용은 supervisor 단일 writer), E-STOP UDP 수신
  즉시 Stop+토크OFF+flag touch(상태는 파일이 소유 — 기존 latch/re-arm 재사용), SO_RCVTIMEO
  1s 로 깨끗한 종료, 파일 폴백 보존(`transport 미기동 → 종전 동작 완전 보존` 주석·코드 일치),
  순수 로직 분리(WalkLabTransport)로 호스트 테스트 가능 구조
- **이슈 1 (HIGH — 머지 전 수정 필수)**: 워치독 티어가 **소스 무관 적용**
  (WalkLabBrokerage.cpp:729-743 — `m_last_cmd_ms` 는 파일 적용(701)에도 갱신).
  Mac 브리지(dedup: line==lastAckedLine 스킵)·Switch v1(변경 시만 송신) 등 파일 경로
  클라이언트는 **일정한 스틱 홀드 시 명령이 끊겨 600ms 후 제자리·2.5s 후 정지** — 정상
  보행 회귀. 설계(O1 §4)는 "20-30Hz 연속 스트림" 계약 클라이언트 전용 티어였음.
  수정: 슬롯(UDP) 소스 플래그 게이팅 + 호스트 테스트 + 계약 §G.4 명시.
- **이슈 2 (MEDIUM — 머지 전 수정 권고)**: 핸드셰이크 `LoadHandshake` 가 Run() 1회뿐
  (576행) + Mac `walkLabWriteChannelHandshake` 호출처 0건(정의만). 정상 플로(데모 기동 후
  Mac 이 기록)에서 UDP 영영 비활성 + 구세션 잔존 토큰 회전 미대응(토큰 불일치 시 UDP
  E-STOP **무음 불능** — SSH 폴백은 생존). 수정: 미기동 시 1s 재시도 + mtime 변경 시 재기동.
- 결선 시 주의(차단 아님, 기록): ① `sendEmergencyStopNow` 가 actor-isolated — 라이브
  E-STOP 결선 시 await 홉 1회 추가됨(§7 위반 소지) → 결선 전 nonisolated 전환
  ② WriteTelemetry 주석 stale(보행 중 실제 50Hz push — O4 에서 30Hz 정식화)
  ③ `m_transport_running` plain bool 크로스스레드(실용상 무해, volatile 권장)
- 절차: 04 §리뷰 절차에 따라 **수정 → 재검 → 커밋(명시 경로) → 본 원장 확정** 순.

## [P11] 3D W3 — 로봇공학 오버레이 — **통과** (2026-06-12, 머지 대기)

- 구현: `claude/p11-3d-overlays` 브랜치 3커밋(59c6501 RigSkeleton 선행 → 9471528 오버레이
  본체 → 48ba615 테스트), 베이스 4c1f6f2, 워크트리 /tmp/Darwin-p11(clean 확인)
- 리뷰어: **Fable 교차 리뷰**(구현 세션과 별도 세션 — 04 §D 외부 검수 충족)
- **A 안전·성능: 통과** — Overlays/ 전체에 자체 타이머/asyncAfter/Task 0건(기계 검사),
  노드 풀 init 1회 할당, 갱신은 `refreshOverlays()`가 applyPose 동일 경로에서만 호출
  (RobotSceneCoordinator:163·170·179), 10파일 1,039줄(전부 800줄 이하), renderImage
  확장 후 기존 호출자(SceneExposure/ScenePresetSnapshot) 무회귀
- **B 계약: 통과** — preset×오버레이 기본값 매트릭스가 설계 §5 표와 6×5 전 칸 일치,
  발 사각형/CoM 높이 상수는 `ZMPMonitor` 단일 정의 직접 참조(SupportPolygonGeometry:15-16·81),
  RigSkeleton 선행 커밋으로 프리미티브 폴백 크래시 방지, emission 우선순위
  warn95>warn85>highlight 단일 진입점
- **C 품질: 통과** — 신규 테스트 9개(ZMP 정합 5·emission 2·스냅샷 2) **리뷰 세션에서
  직접 재실행 0 실패**, 풀 스위트 3408 통과(serial)·빌드 clean(구현 세션 증거)
- **D 절차: 통과** — 커밋 3분할(선행/본체/테스트), README·프롬프트 갱신 브랜치 포함
- 발견 이슈: 블로킹 0
- 비고/이월: ① **머지 충돌 표면 7파일** — MeshRig·DarwinOP2Rig·ViewportControls·
  StudioView·MotionStudioCanvas(메인의 미커밋 P12/P3 작업과 교차) + docs/design/README.md·
  implementation-prompts.md(체크 표기 — union 병합) → **메인 정리 후 머지 + 풀 스위트 재실행
  의무** ② Instruments 풀링 실측·오버레이 실데이터(FSR/verdict) 검증은 실기/O4 이후 이월
  ③ 헤드리스 스냅샷은 "off 대비 픽셀 차" 방식 — 로봇 STL 미로드 제약 내 타당

## [P2] 3D W2 — 화면별 환경 프리셋 + 셰이더 그리드 — **통과** (2026-06-12)

- 구현 커밋: `4c1f6f2` · 리뷰어: Fable(구현 세션) + Codex 교차 검수
- A 안전: 통과(3D 성능 계약 유지 — 30fps·isFullyIdle·wantsHDR=false, 헤드리스 회귀 없음)
- B 계약: 통과(프리셋 주입은 init 단일 경로, legacyGrid 폴백 보존)
- C 품질: `ScenePresetSnapshotTests` 신설, swift test 전체 통과(serial)
- D 절차: README 표·프롬프트 체크박스 갱신 완료
- 발견 이슈: 구현 세션에서 Codex 검수 후 수정 반영(상세는 해당 세션 기록 — 본 원장
  도입 이전이라 이슈 목록 미이관)
- 실기 보류: 없음(UI 전용)

## [P5] bus D0 — J4 deadline + J13 FTDI + 계측 — **통과** (2026-06-11)

- 구현 커밋: `f21f046` · 리뷰어: Fable(구현 세션) + Codex 교차 검수
- A 안전: 통과(E-STOP/cancel 체크 step 경계 유지, phase floor 80ms 유지)
- B 계약: 통과(IOSSDATALAT 미지원 어댑터 no-op 폴백)
- C 품질: `StepDeadlineSchedulerTests`·`PilotLatencyTracerTests` 신설, cargo + swift test 통과
- D 절차: README 표·체크박스 갱신 완료
- 발견 이슈: 본 원장 도입 이전 — 미이관
- 실기 보류: **step 지터 p95 ≤±10ms · USB IMU read p95 ≤3ms** → 로봇 연결일 벤치(02 §2)

---

> 참고: 본 원장은 2026-06-12 하네스 도입 시점부터 운용. 이전 완료분(P2·P5)은 소급
> 기록이며, 이후 항목은 머지 전 기록이 의무다(04 §리뷰 절차 6단계).
