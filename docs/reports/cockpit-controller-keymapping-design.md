# Cockpit 범용 게임패드 연결 & 키매핑 기능 설계

> 작성: 2026-06-03 · 대상: DarwinForge Cockpit(조종 시뮬) · 상태: **설계(미구현)**
> 트리거: 사용자가 Anbernic **RG G01**("RG001") 컨트롤러 구매 → 조종 시뮬에 연결 + 키 재매핑 기능 요구.

---

## 0. 요약 (결론 먼저)

- **기기**: "RG001"은 Anbernic **RG G01**(추정)으로, 독립형 게임기가 아니라 **PC/Mac/Switch용 컨트롤러**다. Xbox 레이아웃 / Bluetooth 5.0 · 2.4G 동글 · USB-C 유선 / Hall 스틱 · 6축 자이로 · 진동. → **PC 있을 때(Mac 시뮬)·없을 때(로봇 2.4G 직결) 둘 다에 부합하는 좋은 선택.**
- **좋은 소식**: 키매핑 인프라의 90%가 **이미 DJI용으로 구현돼 있다**. `CockpitAction`(13개 로봇 의도), 바인딩 프로파일(Codable+UserDefaults), "버튼 눌러서 바인딩"하는 Listen-mode UI, 그리고 **source-agnostic한 `CockpitState` 주입 API**. → 새 기능 = "DJI 전용 바인딩 시스템을 **범용 게임패드로 일반화**".
- **입력 경로**: RG G01은 MFi 미인증이라 macOS 인식이 **불확실**. 설계는 **GCController(GameController.framework) 우선 + IOKit raw HID 폴백**의 2-경로를 프로토콜로 추상화한다.
- **변경 규모**: 신규 4~5파일 + 기존 1파일 확장. `CockpitState`는 **무변경**(이미 범용 API).

---

## 1. 기기 사양 (RG G01) 및 macOS 인식 경로

| 항목 | 값 |
|---|---|
| 폼팩터 | PC/Mac/Switch **컨트롤러** (게임기 아님) |
| 레이아웃 | Xbox (A/B/X/Y, LB/RB, LT/RT, 2 스틱, D-pad, 후면 매크로 4) |
| 연결 | Bluetooth 5.0 / **2.4G 무선 동글** / USB-C 유선 |
| 폴링 | 유선 1000Hz / 2.4G 1000Hz / BT 180Hz |
| 부가 | 6축 자이로, 진동, 기기 자체 매크로/리매핑 |

**macOS 입력 경로 (불확실 → 2-경로 폴백 설계):**
- **경로 A — GCController**: Xbox HID 레이아웃은 macOS 11+에서 `GameController.framework`가 인식하는 경우가 많음. 잡히면 `GCExtendedGamepad`로 표준 접근. **우선 시도.**
- **경로 B — IOKit IOHIDManager(raw HID)**: MFi 미인증이라 A에서 안 잡힐 때의 폴백. DJI에서 쓰는 `DJIVirtualJoystickHIDClient` 패턴 재사용. report descriptor 실측 필요(미확정).
- 권장: **A 먼저, 실패 시 B**. 실기에서 `hidutil list` / `ioreg`로 인식 경로 확인이 첫 검증 항목.

> 참고: RG G01의 **2.4G 동글**은 PC-없음(로봇 직결) 경로에도 쓰인다. 단 그건 별도 문서(§gamepad-direct-control-feasibility §7)의 로봇 커널 3.2 호환성 이슈 영역. 본 설계는 **PC-있음(Mac 시뮬) 경로**에 한정.

---

## 2. 재사용 자산 맵 (코드베이스 실측)

