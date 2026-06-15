# WalkLab 설정값 실로봇 반영/실시간 적용 검증 보고서

- 작성일: 2026-05-21
- 대상 경로: `/Users/bbikiming/Documents/vibe_coding/Darwin`
- 검증 범위: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/`
- 협업 기준: 클로드는 제품/UX 관점 1차 검토, 코덱스는 코드 경로/테스트 관점 보강
- 작업 원칙: 실제 구현 변경 없음. 기획, 검증, 테스트, 보고서 작성만 수행

---

## 1. 한 줄 결론

WalkLab의 대부분 설정은 실제 송신 경로가 존재하지만, **로봇 쪽 ROBOTIS Onboard 엔진에서는 “보폭/측면/회전/주기/발 높이/Hip pitch trim”만 명확히 송신되고, “균형 게인(balanceGain)”과 “자세 보정 ON/OFF·강도”는 로봇 펌웨어로 전달되지 않는다.**

따라서 사용자에게 “워크랩에서 보이는 모든 설정이 실제 로봇에 실시간 반영된다”고 안내하면 안 된다.  
정확한 안내는 **엔진 모드별로 반영 범위를 나누어 표시**해야 한다.

---

## 2. 검증 방식

이번 검증은 실제 로봇 하드웨어를 연결한 물리 실험이 아니라, 다음 근거를 기반으로 한 코드/테스트 검증이다.

- UI 바인딩 확인
- `WalkLabSession` 상태값 추적
- `.macSparseKeyframe` 호스트 송출 경로 확인
- `.robotisOnboard` SSH brokering 송신 경로 확인
- `WalkingEngineCommand` 직렬화 필드 확인
- 실시간 반영 타이밍 확인
- 빌드 분기(`#if DEBUG`) 확인
- 기존 Swift 테스트 일부 실행

실행한 테스트:

- 명령:
  - `swift test --filter WalkLabV115OnboardEngineTests --filter WalkLabV114SafetyAndTrimTests`
- 결과:
  - 총 29개 테스트 통과
  - 실패 0개
- 의미:
  - Onboard 명령 직렬화
  - Hip pitch trim 전달
  - 현재 preset tuning 반영
  - 안전/trim 관련 회귀 테스트는 통과

단, 이 테스트는 실제 모터가 움직이는 실물 검증은 아니다. 실물 검증은 별도 체크리스트가 필요하다.

---

## 3. WalkLab에는 사실상 세 가지 적용 경로가 있다

### 3.1 시뮬레이션/프리뷰 경로

주요 코드:

- `WalkLabSession.syncCommandToEngine()`
- `engine.setCommand(...)`
- `engine.setPeriodMs(...)`

의미:

- UI에서 슬라이더를 움직이면 화면상 시뮬레이션 엔진에는 즉시 가까운 형태로 반영된다.
- 하지만 이 경로는 실제 로봇 송신이 아니다.
- 사용자가 “화면에서 반응한다 = 로봇에도 반영된다”고 오해할 수 있다.

판정:

- 화면 미리보기 반영은 OK
- 실제 로봇 반영으로 보장하면 안 됨

---

### 3.2 Mac sparse keyframe / 호스트 송출 경로

주요 코드:

- `WalkLabSession.start(_:)`
- `WalkLabSession.startWalkCycle(...)`
- `WalkMotionLibrary.continuousWalkPlan(for:tuning:)`
- `WalkMotionLibrary.page(for:tuning:)`
- `runContinuousWalk(...)`
- `runWalkCycle(...)`
- `bus.setPosition(...)`

동작 요약:

- 앱이 Mac 쪽에서 보행 keyframe/plan을 합성한다.
- 합성된 pose가 `ConnectionStore.bus`를 통해 모터 `setPosition`으로 직접 송출된다.
- 보행 중 고급 슬라이더가 바뀌면 `syncCommandToEngine()`이 호출되고, 약 220ms 뒤 `startWalkCycle(preset)`을 다시 호출해 현재 preset을 새 tuning으로 재시작한다.

