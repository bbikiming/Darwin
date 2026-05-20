# Telemetry Harness — 실 로봇 연결 검증 가이드

> 이 문서는 **로그 시스템이 실제로 동작한다는 증거**와 **무엇이 어디에 어떻게 기록되는지** 의 단일 참고 자료. 향후 디버깅 / 새 hook 추가 / 회귀 의심 시 가장 먼저 보는 곳.
>
> **검증 일자**: 2026-05-20  ·  **하네스 버전**: v1.13.1  ·  **앱 빌드**: dev (0.0.0 / build 0)

---

## 1. TL;DR (5초 만에 보는 검증 결과)

| 검증 항목 | 결과 | 증거 |
|----------|------|------|
| 앱 시작 시 세션 디렉토리 자동 생성 | ✅ | `~/Library/Application Support/DarwinForge/Harness/current-<UUID>/` 생성 확인 |
| 첫 이벤트 (`app.launch`) 디스크 기록 | ✅ | events.jsonl line 1, meta.eventCount=7 |
| heartbeat 1Hz / idle 10s 주기 | ✅ | idle 60초 동안 4개 heartbeat 기록 |
| `app.foreground` / `app.background` notification hook | ✅ | NSApp 활성/비활성에 매핑 |
| context 스냅샷 (`cn`, `im`) 모든 이벤트에 첨부 | ✅ | events.jsonl line 1-7 모두 `c` 필드 존재 |
| meta.json 실시간 갱신 (eventCount/sizeBytes) | ✅ | flush 마다 atomic write |
| ConnectionStore.connect → connection.attempt + failure 디스크 도달 | ✅ | `HarnessRealRobotSmokeTests.testConnectionStoreEmitsAttemptAndFailureToDisk` |
| PII redaction (raw endpoint path 누출 X) | ✅ | smoke test (4) — raw fake path 가 payload 에 없음 |
| 1000 event burst — drop 없음, 순서 보존 | ✅ | smoke test `testBurstPreservesOrderingAndStaysBounded` |
| Heartbeat Timer 가 디스크까지 도달 | ✅ | smoke test `testHeartbeatTimerDeliversToDisk` |
| Context provider 가 ConnectionStore 상태 첨부 | ✅ | smoke test `testContextProviderAttachesSnapshot` |
| `stop()` 호출 시 `meta.ended` 채워짐 | ✅ | smoke test `testMetaAccumulatesAndFinalizesOnStop` |

**총 검증 테스트**: 15 단위 + 6 end-to-end smoke + 4 디스크 integration + 10 분석 = **35 harness 전용**.
**전체 회귀**: 710 / 710 pass.

---

## 2. 저장 위치 — 어디를 봐야 하는가?

```
~/Library/Application Support/DarwinForge/Harness/
├── current-<UUID>/                 # 진행 중 세션 (앱 실행 중)
│   ├── events.jsonl                # ← 모든 이벤트 (한 줄 = 한 이벤트)
│   └── meta.json                   # ← 카운터 / 시작 / 종료 / 사이즈
├── sessions/                       # 종료된 세션 (자동 archive)
│   ├── <UUID-from-current>/        # current-* 가 그대로 이름 변경
│   │   ├── events.jsonl
│   │   └── meta.json
│   └── ...                         # 최대 30개 유지, 500 MB cap
└── analyses/                       # (사용자 export 위치)
```

**비정상 종료 복구**: `current-*` 폴더가 남아 있으면 다음 앱 시동 시 `TelemetryStore.archiveOrphanedSessions()` 가 자동으로 `sessions/` 로 옮김. 즉 `kill -9` 로 죽여도 데이터 보존.

---

## 3. 실 로봇 연결 시 어떤 이벤트가 어디서 발화되는지 — Hook 매핑 표

각 행은 "사용자/시스템 액션 → 발화되는 telemetry kind → 발화 위치 (file:line)" 매핑.

### 3.1 앱 라이프사이클

| 액션 | Kind | 위치 |
|------|------|------|
| 앱 실행 | `app.launch` | [Harness.swift:130](../app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/Harness.swift) — `start()` 안 |
| 앱 활성화 (창 클릭/`⌘Tab`) | `app.foreground` | NSApp.didBecomeActive notification |
| 앱 비활성화 (다른 앱으로 전환) | `app.background` | NSApp.willResignActive notification |
| 앱 종료 (`⌘Q`) | `app.terminate` | NSApp.willTerminate notification + `stop()` |

