# Telemetry Harness — Real-Robot Session Recorder

> 실 로봇 동작 세션 동안 일어나는 모든 일을 빠짐없이, 그러나 가볍게 기록해서
> 프로그램 개선 근거로 쓰는 시스템. 이름은 "Harness"이지만 케이블 하네스
> (`docs/harness/engineering-foundations.md`) 와 별개의 소프트웨어 계측 계층.

**상태**: v1.0 — 2026-05-20 도입
**책임자**: DarwinForge UI / Logging 모듈
**저장 위치**: `~/Library/Application Support/DarwinForge/Harness/`

---

## 1. 목표 (왜 만드는가)

실 로봇 빌드/조작 세션 중 발생하는 사건을 **사후 재구성 가능한 수준**으로 기록한다.

| 질문 | 기존 (DFLog/OSLog) | 텔레메트리 하네스 |
|------|-------------------|------------------|
| 어제 17시에 연결됐었나? | Console.app 검색 필요, 휘발성 | 세션 파일 그대로 |
| "Walk Lab 시작" 눌렀을 때 IMU 상태는? | 별도 기록 없음 | 같은 시각 heartbeat snapshot |
| 모터 X 가 응답 안 했을 때 사용자가 직전 무엇을 눌렀나? | 추적 불가 | 직전 UI 이벤트 + bus 실패 이벤트 |
| 이 빌드에서 평균 RTT 와 실패율은? | OSLog 통계 없음 | 세션 export → 집계 |

비목표:
- 프로덕션 telemetry 전송 (앱은 오프라인 우선, 모두 로컬 디스크)
- 무한 보존 (최근 30 세션 자동 회수)
- PII 수집 (이름/네트워크 호스트 IP 마지막 옥텟 등은 redaction)

---

## 2. 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│ UI Layer (RootView / WalkLabView / MotionStudio / Pilot)    │
│  ↓ Harness.record(.ui.sectionChanged(...))                  │
│  ↓ Harness.record(.connection.success(endpoint:...))        │
└─────────────────────────────────────────────────────────────┘
                          │
┌─────────────────────────────────────────────────────────────┐
│ Harness (public façade, @MainActor entry, Sendable events)  │
│   • record(_:) — non-blocking, enqueues to writer           │
│   • currentSession / openSessionDirectory()                 │
│   • exportSession(_:) — zip of JSONL + metadata             │
└─────────────────────────────────────────────────────────────┘
            │ async queue (AsyncStream<TelemetryEvent>)
            ▼
┌─────────────────────────────────────────────────────────────┐
│ TelemetryRecorder (background actor)                        │
│   • 단일 file handle, append-only JSONL                     │
│   • 250 ms 또는 64 event 배치 fsync                         │
│   • 50 MB 도달 시 자동 rotation (.1, .2, ...)               │
│   • drop counter (buffer overflow 시)                       │
└─────────────────────────────────────────────────────────────┘
            ▲
            │ 1 Hz heartbeat