중요한 해석:

- 이 경로에서는 고급 슬라이더가 실제 모터 송출에 반영된다.
- 다만 “모터 제어 파라미터를 매 순간 부드럽게 주입”하는 방식이라기보다, **짧은 debounce 후 보행 cycle을 새 설정으로 재합성/재시작**하는 방식이다.

반영되는 주요 값:

- 보폭 `strideMm`
- 측면 보폭 `sideMm`
- 회전 `turnDeg`
- 주기 `customPeriodMs`
- 발 들기 높이 `footHeightMm`
- 균형 게인 `balanceGain`
- Hip pitch trim `hipPitchOffsetTrimDeg`
- Mac 측 자세 보정 `enableBalanceCorrection`
- Mac 측 보정 강도 `correctorIntensityLevel`
- Balance experiment config 중 Mac pose transform에 연결되는 값

판정:

- `.macSparseKeyframe` 모드에서는 대부분 UI 설정이 실제 모터 송출 경로에 연결되어 있음
- 실시간성은 “즉시 주입”이 아니라 “약 220ms debounce 후 재시작 반영”으로 표현하는 것이 정확함

---

### 3.3 ROBOTIS Onboard / 로봇 펌웨어 송신 경로

주요 코드:

- `WalkLabOnboardBridge`
- `WalkLabSession.currentWalkingEngineCommand(enabled:)`
- `WalkingEngineCommand.serializedLine`
- `RobotSetupCommand.walkLabRobotisSendCommand(...)`
- `RemoteShell.exec(...)`

송신 조건:

- `session.walkingEngine == .robotisOnboard`
- `session.autoOnboardBrokering == true`
- `remoteShell.host`가 비어 있지 않음

즉, Onboard 모드라고 해서 항상 자동 송신되는 것은 아니다.  
자동 송신은 `autoOnboardBrokering`이 켜져 있고 원격 host가 설정되어 있어야 한다.

즉시 송신되는 변경:

- preset 변경
- activeRobotPreset 변경
- walkingEngine 변경
- autoOnboardBrokering 변경
- onboardWalkingActive 변경
- remoteShell.host 변경

300ms debounce 후 송신되는 변경:

- `strideMm`
- `sideMm`
- `turnDeg`
- `customPeriodMs`
- `footHeightMm`
- `hipPitchOffsetTrimDeg`

직렬화되는 필드:

```text
enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg
```

코드상 `WalkingEngineCommand` 필드:

- `enabled`
- `xMm`
- `yMm`
- `aDeg`
- `periodMs`
- `footHeightMm`
- `hipPitchOffsetDeg`

판정:

- ROBOTIS Onboard 모드에서는 위 7개 필드만 로봇 측 daemon으로 전달된다.
- 보폭/측면/회전/주기/발 높이/Hip pitch trim은 실시간 반영 경로가 명확하다.
- 반영 타이밍은 즉시 또는 300ms debounce다.

---

## 4. 가장 중요한 발견: 균형 게인과 자세 보정은 Onboard 로봇에 전달되지 않는다

### 4.1 `balanceGain` 문제

UI 위치:

- `AdvancedSlidersPanel`
- 라벨: `균형 게인 (NimbRo lean_fb)`
- 상태값: `session.balanceGain`

Mac sparse keyframe 경로:

- `currentWalkTuning()`에 포함된다.
- `WalkMotionLibrary.AdvancedTuning.balanceGain`으로 전달된다.
- `WalkMotionLibrary` 내부에서 lateral sway 계열 값에 사용된다.

ROBOTIS Onboard 경로:

- `WalkLabOnboardBridge`의 `onChange` 목록에 `balanceGain`이 없다.
- `WalkingEngineCommand` 구조체에 `balanceGain` 필드가 없다.
- `serializedLine`에도 `balanceGain`이 없다.

결론:

- `.macSparseKeyframe`에서는 반영됨
- `.robotisOnboard`에서는 로봇 펌웨어로 전달되지 않음

UX 위험:

- 사용자는 같은 WalkLab 화면에서 같은 슬라이더를 조작한다.
- 화면상 안정성 점수는 바뀔 수 있다.
- 그러나 Onboard 모드에서 실제 로봇 보행은 해당 값을 받지 않는다.
- 사용자는 “설정을 바꿨는데 왜 로봇 움직임이 그대로지?”라고 느낄 수 있다.

권장 표시:

- Onboard 모드에서는 `균형 게인` 옆에 “Onboard 로봇에는 현재 미송신” 배지를 표시
- 또는 Onboard 모드에서 슬라이더를 비활성화
- 또는 실제 펌웨어 명령 포맷에 `balanceGain`을 추가한 뒤 UI를 활성 상태로 유지

---

### 4.2 `enableBalanceCorrection` / `correctorIntensityLevel` 문제

UI 위치:

- `GyroCorrectorControls`
- `FallPreventionMonitor`
- `WalkLabView`의 “자세 보정 (실험)” 토글

Mac sparse keyframe 경로:

- `applyBalanceCorrectionIfEnabled(to:)`에서 사용된다.
- IMU 기반 보정 pose transform을 계산한다.
- `enableBalanceCorrection`이 꺼져 있으면 pose 적용이 차단된다.
- `correctorIntensityLevel`은 Mac 측 corrector 구성/강도에 반영된다.

ROBOTIS Onboard 경로:

- Mac sparse keyframe 송출이 우회된다.
- `WalkingEngineCommand`에는 자세 보정 ON/OFF나 강도 필드가 없다.
- `WalkLabOnboardBridge`도 해당 값 변경을 감지해 송신하지 않는다.

결론:

- `.macSparseKeyframe`에서는 의미 있음
- `.robotisOnboard`에서는 현재 로봇 펌웨어 제어값으로 전달되지 않음

다행인 점:

- `BalanceExperimentControls`에는 Onboard 모드에서 Mac corrector path가 우회된다는 안내/비활성 로직이 들어가 있다.

남은 UX 위험:

- “자세 보정 (실험)” 토글이나 강도 UI가 Onboard 모드에서 여전히 사용자에게 로봇 제어처럼 보이면 혼선이 생길 수 있다.

권장 표시:

- Onboard 모드에서는 “Mac 보정 경로 전용”이라고 명확히 표기
- Onboard 모드에서 로봇 펌웨어 자체 balance 설정을 제어하지 못한다면 비활성화

---

## 5. 항목별 판정

### 5.1 보행 프리셋

판정:

- 실제 반영 경로 있음
- Onboard 모드에서는 즉시 송신 경로 있음
- Mac sparse 모드에서는 보행 cycle 재시작/송출 경로 있음

주의:

- 이미 보행 중이면 preflight와 active 상태에 따라 중복 시작이 차단될 수 있다.

---

### 5.2 보폭/측면/회전/주기/발 높이

판정:

- Mac sparse 모드: 반영됨
- Onboard 모드: 반영됨

실시간성:

- Mac sparse 모드: 보행 중 약 220ms debounce 후 cycle 재시작
- Onboard 모드: 약 300ms debounce 후 마지막 값만 송신

UX 표현:

- “즉시 반영”보다는 “짧은 지연 후 반영”이 정확함
- 빠르게 드래그할 때 중간값은 모두 보내지 않고 마지막 값 중심으로 반영됨

---

### 5.3 Hip pitch trim

판정:

- Mac sparse 모드: 반영됨
- Onboard 모드: 반영됨

검증 근거:

- `WalkingEngineCommand`에 `hipPitchOffsetDeg` 필드가 존재
- `serializedLine` 마지막 필드로 포함
- 관련 회귀 테스트 통과

의미:

- 이전에 빠져 있던 종류의 값이지만 현재 코드는 보강되어 있음

---

### 5.4 균형 게인 `balanceGain`

