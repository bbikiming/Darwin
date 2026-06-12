# 06 — 구현 요약 (Implementation Summary)

> 프로그램 진행의 누적 요약 — P 완료마다 1절 적립(최신이 위). 전체 프로젝트 이력은
> `PROGRESS.md`, 웨이브 상태 표는 `docs/design/README.md` §1 참조.

## 누계 현황 (2026-06-12 갱신 4차)

- 완료(머지·리뷰 통과): **P2**(3D W2), **P5**(bus D0), **P3**(전송 묶음, 2회전),
  **P12**(3D W4+W5), **P11**(3D W3 — 머지 b3906f9), **P4**(온보드 O2 — 39a613b+54e6246,
  2회전 통과) + 하네스 도입 이전 완료분
- **3D 뷰포트 트랙(W0~W5) 전 웨이브 완료** · 온보드 트랙 O0~O2 완료(O3·O4 잔여)
- **P6 ✅**(bus D1+D2 — 5ff5873·e940e63, 1회전 통과: 공유 샘플러+래치 O2 패리티·LPF·
  FSR 관측. 편차 3건 승인 — FSR 유선 5Hz·낙상윈도 독립·양 루프 공유)
- **P9 ✅**(온보드 O4 TEL2 — daa2550·998297a, 1회전 통과: 파일 TEL v1 폴백 불변·UDP
  TEL2 30Hz·FSR/CoP·phase·래치·J6 폴러·HUD/walkAnimator/오버레이 결선. 양 모드 FSR
  오버레이 대칭 완성)
- 다음(로봇 불필요): **P10**(Switch UDP — 마지막 로봇-프리 P). bus 트랙은 D3(데모 운영)만 잔여
- 온보드 트랙: **O0·O1·O2·O4 완료** — O3(밸런스 피드백, 실기 비중 최대)만 잔여
- 로봇 대기: P1(프로브), P7, P8, 실기 벤치 누적분(05 의 "실기 보류" 항목들 + P3 배포·벤치
  + P4 k_x 보정)

---

## [P4] 온보드 O2 — 거버너·twist v2·슬루·밸런스 결선 (2026-06-12, 39a613b+54e6246)

- V2 twist 프로토콜(SI 정수, 로봇이 변환 소유 X≈k_x·vx·T/2, k_x 벤치 TODO) — v1 영구 수용.
- 결합 엔벨로프 거버너(≤1.15, period 종속 x_max) — **v1 포함 전 클라이언트 최종 클램프**
  (Switch 50mm 구멍 해소). 래치 슬루(|ΔX|≤8mm 등) + 루프 측 전진(단발 명령 램프 보장).
- blevel→게인 결선(BASE 상수 × 배율, 멱등) — **밸런스 enable 은 blevel 단일 소스**
  (benable 직결 시 낙상 회귀라 편차 승인). 속도 비례 게이트 스케줄(Z/Yswap/HIP 가산).
- Mac: serializedLineV2 준비(송출은 v1 유지 — 미패치 로봇 보호), EMA 0.25→0.5.
- 검증: 호스트 142체크 · Swift 신규 11 + 풀 3,472/0 · 계약 §C/§G.8 개정.
  교차 리뷰 2회전(슬루 고착 HIGH·Y_SWAP base MEDIUM → 수정 확인).

---

## [P3] 전송 묶음 — 레이턴시 W1 + 온보드 O0·O1 (2026-06-12, 74fca94·ad287e4·729b4f5)

- **O0 계측**: TEL 파서 ≥11 토큰(+last_cmd_id/loop_ms 폐루프), RobotClockSync(EWMA 클럭
  오프셋), PilotLatencyTracer 7지점 mark + ackReceived 로봇 시각.
- **W1 Mac**: OnboardCommandChannel(actor) + PersistentSSHChannel(상주 exec sh -s·sentinel·
  동기 폴백) + EstopUDPSender(×3연발) + SendPolicy/CoalescingQueue. E-STOP 큐 우회·무스로틀.
  라이브 송출 경로 교체는 후속(플래그 df.onboard.persistentChannel 뒤).
- **O1 로봇**: WalkLabTransport 순수 로직(latest-wins 슬롯·seq 단조·워치독·파서 — 호스트
  테스트 63체크) + 브로커리지 UDP 리스너 2개(E-STOP 17372 즉시정지 / 명령 17374) +
  supervisor 보행 중 20ms + **워치독 티어(스트림 소스 전용 게이팅)** + RefreshHandshake
  (1s 재시도·토큰 회전·삭제 복귀) + 파일 폴백 영구 보존.
