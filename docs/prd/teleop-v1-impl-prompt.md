# Sprint 15 — Remote Pilot 구현 요청 프롬프트

> 이 파일을 그대로 Claude Code 에 붙여넣어 Sprint 15 구현을 시작하세요.
> 사전 조건: `docs/prd/teleop-v1.md` 를 먼저 읽었거나 같이 첨부할 것.

---

## 구현 요청 프롬프트

```
다음 명세에 따라 DarwinForge 앱에 Remote Pilot 기능(Sprint 15)을 완전 구현해 줘.
설계 근거와 상세 명세는 docs/prd/teleop-v1.md 에 있어. 모든 결정은 그 PRD 를 따라.

── 구현 범위 ─────────────────────────────────────────────────────────────────

[Rust / forge-core] forge-core/src/teleop/ 신규 모듈 (Day 1)

1. teleop/command.rs
   - `TeleopCommand` enum { Walk { command: WalkCommand, period_ms: u32, max_duration_secs: u32 }, Motion { slot: u8, confirm_risk: bool }, Stop }
   - `impl TeleopCommand { fn safety(&self) -> SafetyClass; fn max_duration_secs(&self) -> u32 }`
   - JSON serde 지원. 단위 테스트 6개.

2. teleop/gate.rs
   - `SafetyGate` struct { armed: bool, last_input_at: Instant, deadman_timeout_ms: u64=1000, max_imu_roll_deg: f32=25.0, max_imu_pitch_deg: f32=30.0, session_start: Option<Instant> }
   - `fn allow(&self, cmd: &TeleopCommand, imu: Option<ImuSample>, session_elapsed_secs: u32) -> Result<(), GateReason>`
   - `GateReason` enum { NotArmed, RiskNotConfirmed, DeadmanTimeout, ImuOutOfRange { roll, pitch }, SessionExpired { max_secs } }
   - 단위 테스트 10개 (4 gate 각 차단 + 통과 케이스).

3. teleop/ballfollow.rs
   - `BallFollowConfig` { hsv: HsvRange(기본 ROBOCUP_BALL), close_pixel_threshold: u32=1000, turn_dead_zone_px: f32=30.0, max_turn_rate: f64=0.15, forward_amplitude: f64=0.020 }
   - `fn decide(&self, frame: &Frame, prev_state: StrategyState, since_kick_ms: u32) -> BallFollowDecision`
   - `BallFollowDecision { state: StrategyState, command: TeleopCommand, blob: BlobResult }`
   - 알고리즘: LOOKING=좌회전 scan(a=0.15), APPROACHING=centroid offset→(x, a), KICKING=Stop, Cooldown=Stop
   - 단위 테스트 8개.

4. forge-ffi/src/teleop.rs
   - `fc_ballfollow_decide(frame_ptr, w, h, prev_state_raw, since_kick_ms) -> fc_ballfollow_result`
   - `fc_motion_play(slot: u8, dry_run: bool) -> c_int`  (기존 motion_play.rs 래핑)
   - cbindgen 헤더 자동 생성 확인.

5. teleop/mod.rs — pub use 재수출. `cargo test` 전체 pass 확인.

── [Swift] 신규 Swift 파일 14개 ──────────────────────────────────────────────

위치: app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/
ForgeCore 브릿지는 app/ui/DarwinForge/Sources/ForgeCore/

[Day 2] 핵심 로직

6. Remote/PilotTokens.swift
   - `PilotColor` enum — dpadActive/Idle, speedSafe/Caution/Danger, stateIdle/Looking/Approach/LockedOn/Lost, holdCharging/Full
   - `PilotAnim` enum — dpadPress, stateChange, gauge, motionProgress, modeSwitch, lockPop, blobTrack 모두 정의
   - PRD §4 의 모든 토큰 그대로.

7. Remote/TeleopChannel.swift  (@MainActor ObservableObject actor)
   - `@Published currentCmd: TeleopCommand = .Stop`
   - `@Published isDeadmanActive: Bool = false`
   - `func send(_ cmd: TeleopCommand) async throws` — gate 평가 → dispatch → resetDeadman
   - deadman 1 s 타이머 자동 Stop 송출
   - 명령 캐덴스: USB 100ms / 네트워크 200ms (ConnectionStore.activeEndpoint 판단)
   - WalkPreset 5종 실송출 (v1 범위) — `store.bus?.applyWalkPreset(preset)` 공유 헬퍼 연결
   - Motion slot: `fc_motion_play(slot, dryRun: false)` ffi 호출
   - Swift 단위 테스트 8개 (mock Bus payload / dead-man / gate fail 4종).

8. Remote/PilotSafetyGate.swift  (@MainActor ObservableObject)
   - `@Published armed: Bool = false`
   - `@Published sessionElapsed: TimeInterval = 0`
   - `@Published maxDuration: TimeInterval = 60`
   - IMU roll/pitch 구독 (ConnectionStore.lastTelemetry 확장 필요 — OQ-6)
   - `func arm()` / `func disarm()` / `func reset()`
   - Swift 단위 테스트 4개 (arm/disarm / IMU threshold / session expiry).

9. Remote/BallFollowEngine.swift  (@MainActor ObservableObject)
   - `@Published state: StrategyStateSwift = .idle`
   - `@Published blob: BlobResultSwift = .none`
   - `@Published autoWalk: Bool = false`
   - `@Published autoKick: Bool = false`
   - 100ms 폴링 Task: `MjpegSnapshot.fetch` → `fc_ballfollow_decide` → `TeleopChannel.send`
   - autoKick ON + LOCKED_ON → `TeleopChannel.send(.Motion(slot: 12, confirmRisk: true))`
   - Swift 단위 테스트 4개.

10. Remote/MjpegSnapshot.swift
    - `func fetch(host: String) async throws -> NSImage`
    - URLSession 기반 `http://<host>:8080/?action=snapshot` GET
    - 타임아웃 3 s. 실패 시 nil 반환 (crash 없음).

