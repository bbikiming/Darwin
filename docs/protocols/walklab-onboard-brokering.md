# WalkLab ↔ ROBOTIS Onboard Brokering Protocol

**작성**: 2026-05-20 (v1.11.24 audit)
**상태**: 활성 — Mac DarwinForge ↔ robot-side patched `demo-pilot` 간 단일 source-of-truth.

> 본 문서는 `docs/diagnosis/WALKLAB_REAL_ROBOT_MOTION_FAILURE_AUDIT_2026-05-20.md` 의 P1-4
> 후속 — 기존에 코드 / README / 헤더 주석에 흩어져 있던 protocol 설명을 모은다.

---

## 1. 경로 (Mac → robot)

| 항목 | 값 |
|---|---|
| SSH 채널 | `RemoteShell` (host=192.168.123.1 기본) |
| 명령 파일 | `/tmp/df-walklab-cmd` (Mac 가 atomic mv 로 write) |
| ACK 파일 | `/tmp/df-walklab-ack` (robot-side daemon 가 write) |
| 모드 파일 | `/tmp/df-pilot-mode` (`walklab` 일 때 brokering 활성) |
| 폴링 주기 | robot-side 5Hz (200ms) |

## 2. 명령 라인 포맷

```
{cmd_id} {enabled} {x_mm} {y_mm} {a_deg} {period_ms} {foot_mm} {hip_pitch_deg}
```

- 필드 8개. 공백 1칸 구분. trailing newline 1개.
- `cmd_id`: 12자 nonce (UUID prefix 8 + ms epoch 4). stale ACK 차단용.
- `enabled`: `0` 또는 `1`. 0 이면 robot 측이 `X/Y/A_MOVE_AMPLITUDE = 0` set.
- `x_mm`/`y_mm`: 전진/측면 보폭 (mm, ROBOTIS Walking module 스케일).
- `a_deg`: 회전 (°). robot 측이 rad 변환.
- `period_ms`: 보행 cycle 주기.
- `foot_mm`: 발 들기 높이.
- `hip_pitch_deg`: HIP_PITCH_OFFSET trim (deg).

예시 (cmd_id 가 `abc12345-0001` 인 fastWalk):

```
abc12345-0001 1 38.0 0.0 0.0 450 46 13.0
```

## 3. ACK 라인 포맷

robot-side daemon (`demo-pilot` patched) 는 명령 처리 후 `/tmp/df-walklab-ack` 에 한 줄
echo:

```
OK {ts_ms} {cmd_id} {line}
```

- `OK` 는 처리 성공.
- `ts_ms`: robot epoch ms.
- `cmd_id`: Mac 의 명령에서 받은 nonce 그대로.
- `line`: 명령 line 8필드를 그대로 echo (디버깅).

Backward-compat: firmware v1.11.16.1 (pre cmd_id) 은 다음 포맷도 허용 — Bridge 가 매치
강제 X.

```
OK {ts_ms} {line}
```

ACK 가 timeout 안에 안 오거나 `cmd_id` 가 불일치하면 Mac 측 `WalkLabOnboardBridge.handleSendResult`
가 stale 로 분류 → `onboardConsecutiveFailures += 1`. 임계 도달 시 자동 fallback.

## 4. 시작 precondition (v1.11.24 audit P1-3)

WalkLab 가 `walkingEngine == .robotisOnboard` 로 보행을 시작하려면 다음을 모두 통과해야
`onboardWalkingActive=true` 가 된다.

1. `store.bus != nil` — SSH 채널 활성 (`RemoteShell` 연결).
2. `autoOnboardBrokering=true` — UI 토글 ON.
3. `cradleConfirmed=true` — 안전 절차.
4. ACK 가 첫 명령 송출 후 timeout 안에 echo — Bridge 가 `onboardAckStatus` 갱신.

위 4번까지 통과하기 전엔 `onboardAckStatus = "pending"` 으로 표시되며, 실패 시 다음 값으로
설정:

- `"ok"` — ACK 매치 성공.
- `"no_ack"` — firmware backward-compat (cmd_id 없는 ACK).
- `"timeout"` — ACK 가 안 옴.
- `"error: ..."` — SSH 에러.

## 5. 자주 묻는 오작동 진단

| 증상 | 원인 후보 | 확인 |
|---|---|---|
| UI active, robot 미동작 | autoOnboardBrokering OFF | `WalkLabOnboardBridge` 토글 |
| UI active, robot 미동작 | demo-pilot patch 미설치 | robot 측 `ls /tmp/df-walklab-cmd` |
| UI active, robot 미동작 | `/tmp/df-pilot-mode != walklab` | robot 측 `cat /tmp/df-pilot-mode` |
| 명령 무시 | 구버전 patch (cmd_id 미지원) | ACK 포맷 확인 |
| 일부 명령만 처리 | SSH latency spike | `onboardConsecutiveFailures` |

## 6. 관련 코드

| 책임 | 파일 |
|---|---|
| Mac 측 SSH 송출 | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/WalkLabOnboardBridge.swift` |
| 명령 라인 합성 | `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RobotSetupCommand.swift` (`walkLabRobotisSendCommand`) |
| 시작 precondition | `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift` (`startWalkCycle` 의 `robotisOnboard` 분기) |
| robot 측 daemon | (별도 repo / patch — `demo-pilot` fork) |
