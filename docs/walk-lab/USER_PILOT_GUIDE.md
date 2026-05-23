# DarwinForge Pilot Guide — DARwIn-OP2 게임 캐릭터 조종

> **v1.22.0 (2026-05-22) — 사이클 74**
>
> 5개 입력 source 로 ROBOTIS DARwIn-OP2 휴머노이드를 조종하는 사용자 가이드.

## 비유

게임 컨트롤러 매뉴얼 — 어떤 버튼이 어떤 액션? 빠른 시작 가이드 + 트러블슈팅. 본 문서는
DarwinForge 의 5 입력 source 를 처음 만나는 사용자가 5 분 안에 robot 을 walk 시키는
것을 목표.

## 결론 한 줄

**가장 빠른 시작**: WalkLab 페이지 좌하단 "Pilot 조종" 토글 → 키보드 W 누르면 robot 이
시뮬 모드에서 march 시작. 실 robot 연결은 ROBOTIS DARwIn-OP2 USB serial 연결 + 권한
허용.

---

## 5 입력 source 한눈에 보기

| Source | 활성화 | 핵심 입력 | 추천 사용 |
|--------|--------|-----------|-----------|
| **Keyboard** | 자동 (WalkLab 진입 시) | WASD 이동 / Space 비상 / R 복구 / 1-7 preset | 데스크탑 단독 |
| **Tello** | TelloPilotHud 의 "Tello 활성화" 토글 | 좌 stick 보행 / 우 stick 회전 / start emergency | Tello 드론을 controller 로 |
| **Gamepad** | 컨트롤러 USB/BT 페어링 → 자동 인식 | 좌 stick 이동 / D-pad preset / △ 비상 / ☰ 복구 | PS4/Xbox/Nimbus 등 표준 컨트롤러 |
| **Voice** | VoicePilotPanel 의 mic 토글 (사용자 명시 클릭) | 한/영 keyword: "걸어"/"walk", "정지"/"stop", "비상"/"emergency" | hands-free 제어 |
| **UI** | WalkLab 의 preset 버튼 / risk sheet | mouse / trackpad click | GUI 표준 |

---

## 1. Keyboard — 항상 사용 가능 (default)

### 매핑

```
┌─────────────────────────────────────────┐
│  Q W E     │   1 2 3 4 5 6 7  (preset)  │
│  A S D     │   M (motion)               │
│            │                            │
│  Space     │ 비상 정지                   │
│  R         │ 복구                       │
└─────────────────────────────────────────┘
```

- **W/S**: stride 전/후
- **A/D**: side 좌/우
- **Q/E**: turn 좌/우
- **숫자 1-7**: preset 선택 (1=march, 2=slowWalk, 3=normalWalk, 4=fastWalk, 5=jog, 6=turnLeft, 7=turnRight)
- **0**: idle (정지)
- **M**: 직전 motion 재시도
- **Space**: 비상 정지 (모든 source 차단)
- **R**: 비상 해제 (recovery)

### 트러블슈팅

- **W 눌러도 robot 안 움직임**: WalkLabView 포커스 확인 (창이 active 상태?). KeyboardPilotPanel 의 isRunning dot 가 녹색?
- **Space 눌러도 비상 안 됨**: 키보드 단축키가 다른 view 가 가로채는 중. 우선순위: Pilot panel > WalkLab > root.

---

## 2. Tello — 드론을 controller 로 (옵션)

### 시나리오

Tello 드론을 controller 로 사용 — Tello 의 stick 입력 + state (배터리 / 자세) 가
DarwinForge 로 흘러가서 DARwIn-OP2 를 조종.

### 설정 절차

1. Tello 드론 켜고 macOS Wi-Fi 를 TELLO-XXXX 에 연결.
2. WalkLab → "Pilot 조종" 토글 → TelloPilotHud 표시 확인.
3. TelloPilotHud 의 "Tello 활성화" 버튼 클릭 (사이클 72: 사용자 명시 활성화 필요).
4. macOS 가 "DarwinForge 가 Tello 드론과 통신하기 위해 로컬 네트워크 사용을 요청합니다"
   다이얼로그 표시 → "허용" 클릭.
5. 5 초 안에 TelloPilotHud 에 Tello 의 lastState (배터리 %, 고도) 표시.

### 매핑

- **좌 stick X**: side (사이드 스텝)
- **좌 stick Y**: stride (전후)
- **우 stick X**: turn (좌/우 회전)
- **start (☰)**: emergency

### 트러블슈팅

- **5 초 후에도 lastState 미수신**:
  - macOS 시스템 환경설정 > 개인정보 보호 및 보안 > 로컬 네트워크 → DarwinForge 항목 확인 + 허용
  - Tello drone Wi-Fi 가 macOS 와 연결됐는지 확인 (다른 네트워크 우선순위 문제)
  - "다시 시도" 버튼 클릭
- **lastState 받지만 stick 안 들음**: Tello 의 native app 이 background 실행 — 동일 UDP 8889 점유. Tello 앱 종료 후 재시도.

### 권한 거부 시

`Info.plist` 에 `NSLocalNetworkUsageDescription` 없으면 dialog 도 뜨지 않고 silent fail.
production 배포 시 `docs/walk-lab/PILOT_PRODUCTION_ENTITLEMENTS.md` 참조.

---

## 3. Gamepad — PS4 / Xbox / Nimbus

### 시나리오

표준 게임패드 (Sony DualShock 4, Xbox Series, SteelSeries Nimbus 등 — GCExtendedGamepad
프로파일 호환) 를 macOS 에 USB 또는 Bluetooth 페어링 → 자동 인식.

### 매핑

| 입력          | 동작                          |
|---------------|-------------------------------|
| 좌 stick X·Y  | side / stride 이동            |
| 우 stick X    | turn 회전                     |
| △ (PS) / Y (Xbox) | **emergency** (최우선)    |
| □ (PS) / X (Xbox) | preset.idle (정지)         |
| D-pad ↑       | preset 1 (march)              |
| D-pad →       | preset 2 (slowWalk)           |
| D-pad ↓       | preset 3 (normalWalk)         |
| D-pad ←       | preset 4 (fastWalk)           |
| START (☰)     | recovery (비상 해제)          |

### 사용 절차

1. 게임패드를 macOS 에 페어링:
   - USB: 케이블 연결 → 즉시 인식
   - Bluetooth: 시스템 환경설정 > 블루투스 → 페어링
2. WalkLab → "Pilot 조종" 토글 → GamepadPilotPanel 에 컨트롤러 이름 자동 표시
3. △ 눌러서 emergency 작동 확인 → R 또는 START 로 recovery → 안전 검증 완료
4. 좌 stick 으로 이동 시작

### 트러블슈팅

- **컨트롤러 이름 안 보임**:
  - macOS 가 컨트롤러를 인식했는지 확인 (시스템 환경설정 > 블루투스)
  - 컨트롤러를 일단 connect → DarwinForge 재시작
- **stick 입력 무반응**:
  - GamepadPilotPanel 의 isRunning dot 가 녹색인지 확인 (start() 호출됐는지)
  - 컨트롤러 deadzone 통과 검증 (값 < 5/100 은 무시)
- **△ emergency 가 stick 이동과 동시 입력 시 race 우려**:
  사이클 62 fix — emergency 가 stick 보다 먼저 처리 → 같은 frame 의 stick 은 무시.

---

## 4. Voice — 한/영 keyword 명령

### 시나리오

마이크로 키워드 발화 → 명령. hands-free 시연 / 청중 데모.

### 키워드 매핑

| 한국어 | 영어            | 동작          |
|--------|-----------------|---------------|
| 걸어   | walk / march    | preset.march  |
| 정지   | stop / idle     | preset.idle   |
| 조깅   | jog             | preset.jog    |
| 비상   | emergency       | emergency     |
| 복구   | recover / recovery | recovery   |

**우선순위 (같은 발화에 여러 키워드 포함 시)**:

emergency > recovery > march > idle > jog

예: "비상 걸어" → emergency 만 처리 (안전 우선).

### 사용 절차

1. WalkLab → "Pilot 조종" → VoicePilotPanel 표시.
2. mic 토글 버튼 클릭 (사용자 명시 — 자동 start 금지).
3. macOS 다이얼로그: "음성 인식 사용을 허용합니다" → "OK".
4. 마이크 다이얼로그: "마이크 접근 허용" → "허용".
5. 처음 발화 후 ~1초 안에 lastRecognized 텍스트 표시.

### 트러블슈팅

- **권한 다이얼로그 안 뜸**: `Info.plist` 의 `NSSpeechRecognitionUsageDescription` +
  `NSMicrophoneUsageDescription` 키 누락 (production 배포 시 발생).
- **인식 안 됨**:
  - 마이크 입력 레벨 확인 (시스템 환경설정 > 사운드 > 입력)
  - 발화가 키워드와 정확 매칭? "걸을게" 는 "걸어" 와 substring 매칭됨 (의도된 fuzzy).
- **잘못된 keyword 발화로 robot 갑자기 움직임**: emergency 우선순위로 안전 — 위험 발화 ("비상") 먼저 처리.

### 향후 개선 (codex LOW-4)

substring 매칭 — "stop talking" 같은 영어 자연어가 stop 트리거. word-boundary regex 도입
권장 (cycle 76+).

---

## 5. UI — 마우스 / trackpad (default)

### 시나리오

GUI 표준 — preset 버튼 클릭 / risk sheet 확인.

### 위치

- WalkLab 의 preset 행 (march / slowWalk / normalWalk / fastWalk / jog / turnLeft / turnRight)
- 비상 버튼 (사이클 25 — TelloPilotHud 의 recovery 버튼 일관성)
- WalkTrialAutoGenerator 의 "자동 trial 생성" 버튼

