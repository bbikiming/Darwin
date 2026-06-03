# Mac 작업 프롬프트 — `cockpit.telemetry` 송신 구현

> **목적**: OP Pilot(iOS) 모바일 앱이 Mac DarwinForge로부터 **실 robot 자세(IMU roll/pitch)·
> 자이로 보정 상태·자동 낙하 복구 단계**를 받아 조종기 화면의 인공 수평선과 복구 배너를
> 살리도록, Mac 측에 새 텔레메트리 메시지 `cockpit.telemetry`를 추가한다.
>
> **iOS 쪽은 이미 완료**되어 있다(이 문서 맨 끝 "iOS 수신 계약" 참고). Mac이 이 메시지를
> 보내기 시작하면 모바일에서 **자동으로** 인공 수평선/복구 배너가 동작한다. Mac이 안 보내도
> 모바일은 종전과 동일하게 동작한다(graceful degradation). 즉 **하위호환 안전**.

---

## 배경 (왜 필요한가)

현재 Mac→iOS의 유일한 주기 상태 페이로드 `TelemetryStatePayload`
(`MobileRelayCommand.swift`)는 **연결/안전/하드웨어 상태**(mac/robot/battery/temp/latency/
safety/dxlPower/armed/uiState)만 담는다.

Cockpit(⌘9)이 화면에 그리는 **실 robot IMU 기울기(roll/pitch)·balance 상태·자동 복구 단계**는
이 페이로드에 없어서 모바일로 전달되지 않는다. iOS `CockpitAttitudeIndicator`는 인공 수평선을
그릴 준비가 돼 있으나 데이터가 없어 heading만 표시 중이다.

데이터 자체는 이미 Mac에 public으로 존재한다:
- `WalkLabSession.imuRollDeg`, `WalkLabSession.imuPitchDeg` (둘 다 `public var`)
- `ConnectionStore.imuFilter.rollDeg / .pitchDeg` (Cockpit이 `currentIMURoll/Pitch`로 사용 중)
- `WalkLabSession.autoRecoveryPhase`, `enableBalanceCorrection`, balance 상태

따라서 **새 데이터를 만들 필요는 없고**, 기존 값을 새 메시지로 직렬화해 보내기만 하면 된다.

---

## 구현 단계 (Mac 측, `app/ui/DarwinForge/`)

### 1. 송신 이벤트 타입 추가 — `Sources/DarwinForgeUI/MobileRelay/MobileRelayCommand.swift`

`OutboundEventType` enum(현재 line 93~)에 case 추가:

```swift
public enum OutboundEventType: String, Codable, Sendable {
    case sessionWelcome   = "session.welcome"
    case telemetryState   = "telemetry.state"
    case cockpitTelemetry = "cockpit.telemetry"   // ← 추가
    // ... 기존 유지
}
```

### 2. 페이로드 구조 추가 — 같은 파일 (`MobileRelayCommand.swift`)

`TelemetryStatePayload` 정의 근처에 추가. **iOS의 `RobotAttitudePayload`와 필드명·타입이
정확히 일치해야 한다**(JSON 키가 곧 계약):

```swift
/// 실 robot 자세 텔레메트리 — `cockpit.telemetry` 이벤트 페이로드.
/// iOS `RobotAttitudePayload`(MobilePilotKit)와 1:1 대응.
public struct RobotAttitudePayload: Codable, Sendable, Equatable {
    public let rollDeg: Double          // 실 IMU roll(+우측 기울임)
    public let pitchDeg: Double         // 실 IMU pitch(+전방 숙임)
    public let balanceState: String?    // "normal"/"correcting"/... (enum 대신 String)
    public let autoRecoveryPhase: String?  // "idle"/"fallen"/"settling"/"gettingUp"/"failed"/"done"
    public let fallDirection: String?   // "forward"/"backward"/nil

    public init(rollDeg: Double, pitchDeg: Double,
                balanceState: String? = nil,
                autoRecoveryPhase: String? = nil,
                fallDirection: String? = nil) {
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
        self.balanceState = balanceState
        self.autoRecoveryPhase = autoRecoveryPhase
        self.fallDirection = fallDirection
    }
}
```

