# Sprint 15 — Remote Pilot 구현 요청 프롬프트 (v2 — 공식 데모 충실 버전)

> 이 파일을 그대로 Claude Code 에 붙여넣어 Sprint 15 구현을 시작하세요.
> 사전 조건: `docs/prd/teleop-v1.md` (v2) + `docs/prd/teleop-v1-audit.md` 를 먼저 확인.
> 핵심 원칙: **공식 ROBOTIS 데모 모션은 완벽하다. byte-identical 보존, 호출만 한다.**

---

## 구현 요청 프롬프트

```
다음 명세대로 DarwinForge 앱에 Remote Pilot v2 기능(Sprint 15)을 완전 구현해 줘.
전체 설계는 docs/prd/teleop-v1.md (v2) 에 있어. 모든 결정은 그 PRD 와
docs/prd/teleop-v1-audit.md 의 보강 권고를 따라.

── 핵심 원칙 ─────────────────────────────────────────────────────────────────

1. motion_4096.bin 페이지 데이터는 단 1 byte 도 수정하지 마. ROBOTIS 가
   튜닝한 모션이고 byte-identical round-trip 검증 완료 (Phase B).
2. 페이지 ID, raw_name, mp3 동기, duration_ms 는 page-metadata-motion4096.toml
   의 sidecar 데이터를 그대로 따라. UI 라벨은 display_name 채택.
3. 공식 BallFollower 패턴 (head PID 추적 → head 각도 → walk amplitude) 충실 재현.
4. 공식 StatusCheck 자동 복구 (pitch > 50° → page 10/11 자동) 충실 재현.
5. 기존 306 Rust 테스트 + 70 Swift 테스트 회귀 없이 유지.

── Day 1: Rust forge-core::teleop 기초 ──────────────────────────────────────

1. forge-core/src/teleop/pid.rs (신규)
   - `PidController { kp, ki, kd, integral, prev_err }`
   - `fn update(&mut self, err: f32, dt: f32) -> f32`
   - `fn reset(&mut self)`
   - 단위 테스트 4개 (수렴 / Kp only / Ki saturation / clamp)

2. forge-core/src/teleop/head_tracker.rs (신규)
   - `HeadTracker { pan_pid: PidController, tilt_pid: PidController,
                    pan_limits_deg: (-90, 90), tilt_limits_deg: (-45, 45),
                    frame_size: (320, 240) }`
   - `fn update(&mut self, blob: BlobResult, dt_secs: f32) -> HeadDelta`
     알고리즘:
       err_x = (blob.centroid_x - frame_w/2) / (frame_w/2)
       err_y = (blob.centroid_y - frame_h/2) / (frame_h/2)
       pan_delta  = pan_pid.update(err_x, dt) * 30.0   // ±30°/frame max
       tilt_delta = tilt_pid.update(err_y, dt) * 20.0
   - `fn scan(&self, t_secs: f32) -> HeadDelta` — sinusoidal sweep ±45° / 1Hz
   - 기본 PID: Kp=0.4, Ki=0.0, Kd=0.05 (튜닝 가능 — OQ-7)
   - 단위 테스트 6개

3. forge-core/src/teleop/command.rs
   - `TeleopCommand` enum { Walk { command: WalkCommand, period_ms: u32, max_duration_secs: u32 }, Motion { slot: u8, confirm_risk: bool }, Stop }
   - `safety(&self) -> SafetyClass`, `max_duration_secs(&self) -> u32`
   - JSON serde
   - 단위 테스트 6개

4. forge-core/src/teleop/gate.rs
   - `SafetyGate { armed, last_input_at, deadman_timeout_ms=1000,
                   max_imu_roll_deg=25.0, max_imu_pitch_deg=30.0,
                   fall_threshold_deg=50.0, session_start }`
   - `enum GateReason { NotArmed, RiskNotConfirmed, DeadmanTimeout,
                         ImuTilted { roll, pitch },
                         ImuFallen { pitch, direction: FallDir },
                         SessionExpired { max_secs } }`
   - `enum FallDir { Forward, Backward }`
   - `fn allow(&self, cmd, imu, session_elapsed_secs) -> Result<(), GateReason>`
     - imu pitch > 50° → ImuFallen
     - 25° < |roll| OR 30° < |pitch| ≤ 50° → ImuTilted
   - `fn fall_recovery_page(&self, dir: FallDir) -> u8` (10 or 11)
   - 단위 테스트 14개 (낙상 분기 2 + 통과 + 모든 GateReason 차단)

5. forge-core/src/teleop/ballfollow.rs (v2 head 기반 재작성)
   - `BallFollowConfig { hsv, kick_tilt_threshold_deg=30.0,
                          kick_pan_deadzone_deg=5.0,
                          min_kick_pixel_count=1000,
                          forward_amp=0.025,
                          turn_amp_gain=0.10/90.0,
                          auto_kick=false }`
   - `BallFollowDecision { state: StrategyState, walk_cmd: TeleopCommand,
                            head_delta: HeadDelta, kick_slot: Option<u8>,
                            blob: BlobResult }`
   - `fn decide(&self, frame, head_pan_deg, head_tilt_deg,
                head_tracker: &mut HeadTracker, prev_state) -> BallFollowDecision`
     공식 패턴:
       1. detect_blob(frame, hsv) → blob
       2. if !blob.found(): state=LookingForBall; head_delta=scan(t); walk=scan_turn
       3. head_delta = head_tracker.update(blob, dt)
       4. if |pan| < 5° && tilt > 30° && pixel_count > 1000:
            state=Kicking; walk=Stop; kick_slot=Some(pan>0 ? 12 : 13)
       5. else:
            state=ApproachingBall
            a_amp = -turn_amp_gain * pan_deg
            x_amp = forward_amp * ((30.0 - tilt_deg) / 30.0).max(0.0)
            walk = Walk{x_amp, 0, a_amp, enabled:true}
   - 단위 테스트 10개 (LookingForBall scan, ApproachingBall, Kicking left/right,
                       dead zone, LOST, serde)

6. forge-ffi 에 노출
   - fc_pid_*, fc_head_tracker_*, fc_ballfollow_decide
   - fc_motion_play(slot, dry_run) — 기존 motion_play.rs 래핑
   - cbindgen 헤더 자동 생성

── Day 2: 통합 + 추가 테스트 ──────────────────────────────────────────────────

7. forge-core teleop integration test
   - Mock frame → decide loop 10 cycle → state 흐름 검증
   - cargo test --workspace 전체 330+ pass 확인

── Day 3: Swift 핵심 로직 ────────────────────────────────────────────────────

8. ForgeCore/Teleop.swift (FFI 브릿지)
   - TeleopCommandSwift enum + HeadDelta + GateReason + FallDir + StrategyStateSwift

9. ForgeCore/MotionCatalog.swift (신규)
   - `page-metadata-motion4096.toml` 파싱 (build-script 로 generate or hardcode)
   - `MotionPageMetadata { slot, rawName, displayName, displayNameKo,
                            safetyClass, durationMs, mp3Sync, bodyRegions }`
   - `MotionCatalog.all: [MotionPageMetadata]` (16 페이지)
   - `actionBarMain: [UInt8] = [1, 4, 15, 12, 13, 9, 23]`
   - `actionBarMore: [UInt8] = [2, 3, 10, 11, 16, 24, 27, 38, 54]`
   - displayNameKo 매핑: PRD §5.1 표 그대로
   - 단위 테스트 5개

10. DarwinForgeUI/Remote/PilotTokens.swift (v2 토큰)
    - PilotColor + PilotAnim 모두 PRD §10 명세 그대로 (v2 추가 토큰 포함:
      safetySafe/Caution/HighRisk, headReticle, ballReticle,
      headTrack, fallRecovery)

11. DarwinForgeUI/Remote/HeadJointController.swift (신규)
    - `func write(panDeg: Float, tiltDeg: Float) throws` — SYNC_WRITE
    - `func read() throws -> (panDeg: Float, tiltDeg: Float)`
    - `static func clamp(pan, tilt) -> (Float, Float)` ±90° / ±45°
    - 단위 테스트 4개 (mock Bus)

12. DarwinForgeUI/Remote/TeleopChannel.swift (@MainActor ObservableObject)
    - @Published currentCmd, isDeadmanActive, mode
    - func setMode(_:), func arm(), func disarm(), func send(_ cmd) async throws
    - dead-man 1s 타이머. 캐덴스 USB 100ms / 네트워크 200ms.
    - Motion 분기: confirmRisk 체크 + store.playMotionSlot(slot)
    - 단위 테스트 6개

13. DarwinForgeUI/Remote/PilotSafetyGate.swift (@MainActor ObservableObject)
    - @Published armed, sessionElapsed, maxDuration, imuPitch, imuRoll
    - IMU 구독 (ConnectionStore.lastTelemetry — OQ-6 확인)
    - 단위 테스트 4개

14. DarwinForgeUI/Remote/FallRecoveryCoordinator.swift (신규)
    - @Published autoRecovery: Bool = true
    - @Published lastRecoveryAt: Date?
    - observeImu() — ConnectionStore IMU 구독, pitch > 50° 시 triggerRecovery
    - triggerRecovery(_ dir: FallDir) async — Stop → page 10 또는 11 (confirmRisk: true)
    - 단위 테스트 4개

15. DarwinForgeUI/Remote/BallFollowEngine.swift (v2 재작성)
    - 100 ms 폴링 Task:
      a. MjpegSnapshot.fetch
      b. fc_ballfollow_decide(frame, head_pan, head_tilt, &tracker, prev_state)
      c. head_delta → HeadJointController.write(pan + delta, tilt + delta)
      d. walk_cmd → TeleopChannel.send
      e. kick_slot != nil && autoKick → TeleopChannel.send(.Motion(slot, true))
    - @Published state, blob, currentHeadPan, currentHeadTilt, autoWalk, autoKick
    - HSV config 동적 변경 시 다음 frame 부터 반영
    - 단위 테스트 6개

16. DarwinForgeUI/Remote/MjpegSnapshot.swift
    - func fetch(host: String) async throws -> NSImage
    - URLSession `http://<host>:8080/?action=snapshot`, 타임아웃 3s

