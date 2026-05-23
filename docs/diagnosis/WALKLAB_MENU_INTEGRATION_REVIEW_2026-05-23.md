# WalkLab + 주변 메뉴 연계성 리뷰

- 작성일: 2026-05-23
- 사이클: 177
- 대상: `RootView.Section` 8 메뉴 + 공유 state (ConnectionStore / WalkLabSession / WalkTrialStore / Harness / WalkLabRCBridge)
- 목적: 메뉴 간 데이터/상태 chain 식별 + 끊김 / 중복 / silent failure 발견

---

## 0. 한 줄 결론

**메뉴 간 chain 80% 완성, 20% gap**. WalkLab ↔ Trial Library ↔ Recommender chain 견고. 단 (1) Connect 의 연결 상태가 모든 메뉴에 반영되나 일부 silent fallback (Studio motion play), (2) Synth → MotionLibrary → Studio → WalkLab chain 의 적용 path 끊김, (3) Pilot 의 motion catalog 와 MotionLibrary 카탈로그 중복, (4) Harness telemetry 이 일부 메뉴 (Conversation / Studio) 미발화.

---

## 1. 메뉴 구조 + 공유 state

### 1.1 8 메뉴 (RootView.Section)

```
studio (스튜디오)         — 일반 자세 control
teach (티칭 모드)         — 사용자가 robot 가르치기
motion (모션 스튜디오)    — motion 편집/재생
walk (워크 랩)            — 보행 + 자이로 보정
conversation (대화)       — Claude AI
pilot (원격 조종)         — 5 source (Keyboard/Tello/Gamepad/Voice/UI)
remote (원격 명령)        — SSH/RPC
expert (전문가)           — WalkDiagnostics 등
```

### 1.2 공유 state (10+ class)

| State | Scope | 생명주기 | 주 consumer |
|---|---|---|---|
| `ConnectionStore` | App | App lifetime | 모든 메뉴 (bus 연결) |
| `WalkLabSession` | App | App lifetime | WalkLab, Expert, Pilot |
| `WalkTrialStore.shared` | App singleton | 영구 | WalkLab Trials, Recommender |
| `Harness.shared` | App singleton | 영구 | 모든 메뉴 (telemetry) |
| `WalkLabRCBridge` | App | App lifetime | Pilot, WalkLab |
| `MotionLibrary` | 메뉴별 @State | 메뉴 lifetime | Motion / WalkLab |
| `PilotMotionCatalog` | App | App lifetime | Pilot, RC bridge |
| `OfficialCatalogReference` | static | 영구 | Motion, Synth |

---

## 2. 정상 chain (완성)

### 2.1 WalkLab → Trial Library → Recommender (✓)

```
사용자가 WalkLab 보행 → WalkLabSession.start(preset)
  ↓
walk cycle Task → sample 누적 → finalize
  ↓
TrialOutcome (cycles 163-165: + correctionEffectMetric)
  ↓
WalkTrialStore.shared.append(trial)
  ↓
Trial Library view 가 load + 표시 (TrialOutcome.correctionEffectMetric.summaryLabel)
  ↓
사용자가 detail 진입
  ↓
WalkTrialRecommender.recommend(for: preset, realRobotOnly: bus 연결됨)
  ↓
Recommender 카드 표시 (cycle 147 SourceBreakdown badge)
  ↓
"이 config 적용" 버튼 → sim only 면 confirmation (cycle 153)
  ↓
WalkLabSession 에 tuning inject → 다음 보행 자동 사용
```

**상태**: 완성. cycles 163-165 + 147 + 153 chain.

### 2.2 Connect → WalkLab (✓)

```
사용자가 Connect 메뉴 → ConnectionWizard → bus 연결
  ↓
ConnectionStore.bus = Bus(...)
  ↓
WalkLab 진입 → WalkLabView.onAppear { session.attach(store: store) }
  ↓
session.store?.bus != nil → start(preset) 시 실 motor 송출 path
  ↓
walk start → store.imuFastPollActive = true (cycle 159, 20Hz)
  ↓
applyBalanceCorrectionIfEnabled 가 imuRollDeg / imuPitchDeg 사용
```

**상태**: 완성. cycles 159, 167, 168 (HUD signal) chain.

### 2.3 Pilot ↔ WalkLab (✓)

```
사용자가 Pilot 메뉴 → bridge.session = walkLabSession 자동 wire (RootView.onAppear)
  ↓
Pilot 의 keyboard W → KeyboardPilotMapper → bridge.handleIntent
  ↓
bridge.session?.tap(preset: .march, advanced: false)
  ↓
WalkLab session 가 보행 시작
  ↓
WalkLab 종료 시 trial 자동 저장 (pilotInputs 첨부 — cycle 7)
```

**상태**: 완성. cycles 7, 67-72 chain.

---

## 3. Gap 발견 (P0/P1)

### 3.1 P0 — Studio motion play 가 ConnectionStore 무관 silent

- **위치**: `Studio/StudioView.swift` 의 motion play handler.
- **현상**: 사용자가 Studio 에서 motion play 클릭 시:
  - bus 연결됨 → 실 motor 송출.
  - bus 미연결 → **silent fallback** (sim 모드 indication 없음).
- **확인 필요**: motion play 가 sim only 모드 진입 시 사용자에게 명시 — Trial Library 의 cycle 153 처럼.
- **영향**: 사용자가 Studio motion play 후 "robot 안 움직임 — 왜?" 혼란.
- **권고**: motion play 버튼에 connection state badge (cycle 152 의 DFStatusBadge 활용).

