# Log Utilization System — 로그를 능동적 통찰로 변환

> **v1.14.0 (2026-05-20)** — 텔레메트리 하네스 v1.13.x 가 "기록"을 잘 한다면, 본 시스템은 그 기록을 자동으로 "의미"로 바꿔서 사용자/AI 가 다음 행동을 결정하게 한다.

**책임자**: DarwinForge UI / Logging/Harness 모듈
**의존**: `SessionAnalysis` (v1.13.0)
**상태**: 신규 도입

---

## 1. 닫힌 루프 (Closed Loop)

```
실 로봇 사용 ─▶ 이벤트 기록 ─▶ 세션 분석 ─▶ [Insights] ─▶ 행동 권고
                                              ▲                │
                                              │                ▼
                                        Cross-session       사용자 / AI
                                        Baseline diff       (수정 / 재시도)
                                              ▲                │
                                              └────────────────┘
                                              개선 후 다음 세션
```

- 기록 단계 (`v1.12.x`): events.jsonl + meta.json
- 분석 단계 (`v1.13.0`): SessionAnalysis (summary + timeline + envelopes)
- **활용 단계 (v1.14.0, 본 문서)**:
  - `HarnessInsights` — 룰 기반 패턴 검출 → 권고
  - `HarnessBaseline` — 핀 세션 vs 새 세션 자동 diff
  - `HarnessLiveAlerts` — 진행 중 세션 임계 모니터
  - `HarnessJSONReport` — Claude/AI 친화 구조화 export

---

## 2. Insights — 룰 기반 패턴 검출

### 2.1 Insight 모델

```swift
public struct Insight {
    let id: String                  // 룰 ID + 발화 시점 hash
    let severity: Severity          // info | notice | warn | critical
    let kind: Kind                  // 카테고리 (connection, imu, motion, ...)
    let title: String               // 한국어 한 줄
    let evidence: String            // 어떤 데이터 보고 판단했나
    let recommendation: String      // 무엇을 해보라 (사용자 행동)
    let eventRefs: [String]         // 관련 이벤트 seq (Inspector 점프)
    let confidence: Double          // 0..1
}
```

### 2.2 규칙 카탈로그

| 룰 ID | 발화 조건 | Severity | 권고 |
|-------|----------|---------|------|
| `connection.high_failure_rate` | 연결 실패율 ≥ 40% 또는 연속 3회 실패 | warn | USB 케이블 / 드라이버 / 전원 확인 |
| `connection.flapping` | 60초 내 연결-끊김 사이클 3회+ | warn | 네트워크 안정성 / `socat` 프로세스 확인 |
| `rtt.regression` | RTT p95 > 50ms 또는 baseline 대비 +30% | notice | bus polling cadence 또는 endpoint 검토 |
| `rtt.severe` | RTT p95 > 100ms | warn | 즉시 disconnect / 네트워크 진단 |
| `imu.stale_persistent` | heartbeat 중 imu_stale=true 비율 ≥ 25% | warn | IMU register 응답 확인, firmware variant 가능성 |
| `bus.read_storm` | bus.read_fail > 10 / 분 | warn | 특정 motor ID 단선 / power 강하 의심 |
| `walklab.start_blocked_repeat` | 같은 reason 으로 3+ 차단 | warn | preflight 조건 (cradle / IMU / brokering) 점검 |
| `walklab.emergency_pattern` | 보행 시작 N분 내 e-stop ≥ 1회 (단일 세션) | critical | tilt / fall predictor 임계 / IMU 부호 검토 |
| `pose.write_failed_chain` | pose write_failed → bus.read_fail 연쇄 | warn | bus / 모터 power 회복 시퀀스 |
| `harness.dropped_present` | drop > 0 | notice | 이벤트 율 줄이기 / 버퍼 늘리기 검토 |
| `idle_session` | 세션 30분+ 인데 active 이벤트 < 10 | info | 진단 의도가 명확한지 / 닫는 것이 좋은지 |

각 룰은 pure function — `SessionAnalysis` 만 입력으로 받아 0..N 개 Insight 반환.

### 2.3 향후 확장
- 패턴 라이브러리에 사용자 기여 룰 추가 (`~/.config/darwinforge/insights.json`)
- AI 추론 룰 — Claude 호출해서 자유 텍스트 인사이트 추출 (옵션)

---

## 3. Baseline — 세션 간 비교

### 3.1 어떻게 baseline 지정?

- Inspector 의 세션 메뉴에 **"Baseline 으로 지정"** 추가
- meta.json 에 `isBaseline: true` 저장 (`pinned` 와 별개. baseline 은 동시에 1개만)
- UserDefaults `harness.baseline_session_id` 에 ID 저장

### 3.2 SessionDiff 모델

```swift
public struct SessionDiff {
    let baselineId: String
    let currentId: String
    let metrics: [MetricDelta]      // RTT, 연결 성공률, etc.
    let counts: [CountDelta]        // 에러 / e-stop / 차단 / walkLab.start 등
    let verdict: Verdict            // .improvement | .regression | .similar
}

public enum Verdict {
    case improvement(reason: String)
    case regression(reason: String)
    case similar
}
```

### 3.3 판정 규칙

