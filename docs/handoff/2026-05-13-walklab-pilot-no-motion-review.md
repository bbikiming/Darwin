# WalkLab / Remote Pilot 실기체 무동작 이슈 검수 및 Claude 변경 지시서

작성일: 2026-05-13  
작성자: Codex  
대상: Claude 구현 담당자  
범위: WalkLab, Remote Pilot, motion_4096 실기체 송출 경로

## 결론

현재 "워크랩과 원격 조종 메뉴에서 지시를 해도 실제 로봇이 동작하지 않는다"는 제보는 충분히 코드상으로 설명된다. 단순한 UI 버그라기보다, 실제 송출 경로가 기능별로 서로 다르고 일부는 아직 의도적으로 비활성인 상태다.

핵심 원인은 3개다.

1. WalkLab 보행 cycle은 `ConnectionStore.applyPoseSmoothly` 안전/진단 경로를 쓰지 않고 `Bus.setPosition`을 직접 호출하며, power/torque ON 보장 없이 실패를 전부 `try?`로 삼킨다.
2. Remote Pilot Action Bar는 공식 `motion_4096.bin` page chain을 재생하지 않는다. 현재는 대부분 `MotionCatalog.v1TargetPoseID`에 매핑된 단일 `RobotPose`만 보낸다.
3. Remote Pilot D-pad 방향 조작은 현재 feature flag상 실 모터 송출이 꺼져 있다. 버튼은 눌리지만 방향 명령은 `flags.dpadRealMotor == false`에서 조용히 return된다.

따라서 사용자의 "안 움직인다"는 감각은 타당하다. 특히 D-pad, left kick, get-up, raw action page 계열은 현재 구현상 실기체 동작을 기대하면 안 된다.

## 검수 기준

- 하드웨어 실측은 하지 않았고, 현 코드와 기존 PRD/보고서 기준의 정적 검수다.
- 라인 번호는 2026-05-13 현재 worktree 기준이다.
- 본 문서는 증상 재현보다 "왜 그럴 가능성이 높은지"와 "무엇을 고쳐야 하는지"에 집중한다.

## 근거 요약

### WalkLab

활성 화면은 `RootView.detail`에서 `.walk` 선택 시 `WalkLabView()`다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:770-773`

WalkLab UI는 프리셋 보행을 실 송출이라고 안내한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift:205-216`

하지만 실제 보행 loop는 `ConnectionStore.applyPoseSmoothly`가 아니라 `Bus`를 직접 잡고 `setMovingSpeed`, `setPosition`을 호출한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:245-277`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:300-340`

문제는 이 경로에 power/torque ON, write 실패 집계, SafeMotion 검증, critical load watchdog, 사용자-visible 실패 메시지가 없다.

특히 아래 구간은 치명적이다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:303-305`
  - 모든 speed write가 `_ = try?`로 무시된다.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:320-323`
  - 모든 position write가 `_ = try?`로 무시된다.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:333-339`
  - 종료 walkReady 복귀도 실패를 무시한다.

반면 `ConnectionStore.applyPoseSmoothly`는 안전 검증과 실패 집계를 가지고 있다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift:376-387`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift:405-413`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift:438-456`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift:477-512`

WalkLab E-stop은 토크를 OFF한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:203-220`

그런데 WalkLab 프리셋 시작은 이후 다시 `setDxlPower(true)`나 `setTorque(..., true)`를 보장하지 않는다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:141-169`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:245-258`

즉 사용자가 한 번이라도 E-stop, 복구 실패, disarm, torque off 상태를 거쳤다면 WalkLab은 "송출 시작/종료"처럼 보이지만 로봇은 물리적으로 움직이지 않을 수 있다.

### Remote Pilot Action Bar

활성 화면은 `RootView.detail`에서 `.pilot` 선택 시 `RemotePilotView()`다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift:776-777`

Remote Pilot은 기본 feature level이 v1.5다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/RemotePilotView.swift:24-32`

그러나 코드 주석 자체가 현재 raw `motion_4096.bin` step SYNC_WRITE 재생 경로가 별도 PR이라고 명시한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:13-17`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/MotionCatalog.swift:10-15`