| 자산 | 경로 | 재사용도 |
|---|---|---|
| `CockpitAction` (13 액션, 4 그룹) | `Pilot/Cockpit/DJI/CockpitDJIBindingProfile.swift` | **그대로 재사용** (로봇 의도, 장치 무관) |
| `CockpitState.apply/applyHead/trigger*` | `Cockpit/CockpitState.swift` | **무변경** — 이미 source-agnostic |
| `InputSource` enum (`.gamepad` 존재) | `WalkLab/Pilot/PilotIntent.swift` | 재사용 (필요시 case 추가) |
| `CockpitGameControllerWatcher` (GCExtendedGamepad 연결/30Hz 폴링) | `Cockpit/...` | **확장** (현재 버튼 매핑 하드코딩 → 프로파일 적용 추가) |
| `VirtualJoystickMapper.map()` (deadzone/정규화→WalkingCommand) | `WalkLab/Pilot/VirtualJoystick/` | **그대로 재사용** |
| 바인딩 프로파일 패턴(`DJIBindingProfile: Codable` + `DJIBindingProfileStore`) | DJI/ | **템플릿으로 복제** (Axis enum→Int 인덱스) |
| Listen-mode capture(`DJIBindingCapture.detect()`) | DJI/ | 패턴 재사용 (GCExtendedGamepad 버전 신규) |
| 바인딩 UI 3-column 시트(action list/시각화/inspector, "Listen" 버튼) | `CockpitDJIBindingSheet.swift` | **구조 재사용** (가운데 시각화 컬럼만 교체) |

→ **새로 필요한 것**: ① 범용 바인딩 타입 ② 입력 소스 프로토콜(GC/HID 폴백) ③ Watcher의 프로파일 적용 ④ 범용 Listen-capture ⑤ 범용 바인딩 시트.

---

## 3. 아키텍처 설계

```
[RG G01]
  ├─(A) GameController.framework ─┐
  └─(B) IOKit IOHIDManager ───────┤
                                  ▼
                 CockpitControllerSource  (프로토콜: 정규화된 snapshot 제공)
                                  │  snapshot: axes[Int]→Double(-1..1), buttons[Int]→Bool
                                  ▼
                 ControllerBindingProfile  (CockpitAction ↔ Binding, Codable)
                                  │  적용
                                  ▼
                 CockpitControllerWatcher  (30Hz: snapshot×profile → cockpit 주입)
                                  │
        ┌─────────────────┬───────┴───────┬──────────────────┐
        ▼                 ▼               ▼                  ▼
 apply(leftX,leftY,turn) applyHead(pan,tilt) triggerEmergency() triggerBallTrackingToggle()
                                  ▼
                            CockpitState  (무변경)
```

### 3-1. 입력 소스 추상화 — `CockpitControllerSource` 프로토콜 (신규)

GC 경로와 HID 경로를 동일 인터페이스로. WalkLab의 `GamepadInputSource`(이미 존재)와 정합되는 형태.

```swift
// 설계 스케치 — 구현 아님
public struct ControllerSnapshot: Sendable, Equatable {
    public let axes: [Double]      // 정규화 -1...1, 인덱스 = 물리 축
    public let buttons: [Bool]     // 인덱스 = 물리 버튼
    public let timestamp: Double
}

public protocol CockpitControllerSource: AnyObject {
    var displayName: String { get }     // HUD 표시 ("RG G01" 등)
    var axisCount: Int { get }
    var buttonCount: Int { get }
    func start()
    func stop()
    func snapshot() -> ControllerSnapshot
}
```

구현 2종:
- `GCControllerSource` — `GCExtendedGamepad`를 표준 축/버튼 인덱스로 평탄화. (leftStick.x=0, leftStick.y=1, rightStick.x=2, rightStick.y=3, LT=4, RT=5 / A=0,B=1,X=2,Y=3,LB=4,RB=5,…)
- `HIDControllerSource` — `DJIVirtualJoystickHIDClient` 패턴을 VID/PID·report 크기 파라미터화. RG G01 descriptor 실측 후 디코더 작성.

선택 로직: 앱이 GC 우선 탐지(`GCController.controllers()` 비어있지 않으면 GC), 실패 시 HID enumerate 폴백.

### 3-2. 바인딩 타입 — `ControllerBinding` / `ControllerBindingProfile` (신규)

DJI의 `DJIInputBinding`을 **축을 Int 인덱스로** 일반화. `CockpitAction`은 재사용.