── Day 4: 좌측 패널 UI ───────────────────────────────────────────────────────

17. DarwinForgeUI/Remote/PilotArmSlider.swift
    - DragGesture 80% drag → arm() + spring bounce
    - ARM 완료 후:
      a. Toast "보행 자세로 전환 중…"
      b. await teleopChannel.send(.Motion(slot: 9, confirmRisk: false))
      c. duration_ms 대기 (MotionCatalog.find(9).durationMs)
      d. Toast "준비 완료"
      e. D-pad fade in (DFAnimation.smooth)

18. DarwinForgeUI/Remote/PilotModePicker.swift
    - matchedGeometryEffect 세그먼트 thumb
    - 전환 시 1 프레임 Stop 자동 송출 (race 방지)

19. DarwinForgeUI/Remote/PilotDpad.swift
    - 7존 (↑↓←→ + ↶↷ + ◉ 중앙 정지)
    - Hold Ring (1s 충전 → 빨간 flash)
    - 키 W/A/S/D/Q/E/Space + Shift modifier (×1.4)
    - 1..7 키로 Action Bar 트리거 (Day 5)

20. DarwinForgeUI/Remote/PilotSpeedGauge.swift
    - Canvas arc (-130° ~ +130°)
    - 3색 구간 + 한국어 프리셋 이름 + cm 숫자
    - PilotPhaseBar 4 세그먼트 포함

