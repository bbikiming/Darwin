# 06 — 구현 요약 (Implementation Summary)

> 프로그램 진행의 누적 요약 — P 완료마다 1절 적립(최신이 위). 전체 프로젝트 이력은
> `PROGRESS.md`, 웨이브 상태 표는 `docs/design/README.md` §1 참조.

## 누계 현황 (2026-06-12)

- 완료: **P2**(3D W2), **P5**(bus D0) + 하네스 도입 이전 완료분(3D W0·W1, 레이턴시 W0·W2·W3
  일부, 컨트롤러 매핑 P1~P3)
- 진행 예정(로봇 불필요 트랙): P3 → P4 → P11 ∥ P12 → P6 → P9 → P10
- 로봇 대기: P1(프로브), P7, P8, 실기 벤치 누적분(05 의 "실기 보류" 항목들)

---

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
