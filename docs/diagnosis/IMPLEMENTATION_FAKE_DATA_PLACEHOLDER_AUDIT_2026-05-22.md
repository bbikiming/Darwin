# 구현 팔로우업 감사 보고서 — 오류·가짜 데이터·보여주기식 구현 점검

- 작성일: 2026-05-22
- 대상 경로: `/Users/bbikiming/Documents/vibe_coding/Darwin`
- 브랜치: `claude/robotis-darwin-op-setup-oyzTi`
- 참여 기준:
  - 스튜디오 코덱스: 코드 검색, 실제 데이터 흐름, 테스트 실행, 위험도 분류
  - 스튜디오 클로드: 제품/UX 관점 보강 대상으로 공유
- 작업 원칙: 실제 앱 구현 변경 없음. 코드 감사, 테스트, 문서 작성만 수행.

---

## 0. 한 줄 결론

전체 테스트는 통과하지만, 현재 구현에는 **사용자에게 실제 동작처럼 보일 수 있는 추정 진행 UI, sim 데이터 기반 추천, production 미연결 adapter, placeholder 공식 모션, 긴급정지 미완성 경로**가 남아 있다.

이번 1차 감사에서 코드 근거가 있는 항목을 **18건**으로 분류했다.

---

## 1. 검증 방법

- 전체 소스에서 `TODO`, `FIXME`, `mock`, `fake`, `stub`, `placeholder`, `no-op`, `가짜`, `임시`, `하드코딩`, `random`, `fatalError` 키워드 검색
- 검색 후보 중 실제 사용자 화면, 로봇 송출, 추천/검증, 초기 설정, Motion/Pilot/WalkLab 흐름에 연결되는 항목만 선별
- Swift UI 패키지 전체 테스트 실행
- Rust core 전체 테스트 실행
- 기존 WalkLab 실시간 반영 보고서의 결론도 이번 감사 범위에 포함

---

## 2. 테스트 결과

### Swift / DarwinForge

- 명령: `swift test`
- 결과: **1305개 테스트 통과, 실패 0개**
- 남은 경고:
  - `Sources/DarwinForgeApp/Info.plist`
  - `Sources/DarwinForgeApp/DarwinForge.entitlements`
  - SwiftPM에서 두 파일이 target resource 또는 exclude로 명시되지 않았다는 경고가 발생한다.

### Rust / app/core

- 명령: `cargo test`
- 결과:
  - `forge` CLI: 13개 통과
  - `forge-core`: 312개 통과
  - `forge-ffi`: 11개 통과
  - `forge-mcp-synth`: 32개 통과
  - doctest는 2개 ignored, 실패 없음

테스트 기준으로는 현재 브랜치가 깨져 있지는 않다. 다만 아래 항목들은 테스트 통과 여부와 별개로 **제품 신뢰도/실로봇 안전/사용자 오해** 관점에서 수정 또는 명확한 라벨링이 필요하다.

---

## 3. 핵심 발견 요약

### P0 — 안전 또는 실로봇 동작 신뢰도에 직접 영향

1. `forge motion play --engage`의 Ctrl+C 긴급정지 처리 placeholder
2. WalkLab `.robotisOnboard` 모드에서 `balanceGain`, `enableBalanceCorrection`, `correctorIntensityLevel`이 로봇 펌웨어로 송신되지 않음
3. D-pad 방향 조작이 “전진/후진/좌우/회전”처럼 보이지만 실제는 1회 pose 적용 후 700ms 뒤 `walkReady` 복귀
4. MotionBlender는 sim-only인데 일부 경로에서 “motion 적용” 메시지가 실제 하드웨어 송출처럼 읽힐 수 있음

### P1 — 사용자가 실제 기능으로 오해하기 쉬움

5. Remote Pilot 모드 전환 progress가 실제 로봇 상태가 아니라 estimated fake progress로 진행되는 경우가 있음
6. WalkTrial Recommender가 sim 자동 생성 trial을 기본 추천 근거로 사용할 수 있고, 추천 카드에는 sim/real 근거 구분이 없음
7. 공식 모션 카탈로그의 Get Up Front / Get Up Back / Hand Standing이 실제 공식 raw motion이 아니라 `walkReady` hold placeholder
8. DJI Controller Adapter는 production SDK 미통합 stub이며 mock/source 주입 경로만 동작
9. Initial Setup Wizard가 “자동 검증”처럼 안내하지만 VNC 단계는 사용자가 버튼을 누르면 완료 처리됨
10. Static Stability Validator는 실제 CoM/물리 검증이 아니라 단순 proxy이며 `single_foot_ok` 메타데이터가 있으면 체크를 skip
11. MotionDoc의 TORQUE_OFF bit preview semantics가 공식 동작이 아니라 “이전 target 유지” placeholder

