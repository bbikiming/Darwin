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
