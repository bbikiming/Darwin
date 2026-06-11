# 06 — 구현 요약 (Implementation Summary)

> 프로그램 진행의 누적 요약 — P 완료마다 1절 적립(최신이 위). 전체 프로젝트 이력은
> `PROGRESS.md`, 웨이브 상태 표는 `docs/design/README.md` §1 참조.

## 누계 현황 (2026-06-12 갱신)

- 완료(머지됨): **P2**(3D W2), **P5**(bus D0) + 하네스 도입 이전 완료분(3D W0·W1,
  레이턴시 W0·W2·W3 일부, 컨트롤러 매핑 P1~P3)
- 완료(리뷰 통과·**머지 대기**): **P11**(3D W3 — `claude/p11-3d-overlays` 3커밋,
  충돌 표면 7파일은 05 비고 참조)
- 코드 완료(메인 워크트리, **커밋·리뷰 대기**): **P3**(W1+O0·O1 — 동시 세션 작업분)
- 진행 중(메인 워크트리): P12(카메라 연출 일부)
- 다음(로봇 불필요): P3 커밋·리뷰 → P12 마감 → P11 머지 → P4 → P6 → P9 → P10
- 로봇 대기: P1(프로브), P7, P8, 실기 벤치 누적분(05 의 "실기 보류" 항목들)

---

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
