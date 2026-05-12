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
- [x] **Phase A — 안전 기반** (2026-05-11): 20 DOF + JointMap (Official/LegacyOp1) + 부위별 한계 + walkReady (`ini_pose.yaml` 1:1) + 토크 ramp (P_GAIN 0→8→16→32) + `forge walk-ready` CLI + 명세 정정 → **106 tests**.
- [x] **Phase B — 모션 카탈로그** (2026-05-11): `motion_4096.bin` byte-identical 파서 + `SafetyClass {Safe, Caution, HighRisk}` + `Library::with_official_catalog` (11 Safe + 2 Caution + 3 HighRisk) + self-collision 룰 + `precheck_motion(confirm_risk)` → **125 tests**.
- [x] **Phase D (walk 권외)** (2026-05-12): `CmController::detect_joint_map` + `forge connect` + `forge motion catalog` CLI → **127 tests**.

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

## Sprint 9 — Motion Synthesis Core (2026-05-12)

PRD-001 ([`docs/prd/motion-synthesis-v1.md`](docs/prd/motion-synthesis-v1.md))
명세 그대로 12 작업 모두 본구현. 기존 모션을 reference 로 새 페이지를
알고리즘적으로 합성하는 엔진 + 4-stage 안전 검증.

### 신규 모듈 (forge-core::synth)
- **library** — `from_official_bin` + `decode_raw_page` + `auto_metadata` (16 OFFICIAL_CATALOG 페이지)
- **ops** (6 연산자) — `Sequence` / `Layer` / `Morph` / `Mutate` / `Mirror` / `Procedural`
- **validator** (4 단계) — `JointLimit` / `Velocity` / `SelfCollision` (safety wrap) / `StaticStability`
- **provenance** — `Manifest` (builder + JSON I/O + SipHash13 digest + ISO-8601)
- **test_fixtures** — `motion_4096.bin` 6 페이지 byte-preserving 임베드 (page 1/2/9/12/13/16)

### Mirror ground truth
- 좌·우 페어별 mode 자동 결정 (PITCH/ROLL/YAW/ELBOW 4 유형)
- `mirror(page_12_right_kick)` vs `page_13_left_kick` mean abs diff < 600 raw (~13°)
- ROBOTIS 가 손으로 미세 조정한 흔적 확인 (정확 일치 X, 합리적 근사)

### Integration (S9-12, 10 시나리오)
- Mirror + Sequence + Mutate + Morph + Layer + Procedural 풀 파이프라인
- `walkready → right_kick → walkready` 보행 routine 합성 (2-page chain) + Manifest JSON round-trip
- Validator failure → Mutate 회복 시나리오