[Day 3] D-pad + 계기판 컴포넌트

11. Remote/PilotArmSlider.swift  (SwiftUI View)
    - DragGesture 기반 밀어서 ARM 슬라이더
    - drag > 80% → arm() 호출 + spring bounce 아이콘 전환 (lock.fill → lock.open.fill)
    - 미완성 drag → 원래 위치로 spring 복귀
    - 활성 배경: DFColor.success.opacity(0.15) 페이드인 (DFAnimation.smooth)

12. Remote/PilotModePicker.swift  (SwiftUI View)
    - 애니메이션 세그먼트 피커: 선택 thumb 이 matchedGeometryEffect 로 슬라이드
    - Manual: "🕹 수동 조종" / Ball-Follow: "🎯 공 팔로우"
    - 전환 시 PilotAnim.modeSwitch 크로스페이드

13. Remote/PilotDpad.swift  (SwiftUI View)
    - 7존 레이아웃 (↑↓←→ 4방향 + ↶↷ 회전 2 + ◉ 중앙 정지)
    - 각 버튼: mouseDown→scale(0.88)+PilotColor.dpadActive / mouseUp→scale(1.0)+idle
    - Hold Ring: 누르는 동안 원형 progress 0→1 (1s linear) + 완료 시 빨간 flash
    - .onKeyPress W/A/S/D/Q/E/Space 연결
    - Shift modifier: 속도 × 1.4 (x_amplitude 증가)
    - ARM false 시 `.dfDisabled(true)` + 회색 overlay
    - PRD §5.3 의 WalkPreset 매핑 그대로.

14. Remote/PilotSpeedGauge.swift  (SwiftUI View)
    - Canvas 기반 arc (-130° ~ +130°, 260° sweep)
    - 3색 구간 (success/warning/danger), arc 두께 6pt
    - 중앙: 프리셋 한국어 이름 + 보폭 cm 숫자
    - PilotPhaseBar 를 하단에 포함 (4 세그먼트 36×8, electric/elev2)

[Day 4] 카메라 + AR HUD

15. Remote/PilotCameraView.swift  (SwiftUI View)
    - NSImage 표시 (aspect-fit)
    - 오버레이 레이어:
      a. 상태 배지 pill (IDLE/LOOKING/APPROACHING/LOCKED ON/LOST)
         - LOOKING: 1Hz pulse (opacity withAnimation repeat)
         - LOCKED ON: 외곽 pulse + scale
         - LOST: horizontal shake (3 cycle)
      b. TargetReticle (blob centroid 위치, PilotAnim.blobTrack 보간)
      c. Blob 정보 pill (픽셀수·비율·거리 추정)
      d. FSM 5단계 progress dots (하단)
      e. Auto-Walk 토글 (우하단 mini, DFColor.success/textSecondary)
    - 카메라 오프라인 시: 에러 empty state + "vision_demo 시작" 버튼

16. Remote/TargetReticle.swift  (SwiftUI View)
    - 4개 L자 코너 + 중앙 점
    - LOCKED ON: 코너 scale(0.7) spring 수축
    - LOST: 코너 opacity(0) fade
    - 전환 PilotAnim.blobTrack 보간

[Day 5] HUD Strip + 전체 통합

