# PROGRESS

> 살아있는 진행 상태. 단계 종료 시마다 갱신·체크포인트 커밋·`docs/reports/PHASE_{N}_REPORT.md` 작성.
> 사용자 승인 모드: **한 번 승인 후 끝까지 자율** (2026-05-09 결정).

## Phase 진행 상태

- [x] **Phase 0 — Bootstrap** (워크스페이스 초기화, 도구 검증, 빈 구조 생성)
- [x] **Phase 1 — Discovery & Archive** (오픈소스 발굴·아카이브 — 26 엔트리, 4 클론)
- [x] **Phase 2 — Knowledge Synthesis** (5개 신규 명세 + 2개 보존)
- [x] **Phase 3 — Harness Engineering** (BOM·결선·드라이버·probe.sh + ADR-006/7/8)
- [x] **Phase 4 — App Architecture** (ADR-009..013, Cargo workspace 18 tests)
- [x] **Sprint 1** Connection Layer (PosixSerial + Bus + CmController, 26 tests)
- [x] **Sprint 2** Live Joint Control (Sync R/W + JointController + safety, 35 tests)
- [x] **Sprint 3** Motion Import/Export (.mtn ↔ JSON round-trip, 43 tests)
- [x] **Sprint 4** Motion Editor 골격 (timeline + library + SwiftUI stub, 50 tests)
- [x] **Sprint 5** Walk Engine MVP (params + engine + IMU + sim CLI, 59 tests)
- [x] **Sprint 6** Vision & Strategy MVP (HSV blob + FSM + sim CLI, **73 tests**)
- [x] **Sprint 7** SwiftUI Studio 본 구현 (3D viewer + 타임라인 에디터 + 명령 팔레트, **+36 Swift tests**)

## 🎉 MVP 달성 (2026-05-09)

ROADMAP §5 MVP 정의 100% 충족:
- Sprint 1~3 완성, Sprint 4 골격, Sprint 5/6 데이터 모델
- forge-core: 73 tests / cargo build / clippy / fmt 모두 GREEN
- `forge` CLI 9 서브커맨드: ports / ping / scan / board / list-joints /
  joint{set,state,torque,estop} / motion{import,export,inspect} /
  walk / strategy

## 통계

| 항목 | 값 |
|------|-----|
| 단계별 보고서 | 11개 (Phase 0~4 + Sprint 1~6) |
| ADR | 13개 (ADR-001~013) |
| 명세 문서 | 12개 (protocols/motion-format/architecture/harness) |
| Rust modules | 13개 (control, controller, dynamixel{bus,sync,v1,v2}, error, joint{state}, motion{page,parser,writer,timeline,library}, serial{loopback,posix}, strategy, vision{frame,segmentation}, walk{engine,imu,params}) |
| Rust tests | 73 / 73 통과 |
| Hardware BOM 부품 | 18개 (OP1 15 + OP2 3 추가) |
| Research INDEX 엔트리 | 26개 (ROBOTIS 공식 + 1세대 + 커뮤니티 + 학술) |

## 직전 체크포인트

- 커밋: `<latest> sprint-6: vision & strategy MVP`
- 브랜치: `claude/robotis-darwin-op-setup-oyzTi`
- PR: #1 (draft, MVP 완료 후 갱신)

## Sprint 7 — SwiftUI Studio (2026-05-10)

ROADMAP §"Mac 측 SwiftUI 본 구현"이 완료되었음.

### 추가된 Swift 모듈 (12개)
- **ForgeCore (5)**: `Kinematics.swift` (raw↔도, 한계, 회전축, 미러), `RobotPose.swift` (16-DOF 불변 자세 + lerp + mirror), `MotionDoc.swift` (forge-core JSON 미러 + step↔pose), `BusActor.swift` (Bus actor wrap), `LiveTelemetry.swift` (백그라운드 폴링 + AsyncStream)
- **시각화 (3)**: `RobotScene3D.swift` (SceneKit 16-DOF 휴머노이드 + 발 trail + 그리드), `BodyMap2D.swift` (사람 실루엣 위 16점 + 색상 인디케이터), `TelemetrySparkline.swift` (Path 기반 미니 차트)
- **컴포넌트 (2)**: `CommandPalette.swift` (⌘K 팔레트 + 19 명령 카탈로그), `StatusBar.swift` (모드/연결/배터리/온도/토크/팔레트)
- **화면 (5)**: `StudioView.swift` + `PoseInspector.swift` (3D + 슬라이더 + 텔레메트리 sparklines), `MotionStudioView.swift` + `TimelineCanvas.swift` + `MotionPlayer.swift` (RoboPlus 대체), `WalkLab.swift` (Webots 스타일 발 trail), 새 `RootView.swift` (5 모드 통합)
- **연결 (1)**: `AutoConnect.swift` (USB 포트 best-guess heuristic), `ConnectionStore` 향상 (autoConnect + 텔레메트리 폴링 + voltageHistory/avgTempHistory)

