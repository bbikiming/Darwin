# Wave 4 Plan — God Object 분할 (별도 세션 진행 권장)

> **결론 먼저**: 세 god object 모두 책임 분리는 명확하지만 `@Observable` macro (WalkLabSession) 와 SwiftUI `@State` (MotionStudioView) 가 분할을 어렵게 만든다. 권장 패턴은 (1) value-type state struct + actor 로 mutation/concurrency 분리, (2) sub-View + sub-ObservableObject 로 View 분할. WalkLabSession 은 이미 15개 extension 분할 완료(스토리지 잔존 본체 2,599줄), MotionStudioView 는 단일 struct (분할 0건).

작성: 2026-05-23 (사이클 244 직전)
근거: `docs/architecture/reference-research-2026-05.md` + audit (사이클 240 분석 결과)

## 권장 실행 순서 (위험도 역순)

1. **Wave 4.3 (MotionStudioView)** — 가장 안전 (test 3 file). View 분할 패턴 확립.
2. **Wave 4.2 (ConnectionStore)** — health 먼저. Phase 4.2.3 (TelemetryPoller actor) 는 Wave 4.1.4 와 같은 PR.
3. **Wave 4.1 (WalkLabSession)** — 가장 위험. Phase 4.1.1-2 (struct) 만 단독 가능, actor phase 는 Wave 4.2.3 와 묶음.

## 1. WalkLabSession (2,599 lines, 24 MARK sections, 178 method/property)

### 잔존 책임 (이미 15개 +extension.swift 분할 후)
- L33-230: stored property + UI input (~200)
- L431-688: v2 pipeline handoff wiring + monitoring publish (~260)
- L692-980: 실 robot store attach + preflightStatus (~290)
- L981-1500: timer + engine + walkCycleTask + harness DI + preset apply (~520)
- L1499-1660: 실 보행 cycle 송출 facade (~160)
- L1815-2599: 기존 extension 영역 잔존 (이미 부분 분할)

### 분할 단위
| Module | 책임 | LOC | Type | 회귀 위험 |
|---|---|---|---|---|
| `WalkInputState` | UI slider 13개 묶음 | ~180 | struct (Sendable) | LOW |
| `WalkSafetyState` | balanceState/safetyTimeline/preflightStatus | ~280 | struct | MED |
| `WalkLabViewModel` | @Observable, view publish | ~450 | @MainActor class | LOW |
| `WalkEngineRuntime` | 50Hz gyro loop + walkCycleTask | ~450 | **actor** (Swift 6) | **HIGH** |
| `WalkSafetyMonitor` | predictor / fall prediction (이미 +Ext) | ~300 | actor | MED |
| `WalkLabRecorder` | IMU ring buffer + session logger | ~200 | actor | MED |
| `WalkPresetApplier` | preset → keyframe / tuning | ~150 | struct | LOW |
| `WalkRobotBridge` | store?/pilotBridge?/onboardBridge facade | ~250 | class | MED |
| **facade WalkLabSession** | composition entry | ~400 | class | — |

### Phase (총 6 사이클)
- 4.1.1: WalkInputState 추출 (LOW)
- 4.1.2: WalkSafetyState 추출 (MED — view binding)
- 4.1.3: WalkLabRecorder actor (MED — sample timing)
- 4.1.4: **WalkEngineRuntime actor** (HIGH, 2 사이클) — 50Hz closed-loop, freshness gate 위험. 측정 test 먼저 RED → GREEN
- 4.1.5: WalkPresetApplier + WalkRobotBridge facade
- 4.1.6: 본체 facade ~400 lines 검증

## 2. ConnectionStore (1,595 lines, 14 MARK sections, 44 @Published)

### 잔존 책임 (extension 없음)
- L8-280: enum + 44 @Published
- L340-600: lifecycle (connect/disconnect/autoConnect/reconnect)
- L440-535: auto-reconnect exponential backoff
- L602-935: pose apply (applyPoseSmoothly)
- L936-1392: E-stop + recovery
- L1393-1595: per-joint helper + runImuLoop (50-200ms) + runTelemetryLoop (1Hz)

### 분할 단위
| Module | 책임 | LOC | Type | 회귀 위험 |
|---|---|---|---|---|
| `ConnectionTransportStore` | port enum / connect / disconnect | ~350 | @MainActor class | LOW |
| `ReconnectCoordinator` | exponential backoff | ~150 | actor | MED |
| `TelemetryPoller` | runTelemetryLoop + runImuLoop | ~350 | **actor** | **HIGH** (50ms IMU) |
| `ConnectionHealthStore` | counters / latency / imuFilter | ~250 | @MainActor class | LOW |
| `ConnectionRecoveryService` | E-stop + recover | ~300 | @MainActor class | MED |
| `PoseApplyService` | applyPoseSmoothly | ~250 | @MainActor class | MED |
| **facade ConnectionStore** | composition | ~150 | class | — |

