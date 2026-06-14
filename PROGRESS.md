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
- [x] **2026-05 후반 사이클 (V280~V297) — UI 하드닝 + iOS Mobile Pilot MVP** (2026-05-13~25): WalkLabView Progressive Disclosure 15→5(`b894baa`) · KoreanUX Voice&Tone + DFNotification taxonomy(`273f353`) · Code coverage + fitness function 자동화(`3d42ca0`) · STPA + RobotPort + ZMP + xctrace baseline + Mutation pilot(`f977d90`) · iPhone Mobile Pilot MVP + Mac relay + safety hardening(`fab4338`) · App Store Connect 배포 인프라(`fb7514d`) + TestFlight 첫 화면 fatalError 수정(`f4f2faf`). 상세 보고서 다수 `docs/handoff/`·`docs/reports/`.
- [x] **온보드 비전·원격 콘솔·UDP 업링크** (2026-06): C1 카메라 스트림 — walklab 중 8080 MJPEG 라이브뷰 실기검증(`3d2eb5e`) · 온보드 볼 트래킹 헤드모션 on/off + 버튼 매핑(`da2506e`) · RemoteShell exit code 캡처·히스토리 링버퍼(`2dbab85`) · 원격 데모 메뉴 감사 13→9 + 명령 화면 UX 리디자인(`76edbf6`·`66a9443`) · UDP 푸시 업링크 robot→Mac 1 RTT + SSH 폴링 폴백(`f9c7978`).
- [x] **DARwIn FPV W0** (2026-06-13): ROG Ally 게임형 콕핏 앱 — 기획·PRD·UX·아키텍처·수용기준 문서 5종(`app/ally/docs/`) + 독립 Cargo workspace + `df-wire` 와이어 계약 포팅(Python↔Rust 골든 벡터 패리티, **21 tests GREEN**). 다음: W1 제어 코어(유선 실기 게이트).
- [x] **DARwIn FPV W1 — ally-link 연결 계층** (2026-06-13, `d00b8ca`): `app/ally/crates/ally-link/` (ssh/udp/metrics/session) 구현 + macOS selftest GREEN(ACK eff_hz≈20.0, clippy -D warnings 0). W1 이어가기 핸드오프 문서(`4c89353`, ROG Ally 로컬 Claude Code용). **유선 실기 게이트(Ally 기기) 대기**.
- [x] **Mac 'FPV 조종' 탭** (2026-06-13, `40434a0`): 전문가 탭에 ROG Ally FPV 데모 런처(AllyFpvCommands/Session/View, probe/connect/fpv 명령 생성·파싱). 기존 '스위치 연결' 탭 개편 흡수.
- [x] **iOS Mobile Relay 고도화** (2026-06-13~14): walk 30→10Hz latest-wins throttle(`b1fb37b`), 디스패치 직렬화(release가 in-flight move 추월 차단, `ddfc498`), Mac 릴레이 walk conflation 슬롯 + 레이턴시 JSON sink(`7a4ffb1`), 텔레메트리 @Published 게이트 + 유선 재프로브 배너(`f1af504`), 릴레이 conflation 실측·통합테스트 + isEnabled 게이트 테스트(`05ce002`).
- [x] **WalkLab 텔레옵·킥** (2026-06): Anbernic 보행 고도화 P0~P6(`ea5bbb9`, 호스트 test_transport 187/test_gamepad 216 GREEN), 게임패드 LB/RB 공식 킥 F12(`f2e9fae`·`cb0a964`, 온보드 단독), 킥 안정성 감속·착지 settle·사후낙상 인계(`58efaa8`). P7(32/20/L2)·킥 K3 실기 게이트 대기.
- [x] **Anbernic 동글직결 조종 하드닝 + D-패드/볼-추종** (2026-06-14, 호스트 test 279 checks/0 fail): 14-에이전트 감사+플랜(`1bfe8ef`) → Batch A/B/C 구현 `1c7f35c`(A1 ForceDisarm·소스소멸 단일화·신선창 정렬, B2 측보정 정규화, B3 idle timeout). 회전각 18→24→28°(`423e7f0`·`58866f9`)·좌우 보폭/횡속 28→32mm·트리거 회전 연속화(`ef65c02`, 신선도/침묵을 offer 기준). **볼-추종 자동 보행**(`c67fd4a`, START 토글 — 싸커 데모 BallFollower 응용, balltrack 0/1/2) + 보행 중 추적 끊김 수정(`7c89d22`, 정적 추적 휴리스틱 보행 중 비활성). **D-패드 모션**(`8cdc282`, 위=서기 page16·아래=앉기 page15·좌=lPASS71·우=rPASS70, 공식 Action 속도 준수). 전부 **로봇 미배포(OFF)·실기 미검증** — 잔여 게이트 = M2M p95·침묵 임계·단절 매트릭스.
- [x] **실기 브링업 RG G01** (2026-06-13 입회, 보고서 `docs/reports/2026-06-13-rgg01-bringup.md`): F6/F7 버스 선점·하드 타임아웃(`465b7d9`), F9 E-STOP 복구 관절 재enable 결함 수정 + F10b 조작계 리디자인 + F11 레이턴시(`1d8c6ff`), 실기 벤치 도구(`6df967d`). 단절 매트릭스·10분 분포 등 잔여.
- [x] **App Store 심사 대응 코드** (2026-06-11~13): hardened runtime 예외 제거(`8d62550`, PR #43), device.serial entitlement + CFBundleVersion 자동 bump(`be8ab20`), Claude/Synth App Store 빌드 숨김(`48365e4`), bundle ID·저작권 com.yuseokkim 시나리오 B(`8cee624`), 마스터 플랜(`645a571`, `docs/app-review/2026-06-13-pass-master-plan.md`). **잔여 = 개발자 포털(새 App ID·profile 재발급·새 앱 레코드)·아카이브 실기 검증·데모 영상**.
- [x] **콕핏 레이턴시/3D 뷰포트** (2026-06): 콕핏 HUD 아코디언 + 3D 오버레이 기본 OFF·머리 장식 제거(`9ad2563`). 콕핏 레이턴시 Wave 0~2·부분 W3, 3D 뷰포트 W0~W5 설계는 `docs/design/` 참조(실기 벤치 잔여).

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

- 커밋: `8cdc282` feat(walklab): D-패드 모션 — 위=서기·아래=앉기·좌우=패스 (공식 Action 페이지) — 2026-06-14
- 브랜치: `claude/robotis-darwin-op-setup-oyzTi`
- PR: #1 (draft, MVP 완료 후 갱신)
- 테스트 실측 (2026-06-14): Rust `cargo test --workspace` **382 / 382 통과**(exit 0), 펌웨어 호스트 `make -C firmware-patches/walklab-brokerage/tests` **279 checks / 0 fail**.
- 핸즈오프 문서: [`docs/handoff/2026-06-14-darwinforge-full-handoff.md`](docs/handoff/2026-06-14-darwinforge-full-handoff.md) — 다른 Claude 계정 인계용 전체 구조·현황·다음 작업.
> 직전 체크포인트가 `05ce002`(mobile-relay)에 고정돼 있던 것을 2026-06-14 현행 HEAD(`8cdc282`)로 갱신. 그 사이 12개 커밋(Anbernic 하드닝·게임패드 튜닝·볼-추종·D-패드) 반영.

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

### 통계 (2026-06-14 실측 갱신)

| 항목 | 값 | 근거 |
|------|-----|------|
| Rust workspace tests | **382 / 382 통과** (+ doc-test 2 ignored) | `cargo test --workspace` exit 0 실측 (forge-cli 13, forge-core 322+15, forge-mcp-synth 32) |
| Rust crates | 4 (`forge-core`, `forge-cli`, `forge-ffi`, `forge-mcp-synth`) | `app/core/Cargo.toml` members |
| Rust MSRV | 1.78 (`Cargo.toml rust-version`) — 로컬 toolchain 1.95.0 | README는 'Rust 1.78+ (MSRV; 권장 toolchain 1.94+)'로 정합 |
| Swift 테스트 (선언) | UI 3577 + iOS(app/mobile) 151 `func test*` 선언 — **통과 수 unverified** (swift test 미실행) | 정적 카운트, .build 제외 |
| Mac 앱 버전 | 1.24.0 (`Info.plist` CFBundleShortVersionString) | `scripts/run-app.sh`가 이번 변경으로 Info.plist의 CFBundleShortVersionString을 PlistBuddy(+grep/sed 폴백)로 읽어 번들에 스탬프 — 이전 1.11.2 하드코딩 제거, 드리프트 해소 |
| ally 워크스페이스 | 독립 Cargo workspace, 멤버 5크레이트(df-wire/ally-link/ally-input/ally-pose/ally-cli). `darwin-fpv`(Tauri bin)는 디렉터리·README 자리만·워크스페이스 멤버 미등록(W1 보류) | `app/ally/Cargo.toml` |
| ADR | 14 (ADR-014 `ADR-014-motion-synthesis.md` 포함) | `docs/decisions/` 실측 |

주의: PROGRESS.md의 과거 'NN tests' 수치는 스프린트별 누적 기록이며 워크스페이스 단일 합계가 아니다. 그라운드트루스는 위 382(Rust 실측)/3577 선언(Swift, 통과 수 unverified)를 사용.

## 다음 단계 (사용자 결정)

1. **App Store 재제출** — 코드는 P0/P1 시나리오 B까지 완료(`8d62550`·`be8ab20`·`48365e4`·`8cee624`). 잔여 = 개발자 포털(새 App ID·provisioning profile 재발급·App Store Connect 새 앱 레코드)·아카이브 실기 검증·데모 영상. 플랜 `docs/app-review/2026-06-13-pass-master-plan.md`.
2. **DARwIn FPV W2+** — W0·W1 코드 완료, Ally 기기 유선 실기 게이트 → W2 Tauri 콕핏 → W3(ally-pose↔forge-core)·W4 내구.
3. **WalkLab 실기 게이트** — P7(Anbernic 32/20/L2 온스탠드 스윕), 킥 K3, D1/D2·H1/H2 필드 검증, O3(FSR/IMU 밸런스 피드백) 미착수.
4. **레이턴시/E-STOP 하드닝** — UDP 명령/E-STOP 패스트레인 완비됐으나 Mac 핸드셰이크 미사용으로 100% 미배선. 계측 0샘플·무선 고착(166x) → 설계 `docs/design/cockpit-latency-hardening.md`.
5. (보존) Sprint 11 SwiftUI Synth Palette 통합, V1/V2 validator 실 robot calibration, AVFoundation 카메라 라이브.