> **주의**: `autoRecoveryPhase`/`fallDirection`은 Mac 내부 enum(`AutoRecoveryPhase`,
> `AutoFallRecovery.FallDirection`)을 **rawValue String으로 변환**해 보낸다. iOS는 String으로
> 받아 매칭하므로(`"gettingUp"` 등), Mac enum의 case 이름과 문자열이 일치하는지 확인할 것.
> iOS가 인식하는 문자열: `idle / fallen / settling / gettingUp / failed / done`,
> 방향 `forward / backward`. Mac enum 이름이 다르면 변환 시 매핑 테이블을 둘 것.

### 3. broadcast 메서드 추가 — `Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift`

기존 `broadcastTelemetry()`(line 327~) 바로 아래에 동일 패턴으로 추가:

```swift
/// 실 robot 자세를 활성 세션에 전송. payload는 호출자(MobileRelayBootstrap)가
/// WalkLabSession/ConnectionStore에서 채워 넘긴다.
public func broadcastCockpitTelemetry(_ payload: RobotAttitudePayload) async {
    guard let session else { return }
    await send(envelope: makeEnvelope(type: OutboundEventType.cockpitTelemetry.rawValue,
                                      payload: payload),
               to: session.channel)
}
```

> `broadcastTelemetry()`는 `port.snapshot()`으로 스스로 데이터를 만들지만, 자세 데이터는
> `RobotSafetyPort` 계약 밖이므로(IMU는 안전 포트의 책임이 아님) **호출자가 payload를 주입**하는
> 형태가 깔끔하다. (대안: `RobotSafetyPort`에 `attitudeSnapshot()`을 추가하고 `broadcastTelemetry`
> 처럼 self-contained로 만들 수도 있음 — 취향. 아래 4단계는 주입 방식 기준.)

### 4. 주기적 전송 배선 — `Sources/DarwinForgeUI/MobileRelay/MobileRelayController.swift`

`startTelemetryPump()`(telemetry 주기 송신 루프)에서 `broadcastTelemetry()`를 호출하는
지점 근처에 자세 전송을 추가한다. WalkLabSession/ConnectionStore 접근이 필요하므로,
`MobileRelayBootstrap`이 주입한 closure를 통해 값을 읽는다(아래 5단계).

권장: **자세는 일반 telemetry와 동일 주기(burst 200ms / steady 250~1000ms)로 충분**하다.
인공 수평선은 4Hz면 부드럽게 보인다. 30Hz는 불필요(대역폭/부하만 증가).

```swift
// startTelemetryPump 루프 안, broadcastTelemetry() 호출 직후:
if let attitude = await self.cockpitAttitudeProvider?() {
    await server.broadcastCockpitTelemetry(attitude)
}
```

### 5. 데이터 소스 주입 — `Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift`

`MobileRelayController`에 자세 provider closure를 추가하고, bootstrap의 `rebindHooks()`
시점(WalkLabSession/ConnectionStore가 wiring되는 곳)에서 주입한다. 기존 `swapBatteryVoltage`
패턴과 동일:

```swift
// MobileRelayController:
private var cockpitAttitudeProvider: (@Sendable () async -> RobotAttitudePayload?)?
public func swapCockpitAttitudeProvider(
    _ closure: @escaping @Sendable () async -> RobotAttitudePayload?) {
    self.cockpitAttitudeProvider = closure
}

// MobileRelayBootstrap.rebindHooks() 안:
controller.swapCockpitAttitudeProvider { [weak session, weak store] in
    guard let session else { return nil }
    return RobotAttitudePayload(
        rollDeg: session.imuRollDeg,          // 이미 public
        pitchDeg: session.imuPitchDeg,        // 이미 public
        balanceState: session.enableBalanceCorrection ? "correcting" : "normal",
        autoRecoveryPhase: String(describing: session.autoRecoveryPhase), // enum→String
        fallDirection: /* fallen일 때 방향, 아니면 nil */ nil)
}
```

> `autoRecoveryPhase`가 `.fallen(.forward)`처럼 연관값을 가지면, phase 문자열은
> `"fallen"`으로, 방향은 `"forward"`로 **분리**해 넣어야 한다(iOS가 두 필드를 따로 읽음).
> `String(describing:)`은 `"fallen(forward)"`가 되어 매칭 실패하므로, switch로 분해할 것:
> ```swift
> let (phaseStr, dir): (String, String?) = {
>     switch session.autoRecoveryPhase {
>     case .idle: return ("idle", nil)
>     case .fallen(let d): return ("fallen", d == .forward ? "forward" : "backward")
>     case .settling: return ("settling", nil)
>     case .gettingUp: return ("gettingUp", nil)
>     case .failed: return ("failed", nil)
>     case .done: return ("done", nil)
>     // 실제 enum case 이름에 맞춰 조정
>     }
> }()
> ```