```swift
// 설계 스케치
public enum ControllerBinding: Codable, Equatable {
    case axis(index: Int, polarity: Polarity)   // DJI의 (Axis enum) → Int 인덱스
    case button(index: Int)
    case unbound
    public enum Polarity: String, Codable { case positive, negative }
}

public struct ControllerBindingProfile: Codable, Equatable {
    public var name: String
    public var deviceKey: String                       // "gc.xbox" / "hid.2ca3.1021" 등
    public var bindings: [CockpitAction: ControllerBinding]
    public var deadzone: Double                         // 기본 0.10 (VirtualJoystickMapper와 정합)
    public var sensitivity: Double                      // 진폭 스케일
    // 불변 갱신: setBinding은 새 프로파일 반환 (mutation 금지)
    public func setting(_ b: ControllerBinding, for a: CockpitAction) -> ControllerBindingProfile
}
```

불변성 원칙 준수: `setBinding` 대신 **새 프로파일을 반환**하는 순수 함수. DJI의 mutating `setBinding`과 달리 immutable 패턴 채택. 1:1 invariant(같은 입력 중복 할당 시 swap)·안전 액션(emergencyStop/recover) unbound 거부 보호는 DJI 로직 이식.

### 3-3. Watcher 확장 — `CockpitControllerWatcher` (신규, 기존 패턴 복제)

30Hz 폴링 루프에서 `source.snapshot()` × `profile` → cockpit 주입:
- 이동 4축(moveF/B, strafeL/R) → `leftX/leftY` 합성 → `cockpit.apply(leftX:leftY:turn:from:.gamepad)`
- 회전(turnL/R) → `turn`
- 헤드(panL/R, tiltU/D) → norm 합성 → `cockpit.applyHead(panNorm:tiltNorm:)`
- 버튼 edge-trigger → `cockpit.triggerEmergency()/triggerRecovery()/triggerBallTrackingToggle()`
- 연결 시 `cockpit.setController(name: source.displayName)`

`profile == nil`이면 기본 프리셋(§5) 사용.

### 3-4. 영속화 — `ControllerBindingProfileStore` (신규, 패턴 복제)

`UserDefaults.standard`, JSON, 키 `"cockpit.controller.binding.profile.v1"`(컨벤션 `<domain>.<entity>.<subject>.v<N>`). 디바이스별 프로파일을 원하면 `cockpit.controller.<deviceKey>.binding.v1`로 분기.

---

## 4. UI 설계 — 바인딩 시트 (기존 3-column 재사용)

`CockpitDJIBindingSheet` 구조를 복제해 `CockpitControllerBindingSheet` 신규:
- **왼쪽**: `CockpitAction` 그룹별(이동/회전/머리/안전) 할당 카드 — 그대로 재사용.
- **가운데**: DJI 조종기 일러스트(`CockpitDJIControllerVisual`) → **Xbox 레이아웃 패드 일러스트로 교체**(유일한 신규 시각 자산). 현재 바인딩 하이라이트.
- **오른쪽 Inspector**: 매핑 dropdown + 감도/deadzone slider + 반응곡선 — 재사용.
- **Listen-mode("눌러서 바인딩")**: "Listen" 버튼 → 다음 입력 캡처 → 자동 매핑. `DJIBindingCapture.detect()`의 GCExtendedGamepad/HID 버전(`ControllerBindingCapture`) 신규.
- **Manual picker**: 미연결 시 축인덱스/polarity/버튼 수동 선택 — 재사용.
- 저장(Return)/취소(ESC)/기본값 복원 — 재사용.

진입점: Cockpit 화면 툴바에 "컨트롤러 설정" 버튼 → 시트 present.

---

## 5. 기본 매핑 프리셋 (RG G01 = Xbox 레이아웃)

| 입력 | CockpitAction | 비고 |
|---|---|---|
| 좌스틱 Y (−위) | moveForward / moveBackward | 전후진 |
| 좌스틱 X | strafeLeft / strafeRight | 횡이동 |
| 우스틱 X | turnLeft / turnRight | 제자리 회전 |
| 우스틱 Y | headTiltUp / headTiltDown | 머리 상하 |
| LT / RT (또는 D-pad ←→) | headPanLeft / headPanRight | 머리 좌우 |
| B | emergencyStop | 즉시 정지(안전, unbound 불가) |
| Y | recover | 기립/복구(안전) |
| X (또는 후면 매크로) | ballTracking | 자율 볼트래킹 토글 |