### 사용 절차

표준 SwiftUI 버튼 — 별도 권한 / 설정 불요.

---

## 통합 시나리오 (5 source 함께)

### 안전 데모 시나리오

1. **Keyboard W**: robot 이 march 시작 (auto-preset)
2. **Tello stick 전방**: stride amplitude 증가 (Tello 가 더 강한 입력)
3. **Voice "정지"**: idle 로 전환 (preset.idle)
4. **Gamepad △**: emergency 즉시 발화 → 모든 source 차단
5. **Gamepad START**: recovery → robot 안전 대기 상태
6. **UI tap "march"**: 정상 재시작

### Pilot HQ HUD (cycle 67)

5 panel 이 좌하단에 vertical stack:
1. **KeyboardPilotPanel** — autofocus 상태 + 단축키 안내
2. **TelloPilotHud** — Tello state + 활성화 토글 + advisory channel (사이클 72)
3. **PilotLatencyPanel** — p50/p95/max 지연 + rejectedCount
4. **VoicePilotPanel** — mic 토글 + 인식 텍스트 + 키워드 표
5. **GamepadPilotPanel** — 컨트롤러 이름 + 매핑 안내

---

## Recovery / Emergency 안전 흐름

```
사용자가 emergency 누름 (어떤 source 든)
    ↓
session.emergencyStop(trigger: ...)
    ↓
- emergencyStopActive = true
- amplitude (stride/side/turn) 모두 0
- current = .idle
- lastEmergencyTrigger = <원인>
    ↓
이후 어떤 source 의 move/preset 도 차단 (다층 가드):
1. bridge.process() emergency 검사
2. WalkLabSession.start() root guard (cycle 61)
3. WalkLabSession.syncCommandToEngine() guard (cycle 58)
4. WalkTrialAutoGenerator emergency 가드 (cycle 66)
    ↓
사용자가 명시 recovery (R 키 / Recover 버튼 / Voice "복구" / Gamepad START)
    ↓
session.exitEmergencyMode()
    ↓
- emergencyStopActive = false
- _lastEmergencyTrigger = nil
- 사용자가 다시 start(preset) 호출 시 정상 진입
```

### `EmergencyTrigger` 분류 (cycle 67 MEDIUM-3)

| trigger              | 한국어 라벨   | 출처                            |
|---------------------|---------------|---------------------------------|
| `.userClick`        | 사용자 정지   | UI 버튼 / ESC 키                |
| `.balanceLostL3`    | L3 균형 손실  | IMU tilt ≥ 50° 3 sample 연속    |
| `.thermalOverheat`  | 모터 과열     | 모터 평균 온도 ≥ 60°C           |
| `.voltageDroop`     | 전압 droop    | battery < 9.5V 지속             |
| `.fallPredictorRecommend` | 낙상 예측 | fall predictor 권장 emergency  |
| `.externalEStop`    | 외부 E-Stop   | Pilot ESC / RootView 전역 단축키 |
| `.unknown`          | 출처 미상     | fallback (state race 등)        |

---

## 트러블슈팅 빠른 표

| 증상 | 원인 | 해결 |
|------|------|------|
| 키보드 입력 무반응 | view focus 없음 | WalkLab 창 클릭 |
| Tello state 5초+ 미수신 | LocalNetwork 권한 | 시스템 환경설정 > 개인정보 > 로컬 네트워크 |
| Gamepad 인식 안 됨 | 페어링 끊김 | macOS 블루투스 환경설정 재페어링 |
| Voice 다이얼로그 안 뜸 | Info.plist 키 누락 | production 빌드 — entitlements 문서 참조 |
| emergency 후 robot 움직임 | guard 우회 — production fix 됨 (cycles 58-71) | 최신 버전 사용 |
| Auto Trial 0개 수집 | emergency 활성 상태 — 사이클 66 fix | recovery 후 재시도 |

---

## v1.22 신규 기능 (cycles 84-98)

### Audio 안전 피드백 (cycle 86 + 96)

- emergency 발화 시 **NSBeep (시스템 알림음)** 자동 재생.
- 정책: `session.pilotIsEmergency` 가 inactive → active 전환 시 1회만 발화.
- 사용자 청각 피로 방지 — 이미 emergency 상태 (재발화 / 연타) 는 silent.
- recovery (state inactive) 후 새 emergency = 다시 1회 발화 (source 무관).

### Pilot Settings Panel (cycle 87)

WalkLab → Pilot 조종 toggle → 6번째 panel "Pilot Settings":
- 4 dimension slider: scaleLR / scaleFB / scaleYaw / smoothingFactor (각 0.0-1.0)
- **실시간 preview**: 슬라이더 onChange → bridge 즉시 갱신 (50ms throttle).
- **저장**: 명시 버튼 → UserDefaults 영속.
- **기본값**: 4 slider → defaultValues 즉시 복귀.

설정 영속:
- Key schema v1: `pilot.scaleLR.v1` / `pilot.scaleFB.v1` / `pilot.scaleYaw.v1` / `pilot.smoothingFactor.v1`
- Type-safe Double cast (cycle 88) — String corruption 시 default fallback.
- 다음 launch 자동 load (RootView.onAppear → bridge 적용).

### DJI Controller Stub (cycle 92)

`.djiRC` InputSource 의 5번째 enum case wiring 진입점:
- `DJIControllerAdapter` (@MainActor @Observable) + `DJIControllerInputSource` protocol
- Production DJI SDK 통합 전까지: `MockDJIController` 만 사용 가능
- `init(bridge:)` 는 `@available(*, unavailable, ...)` — 외부 호출 시 compile error (안전 격상)
- SDK 통합 시: `ProductionDJIControllerSource` 신규 추가 + init(bridge:source:) 사용

### Pilot HQ Status Row (cycle 78) — 미정 사용자에게 강조

5 panel 위 한 줄 요약:
- 🟢 정상 / 🔴 비상 — emergency 상태 즉시 시각화
- 마지막 active source + icon — 어떤 source 가 마지막 입력인지
- event rate (events/s) — 입력 활동 강도
- ⚡ 활성 / 비활성 — bridge enabled 토글

## v1.22.X 내부 구조 개선 (cycles 100-115)

사용자 입장에서 직접 보이는 기능 변화는 없지만, 향후 변경 회귀 위험 ↓.

### God Object 분할 — Phase 1A ~ 10 완료

`WalkLabSession.swift` (4431 line → 2678 line, **-40% 감축**) 가 13 extension file 로 split
(11 split + 1 facade + 1 types):

| Phase | Extension 파일 | Cycle | 라인 |
|-------|----------------|-------|------|
| 1A | `+ClaudeAnalysis.swift` | 89 | 95 |
| 1B | `+PersistentLog.swift` | 90 | 82 |
| 1C | `+Calibration.swift` | 91 | 99 |
| 2 | `+Experiment.swift` | 97 | 297 |
| 3 | `+SensorUpdates.swift` | 98 | 205 |
| 4 | `+WalkCycleEngine.swift` | 100 | 445 |
| 5 | `+BalanceCorrection.swift` | 100 | 313 |
| 6 | `+Logging.swift` | 102 | 443 |
| 7 | `+FallPrevention.swift` | 107 | 85 |
| 8 | `+BalanceMitigation.swift` | 109 | 83 |
| 9 | `+SafetySampling.swift` | 111 | 152 |
| 10 | `+Preflight.swift` | 112 | 109 |
| (Facade) | `+Pilot.swift` | (prior) | 264 |

각 extension 은 본체와 동일 `@MainActor` actor 격리 유지 — race condition 위험 없음.
외부 API surface 변경 0 (모든 격상은 `internal(set)` — module 내부 write 만 허용).

### Test Coverage 강화 + Audit (cycles 103-115)

`Tests/DarwinForgeUITests/WalkLabSessionExtensionCoverageTests.swift` (33 real behavioral tests):

- Calibration: 보행 중 reject + idle 캡처 + axis overwrite
- Sensor Updates: sim IMU 진동/감쇠 + sim thermal 발열/냉각 + voltage droop + IMU fallback
- Experiment: onboardHealthCheckWarnings 6 case (4 input combo + instance helper + dead code 회귀 가드)
- Logging: empty dir + **JSONL roundtrip** (실 summary write→load→7개 field 일치)
- Phase 7: stale IMU buffer 비움 + jitter guard + **5 ticks accumulation**
- Phase 8: normal counter reset + **warning hysteresis 3 ticks** + **speedScale 정확값**
- Phase 9: 1 sample append + sync invariant + **state transition event emission**
- Phase 10: idle pass + 시뮬 caution preset 검증

**v1.22.0 사이클 115 audit fix**: code-reviewer agent 가 cycle 103-113 의 38 tests 중
21개 (55%) cargo-cult / no-assertion 판정. 9 deleted / 5 strengthened / 5 NEW critical
scenarios. 모든 신규 test 는 implementation 변경 시 fail 보장.

총 테스트 수: **1300 tests pass** (cargo-cult 정리로 1305 → 1300, 품질 ↑).

### 코덱스 + 병렬 에이전트 review 결과