### Phase (총 6 사이클)
- 4.2.1: ConnectionHealthStore (LOW)
- 4.2.2: ConnectionTransportStore (LOW)
- 4.2.3: **TelemetryPoller actor** (HIGH, 2 사이클) — Wave 4.1.4 와 동시 PR
- 4.2.4: ConnectionRecoveryService
- 4.2.5: ReconnectCoordinator + PoseApplyService
- 4.2.6: facade backward-compat property delegate

## 3. MotionStudioView (1,641 lines, 13 MARK sections, 40 methods)

### 잔존 책임 (분할 0건, 단일 struct)
- L33-60: @State 15개 + Harness DI
- L60-246: body + shortcut + Synth/Teach import + aiBuilder runner
- L248-329: AI Motion Builder
- L330-585: Sidebar
- L587-981: Center (3D + timeline + sourceMode badge)
- L983-1040: Right inspector
- L1042-1265: Actions + page management
- L1266-1390: copy/paste/split helpers
- L1391-1641: starter document extension

### 분할 단위
| Module | 책임 | LOC | Type | 회귀 위험 |
|---|---|---|---|---|
| `MotionDocumentStore` | motion/selectedIdx/undo-redo/copiedStep | ~280 | @Observable class | LOW |
| `MotionStudioToolbar` | 저장/로드/공유/sendToHardware | ~120 | View | LOW |
| `MotionStudioSidebar` | page list + category + context menu | ~360 | View | LOW |
| `MotionStudioCanvas` | RobotScene3D + sourceMode badge | ~250 | View | LOW |
| `MotionStudioTimeline` | step row + playback bar | ~200 | View | MED |
| `MotionStudioInspector` | rightColumn wrapper | ~80 | View | LOW |
| `MotionAIBuilderPanel` | aiBuilderPanel + runAIBuilder | ~120 | View + VM | LOW |
| `MotionPageActions` | add/duplicate/delete/export 정적 | ~200 | struct | LOW |
| `StarterMotionLibrary` | 5 prebundled motion pages | ~150 | struct | LOW |
| **facade MotionStudioView** | GeometryReader composition | ~120 | View | — |

### Phase (총 6 사이클)
- 4.3.1: StarterMotionLibrary 분리 (LOW)
- 4.3.2: MotionDocumentStore 추출
- 4.3.3: MotionPageActions 정적 함수 분리
- 4.3.4: MotionAIBuilderPanel + VM
- 4.3.5: Sidebar + Inspector
- 4.3.6: Canvas + Timeline (HIGH — sourceMode 4-case + camera)

## 리스크 평가

- **HIGH**: 4.1.4 + 4.2.3 actor phase — 50ms IMU polling + 50Hz gyro closed-loop freshness gate (250ms) 침해 위험. **반드시 timing test 먼저 RED → GREEN**. 사이클 159 `imuFastPollActive` flag 가 actor 사이 흐름 명시 설계 필요.
- **MED**: ObservableObject (ConnectionStore) ↔ @Observable (WalkLabSession) mix → view invalidation 영역 불일치 가능. ConnectionStore 도 @Observable 마이그레이션 추가 사이클 검토.
- **MED**: W3.3 batch migration 미완 시 init signature 충돌 — Wave 4 진입 gate = W3.3 100% merge (완료됨)
- **컨텍스트 50%**: 18 phase 한 세션 진행 시 폭증 → **사이클 1 phase 원칙** 강제
- **HARD-GATE**: actor 추출 phase 는 특히 critical, `/plan` 으로 phase scope 재확정 필수

## 영향 받는 테스트

- WalkLab: WalkLabV1147SimUnblockTests, WalkLabV1114FeedbackLoopTests, WalkLabV1124AuditFixesTests, WalkLabV115OnboardEngineTests, WalkLabGyroClosedLoopIntegrationTests, WalkLabBalanceFreshnessTests, WalkLabFreshnessTelemetryTests, WalkLabPresetCommandIntegrationTests, WalkLabRCBridgeTrialTests, WalkLabRCBridgeEmergencyTests, WalkLabRCBridgeStickTests, WalkTrialAutoGeneratorTests, WalkLabSessionExtensionCoverageTests, WalkLabOnboardSchemaWarningTests
- Connection/Pilot: HarnessRealRobotSmokeTests, HarnessDIMigrationTests, FiveSourcePilotPipelineTests, PilotConcurrentStressTests, PilotEndToEndCohesionTests, MultiSourceRaceTests
- Motion: StarterMotionLibraryTests, MotionPlayerSmokeTests

권장: backward-compat computed property delegate 로 test 무수정 유지 (struct 추출 phase). actor 추출 phase 부터는 await 필요 → signature 변경.
