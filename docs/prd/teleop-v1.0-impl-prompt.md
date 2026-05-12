# Sprint 15 — Remote Pilot v1.0 구현 요청 프롬프트

> **3~4일 안에 동작하는 PR 머지가 목표**.
> 사전 조건: `docs/prd/teleop-v1.md` (v3 = 단일 설계 + 단계별 활성화) 정독.
> 핵심 원칙: **공식 데모 모션 7개 (`motion_4096.bin` page 1·4·9·12·13·15·23) 만 실 모터 송출**. 나머지는 UI 만 v1.5 최종 형태 + "준비 중" 배지.

---

## 구현 요청 프롬프트

```
다음 명세대로 DarwinForge 앱에 Remote Pilot v1.0 (Sprint 15) 을 구현해 줘.
전체 설계: docs/prd/teleop-v1.md (v3). 본 단계의 가치: "ARM 후 Action Bar 7
페이지를 실 로봇에 정확히 송출 + 최종 UI 스캐폴드 완성 + 안전 게이트 L0/L1/L2".

── 핵심 원칙 ─────────────────────────────────────────────────────────────────

1. motion_4096.bin 페이지 데이터는 단 1 byte 도 수정 금지 (byte-identical).
2. 페이지 ID / raw_name / mp3 / duration 은 docs/motion-format/page-metadata-motion4096.toml
   의 sidecar 그대로 사용.
3. v1.0 에서 실제 송출되는 페이지는 7개만: 1, 4, 9, 12, 13, 15, 23.
4. UI 는 v1.5 최종 레이아웃 그대로. 비활성 기능은 ComingSoonOverlay 적용.
5. 기존 306 Rust + 70 Swift 테스트 회귀 0.
6. 신규 코드 최소 — 검증된 forge motion play 의 로직만 라이브러리로 추출.

── Day 1: forge-core motion player 라이브러리 추출 (Reality-check C1 해결) ──

1. forge-core/src/motion/player.rs (신규)
   - `MotionPlayer` struct — bus, opts, current_task_handle
   - `fn play_pages(&mut self, pages: &[MotionPage], opts: ExecuteOptions) -> Result<()>`
     - precheck_motion 호출
     - 각 step decode (INVALID/TORQUE_OFF mask 처리)
     - SYNC_WRITE goal_position
     - (pause + time) × 8 ms wait
     - chain follow_next 옵션 (v1.0 default OFF — page 9/12/13/15/23 단발만)
   - `fn cancel(&mut self)` — 진행 중인 wait 중단, 다음 step 송출 안함
   - 단위 테스트 6개:
     - precheck_motion HighRisk + !confirm_risk 거부
     - INVALID bit 처리 (해당 관절 미송출)
     - TORQUE_OFF bit 처리 (해당 관절 torque 0)
     - cancel 호출 시 즉시 정지
     - 7 페이지 ID 모두 load 가능
     - JSON round-trip

2. forge-core/src/motion/mod.rs
   - pub mod player; pub use player::MotionPlayer;

3. forge-cli/src/motion_play.rs
   - 본 라이브러리 사용으로 단순화 (기존 동작 유지)
   - cargo test 회귀 0 확인

── Day 2: forge-ffi 노출 (Reality-check C1 + C11) ───────────────────────────

4. forge-ffi/src/lib.rs 추가
   - `fc_motion_play_slot(handle, slot, bin_path, dry_run, confirm_risk,
                          single_foot_ok, follow_chain, max_depth) -> c_int`
     - bin_path 가 NULL 이면 기본 motion_4096.bin (research/...) 사용
     - dry_run=1 이면 stdout 로그만
     - return: 0=OK, 음수=에러
   - `fc_motion_play_cancel(handle) -> c_int` — 진행 중인 motion task 취소
   - `fc_motion_play_is_running(handle) -> c_int` — 0 or 1
   - cbindgen 헤더 자동 재생성 (build.rs)
   - FFI 통합 테스트 4개

── Day 3: Swift 핵심 컴포넌트 (UI 골격) ──────────────────────────────────────

5. ForgeCore/MotionCatalog.swift (신규)
   - `MotionPageMetadata { slot: UInt8, rawName: String, displayName: String,
                            displayNameKo: String, safetyClass: SafetyClass,
                            durationMs: UInt32, mp3Sync: String?,
                            bodyRegions: [String] }`
   - `MotionCatalog.all: [MotionPageMetadata]` — 16 페이지 hardcode
     (sidecar TOML 을 build-time 자동 생성 또는 직접 코딩, v1.0 에서는 hardcode 충분)
   - displayNameKo 매핑 (PRD §7.1/§7.2 표):
     1: "기본 자세", 4: "감사 인사", 15: "앉기", 12: "오른발 차기",
     13: "왼발 차기", 9: "보행 자세", 23: "출발!",
     2: "끄덕임", 3: "가로젓기", 10: "앞 일어서기", 11: "뒤 일어서기",
     16: "일어서기", 24: "감탄", 27: "실수", 38: "손 흔들기", 54: "박수 요청"
   - `actionBarMain: [UInt8] = [1, 4, 15, 12, 13, 9, 23]`
   - `actionBarMore: [UInt8] = [2, 3, 10, 11, 16, 24, 27, 38, 54]`
   - `find(slot:) -> MotionPageMetadata?`
   - 단위 테스트 3개

6. DarwinForgeUI/Remote/PilotFeatureFlags.swift (신규)
   - PRD §4.1 그대로
   - default `.active = .v1_0`
   - 단위 테스트 1개 (v1.0/v1.1/v1.5/v2 매트릭스 정합)

7. DarwinForgeUI/Remote/PilotTokens.swift (신규)
   - PilotColor + PilotAnim (PRD §6)

8. DarwinForgeUI/Remote/TeleopChannel.swift (@MainActor ObservableObject)
   - @Published currentCmd: TeleopCommandSwift = .stop
   - @Published isPlaying: Bool = false
   - @Published lastError: String?
   - func arm() async — PRD §5.2 ARM 시퀀스:
     [1] dxl_power=1 via fc_bus_set_dxl_power
     [2] all joints torque ramp (이미 존재 — JointController 활용)
     [3] toast "보행 자세로 전환 중…"
     [4] fc_motion_play_slot(slot=9, confirm_risk=0)
     [5] await duration_ms (MotionCatalog.find(9).durationMs)
     [6] toast "준비 완료"
   - func disarm() async — Task.cancel + (선택) dxl_power=0
   - func sendMotion(slot: UInt8, confirmRisk: Bool) async throws
     - precheck via metadata.safetyClass
     - fc_motion_play_slot 호출
     - currentMotionTask 보존
   - func emergencyStop() async — PRD §5.3:
     - cancel motion task
     - bus.emergencyStop()
     - currentCmd = .stop
     - safety gate disarm
     - flash red UI 신호
   - 단위 테스트 5개 (motion send / cancel / e-stop / arm sequence / disarm)

9. DarwinForgeUI/Remote/PilotSafetyGate.swift (@MainActor ObservableObject)
   - @Published armed: Bool = false
   - @Published flashRed: Bool = false   // E-stop 시 0.3s flash
   - L1/L2 만 (v1.0)
   - func allowMotion(_ meta: MotionPageMetadata, confirmRisk: Bool) -> GateResult
   - 단위 테스트 2개

10. DarwinForgeUI/Remote/ComingSoonOverlay.swift (신규)
    - PRD §4.2 그대로
    - View modifier `.comingSoon(stage:title:why:when:alternative:)`
    - 단위 테스트 1개 (modifier가 비활성 view 에 overlay 추가)

11. DarwinForgeUI/Remote/PilotArmSlider.swift
    - DragGesture 80% drag → arm()
    - drag 완료 spring bounce, 미완성 시 원위치
    - ARM 후 잠금 아이콘 lock.fill → lock.open.fill
    - 단위 테스트 2개 (완료 trigger / 미완성 reset)

12. DarwinForgeUI/Remote/PilotActionBar.swift (v1.0 메인 7 버튼)
    - 7 버튼: MotionCatalog.actionBarMain 그대로
    - 각 버튼:
      a. 라벨: displayNameKo
      b. 아래: raw_name + duration + safety mark
      c. progress ring (재생 중)
      d. tooltip (500ms hover): raw_name / mp3 / duration / safety / "source: motion_4096.bin page N" / "v1.0 활성"
    - HighRisk 클릭 → Alert "위험 동작 확인"
    - 키 1..7 매핑
    - "+ 더 보기" 버튼: ComingSoonOverlay "v1.5 활성"
    - 단위 테스트 3개

13. DarwinForgeUI/Remote/PilotModePicker.swift
    - 두 옵션: Manual / Ball-Follow
    - Manual: 항상 활성
    - Ball-Follow: ComingSoonOverlay "v1.1 활성 — head 추적, v1.5 — 카메라+walk"
    - matchedGeometryEffect 슬라이드

14. DarwinForgeUI/Remote/PilotDpad.swift (v1.0 sim only)
    - 7 존 (↑↓←→ + ↶↷ + ◉ 정지)
    - 누름 시 sim WalkEngine.setCommand (시각 미리보기만)
    - flags.dpadRealMotor=false → 실 모터 송출 코드 경로 자체가 빠짐
    - 컴포넌트 외곽에 작은 "v2 활성 — 실 보행 IK 후" 라벨 (overlay 아님, 인라인)
    - 키 W/A/S/D/Q/E/Space 매핑 (sim)

15. DarwinForgeUI/Remote/PilotSpeedGauge.swift
    - sim 만 — D-pad sim 입력에 반응
    - PRD §11 v1 (이전) §5.4 명세 그대로
    - Phase 4 segment bar 하단 포함

16. DarwinForgeUI/Remote/PilotCameraView.swift (v1.0 비활성)
    - 회색 placeholder + "카메라 v1.5 활성" 배지
    - ComingSoonOverlay 적용
    - 탭 → sheet: "robot-side mjpg-streamer 셋업 가이드 (Sprint 17)"
    - sheet 내 링크: RemoteShellView 의 vision-start QuickAction (이미 존재)

17. DarwinForgeUI/Remote/PilotHudStrip.swift (v1.0 부분)
    - V·T·세션 타이머·E-Stop: 활성
    - IMU 인공수평선 + 자동복구 토글: ComingSoonOverlay "v1.1 활성"
    - E-Stop 56pt button → TeleopChannel.emergencyStop()

18. DarwinForgeUI/Remote/RemotePilotView.swift (최상위)
    - 좌 360px / 우 fill
    - 좌측: ARM 슬라이더 → Mode Picker → Speed Gauge + D-pad → Action Bar
    - 우측: (모드별 크로스페이드) Camera (placeholder) + 3D 로봇 뷰 (sim) + HUD strip
    - .onKeyPress 글로벌: 1..7 Action / W/A/S/D/Q/E/Space sim D-pad / ESC disarm
    - @EnvironmentObject ConnectionStore
    - @StateObject TeleopChannel + PilotSafetyGate
    - Bus == nil 시 배너 "시뮬 모드 — 실 로봇 연결 안 됨"
    - 단위 테스트 2개

19. RootView.swift 변경
    - Section.pilot 추가:
      label: "원격 조종", icon: "gamecontroller.fill",
      shortcut: "⌘8", tint: DFNeon.electric
    - detail switch case .pilot: RemotePilotView()
    - globalShortcuts ⌘8 추가

── Day 4: HIL 시나리오 + 마무리 ──────────────────────────────────────────────

20. HIL 시나리오 4건 (PRD §2.1):
    1. ARM 슬라이더 → walkready 자동 호출 (3D 뷰가 자세 변화 표시)
    2. "감사 인사" 클릭 → 3.6s progress ring + 실 모터 동작
    3. "오른발 차기" 클릭 → HighRisk confirm → 1.7s 차기 (cradle 거치 필수)
    4. 차기 중 ⌘⇧. → 즉시 모터 토크 OFF + 다음 step 송출 X
    각 시나리오 결과 docs/handoff/teleop-v1.0-hil.md 에 캡처

21. 회귀 확인
    - cargo test --workspace = 기존 306 + 신규 14 = 320 pass
    - swift test = 기존 70 + 신규 14 = 84 pass
    - cargo clippy / fmt 모두 GREEN

22. 문서 갱신
    - PROGRESS.md: Sprint 15 v1.0 완료
    - BLOCKERS.md: 그대로 (C3 = v2 결정 후)
    - docs/handoff/teleop-v1.0-walkthrough.md 신규 (사용자 가이드)

── 완료 기준 ──────────────────────────────────────────────────────────────────

✓ cargo test --workspace ≥ 320 pass
✓ swift build Universal 성공, swift test ≥ 84 pass
✓ ⌘8 → RemotePilotView 진입
✓ ARM 슬라이더 drag → walkready(page 9) 자동 호출
✓ Action Bar 7 페이지 (1·4·9·12·13·15·23) 모두 실 모터 송출 + tooltip 정확
✓ HighRisk (page 12·13) confirm 다이얼로그 동작
✓ ⌘⇧. → motion task cancel + 모터 토크 OFF
✓ 비활성 5 컴포넌트 모두 ComingSoonOverlay + sheet 안내 동작
✓ HIL 시나리오 1~4 통과 캡처

── 안전 주의 ──────────────────────────────────────────────────────────────────

- motion_4096.bin 데이터 변경 절대 금지.
- page 12/13 (HighRisk) confirm 우회 절대 금지.
- emergencyStop 은 ⌘⇧. 어느 상태에서도 작동, 절대 disable 금지.
- forge-core 기존 모듈 (motion 외) 코드 변경 최소 — teleop 은 호출만.
- ConnectionStore 기존 API 변경 없음 (v1.1 에서 IMU 보강).
- BLOCKER C3 (실 IK) 미해결 — D-pad 실 모터 송출 절대 금지. UI 만.

── 명시적 v1.0 비목표 (v1.1+ 로 미룸) ─────────────────────────────────────────

- IMU 텔레메트리 / 자동 낙상 복구 (v1.1)
- Head 추적 / Ball-Follow (v1.1 head, v1.5 walk)
- 카메라 view + AR HUD (v1.5)
- HSV 튜닝 (v1.5)
- forge-bridge TCP 5530 셋업 가이드 (v1.5)
- D-pad 실 모터 송출 (v2, BLOCKER C3 후)
- + 더 보기 9 페이지 (v1.5)
- mp3 동기 재생 (v2)
- Page chain 자동 재생 (v1.5)
- HeadTracker PID (v1.1)
- emergencyStop motion cancellation (v1.0 포함 ✅)
- ARM dxl_power + torque ramp (v1.0 포함 ✅)

── 참고 파일 ──────────────────────────────────────────────────────────────────

필수:
- docs/prd/teleop-v1.md (v3 — 단일 설계)
- docs/prd/teleop-v1-reality-check.md (격차 분석)
- docs/motion-format/page-metadata-motion4096.toml (16 페이지 sidecar)
- docs/motion-format/page-catalog-motion4096.md
- app/core/forge-core/src/control/mod.rs (precheck_motion, emergency_stop)
- app/core/forge-core/src/safety/torque_ramp.rs (TorqueRamper)
- app/core/forge-cli/src/motion_play.rs (Day 1 추출 대상)
- app/ui/.../DesignSystem/* (DFColor, DFNeon, DFAnimation, KoreanUX)

Sprint 15 v1.0 시작. 3~4일 추정. PR 본문에 HIL 시나리오 4 결과 + 신규 테스트
수 + 회귀 0 확인 + 비활성 컴포넌트 5 의 ComingSoonOverlay 스크린샷 포함.

v1.1, v1.5 는 별도 PR.
```