┌─────────────────────────────────────────────────────────────┐
│ HeartbeatSampler                                            │
│   • ConnectionStore @Published 스냅샷 → record(.heartbeat)  │
│   • 연결 안 됐을 때도 idle heartbeat (10 s 주기)            │
└─────────────────────────────────────────────────────────────┘
```

핵심 원칙:
- **UI 스레드 절대 안 막음** — `record()` 호출은 enqueue 후 즉시 반환.
- **세션 = 앱 실행 한 번** — UUID 부여, 시작/종료 이벤트로 경계 마킹.
- **append-only** — 크래시 시 마지막 fsync 전 일부 손실 허용, 이전 데이터 보존.
- **schema versioning** — 첫 줄에 `{"schema_version": 1, "session": ...}` meta record.

---

## 3. Event Schema

```jsonc
{
  "v": 1,                            // schema version
  "s": "0F3A...UUID",                // session id (UUID, 첫 8자 표시용)
  "i": 12345,                        // monotonic sequence within session
  "tw": "2026-05-20T21:00:00.123Z",  // wall clock ISO-8601 (ms 정밀도)
  "tm": 5234567890,                  // monotonic clock nanoseconds (since boot)
  "k": "connection.success",         // kind (dot.namespace.event)
  "lv": "info",                      // level: trace|info|notice|warn|error
  "a": "user",                       // actor: user|system|robot|claude
  "d": { /* kind-specific payload */ },
  "c": {                             // context snapshot (compact)
    "cn": "connected",               // connection: connected|connecting|disconnected|error
    "ep": "net:10.0.0.x:5530",       // endpoint (redacted last octet)
    "sc": "studio",                  // section
    "bv": 11.4,                      // battery V (nil 가능)
    "rt": 12.4,                      // last RTT ms (nil 가능)
    "im": false                      // imu_stale (key `im`, `is` 는 Swift 예약어)
  }
}
```

**짧은 키**(`v`, `s`, `i`, `tw`, …) — 100 K event/세션 시 디스크 절약. Decoder/Inspector 가 표시할 때 풀어 보여줌.

### 3.1 Event Taxonomy (네임스페이스 도트 표기)

| Namespace | Kinds | Payload 예 |
|-----------|-------|-----------|
| `app` | `launch`, `terminate`, `foreground`, `background`, `version_info` | `{ "build": "1.11.23" }` |
| `connection` | `attempt`, `success`, `failure`, `disconnect`, `reconnect_start`, `reconnect_attempt`, `endpoint_switch` | `{ "endpoint_kind": "usb", "reason": "..." }` |
| `bus` | `read_fail`, `write_fail`, `recovered`, `e_stop`, `e_stop_recover` | `{ "joint": "HeadPan", "err": "timeout" }` |
| `imu` | `stale`, `unavailable`, `recovered`, `scale_changed` | `{ "consec_fail": 4, "stale_for_s": 8.2 }` |
| `ui` | `section_changed`, `tab_changed`, `palette_opened`, `palette_command`, `wizard_opened`, `dashboard_opened`, `dialog_shown`, `button_tapped` | `{ "from": "studio", "to": "walkLab" }` |
| `motion` | `load`, `play_start`, `play_complete`, `play_abort`, `record_start`, `record_stop` | `{ "page_id": 12, "step_count": 8 }` |
| `walklab` | `start`, `stop`, `emergency_stop`, `config_change`, `preset_applied`, `experiment_start`, `experiment_complete` | `{ "preset": "smooth-default" }` |
| `pose` | `apply_start`, `apply_complete`, `apply_failed`, `cancel` | `{ "joints": 6, "profile": "smooth", "ms": 942 }` |
| `pilot` | `mode_changed`, `dpad`, `head_track_on`, `head_track_off`, `e_stop` | `{ "mode": "walk" }` |
| `teach` | `capture_start`, `capture_stop`, `pose_recorded` | `{ "duration_s": 4.2 }` |
| `claude` | `prompt_sent`, `response_received`, `tool_invoked`, `error` | `{ "turn": 7, "input_tokens": 1234 }` (raw text **X**) |
| `heartbeat` | `tick` | full context block; data 비움 |
| `error` | `exception`, `boundary` | `{ "msg": "...", "file": "...", "line": 42 }` |

### 3.2 Redaction Rules

- 네트워크 IP/호스트 → `net:<v4-redacted>:port` (마지막 옥텟 `x` 마스킹)
- 사용자 입력 텍스트 → 길이/토큰 수만; 본문 X
- Claude API 응답 본문 → 토큰 수, error code 만
- 파일 시스템 경로 → home directory `~` 치환

---

## 4. Persistence Layout

```
~/Library/Application Support/DarwinForge/Harness/
├── current/                       # 진행 중 세션 (앱 종료 시 sessions/ 로 이동)
│   ├── 0F3A...-meta.json
│   └── 0F3A...-events.jsonl
├── sessions/
│   ├── 0F3A...-2026-05-20T21-00-events.jsonl
│   ├── 0F3A...-2026-05-20T21-00-meta.json
│   ├── 9B12...-2026-05-19T10-12-events.jsonl
│   └── ...                        # 최대 30개 유지, 오래된 것 자동 삭제
└── index.json                     # 세션 메타 인덱스 (id/시작/끝/이벤트 수/크기)
```

`index.json`:
```jsonc
{
  "schema": 1,
  "sessions": [
    {
      "id": "0F3A...",
      "started": "2026-05-20T21:00:00Z",
      "ended": "2026-05-20T21:34:12Z",
      "event_count": 8421,
      "size_bytes": 1432109,
      "app_version": "1.11.23",
      "connect_count": 3,
      "error_count": 2
    },
    ...
  ]
}
```

회수 규칙:
- 30 세션 또는 500 MB 도달 시 가장 오래된 세션 삭제
- "Pin" 된 세션 (`meta.pinned = true`) 은 회수 제외 — 디버깅용 표시

---

## 5. Performance Budget

| 항목 | 한도 | 측정 방법 |
|------|------|----------|
| `Harness.record()` 호출 비용 | < 50 µs (UI thread) | XCTMetric (Tests/) |
| 1 세션 평균 event 율 | 5-20 events/s | heartbeat 1Hz + UI 산발 |
| 1 세션 평균 디스크 | < 5 MB / 시간 | gzipped baseline |
| 메모리 (in-flight queue) | < 1 MB | drop counter trigger |
| 디스크 fsync 주기 | 250 ms 또는 64 event | 둘 중 먼저 |

오버플로 시: 가장 낮은 우선순위(heartbeat) 부터 drop, drop counter 누적 → 다음 record 직전 `harness.dropped` event 로 발행.

---

## 6. In-App Inspector

위치: Expert 탭 → 새 sub-tab "Harness" (또는 Settings).

기능:
1. **Live tail** — 최근 200 event 스트림, kind 필터, level 필터
2. **Session list** — 현재 + 과거 세션, 정렬(시간/크기/오류수)
3. **Session detail** — meta + 이벤트 카운트 by namespace
4. **Export** — "Finder에서 보기" / "ZIP으로 내보내기" / "Pin"
5. **Manual marker** — 사용자가 "여기 문제 발생" 마커 삽입 (`user.bookmark` event)

내보낸 ZIP 구조 (개선 검토용 공유):
```
session-0F3A-2026-05-20.zip
├── meta.json
├── events.jsonl
├── app-version.txt
└── README.md  (시각 + redaction 안내)
```

---

## 7. 통합 포인트 (Phase 1, MVP)

본 v1.0 에서 instrument 할 최소 핵심:

1. **`DarwinForgeApp.swift`** — `app.launch` / `terminate` / `foreground` / `background`
2. **`ConnectionStore`** — `connection.*`, `bus.*`, `imu.*`, heartbeat sampler 시동
3. **`RootView`** — `ui.section_changed`, `ui.palette_opened`, `ui.wizard_opened`, `ui.dashboard_opened`
4. **`WalkLabSession`** — `walklab.*` (start/stop/emergency_stop/preset)
5. **`MotionStudioView` / `MotionPlayer`** — `motion.play_start`/`complete`/`abort`
6. **`RemotePilotView`** — `pilot.mode_changed`, `pilot.e_stop`
7. **`ConversationViewModel`** — `claude.prompt_sent`, `claude.response_received` (토큰 카운트만)
8. **`applyPoseSmoothly`** — `pose.apply_*`

Phase 2 (후속 PR): Teach 모드, Studio 인스펙터, Expert 탭 세부 인터랙션, Claude tool-use 흐름.

---

## 8. Schema Evolution

- 새 필드: optional 로 추가 (decoder forward-compat)
- 새 kind: enum 에 case 추가, decoder 가 모르는 kind 는 `unknown` 으로 폴백
- breaking change: `schema_version` bump + meta.json 에 `min_reader_version` 명시
- 모든 decoder 는 unknown 필드 무시 (`decodeIfPresent`)

---

## 9. Privacy & Consent

- 첫 실행 시 "이 데이터는 모두 이 Mac 에 로컬 저장되며, 사용자가 명시적으로 export 하기 전엔 외부 전송되지 않습니다." 1-time 토스트
- Settings 에 "텔레메트리 비활성화" 토글 — 비활성 시 record() no-op, 기존 세션 보존
- "모든 세션 삭제" 버튼

---

## 10. 향후 확장 (out-of-scope, v2)

- 세션 cross-session aggregation 대시보드 (평균 RTT, 일별 에러 수)
- Claude 가 `harness.summarize_session(id)` tool 로 세션 요약
- 두 세션 diff (변경 전/후 비교)
- 실 로봇 빌드 체크리스트 (`first_connect`, `walked_3_steps`, `emergency_stop_works`) 자동 마킹
- Optional opt-in 익명 통계 업로드 (분기점 결정 필요)
