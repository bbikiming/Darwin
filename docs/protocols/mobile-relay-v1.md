# Mobile Relay Protocol v1

작성일: 2026-05-25
대상: DarwinForge iOS Mobile Pilot ↔ Mac DarwinForge MobileRelayServer
상태: Draft — 첫 MVP 구현 기준

## 1. 목적

iPhone Mobile Pilot 앱이 Mac DarwinForge MobileRelayServer 를 거쳐 ROBOTIS DARWIN
로봇을 안전하게 조종하기 위한 명령/응답/이벤트 스키마를 단일 source-of-truth 로
정의한다. iOS 앱과 Mac 앱은 같은 스키마를 사용해야 한다.

## 2. 비범위

- iPhone 이 raw Dynamixel/CM 바이트를 직접 보내는 경로
- HTTP REST 인터페이스 (MVP 는 WebSocket only)
- 다중 iPhone 동시 권한
- 보행 free-form streaming

## 3. 전송 (Transport)

| 항목 | 값 |
|---|---|
| 프로토콜 | WebSocket (RFC 6455) over TCP |
| 발견 | Bonjour `_darwinforge._tcp` |
| 페어링 | 6자리 숫자 코드 + QR payload |
| 페이로드 | JSON UTF-8, 한 WebSocket frame 당 한 메시지 |
| 압축 | 없음 (MVP) |
| TLS | 없음 (로컬 네트워크). 후속 protocol v2 에서 mTLS 검토 |

WebSocket 경로: `ws://<host>:<port>/mobile-relay`

QR payload:

```json
{
  "type": "darwinforge.mobileRelay",
  "host": "192.168.0.20",
  "port": 17370,
  "pairingCode": "482913",
  "service": "_darwinforge._tcp"
}
```

## 4. 메시지 봉투 (Envelope)

모든 메시지는 동일한 봉투를 사용한다.

```json
{
  "v": 1,
  "id": "cmd_000123",
  "type": "pilot.walk",
  "sentAt": "2026-05-25T12:00:00.000Z",
  "payload": { }
}
```

| 필드 | 타입 | 필수 | 설명 |
|---|---|---|---|
| `v` | int | yes | 프로토콜 버전. 현재 1 |
| `id` | string | yes | 메시지 ID. command 는 sender 가 생성, event 는 server 가 생성 |
| `type` | string | yes | 메시지 종류 (아래 분류) |
| `sentAt` | ISO 8601 string | yes | sender clock 기준 송신 시각 |
| `payload` | object | yes | 타입별 데이터. 없으면 `{}` |

ID 규칙:

- iOS 가 보내는 command: `cmd_<6-digit-monotonic>` (e.g. `cmd_000123`)
- Mac 이 보내는 event: `evt_<6-digit-monotonic>`
- 응답 (ack/accepted/rejected/failed) 은 원본 command 의 `id` 를 그대로 echo

타임스탬프:

- ISO 8601 with millisecond precision and `Z` suffix.
- iOS / Mac clock 차이는 latency 계산에 영향이 있으므로 `command.ack` 의 `latencyMs`
  는 server 측 `receivedAt - command.sentAt` 가 아니라 robot ACK round-trip 으로
  계산해야 한다.

## 5. 세션 흐름

```
iOS                                       Mac relay
 │  ─── session.hello ──────────────────▶ │
 │  ◀── session.welcome ──────────────── │   pairing 확인
 │  ─── pilot.heartbeat (100ms) ───────▶ │   active control 중에만
 │  ◀── telemetry.state (1Hz) ─────────  │
 │  ─── pilot.arm ─────────────────────▶ │
 │  ◀── command.accepted ──────────────  │
 │  ◀── arming.progress (multi) ───────  │
 │  ◀── command.ack ───────────────────  │   armed=true
 │  ─── pilot.walk ────────────────────▶ │
 │  ◀── command.ack ───────────────────  │
 │  ─── pilot.stop ────────────────────▶ │   touch end
 │  ◀── command.ack ───────────────────  │
 │  ─── session.goodbye ───────────────▶ │   optional
```

## 6. 명령 (Client → Server)