- 계약: ssh-parity-contract.md §A.2/§A.3 개정 + §G 신설(핸드셰이크·데이터그램·티어 규약).
- 검증: 호스트 C++ 63 · Swift 5스위트 41/41 · cargo 382 · 빌드 0 errors.
  교차 리뷰 2회전(HIGH 워치독 게이팅·MEDIUM 핸드셰이크 → 수정 확인). 실기 배포·벤치 이월.

## [P11] 3D W3 — 로봇공학 오버레이 (2026-06-12, `claude/p11-3d-overlays` 59c6501→48ba615 · 머지 대기)

- RigSkeleton 프로토콜 선행(MeshRig·DarwinOP2Rig 양쪽 채택 — 폴백 크래시 방지) +
  EmissionState 우선순위 합성(warn95>warn85>highlight 단일 진입점).
- 오버레이 6종: CoM 투영+지지다각형(ZMP verdict 색·상수 공유), 관절축+한계각 아크(85/95%
  경고), FSR 발 접지(휴리스틱 폴백), IMU 수평선(tiltNode 바깥), EE 궤적(160 풀·4mm 게이트),
  한계 근접 경고. preset 기본값 매트릭스 + ViewportControls 팝오버 토글.
- 성능 계약 준수: 자체 타이머 0·풀 1회 할당·applyPose 동일 경로 갱신.
- 검증: 신규 테스트 9개(ZMP 정합·emission·스냅샷) + 풀 스위트 3408 통과·빌드 clean.
  리뷰: 05 원장 [P11] 통과(Fable 교차).

## [P2] 3D W2 — 화면별 환경 프리셋 + 셰이더 그리드 (2026-06-12, `4c1f6f2`)

- ScenePreset 5종(.studio/.teach/.walkLab/.motion/.cockpit) + `SceneEnvironment.swift` 스펙
  테이블, 화면 호출부 주입(Studio/Teach/WalkLab/Motion/RemotePilot/Cockpit).
- fwidth AA 그리드 셰이더(`GridFloorMaterial.swift`) — 실린더 그리드 대체(노드 -36, Cockpit
  -58), legacyGrid 폴백 보존. 소품(originAxes·workMat·distanceMarks·startLine·stageSpot).
- 검증: `ScenePresetSnapshotTests` + swift test 전체(serial) + Codex 교차 검수.

## [P5] bus D0 — J4 deadline + J13 FTDI + 계측 (2026-06-11, `f21f046`)

- `StepDeadlineScheduler` 신설 — 고정 sleep → deadline 보상 스케줄(J4), MobileFreeform/
  WalkCycleEngine 배선.
- `posix.rs` IOSSDATALAT ioctl FTDI latency 1ms(J13, 미지원 no-op).
- `PilotLatencyTracer` bus 마크(stepScheduled→syncWriteDone→imuRead) + 지터 히스토그램 +
  `PilotDiagnosticsPanel` 1Hz 디버그 노출.
- 검증: `StepDeadlineSchedulerTests`·`PilotLatencyTracerTests`, cargo+swift 통과.
  실기 지터/IMU 벤치는 로봇 연결일로 이월.

## 하네스 도입 이전 완료분 (요약)

- **3D W0·W1** (`b941f54`·`2a58777`+`2abd6d4`+`94b4866`): RobotScene3D 4분할(픽셀 diff 0) →
  PBR(RigMaterials)+절차적 IBL+STL normal smoothing(crease 35°), SceneExposureTests 등
  신설(3,381 테스트), 라이브 튜닝 패널(`9a32f8d`+`b4ca7d5`+`6a82d39`, 계획 외 추가).
- **레이턴시 W0·W2 + W3 일부** (`66039c6`·`8139247`·`e0bb2cf`·`da495d6`·`7808fdb`·`c62d3af`·
  `a61afbc`·`9dff323`·`fe8d748`·`0153464`): 안전 배선(S1·S2·S3)·런루프(L3)·cadence(J3) →
  SYNC_WRITE 일원화(L5)+burst read(J12)+E-STOP 락 선점(S4)+논블로킹 drain(J11)+io-timeout →
  머리 SYNC_WRITE(J2)·MainActor 탈출(L6·L7)·@Published 가드(J1)·MJPEG 코얼레싱(J9).
- **컨트롤러 매핑 P1~P3+드라이버 실소비** (`cde16de`·`3c5f97c`·`f3352c1`·`f088628`·`1f52279`).