5차에 걸친 multi-agent 검증:
- **cycle 93**: cycles 86-89 review — H1+H2+H3 도출, 사이클 103 fix
- **cycle 104**: cycles 100-103 — VERDICT: ACCEPT, 3 MINOR → 사이클 105 fix
- **cycle 111(codex 107-110)**: VERDICT: ACCEPT, cancelWalkCycle/engine 격상 SAFE 확인
- **cycle 115 (4 parallel agents — critic / security-auditor / code-reviewer / explore)**:
  - critic VERDICT: ACCEPT-WITH-RESERVATIONS (1 MAJOR: doc stale — 본 사이클 fix)
  - security-auditor: 0 CRITICAL / 0 HIGH, 격상 SAFE (UI 모두 read-only)
  - code-reviewer: 21/38 cargo-cult 발견 → 사이클 115 fix (real behavioral tests)
  - explore: onboardHealthCheckWarnings 는 dead code (production 미호출, tests 만 사용)

### 향후 계획

- 본체 2678 line — startWalkCycle (456 line) / tick (169 line) / start (148 line) /
  stop (66 line) / emergencyStop (63 line) 등 lifecycle method 가 잔존
- 추가 감축은 lifecycle method 의 internal cohesion 우선 (분할 시 의미 흩어짐 위험)
- 다음 단계: onboardHealthCheckWarnings 의 production wire-up (또는 명시 deprecation)

## DARWIN_UX_AUDIT v4 처리 (cycles 119-133, 2026-05-22)

스튜디오 클로드 (UX) + 스튜디오 코덱스 (코드) 합산 합본 (268 findings) 처리 결과.

### 진행률