실제 `sendMotion`은 `MotionCatalog.v1TargetPoseID`를 찾아 `PoseLibrary`의 단일 target pose를 `applyPoseSmoothly`로 보낸다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:285-318`

즉 "Thank You", "Yes Go", "Sit Down" 등의 버튼은 공식 page chain을 재생하지 않는다. 최종 자세 또는 단일 대체 자세만 보낸다. 사용자는 "모션을 실행했다"고 기대하지만 실제 구현은 "대표 포즈 하나로 이동"에 가깝다.

이 점은 기존 Reality Check 문서와도 일치한다.

- `docs/prd/teleop-v1-reality-check.md:17-29`
  - `forge motion play`는 CLI에만 있고 Swift/FFI 경로에는 `fc_motion_play`가 없다고 기록되어 있다.
- `docs/prd/teleop-v1.0-impl-prompt.md:26-63`
  - 원래 요구는 `forge-core::motion::player` 추출, FFI `fc_motion_play_slot` 노출, SYNC_WRITE 기반 page step 재생이다.

현재 구현은 이 요구를 아직 충족하지 못한다.

### Remote Pilot D-pad

D-pad 자체도 UI에 "v1.0: sim 미리보기"라고 쓰여 있다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotDpad.swift:92-101`

방향 입력 처리에서 실제로도 실 송출은 feature flag가 켜져야만 진행된다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotDpad.swift:203-217`

현재 v1.5 feature flag는 `dpadRealMotor`가 false다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotFeatureFlags.swift:97-113`

따라서 W/A/S/D/Q/E/방향 버튼은 현재 실기체를 움직이지 않는 것이 정상 구현이다. 다만 UX 관점에서는 "원격 조종" 화면의 핵심 조작처럼 보이기 때문에 사용자가 고장으로 느끼는 것도 정상이다.

### Action Bar 버튼 활성 상태

Action Bar 버튼 활성 조건이 사실상 항상 true다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotActionBar.swift:63-67`

```swift
let isEnabled = isV1Sendable && (gate.armed || !gate.armed)
```

`gate.armed || !gate.armed`는 언제나 true다. 따라서 실 로봇 연결 상태에서 ARM이 안 된 경우에도 버튼은 활성처럼 보이고, 클릭 후 `TeleopChannel.sendMotion` 내부에서야 "먼저 ARM..."으로 거부된다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:267-278`

이 구조는 사용자가 "눌렀는데 안 움직인다"고 느끼게 만든다. 버튼 레벨에서 비활성/잠금 상태가 명확해야 한다.

## 상세 이슈

### P0. WalkLab 보행 송출은 torque/power 보장 없이 직접 Bus write를 수행한다

WalkLab start 경로는 `cradleConfirmed`와 preset 위험 확인만 본다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:141-169`

실기체 송출 직전 다음을 하지 않는다.

- `bus.setDxlPower(true)`
- `bus.setTorque(j, enable: true)`
- torque on count 확인
- E-stop 이후 recovery/ARM 요구
- `ConnectionStore.applyPoseSmoothly`나 공통 motion executor를 통한 실패 결과 확인

따라서 현재 상태가 torque OFF면 goal position write가 성공처럼 보여도 로봇은 움직이지 않는다. 특히 WalkLab E-stop은 명시적으로 `store?.emergencyStop()`을 호출해 토크를 끈다.

변경 지시:

1. WalkLab에서 자체 `Task.detached + Bus` 직접 제어를 제거하거나 최소한 공통 executor로 감싸라.
2. 프리셋 시작 전 반드시 "실기체 ARM 상태"를 확인하라. 최소 조건:
   - bus 존재
   - CM dxl_power ON 성공
   - 하체 12개 torque ON 성공
   - walkReady anchor 적용 성공 또는 degraded 상태 명시
3. 조건 미충족 시 보행 cycle을 시작하지 말고 UI에 실패 이유를 표시하라.
4. E-stop 이후에는 WalkLab 프리셋 버튼을 바로 실행하지 말고 "로봇 복구" 또는 WalkLab 전용 ARM을 요구하라.

### P0. WalkLab 보행 루프가 모든 write 실패를 삼킨다

`runWalkCycle`의 모든 bus write가 `_ = try?`다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:303-305`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:320-323`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift:336-339`