### 핵심 기능
- **3D 미러 뷰**: SceneKit으로 본 트리 렌더, 슬라이더 변경 시 즉시 회전 반영
- **타임라인 에디터**: 페이지 목록 + step bar (play/pause 시각화) + seek + 재생 + 키프레임 추가/삭제 + 실측 캡처
- **명령 팔레트**: ⌘K로 19개 명령 (연결, 깨우기, 자세 적용, 모션 임포트, 섹션 전환 등) 빠른 검색·실행
- **실기기 즉시 적용 토글**: Studio/Motion에서 슬라이더 → 모터 명령 즉시 발행
- **글로벌 단축키**: ⌘1..5 섹션, ⌘⇧. 비상정지, ⌘⇧C 자동 연결, ⌘K 팔레트, ⌘⇧P 실측 캡처

### 통계
- 총 Swift 파일: 25 → 39
- Swift 테스트: 4 → 36 (Kinematics 10, RobotPose 10, MotionDoc 8, Strategy 3, Walk 1, Smoke 2 + 기존 2)
- forge-core Rust 테스트: 73 / 73 그대로 통과
- Universal binary `libforge_core.a`: 12 MB

## Sprint 8 — V2 Production Hardening (2026-05-10)

V2 점검 (`docs/reports/AUDIT_DARWIN_V2.md`)에서 도출한 P0 8개 패치 일괄 반영. 핵심:
*하드웨어 안전*과 *비전문가 UX 신뢰*를 위한 최소 셋트.

### P0 패치 (본 PR)
- **P0-A** PoseInspector slider edit-end gating — 매 프레임 setPosition × 16관절 → 1슬라이더 1패킷
- **P0-B** StudioView diff-based apply (`RobotPose.changedJoints`) — 변경된 관절만 발행 (15 패킷 / move 절감)
- **P0-C** Live Apply confirm race 수정 — 사용자 동의 *이전* liveApply가 true가 되지 않게
- **P0-D** USB drop watchdog (3 strikes → status .error) — 연결 끊겨도 계속 .connected이던 false-trust 윈도우 차단
- **P0-E** Camera defaults centralized (defaultAzimuth/Elevation static) — `resetCamera()` 진실의 원천 통일
- **P0-F** STL fallback banner — primitive rig fallback 시 노란 배너로 사용자 통지
- **P0-G** macOS Menu commands (보기/로봇 메뉴) — ⌘1..5 / ⌘⇧. / ⌘K 단축키가 메뉴바에 노출 (Apple HIG)
- **P0-H** Starter motion library 5페이지 — 기본자세 / T자세 / 인사 / 손 흔들기 / 앉기

### 검증
- `swift build` GREEN (8s, Universal)
- `swift test` **70 tests / 0 failures** (Kinematics 10, RobotPose 15 (+5 changedJoints 신규), MotionDoc 8, Strategy 3, Walk 1, RobotSnapshot 5, StarterMotionLibrary 5 (신규), ConnectionStoreWatchdog 4 (신규))
- 변경 파일: 9 (Swift), 추가: 2 (Tests/StarterMotionLibraryTests, Tests/ConnectionStoreWatchdogTests)
- 추가 코드: ~280 LOC
- Rust forge-core: 73 tests 그대로 GREEN

### 통계
- 총 Swift 파일: 39 → 41
- Swift 테스트: 36 → 70
- 새 정의: `RobotPose.changedJoints(from:)`, `MotionStudioView.starterPages()`, `ConnectionStore.handleBusError()`,
  `InteractiveSceneView.defaultAzimuth/Elevation/Distance/Target`, `RobotScene3D.onMeshFallback`,
  `RobotScene3D.Coordinator.usingMeshFallback`

## 다음 단계 (사용자 결정)

1. **P1 (1주)**: Sync_Write FFI 노출 (16관절 1패킷 ≈ 12 ms), walking IK + 실 모터 발행 토글, Help cheat sheet
2. **P2 (2주)**: AVFoundation 카메라 → forge-core::vision 라이브, SQLite persistence, undo/redo
3. **P3 (4주)**: 거대 파일 분리 (RobotScene3D 936줄 → 4 파일), UI 픽셀 회귀, ROS2 bridge
4. **실기기 검증** — Mac에서 USB 연결 → Studio 자동 연결 → 슬라이더 → 모션 재생까지 E2E
5. **PR #1 ready for review 전환** — 문서 + 코드 리뷰
