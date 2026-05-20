# WalkLab 실제 로봇 보행 실패 원인 점검

작성일: 2026-05-20  
대상 빌드/로그: DarwinForge v1.11.23, `~/Library/Application Support/DarwinForge/sessions` 최신 세션  
검토 범위: WalkLab preset, profile/tuning, Mac sparse 송출, ROBOTIS onboard bridge, 세션 로그

## 결론

현재 증상은 단일 원인이 아니라 4개 문제가 겹친 것으로 보인다.

1. **보행 중 다른 preset을 누르면 UI/로그의 preset만 바뀌고 실제 로봇 보행 task는 바뀌지 않는다.**
   - 코드상 `current`와 시뮬레이션 명령을 먼저 바꾼 뒤, 실제 모터 task 진입에서 `walkCycleTask != nil`이면 새 보행을 막는다.
   - 최신 로그에서 `slowWalk` 세션 안에 `normalWalk`, `fastWalk` sample이 섞여 있다. 즉 사용자는 fastWalk를 누른 것이 맞지만 실제 시작 세션은 slowWalk였다.
   - 이게 “로봇 애니메이션은 움직이는데 실제 로봇은 특정 걸음으로 안 바뀜”의 가장 강한 재현 근거다.

2. **`fastWalk`, `turnLeft`, `turnRight`는 `자세 보정(enableBalanceCorrection)`이 꺼져 있으면 실제 송출이 차단된다.**
   - 이 3개 preset은 `.caution`이다.
   - 최신 로그 대부분은 `enableBalanceCorrectionAtStart=false`다.
   - 차단은 실제 motor path에서 발생하지만, `start()`가 이미 `current`와 타이머를 바꾼 뒤라 UI는 움직인 것처럼 보일 수 있다.

3. **고급 모드가 켜져 있으면 preset 기본값이 아니라 슬라이더 값이 실제 명령이 된다.**
   - `turnLeft` preset 기본값은 `turnDeg=25`지만, 고급 모드에서는 슬라이더 `turnDeg`가 0이면 실제 회전도 0이다.
   - `fastWalk`도 고급 모드에서 `strideMm=0`, `customPeriodMs=600`이면 이름만 fastWalk이고 실제로는 전진/빠른 보행이 아니다.
   - 따라서 “같은 프로파일인데 제자리 걸음은 되고 빠른 걸음은 안 됨”은 preset 프로파일 문제가 아니라, 고급 슬라이더가 preset을 덮어쓰는 UX/상태 문제일 가능성이 높다.

4. **ROBOTIS onboard 모드는 아직 ‘선택만 하면 움직이는 모드’가 아니다.**
   - Mac이 직접 모터를 쓰는 경로를 우회하고, SSH로 `/tmp/df-walklab-cmd`를 쓰며, 로봇 쪽 patched `demo-pilot`/`WalkLabBrokerage`가 이를 읽어야 한다.
   - `autoOnboardBrokering=false`, RemoteShell host 미설정, robot-side patch 미설치, 구버전 patch protocol이면 UI는 active처럼 보여도 실제 로봇은 안 움직인다.

냉정하게 말하면, 현재 WalkLab은 “ball tracking 데모처럼 믿고 걷는 앱”이 아니라 아직 **preset 상태 관리와 실제 송출 상태가 분리되어 보이는 진단/실험 도구**에 가깝다. 실제 보행 성공률을 보려면 먼저 위 상태 불일치를 고쳐야 한다.

## 확인한 코드 근거

### 1. `start()`가 실제 송출 성공 전에 UI 상태부터 바꾼다

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift`

- `start(_:)`에서 `current = preset` 수행
- 이어서 `engine.setCommand(...)`, `simTimer` 시작
- 그 다음에야 `startWalkCycle(preset)` 호출

문제 흐름:

```text
사용자 fastWalk 클릭
→ current = fastWalk
→ 시뮬레이션/표시 상태 fastWalk로 변경
→ startWalkCycle(fastWalk)
→ 이미 walkCycleTask가 있으면 "보행 진행 중"으로 return
→ 실제 로봇은 기존 task 유지 또는 새 명령 없음
```

`startWalkCycle(_:)` 안에는 다음 가드가 있다.

```swift
if walkCycleTask != nil || onboardWalkingActive {
    lastRobotEvent = "⚠️ 보행 진행 중 — 정지(■) 후 다시 시도하세요 (...)"
    return
}
```

이 가드는 안전 측면에서는 맞지만, **이미 바뀐 `current`를 되돌리지 않아서** UI와 실제 로봇이 갈라진다.

### 2. 세션 로거도 실제 active preset이 아니라 `current`를 기록한다

파일: `WalkLabSession.swift`

`appendSessionSampleIfLogging()`은 sample preset을 `current.rawValue`로 저장한다.

```swift
preset: current.rawValue
```

그래서 실제로는 slowWalk task가 돌고 있어도 사용자가 fastWalk 버튼을 누르면 이후 sample에는 `fastWalk`가 찍힌다. 이 데이터는 “실제 로봇이 fastWalk를 수행했다”는 증거가 아니다.

### 3. caution preset은 자세 보정 OFF면 실제 송출 차단

파일: `WalkPresetCatalog.swift`

```swift
case .fastWalk, .turnLeft, .turnRight:
    return .caution