> ballTracking이 ON이면 머리·보행이 자율 점유(별도 문서 §6 참조) → 토글 시 수동 헤드 입력은 무시되는 UX를 HUD에 표시.

---

## 6. 신규/수정 파일 (구현 범위)

신규:
1. `Cockpit/Controller/CockpitControllerSource.swift` — 프로토콜 + `ControllerSnapshot`.
2. `Cockpit/Controller/GCControllerSource.swift` — GameController 구현.
3. `Cockpit/Controller/HIDControllerSource.swift` — IOKit 폴백(파라미터화, DJI 클라이언트 일반화).
4. `Cockpit/Controller/ControllerBinding.swift` — `ControllerBinding`/`ControllerBindingProfile`/`Store`/기본 프리셋.
5. `Cockpit/Controller/CockpitControllerWatcher.swift` — 폴링·주입.
6. `Cockpit/Controller/CockpitControllerBindingSheet.swift` + Xbox 패드 일러스트.

수정:
- 기존 `CockpitGameControllerWatcher` — 신규 `CockpitControllerWatcher`로 대체하거나, 프로파일 적용 경로만 추가(하위호환). `CockpitState`는 **무변경**.

테스트(TDD, RED 먼저):
- `ControllerBindingProfile` 직렬화/불변 setBinding/안전액션 보호.
- snapshot×profile → cockpit 주입 매핑(MockControllerSource).
- Listen-capture detect(최대 magnitude 축/버튼 우선).
- deadzone/정규화 정합(`VirtualJoystickMapper` 재사용 검증).

---

## 7. 단계별 구현 플랜 (승인 후)

1. **RED**: `ControllerBinding`/`Profile`/`Store` + 테스트(직렬화·불변·안전).
2. 소스 추상화 + `GCControllerSource` + `MockControllerSource`.
3. `CockpitControllerWatcher` + 주입 매핑 테스트.
4. 기본 프리셋(Xbox) + cockpit 연동(실 시뮬에서 스틱→로봇 의도 확인).
5. Listen-capture + 바인딩 시트 UI(가운데 컬럼 교체).
6. `HIDControllerSource` 폴백 — **실기에서 GC 인식 실패가 확인될 때만**(RG G01 descriptor 실측 필요).
7. code-reviewer / 스펙 리뷰.

---

## 8. 미확정 · 리스크

- **GC vs HID**: RG G01이 macOS GCController에 잡히는지 **실기 검증 전 불확실**. 안 잡히면 6번(HID 폴백) 필수 + descriptor 실측 작업 추가.
- **2.4G 동글의 macOS 인식**: 동글 모드가 XInput/DirectInput 중 무엇으로 enumerate되는지 미확인.
- **기기 자체 리매핑과 충돌**: RG G01은 기기 내 매크로/리매핑 기능 보유 → 앱 바인딩과 이중 매핑 혼란 가능. 권장: **기기는 표준 Xbox 출력으로 두고 의미 매핑은 앱에서**.
- 모델명 RG G01은 **추정**(사용자 "RG001"). 실물 모델명 확인 필요.

---

## 출처

- 코드 근거: `CockpitDJIBindingProfile.swift`, `CockpitGameControllerWatcher.swift`, `CockpitState.swift`(apply/applyHead/trigger*), `VirtualJoystickMapper.swift`, `CockpitDJIBindingSheet.swift`, `CockpitDJIBindingCapture.swift`, `DJIVirtualJoystickHIDClient.swift`, WalkLab `GamepadInputSource`/`GamepadMappingStore`.
- 기기: [Anbernic RG G01 제품 페이지](https://anbernic.com/products/rg-g01), [Anbernic Game Controller 카테고리](https://anbernic.com/collections/game-controller)
- 연계: `docs/reports/gamepad-direct-control-feasibility.md` (§6 볼트래킹 토글, §7 로봇 직결 커널 호환).