---

## 검증 (Mac 측)

1. **빌드**: `cd app/ui/DarwinForge && swift build`
2. **단위 테스트**: `RobotAttitudePayload` 인코딩 → JSON 키가 `rollDeg/pitchDeg/balanceState/
   autoRecoveryPhase/fallDirection`인지 확인하는 round-trip 테스트 추가.
3. **통합(실기기/시뮬)**:
   - iOS OP Pilot 페어링 → Mac에서 로봇을 손으로 기울임 → **모바일 조종기 탭의 컴퍼스 안에
     인공 수평선이 기울어지는지** 확인.
   - `|roll|` 또는 `|pitch| > 25°`면 모바일에서 빨간 "기울기 경고" 표시.
   - 자동 복구 트리거 시 모바일 상단에 "앞으로 넘어짐 감지 → 일어나는 중…" 배너.

---

## iOS 수신 계약 (이미 구현됨 — 변경 금지, 참고용)

Mac이 맞춰야 할 **JSON 와이어 포맷**. iOS가 이 형태를 디코드한다.

```json
{
  "v": 1,
  "id": "evt_xxxxxx",
  "type": "cockpit.telemetry",
  "sentAt": "2026-06-03T12:00:00.000Z",
  "payload": {
    "rollDeg": -3.5,
    "pitchDeg": 12.0,
    "balanceState": "correcting",
    "autoRecoveryPhase": "gettingUp",
    "fallDirection": "forward"
  }
}
```

- `payload.rollDeg`, `payload.pitchDeg`: **필수**(Double).
- 나머지 3개: **선택**(생략 가능). Mac이 IMU만 먼저 보내고 싶으면 roll/pitch만 보내도 됨.
- iOS 측 정의: `MobilePilotKit/MobileRelayModels.swift`의
  - `enum EventType { case cockpitTelemetry = "cockpit.telemetry" }`
  - `struct RobotAttitudePayload`
  - `InboundMessage.cockpitTelemetry` + `InboundDecoder`의 해당 case
- iOS 소비:
  - `AppState.robotAttitude: RobotAttitudePayload?` (handle에서 갱신, 끊김 시 nil)
  - `CockpitAttitudeIndicator(rollDeg:pitchDeg:)` — 인공 수평선
  - `RemotePilotScreen.autoRecoveryBanner` — `isRecovering`(idle/done이 아니면 true)일 때 표시
- iOS 인식 문자열 값:
  - `autoRecoveryPhase`: `idle`, `fallen`, `settling`, `gettingUp`, `failed`, `done`
  - `fallDirection`: `forward`, `backward`
  - (그 외 문자열도 안전하게 무시됨 — "자동 복구 중" 기본 라벨)

---

## 추가 작업 2 — `cockpit.link` 회선 품질 송신 (★ 우선순위 높음)

> **배경**: 통신은 3-hop — **iPhone ─①WS/WiFi─ Mac ─②SSH/UDP/유선─ 로봇**. 모바일이
> 보여주는 `latencyMs`(`TelemetryStatePayload`)는 **①구간 + Mac 내부 함수 실행시간만** 반영하고
> **②구간(Mac↔로봇)의 실지연을 숨긴다**. 그래서 SSH 무선으로 실제 0.7~2.5초 지연이 나도 화면엔
> 50~200ms로 떠 사용자가 위험을 인지 못 한다. **이 갭이 "SSH 무선에서 원활한가"의 핵심 문제다.**
>
> iOS는 이미 `cockpit.link`를 받아 **로봇 회선 행 + 저하 배너("유선 권장")**를 띄울 준비가 됐다.
> Mac이 ②구간 품질을 측정해 보내기만 하면 된다.

### iOS 수신 계약 (이미 구현됨 — 변경 금지)