### 6.1 session.hello

connection 직후 첫 메시지. pairing code 와 클라이언트 정보를 전달한다.

```json
{
  "v": 1,
  "id": "cmd_000001",
  "type": "session.hello",
  "sentAt": "2026-05-25T12:00:00.000Z",
  "payload": {
    "app": "ios",
    "appVersion": "0.1.0",
    "protocolVersion": 1,
    "deviceName": "Pilot iPhone",
    "deviceId": "B4E1A0C8-...",
    "pairingCode": "482913"
  }
}
```

Mac 응답:

- 정상: `session.welcome`
- 코드 불일치: `session.rejected` (`reason: pairingMismatch`)
- 다른 iPhone 이 이미 권한 보유: `session.rejected` (`reason: alreadyOwned`)
- 프로토콜 비호환: `session.rejected` (`reason: protocolMismatch`)

### 6.2 pilot.heartbeat

active control (walking / motion progress / E-stop 직후) 중에 iOS 가 100ms 마다
송신한다. ACK 없음.

```json
{
  "v": 1,
  "id": "cmd_000099",
  "type": "pilot.heartbeat",
  "sentAt": "2026-05-25T12:00:00.500Z",
  "payload": {
    "uiState": "commandActive",
    "activeCommandId": "cmd_000098"
  }
}
```

uiState 허용 값:

- `idle` — heartbeat 미전송 (이 경우 메시지 자체를 보내지 않음)
- `armedReady` — 명령 가능하지만 active 없음
- `commandActive` — walk 또는 motion 진행 중
- `estopping` — E-stop UI 전환 후 ACK 대기

### 6.3 pilot.arm

ARM checklist 통과 후 송신.

```json
{
  "v": 1,
  "id": "cmd_000010",
  "type": "pilot.arm",
  "sentAt": "2026-05-25T12:00:00.000Z",
  "payload": {
    "cradleConfirmed": true,
    "operator": "Pilot iPhone"
  }
}
```

### 6.4 pilot.disarm

```json
{
  "v": 1,
  "id": "cmd_000011",
  "type": "pilot.disarm",
  "sentAt": "2026-05-25T12:00:01.000Z",
  "payload": { "reason": "user" }
}
```

reason 허용 값: `user`, `tabSwitch`, `appBackground`, `timeout`.

### 6.5 pilot.estop

```json
{
  "v": 1,
  "id": "cmd_000012",
  "type": "pilot.estop",
  "sentAt": "2026-05-25T12:00:02.000Z",
  "payload": { "reason": "user" }
}
```

reason 허용 값: `user`, `watchdog`, `latencyGate`, `appBackground`, `disconnect`.

처리 보장:

- Mac relay 는 즉시 `ConnectionStore.emergencyStop()` 경로 호출
- 응답 (`command.ack` 또는 `command.failed`) 은 즉시 송신
- iOS UI 는 ACK 를 기다리지 않고 EStopped 표시

### 6.6 pilot.motion

검증된 motion/pose 1개 실행.

```json
{
  "v": 1,
  "id": "cmd_000020",
  "type": "pilot.motion",
  "sentAt": "2026-05-25T12:01:00.000Z",
  "payload": {
    "slot": 9,
    "label": "walkReady",
    "confirmRisk": false
  }
}
```

MVP slot ↔ label 매핑 (Mac 측 카탈로그와 일치 필수):

| label | slot | 위험도 |
|---|---:|---|
| `walkReady` | 9 | safe |
| `basicPosture` | 1 | safe |
| `sit` | 15 | caution |
| `greeting` | 4 | safe |
| `stop` | -1 | safe (`pilot.stop` 사용 권장) |
| `kickRight` | 12 | highRisk — MVP 비활성 |
| `kickLeft` | 13 | highRisk — MVP 비활성 |

**P0-4 fix (truth-gap report, 2026-05-25):** `bow` 는 첫 빌드에서 제외됨.
`docs/motion-format/page-catalog-motion4096.md` 기준 slot 41 은 `talk2`
long-chain 시작이라 "절" 의미와 다르다. 정확한 slot 이 확인되고 HIL 검증을
통과한 뒤 재추가한다.