```

파일: `WalkLabSession.swift`

```swift
if preset.safety == .caution, !enableBalanceCorrection {
    lastPreflightFailure = ...
    lastRobotEvent = "'...' 시작 차단 — '자세 보정' 토글을 먼저 켜주세요"
    return
}
```

중요한 UX 함정:

- `autoFallPrevention` 토글 이름은 UI에서 “자동 균형 보정”
- `enableBalanceCorrection` 토글 이름은 UI에서 “자세 보정 (실험)”
- 실제 caution gate가 보는 것은 `enableBalanceCorrection`이다.

사용자가 “자동 균형 보정”을 켰다고 생각해도, `enableBalanceCorrection`이 꺼져 있으면 fast/turn은 차단된다.

### 4. 고급 모드가 preset을 덮어쓴다

파일: `WalkLabSession.swift`

```swift
public var effectiveCommand: (...) {
    if advanced {
        return (customX, customY, customA, current != .idle)
    }
    return current.command
}
```

```swift
return WalkMotionLibrary.AdvancedTuning(
    strideMm: advanced ? strideMm : WalkMotionLibrary.defaultTuning(for: current).strideMm,
    turnDeg: advanced ? turnDeg : WalkMotionLibrary.defaultTuning(for: current).turnDeg,
    periodMs: advanced ? customPeriodMs : WalkMotionLibrary.defaultTuning(for: current).periodMs,
    ...
)
```

즉 고급 모드 ON에서는 다음이 가능하다.

| 화면에서 누른 preset | 실제 슬라이더 상태 | 실제 동작 |
|---|---:|---|
| `turnLeft` | `turnDeg = 0` | 좌회전 안 함 |
| `turnRight` | `turnDeg = 0` | 우회전 안 함 |
| `fastWalk` | `strideMm = 0`, `periodMs = 600` | 빠른 전진 아님 |
| `march` | `strideMm = 0`, `turnDeg = 0` | 제자리 걸음처럼 보임 |

이건 코드 오류라기보다 UX 설계 오류에 가깝다. preset 버튼을 누르면 슬라이더를 preset 기본값으로 동기화하거나, 고급 모드에서는 버튼명을 “preset”이 아니라 “현재 슬라이더로 시작”으로 바꿔야 한다.

### 5. ROBOTIS onboard는 실제 robot-side patch 의존

파일: `WalkingEngine.swift`

- `macSparseKeyframe`: Mac이 sparse keyframe을 만들고 `setPosition`을 순차 송출
- `robotisOnboard`: robot-side `Walking::GetInstance()` 사용, patch 필요

파일: `WalkLabSession.swift`

```swift
if walkingEngine == .robotisOnboard {
    onboardWalkingActive = true
    lastRobotEvent = "ROBOTIS Onboard 모드..."
    return
}
```

이 분기에서는 Mac sparse 모터 송출을 하지 않는다. 실제 로봇이 움직이려면 아래 조건이 모두 필요하다.

- RemoteShell host 설정
- `ROBOTIS 측 시작`으로 patched `demo-pilot` 실행
- `/tmp/df-pilot-mode = walklab`
- `/tmp/df-walklab-cmd` write 가능
- `WalkLabBrokerage`가 파일을 polling
- 현재 Mac 명령 포맷 `{cmd_id} enabled x y a period foot hip`을 robot-side parser가 이해
- ACK `/tmp/df-walklab-ack` 반환

이 중 하나라도 빠지면 UI는 active처럼 보여도 로봇은 안 움직인다.

## 실측 로그 근거

분석한 최신 파일:

```text
~/Library/Application Support/DarwinForge/sessions/2026-05-20T*.jsonl
~/Library/Application Support/DarwinForge/sessions/2026-05-20T*.summary.json
```

### 최신 세션 공통 상태

최신 세션 헤더에서 확인한 공통 경향:

- `walkingEngine`: `macSparseKeyframe`
- `autoOnboardBrokeringAtStart`: `false`
- `enableBalanceCorrectionAtStart`: 대부분 `false`
- `isRealRobot`: `true`
- `busWriteFailureDelta`: `0`

`busWriteFailureDelta=0`은 통신 실패가 없었다는 뜻이지, fast/turn 명령이 실제로 시작됐다는 뜻은 아니다. preflight에서 차단되거나 active task 때문에 막히면 송출 루프 자체가 시작되지 않으므로 write failure도 0일 수 있다.

### 결정적 로그: 한 세션 안에 preset이 섞임

최신 로그의 preset 변화:

| 파일 | header/파일명 | sample 내부 변화 |
|---|---|---|
| `2026-05-20T11-49-01.942Z-march.jsonl` | march | 10.7s 지점 `march → slowWalk` |
| `2026-05-20T11-49-56.760Z-slowWalk.jsonl` | slowWalk | 3.6s `slowWalk → normalWalk`, 10.0s `normalWalk → fastWalk` |
| `2026-05-20T11-50-56.166Z-march.jsonl` | march | 3.1s `march → normalWalk`, 8.7s `normalWalk → fastWalk` |
| `2026-05-20T11-51-44.794Z-normalWalk.jsonl` | normalWalk | 17.0s `normalWalk → march` |
| `2026-05-20T11-52-12.045Z-slowWalk.jsonl` | slowWalk | 17.7s `slowWalk → normalWalk`, 21.3s `normalWalk → fastWalk` |

이건 “사용자가 여러 버튼을 눌렀고 UI 상태는 바뀌었지만, 로거의 session 기준과 실제 motor task 기준이 분리됐다”는 강한 증거다.

### 좌/우회전 데이터 부재

현재 보존된 세션 파일에는 `turnLeft`, `turnRight`로 시작한 최신 세션이 없다. 가능한 해석:

1. 사용자가 눌렀지만 `startWalkCycle` 진입 전에 막혀 logger가 만들어지지 않았다.
2. 보행 중 눌러서 `current`만 바뀌었지만 실제 task가 시작되지 않았다.
3. 고급 모드에서 `turnDeg=0`이라 실제 회전 명령이 없었다.
4. onboard 모드에서 명령 brokering이 성립하지 않았다.

따라서 현재 데이터만으로는 “좌/우회전 모션이 잘못된 관절값이라서 실패했다”고 말할 수 없다. 더 앞 단계에서 명령이 실제로 시작됐는지부터 불명확하다.

## 경우의 수별 판정

| 조건 | 실제 로봇 예상 | 현재 문제 |
|---|---|---|
| Mac sparse + safe preset + 보행 중 아님 + IMU/torque OK | 움직여야 함 | 최신 march/slow/normal은 이 경로로 보임 |
| Mac sparse + `fastWalk/turn*` + `enableBalanceCorrection=false` | 실제 송출 차단 | UI는 먼저 바뀌므로 헷갈림 |
| Mac sparse + 보행 중 다른 preset 클릭 | 새 preset 실제 시작 안 됨 | `current`만 바뀌고 active task 가드에 막힘 |
| Advanced ON + turn preset + `turnDeg=0` | 회전 안 함 | preset 이름과 실제 명령 불일치 |
| Advanced ON + fast preset + `strideMm=0` | 전진 안 함 | preset 이름과 실제 명령 불일치 |
| Advanced ON + stability critical | 시작 차단 | 현재 `tap()`에서 조용히 return 가능 |
| ROBOTIS onboard + auto brokering OFF | 자동 명령 없음 | 수동 `현재 명령 송출` 필요 |
| ROBOTIS onboard + RemoteShell host 없음 | 자동 명령 없음 | bridge `shouldSend()`에서 차단 |
| ROBOTIS onboard + robot patch 없음 | 명령 무시/NO_ACK | ball tracker 기본 SOCCER 모드만 동작 가능 |
| ROBOTIS onboard + 구버전 patch | cmd_id 포함 명령 파싱 실패 가능 | 현재 Mac은 cmd_id prefix를 붙임 |
| IMU unavailable/stale/plausibility fail | 실제 송출 차단 | `lastRobotEvent` 확인 필요 |

## Ball tracking 데모는 되는데 WalkLab은 안 되는 이유

Ball tracking은 robot 내부의 ROBOTIS `Walking::GetInstance()`를 사용한다.

- 8ms 루프, 약 125Hz
- robot-side IK
- walking module 내부 balance/gyro 루프
- `X_MOVE_AMPLITUDE`, `A_MOVE_AMPLITUDE`를 점진적으로 갱신

WalkLab 기본값인 Mac sparse는 다르다.

- 6 phase sparse keyframe
- Mac에서 각 관절 `setPosition` 순차 송출
- sync write 아님
- robot-side walking loop가 아니라 외부 pose 찍기
- 빠른 보행/회전에서 안정성이 낮다

따라서 “ball tracker는 잘 걷는데 WalkLab은 뒤뚱거림”은 정상적인 의심이다. WalkLab이 안정 보행을 하려면 결국 ROBOTIS onboard 경로가 맞지만, 그 경로는 현재 robot-side patch와 명령 ACK까지 검증되어야 한다.

## 우선 수정해야 할 항목

### P0-1. 보행 중 preset 클릭 시 UI 상태를 먼저 바꾸지 않기

현재는 `start()`가 먼저 `current`를 바꾸고 나중에 실제 시작 실패를 안다. 구조를 바꿔야 한다.

권장 방향:

- `startWalkCycle(_:)`가 `StartEligibility` 또는 `Bool`을 반환
- 실제 송출 가능 여부를 먼저 판단
- 실패하면 `current`, `engine`, `simTimer`, logger를 바꾸지 않음
- 또는 `start()` 초입에서 `walkCycleTask != nil || onboardWalkingActive`이면 즉시 return하고 UI 메시지만 표시

필수 회귀 테스트:

- march 실행 중 fastWalk 클릭
- `current`가 fastWalk로 바뀌지 않아야 함
- logger sample preset도 march로 유지되어야 함
- `lastRobotEvent`가 사용자에게 표시되어야 함

### P0-2. preset 버튼을 보행 중 비활성화하거나 “정지 후 변경” 플로우로 바꾸기

현재 `PresetButton`은 `cradleConfirmed`만 보면 활성화된다.

권장 UX:

- 보행 중에는 non-idle preset 버튼 disable
- 또는 클릭 시 “현재 보행을 정지하고 fastWalk로 다시 시작할까요?” confirmation
- 자동 전환을 하려면 stop ACK 또는 walkReady 복귀 완료 후 새 preset 시작

### P0-3. caution 차단을 UI에서 버튼 상태로 미리 보여주기

`fastWalk`, `turnLeft`, `turnRight`가 `enableBalanceCorrection=false`에서 막힌다면 버튼 자체에 표시해야 한다.

권장 UX:

- 버튼 disabled + 이유: “자세 보정 OFF라 실제 로봇 송출 차단”
- “자세 보정 켜기” inline action
- `autoFallPrevention`과 `enableBalanceCorrection` 이름 분리
  - `autoFallPrevention`: “기울기 감지 시 자동 정지”
  - `enableBalanceCorrection`: “IMU 자세 보정값을 관절에 적용”

### P0-4. 고급 모드와 preset의 관계를 명확히 하기

현재 고급 모드 ON이면 preset 기본값이 무시된다. 이건 사용자가 알기 어렵다.

권장 중 하나:

1. preset 클릭 시 슬라이더를 해당 preset 기본값으로 로드
2. 고급 모드 ON에서는 preset 버튼을 “프리셋 불러오기”와 “현재 슬라이더로 시작”으로 분리
3. active command preview를 항상 크게 표시

예시 표시:

```text
실제 송출값: stride 0mm, turn 0°, period 600ms
선택 preset: turnLeft
주의: 고급 모드가 preset 기본 회전값 25°를 덮어쓰고 있습니다.
```

### P1-1. 실제 active preset과 UI selected preset을 분리

추천 상태 모델:

- `selectedPreset`: 사용자가 마지막으로 클릭/선택한 것
- `activeRobotPreset`: 실제 motor task가 시작된 preset
- `previewPreset`: 3D 미리보기 preset

로거는 `activeRobotPreset`을 기록해야 한다. 현재처럼 `current` 하나로 UI/preview/robot/logging을 모두 표현하면 같은 문제가 반복된다.

### P1-2. 세션 로그 schema 보강

추가 필드 권장:

- `activePresetAtStart`
- `requestedPreset`
- `actualMotionPreset`
- `startBlockedReason`
- `walkCycleTaskActive`
- `onboardAckStatus`
- `lastRobotEvent`
- `motorWriteStarted: Bool`
- `motorWriteStepCount`

지금은 fast/turn을 눌렀는지, 실제 송출이 시작됐는지, preflight에서 막혔는지 로그만으로 분리하기 어렵다.

### P1-3. Onboard 설치/ACK를 시작 전 필수 검증

`robotisOnboard`에서 “시작됨”처럼 보이기 전에 다음을 통과해야 한다.

- RemoteShell host 있음
- `demo-pilot` patched 여부 확인
- `/tmp/df-pilot-mode`가 `walklab`
- `/tmp/df-walklab-cmd` write 가능
- `/tmp/df-walklab-ack`에 현재 `cmd_id`가 echo됨

이게 실패하면 `onboardWalkingActive=true`로 두지 않는 편이 맞다.

### P1-4. protocol 문서와 코드 통일

현재 Mac 송신은 cmd_id 포함 포맷을 쓴다.

```text
{cmd_id} enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg
```

하지만 README 일부는 아직 7필드 예시 중심이다. robot에 구버전 patch가 설치되어 있으면 cmd_id가 붙은 명령을 무시할 수 있다. 문서/설치 스크립트/robot-side parser 버전 검증이 필요하다.

## 지금 사용자가 실험할 때 확인할 순서

실기기에서 바로 fast/turn을 반복하지 말고, 아래 순서로 원인만 분리하는 것이 안전하다.

1. 정지 상태에서 `정지`를 먼저 누른다.
2. 고급 모드 OFF.
3. `자세 보정 (실험)` OFF 상태로 `march`, `slowWalk`, `normalWalk` 각각 단독 실행.
4. 각 실행 중 다른 preset을 누르지 않는다.
5. `fastWalk/turnLeft/turnRight`는 버튼을 누르기 전에 `자세 보정 (실험)` ON 여부를 확인한다.
6. `fastWalk/turn*`가 차단되면 `lastRobotEvent` 문구를 기록한다.
7. ROBOTIS onboard를 쓰려면 먼저 `ROBOTIS 측 시작` 후 ACK/health가 정상인지 확인한다.
8. onboard에서 `현재 명령 송출` 결과가 `OK ... cmd_id ...`인지 확인한다.

## 다음 Claude 작업 지시 요약

Claude에게 바로 구현시킬 경우 우선순위는 다음이다.

1. `WalkLabSession.start(_:)`에서 실제 시작 가능 여부를 `current` 변경 전에 검사한다.
2. 보행 중 non-idle preset 클릭은 `current`를 바꾸지 않고 사용자 메시지만 표시한다.
3. logger sample의 `preset`은 `current`가 아니라 실제 active preset을 기록한다.
4. `selectedPreset`, `activeRobotPreset`, `previewPreset` 상태를 분리한다.
5. `fastWalk/turn* + enableBalanceCorrection=false`는 버튼 단계에서 disabled와 이유를 표시한다.
6. 고급 모드 ON에서 preset 클릭 시 슬라이더를 preset 기본값으로 로드할지, 아니면 preset이 무시된다는 banner를 표시할지 결정해서 구현한다.
7. ROBOTIS onboard 시작은 ACK 검증 전에는 `onboardWalkingActive=true`로 만들지 않는다.
8. 실험 로그에 `startBlockedReason`, `motorWriteStarted`, `activePresetAtStart`, `requestedPreset`을 추가한다.

## 최종 판단

현재 “좌회전/우회전이 전혀 안 됨”, “특정 걸음은 되고 특정 걸음은 안 됨”은 관절 각도 자체의 문제가 아니라, 우선 **상태 관리와 송출 가드가 UI보다 늦게 동작하는 문제**가 가장 크다.

특히 최신 로그의 mixed preset 기록은 실제 오류다. 이 상태에서는 사용자가 보는 preset, 기록되는 preset, 실제 로봇이 수행 중인 preset이 서로 다를 수 있다. 이 문제를 해결하기 전에는 fastWalk/turnLeft/turnRight의 보행 품질을 평가해도 데이터 신뢰도가 낮다.