판정:

- Mac sparse 모드: 반영됨
- Onboard 모드: 미반영

위험도:

- 높음

이유:

- UI에서는 실제 설정처럼 보이지만 Onboard 로봇 명령에는 포함되지 않기 때문

---

### 5.5 자세 보정 ON/OFF와 강도

판정:

- Mac sparse 모드: 반영됨
- Onboard 모드: 로봇 펌웨어로 직접 전달되지 않음

위험도:

- 중간

이유:

- Balance experiment 패널 일부에는 Onboard 안내가 있지만, 사용자가 전체 WalkLab 화면을 볼 때 “자세 보정이 로봇에도 적용된다”고 오해할 수 있음

---

### 5.6 안전 한도 해제 `forceOverrideSafety`

판정:

- 직접 로봇으로 송신되는 설정은 아님
- UI/시작 전 안전 게이트 성격이 강함

의미:

- 사용자가 슬라이더 cap을 무시할 수 있게 하지만, critical 위험 점수에서는 여전히 시작 차단 로직이 남아 있다.

---

### 5.7 Cradle 확인 / 위험 동의

판정:

- 로봇으로 보내지는 “동작 파라미터”가 아니라 보행 시작을 막거나 허용하는 gate

의미:

- 실시간 로봇 동작 변경값이 아니라 “시작 가능 조건”으로 이해해야 한다.
- 이미 보행이 시작된 뒤 값을 바꿔서 로봇 동작이 바뀌는 종류의 설정은 아니다.

---

### 5.8 Auto Onboard Brokering

판정:

- Onboard 모드에서 매우 중요
- 이 값이 꺼져 있으면 자동 실시간 송신이 일어나지 않는다.

사용자에게 필요한 안내:

- “Onboard 자동 명령 송출이 켜져 있어야 슬라이더 변경이 로봇에 자동 반영됩니다.”
- 꺼져 있으면 수동 송출 버튼 또는 시작 차단 흐름을 명확히 보여줘야 한다.

---

## 6. 빌드 분기 검토

WalkLab 주요 송신/보정 경로는 `#if DEBUG`에 의해 릴리즈 빌드에서 빠지는 구조로 보이지 않는다.

확인된 `#if DEBUG`의 주요 용도:

- 테스트 전용 helper
- SwiftUI preview
- 디버그/프리뷰 보조 코드

판정:

- 실제 송신 경로, Onboard command serialization, Mac sparse motor write 경로가 Debug 전용으로만 묶여 있지는 않다.

---

## 7. UI/UX 관점 권장 정리

현재 WalkLab은 기능이 많고 실제 적용 경로가 모드별로 다르다.  
사용자가 기획자/비개발자 관점에서 이해하려면 화면에 다음 구분이 필요하다.

### 7.1 설정마다 “적용 범위” 배지를 붙이는 것을 권장

예시:

- `Mac 실송출`
- `Onboard 로봇 송신`
- `시뮬레이션 전용`
- `시작 전 안전 조건`
- `로그/분석 전용`
- `현재 Onboard 미지원`

### 7.2 Onboard 모드에서는 미송신 항목을 숨기거나 비활성화 권장

특히:

- 균형 게인
- 자세 보정 ON/OFF
- 자세 보정 강도
- Mac corrector 관련 실험 옵션

완전히 숨기기 어렵다면 최소한 다음 문구가 필요하다.

```text
ROBOTIS Onboard 모드에서는 이 값이 현재 로봇 펌웨어 명령으로 송신되지 않습니다.
Mac sparse keyframe 모드에서만 실제 보행에 적용됩니다.
```

### 7.3 “실시간 반영” 문구는 세분화해야 함

권장 문구:

- “즉시 송신”
- “300ms 후 자동 송신”
- “220ms 후 보행 재시작 반영”
- “다음 시작 시 반영”
- “현재 세션에는 영향 없음”
- “로봇 미송신”

---