### 3.2 P0 — Synth validate → 적용 path 끊김

- **위치**: `Synth/SynthInspectorPanel.swift`.
- **현상**:
  - Synth 가 page generate + validate (앱 내부 mocked Pass).
  - 사용자가 validate 통과한 page 를 Motion Studio 에 적용하려면 → ??? 자동 path 없음.
  - cycle 127 에서 "외부 CLI validate 권장" 표시 했지만 chain 자체 없음.
- **권고**: Synth → MotionLibrary auto-import (validate pass 시) or 명시 export 버튼.

### 3.3 P0 — Pilot motion catalog vs MotionLibrary 중복

- **위치**: `Pilot/MotionCatalog.swift` vs `MotionLibraryView.swift`.
- **현상**:
  - Pilot 의 motion 7개 (slot 1, 2, 3, 4, 9, 10, 11, ...).
  - MotionLibrary 의 official 16개 + reference 19개 + prebundled 5개.
  - Pilot 이 slot 10/11 Get Up Front/Back 가짐 — MotionLibrary 와 동일 ID.
- **영향**: 같은 motion 이 두 곳에서 다른 metadata. cycle 143 의 [placeholder] prefix 가 MotionLibrary 에 적용됐는데 Pilot 도 같이 적용? → 확인 필요.
- **권고**: PilotMotionCatalog 가 MotionLibrary 의 subset reference. metadata single source.

### 3.4 P1 — Conversation (Claude) 의 Harness telemetry 발화 미흡

- **위치**: `Conversation/ConversationViewModel.swift`.
- **현상**: Claude API 호출 / 응답 — Harness telemetry 미발화 가능.
- **확인**: `grep -n "Harness.shared.record" Conversation/` — 결과 분석.
- **권고**: claude.request / claude.response / claude.error 신규 TelemetryKind.

### 3.5 P1 — Expert WalkDiagnostics 가 WalkLab session 만 사용 — Trial Library 무관

- **위치**: `Expert/WalkDiagnostics/`.
- **현상**: WalkDiagnostics 의 metric 이 live session 만 — 과거 trial 비교 미지원.
- **권고**: trial 선택 dropdown → 과거 vs 현재 비교 view.

### 3.6 P1 — Remote (SSH) 명령 결과가 Harness telemetry 미발화

- **위치**: `Remote/RemoteShell.swift` 등.
- **현상**: SSH 명령 실행 → 결과 stdout/stderr 만 표시 → telemetry 발화 없음.
- **권고**: ssh.command / ssh.response / ssh.error TelemetryKind.

---

## 4. 시각 chain 다이어그램

```
┌─────────────┐   bus 연결    ┌─────────────────┐
│  Connect    │──────────────→│ ConnectionStore │
└─────────────┘               └────────┬────────┘
                                       │ (모든 메뉴 read)
       ┌───────────────────────────────┼────────────────────────┐
       │                               │                        │
       ▼                               ▼                        ▼
┌───────────┐   session             ┌─────────┐            ┌─────────┐
│  WalkLab  │←─────────────────────→│ Pilot   │            │ Studio  │
│ Session   │   bridge.session       │ Bridge  │            │ View    │
└─────┬─────┘                        └─────────┘            └────┬────┘
      │ trial finalize                                            │ motion play
      ▼                                                            │
┌─────────────┐                                                    │
│ WalkTrial   │←────── Recommender ────────→ Recommendation Card   │
│ Store (📦)  │                                                    │
└─────────────┘                                                    │
                                                                   ▼
                                                              ┌─────────┐
                                                              │ Robot   │
                                                              │ (bus)   │
                                                              └─────────┘

┌─────────────┐                                ┌─────────────┐
│  Synth      │ ??? gap (cycle 177 #3.2) ?→   │ MotionLibrary│
│ Inspector   │                                └──────┬──────┘
└─────────────┘                                       │ (Studio 도 read)
                                                      │
                                                      ▼
                                                ┌──────────┐
                                                │ Pilot    │
                                                │ Catalog  │ ← cycle 177 #3.3 중복?
                                                └──────────┘

┌──────────────────────────────────────────────────────────┐
│ Harness.shared (모든 메뉴 telemetry 발화)                │
│ WalkLab ✓ / Pilot ✓ / Trial ✓ / Conversation? / Remote?│
└──────────────────────────────────────────────────────────┘
```

---

## 5. 우선순위 처리 계획

### P0 즉시 (cycle 178+)

1. **#3.1 Studio motion play sim/real badge** — cycle 178.
2. **#3.3 Pilot/MotionLibrary 중복 검증 + [placeholder] 일관** — cycle 179.
3. **#3.2 Synth → MotionLibrary chain wire-up** — cycle 180 (도구 design 필요).

### P1 다음 sprint

4. **#3.4 Conversation harness hook** — cycle 181.
5. **#3.5 Expert vs Trial Library 통합** — cycle 182.
6. **#3.6 Remote SSH harness hook** — cycle 183.

---

## 6. 결론

WalkLab 자이로 closed-loop 는 cycles 158-176 에서 80% 완성. 본 audit 는 메뉴 간 연계 의 남은 20% 의 gap 6건 식별. P0 3건 즉시 처리 → cycle 178-180.