### 통계
- 신규 tests: 188 개 (73 → 261)
- 신규 Rust 모듈: 17 (synth/* 디렉토리)
- 신규 문서: PRD-001, ADR-014, page-catalog-motion4096.md, page-metadata-motion4096.toml

## Sprint 10 — CLI & MCP Integration (2026-05-12)

### S10-1 ~ S10-4: forge-cli `synth` 서브명령 (11 개)
- `forge-cli/src/synth.rs` (738 줄) + main.rs 3 줄 추가 (충돌 회피)
- `library list/metadata`, `sequence`, `layer`, `morph`, `mutate`, `mirror`,
  `procedural`, `validate`, `commit` (백업 자동), `simulate` (ascii/summary)
- 6 unit tests

### S10-5 ~ S10-7: MCP 서버 `forge-mcp-synth` (신규 crate)
- stdio JSON-RPC 2.0 server (외부 dep 없이 표준 라이브러리만)
- 11 tools: `library_search` / `library_get` / `synth_*` × 6 / `validate` / `commit` / `preview`
- 30 unit tests (engine 4 + protocol 7 + tools 19)
- E2E 검증: initialize / tools/list / tools/call 전 흐름
- **안전 게이트**: validator FAIL → commit 거부, 자동 백업, slot 점유 시 force 명시 필요

### 부수 수정 (공식 모션 근거 정합성)
- `synth/library.rs` PAGEHEADER offset 정정 (ROBOTIS Action.h 와 일치)
- integration test + forge-cli path 정정 (`../../research` → `../../../research`)
- Integration test expectations 현실화 (V1/V2 보수성 인정)

### 통계
- 신규 tests: 41 개 (261 → 302)
- 신규 crate: 1 (`forge-mcp-synth`, workspace members 3 → 4)

## Sprint 12 — Claude Integration (2026-05-12)

PRD-001 §5.5 (FR-CLAUDE) 3-track 통합. Sprint 11 (SwiftUI Synth Palette) 은
PENDING — 다른 worktree GUI 작업과 조율 후 진행.

### `.claude/` 신규
- `commands/synth.md` (128 줄) — `/synth <자연어>` 슬래시
- `agents/motion-composer.md` (223 줄) — opus 서브에이전트 (11 MCP tools 권한)
- `settings.json` (53 줄) — MCP 등록 + 15 allow + 3 ask + 2 deny
- `README.md` (122 줄) — 통합 가이드 + 디버깅

### 안전 정책 4-layer
1. slash command 본문: `commit` 자동 호출 금지
2. subagent 시스템 프롬프트: Hard Constraint 명시
3. settings.json permissions: `commit` 도구 → `ask`
4. MCP server 자체: validator FAIL → commit 거부

### 검증
- settings.json valid JSON, 1 MCP server 정의, 15 allow / 3 ask / 2 deny
- MCP stdio ping / tools/list (11 개) 정상 동작
- 전체 workspace tests: **302 passed; 0 failed**

## Sprint 13 — `forge motion play` (실 robot 송출 본구현, 2026-05-12)

`HARDWARE_VERIFICATION_PROTOCOL.md` G3 단계 자동화. `motion_4096.bin` 슬롯 또는
Motion JSON 의 페이지를 실 robot 에 SYNC_WRITE 로 송출. **기본 dry-run**.

### 신규 모듈
- `forge-cli/src/motion_play.rs` (335 줄) — `PlayArgs` + handler + step decoder
- main.rs 변경: 2 줄 (`mod motion_play;`, `MotionAction::Play` variant + dispatch)

### 안전 게이트 (4-layer)
1. `--dry-run` 기본 ON → `--engage` 명시 시에만 실 송출
2. `precheck_motion` (V1 + V3) 자동 — fail 시 거부
3. `TorqueRamper` gentle 프로필 (P-gain 0→8→16→32)
4. Bus drop → SIGINT 시 모터 명령 stop (signal-hook 후속)

### 검증
- `forge motion play --help` 11 options 정상 출력
- `forge motion play --slot 1` (Stand Up) dry-run → 20 joints 디코드 정확
- `forge motion play --slot 12` (Right Kick, 7 step) dry-run → step timing 정확
- 신규 tests: 4 (motion_play 모듈)
- 전체 workspace: **306 passed; 0 failed** (302 → 306)

### Validator V2 calibration (2026-05-12)
- 측정: ROBOTIS motion_4096.bin 16 페이지의 raw_change/ms 분포
- p99=4.74, max=10.26 (page 12 ankle_pitch)
- 임계 보정: WARN 5.2 / FAIL 11.3 (2-tier)
- kick routine 결과: FAIL → **WARN** (정상 ROBOTIS 동작 인정)

## PR #2 + PR #3 머지 (2026-05-12, c85e9ef)

PR #2 (Remote Teleop v1 PRD) + PR #3 (커뮤니티 모션 DB + Walk Lab 슬라이더 고도화)
+ post-merge handoff v2 머지 (fast-forward, 충돌 0).

### PR #3 산출물 (Swift 측, Mac 빌드 필요)
- `ForgeCore/WalkStabilityPredictor.swift` (267줄) — 휴리스틱 evaluate + recommendedCaps
- `WalkLab/Components/SafetyBandedSlider.swift` (285줄) — 색대역 슬라이더
- `WalkLab/Components/AdvancedSlidersPanel.swift` (283줄) — 6 슬라이더 패널
- `Motion/ReferenceMotionLibrary.swift` (443줄) — **19 starter 페이지**
- `Tests/ForgeCoreTests/WalkStabilityPredictorTests.swift` (145줄) — 14 tests

### PR #3 산출물 (data + scripts)
- `motions/test/walk-progression-v1.bin` (131,072 bytes, 6 페이지) — slot 110-115
  - `wk_hold` (자세 유지 2초) / `wk_arms` (팔만 흔들기) / `wk_knee` (3° squat)
  - `wk_hip_r` / `wk_hip_l` (hip sway 좌우) / `wk_lean_pitch` (앞뒤 lean ±2°)
- `scripts/research/extract_motion_pages.py` + `generate_walk_test_motion.py`
- `docs/walk-lab/WALK_PROGRESSION_TEST.md` (230줄)
- `docs/handoff/2026-05-12-pr3-build-and-verify.md` (Mac 빌드 7-단계)
- `research/` — 4 외부 robot 모션 저장소 (vendor data, 약 930K 라인)

### 본 worktree 검증 (Rust 측만 — Swift 는 Mac 필요)
- ✅ `cargo build --workspace` 통과
- ✅ `cargo test --workspace` → **331 passed; 0 failed** (306 → 331, +25)
- ✅ `forge motion play --slot 110 --bin motions/test/walk-progression-v1.bin` dry-run 정상
- ✅ walk-progression-v1.bin 6 페이지 byte-preserving 디코드 (handoff §1-4 명세 일치)
- ⏳ Swift `swift test` — Mac 환경 필요 (handoff §3)
- ⏳ Walk Lab 시각 검증 — Mac 환경 필요 (handoff §4-A~D)
- ⏳ 실 robot 적용 — 사용자 권한 (handoff §5)

### 안전 노트
- PR #3는 Walk Lab의 6-슬라이더 안전 색대역 + 낙상 위험 점수 + smart-clamp 추가
- **start gate 차단** — 점수 80 이상이면 보행 시작 못 함
- "안전 한도 해제" 토글로 임계 우회 가능 (사용자 책임)
- 실 robot 적용 전 [`docs/walk-lab/WALK_PROGRESSION_TEST.md`](docs/walk-lab/WALK_PROGRESSION_TEST.md) 5 체크리스트 필수

## 통계 (PR #1 + #2 + #3 머지 후)

| 항목 | 값 |
|------|-----|
| Rust workspace tests | **331 / 331 통과** |
| Rust crates | 4 (`forge-core`, `forge-cli`, `forge-ffi`, **`forge-mcp-synth`**) |
| forge-core 모듈 | 14 (control, controller, dynamixel, joint, motion, safety, serial, strategy, **synth**, vision, walk, error, lib) |
| forge-cli 서브명령 | 13 + motion::play (ports / ping / scan / board / list-joints / joint / motion[import/export/inspect/catalog/**play**] / walk / strategy / serve / connect / walk-ready / **synth**) |
| MCP tools | **11** (library_search/get, synth_×6, validate, commit, preview) |
| Slash commands | **1** (`/synth`) |
| Subagents | **1** (`motion-composer`) |
| Swift tests | 70 (Sprint 8 마지막 측정) |
| ADR | 14 (ADR-014 Motion Synthesis Architecture 추가) |
| PRD | 1 (PRD-001 Motion Synthesis v1) |

## 다음 단계 (사용자 결정)

1. **Sprint 11 — SwiftUI Synth Palette** (Pending — 다른 worktree GUI 작업 조율 후)
2. **Validator calibration** — V1/V2 임계 보정 (PRD §17.4 후속, 실 robot 데이터 필요)
3. **실기기 검증** — Mac에서 USB 연결 → Studio 자동 연결 → 슬라이더 → 모션 재생까지 E2E
4. **P1 (1주)**: Sync_Write FFI 노출 (16관절 1패킷 ≈ 12 ms), walking IK + 실 모터 발행 토글
5. **P2 (2주)**: AVFoundation 카메라 → forge-core::vision 라이브, SQLite persistence
6. **PR #1 ready for review 전환** — 문서 + 코드 리뷰