이러면 USB/네트워크 단절, torque off, 일부 ID 미응답, 권한 문제, 포트 오류가 전부 UI에서 "정상 종료"처럼 보일 수 있다.

변경 지시:

1. `runWalkCycle`이 `WalkCycleResult`를 반환하게 하라.
2. speed/position 실패 수, 하체 실패 관절, 마지막 오류 메시지를 집계하라.
3. 하체 position write 실패 1개 이상이면 즉시 cycle을 중단하고 `lastRobotEvent`와 `ConnectionStore.lastSafetyEvent`에 표시하라.
4. 모든 `_ = try?`를 금지하라. 실패를 무시해야 하는 경우도 카운터와 sample error를 남겨라.
5. 테스트에서 "bus write 실패 시 성공 이벤트가 뜨지 않는다"를 검증하라.

### P0. Remote Pilot은 아직 공식 motion_4096 page chain 재생이 아니다

PRD의 핵심 원칙은 공식 데모 모션 7개 page를 실 모터에 정확히 송출하는 것이었다.

- `docs/prd/teleop-v1.0-impl-prompt.md:1-6`
- `docs/prd/teleop-v1.0-impl-prompt.md:26-63`

하지만 현재 Swift 경로는 raw page step이 아니라 단일 pose target이다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:13-17`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:285-318`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/MotionCatalog.swift:10-15`

변경 지시:

1. 선택지가 둘 중 하나여야 한다.
   - A안: 실제 공식 모션 재생을 구현한다.
   - B안: 현재 기능명을 "단일 포즈 프리뷰"로 낮추고 공식 모션 실행처럼 보이는 문구/tooltip/progress를 제거한다.
2. A안을 택하면 `app/core/forge-cli/src/motion_play.rs` 로직을 `forge-core` 라이브러리로 추출하고 FFI를 노출하라.
   - `fc_motion_play_slot`
   - `fc_motion_play_cancel`
   - `fc_motion_play_is_running`
3. Swift `TeleopChannel.sendMotion`은 `v1TargetPoseID` fallback이 아니라 `store.playMotionSlot(slot, confirmRisk:)` 같은 명시적 raw page 재생 경로를 호출해야 한다.
4. page step 재생은 `motion_4096.bin` byte-identical 원본을 사용하고, INVALID/TORQUE_OFF mask, pause/play timing, SYNC_WRITE를 보존해야 한다.
5. raw page 재생이 준비되지 않은 슬롯은 버튼을 비활성화하고 "준비 중"으로 보여라.

### P1. D-pad 방향 조작은 현재 실기체 송출이 꺼져 있다

현재 v1.5에서 `dpadRealMotor`는 false다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotFeatureFlags.swift:103-107`

그리고 입력 처리도 false일 때 조용히 return한다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotDpad.swift:214-217`

변경 지시:

1. D-pad를 실기체 조종으로 제공할 계획이면 `dpadRealMotor`를 켜는 것만으로 끝내지 말고, 실제 walking IK 또는 검증된 step primitive를 구현하라.
2. 구현 전까지는 D-pad 방향 버튼을 시각적으로 disabled 처리하거나 "시뮬 전용" 상태를 더 명확히 표시하라.
3. 버튼 클릭 시 아무 반응 없이 return하지 말고, toast/diagnostics에 "현재 D-pad 실송출 비활성"을 기록하라.
4. Space/정지 버튼만 실송출이라면 Stop과 방향 버튼의 시각 상태를 분리하라.

### P1. Action Bar가 ARM 전에도 활성처럼 보인다

현재 버튼 enabled 계산은 논리적으로 무의미하다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotActionBar.swift:63-67`

변경 지시:

