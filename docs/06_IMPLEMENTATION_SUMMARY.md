# 06 — 구현 요약 (Implementation Summary)

> 프로그램 진행의 누적 요약 — P 완료마다 1절 적립(최신이 위). 전체 프로젝트 이력은
> `PROGRESS.md`, 웨이브 상태 표는 `docs/design/README.md` §1 참조.

## 누계 현황 (2026-06-12 갱신 3차)

- 완료(머지·리뷰 통과): **P2**(3D W2), **P5**(bus D0), **P3**(전송 묶음, 2회전 통과 +
  레거시 테스트 정정 ef559c0), **P12**(3D W4+W5 — 62d18e6·26e9df4),
  **P11**(3D W3 — 머지 b3906f9, 풀 스위트 3,461/0) + 하네스 도입 이전 완료분
- **3D 뷰포트 트랙(W0~W5) 전 웨이브 완료** — 머지 게이트 풀 스위트 3,461 테스트 0 실패
- 다음(로봇 불필요): **P4**(거버너 — 즉시 착수 가능) → P6 → P9 → P10
- 로봇 대기: P1(프로브), P7, P8, 실기 벤치 누적분(05 의 "실기 보류" 항목들 + P3 배포·벤치)

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