위험도가 `caution` 이상이면 `confirmRisk: true` 가 없으면 Mac 이 reject.

### 6.7 pilot.walk

WalkLab onboard brokering 명령. 첫 빌드는 preset 만 활성 (slowForward, turnLeft,
turnRight, stop). free-form param 은 인터페이스만 정의하고 서버가 reject 한다.

```json
{
  "v": 1,
  "id": "cmd_000030",
  "type": "pilot.walk",
  "sentAt": "2026-05-25T12:02:00.000Z",
  "payload": {
    "preset": "slowForward",
    "enabled": true,
    "xMm": 20.0,
    "yMm": 0.0,
    "aDeg": 0.0,
    "periodMs": 700,
    "footMm": 35.0,
    "hipPitchDeg": 13.0
  }
}
```

| preset | enabled | xMm | yMm | aDeg | periodMs | footMm | hipPitchDeg |
|---|:---:|---:|---:|---:|---:|---:|---:|
| `slowForward` | true | 20 | 0 | 0 | 700 | 35 | 13 |
| `turnLeft` | true | 0 | 0 | 8 | 700 | 35 | 13 |
| `turnRight` | true | 0 | 0 | -8 | 700 | 35 | 13 |
| `stop` | false | 0 | 0 | 0 | 700 | 35 | 13 |

수용 규칙:

- 알려지지 않은 preset 은 reject (`reason: unknownPreset`).
- preset 이름이 있으면 numeric 값은 무시하고 서버가 위 표를 권위로 사용한다.
- 동일 preset 연속 호출은 server 가 5Hz 이하로 dedup 한다.

### 6.8 pilot.stop

walk 또는 motion 즉시 중단. ARM 은 유지된다 (E-stop 과 차이).

```json
{
  "v": 1,
  "id": "cmd_000031",
  "type": "pilot.stop",
  "sentAt": "2026-05-25T12:02:01.000Z",
  "payload": { "reason": "deadmanRelease" }
}
```

reason 허용 값: `user`, `deadmanRelease`, `tabSwitch`, `appBackground`, `latencyGate`.

### 6.9 session.goodbye

선택적. 정상 종료 시 송신.

```json
{
  "v": 1,
  "id": "cmd_000099",
  "type": "session.goodbye",
  "sentAt": "2026-05-25T12:10:00.000Z",
  "payload": { "reason": "user" }
}
```

송신 후 iOS 는 WebSocket close frame 을 보낸다.

## 7. 응답 (Server → Client, per command)

Mac relay 는 hello/heartbeat 를 제외한 모든 command 에 대해 다음 흐름으로 응답한다 (v1.2):

```
client → command         (e.g. pilot.walk)
server → command.accepted  (informational interim, 검증 통과 후 즉시)
server → command.ack | command.rejected | command.failed   (terminal — 정확히 하나)
```

`command.accepted` 는 **informational interim event** 다. iOS 가 "처리 중" UI 표시를
시작할 수 있다는 신호일 뿐이며, terminal 응답을 대체하지 않는다. terminal 응답
(`command.ack` / `command.rejected` / `command.failed`) 은 항상 정확히 하나 송신된다.

`session.hello` 는 별도 흐름 — `session.welcome` 또는 `session.rejected` (이벤트) 로 응답.
`pilot.heartbeat` 와 `session.goodbye` 는 응답 없음.

### V297-5 priority commands

`pilot.estop` 와 `pilot.stop` 는 **priority commands** — 진행 중인 다른 long-running
명령 (예: ARM 의 battery wait) 에 막히지 않고 서버에서 즉시 처리된다. WSChannel
transport layer 가 frame head 만 sniff 하여 우회 dispatch.

### 7.1 command.accepted

명령을 수신해서 검증을 통과했지만 robot ACK 가 도착하기 전 단계.

```json
{
  "v": 1,
  "id": "cmd_000020",
  "type": "command.accepted",
  "sentAt": "2026-05-25T12:01:00.040Z",
  "payload": {}
}
```

### 7.2 command.rejected

검증 실패. robot 에는 전달되지 않았다.