── Day 5: Action Bar (v2 핵심) ──────────────────────────────────────────────

21. DarwinForgeUI/Remote/PilotActionBar.swift
    - 7 버튼 가로 스크롤 (또는 두 줄 4+3)
    - 각 버튼: displayNameKo + raw_name + duration + safety mark + 진행 ring
    - 외곽 색: Safe=forge, Caution=warning, HighRisk=danger
    - HighRisk 클릭 → Alert (confirm)
    - tooltip (500ms hover): raw_name, mp3_sync, duration, safety_class, "source: page N"
    - ⋯ "+ 더 보기" 버튼 → 모달 시트
    - 모달 시트: 9 추가 페이지 (MotionCatalog.actionBarMore) 그리드 표시
    - 키 1..7 = main / Cmd+1..9 = more (선택)
    - 단위 테스트 4개

── Day 6: 카메라 + Ball-Follow E2E ───────────────────────────────────────────

22. DarwinForgeUI/Remote/PilotCameraView.swift (v2)
    - NSImage aspect-fit
    - 오버레이 레이어:
      a. 상태 배지 pill (LOOKING pulse / APPROACHING / LOCKED ON / LOST shake)
      b. blob 십자선 (TargetReticle, PilotColor.ballReticle)
      c. head 십자선 (현재 joint 19/20 → frame 좌표 역계산, PilotColor.headReticle)
      d. blob 정보 pill (픽셀 / 비율 / 거리 추정)
      e. FSM 5단계 progress dots (하단)
      f. Auto-Walk / Auto-Kick 토글 (우하단)
      g. HsvTuningPanel (우하단 접힘 가능)
    - LOCKED ON 시 두 십자선이 합쳐짐 + 외곽 ring pulse
    - 카메라 오프라인 시 empty state + "vision_demo 시작" 버튼