### P2 — 문서/주석/UX 라벨 불일치 또는 혼선

12. SynthInspectorPanel은 합성 결과를 앱 안에서 자동 검증하지 않고 “미검증” 경고만 표시
13. PilotFeatureFlags `v1_5` 주석은 일부 기능이 OFF라고 설명하지만 실제 기본값은 ON
14. WalkLab tuning 주석 중 `footHeightMm`은 “엔진 미반영”이라고 되어 있으나 현재 command serialization에는 포함됨
15. `MotionBuilder`의 fallback page ID가 random이라 호출자가 재할당을 빼먹으면 비결정적 ID가 생길 수 있음
16. Synthetic IMU / Auto Trial Generator는 명시적으로 sim용이지만, downstream 추천·분석에서 실험 데이터와 섞이지 않게 더 강한 표시가 필요
17. WalkComparisonTag와 Claude recommender strategy는 현재 compatibility/future hook 성격
18. SwiftPM resource 경고가 남아 있어 앱 패키징 시 `Info.plist` / entitlements 처리 의도가 불명확

---

## 4. 상세 발견

### 4.1 `forge motion play --engage` Ctrl+C 긴급정지 placeholder

- 파일: `app/core/forge-cli/src/motion_play.rs`
- 코드 근거:
  - 파일 상단 주석에서 Ctrl+C 시그널 처리가 현재 placeholder라고 명시
  - `setup_ctrlc_handler()`가 실질적인 torque off 없이 `Ok(())`만 반환
- 문제:
  - `--engage`는 실제 모터 송출을 의미한다.
  - 이 상태에서 Ctrl+C를 눌렀을 때 토크 OFF 또는 P gain zero가 보장되지 않는다.
- 사용자 관점:
  - CLI가 멈추면 로봇도 안전 정지했다고 기대하기 쉽지만, 현재 구현은 그 보장을 하지 않는다.
- 권고:
  - P0로 별도 구현 필요.
  - 최소한 CLI 실행 전 “Ctrl+C는 emergency stop이 아님”을 강하게 표시해야 한다.

### 4.2 WalkLab Onboard 모드에서 일부 설정 미송신

- 파일:
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkingEngine.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/WalkLabOnboardBridge.swift`
- 코드 근거:
  - `WalkingEngineCommand` 직렬화 필드는 `enabled`, `x`, `y`, `a`, `period`, `foot`, `hipPitch` 7개
  - `balanceGain`, `enableBalanceCorrection`, `correctorIntensityLevel`은 Onboard command에 포함되지 않음
- 문제:
  - UI에서는 자이로/균형 보정이 WalkLab 설정처럼 보이지만, `.robotisOnboard`에서는 로봇 펌웨어로 전달되지 않는다.
- 사용자 관점:
  - “균형 게인 조절했는데 왜 로봇 반응이 같지?”라는 혼란이 생긴다.
- 권고:
  - Onboard 모드에서는 미반영 항목을 disabled 또는 “Mac sparse 전용”으로 표시.
  - 장기적으로 firmware daemon command schema에 balance 관련 필드를 추가.

### 4.3 D-pad 방향 조작은 continuous teleop이 아니라 one-shot pose

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotDpad.swift`
- 코드 근거:
  - 버튼 라벨은 `전진`, `후진`, `좌이동`, `우이동`, `좌회전`, `우회전`
  - 실제 처리에서는 `zone.makePose()`로 단일 자세를 적용하고, 700ms 뒤 `.walkReady`로 복귀
- 문제:
  - 사용자는 게임 조작처럼 계속 걷거나 이동한다고 기대할 수 있다.
  - 실제로는 walking IK나 continuous teleop이 아니라 짧은 pose nudge다.
- 권고:
  - 라벨을 “전진 포즈”, “좌이동 포즈”처럼 바꾸거나, 설명에 “연속 보행 아님”을 노출.
  - 진짜 teleop은 WalkLab RC bridge / walking amplitude path와 연결해야 한다.

### 4.4 MotionBlender는 sim-only인데 적용 메시지가 강함