1. 실기체 연결 상태에서는 `gate.armed == true`일 때만 Action Bar 실행 버튼을 enabled로 하라.
2. bus가 nil인 sim mode에서는 "시뮬 미리보기" 버튼으로 별도 스타일을 적용하라.
3. high-risk confirm sheet도 ARM 전에 먼저 뜨지 않게 하라. 순서는 ARM 요구가 먼저다.
4. tooltip의 `source: motion_4096.bin page N` 문구는 raw page 재생이 아닐 경우 제거하거나 "대표 포즈: PoseLibrary.xxx"로 바꿔라.

### P1. 일부 Remote Pilot 슬롯은 애초에 송출 대상이 없다

`MotionCatalog`에서 left kick, get-up front/back 등은 `v1TargetPoseID: nil`이다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/MotionCatalog.swift:97-103`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/MotionCatalog.swift:138-151`

이 버튼은 `TeleopChannel.sendMotion`에서 "후속 Sprint" 오류로 끝난다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:285-289`

변경 지시:

1. raw page chain 재생이 없다면 해당 슬롯은 disabled 또는 준비 중이어야 한다.
2. left kick을 단일 pose로 임시 지원하려면 `kick_forward_right`를 단순 부호 반전하지 말고 공식 page 13 또는 검증된 좌우 mirror 규칙으로 새 pose를 만들어야 한다.
3. get-up 계열은 단일 pose로 활성화하지 마라. 낙상 자세에서 직립까지의 multi-step chain이 필수다.

### P2. Teleop ARM degraded 상태가 defer 때문에 idle로 돌아갈 수 있다

`TeleopChannel.arm()`의 defer는 `.ready`가 아니면 `.idle`로 되돌린다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:109-112`