```json
{
  "v": 1,
  "id": "cmd_000020",
  "type": "command.rejected",
  "sentAt": "2026-05-25T12:01:00.050Z",
  "payload": {
    "reason": "notArmed",
    "message": "ARM 후 다시 시도하세요."
  }
}
```

표준 reason 코드:

- `notArmed` — ARM 전 명령
- `robotDisconnected` — robot endpoint 미연결
- `busBusy` — ROBOTIS demo 가 USB bus 점유
- `pairingMismatch` — pairing 코드 불일치
- `alreadyOwned` — 다른 iPhone 이 권한 보유
- `protocolMismatch` — 프로토콜 버전 불일치
- `unknownPreset` — pilot.walk 의 알려지지 않은 preset
- `riskNotConfirmed` — caution/highRisk 동작인데 `confirmRisk: false`
- `simulated` — Mock/Review Mode 에서 실 명령 거부
- `latencyGate` — 응답 지연으로 walk command 차단
- `invalidPayload` — schema 불일치
- `internalError` — 그 외

V297-5 (v1.2) 추가 코드:

- `lowBattery` — Mac 측 배터리 게이트 (defense-in-depth) 통과 실패
- `clockSkew` — iOS envelope.sentAt 가 Mac clock 과 ±10초 이상 드리프트
- `highRiskNotAllowed` — freeform/jog 등 MVP 비활성 preset 시도
- `dxlPowerOff` — dxlPower OFF 상태에서 walk 시도
- `headUnsupportedInMVP` — pilot.head (capabilities.head=false)
- `preflightFailed` — WalkLabSession.quickPreflight 차단 (cradle/IMU/thermal)
- `walkSessionUnavailable` — WalkLabSession nil (UI tree 미마운트)
- `cradleRequired` — ARM 시 cradleConfirmed=false
- `invalidSlot` — runMotion 슬롯이 UInt8 범위 외
- `armFailed` — TeleopChannel.arm 결과 .ready 미도달

iOS 클라이언트는 forward-compat 위해 모르는 reason 을 `.unknown` 으로 fallback 한다.
서버는 미래 reason 추가 시 본 목록 갱신 + iOS RejectionReason enum 추가 case 등록.

### 7.3 command.ack

robot ACK 수신. 성공으로 표시 가능.

```json
{
  "v": 1,
  "id": "cmd_000020",
  "type": "command.ack",
  "sentAt": "2026-05-25T12:01:00.122Z",
  "payload": {
    "latencyMs": 82,
    "robotAckId": "abc12345-0001"
  }
}
```

### 7.4 command.failed

명령은 받아들였지만 robot ACK 가 timeout / error.

```json
{
  "v": 1,
  "id": "cmd_000020",
  "type": "command.failed",
  "sentAt": "2026-05-25T12:01:01.040Z",
  "payload": {
    "reason": "noAck",
    "message": "로봇 응답이 없습니다.",
    "lastErrorAtMs": 1000
  }
}
```

reason 코드: `noAck`, `staleCommand`, `transportError`, `safetyAbort`, `internalError`, `stopFailed`.

V297-5: `safetyAbort` 는 E-stop verification 실패 (bus nil, torque-off 미확인 등) 도
포함. `message` 필드에 verification detail (`estopVerificationFailed` 등) 포함.

## 8. 이벤트 (Server → Client, broadcast)

### 8.1 session.welcome

hello 수락 응답.

```json
{
  "v": 1,
  "id": "evt_000001",
  "type": "session.welcome",
  "sentAt": "2026-05-25T12:00:00.020Z",
  "payload": {
    "macName": "Pilot's Mac mini",
    "macVersion": "1.11.24",
    "relayProtocolVersion": 1,
    "sessionId": "ses_AB12CD",
    "heartbeatIntervalMs": 100,
    "watchdogTimeoutMs": 500
  }
}
```

### 8.2 session.rejected

hello 거부.

```json
{
  "v": 1,
  "id": "evt_000001",
  "type": "session.rejected",
  "sentAt": "2026-05-25T12:00:00.020Z",
  "payload": {
    "reason": "pairingMismatch",
    "message": "Mac 에서 새 코드를 생성하세요."
  }
}
```