- 파일:
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/Motion/MotionBlender.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/WalkLabRCBridge.swift`
- 코드 근거:
  - MotionBlender 주석에 “실 robot 송출은 안 함”, “본 phase에선 송출 자체 미구현”이라고 명시
  - `WalkLabRCBridge.handleMotion()`은 `motionBlender.play()`가 accepted면 `motion '...' 적용` 이벤트를 남김
- 문제:
  - 내부적으로는 sim/composition 상태만 바뀌는데, 메시지는 실제 적용처럼 읽힌다.
- 권고:
  - 메시지를 “motion preview/blend 적용”으로 바꾸거나 하드웨어 송출 여부를 함께 표시.

### 4.5 Remote Pilot progress가 추정 기반으로 진행

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/RemotePilotView.swift`
- 코드 근거:
  - automatic step은 `estimatedSeconds` 동안 fake progress
  - patched ball-follow demo가 설치된 경우에만 progress file polling으로 실제 stage를 sync
  - step id가 robot stage와 다르면 fake fallback
- 문제:
  - progress bar가 실제 로봇 상태 확인이 아니라 시간 추정일 수 있다.
- 권고:
  - UI에 “추정 진행”과 “로봇 확인됨” 상태를 분리.
  - 실제 stage polling이 없는 모드는 완료 체크 아이콘 대신 estimated badge 사용.

### 4.6 WalkTrial Recommender가 sim trial을 실제 추천처럼 사용할 수 있음

- 파일:
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Recommender/WalkTrialRecommender.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Trials/WalkTrialStore.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Trials/WalkTrialAutoGenerator.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Recommender/WalkTrialRecommenderCard.swift`
- 코드 근거:
  - `TrialFilter`에는 `realRobotOnly` 필드가 있지만 기본값은 `false`
  - `ruleBased`, `coordinateDescent`, `pilotBiased` 추천 필터에서 `realRobotOnly: true`를 지정하지 않음
  - AutoGenerator는 sim mode trial을 자동 생성해 store에 저장
  - 추천 카드에는 `데이터 n%`, `기반 trial n개`만 보이고 sim/real 근거 비율은 표시하지 않음
- 문제:
  - sim에서 자동 생성된 trial이 충분히 쌓이면 추천이 “데이터 기반”처럼 보인다.
  - 사용자는 이 추천을 실로봇에 적용할 수 있다.
- 권고:
  - 추천 카드에 `실로봇 n개 / 시뮬 n개` 근거 비율 표시.
  - 실로봇 연결 상태에서 추천을 적용할 때 sim-only 추천이면 확인 단계 추가.
  - P0/P1 보행 추천은 `realRobotOnly` 기본값을 true로 두고, sim 추천은 별도 탭으로 분리.

### 4.7 공식 모션 카탈로그 일부가 placeholder

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/OfficialCatalogReference.swift`
- 코드 근거:
  - Get Up Front, Get Up Back, Hand Standing이 placeholder라고 주석 명시
  - 실제 steps는 `walkReady` hold 수준
- 문제:
  - 이름은 “공식 10 — Get Up Front”, “공식 17 — Hand Standing”처럼 보인다.
  - 사용자는 공식 복구 동작 또는 고위험 동작이 실제 구현됐다고 오해할 수 있다.
- 권고:
  - UI 목록 이름 앞에 `[placeholder]` 또는 `[preview only]`를 붙임.
  - 실제 raw 실행은 CLI slot playback과 명확히 분리.

### 4.8 DJI Controller Adapter는 production SDK 미통합

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/DJI/DJIControllerAdapter.swift`
- 코드 근거:
  - 파일 주석에 “DJI Controller Stub Adapter”, “현재는 stub — 외부 simulator / mock만 사용” 명시
  - production constructor는 unavailable이고 “DJI SDK 미통합” 메시지 포함
- 문제:
  - 테스트는 mock source로 잘 통과하지만 실제 DJI SDK 입력은 아직 없다.
- 권고:
  - UI에서 DJI RC를 “실험/Mock ready”로 표시.
  - 실제 SDK 통합 전에는 production 입력 소스로 노출하지 않기.

### 4.9 Initial Setup Wizard의 VNC 단계는 자동 검증이 아님

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/InitialSetupWizard.swift`
- 코드 근거:
  - 화면 설명은 “자동 검증되니 단계가 끝나면 자동으로 다음으로”
  - VNC 단계 주석은 “정확한 검증 어려움. 사용자가 한 번 열었음 클릭하면 완료”
  - `VNC 데스크톱 열기` 버튼에서 URL open 후 `.vnc`를 completed로 mark
- 문제:
  - 사용자는 실제 연결 검증이 완료된 것으로 오해할 수 있다.