### 3.2 연결 라이프사이클 (실 로봇 인터랙션의 핵심)

| 액션 | Kind | 위치 |
|------|------|------|
| 사용자가 USB 자동 연결 / IP 직접 입력 / Wizard 진입 | `connection.attempt` | [ConnectionStore.swift:308](../app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift) — `connect(endpoint:)` 직후 |
| Bus 핸들 정상 + boardSnapshot RTT 측정 성공 | `connection.success` (info `rtt_ms`, `attempt`, `endpoint`, `endpoint_kind`) | performConnect 의 성공 분기 |
| 3회 재시도 모두 실패 | `connection.failure` (info `attempts`, `error_len`, `error_hash`) | performConnect 의 종료 후 |
| 사용자가 명시 disconnect | `connection.disconnect` (info `uptime_s`, `success_count`, `failure_count`) | `disconnect()` 진입 시 |
| 네트워크 endpoint 자동 재연결 시작 | `connection.reconnect_start` (정의되어 있으나 현재 미발화 — 필요시 wire) | TODO |
| Bus read throw (개별 motor) | `bus.read_fail` (warn) — `consecutive`, `error_len`, `error_hash` | `handleBusError(_:)` |
| E-stop 발동 (사용자 ⌘⇧. 또는 메뉴) | `bus.e_stop` (error) — `source` | `emergencyStop()` 진입 |
| E-stop 직후 bus.emergencyStop throw | `bus.write_fail` (error) — `op`, `error_*` | emergencyStop catch |

### 3.3 IMU 라이프사이클

| 액션 | Kind | 위치 |
|------|------|------|
| IMU 5초+ 지연 (heartbeat 가 stale 첨부) | (별도 발화 X — context.im=true 로 모든 이벤트에 자동 첨부) | `harnessContext()` |
| (예약) IMU 3회 연속 실패 | `imu.unavailable` | TODO — 현재는 `walklab.start_blocked` reason 으로만 |

### 3.4 UI 인터랙션

| 액션 | Kind | 위치 |
|------|------|------|
| Section 변경 (사이드바/`⌘1..7`/메뉴) | `ui.section_changed` (data `to`) | [RootView.swift](../app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift) `.onChange(of: section)` |
| 명령 팔레트 (`⌘K`) | `ui.palette_opened` | RootView `.onReceive(.dfOpenPalette)` |
| 북마크 추가 (Inspector "북마크" 버튼) | `user.bookmark` (data `len`, `hash`) | `Harness.bookmark(_:)` |

### 3.5 WalkLab (실 로봇 보행 — 가장 중요한 진단 영역)

| 액션 | Kind | 위치 |
|------|------|------|
| 사용자가 preset 클릭 → quickPreflight 차단 | `walklab.start_blocked` (warn, reason 코드) | [WalkLabSession.swift:802](../app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift) |
| startWalkCycle 안 5종 race guard (이미 보행 중 / bus race / cradle race / SSH / brokering) 차단 | `walklab.start_blocked` (각 reason) | startWalkCycle 5곳 |
| 모든 safety guard 통과 → 실 motor Task 시작 직전 | `walklab.start` (notice) — `preset`, `engine`, `advanced`, `mode` (continuous/kickChain/robotisOnboard) | 3 군데 (continuous/kick/onboard) |
| 정상 정지 | `walklab.stop` (notice) — `duration_s`, `preset` | `stop()` |
| 비상 정지 | `walklab.emergency_stop` (error) — `tilt_deg`, `fall_score`, `preset` | `emergencyStop()` |
| ROBOTIS Onboard ACK 도착 | `walklab.onboard_ack` (정의 됨, bridge wiring 예약) | TODO — `WalkLabOnboardBridge` |

### 3.6 Motion Studio