- 핵심 5개 지표 가중 평균:
  - RTT p95 (lower better, weight 1)
  - 연결 성공률 (higher better, weight 2)
  - 에러 카운트 (lower better, weight 1)
  - e-stop / emergency stop (lower better, weight 3)
  - walkLab.start_blocked / start 비율 (lower better, weight 1)
- 가중 합 ±10% 이내 → `.similar`. -20%↓ → `.improvement`. +20%↑ → `.regression`.
- 결정적이지 못한 경계 — `confidence` 도 함께 노출.

---

## 4. Live Alerts — 진행 중 모니터

### 4.1 모니터 사이클

- 별도 타이머 1Hz — 최근 60초 윈도우 의 이벤트만 분석
- in-memory ring buffer (heartbeat 사이로 events 받아옴)
- 임계 초과 시 `ActiveAlert` 발행 → Inspector 배너 + (옵션) 토스트

### 4.2 임계 (default)

| 알림 | 윈도우 | 임계 |
|------|-------|------|
| RTT 급증 | 60s 평균 | > 80 ms |
| IMU stale 비율 | 60s heartbeat | ≥ 50% |
| 연결 실패 buffer | 60s | failure ≥ 2 |
| Bus write fail | 60s | ≥ 3 |
| 사용자 e-stop | 즉시 | 1 회 (level=critical) |

알림은 자동 해제 — 임계 하단으로 복귀하면 60초 후 사라짐.

### 4.3 토스트 설정

- 기본 OFF. Inspector 좌측 하단 "라이브 알림 토스트" 토글.
- 옵션 ON 시 critical / warn 알림은 NSUserNotification 으로 표시.

---

## 5. JSON Export — AI / 외부 도구

### 5.1 포맷

```jsonc
{
  "schema": "darwinforge-harness/1.0",
  "session": { /* meta + summary */ },
  "insights": [ /* HarnessInsights output */ ],
  "errors": [ /* envelope summary */ ],
  "timeline": [ /* bins */ ],
  "diff": { /* optional: baseline 지정돼 있으면 */ }
}
```

### 5.2 호출 시나리오

- Inspector → "Markdown 리포트" 옆 "**JSON 리포트**" 메뉴
- Claude/외부 스크립트가 직접 `harness export <id> --json > report.json` (CLI 추후 확장)
- AI 가 받아서 자체 분석 → 권고 → 사용자에게 (`Conversation` 흐름)

---

## 6. UI 통합 (Inspector v2)

```
┌─────────────────────────────────────────────────────────────┐
│  Session 0F3A...     [Baseline 으로 지정]   [동작 메뉴 ▼]   │
├─────────────────────────────────────────────────────────────┤
│  Summary cards (기존)                                       │
│  Timeline strip (기존)                                      │
│  ─────────────────────────────────────────────────────────  │
│  🔍 Insights (3)                                            │
│   • [critical] WalkLab 보행 시작 30초 내 e-stop 발생       │
│     → tilt 임계 / IMU 부호 / fall predictor 검토            │
│   • [warn] RTT p95 75ms — baseline 대비 +42%                │
│     → bus polling cadence / 케이블 검토                     │
│   • [notice] heartbeat IMU stale 27% — 정상은 < 5%          │
│  ─────────────────────────────────────────────────────────  │
│  📊 Baseline 비교 vs 0A12...                                │
│   • RTT p95 75ms (+15ms vs baseline)  ⚠️ regression         │
│   • 연결 성공률 100% (= baseline)        ✅                  │
│   • 보행 시작 차단 5건 (+4)               ⚠️                 │
│   → 종합: REGRESSION (-18%)                                 │
└─────────────────────────────────────────────────────────────┘
```

진행 중 세션 (Current) 패널에는 LiveAlerts 배너:
```
┌─ 🔴 라이브 알림 (2) ─────────────────────────────────────────┐
│ • [60s] RTT 평균 95ms — 임계 80ms 초과                      │
│ • [즉시] e-stop 발동                                        │
└──────────────────────────────────────────────────────────────┘
```

---

## 7. 비목표

- 외부 서버 전송 — 모든 분석 로컬
- ML 기반 자동 분류 — v1 은 룰 기반만
- 자동 코드 수정 — 권고는 사람이 실행
- 다국어 — 현재 한국어. 영어 fallback 추후

---

## 8. 마이그레이션 / 호환

- 기존 v1.13.x 와 100% 호환. 새 모듈은 모두 부가 — 비활성화 가능.
- meta.json 에 `isBaseline` 필드 추가 — 옛 세션 로딩 시 `false` 폴백 (이미 lossy decode 적용).
- 기존 테스트 회귀 0건 목표.

---

## 9. 검증 매트릭스 (v1.14.0)

| 레이어 | 테스트 |
|--------|-------|
| Insights 룰 | 룰 별 trigger / no-trigger 케이스 (16+ unit) |
| Baseline diff | metric/count delta 계산, verdict 분기 (5+ unit) |
| LiveAlerts | 윈도우 계산, 임계 trigger / 해제 (4+ unit) |
| JSON export | schema 검증, baseline 옵션 (3+ unit) |
| 회귀 | 기존 716 테스트 그린 유지 |

---

**참고**:
- `docs/harness/telemetry-harness.md` — 기록 레이어
- `docs/harness/real-robot-verification.md` — 실 로봇 검증 가이드
- 본 문서 — 활용 레이어