```json
{
  "v": 1, "id": "evt_xxxxxx", "type": "cockpit.link",
  "sentAt": "2026-06-03T12:00:00.000Z",
  "payload": {
    "robotLinkRttMs": 480,
    "telemetryHz": 4.5,
    "transport": "ssh-wireless",
    "onboardStale": false
  }
}
```

- 모든 필드 **선택**(생략 가능). iOS 정의: `MobilePilotKit/MobileRelayModels.swift`의
  `EventType.cockpitLink = "cockpit.link"`, `struct RobotLinkPayload`,
  `InboundMessage.cockpitLink` + 디코더.
- iOS 소비: `AppState.robotLink`, `CockpitTelemetryGrid`(로봇회선 행), `RemotePilotScreen.robotLinkBanner`.
- iOS 판정 임계(참고): `isDegraded` = RTT > 350ms **또는** telemetryHz < 2.0 **또는** onboardStale;
  `isWireless` = transport=="ssh-wireless" 또는 RTT > 100ms.
- iOS 인식 `transport` 값: `udp` / `ssh-wired` / `ssh-wireless` / `lan` (그 외 문자열은 그대로 표시).

### Mac 구현 (저주파 1Hz면 충분 — 자세보다 느려도 됨)

1. **타입/페이로드** — `MobileRelayCommand.swift`:
   - `OutboundEventType`에 `case cockpitLink = "cockpit.link"`
   - `RobotLinkPayload` struct (위 JSON 필드와 1:1, iOS와 키 일치)
2. **broadcast** — `MobileRelayServer.swift`에 `broadcastCockpitLink(_ payload:)` (telemetry 패턴 복사)
3. **데이터 소스** — 값은 이미 `ConnectionStore`에 있다(메모리/코드 확인):
   - `robotLinkRttMs`: SSH 폴 왕복 또는 UDP 패킷 간격 기반. `OnboardTelemetryPoller`의 마지막
     exchange 소요시간, 또는 `ConnectionStore.lastRoundTripMs`(단 이건 TCP 5530 RTT라 보행 모드선
     부정확 — SSH RTT를 따로 측정 권장).
   - `telemetryHz`: 최근 N개 텔레메트리 수신 간격의 역수(이동평균). `ingestOnboardTelemetry`에
     수신 타임스탬프 ring 추가해 계산.
   - `transport`: UDP 수신중이면 `"udp"`; SSH 폴링이면 `remoteShell.host`가 유선(192.168.123.x)
     이면 `"ssh-wired"`, 무선(192.168.0.x 등)이면 `"ssh-wireless"`; 관절편집(bus!=nil)이면 `"lan"`.
   - `onboardStale`: `telemetryMode == .onboardStale` 여부.
4. **주기 전송** — `MobileRelayController.startTelemetryPump`에서 1초(또는 2초)마다
   `broadcastCockpitLink` 호출(자세 4Hz보다 낮게).

### 추가 작업 3 — 유선 우선 폴러 host 자동 선택 (★ 근본 개선)

메모리 노트 `telemetry-path-bottleneck`: 유선 직결(192.168.123.1)이 무선 대비 **~166배 빠름**
(RTT 0.9ms vs 149ms, 손실 0% vs 10%). 그러나 `OnboardTelemetryPoller`의 host는 연결 시점
`remoteShell.host`로 고정되어 **무선에 고착**될 수 있다.

- `ConnectionStore.startOnboardTelemetry`(메모리상 L1581 근처)에서 폴러 host 선택 시 **유선 대역
  (192.168.123.x)을 우선** 시도하고, 실패 시에만 무선으로 폴백.
- 또는 UI에 "유선 재연결" 원클릭 버튼(메모리상 이미 일부 존재). 코드 변경 최소화하려면 이 버튼
  하나로도 ②구간이 ~166배 빨라진다.

---

## 선택적 후속 (지금은 불필요)

- **실 robot pose 30Hz 미러링**: 18관절 각도를 보내 모바일에서도 3D 자세 렌더링. 대역폭이
  커지므로 binary/delta encoding 필요. 인공 수평선만으로 "기울기 모니터링" 목적은 충분하니
  필요할 때만.
- **heading도 실 IMU yaw로**: 현재 모바일 컴퍼스 heading은 iOS 자체 시뮬값. 실 yaw를 보내면
  더 정확하나, robot에 절대 yaw 센서가 없으면 의미 제한적.