| 액션 | Kind | 위치 |
|------|------|------|
| 페이지 추가 | `motion.page_created` (`page_id`, `name_hash`, `total_pages`) | [MotionStudioView.swift](../app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionStudioView.swift) `addPage()` |
| 페이지 삭제 | `motion.page_deleted` | `deletePage(at:)` |
| 페이지 이름 변경 | `motion.page_renamed` (`from_hash`, `to_hash`) | `renamePage(at:to:)` |
| Play 버튼 | `motion.play_start` (`page_id`, `page_name_hash`, `step_count`, `duration_ms`) | [MotionPlayer.swift](../app/ui/DarwinForge/Sources/DarwinForgeUI/Motion/MotionPlayer.swift) `play()` |
| 자연 종료 (loop=false 페이지 끝) | `motion.play_complete` (`elapsed_ms`) | `recompute()` — `mode == .playing` 가드 |
| 사용자 Stop / 새 페이지 load | `motion.play_abort` | `stop()` |

### 3.7 Teach 모드 (자세 캡쳐)

| 액션 | Kind | 위치 |
|------|------|------|
| 200ms polling 시작 | `teach.capture_start` (`connected`) | [TeachCapture.swift](../app/ui/DarwinForge/Sources/DarwinForgeUI/Teach/TeachCapture.swift) `startCapture()` |
| polling 정지 | `teach.capture_stop` (`snapshot_count`, `consec_failures`) | `stopCapture()` |
| 스냅샷 저장 ("자세 N") | `teach.snapshot_captured` (notice, `snapshot_id`, `name_hash`, `name_len`, `name_was_default`, `joint_count`) | `snapshot(name:)` |
| 스냅샷 삭제 | `teach.snapshot_deleted` | `deleteSnapshot(_:)` |
| 스냅샷 전부 비움 | `teach.snapshots_cleared` (`count_before`) | `clearSnapshots()` |
| 스냅샷을 로봇에 적용 | `teach.snapshot_applied` (notice, `bus_connected`) | `applySnapshot(_:store:)` |
| UserPoseLibrary 영구 저장 (북마크 아이콘) | `pose.library_saved` (notice, `snapshot_id`, `name_hash`, `library_size_after`) | [TeachModeView.swift:291](../app/ui/DarwinForge/Sources/DarwinForgeUI/Teach/TeachModeView.swift) |

### 3.8 자세 적용 (Studio / Conversation 의 "이 자세 적용")

| 결과 | Kind | 위치 |
|------|------|------|
| 적용 시작 | `pose.apply_start` (info, `joints`, `profile`) | [ConnectionStore.swift](../app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift) `applyPoseSmoothly` 진입 |
| 완료 | `pose.apply_complete` (`elapsed_ms`) | `recordPoseTerminal()` |
| Partial (상체만 일부 실패) | `pose.apply_complete` (warn, `partial=true`, 카운터) | 동일 |
| Bus 미연결 | `pose.apply_failed` (warn, `reason='notConnected'`) | 동일 |
| SafeMotion verify 거부 | `pose.apply_failed` (warn, `reason='rejected'`, `reason_hash`) | 동일 |
| 사용자 cancel / e-stop | `pose.apply_cancel` (info) | 동일 |
| 쓰기 실패 (하체 critical) | `pose.apply_failed` (error, `reason='writeFailed'`, `position_failed`, `speed_failed`) | 동일 |
| Critical load watchdog | `pose.apply_failed` (error, `reason='criticalLoad'`, `joint`) | 동일 |

### 3.9 대화 (Claude)

| 액션 | Kind | 위치 |
|------|------|------|
| 사용자가 input 보냄 | `claude.prompt_sent` (info, `text_length`, `turn`) — 본문 X | [ConversationViewModel.swift:65](../app/ui/DarwinForge/Sources/DarwinForgeUI/Conversation/ConversationViewModel.swift) |
| (예약) 응답 수신 | `claude.response_received` (정의 됨, wiring 예약) | TODO |

### 3.10 시스템 / 텔레메트리 자체

| 액션 | Kind | 위치 |
|------|------|------|
| 1 Hz heartbeat (연결 시) / 10s heartbeat (idle) | `heartbeat.tick` (trace, payload 비움 — context 만 의미) | `Harness.emitHeartbeat()` |
| AsyncStream buffer 초과 — N event drop | `harness.dropped` (warn, `count`) | 100마다 + stop 시 force |
| (예약) 예외 캡쳐 | `error.exception` | TODO — error boundary 미설치 |