### 8.3 telemetry.state

Mac → iOS 가 1Hz 이상 송신.

```json
{
  "v": 1,
  "id": "evt_000005",
  "type": "telemetry.state",
  "sentAt": "2026-05-25T12:00:01.000Z",
  "payload": {
    "mac": "connected",
    "robot": "connected",
    "endpoint": "tcp://192.168.123.1:5530",
    "armed": true,
    "dxlPower": true,
    "batteryV": 11.7,
    "maxTempC": 42,
    "latencyMs": 34,
    "lastAckAgeMs": 90,
    "safety": "ready",
    "uiState": "armedReady"
  }
}
```

값:

- `mac`: `connected` / `searching` / `lost`
- `robot`: `sim` / `connected` / `stale` / `busBusy` / `disconnected` / `estopped`
- `safety`: `ready` / `arming` / `degraded` / `estopped`
- `uiState`: `notPaired` / `macConnectedNoRobot` / `robotConnectedLocked` /
  `arming` / `armedReady` / `commandActive` / `staleStop` / `estopped`

### 8.4 arming.progress

ARM 진행 단계.

```json
{
  "v": 1,
  "id": "evt_000010",
  "type": "arming.progress",
  "sentAt": "2026-05-25T12:00:05.100Z",
  "payload": {
    "commandId": "cmd_000010",
    "stage": "enablingPower",
    "progress": 0.4
  }
}
```

stage 값: `checkingChecklist`, `enablingPower`, `engagingTorque`, `walkReadyPose`,
`armed`, `failed`.

### 8.5 transport.warning

지연/half-open 등 정보성 경고.

```json
{
  "v": 1,
  "id": "evt_000020",
  "type": "transport.warning",
  "sentAt": "2026-05-25T12:00:10.000Z",
  "payload": {
    "kind": "highLatency",
    "latencyMs": 220,
    "message": "응답이 늦어 보행 조작을 제한했어요."
  }
}
```

kind: `highLatency`, `halfOpen`, `clockSkew`, `demoBusBusy`.

### 8.6 watchdog.stop

heartbeat timeout / disconnect 로 Mac 이 stop 을 발동했음을 알린다.

```json
{
  "v": 1,
  "id": "evt_000030",
  "type": "watchdog.stop",
  "sentAt": "2026-05-25T12:00:15.000Z",
  "payload": {
    "reason": "heartbeatTimeout",
    "lastHeartbeatAgeMs": 740
  }
}
```

reason: `heartbeatTimeout`, `transportDisconnect`, `appBackground`, `pairingRevoked`.

### 8.7 log.event

UI Logs 탭에 표시할 사용자용 이벤트.

```json
{
  "v": 1,
  "id": "evt_000040",
  "type": "log.event",
  "sentAt": "2026-05-25T12:00:20.000Z",
  "payload": {
    "level": "info",
    "category": "command",
    "message": "ARM 완료",
    "commandId": "cmd_000010"
  }
}
```

level: `debug`, `info`, `warning`, `error`. category: `command`, `safety`,
`connection`, `system`.

## 9. Watchdog 정책

Mac relay 가 운영하는 watchdog 규칙. 이 정책은 iOS 가 알지만 강제하지는 않는다.

| 상황 | 동작 |
|---|---|
| heartbeat 500ms 초과 | active walk 즉시 stop, `watchdog.stop(reason=heartbeatTimeout)` |
| heartbeat 2000ms 초과 | DISARM 권장, telemetry `uiState=staleStop` |
| WebSocket close (1000~1015) | 즉시 stop, ARM 유지, `watchdog.stop(reason=transportDisconnect)` |
| pairing token 만료 | 새 hello 요구, 활성 명령 강제 종료 |
| robot ACK 600ms 초과 | 동일 명령 재전송 금지, `command.failed(reason=noAck)` |
| ROBOTIS demo 가 USB bus 점유 | 모든 motion/walk reject (`reason=busBusy`) |

## 10. 보안

MVP 보안 모델:

- 로컬 네트워크 내 only. 인터넷 노출 금지.
- pairing 코드는 6자리 숫자, 매 Mac relay 시작마다 갱신.
- 코드 3회 실패 시 5분 lockout, 새 코드 강제.
- 단일 권한 (single authority): 한 번에 한 iPhone 만 hello 수락.
- 다른 iPhone 의 hello 는 `session.rejected(reason=alreadyOwned)`.
- 권한 iPhone 의 disconnect 후 1초 grace, 그 다음 새 hello 수락.

## 11. 후방 호환

- protocol version 은 `v` 필드로 표시. MVP 는 1 만 지원.
- 모르는 type 메시지는 무시하고 `transport.warning(kind=unknownType)` 로 알림.
- 모르는 reason 코드는 `internalError` 로 fallback.
- Mac relay 는 iOS 가 보낸 unknown field 를 무시 (forward compatible).

## 12. iOS / Mac 공통 구현 책임

| 항목 | iOS 책임 | Mac 책임 |
|---|---|---|
| ID 생성 | command ID | event ID |
| ACK matching | `id` 로 pending 추적 | `id` echo |
| Heartbeat | 100ms 주기 송신 | 500ms watchdog |
| ARM gate | UI 차단 | safety gate 호출 |
| E-stop | UI 즉시 전환 | `ConnectionStore.emergencyStop()` |
| pilot.walk | preset 매핑은 schema 기준 송신 | 실제 robot 명령 변환 권위 |
| sim/review mode | UI badge | `command.rejected(reason=simulated)` |

## 13. 변경 이력

- 2026-05-25 — v1 초안 (이 문서)
- 2026-05-25 — v1.1 truth-gap fix:
  - `pilot.walk` payload 에 `speedScale` 필드 추가 (server 측 optional, 기본 1.0)
  - `WalkPreset.freeform` 인터페이스 정의 (서버 측 highRiskNotAllowed reject — 첫 빌드)
  - `pilot.head` 명령 신설 (`enabled/panDeg/tiltDeg/tracking`)
  - `bow/slot 41` 제거 — slot 41 은 `talk2` long-chain
  - watchdog tracking: server 가 walk accepted 시 `activeCommandId` 즉시 설정
  - pairing flow: discovery tap 후 사용자 6자리 코드 입력 필수 (자동 "000000" 제거)
- 2026-05-26 — v1.2 audit + GPT review fix (V297-4 + V297-5):
  - **응답 흐름 명시 (§7)**: `command.accepted` 가 interim event, terminal 응답 (ack/rejected/failed)
    이 정확히 하나. 종전 문서가 "4종 중 하나" 표현이라 구현과 불일치였음.
  - **priority commands (§7)**: `pilot.estop` / `pilot.stop` 는 transport layer 에서 우회 dispatch.
    long-running command 의 actor 점유에 막히지 않음.
  - **새 reason 코드 등록 (§7.2)**: `lowBattery`, `clockSkew`, `highRiskNotAllowed`,
    `dxlPowerOff`, `headUnsupportedInMVP`, `preflightFailed`, `walkSessionUnavailable`,
    `cradleRequired`, `invalidSlot`, `armFailed`. iOS 는 forward-compat 위해 `.unknown` fallback.
  - **`WelcomePayload.capabilities` 신설 (§8.1)**: `head/walkFreeform/speedScaleAccepted` flag.
    iOS 가 capability 보고 미지원 명령 UI 진입점 숨김.
  - **reconnect identity (§5)**: `HelloPayload.deviceId` 가 stable identifier. Wi-Fi 깜빡임
    재연결은 동일 deviceId 매칭으로 인정 — sessionId 보존.
  - **latency gate (§4 재확정)**: 서버측 robot ACK round-trip 기반 (iOS clock 사용 금지).
    clockSkew 는 ±10초 양방향 검사.
  - **transport.warning(highLatency) (§8.5)**: reject 임계의 2/3 도달시 informational warning.
  - **E-stop verification (§6.5)**: server 가 torque-off 검증 후에만 `command.ack`. 검증 실패시
    `command.failed(reason=safetyAbort)`.