- 권고:
  - VNC 단계만 “수동 확인”으로 분리.
  - 가능하면 Screen Sharing process 감지 또는 사용자 체크박스를 별도 표시.

### 4.10 Static Stability Validator는 실제 물리 검증이 아님

- 파일: `app/core/forge-core/src/synth/validator/static_stability.rs`
- 코드 근거:
  - 주석에서 실제 CoM 계산 전의 단순 heuristic proxy라고 명시
  - `single_foot_ok` 메타데이터가 있으면 stability check를 skip
- 문제:
  - Synth validate 통과가 실제 낙상 안정성 통과로 해석될 수 있다.
- 권고:
  - 결과 라벨을 “정적 안정성 proxy”로 표시.
  - single-foot motion은 별도 위험 동의와 실물 검증 checklist 필요.

### 4.11 MotionDoc TORQUE_OFF bit preview semantics placeholder

- 파일: `app/ui/DarwinForge/Sources/ForgeCore/MotionDoc.swift`
- 코드 근거:
  - TORQUE_OFF bit를 “자세 변경 없이 이전 target 유지”로 처리
  - 주석에 공식 동작이 아닌 placeholder라고 명시
- 문제:
  - preview와 실제 ROBOTIS Action 동작이 달라질 수 있다.
- 권고:
  - Motion preview에서 torque-off step이 포함된 페이지는 “preview approximate” 표시.

### 4.12 SynthInspectorPanel은 앱 내부 자동 검증이 아님

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Synth/SynthInspectorPanel.swift`
- 코드 근거:
  - 이전 hardcoded pass는 제거됨
  - 현재는 “이 화면에선 검증되지 않음” warning 표시
  - 실제 검증은 terminal `forge synth validate <page.json>` 안내
- 평가:
  - 가짜 pass는 고쳐졌으므로 긍정적이다.
  - 다만 사용자가 앱 안에서 곧바로 검증됐다고 생각하지 않도록 warning을 더 강하게 유지해야 한다.

### 4.13 PilotFeatureFlags `v1_5` 주석과 실제 기본값 불일치

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotFeatureFlags.swift`
- 코드 근거:
  - 주석은 `dpadRealMotor`, `hsvTuning` 등이 OFF라고 설명
  - 실제 `v1_5` 값은 `dpadRealMotor = true`, `hsvTuning = true`
  - `RemotePilotView`의 기본 feature level도 `v1_5`
- 문제:
  - 안전/출시 단계 판단 시 문서와 실제 런타임이 다르다.
- 권고:
  - 주석을 현재 기본값에 맞게 갱신하거나 feature level을 재분리.

### 4.14 WalkLab tuning 주석 일부가 현재 동작과 다름

- 파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift`
- 코드 근거:
  - `footHeightMm` 주석은 “sim 영향 — 엔진 미반영”
  - 현재 `currentWalkingEngineCommand()`와 `WalkingEngineCommand.serializedLine`에는 `footHeightMm`가 포함됨
  - `balanceGain`은 여전히 Onboard command에는 빠져 있어, 모드별 설명이 필요
- 문제:
  - 주석만 보고 기획/검증하면 잘못된 결론을 낼 수 있다.
- 권고:
  - “Mac sparse / sim / Onboard”별 반영 여부를 주석과 UI tooltip에 분리.

### 4.15 MotionBuilder random ID fallback

- 파일: `app/ui/DarwinForge/Sources/ForgeCore/MotionBuilder.swift`
- 코드 근거:
  - `UInt8.random(in: 100...250)`로 임시 ID를 생성하고 호출자가 재할당한다고 주석 처리
- 문제:
  - 호출자가 재할당을 빼먹으면 저장/비교/테스트에서 비결정적 ID 또는 충돌이 생길 수 있다.
- 권고:
  - 임시 ID를 명시적 placeholder ID로 고정하거나 builder output에 “unassigned id” 상태를 도입.

### 4.16 Synthetic IMU / Auto Trial 데이터는 sim 표시 강화 필요

- 파일:
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/SyntheticImuGenerator.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Trials/WalkTrialAutoGenerator.swift`
- 코드 근거:
  - Synthetic IMU는 random Gaussian noise 기반
  - Auto Trial은 sim mode 전용으로 trial을 자동 저장
- 평가:
  - 테스트와 초기 UX 검증에는 유용하다.
  - 다만 추천/학습/품질 점수에서는 실로봇 데이터와 섞이면 “가짜 성능”처럼 보일 수 있다.