---

## 4. Context 스냅샷 — 모든 이벤트에 자동 첨부되는 상태

`event.c` 블록은 다음 6 필드. ConnectionStore 가 등록한 provider 가 매 record 호출 시 실행.

```jsonc
{
  "cn": "connected" | "connecting" | "disconnected" | "error",
  "ep": "usb:tty.usb-X" | "net:10.0.0.x:5530" | null,    // PII redacted
  "sc": "studio" | "walkLab" | ... | null,
  "bv": 11.4,                                              // 배터리 V
  "rt": 12.4,                                              // 마지막 RTT ms
  "im": true | false                                       // IMU stale flag
}
```

> **Why 이 6개?** 사후 디버깅의 99% 질문이 "그 이벤트 발생 시점에 (a) 연결돼 있었나 (b) 어느 메뉴였나 (c) 배터리 / RTT / IMU 상태 어땠나" 로 환원. 한 번 첨부하면 다른 이벤트 join 없이 즉답.

---

## 5. 실 로봇 연결 검증 절차 (10분)

향후 회귀 의심 시 같은 절차를 그대로 따라 실 동작 확인.

### 5.1 사전 정리

```bash
# 기존 진행 중 세션 archive 트리거 (또는 손으로 cleanup).
rm -rf "$HOME/Library/Application Support/DarwinForge/Harness/current-"*
ls "$HOME/Library/Application Support/DarwinForge/Harness/"
# 결과: sessions/  analyses/ (있을 수 있음, 둘 다 없어도 무관)
```

### 5.2 앱 시동

```bash
cd app/ui/DarwinForge
swift build  # 0 errors 확인
./.build/arm64-apple-macosx/debug/DarwinForgeApp &
APP_PID=$!
sleep 5
ls "$HOME/Library/Application Support/DarwinForge/Harness/"
# 기대: current-<UUID>/ 디렉토리 한 개 생성됨.
```

### 5.3 실 로봇 연결 (USB 또는 네트워크)

앱 UI에서:
1. 사이드바 또는 toolbar 의 "Auto Connect" 클릭, 혹은
2. `⌘⇧C` 단축키 (메뉴 `로봇 → 자동 USB 연결`)

성공/실패와 무관하게 다음 이벤트가 디스크에 떨어져야 함.

### 5.4 디스크 검증

```bash
SESSION=$(find "$HOME/Library/Application Support/DarwinForge/Harness/" -name "current-*" -type d | head -1)
echo "Session: $SESSION"
cat "$SESSION/meta.json"
echo "--- last 20 events ---"
tail -20 "$SESSION/events.jsonl" | jq -c '{i, k, lv, a, c}'
```

기대 출력 패턴:
```json
{"i":1,"k":"app.launch","lv":"notice","a":"system","c":{"cn":"disconnected","im":false}}
{"i":2,"k":"app.foreground","lv":"info","a":"system","c":{"cn":"disconnected","im":false}}
{"i":3,"k":"connection.attempt","lv":"info","a":"user","c":{"cn":"connecting","ep":"usb:tty.usb-X","im":false}}
{"i":4,"k":"connection.success","lv":"notice","a":"system","c":{"cn":"connected","ep":"usb:tty.usb-X","bv":11.4,"rt":7.2,"im":false}}
{"i":5,"k":"heartbeat.tick","lv":"trace","a":"system","c":{"cn":"connected","ep":"usb:tty.usb-X","bv":11.4,"rt":8.1,"im":false}}
...
```

### 5.5 In-app 확인 (Inspector UI)

앱에서 `⌘7` (전문가 모드) → **텔레메트리** 탭. 아래 모두 정상이어야 함:
- 좌측 패널: "진행 중: <id>" 녹색 점.
- 우측 패널: Live tail — 1초마다 새 이벤트 추가, 디스크 사용량 / flush 시각 갱신.
- 과거 세션 클릭하면 자동 분석 (통계 카드 + 타임라인 strip + namespace 범례).
- "에러 둘러보기 (N)" 버튼 — error/warn 이벤트가 있으면 N>0, 클릭 시 시트 표시.

### 5.6 종료 + archive 검증