23. DarwinForgeUI/Remote/TargetReticle.swift
    - 4 L자 코너 + 중앙 점
    - LOCKED ON: scale(0.7) 수축 spring
    - LOST: fade out
    - PilotAnim.blobTrack / PilotAnim.headTrack 보간

24. DarwinForgeUI/Remote/HsvTuningPanel.swift (신규)
    - dropdown: 주황(기본) / 빨강 / 노랑 / 파랑 / 사용자 정의
    - 사용자 정의: h_min, h_max, s_min, v_min 슬라이더 4개
    - UserDefaults 영속화 (PilotHsvUserProfile key)
    - 실시간 미리보기: 카메라 frame 의 매칭 픽셀 시각화
    - 단위 테스트 3개

── Day 7: 통합 + HUD + 검증 ──────────────────────────────────────────────────

25. DarwinForgeUI/Remote/PilotHudStrip.swift (v2)
    - 배터리·온도 8세그먼트 블록 바
    - IMU 인공수평선 (80×20 rect, ±30°)
    - 세션 타이머 카운트다운
    - E-Stop 56pt
    - v2 추가: 🔁 자동복구 토글 (FallRecoveryCoordinator.autoRecovery 바인딩)

26. DarwinForgeUI/Remote/RemotePilotView.swift (최상위)
    - 좌 360px / 우 fill 레이아웃
    - 모드별 우측 패널 크로스페이드 (Manual: 3D 메인+카메라 mini / Ball-Follow: 카메라 메인+3D mini)
    - .onKeyPress 글로벌 W/A/S/D/Q/E/Space/1..7/ESC
    - Bus == nil 시 시뮬 배너
    - vision_demo 충돌 감지 배너 + RemoteShellView 링크
    - @EnvironmentObject ConnectionStore
    - @StateObject TeleopChannel, PilotSafetyGate, BallFollowEngine, FallRecoveryCoordinator

27. RootView.swift 변경
    - Section.pilot 추가 (label: "원격 조종", icon: "gamecontroller.fill",
                          shortcut: "⌘8", tint: DFNeon.electric)
    - detail switch case .pilot: RemotePilotView()
    - globalShortcuts ⌘8