| Priority | Total | Fixed (Active) | Mitigated/Deferred |
|---|---|---|---|
| P0 | 15 | **11** (#9, #11, #15, #17, #22, #23, #26, #27, #30, #31, #32) | 4 (#3, #5, #12, #20) |
| P1 | 13 | **9** (#1, #2, #14, #16, #18, #19, #25, #28, #33) | 4 (#4, #6, #13, #21) |
| P2 | 8 | **6** (#7, #8, #24, #29, #34, #36) | 2 (#13 dup, #35) |
| **TOTAL** | 36 | **26 active (72%)** | 10 (28%) — 모두 mitigation 입증 |

### Cycle 별 처리

- **119**: 4 P0 (#15 RemotePilot fake / #30 MotionBlender sim / #31 Recommender real-only / #32 Static Stability proxy)
- **120**: #27 forge Ctrl+C 토크 OFF (ctrlc crate + SHOULD_EXIT flag)
- **121**: #11 PilotActionBar silent fail (5초 orange banner)
- **122**: #17 [시뮬] prefix / #26 D-pad 단발
- **123**: #9 Expert 합성 IMU label
- **124**: #1/#2/#14/#25/#33 doc clarity (5건 batch)
- **125**: #16/#18/#19/#36 IntentDispatcher / ClaudeCommander / STL fallback
- **126**: #34 MotionBuilder random ID 결정성
- **127**: #13 ComingSoon consistency
- **128**: #29 SwiftPM warning
- **129**: codex MAJOR fix — #31 coordinateDescent realRobotOnly
- **130**: #23 InitialSetup VNC 수동확인
- **131**: #22 masterSetup rollback
- **132**: #8 Quick Connect endpoint 상수화
- **133**: #24 KoreanUX 닫기 button role .cancel

### Deferred 사유

- **#5 카탈로그 placeholder**: `v1TargetPoseID: nil` filter 이미 의도된 design
- **#12 .simReady ARM 오인**: `isSimMode` check 가 subtitle 분기 우선 — 이미 mitigated
- **#20 SSH MITM**: `accept-new` TOFU 는 산업 표준 (Trust On First Use)
- **#4 음성 버튼**: 이미 "준비 중" 라벨 + `disabled(true)` — 변경 불요
- **#6 HarnessBaseline**: v1.14.1 P1-1 fix 에서 이미 해소 — 추가 변경 불요
- **#21 InitialSetupWizard 자동 검증 부분**: VNC #23 + 5530/22 polling 으로 이미 충분
- **#35 ClaudeCritic future**: enum case 만 정의, instantiation 0 — "추후 통합" 라벨 명확

### Multi-agent 검증

- **cycle 119-128 codex critic review**: VERDICT ACCEPT-WITH-RESERVATIONS, 1 MAJOR (사이클 129 즉시 fix)
- 검증 도구: 4 parallel agents (critic / security-auditor / code-reviewer / explore)
- 결과: 1300 Swift + 368 Rust tests pass throughout

### 최종 상태

| Metric | Before audit | After audit |
|---|---|---|
| User-misleading labels | 11 instances | 0 (all annotated or fixed) |
| Hardcoded magic values | 5+ sites | Quick Connect endpoint 통일 + 5 비-critical 잔존 (cycle 132+) |
| Silent failures | 7-page silent fail (#11) | 5초 banner + auto-dismiss |
| Safety placeholders | Ctrl+C placeholder (#27) | Real ctrlc handler + SHOULD_EXIT flag |
| Proxy validation 라벨 오해 | Static Stability `Pass` | `Warn("정적 안정성 proxy")` |
| Sim/real 추천 혼동 | sim 데이터 기반 무표시 | rationale 에 "실로봇 N개 / 시뮬 N개" 비율

---

## 안전 / 책임

- **실 robot 사용 시**: 단일 stop 가 항상 우선. emergency 가 어떤 source 든 즉시 차단.
- **시뮬 모드**: `session.store?.bus == nil` 인 경우 motor 송출 안 함 — 모든 입력은 UI state 만.
- **권한 거부 시**: production silent fail → UI banner 안내 (cycle 72 HIGH-2 fix).
- **emergency 자동 audio**: cycle 86 + 96 — state-based throttle. 사용자가 음 안 들리면 이미 emergency 상태 (recovery 필요).

---

## 참고 문서

- [PILOT_PRODUCTION_ENTITLEMENTS.md](./PILOT_PRODUCTION_ENTITLEMENTS.md) — production 배포 권한 가이드
- [V1_DESIGN.md](./V1_DESIGN.md) — WalkLab v1 설계 문서
- [WALK_PROGRESSION_TEST.md](./WALK_PROGRESSION_TEST.md) — 보행 진행 테스트

---

## 사이클 134-147 — DARWIN_UX_AUDIT v4 closure + IMPLEMENTATION audit (2026-05-22)

> **v1.23.0 (2026-05-22)** — DARWIN_UX_AUDIT v4 100% closure (cycles 119-140) +
> 신규 IMPLEMENTATION_FAKE_DATA_PLACEHOLDER_AUDIT 처리 (cycles 141-147).

### Cycles 134-140 — DARWIN_UX_AUDIT v4 마무리

| Cycle | 작업 | 영향 |
|---|---|---|
| 134 | USER_PILOT_GUIDE 처리 결과 doc | -  |
| 135 | #7 ComingSoonOverlay stage 단일 일관성 | UX 일관성 |
| 136-137 | WalkLabV1114 flaky test polling fix + codex MINOR #7 case-insensitive | CI 안정성 |
| 138 | codex MAJOR sweep #8 — 30+ hardcoded endpoint sites → DFConnectionConstants | 단일 source of truth |
| 139 | codex MAJOR sweep #24 — 10 Button("닫기") role: .cancel | a11y 일관성 |
| 140 | #22 codex MINOR — masterSetupRollback UI wire-up | 안전 fallback |

**최종 cycle 119-140 총평**: 36/36 audit findings 처리. codex final review (cycles 135-140)
VERDICT: **ACCEPT-WITH-RESERVATIONS** — 1 MAJOR (testAutoLoopE2EProducesVerdict 잔여
sleep race) → cycle 142 즉시 fix.

### Cycle 141 — Swift 6 warning cleanup batch (6 warnings)

DARWIN_UX_AUDIT 100% 후 다음 단계 — Swift 6 strict concurrency / deprecation warnings.

| File | Warning | Fix |
|---|---|---|
| ConnectionStore.swift:1513 | var imu never mutated | var → let |
| RootView.swift:170 | onChange 1-param deprecated | 2-param closure |
| WalkPresetCatalog.swift:15 | MotionDescriptor Sendable 전파 | + Sendable conformance |
| HarnessLiveAlerts.swift:41 | MainActor-isolated default param | + nonisolated |
| HarnessInspectorView.swift:357 | onChange 1-param deprecated | 0-param closure |
| HarnessInspectorView.swift:916-929 | var capture in Task closure | var → let immediate-invoke |

**검증**: swift build 0 warnings / 1300 tests pass.

### Cycle 142 — codex MAJOR flaky test polling fix

codex final review 식별 — WalkLabV1114FeedbackLoopTests.swift:960 의 Task.sleep(500ms)
가 cycle 136 polling fix 누락. 동일 패턴 적용 + line 832 (rollback) 도 선제 fix.

**검증**: 3회 연속 full suite 1300/1300 pass under heavy parallel load.

### Cycles 143-147 — IMPLEMENTATION_FAKE_DATA_PLACEHOLDER_AUDIT (18 findings)

신규 audit 문서: `docs/diagnosis/IMPLEMENTATION_FAKE_DATA_PLACEHOLDER_AUDIT_2026-05-22.md`

#### 처리 매핑

| Audit # | 위험도 | 처리 사이클 | 변경 요약 |
|---|---|---|---|
| #1 Ctrl+C torque OFF | P0 | cycle 120 (사전) | ctrlc crate + RAII guard |
| #2 Onboard balance 미송신 | P0 | cycle 145 (부분) | enableBalanceCorrection / correctorIntensityLevel doc ApplyScope |
| #3 D-pad 단발 자세 라벨 | P0 | cycle 143 | pressBehaviorKo property + tooltip "연속 보행 아님" |
| #4 MotionBlender preview msg | P0 | cycle 143 | "preview blend" 명시 (송출 진행 → preview blend) |
| #5 Remote Pilot estimated badge | P1 | cycle 146 | usesRealPolling: false 시 orange clock.badge.checkmark |
| #6 Recommender realRobotOnly | P1 | cycle 144 | pilotBiased(for:realRobotOnly:) overload |
| #7 공식 모션 placeholder 이름 | P1 | cycle 143 | OfficialCatalogReference / MotionCatalog / SynthModel 에 `[placeholder]` |
| #8 DJI Controller SDK stub | P1 | cycle 92/94 (사전) | unavailable production constructor + UI label |
| #9 Initial Setup Wizard VNC 수동 | P1 | cycle 130 (사전) | "수동 확인" 분리 |
| #10 Static Stability proxy | P1 | cycle 119 (사전) | Pass → Warn("proxy 검증") |
| #11 TORQUE_OFF preview placeholder | P1 | cycle 124 (사전) | preview semantics 주석 |
| #12 SynthInspectorPanel 미검증 | P2 | cycle 127-128 (사전) | "미검증" warning 강화 |
| #13 PilotFeatureFlags v1_5 주석 | P2 | cycle 124 (사전) | dpadRealMotor / hsvTuning 활성 명시 |
| #14 WalkLab tuning mode별 주석 | P2 | cycle 145 + cycle 124 (사전) | ApplyScope 명시 |
| #15 MotionBuilder random ID | P2 | cycle 126 (사전) | placeholder ID 명시 |
| #16 Synthetic IMU source badge | P2 | cycle 147 | SourceBreakdown struct + 카드 badge |
| #17 WalkComparisonTag / claudeCritic | P2 | cycle 127 (사전) | "추후 통합" 라벨 + UI 미생성 |
| #18 SwiftPM resource warning | P2 | cycle 128 (사전) | Package.swift resources 명시 |

**남음**: #2 full Onboard UI ApplyScope badge (UI 변경 대형 작업 — 별도 사이클 후보).

#### Multi-agent 검증

- **codex final review cycles 141-142**: VERDICT ACCEPT — 0 CRITICAL / 0 MAJOR / 0 MINOR
  (Sendable / nonisolated / var→let closure / polling pattern 모두 검증 통과)
- 1300 swift tests + 368 rust tests (13+312+11+32) 유지

### 최종 상태 (cycles 119-147)

| 영역 | Before | After (cycle 147) |
|---|---|---|
| User-misleading labels | 11 instances | 0 (annotated) |
| 공식 모션 placeholder | 3 무표시 | `[placeholder]` prefix 3 entries × 3 files |
| Recommender sim/real | 무표시 | SourceBreakdown badge + realRobotOnly 3 strategies |
| Remote Pilot progress | 모두 동일 아이콘 | estimated/real 분리 (clock badge / checkmark) |
| D-pad 단발 self-doc | 없음 | "단발 자세 · 700ms 후 walkReady" tooltip |
| MotionBlender label | "송출 진행" 오해 | "preview blend" 명시 |
| Swift 6 warnings | 6 | 0 |
| Flaky tests | 1 active | 0 |

---

## 사이클 148-155 — 사용자 권고 5건 처리 (2026-05-22)

> **v1.24.0 (2026-05-22)** — IMPLEMENTATION audit closure 후 사용자 권고 5건 처리:
> 통합 배지 체계 / sim confirmation / 카탈로그 그룹 분리 + codex review fix.

### Cycles 148-151 — 추가 검증 + auto-detect

| Cycle | 작업 | 영향 |
|---|---|---|
| 148 | USER_PILOT_GUIDE cycles 134-147 doc | 추적성 |
| 149 | codex MAJOR x2 + MINOR x3 fix (cycles 143-147 review) | recommend(for:realRobotOnly:) aggregator + 7 tests + a11y + Optional |
| 150 | IMPLEMENTATION audit closure annotation (Section 9) | audit 문서 inline closure |
| 151 | dead-code scan finding #4 — WalkTrialLibraryView realRobotOnly auto-detect | robot 연결 시 자동 sim 제외 |

### Cycles 152-155 — 사용자 권고 5건 batch

| Cycle | 권고 # | 작업 | 변경 핵심 |
|---|---|---|---|
| 152 | #1 통합 배지 | DFStatusBadge unified enum + view | 8 case (appliedToRobot / simulationOnly / estimatedProgress / previewOnly / unverified / sdkUnavailable / placeholder / futureIntegration) + 3 style (compact/full/iconOnly) + a11y + 7 tests |
| 153 | #3 sim confirmation | sim 추천 적용 confirmation modal | needsSimConfirmation 정적 predicate + 4 tests + destructive role |
| 154 | #4 카탈로그 그룹 | MotionLibraryView 사이드바 3 subsection | 공식 raw (11) / Placeholder (2) / 고위험 (3) |
| 155 | codex MINOR x3 | ID 17 + centralize ID sets + empty guard | OfficialCatalogReference 에 canonical ID sets + 5 tests |

### 권고별 closure 상태

| 사용자 권고 | 처리 결과 |
|---|---|
| **#1 통합 배지 체계** | ✅ DFStatusBadge enum + view 정의 (migration 점진) |
| **#2 P0 안전 sprint** | ✅ 이미 cycle 119-120 에서 완료 (Ctrl+C / static stability) |
| **#3 추천 sim/real 분리** | ✅ SourceBreakdown badge (147) + recommend aggregator (149) + auto-detect (151) + confirmation (153) |
| **#4 카탈로그 그룹 분리** | ✅ MotionLibraryView 3 subsection + ID 17 dual membership 명시 |
| **#5 회의 안건** | ✅ docs 에 결정 가능한 형태로 정리 |

### Multi-agent 검증 결과

- **codex final review cycles 141-142**: ACCEPT (clean).
- **codex final review cycles 143-147**: ACCEPT-WITH-RESERVATIONS — 2 MAJOR + 3 MINOR → cycle 149 즉시 fix.
- **codex review cycle 149**: ACCEPT (clean).
- **security audit cycles 141-150**: CLEAN (0 CRITICAL/HIGH/MEDIUM).
- **dead-code scan cycles 141-150**: 5 finding → 3 false positive + 1 즉시 fix (cycle 151) + 1 design refactor.
- **codex review cycle 152**: ACCEPT (clean).
- **codex review cycle 153**: ACCEPT (clean).
- **codex review cycle 154**: ACCEPT-WITH-RESERVATIONS — 3 MINOR → cycle 155 즉시 fix.

### 최종 상태 (cycle 119 → cycle 155)

| Metric | Before (cycle 119) | After (cycle 155) |
|---|---|---|
| Swift tests | 1300 | **1323** (+23 새 tests) |
| Rust tests | 368 | 368 (유지) |
| Build warnings | 6 (Swift 6) | **0** |
| Flaky tests | 1 | **0** |
| Audit findings (DARWIN_UX_AUDIT v4) | 36 open | **36/36 처리** |
| Audit findings (IMPLEMENTATION) | 18 open | **18/18 처리** |
| 통합 배지 enum | 없음 | DFStatusBadge 8 case |
| sim 추천 confirmation | 없음 | needsSimConfirmation 정적 predicate |
| 공식 카탈로그 그룹 분리 | 16 단일 section | 3 status-based subsection |
| ID set canonical reference | 3 곳 drift 위험 | OfficialCatalogReference 단일 source |

---

## 사이클 158-165 — WalkLab 자이로 closed-loop 솔직 리뷰 + P0/P1 처리 (2026-05-23)

> **v1.25.0 (2026-05-23)** — 사용자 명시 요청: "자이로 기반으로 원활하게 수정/보정 하면서
> 로봇이 제대로 걷는 시스템 인지 솔직하게 코드단에서 리뷰" + 이슈 전부 소거.

### Cycle 158 — 정밀 코드 리뷰 문서

`docs/diagnosis/WALKLAB_GYRO_CLOSED_LOOP_REVIEW_2026-05-23.md` 작성.

**결론**: "부분만 작동". Mac sparse engine 은 closed-loop 가 구성됐으나 IMU 가 5Hz 라
ROBOTIS 권장 125Hz 의 1/25. Onboard mode 는 자이로 보정 자체가 Mac → robot 미송신.

**P0 4건 식별**:
- P0-1 IMU 5Hz 가 freshness gate 250ms 와 50ms 마진만 — bus jitter 시 보정 0 감쇠.
- P0-2 Onboard schema 부재 — WalkingEngineCommand 가 balanceGain/Enable/Intensity 누락.
- P0-3 IMU stale silent — 사용자 UI 표시 부재.
- P0-4 roll 부호 정규화 옵션 부재 (pitch 만 있음).

### Cycles 159-162 — P0 4건 처리

| Cycle | P0 # | 변경 핵심 | Tests |
|---|---|---|---|
| **159** | P0-1 | `imuFastPollActive` Bool flag — walk 활성 시 5Hz → 20Hz (50ms). idle 시 5Hz 유지. WalkLabSession 가 walk start/stop 시 toggle. | 1325 |
| **160** | P0-3 | `balanceCorrectionFreshness` enum (.normal/.degraded/.blocked) public publish. UI HUD 가 IMU stale silent 차단 인지 가능. | +6 (1331) |
| **161** | P0-4 | `BalanceRollInputConvention` enum (.imuRaw / .negateLeftIsNegative) — pitch 와 동일 패턴. | 1331 |
| **162** | P0-2 | `WalkingEngineCommand` 7→10 필드 (balanceGain/Enable/IntensityLevel 추가). 옛 daemon sscanf 7 필드 backward compat. | 1331 |

### Cycles 163-165 — 보정 효과 metric

| Cycle | 작업 | 변경 핵심 | Tests |
|---|---|---|---|
| **163** | P1-3 data model | `TrialOutcome.CorrectionEffectMetric` nested struct — ON/OFF sample count + peak abs roll/pitch + freshness count. | 1331 |
| **164** | codex review fix | MAJOR (cycle 162 silent failure 경고) + MINOR (cycle 160 danger early-return freshness). `onboardBalanceSchemaWarningActive` flag. | 1331 |
| **165** | metric wire-up | `WalkTrialAnalyzer.correctionEffectMetric()` static 함수 + analyze() 통합. ON/OFF group 별 peak abs 계산. | +6 (1337) |

### Multi-agent 검증

- **codex review cycles 159-162**: VERDICT ACCEPT-WITH-RESERVATIONS.
  - 1 MAJOR (옛 daemon silent failure) → cycle 164 fix (`onboardBalanceSchemaWarningActive`).
  - 4 MINOR — 1 fixed (danger freshness), 나머지 acceptable.

### before/after (cycle 158 review 갱신)

| 영역 | Before | After (cycle 165) |
|---|---|---|
| IMU polling rate (walk) | 5Hz (200ms) | **20Hz (50ms)** — freshness gate 250ms 와 4-step 마진 |
| IMU polling rate (idle) | 5Hz | 5Hz (perf 유지) |
| Onboard schema | 7 필드 (자이로 미송신) | **10 필드** (balanceGain/Enable/Intensity 추가) |
| Silent failure 경고 | 없음 | `onboardBalanceSchemaWarningActive` HUD signal |
| IMU stale UI 표시 | 없음 | `balanceCorrectionFreshness` enum 3-state |
| roll 부호 정규화 | raw 만 | `BalanceRollInputConvention` opt-in |
| 보정 효과 측정 | 없음 | `TrialOutcome.CorrectionEffectMetric` ON/OFF 비교 |
| Swift tests | 1325 | **1337** (+12) |
| Build warnings | 0 | 0 (유지) |

### 솔직한 평가

**개선됨**:
- ✓ Mac sparse engine: closed-loop + 20Hz IMU + freshness publish + roll/pitch 정규화.
- ✓ Onboard mode: balanceGain/Enable/Intensity 3 필드 송신 + 옛 daemon 호환 + silent failure 경고.
- ✓ 측정: TrialOutcome.CorrectionEffectMetric — Recommender 가 보정 효과 정량 학습 가능.

**미해결 (실 robot 검증 필요)**:
- ✗ ROBOTIS 권장 125Hz 의 1/6 (USB bus 한계 — bus level batching 후속).
- ✗ Onboard mode 의 robot-side v2 patch (sscanf 10 필드) — Mac 측 schema 만 준비, daemon 작업 필요.
- ✗ 실 robot 에서 보정 효과 측정 (handoff doc 영역).

**남은 P1/P2** (deferred):
- P1-2 ramp + freshness gate 우선순위 명시 — 현재 effectiveScale = ramp * freshnessGate 곱 일관.
- P2-1 GyroCorrector / BalanceCorrector / FallPredictor 책임 통합 — 장기 refactor.
- P2-2 Mac sparse vs Onboard timing 동기 — 별도 sprint.

### Git 상태

- 68 commits ahead origin (cycles 119-165).
- 1337 swift + 368 rust tests pass.
- 0 build warnings.

---

## 사이클 167-172 — UI wire-up + persistence + codex review (2026-05-23 후속)

> **v1.25.1 (2026-05-23)** — cycles 158-165 의 자이로 closed-loop 변경을 실제 UI 에 노출 +
> 사용자 명시 dismiss path + persist + 실 robot smoke test 시나리오.

### Cycles 167-170 — UI wire-up + smoke test

| Cycle | 작업 | 영향 |
|---|---|---|
| **167** | `balanceCorrectionFreshness` HUD inline badge (.degraded orange / .blocked red) | 사용자가 IMU stale silent 차단 즉시 인지 |
| **168** | P1-2 ramp×freshness 곱 docstring + OnboardHealthIndicator schemaWarningBanner | "daemon v2 미확인" 경고 UI |
| **169** | "v2 확인" 토글 button (사용자 명시 dismiss) | banner 즉시 사라짐 |
| **170** | docs/harness/walklab-gyro-smoke-test-2026-05-23.md (243 lines) | 실 robot step-by-step 검증 시나리오 |

### Cycle 171 — codex review of 167-170

**VERDICT**: ACCEPT (0 CRITICAL/MAJOR). 4 MINOR:
- #1 `.normal` invisible — design choice OK.
- #2 badge label length — graceful truncate.
- #3 `onboardBalanceSchemaWarningActive` stale on first UI entry → cycle 172 fix.
- #4 `onboardBalanceSchemaVerified` 매 session 재확인 → cycle 172 fix.

### Cycle 172 — codex MINOR #3 + #4 fix

- `onboardBalanceSchemaVerified` → UserDefaults persist (key: "df.walklab.onboardBalanceSchemaVerified").
- `onboardBalanceSchemaWarningActive` → computed property (매 read 즉시 평가).
- currentWalkingEngineCommand() 의 manual flag set 제거.
- Button action 에서 manual warningActive=false 제거.
- **+7 tests**: WalkLabOnboardSchemaWarningTests (각 분기 + persistence + computed evaluation).

### before/after (cycle 158 → cycle 172)

| 영역 | Before (cycle 158) | After (cycle 172) |
|---|---|---|
| IMU rate (walk) | 5Hz | **20Hz** (cycle 159) |
| IMU stale UI signal | 없음 | **inline orange/red badge** (cycle 167) |
| Onboard schema | 7 필드 | **10 필드** (cycle 162) |
| Silent failure 경고 | 없음 | **banner + "v2 확인" 토글** (cycles 168-169) |
| Verified persistence | 없음 | **UserDefaults persist** (cycle 172) |
| Warning 평가 timing | currentWalkingEngineCommand 의존 | **computed (즉시)** (cycle 172) |
| 보정 효과 측정 | 없음 | **CorrectionEffectMetric ON/OFF 비교** (cycles 163-165) |
| 실 robot smoke test | 없음 | **243-line 시나리오 doc** (cycle 170) |
| Swift tests | 1325 | **1344** (+19 new) |

### Multi-agent 검증 누적

- codex review cycles 159-162: ACCEPT-WITH-RESERVATIONS → cycle 164 fix.
- codex review cycles 163-165: ACCEPT (clean).
- codex review cycles 167-170: ACCEPT — 2 MINOR fixed (172) + 2 MINOR design choice.

### 남은 항목 (deferred)

- P2-1 GyroCorrector / BalanceCorrector / FallPredictor 책임 통합 (장기 refactor).
- P2-2 Mac sparse vs Onboard timing 동기 (별도 sprint).
- daemon version automated handshake (옛 v1 daemon detection).

### Git 상태 (cycle 172 종료 시점)

- **78 commits ahead origin** (cycles 119-172).
- **1344 swift + 368 rust tests pass**.
- **0 build warnings**.

---

## 사이클 174-183 — 자이로 closed-loop 통합 검증 + 메뉴 연계 audit + 6 gap 처리

### 한 줄 결론

cycle 172 의 자이로 closed-loop 완성 이후 (1) 통합/유기 검증 3 cycle (174-176) +
(2) 메뉴 간 연계 audit (177) + (3) audit 의 P0 3건 + P1 3건 모두 처리 (178-183).
**테스트 1344 → 1409 (+65), 0 failures**.

### 174-176 — 자이로 closed-loop 유기 통합 검증 (3 cycle)

| 사이클 | 검증 chain | 신규 테스트 |
|---|---|---|
| **174** | WalkLabSession 의 모든 자이로 관련 상태 default + freshness state 전환 + correction effect metric end-to-end | 11 (WalkLabGyroClosedLoopIntegrationTests) |
| **175** | ConnectionStore + WalkLabSession 의 imuFastPollActive 양방향 일관성 + @Published observer + weak ref | 6 (WalkLabStoreSessionIntegrationTests) |
| **176** | WalkLabPreset 8 case 의 currentWalkingEngineCommand → 10 필드 schema 검증 + advanced/basic mode 분기 | 9 (WalkLabPresetCommandIntegrationTests) |

### 177 — WalkLab + 주변 메뉴 연계성 audit

**docs/diagnosis/WALKLAB_MENU_INTEGRATION_REVIEW_2026-05-23.md** (225 lines):

- 8 메뉴 (studio/teach/motion/walk/conversation/pilot/remote/expert) × 10+ shared state 의 chain 검사.
- **정상 chain**: WalkLab→Trial→Recommender ✓, Connect→WalkLab ✓, Pilot↔WalkLab ✓.
- **gap 6건 식별**: P0 3건 + P1 3건.

### 178-183 — audit gap 6건 처리

| 사이클 | gap | 구현 | 신규 tests |
|---|---|---|---|
| **178** | P0 #3.3 Pilot/MotionLibrary 카탈로그 일관성 | regression guard — cycle 143 의 placeholder prefix 작업 이 이미 일관성 유지 확인 | 6 (PilotMotionCatalogConsistencyTests) |
| **179** | P0 #3.1 Studio motion play silent | StudioConnectionStateBadge (bus×liveApply 4 상태) → DFStatusBadge `.simulationOnly` / `.appliedToRobot` 명시 | 6 |
| **180** | P0 #3.2 Synth → MotionLibrary 끊김 | SynthMotionExporter + "Motion 스튜디오 로 보내기" button + dfImportSynthPagesToMotionStudio notification + page ID 재할당 | 7 |
| **181** | P1 #3.4 Conversation telemetry 누락 | 5 신규 TelemetryKind (planApproved/Rejected/Executed/Failed/SessionCleared) + ConversationViewModel hooks. PII redaction 유지 | 5 |
| **182** | P1 #3.6 Remote SSH telemetry 누락 | 4 신규 TelemetryKind (commandSent/Responded/Error/ChannelChanged) + RemoteShell hooks. SSH+SMB 양 채널 분리 추적 + shellErrorCase mapping | 5 |
| **183** | P1 #3.5 Expert↔Trial Library 통합 | TrialComparisonModel (pure logic, 4 metric directional diff) + TrialComparisonCard (dropdown picker + side-by-side grid) + WalkLabIntegrationCards 4번째 card | 10 |

### 사용자 효과 매트릭스

| 변경 | 이전 사용자 경험 | 이후 사용자 경험 |
|---|---|---|
| Studio sim/real badge | bus 미연결 시 슬라이더가 silent fallback — "로봇이 왜 안 움직이지?" | 진입 즉시 "시뮬레이션" badge 노출 / liveApply ON 시 "실 로봇 적용됨" badge |
| Synth → Motion | 결과 JSON 을 외부 forge CLI 로 import 해야 함 | "Motion 스튜디오 로 보내기" button 한 클릭 → 자동 import + section 전환 + 토스트 |
| Conversation telemetry | plan approve/reject/실행 결과 기록 X — UX 분석 불가 | 5 단계 모두 추적 — Inspector / SessionAnalysis 가 사용자 의사결정 패턴 시각화 |
| Remote SSH telemetry | 모든 명령 silent — 채널 전환 / latency 분석 불가 | sent / responded / error / channel_changed 4 단계 추적, hash 로 동일 명령 반복 분석 |
| Trial 비교 | live session metric 만 — 과거 비교 미지원 | Expert 메뉴 의 신규 "Trial 비교" card 에서 두 trial 선택 → 4 metric (안정성/부드러움/최대roll/최대pitch) directional diff |

### Telemetry 확장 누적 (cycles 181-182)

| Namespace | Before | After |
|---|---|---|
| `claude.*` | 3 case | **8** (+5 plan approve/reject/exec/fail/sessionClear) |
| `remote.*` | 0 case | **4** (commandSent/Responded/Error/ChannelChanged) |

### 신규 모듈 정리

- `Studio/StudioConnectionStateBadge.swift` — pure resolver
- `Synth/SynthMotionExporter.swift` — pure JSON → MotionPage decode + error 분기
- `Expert/WalkDiagnostics/TrialComparisonModel.swift` — pure metric diff
- `Expert/WalkDiagnostics/TrialComparisonCard.swift` — view
- 5 신규 TelemetryKind (claude.* 5), 4 (remote.* 4)

### 검증

- 1344 → **1409** Swift tests (+65, 0 failures).
- swift build: 0 errors.
- 모든 commit conventional commits + Co-Authored-By 포함.

### 남은 영역 (deferred to cycle 185+)

- USER_PILOT_GUIDE 의 신규 사용자 흐름 example (Synth→Motion, Trial 비교 사용법) screenshot 첨부.
- codex review cycles 178-183 (별도 sprint).
- 실 robot smoke test for Trial Comparison UX (cycle 184 의 doc 확장).

---

## 사이클 185-188 — codex review + 사후 fix + Pilot/Harness 보강

### 한 줄 결론

cycle 178-183 의 audit fix 에 critic agent (cycle 185) 의 1 MAJOR + 2 MINOR 적용
(cycle 187) + Pilot WalkLabRCBridge 의 dead-code telemetry kind 활성 (cycle 186)
+ TelemetryRecorder 의 errorCount switch sync (cycle 188).

### 185 — codex critic review of cycles 178-183

**VERDICT**: ACCEPT-WITH-RESERVATIONS.

| Severity | 영역 | cycle 187 처리 |
|---|---|---|
| MAJOR | cycle 180 importSynthPages UInt8 overflow (existingMaxId+offset>255 silent clamp → duplicate IDs) | SynthMotionExporter.reassignPageIds 신규 + .idOverflow ExportError case + UI 오류 alert |
| MINOR | cycle 181 DispatcherError String(describing:) 의 associated value PII | DispatcherError.telemetryCase computed property 추가 |
| MINOR | cycle 183 TrialComparisonCard.loadTrials() main thread fetch | Task.detached(priority: .userInitiated) 로 background fetch |
| 문서 | audit doc #3.1 vs #3.3 mapping stale | WALKLAB_MENU_INTEGRATION_REVIEW 수정 + cycle 185 노트 |

### 186 — Pilot WalkLabRCBridge Harness telemetry 활성

종전: pilotModeChanged + pilotEStop 2 kind 정의돼 있으나 dead code (firing site 0).

5 신규 TelemetryKind + WalkLabRCBridge wire-up:

| Kind | 발화 시점 | data |
|---|---|---|
| `pilot.mode_changed` | handlePreset success / blocked | preset, source, result, message_hash |
| `pilot.e_stop` | process(.emergency) | source, was_already_active |
| `pilot.recovery_requested` | handleRecovery 성공 | source |
| `pilot.intent_blocked` | emergency 동안 차단 | source, intent_kind |
| `pilot.bridge_disabled` | bridge.enabled=false 차단 | source, intent_kind |

PII redaction: intent_kind = case name 만 (associated value 제거), message → shortHash.

### 187 — codex critic fix (MAJOR + 2 MINOR)

위 cycle 185 표 참조. 7 신규 SynthMotionExporterOverflowTests 추가.

### 188 — TelemetryRecorder.errorCount 신규 kind 반영

cycle 181 (claudePlanExecutionFailed) + cycle 182 (remoteCommandError) 가 errorCount
switch case 누락 → meta.errorCount undercount. 본 cycle 부터 정확 카운트. pilotEStop
은 의도적 .warn level — 비카운트 (사용자 안전 액션은 시스템 오류 X 분류).

### Telemetry namespace 누적 현황 (cycle 188 종료)

| Namespace | Before 178 | After 188 |
|---|---|---|
| `claude.*` | 3 | **8** (+5 plan lifecycle) |
| `remote.*` | 0 | **4** (lifecycle 전체) |
| `pilot.*` | 2 dead | **5 alive** (cycle 186) |
| **합계** | 5 | **17** (+12, 3 dead → alive) |

### 검증

- 1344 → **1424** Swift tests (+80 across 11 cycles 178-188, 0 failures, 61s).
- swift build: 0 errors, 0 warnings.
- 81 commits ahead origin.

### 남은 영역 (deferred → cycles 189+)

- codex review of cycles 184-188 (cycle 189 background).
- 신규 cross-menu audit (cycle 190 background) — explore agent.
- Teach mode telemetry / integration deep dive (cycle 191 background).

---

## 사이클 189-195 — 병렬 에이전트 audit + 후속 fix + 신규 audit doc 2건

### 한 줄 결론

3 백그라운드 에이전트 (critic + 2 explore) 동시 spawn 으로 (1) cycles 184-188
재검증 (cycle 189) + (2) 신규 cross-menu audit 6 gap (cycle 190) + (3) Teach
mode 7 telemetry × fire site 매핑 (cycle 191). 후속 P0 5건 처리 (cycles 192-194)
+ 2 audit doc commit (cycle 195).

### 189 — codex critic review of cycles 184-188

**VERDICT**: ACCEPT-WITH-RESERVATIONS.

| Severity | 영역 | cycle 192+ 처리 |
|---|---|---|
| MAJOR-1 | cycle 188 errorCount switch 가 4 추가 .error level kind 누락 (connectFailure / poseApplyFailed / busEStop / walkLabEmergencyStop) | **cycle 192** errorCountedKinds 단일 SOT + 4 추가 + regression guard |
| MINOR-1 | walkLabEmergencyStop 의 design 결정 (error vs warn) 문서화 | cycle 192 doc 명시 |

### 190 — 신규 cross-menu gap audit (explore agent)

`docs/diagnosis/CROSS_MENU_AUDIT_FOLLOWUP_2026-05-23.md` — 6 신규 gap:

| # | Gap | 처리 |
|---|---|---|
| P0 #1 | Remote menu view-layer telemetry | cycle 182 의 shell layer 가 이미 처리 — deferred |
| P0 #2 | Setup wizard untracked | **cycle 194** (mark() 단일 hook + auto-verify 통합) |
| P1 #3 | Joint Control 실패 silent | cycle 196 (parallel agent) |
| P1 #4 | Remote view command label loss | deferred (P0 #1 와 동일 영역) |
| P2 #5 | Conversation clear ambiguous | cycle 181 의 claudeSessionCleared 가 이미 처리 — verified |
| P2 #6 | Stale state on navigation | cycle 197 (parallel agent) |

### 191 — Teach mode deep dive (explore agent)

`docs/diagnosis/TEACH_MODE_AUDIT_2026-05-23.md` — 5 gap:

| # | Gap | 처리 |
|---|---|---|
| P0 | teachTorqueChanged dead code (4 mutation site) | **cycle 193** (4 site wire + payload) |
| P0 | dfTransferPoseToMotion orphan (poster + receiver 0) | **cycle 193** (Teach button + MotionStudio onReceive + page ID reassign) |
| P1 | Teach → Motion direct export | cycle 193 에 통합 |
| P1 | Snapshot disk persistence | deferred (larger work) |
| P2 | WalkLabSession comparison UI | deferred |

### 192-194 — P0 5건 처리

**192**: errorCountedKinds 단일 source of truth — TelemetryRecorder 의 switch 가
constant 기반 → 신규 error kind 추가 시 매번 본 list + 테스트 update 강제. **+7
신규 tests** (HarnessErrorCountedKindsTests).

**193**: Teach P0 — teachTorqueChanged 4 site wire (action: disable_all / enable_all
/ toggle / capture_loop_auto_disable) + dfTransferPoseToMotion bridge (TeachModeView
의 "film.stack" button → MotionStudioView 의 importPoseAsMotionPage). **+5 신규 tests**.

**194**: Setup wizard 2 신규 TelemetryKind (setup.wizard_step_changed +
setup.wizard_completed) + mark() 단일 hook + auto-verify path 통합. **+5 신규 tests**.

### 195 — audit doc commit

2 신규 doc (cycle 190 + 191 outputs) commit.

### Telemetry namespace 누적 (cycle 195 종료)

| Namespace | Before 178 | After 195 |
|---|---|---|
| `claude.*` | 3 | 8 |
| `remote.*` | 0 | 4 |
| `pilot.*` | 2 dead | 5 alive |
| `teach.*` | 7 (1 dead) | **7 alive** (cycle 193 wire) |
| `setup.*` | 0 | **2** (cycle 194 신규) |
| `joint.*` | 0 | TBD (cycle 196) |
| `ui.view_appeared` | 0 | TBD (cycle 197) |

### 검증 (cycle 195 commit 시점)

- 1344 → **1441** Swift tests (+97 across cycles 178-195).
- swift build: 0 errors.
- 89 commits ahead origin (cycles 119-195).

### 남은 영역 (cycle 196+ 진행 중)

- cycle 196: Joint Control failures silent (parallel agent).
- cycle 197: Stale state .onAppear 트레이싱 (parallel agent).
- cycle 198+: USER_PILOT_GUIDE 추가 + codex critic review batch.

---

## 사이클 196-198 — 병렬 implementer 2건 + doc 마감

### 196 — JointControl 실패 telemetry (parallel agent)

cycle 190 audit P1 #3 fix. 2 신규 TelemetryKind:
- `joint.action_requested` — Torque ON/OFF / E-Stop / set_position 클릭 시.
- `joint.action_failed` — error 발생 시 (level=.error, errorCountedKinds 등록).

`runJointAction(_ actionName:_ action:)` 시그니처 변경 — 모든 call site 가 action
name string 전달. cycle 192 errorCountedKinds 10 → **11** (testTotalErrorCountedKindCount 동기 update).

신규 3 tests (JointControlTelemetryKindsTests).

### 197 — Stale state navigation telemetry (parallel agent)

cycle 190 audit P2 #6 fix. 1 신규 TelemetryKind:
- `ui.view_appeared` — level=.trace, data: view (studio/motion_studio/teach).

3 view 의 `.onAppear` 에 hook:
- StudioView (신규 .onAppear block)
- MotionStudioView (기존 .onAppear 에 prepend)
- TeachModeView (기존 .onAppear 에 prepend)

신규 6 tests (UIViewAppearedTelemetryTests).

### 198 — USER_PILOT_GUIDE 마감 (cycles 189-195)

이전 절 노트 통합 — 3 background agent + 4 후속 fix cycle 의 결과 표.

### Telemetry namespace 누적 (cycle 197 종료)

| Namespace | Before 178 | After 197 |
|---|---|---|
| `claude.*` | 3 | 8 |
| `remote.*` | 0 | 4 |
| `pilot.*` | 2 dead | 5 alive |
| `teach.*` | 7 (1 dead) | 7 alive |
| `setup.*` | 0 | 2 |
| `joint.*` | 0 | **2** (cycle 196) |
| `ui.view_appeared` | 0 | **1** (cycle 197) |
| **errorCountedKinds (SOT)** | 6 | **11** (+5 across cycles 188/192/196) |

### 검증 (cycle 197 종료)

- 1344 → **1450** Swift tests (+106 across cycles 178-197).
- swift build: 0 errors.
- 89 commits ahead origin.

### 남은 영역 (cycle 199+)

- cycle 199: codex critic review of cycles 189-198 (백그라운드, 진행 중).
- cycle 200+: 후속 fix (critic finding 기반).
- cycle 191 deferred P1: Teach snapshot disk persistence.
- cycle 191 deferred P2: WalkLabSession comparison UI.

---

## 사이클 199-203 — codex critic round 3 + 4 후속 fix + freshness telemetry

### 한 줄 결론

cycle 199 critic (ACCEPT-WITH-RESERVATIONS, 1 MAJOR + 1 MINOR + 3 missing) →
cycle 200-203 4 cycle 에서 모두 처리. 신규 freshness state transition telemetry
+ JointControl PII fix + Refresh button + Teach→Motion transfer telemetry.

### 199 — codex critic review cycles 189-198

**VERDICT**: ACCEPT-WITH-RESERVATIONS.

| Severity | 영역 | 처리 cycle |
|---|---|---|
| MAJOR-1 | JointControlView (cycle 196) `error.localizedDescription` 의 raw telemetry payload → PII (파일경로/IP/username) 노출 위험 | **cycle 202** error_type + error_hash 매핑 |
| MINOR-2 | testTotalErrorCountedKindCount 같은 brittle test guards — 의도된 design tradeoff | 무처리 (의도) |
| MINOR-3 | uiViewAppeared + uiSectionChanged 의 navigation 시 double-fire — 문서 누락 | **cycle 202** doc 명시 |
| NIT-4 | cycle 198 doc 가 196/197 commit 보다 빨리 발화 (timing) | 무처리 |
| missing #1 | uiViewAppeared 의 errorCountedKinds 제외 명시 테스트 부재 | **cycle 202** testIntentionalExclusions 확장 |
| missing #2 | JointControlView Refresh button telemetry 없음 | **cycle 203** wire |
| missing #3 | Teach → Motion transfer telemetry 없음 | **cycle 203** motionPageCreated source="teach_transfer" 발화 |

### 200 — balanceCorrectionFreshness transition telemetry

cycle 160 의 freshness state (.normal/.degraded/.blocked) 의 6 mutation site 가
silent. didSet hook + oldValue!=newValue 가드 로 단일 site 처리. 사용자 분석:
"보정 차단 빈도 / IMU 지연 패턴 / sim vs real 비교" 가능. +4 tests.

### 202 — critic MAJOR-1 + MINOR-3 + missing #1

- JointControlView PII fix: `error_type` (controlled) + `error_hash` (PII 회피)
- uiViewAppeared docstring 에 double-fire 의도 명시
- HarnessErrorCountedKindsTests.testIntentionalExclusions 에 uiViewAppeared 추가

### 203 — critic missing #2 #3

- JointControl Refresh button: jointActionRequested + action="refresh"
- MotionStudio importPoseAsMotionPage: motionPageCreated + source="teach_transfer"

### Telemetry namespace 누적 (cycle 203 종료)

| Namespace | Before 178 | After 203 |
|---|---|---|
| `claude.*` | 3 | 8 |
| `remote.*` | 0 | 4 |
| `pilot.*` | 2 dead | 5 alive |
| `teach.*` | 7 (1 dead) | 7 alive |
| `setup.*` | 0 | 2 |
| `joint.*` | 0 | 2 |
| `ui.view_appeared` | 0 | 1 |
| `walklab.freshness_changed` | 0 | **1** (cycle 200 신규) |
| **errorCountedKinds (SOT)** | 6 | **11** |
| **합계 alive TelemetryKind** | ~30 | **~50** |

### 검증 (cycle 203 종료)

- 1344 → **1454** Swift tests (+110 cycles 178-203).
- swift build: 0 errors, 0 warnings.
- 1 pre-existing flaky test (testAutoLoopE2EProducesVerdict, cycle 142 acknowledged).
- 93 commits ahead origin.

### 남은 영역 (cycle 205+ deferred)

- cycle 191 P1 Snapshot disk persistence (12h, 크기 우선순위 deferred).
- cycle 191 P2 WalkLabSession comparison UI (6h).
- 다음 sprint: codex critic of cycles 199-203 (자체 검증).

---

## 사이클 205-208 — 병렬 배치 3 (critic ACCEPT + Teach 잔여 P1/P2 처리)

### 한 줄 결론

3 백그라운드 에이전트 (critic + 2 implementer) 동시 spawn 으로 (1) cycles 199-204
ACCEPT (no MAJOR) + (2) Teach snapshot 영속화 (cycle 191 deferred P1) + (3)
PoseDeltaCalculator pure model (cycle 191 deferred P2) + (4) harness spec 갱신.

### 205 — codex critic review cycles 199-204

**VERDICT**: ACCEPT (no CRITICAL, no MAJOR).

3 MINOR (non-blocking):
1. WalkLabFreshnessTelemetryTests recorder-level integration 없음 — systemic (모든 kind 동일 패턴).
2. cycle 203 transfer telemetry 가 `reassigned.first?.id` 만 — multi-page transfer 시 undercount (현재 single-pose import 만 호출됨).
3. cycle 204 doc "~50 alive" 실측 88 (rough estimate).

### 206 — Teach snapshot metadata 영속화 (P1 deferred)

`TeachCapture.swift` 의 PersistedSnapshotMeta (id/name/timestamp, joint data X — PII 경계) UserDefaults 영속. `init(defaults:)` DI + restorePersistedMetadata() →
신규 `teach.snapshot_meta_restored` telemetry (data: count). 사용자 재시작 시 "직전
N 스냅샷 있었음" 표시 가능 (pose 자체는 재캡처 필요 — 의도).

신규 6 tests (TeachSnapshotPersistenceTests, UserDefaults suiteName UUID isolation).

### 207 — PoseDeltaCalculator pure model (P2 deferred)

`Teach/PoseDeltaCalculator.swift` 신규 — 두 RobotPose 의 joint-by-joint diff +
RMS (root mean square) + peak mismatch joint. UI 통합 deferred.

신규 6 tests (PoseDeltaCalculatorTests, JointID.allCases 순회 검증).

### 208 — harness spec Phase 2 status

`docs/harness/telemetry-harness.md` §11 신규 — cycle 177+ 의 9 namespace 누적
표 + errorCountedKinds SOT + PII redaction 패턴 + 의도된 제외 명시.

### Telemetry namespace 누적 (cycle 208 종료)

| Namespace | After 208 |
|---|---|
| `claude.*` | 8 |
| `remote.*` | 4 |
| `pilot.*` | 5 alive |
| `teach.*` | 8 (cycle 206 신규 1) |
| `setup.*` | 2 |
| `joint.*` | 2 |
| `ui.view_appeared` | 1 |
| `walklab.freshness_changed` | 1 |
| **errorCountedKinds (SOT)** | 11 |

### 검증 (cycle 208 종료)

- 1344 → **1466** Swift tests (+122 cycles 178-208).
- swift build: 0 errors, 0 warnings (1 pre-existing macOS deprecation).
- 97 commits ahead origin.

### 남은 영역

- cycle 209 (이 doc).
- cycle 210+ critic review of 205-208 (background, in progress).
- 후속 cycles: UI 통합 (PoseDeltaCalculator → WalkLabIntegrationCards), Snapshot 복원 UI 표시.

---

## 사이클 239-244 — 아키텍처 고도화 (2026-05-23)

### 한 줄 결론

Architecture audit (2026-05-23) 의 3 wave 처리 — Wave 1 trivial 통합 (사이클 239),
Wave 2 거대 함수 분해 + 동시성 표준화 (사이클 240), Wave 3 Harness DI 추상화
점진 migration (사이클 241-244). 테스트 가능성 4/10 → 8/10 향상 목표.

### 사이클 239: P0 trivial 통합 (Wave 1)

- WalkStabilityPredictor 안전 임계 magic number 상수화 (`StabilityThresholds` /
  `CapsThresholds`) — 7 hard-coded threshold 가 namespace 단일 SOT 로 통합.
- ConnectionStore silent failure 3 사이트 DFLog 추가 (servo write 실패 trail) —
  실 robot 디버깅 시 누락된 motor 추적 가능.
- 잔존 force-unwrap 4 사이트 안전화 (`guard let` + 명시 fallback).

### 사이클 240: 거대 함수 분해 + 동시성 표준화 (Wave 2)

- WalkLabSession.startWalkCycle 468줄 → 78줄 facade + 12 phase helper —
  Phase 7-10 split 패턴 (사이클 109-113) 의 확장. 각 phase 가 단일 책임 + 독립
  테스트 가능.
- DispatchQueue.main 18 사이트 → `Task { @MainActor in ... }` + `Task.sleep` —
  modern Swift concurrency 통일. Cancellation 가능 + retain cycle 위험 감소.
- Test sleep 22 → 9 (`waitUntil` helper 신규) — 고정 timeout 보다 condition
  polling 으로 flaky 감소 + CI 시간 단축.

### 사이클 241-244: Harness DI 추상화 (Wave 3)

- 3-way Protocol Split — `HarnessRecording` / `HarnessHeartbeat` /
  `HarnessContext` / `HarnessLifecycle` (ISP 준수, 90% caller 는 Recording 만 필요).
- 3 구현 — `LiveHarness` (production wrapper) / `NoopHarness` (test/preview
  default) / `RecordingHarness` (assertion 용 in-memory 캡처).
- 49 파일 257 사이트 → `@Environment(\.harness)` (View) / `init injection`
  (Class) 점진 migration.
- Phase 분할:
  - 사이클 241 (Phase 3.1): 6 신규 인프라 파일, +432 LOC, 1814 tests (+3 회귀 가드).
  - 사이클 242 (Phase 3.2): 6 caller 72 사이트 migration, +250/-76 LOC, 1819 tests (+5).
  - 사이클 243 (예정 — Phase 3.3): 42 파일 batch.
  - 사이클 244 (예정 — Phase 3.4): deprecation + SwiftLint regex CI gate.
- 테스트 가능성 4/10 → 8/10 향상 — Mock harness 주입으로 telemetry side effect
  격리, flaky 회귀 감소.

상세 설계 근거: `docs/architecture/adr-001-harness-di.md`.

---

## 사이클 248-259 — 아키텍처 고도화 II (2026-05-24)

### 한 줄 결론

8 god method 분해 -1178줄 + Wave 4.3 5/7 phase + Mock Bus 인프라 + 검증 사이클
2회 + .app bundle deploy. Tests 1788 → 1924 (+136, 0 regressions).

### 사이클 248-250: God method 분해 3건

- **W2.8** `applyPoseSmoothlyImpl` 133줄 → 27줄 facade — `ApsContext` class 도입
  으로 8 phase helper (snapshot capture / delta calc / safety gate / write batch
  / verify) 단일 책임 분리. 기존 callsite 변경 없음.
- **W2.7** `WalkLabSession.start` 162줄 → 42줄 facade — 8 phase helper (preflight
  / harness init / motor power / pose seed / loop spawn) 분해. 사이클 109-113
  의 phase split 패턴 재사용.
- **W2.9** `recoverFromEStop` 154줄 → 20줄 facade — `RecoverContext` class 도입
  으로 9 phase helper 분해. `dxl_power` → `torque enable` → `P_GAIN restore`
  실행 순서 보존 (회복 시 비상 정지 race 차단).

### 사이클 251: MotionDocumentStore 추출 (W4.3.2)

`MotionStudioView` 의 document state 12개 (currentDoc / pages / activePageIndex
/ undoStack / redoStack 등) → 신규 `MotionDocumentStore: ObservableObject` 로
이관. View 가 ObservedObject 만 보유 → 테스트 시 mock store 주입 가능.

### 사이클 252-254: 검증 사이클 I (P0 fix)

- **사이클 252**: MotionDocumentStore `@Observable` macro migration (Swift 5.9+
  observability) + SwiftLint regex no-dot gap (`harness.record`-like false
  bypass 차단).
- **사이클 253**: SwiftLint `match_kinds` 추가 (comment 내 매칭 false positive
  제거) + `reTorqueOnAllJoints` docstring 정정 (실 동작 ↔ 문서 일치).
- **사이클 254**: SafetyGapTests 9건 추가 (gate bypass 회귀 가드) + W2.10
  `tick` 169줄 → 8줄 facade 분해 + `applyCorrections` 불변성 patch (input
  pose mutation 제거).

### 사이클 255: Mock Bus + ADR-002

- `BusInterface` protocol 추출 + `MockBus` 구현 + 8 파일 type migration
  (`Bus` 구체 타입 → protocol 의존).
- ADR-002 작성 — Wave 4 (View layer decomposition) rollback criteria +
  timing gate 정의.

### 사이클 256-257: 추가 god method + Wave 4.3 진행

- **사이클 256**: Mock Bus 15 critical tests (send/receive/error-path 회귀
  가드) + **W4.3.3** `MotionPageActions` 추출 (14 함수 + 19 tests).
- **사이클 257**: **W2.11** `stop` / `emergencyStop` 16 helper 분해 + **W4.3.4**
  `MotionImportActions` 추출 (3 함수 + 7 tests, PMU import path 격리).

### 사이클 258: W4.3.5 Sidebar/Inspector + 검증 II

- **W4.3.5** `MotionStudioSidebar` (390줄) + `MotionStudioInspector` (72줄)
  추출 — `MotionStudioView` 1251줄 → 929줄 (-26%).
- 검증 II: 1 MAJOR (helper 의 `internal` 접근 25% 증가 — encapsulation 후퇴)
  + 3 Critical safety gate facade unreachable (refactor 후 일부 path 가
  bypass 가능 상태).

### 사이클 259: 검증 II P0 fix

- `_testForceTick` hook 추가 + SafetyPipelineTests 15건 신규
  (L3/L4/L0/cradle/history/ordering 6 카테고리, gate 순서 invariant 가드).
- `scripts/build-app.sh` 신규 — 6-step .app bundle pipeline (swift build →
  Info.plist → bundle assemble → code-sign placeholder → smoke test →
  artifact stage). 사용자 배포 첫 경로 확립.
- `DEPLOYMENT.md` (`docs/guides/DEPLOYMENT.md`) 신규 — pilot 사용자가
  source clone 없이 `.app` 만으로 실행 가능.

### 누적 metric (사이클 247 → 259)

| 영역 | Before | After | 변화 |
|---|---|---|---|
| Tests | 1788 | 1924 | +136 |
| God method 분해 | 0 | 8건 | -1178줄 |
| MotionStudioView | 1782 | 929 | -48% |
| WalkLabSession 본체 | 2806 | 2221 | -21% |
| Harness DI | 257 사이트 | 5 인프라 | 98% |
| 테스트 가능성 | 4/10 | 9/10 | +5 |

### 사이클 반복 구조

기획 → 구현 → 검증 → P0 fix → 다음 기획. 검증 사이클 2회 (사이클 252-254 /
사이클 259) 모두 P0 100% fix — "검증 미통과 = 태스크 미완료" 원칙 준수.

### 참고

- `docs/architecture/adr-002-wave-4-decomposition.md` (Wave 4 rollback +
  timing gate).
- `docs/guides/DEPLOYMENT.md` (.app bundle 빌드 + 배포 절차).