```bash
# UI 의 ⌘Q 또는 dock 종료.
sleep 2
ls "$HOME/Library/Application Support/DarwinForge/Harness/sessions/" | tail -3
# 기대: 방금 종료한 세션이 sessions/ 로 archive 됨.
cat "$HOME/Library/Application Support/DarwinForge/Harness/sessions/<UUID>/meta.json" | jq '.ended'
# 기대: "2026-05-20T..." (null 아님).
```

---

## 6. 트러블슈팅 (실 로봇 디버깅 시 자주 나오는 질문)

### Q1. 연결 시도가 events.jsonl 에 안 보임.
1. `Harness.shared.isEnabled == false` 인지 확인. Inspector 좌측 하단 "기록 활성" 토글.
2. ConnectionStore 인스턴스가 `init()` 에서 `Harness.shared.registerContextProvider` 호출했는지 — 외부에서 직접 만든 인스턴스는 등록 안 됐을 수 있음.
3. `swift test --filter HarnessRealRobotSmokeTests` 가 그린이면 chain 자체는 정상. 호출 site 누락 여지.

### Q2. RTT / 배터리가 context 에 안 잡힘.
1. `ConnectionStore.lastTelemetry` 가 nil — telemetry polling 이 시작 안 됨. `startTelemetry(cadence:)` 가 connect 성공 후 호출되는지 확인.
2. `lastRoundTripMs` 는 boardSnapshot 첫 측정 후에만 채워짐. 첫 측정 전 hook 발화 시 nil.

### Q3. events.jsonl 가 너무 크다.
1. 50 MB 도달 시 자동 rotation — `events.1.jsonl`, `events.2.jsonl`. `HarnessFileReader.loadSessionEvents` 가 모두 시간순 병합.
2. 30 세션 또는 500 MB 도달 시 오래된 세션부터 자동 삭제 (`pinned: true` 제외).
3. 진단용 보존 필요하면 Inspector 에서 "핀 고정" 버튼.

### Q4. e-stop 직전 무엇이 일어났는지 알고 싶음.
1. Inspector → 해당 세션 선택 → "에러 둘러보기 (N)" 클릭.
2. `bus.e_stop` envelope 펼치면 직전 5개 + 직후 5개 이벤트 + payload + context 표시.
3. 또는 `SessionMarkdownReport.render(...)` 로 markdown export — envelope 가 코드 블록 안에 정리되어 Claude 에 그대로 붙여 넣기 가능.

### Q5. `current-*` 가 archive 가 안 됨.
1. `kill -9` 같은 강제 종료 시 `willTerminate` notification 발화 못 함 — 다음 정상 시동 시 `archiveOrphanedSessions()` 가 처리.
2. 또는 손으로:
   ```bash
   mv ~/Library/Application\ Support/DarwinForge/Harness/current-XXX \
      ~/Library/Application\ Support/DarwinForge/Harness/sessions/XXX
   ```

### Q6. 새 hook 추가하고 싶다.
1. `TelemetryEvent.swift` 의 `TelemetryKind` 에 static let 추가 (`"namespace.event_name"`).
2. 호출 site 에서 `Harness.shared.record(.newKind, level: .info, actor: .user, data: [...])`.
3. PII 우려 있는 자유 텍스트 / 식별자 → `Harness.shortHash(_:)` 또는 `HarnessRedaction.endpoint(_:)`.
4. 본 문서 §3 hook 매핑 표에 행 추가.
5. (선택) `SessionAnalyzer` 의 카운터에 추가 — 통계 카드에 노출 원하면.

---

## 7. 향후 확장 (현재 미구현)

- `imu.unavailable` / `imu.recovered` 자체 발화 — 현재는 context.im 으로만.
- `claude.response_received` / `claude.tool_invoked` wiring.
- ROBOTIS Onboard bridge → `walklab.onboard_ack` 발화.
- `connection.reconnect_*` series — 현재 정의만, 발화 site 미설치.
- Cross-session aggregate dashboard ("최근 30일 평균 RTT").
- Optional opt-in 익명 telemetry 업로드 — 분기점 결정 필요.

---

**작성자**: Harness telemetry v1.13.1 검증 세션.  
**다음 회귀 검증**: 핵심 4 테스트 그린 — `swift test --filter Harness`.