## 8. 실물 로봇 검증 체크리스트

실제 DARwIn-OP 로봇에서 최종 확인하려면 아래 순서로 테스트하는 것이 좋다.

### 8.1 Onboard 모드 명령 송신 확인

준비:

- `walkingEngine = .robotisOnboard`
- `autoOnboardBrokering = true`
- `remoteShell.host` 설정
- cradle 확인

확인:

- preset 변경 시 ACK가 `ok`로 바뀌는지
- `strideMm` 변경 후 약 300ms 뒤 ACK가 갱신되는지
- `customPeriodMs` 변경 후 로봇 보행 속도가 바뀌는지
- `hipPitchOffsetTrimDeg` 변경 후 직렬화 line 마지막 값이 바뀌는지

예상:

- 위 항목은 반영되어야 정상

### 8.2 Onboard 모드 미지원 항목 확인

확인:

- `balanceGain`을 크게 바꿔도 송신 line이 바뀌지 않는지
- `enableBalanceCorrection`을 바꿔도 송신 line이 바뀌지 않는지
- `correctorIntensityLevel`을 바꿔도 송신 line이 바뀌지 않는지

예상:

- 현재 코드 기준으로는 line이 바뀌지 않는 것이 맞다.
- 만약 사용자가 이것을 “로봇에 적용됨”으로 기대한다면 UX/기능 갭이다.

### 8.3 Mac sparse 모드 확인

준비:

- `walkingEngine = .macSparseKeyframe`
- 실제 bus 연결
- cradle 확인

확인:

- 보행 중 `strideMm`, `periodMs`, `footHeightMm` 변경 시 약 220ms 뒤 보행 cycle이 새 설정으로 재시작되는지
- `balanceGain` 변경 시 lateral sway 성격이 달라지는지
- `enableBalanceCorrection`과 강도 변경 시 IMU 기반 correction이 pose에 적용되는지

---

## 9. 최종 판정

### 명확히 적용된다고 볼 수 있는 영역

- Mac sparse 모드의 고급 보행 슬라이더
- Mac sparse 모드의 자세 보정/강도
- Onboard 모드의 보폭/측면/회전/주기/발 높이/Hip pitch trim
- Onboard 모드의 preset 변경
- Onboard 모드의 자동 brokering이 켜진 상태에서의 300ms debounce 송신

### “실시간”이라고 말할 때 주의가 필요한 영역

- Mac sparse 모드의 보행 중 슬라이더 변경은 즉시 주입이 아니라 약 220ms 후 재시작 반영
- Onboard 모드의 슬라이더 변경은 약 300ms debounce 후 마지막 값만 송신
- 자동 brokering이 꺼져 있으면 Onboard 자동 반영이 아님

### 현재 사용자 오해 가능성이 큰 영역

- `balanceGain`
- `enableBalanceCorrection`
- `correctorIntensityLevel`
- Mac corrector/Balance experiment 계열 옵션

이 항목들은 Onboard 로봇 펌웨어로 직접 전달되지 않거나 모드별 의미가 달라, UI에서 명확히 구분해야 한다.

---

## 10. 권장 다음 액션

구현은 아직 하지 않는 전제로, 다음 기획 결정을 먼저 권장한다.

1. WalkLab 설정 항목을 “실제 로봇 송신”, “Mac 보정 전용”, “시뮬레이션 전용”, “안전 게이트”로 분류한다.
2. Onboard 모드에서 미송신 항목을 비활성화할지, 아니면 펌웨어 명령 포맷을 확장할지 결정한다.
3. “실시간 반영”이라는 표현을 하나로 쓰지 말고, 항목별 반영 타이밍을 표시한다.
4. 실물 로봇 테스트에서는 먼저 Onboard 송신 line과 ACK를 확인하고, 그다음 모터 움직임 변화를 본다.
5. 사용자에게는 “이 설정이 지금 로봇에 적용되는지”를 화면에서 바로 알 수 있게 배지/도움말을 제공한다.