그런데 성공 케이스 중 `.readyDegraded`가 있다.

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift:203-220`

현재 defer 조건이면 `.readyDegraded`도 함수 종료 시 `.idle`로 바뀔 수 있다. 실제 gate는 armed인데 UI 단계는 idle처럼 보이는 불일치가 생긴다.

변경 지시:

```swift
defer {
    if armStage != .ready && armStage != .readyDegraded && armStage != .simReady {
        armStage = .idle
    }
}
```

또는 명시적 `isTerminalReadyStage` 헬퍼로 처리하라.

## 구현 우선순위

### 1단계: UX와 실제 기능의 거짓 양성 제거

먼저 "눌렀는데 안 움직이는" 경험을 줄여야 한다. 실제 구현보다 먼저 할 수 있다.

- D-pad 방향 버튼: 실송출 OFF면 disabled 또는 sim-only badge + toast.
- Action Bar: real mode에서 ARM 전 버튼 disabled.
- `source: motion_4096.bin page N` tooltip: raw page chain 미구현이면 제거.
- WalkLab: torque off / recovery required 상태에서는 프리셋 시작 차단.

### 2단계: WalkLab 송출 경로를 공통 안전 executor로 이동

WalkLab의 직접 Bus write는 현재 구조상 계속 문제를 만든다.

요구사항:

- `runWalkCycle`에서 실패를 삼키지 말 것.
- cycle 시작 전 ARM/power/torque 조건을 명시적으로 확인할 것.
- 하체 write 실패 시 즉시 중단할 것.
- 종료 walkReady 복귀도 결과를 확인할 것.
- `Task.detached`에서 main actor 객체와 bus를 약하게 섞어 쓰는 구조를 줄일 것.

### 3단계: Remote Pilot 공식 모션 재생 구현

진짜 "원격 조종 메뉴에서 ROBOTIS 공식 모션 실행"이 목표라면 이 작업이 본체다.

요구사항:

- `forge-cli/src/motion_play.rs`의 proven path를 `forge-core` 라이브러리로 추출.
- FFI 노출.
- Swift wrapper 추가.
- `TeleopChannel.sendMotion`에서 raw page 재생 호출.
- 기존 단일 pose fallback은 명시적 preview mode로만 유지.

## 최소 수용 기준

다음 조건을 만족해야 이 이슈를 해결했다고 볼 수 있다.

1. 실 로봇 연결 + ARM 전에는 Remote Pilot Action Bar가 실제 송출 가능한 것처럼 보이지 않는다.
2. D-pad 방향 조작은 실송출이 꺼져 있으면 누를 때 명확한 "sim only / 준비 중" 피드백이 나온다.
3. WalkLab에서 E-stop 후 바로 프리셋 실행을 누르면 silent failure가 아니라 "복구/ARM 필요"로 차단된다.
4. WalkLab 보행 loop에서 speed/position write 실패가 발생하면 성공 이벤트가 뜨지 않는다.
5. Remote Pilot의 공식 모션 버튼은 둘 중 하나다.
   - 실제 `motion_4096.bin` page step chain을 재생한다.
   - 아니면 단일 포즈 프리뷰라고 명확히 표시한다.
6. left kick/get-up 등 raw chain이 필요한 슬롯은 구현 전까지 disabled/준비 중이어야 한다.

## 테스트 요구

하드웨어가 없더라도 최소 다음 테스트가 필요하다.

1. `PilotActionBar` enabled 로직 테스트
   - bus connected + gate unarmed이면 real send 버튼 disabled.
   - bus nil이면 sim preview로만 허용.
2. `PilotDpad` 테스트
   - `dpadRealMotor == false`에서 방향 입력 시 `applyPoseSmoothly`가 호출되지 않고 사용자 피드백이 남는다.
   - stop은 기존 정책대로 walkReady를 보낸다.
3. `TeleopChannel.arm` 테스트
   - partialFailure 또는 상체 torque degraded 후 `armStage == .readyDegraded`가 유지된다.
4. WalkLab executor 테스트
   - speed write 실패가 result에 집계된다.
   - 하체 position write 실패는 cycle 중단과 실패 이벤트를 만든다.
   - torque off 상태에서는 cycle 시작 전 차단된다.
5. raw motion playback 구현 시 Rust 테스트
   - slot 1, 4, 9, 12, 13, 15, 23 load 가능.
   - INVALID/TORQUE_OFF mask 처리.
   - SYNC_WRITE 1 step당 1 packet.
   - cancel 시 다음 step 송출 중단.

검증 명령:

```bash
swift test
cargo test --workspace
```

하드웨어 검증은 별도 체크리스트로 해야 한다.

1. 로봇 연결 후 torque count가 20인지 확인.
2. E-stop 후 WalkLab 프리셋이 차단되는지 확인.
3. 로봇 복구 후 walkReady가 실제로 움직이는지 확인.
4. Remote Pilot ARM 후 slot 9 walkReady가 실제 goal write를 발생시키는지 확인.
5. raw motion playback 구현 후 slot 4, 12, 13을 정비 스탠드에서 저속/감시 상태로 검증.

## Claude에게 전달할 최종 지시

이번 수정 목표를 "모션 값을 또 조정"으로 잡으면 안 된다. 현재 이슈의 본질은 값이 아니라 송출 경로와 UX 상태 불일치다.

먼저 다음 순서로 고쳐줘.

1. Remote Pilot에서 실제로 실송출이 안 되는 기능은 버튼/문구/tooltip에서 명확히 비활성 또는 sim-only로 표시.
2. Action Bar ARM 전 활성 버그 수정.
3. Teleop ARM `readyDegraded` defer 버그 수정.
4. WalkLab 직접 Bus write 루프의 silent failure 제거.
5. WalkLab cycle 시작 전 power/torque/ARM/recovery 상태 확인 추가.
6. 공식 `motion_4096.bin` page chain 재생을 구현할지, 단일 포즈 프리뷰로 낮출지 결정. 실 조종 메뉴라면 반드시 raw page playback FFI를 구현.

완료 후에는 변경 범위와 함께 다음을 보고해줘.

- WalkLab 프리셋이 실제로 어떤 조건에서 실송출되는지.
- E-stop 이후 어떤 경로로 다시 움직일 수 있는지.
- Remote Pilot Action Bar의 각 버튼이 raw page playback인지, 단일 pose preview인지.
- D-pad 방향 버튼이 실송출인지 sim-only인지.
- `swift test`, `cargo test --workspace` 결과.