28. ConnectionStore.swift 보강 (OQ-6)
    - @Published lastImuRoll: Double = 0
    - @Published lastImuPitch: Double = 0
    - telemetry 폴링에서 CM-730/740 IMU 레지스터 (0x26..0x2B) 읽어 갱신
    - 없으면 0 유지 + UI 에서 "IMU 없음" 표시

29. HIL 시나리오 6 실행 (PRD §15.3) + 통과 캡처

30. 문서 갱신
    - PROGRESS.md: Sprint 15 완료 항목
    - BLOCKERS.md: OQ-7 (PID 튜닝 실측 필요) 등재
    - docs/handoff/sprint-15-pilot-walkthrough.md 신규

── 완료 기준 ──────────────────────────────────────────────────────────────────

✓ cargo test --workspace 전체 ≥ 336 (기존 306 + 신규 30+)
✓ swift build Universal 성공
✓ swift test 전체 ≥ 94 (기존 70 + 신규 24+)
✓ RootView ⌘8 → RemotePilotView 진입
✓ ARM 슬라이더 drag → walkready (page 9) 자동 호출 + D-pad 활성화
✓ ↑ 누름/뗌 → 1s dead-man 정지
✓ Action Bar 7 버튼 모두 (page 1/4/9/12/13/15/23) 송출
✓ "+ 더 보기" 시트 9 페이지 송출
✓ Ball-Follow ON → head 추적 + body 회전 + 좌/우 차기 자동 (auto_kick ON)
✓ pitch 60° 모의 → page 10 또는 11 자동 호출
✓ HSV preset 4종 + 사용자 정의 → 다음 frame 부터 반영
✓ 모든 Action 버튼 tooltip 에 raw_name + mp3 + safety_class 표시

── 안전 주의 ──────────────────────────────────────────────────────────────────

- motion_4096.bin 데이터 byte 1개도 변경 금지
- page 12/13 (HighRisk) 는 confirm_risk 필수
- E-Stop ⌘⇧. 어떤 상태에서도 작동, disable 금지
- Auto-Recovery OFF 시: 낙상 시 모달, 자동 페이지 호출 금지
- forge-core 기존 모듈 (motion, walk, vision, strategy, safety) 코드 변경
  최소화 — teleop 은 호출만, 수정 없음
- ConnectionStore IMU 보강은 추가만, 기존 API 변경 없음

── 참고 파일 (반드시 확인) ──────────────────────────────────────────────────

필수:
- docs/prd/teleop-v1.md (v2 — 전체 명세)
- docs/prd/teleop-v1-audit.md (충실도 점검 + 보강 근거)
- docs/motion-format/page-metadata-motion4096.toml (16 페이지 sidecar)
- docs/motion-format/page-catalog-motion4096.md (페이지 매핑 검증)
- app/core/forge-core/src/walk/preset.rs (WalkPreset)
- app/core/forge-core/src/strategy/mod.rs (StrategyState)
- app/core/forge-core/src/vision/segmentation.rs (detect_blob, BlobResult)
- app/core/forge-core/src/safety/ (precheck_motion, TorqueRamper)
- app/ui/.../DesignSystem/ (DFColor, DFNeon, DFAnimation, KoreanUX)

공식 데모 참조:
- research/robotis-official/ROBOTIS-OP2/op2_walking_module/ (X/Y/A amplitude)
- research/robotis-official/ROBOTIS-OP2/op2_manager/src/op2_manager.cpp
- docs/HARDWARE_VERIFICATION_PROTOCOL.md (안전 절차)

Sprint 15 시작. 7일 추정. PROGRESS.md + BLOCKERS.md 동시 갱신.
완료 시 PR 본문에 6 HIL 시나리오 결과 + 신규 테스트 수 + 회귀 확인 포함.
```