17. Remote/PilotHudStrip.swift  (SwiftUI View)
    - 배터리 8세그먼트 블록 바 (DFAnimation.standard 갱신)
    - 온도 8세그먼트 + 60°C pulse
    - IMU 인공수평선 (80×20 rect, 이동 점 ◉, ±30° 매핑)
    - 세션 타이머 (경과/최대, progress 바, 마지막 10s pulse)
    - E-Stop 버튼 56pt DFColor.danger ⌘⇧.

18. Remote/RemotePilotView.swift  (최상위 화면)
    - DFPageScaffold or 커스텀 layout (scaffold 없이 full-bleed 가능)
    - 좌측 360px fixed: ARM 슬라이더 → 모드 토글 → D-pad + 속도계 → Action Bar
    - 우측 fill: 모드에 따라 카메라(메인)+3D(mini) or 3D(메인)+카메라(mini) 크로스페이드
    - HUD Strip 하단 고정
    - .onKeyPress 글로벌 W/A/S/D/Q/E/Space/1..4/ESC
    - Bus == nil 시 상단 배너 "시뮬 모드 — 실 로봇 연결 안 됨"
    - vision_demo 충돌 감지 배너 (ConnectionStore.activeEndpoint + port 확인)
    - @EnvironmentObject ConnectionStore, @StateObject TeleopChannel, PilotSafetyGate, BallFollowEngine

19. RootView.swift 변경
    - Section.pilot 추가 (label: "원격 조종", icon: "gamecontroller.fill", shortcut: "⌘8", tint: DFNeon.electric)
    - detail switch case .pilot: RemotePilotView()
    - globalShortcuts Button "Section 8" ⌘8

── 추가 보강 (기존 파일 소규모 수정) ──────────────────────────────────────────

20. ConnectionStore.swift 보강
    - `@Published lastImuRoll: Double = 0`
    - `@Published lastImuPitch: Double = 0`
    - telemetry 폴링에서 CM-730/740 IMU 레지스터 읽어 갱신 (가능한 경우)
    - 없으면 0으로 유지 + PilotHudStrip 에서 "IMU 없음" 표시

21. WalkLab.swift / ConnectionStore.swift 보강
    - 기존 WalkLab 의 walk→실 로봇 적용 로직을 `ConnectionStore.applyWalkPreset(_:)` 공유 헬퍼로 추출
    - TeleopChannel 과 WalkLab 둘 다 동일 헬퍼 사용

── 완료 기준 ──────────────────────────────────────────────────────────────────

- `cargo test --workspace` 전체 통과 (기존 306 + 신규 24+ = 330+ 목표)
- `swift build` Universal binary 성공
- `swift test` 전체 통과 (기존 70 + 신규 18+ = 88+ 목표)
- RootView ⌘8 으로 RemotePilotView 진입 확인
- ARM 슬라이더 drag → D-pad 활성화 확인
- ↑ 누름/뗌 → WalkCommand 송출 + 1s dead-man 정지 확인 (sim 로그)
- Action 버튼 "서기" → progress ring 2s 진행 확인
- Ball-Follow 모드 전환 → 우측 패널 크로스페이드 확인

── 안전 주의 ──────────────────────────────────────────────────────────────────

- `--engage` flag 없는 dry-run 기본. 실 모터 명령은 ARM 완료 + Bus 연결 상태에서만.
- HighRisk 명령 (Jog 프리셋 / page 12 차기) 은 confirm 다이얼로그 필수.
- E-Stop ⌘⇧. 는 언제나 작동. 절대 disable 금지.
- 기존 306 Rust 테스트 / 70 Swift 테스트 모두 회귀 없이 유지.
- `forge-core` 기존 모듈 (motion, walk, vision, strategy) 코드 변경 최소화.
  teleop 은 기존 API 를 호출만 하고 수정하지 않는다.

── 참고 파일 ──────────────────────────────────────────────────────────────────

- docs/prd/teleop-v1.md          ← 이 구현의 전체 명세
- docs/walk-lab/V1_DESIGN.md     ← WalkPreset 8종 정의
- app/ui/.../DesignSystem/DesignTokens.swift   ← DFColor, DFFont, DFAnimation
- app/ui/.../DesignSystem/GlassNeon.swift      ← DFNeon, GlassModifier
- app/ui/.../DesignSystem/KoreanUX.swift       ← 한국어 텍스트 상수
- app/ui/.../DarwinForgeUI/Walk/WalkLab.swift  ← 기존 walk 실송출 참고
- app/core/forge-core/src/walk/preset.rs       ← WalkPreset enum
- app/core/forge-core/src/strategy/mod.rs      ← StrategyState FSM
- app/core/forge-core/src/vision/segmentation.rs ← detect_blob, BlobResult
- docs/HARDWARE_VERIFICATION_PROTOCOL.md       ← 안전 절차

Sprint 15 시작. PROGRESS.md 와 BLOCKERS.md 도 갱신해 줘.
```