- 권고:
  - 모든 분석/추천 결과에 source badge를 필수화.
  - sim 데이터는 별도 storage namespace 또는 기본 필터 제외를 검토.

### 4.17 WalkComparisonTag / Claude critic strategy는 future hook

- 파일:
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkComparisonTag.swift`
  - `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Recommender/WalkTrialRecommender.swift`
- 코드 근거:
  - WalkComparisonTag는 compatibility stub
  - `.claudeCritic` strategy는 enum에는 있으나 recommender가 직접 instantiate하지 않는 placeholder
- 문제:
  - UI에서 해당 용어가 노출될 경우 실제 분석이 붙어 있다고 오해할 수 있다.
- 권고:
  - “추후 통합” 라벨 유지.
  - 실제 카드로 생성되지 않는지 UI snapshot 테스트 추가.

### 4.18 SwiftPM resource 경고

- 파일:
  - `app/ui/DarwinForge/Sources/DarwinForgeApp/Info.plist`
  - `app/ui/DarwinForge/Sources/DarwinForgeApp/DarwinForge.entitlements`
- 현상:
  - `swift test` 실행 시 두 파일이 unhandled file이라고 경고
- 문제:
  - 테스트 실패는 아니지만 앱 패키징/권한/배포 의도가 불명확하다.
- 권고:
  - `Package.swift`에서 resource 또는 exclude 의도를 명시.

---

## 5. 반대로 긍정적으로 확인된 부분

- 전체 Swift 테스트 1305개가 통과했다.
- Rust core 테스트도 모두 통과했다.
- MotionStudio는 `sendToHardware`가 켜져 있어도 bus가 없으면 “로봇 송출 중”으로 표시하지 않도록 방어되어 있다.
- SynthInspectorPanel은 이전 hardcoded pass 위험을 제거하고 “미검증”으로 표시한다.
- WalkLab은 sim/real/stale 출처를 표시하려는 구조가 이미 있다.
- DJI/Gamepad/Voice/Tello 계열은 mock-first 구조라 테스트 가능성은 좋다. 문제는 mock 상태를 production 가능 상태로 오해하지 않게 하는 것이다.

---

## 6. 우선순위 권고

### 즉시 처리 권장

1. `forge motion play --engage` Ctrl+C 긴급정지 구현 또는 강한 경고 추가
2. WalkLab Onboard 미송신 항목 UI 비활성/tooltip 처리
3. Recommender 추천 카드에 sim/real 근거 비율 표시
4. Remote Pilot progress에 “추정 진행” 표시
5. 공식 모션 placeholder 이름에 `[placeholder]` 또는 `[preview only]` 추가

### 다음 스프린트

1. D-pad 방향 조작을 실제 walking amplitude/IK path로 연결하거나 라벨 수정
2. MotionBlender accepted 이벤트를 preview와 hardware-applied로 분리
3. DJI RC production SDK 통합 전까지 실사용 노출 제한
4. Initial Setup Wizard VNC 단계 수동 확인 라벨링
5. Static stability validator 결과를 “proxy”로 명확히 표시

### 문서/정리

1. PilotFeatureFlags 주석 갱신
2. WalkLab tuning 주석을 모드별 반영 기준으로 갱신
3. MotionBuilder random ID fallback 제거 또는 명시적 unassigned ID 도입
4. SwiftPM resource 경고 정리

---

## 7. 제품/UX 관점 핵심 문구 제안

사용자가 헷갈리지 않게 아래 표현을 UI에 쓰는 것을 권장한다.

- “실제 로봇 확인됨”
- “추정 진행 중”
- “시뮬레이션 데이터 기반 추천”
- “실로봇 데이터 기반 추천”
- “Preview only”
- “Mock/SDK 미연결”
- “앱 내부 미검증 — CLI 검증 필요”
- “연속 보행 아님 — 단일 자세 테스트”

---

## 8. 최종 판단

현재 구현은 테스트 기준으로 안정적이지만, “보여주기식 구현”으로 오해될 수 있는 지점이 아직 있다. 특히 **sim 기반 추천**, **추정 progress**, **stub adapter**, **placeholder 공식 모션**, **실로봇 긴급정지 미완성**은 사용자에게 명확히 분리해서 보여줘야 한다.

이번 감사의 핵심은 “기능을 숨기자”가 아니라, **실제 로봇에 적용되는 것 / 시뮬레이션인 것 / 향후 연결 예정인 것 / 검증되지 않은 것**을 UI와 문서에서 분명히 갈라야 한다는 점이다.
